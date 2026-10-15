import Foundation
import Darwin
import CoolMacCore
import CoolMacHardware

final class Worker {
    private let hardware: FanHardware
    private var policy = FanPolicy()
    private var status = ServiceStatus(available: true, phase: .system, message: "系统自动控制")
    private var deadline: Double = 0
    private var boostUntil: Double = 0
    private var commissionUntil: Double?
    private var commissionTarget: Double = 0
    private var expectedTargets: [Int: Double] = [:]
    private var targetChangedAt: Double = 0
    private var responseFailures = 0
    private var automaticConfirmed = false
    private var enhancement = 0
    private var lastTick: Double = 0
    private let input = LineBuffer()
    private var lockFD: Int32 = -1
    private let recoveryOnly: Bool

    init(recoveryOnly: Bool) throws {
        self.recoveryOnly = recoveryOnly
        let descriptor = open(statePath("writer.lock"), O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HardwareError("无法打开受保护的风扇写入锁") }
        var initialized = false
        defer { if !initialized { close(descriptor) } }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw HardwareError("旧控制进程仍持有写入锁，禁止并发接管") }
        lockFD = descriptor
        hardware = try FanHardware(discoverSensors: !recoveryOnly)
        status.workerPID = getpid()
        if hasState("armed") {
            try restore()
            try putState("fault", text: "上次控制进程中断，已恢复系统自动；需要重新安全自检")
            status.message = "上次遗留控制已恢复系统自动"
        }
        if recoveryOnly { initialized = true; return }
        let snapshot = try hardware.sample()
        status.snapshot = snapshot
        automaticConfirmed = snapshot.fans.allSatisfy { !$0.manual }
        status.commissioned = (try? String(contentsOfFile: statePath("commissioned"), encoding: .utf8)) == fingerprint(snapshot)
        if hasState("fault") {
            status.phase = .fault
            status.message = "上次控制发生故障；已停止接管，请先恢复再重新安全自检"
        }
        if snapshot.fans.contains(where: \.manual) {
            status.phase = .fault
            status.message = "风扇已处于其他程序的手动模式；请先在原程序恢复系统自动"
        }
        initialized = true
    }

    deinit { if lockFD >= 0 { close(lockFD) } }

    private func fingerprint(_ snapshot: HardwareSnapshot) -> String {
        "\(Product.version)|\(snapshot.model)|\(ProcessInfo.processInfo.operatingSystemVersionString)|" + snapshot.fans.map { "\($0.id):\($0.minimumRPM):\($0.maximumRPM)" }.joined(separator: ",")
    }

    private func emit(restored: Bool = false, commissioned: Bool = false) throws {
        status.updatedAt = Date().timeIntervalSince1970
        try FileHandle.standardOutput.write(contentsOf: encodeLine(WorkerEvent(status: status, progress: ContinuousClock.now, restored: restored, commissioningCompleted: commissioned)))
    }

    private func restore(resetPolicy: Bool = true) throws {
        automaticConfirmed = false
        if hasState("armed") {
            let record = try JSONDecoder().decode(OwnershipRecord.self, from: Data(contentsOf: URL(fileURLWithPath: statePath("armed"))))
            let mode = try hardware.smc.number("F0Md")
            if mode == 1 {
                let target = try hardware.smc.number("F0Tg")
                guard record.permitsManualRecovery(target: target) else {
                    try removeState("armed")
                    throw HardwareError("目标已被其他控制器改变；已放弃所有权，不覆盖外部手动控制")
                }
                try hardware.restoreSystem()
            } else if mode != 0 {
                throw HardwareError("恢复时发现未知模式，禁止写入")
            }
            try removeState("armed")
        } else {
            guard try hardware.smc.number("F0Md") == 0 else { throw HardwareError("手动模式不属于本程序，未擅自覆盖其他控制器") }
        }
        guard try hardware.smc.number("F0Md") == 0 else { throw HardwareError("自动模式最终确认失败") }
        automaticConfirmed = true
        expectedTargets = [:]
        responseFailures = 0
        if resetPolicy { policy.reset() }
        status.selectedMode = .system
        status.phase = .system
        status.boostRemaining = nil
        status.commandedRPM = nil
        commissionUntil = nil
    }

    private func arm(targets: [Int: Double]) throws {
        // Both the previous and next target are ours during an interrupted update.
        let allowed = Array(Set(Array(expectedTargets.values) + Array(targets.values)))
        automaticConfirmed = false
        let record = OwnershipRecord(allowedTargets: allowed, enteringManual: expectedTargets.isEmpty, writtenAt: Date().timeIntervalSince1970)
        try putState("armed", text: String(decoding: try JSONEncoder().encode(record), as: UTF8.self))
    }

    private func commitTargets(_ targets: [Int: Double]) throws {
        let record = OwnershipRecord(allowedTargets: Array(targets.values), enteringManual: false, writtenAt: Date().timeIntervalSince1970)
        try putState("armed", text: String(decoding: try JSONEncoder().encode(record), as: UTF8.self))
        expectedTargets = targets
    }

    private func fail(_ error: Error) throws {
        if error is HardwareOwnershipLost { try removeState("armed") }
        let reason = error.localizedDescription
        deadline = 0
        commissionUntil = nil
        status.selectedMode = .system
        do {
            try restore()
            status.message = "已交还系统：" + reason
        } catch {
            status.message = "恢复未确认：\(error.localizedDescription)；原始错误：\(reason)"
        }
        status.phase = .fault
        status.commissioned = false
        try putState("fault", text: status.message)
        try emit(restored: automaticConfirmed)
    }

    private func accept(_ command: WorkerCommand) throws -> Bool {
        let now = ContinuousClock.now
        switch command.operation {
        case .sample: break
        case .shutdown:
            try restore()
            try emit(restored: true)
            return false
        case .restore:
            try restore()
            status.message = "已确认系统自动控制"
            try emit(restored: true)
        case .commission:
            guard commissionUntil == nil else { throw HardwareError("安全自检正在进行") }
            status.commissioned = false
            status.phase = .monitoring
            status.message = "安全自检：正在确认系统自动模式"
            try emit()
            let snapshot = try hardware.sample()
            guard snapshot.supported else { throw HardwareError("硬件自检不受支持") }
            if let conflict = try hardware.conflictingController() { throw HardwareError("请先退出 \(conflict)，避免两个程序争用风扇") }
            guard snapshot.fans.allSatisfy({ !$0.manual }) else { throw HardwareError("安全自检要求风扇先处于系统自动") }
            try hardware.restoreSystem()
            let targets = Dictionary(uniqueKeysWithValues: snapshot.fans.map { fan in
                (fan.id, min(fan.maximumRPM, max(fan.minimumRPM + 600, fan.actualRPM, fan.targetRPM)))
            })
            try arm(targets: targets)
            try hardware.setTargets(targets, ownedTargets: expectedTargets)
            try commitTargets(targets)
            targetChangedAt = now
            responseFailures = 0
            commissionTarget = targets.values.max() ?? 0
            commissionUntil = now + 6
            deadline = min(command.deadline, now + 10)
            status.phase = .cooling
            status.message = "正在安全自检：短时升速后验证恢复系统自动"
        case .select:
            guard let mode = command.mode else { throw HardwareError("缺少预置模式") }
            if mode == .system {
                try restore()
                status.enhancement = enhancement
                status.message = "已确认系统自动控制"
                try emit(restored: true)
                break
            }
            guard status.commissioned, !hasState("fault"), status.phase != .fault else { throw HardwareError("请先完成安全自检") }
            guard commissionUntil == nil else { throw HardwareError("安全自检尚未结束") }
            guard hasState("armed") || status.snapshot?.fans.allSatisfy({ !$0.manual }) == true else { throw HardwareError("其他控制器已接管风扇，拒绝争用") }
            if let conflict = try hardware.conflictingController() { throw HardwareError("请先退出 \(conflict)") }
            if mode != status.selectedMode || (command.enhancement != nil && command.enhancement != enhancement) {
                // A changed step must take effect now: release, then re-enter with
                // the new base instead of holding the previous higher target.
                if hasState("armed") { try restore() }
                policy.reset()
                if mode == .boost { boostUntil = now + 120 }
            }
            if let requested = command.enhancement {
                guard Enhancement.isValid(requested) else { throw HardwareError("增强档位无效") }
                enhancement = requested
            }
            status.selectedMode = mode
            status.enhancement = enhancement
            deadline = min(command.deadline, now + 6)
        case .renew:
            if let requested = command.enhancement {
                guard Enhancement.isValid(requested) else { throw HardwareError("增强档位无效") }
                if requested != enhancement {
                    if hasState("armed") { try restore() }
                    policy.reset()
                    enhancement = requested
                }
                status.enhancement = enhancement
            }
            deadline = min(command.deadline, now + 6)
        }
        return true
    }

    private func tick() throws {
        let now = ContinuousClock.now
        let gap = now - lastTick
        lastTick = now
        if gap > 4 && hasState("armed") {
            try restore()
            status.message = "采样间隔中断或睡眠唤醒，已交还系统"
        }
        let snapshot = try hardware.sample()
        status.snapshot = snapshot
        if hasState("armed") {
            for fan in snapshot.fans {
                guard fan.manual, let expected = expectedTargets[fan.id], abs(fan.targetRPM - expected) <= 3 else { throw HardwareError("检测到风扇模式被外部改变；停止争用") }
            }
            if commissionUntil == nil && now - targetChangedAt >= 8 {
                let responding = snapshot.fans.allSatisfy { fan in fan.actualRPM >= fan.targetRPM - max(700, fan.targetRPM * 0.2) }
                responseFailures = responding ? 0 : responseFailures + 1
                if responseFailures >= 3 { throw HardwareError("风扇实测转速持续未响应目标，已停止接管") }
            }
        } else if snapshot.fans.contains(where: \.manual) {
            status.phase = .unavailable
            status.message = "其他控制器已接管风扇，请先恢复系统自动"
            status.selectedMode = .system
        }
        if commissionUntil != nil || status.selectedMode != .system {
            guard now < deadline else {
                try restore()
                status.message = "控制许可已过期，已确认恢复系统自动"
                try emit(restored: true)
                return
            }
            if let conflict = try hardware.conflictingController() { throw HardwareError("检测到 \(conflict)，已停止自定义控制") }
        }
        if let until = commissionUntil {
            if now >= until {
                guard let fan = snapshot.fans.first, fan.actualRPM >= max(900, commissionTarget - 700) else { throw HardwareError("自检时风扇实测 RPM 未响应目标") }
                try restore()
                try putState("commissioned", text: fingerprint(snapshot))
                try removeState("fault")
                status.commissioned = true
                status.message = "安全自检通过：升速与恢复系统自动已验证"
                status.snapshot = try hardware.sample()
                try emit(restored: true, commissioned: true)
            } else { try emit() }
            return
        }
        guard status.selectedMode != .system else {
            if status.phase != .fault && status.phase != .unavailable { status.phase = .system }
            try emit()
            return
        }
        if status.selectedMode == .boost && now >= boostUntil {
            try restore()
            status.message = "强力散热已到期，已交还系统"
            try emit(restored: true)
            return
        }
        let selected = status.selectedMode
        let decision = policy.evaluate(snapshot: snapshot, mode: selected, enhancement: enhancement, now: now, sampleAge: 0)
        switch decision.action {
        case .targets:
            if expectedTargets.isEmpty || decision.targets.contains(where: { $0.value - (expectedTargets[$0.key] ?? 0) > 500 }) {
                targetChangedAt = now
                responseFailures = 0
            }
            try arm(targets: decision.targets)
            try hardware.setTargets(decision.targets, ownedTargets: expectedTargets)
            try commitTargets(decision.targets)
            status.phase = selected == .boost ? .boosting : .cooling
            status.message = decision.reason
        case .system:
            if hasState("armed") { try restore(resetPolicy: false) }
            status.selectedMode = selected
            status.phase = .system
            status.message = decision.reason
            if snapshot.thermalPressure >= 2 || (snapshot.hottest ?? 0) >= 90 {
                throw HardwareError(decision.reason)
            }
        case .hold: status.message = decision.reason
        case .fault: throw HardwareError(decision.reason)
        }
        if let baseline = decision.baselineRPM { status.baselineRPM = baseline }
        if let commanded = decision.commandedRPM, decision.action == .targets { status.commandedRPM = commanded }
        if decision.action == .system { status.commandedRPM = nil }
        status.enhancement = enhancement
        status.snapshot = try hardware.sample()
        if selected == .boost { status.boostRemaining = max(0, Int(boostUntil - now)) }
        try emit()
    }

    func run() throws {
        if recoveryOnly {
            try restore()
            status.message = "恢复进程已确认系统自动"
            try emit(restored: true)
            return
        }
        lastTick = ContinuousClock.now
        try emit(restored: automaticConfirmed)
        var running = true
        while running {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&descriptor, 1, 200)
            guard result >= 0 || errno == EINTR else { throw HardwareError("监督通道读取失败") }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count <= 0 {
                    if hasState("armed") || status.selectedMode != .system {
                        try putState("fault", text: "监督进程失联，已停止接管；需要重新安全自检")
                    }
                    try restore()
                    try emit(restored: true)
                    break
                }
                for line in try input.append(Data(bytes.prefix(count))) {
                    do { running = try accept(JSONDecoder().decode(WorkerCommand.self, from: line)) }
                    catch { try fail(error) }
                    if !running { break }
                }
            }
            if running && ContinuousClock.now - lastTick >= 1 {
                do { try tick() }
                catch { try fail(error) }
            }
        }
    }
}
