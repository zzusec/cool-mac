import Foundation
import Darwin
import SystemConfiguration
import IOKit.pwr_mgt
import CoolMacCore
import CoolMacHardware
import CIPC
import CSMC

private func handleClientJSON(_ json: UnsafePointer<CChar>?, _ uid: UInt32, _ pid: Int32, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
    guard let json, let context else { return nil }
    let guardian = Unmanaged<Guardian>.fromOpaque(context).takeUnretainedValue()
    return strdup(guardian.handle(String(cString: json), uid: uid, pid: pid))
}

// All mutable state is confined to queue; C callbacks enter through handle().
final class Guardian: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.hx10.coolmac.guardian")
    private var status = ServiceStatus(available: true, phase: .monitoring, message: "后台已启动，正在只读自检")
    private var worker: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var lineBuffer = LineBuffer()
    private var timer: DispatchSourceTimer?
    private var lastProgress = ContinuousClock.now
    private var lastRenew = 0.0
    private var leaseUntil = 0.0
    private var ownerSession: String?
    private var ownerPID: Int32?
    private var requestedMode: CoolingMode = .system
    private var requestedEnhancement: Int?
    private var recoveryAttempts = 0
    private var stopping = false
    private var forceRecovery = false
    private var recoveryConfirmed = false
    private var waitingForExit = false
    private var shutdownRequested = false
    private var power = PowerObserver()

    func start() throws {
        try verifyInstalledHelper()
        try createStateDirectory()
        status.guardianPID = getpid()
        let result = Product.service.withCString { service in
            Product.manifestPath.withCString { manifest in
                cm_server_start(service, manifest, handleClientJSON, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard result == 0 else { throw HardwareError("无法注册可信本地 IPC 服务（\(result)）") }
        try power.start { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.requestedMode = .system
                self.leaseUntil = 0
                self.ownerSession = nil
                self.send(WorkerCommand(operation: .restore))
                self.status.message = "睡眠/唤醒后已撤销旧控制许可"            }
        }
        queue.async { self.launchWorker(recovery: false) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.supervise() }
        timer.resume()
        self.timer = timer
    }

    private func consoleUID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid), name as String != "loginwindow", uid >= 500 else { return nil }
        return uid
    }

    func handle(_ json: String, uid: UInt32, pid: Int32) -> String {
        queue.sync {
            do {
                guard !shutdownRequested else { throw HardwareError("后台正在退出") }
                guard consoleUID() == uid else { throw HardwareError("只允许当前登录桌面的用户控制") }
                let request = try JSONDecoder().decode(ServiceRequest.self, from: Data(json.utf8))
                try ProtocolValidation.validate(request)
                switch request.operation {
                case .status: break
                case .restore:
                    requestedMode = .system
                    leaseUntil = 0
                    ownerSession = nil
                    ownerPID = nil
                    send(WorkerCommand(operation: .restore))
                    status.phase = .restoring
                    status.message = "正在交还系统；等待硬件回读确认"
                case .select, .commission:
                    guard !waitingForExit, worker?.isRunning == true else { throw HardwareError("硬件进程未就绪") }
                    let now = ContinuousClock.now
                    if let ownerSession, leaseUntil > now, ownerSession != request.session || ownerPID != pid {
                        throw HardwareError("已有另一个清凉风扇会话控制，请先恢复系统自动")
                    }
                    if request.operation == .select, request.mode != .system {
                        guard status.commissioned, status.phase != .fault else { throw HardwareError("请先完成风扇安全自检") }
                    }
                    ownerSession = request.session
                    ownerPID = pid
                    leaseUntil = now + (request.operation == .commission ? 10 : 5)
                    requestedMode = request.mode ?? .system
                    requestedEnhancement = request.enhancement
                    if request.operation == .commission {
                        status.commissioned = false
                        status.phase = .monitoring
                    }
                    send(WorkerCommand(operation: request.operation == .commission ? .commission : .select, mode: request.mode, enhancement: request.enhancement, deadline: leaseUntil))
                    status.message = request.operation == .commission ? "正在启动短时风扇安全自检" : "模式切换已请求，等待硬件确认"
                case .renew:
                    guard ownerSession == request.session, ownerPID == pid, ContinuousClock.now < leaseUntil else { throw HardwareError("控制会话已过期，请重新选择模式") }
                    leaseUntil = ContinuousClock.now + 5
                    if let enhancement = request.enhancement { requestedEnhancement = enhancement }
                    send(WorkerCommand(operation: .renew, enhancement: request.enhancement, deadline: min(leaseUntil, ContinuousClock.now + 3)))
                }
                return response(ok: true)
            } catch { return response(ok: false, error: error.localizedDescription) }
        }
    }

    private func response(ok: Bool, error: String? = nil) -> String {
        let response = ServiceResponse(ok: ok, error: error, status: status)
        do { return String(decoding: try JSONEncoder().encode(response), as: UTF8.self) }
        catch { return "{\"ok\":false,\"error\":\"后台状态编码失败\"}" }
    }

    private func launchWorker(recovery: Bool) {
        guard worker == nil, !shutdownRequested else { return }
        recoveryConfirmed = false
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: Product.helperPath)
        process.arguments = [recovery ? "--recover-worker" : "--worker"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let buffer = LineBuffer()
        self.lineBuffer = buffer
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in self?.receive(data, processID: process.processIdentifier) }
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.workerExited(processID: process.processIdentifier, code: process.terminationStatus, wasRecovery: recovery) }
        }
        do {
            let descriptor = input.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw HardwareError("无法建立非阻塞监督通道") }
            try process.run()
            worker = process
            self.input = input
            self.output = output
            status.workerPID = process.processIdentifier
            lastProgress = ContinuousClock.now
            waitingForExit = false
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            status.phase = .fault
            status.message = "无法启动硬件进程：\(error.localizedDescription)"
            status.commissioned = false
        }
    }

    private func receive(_ data: Data, processID: Int32) {
        guard worker?.processIdentifier == processID, !data.isEmpty else { return }
        do {
            for line in try lineBuffer.append(data) {
                let event = try JSONDecoder().decode(WorkerEvent.self, from: line)
                guard event.progress.isFinite, event.progress <= ContinuousClock.now + 1 else { throw HardwareError("硬件进度时间无效") }
                lastProgress = event.progress
                if event.restored { recoveryConfirmed = true }
                let guardianPID = status.guardianPID
                let previousError = forceRecovery ? status.message : nil
                status = event.status
                status.guardianPID = guardianPID
                status.workerPID = processID
                if let previousError {
                    status.phase = .fault
                    status.message = event.restored ? "已恢复系统自动；\(previousError)" : "\(previousError)；恢复未确认"
                    status.commissioned = false
                }
                if status.phase == .fault || event.commissioningCompleted {
                    requestedMode = .system
                    leaseUntil = 0
                    ownerSession = nil
                }
            }
        } catch { interruptWorker("硬件进程响应无效：\(error.localizedDescription)") }
    }

    private func send(_ command: WorkerCommand) {
        guard let input, worker?.isRunning == true, !waitingForExit else { return }
        do {
            let data = try encodeLine(command)
            guard data.count <= 512 else { throw HardwareError("监督消息超过原子写入上限") }
            let count = data.withUnsafeBytes { bytes in
                write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            guard count == data.count else { throw HardwareError("非阻塞监督通道已满或断开（errno \(errno)）") }
        } catch { interruptWorker("监督通道写入失败：\(error.localizedDescription)") }
    }

    private func interruptWorker(_ reason: String) {
        guard !waitingForExit else { return }
        forceRecovery = true
        requestedMode = .system
        leaseUntil = 0
        ownerSession = nil
        status.phase = .fault
        status.commissioned = false
        status.message = reason
        do { try putState("fault", text: reason) }
        catch { status.message += "；故障状态保存失败：\(error.localizedDescription)" }
        if let process = worker, process.isRunning {
            waitingForExit = true
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func workerExited(processID: Int32, code: Int32, wasRecovery: Bool) {
        guard worker?.processIdentifier == processID else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        worker = nil
        status.workerPID = nil
        waitingForExit = false
        if shutdownRequested { exit(hasState("armed") ? 1 : 0) }
        if wasRecovery {
            if code != 0 || !recoveryConfirmed || hasState("armed") {
                status.phase = .fault
                status.message += "；自动恢复未确认（退出码 \(code)）"
                if recoveryAttempts < 2 {
                    recoveryAttempts += 1
                    queue.asyncAfter(deadline: .now() + 1) { self.launchWorker(recovery: true) }
                }
            } else {
                forceRecovery = false
                status.phase = .fault
                status.message = "系统自动已恢复；为安全起见暂停接管，请重新安全自检"
                launchWorker(recovery: false)
            }
        } else {
            forceRecovery = true
            status.phase = .fault
            status.commissioned = false
            status.message = "硬件进程意外退出（\(code)），正在恢复系统自动"
            requestedMode = .system
            leaseUntil = 0
            ownerSession = nil
            recoveryAttempts = 1
            do { try putState("fault", text: status.message) }
            catch { status.message += "；状态保存失败：\(error.localizedDescription)" }
            queue.asyncAfter(deadline: .now() + 0.5) { self.launchWorker(recovery: true) }
        }
    }

    private func supervise() {
        let now = ContinuousClock.now
        guard worker != nil else { return }
        if !waitingForExit, now - lastProgress > 4 {
            interruptWorker("硬件采样卡住或数据过期，已撤销控制许可")
            return
        }
        if now - lastRenew >= 1, !waitingForExit {
            lastRenew = now
            if leaseUntil > now {
                send(WorkerCommand(operation: .renew, enhancement: requestedEnhancement, deadline: min(leaseUntil, now + 3)))
            } else if requestedMode != .system || ownerSession != nil {
                requestedMode = .system
                ownerSession = nil
                ownerPID = nil
                send(WorkerCommand(operation: .restore))
                status.phase = .restoring
                status.message = "界面失联或许可过期，正在恢复系统自动"
            } else {
                send(WorkerCommand(operation: .sample))
            }
        }
    }

    func shutdown() {
        queue.async {
            self.shutdownRequested = true
            self.requestedMode = .system
            self.leaseUntil = 0
            self.send(WorkerCommand(operation: .shutdown))
            self.queue.asyncAfter(deadline: .now() + 4) {
                if let worker = self.worker, worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
                exit(hasState("armed") ? 1 : 0)
            }
        }
    }
}

// Power notifications are handled on the daemon run loop, never by SMC I/O.
final class PowerObserver: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private var handler: (@Sendable () -> Void)?

    func start(handler: @escaping @Sendable () -> Void) throws {
        self.handler = handler
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            if message == cm_power_will_sleep() || message == cm_power_did_wake() {
                observer.handler?()
            }
            if message == cm_power_will_sleep() || message == cm_power_can_sleep() {
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            }
        }, &notifier)
        guard connection != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else { throw HardwareError("无法注册睡眠/唤醒安全通知") }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if connection != 0 { IOServiceClose(connection) }
        if let port { IONotificationPortDestroy(port) }
    }
}
