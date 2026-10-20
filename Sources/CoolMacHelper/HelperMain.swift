import Foundation
import Darwin
import OSLog
import CoolMacCore
import CoolMacHardware

@main
struct HelperMain {
    static func main() {
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)
        do {
            try verifyInstalledHelper()
            try createStateDirectory()
            switch CommandLine.arguments.dropFirst().first {
            case "--worker": try Worker(recoveryOnly: false).run()
            case "--recover-worker": try Worker(recoveryOnly: true).run()
            case "--install-service": try installService()
            case "--prepare-upgrade": try stopAndRestore()
            case "--uninstall": try uninstall()
            case "--uninstall-after-app-removal": try uninstall(onlyIfAppMissing: true)
            case "--daemon":
                let guardian = Guardian()
                try guardian.start()
                signal(SIGTERM, SIG_IGN)
                signal(SIGINT, SIG_IGN)
                let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
                term.setEventHandler { guardian.shutdown() }
                interrupt.setEventHandler { guardian.shutdown() }
                term.resume()
                interrupt.resume()
                withExtendedLifetime((guardian, term, interrupt)) { RunLoop.main.run() }
            default: throw HardwareError("不支持的后台组件操作")
            }
        } catch {
            FileHandle.standardError.write(Data(("CoolMacHelper: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    @discardableResult
    static func launchctl(_ arguments: [String], allowMissing: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || (allowMissing && (process.terminationStatus == 3 || process.terminationStatus == 113)) else {
            throw HardwareError("launchctl \(arguments.first ?? "") 失败（\(process.terminationStatus)）：\(String(decoding: data, as: UTF8.self))")
        }
        return process.terminationStatus
    }

    static func installService() throws {
        let plist = "/Library/LaunchDaemons/\(Product.service).plist"
        try assertRootPath(plist)
        try launchctl(["bootstrap", "system", plist])
        try launchctl(["print", "system/" + Product.service])
        print("清凉风扇后台已安装；默认仅监测，安全自检后才控制")
    }

    static func stopAndRestore() throws {
        try launchctl(["bootout", "system/" + Product.service], allowMissing: true)
        let end = ContinuousClock.now + 8
        var lastError: Error?
        // Even an idle worker owns the writer lock. Wait for its actual exit,
        // not just the absence of an armed marker, before taking that lock.
        while ContinuousClock.now < end {
            do {
                guard try launchctl(["print", "system/" + Product.service], allowMissing: true) != 0 else {
                    throw HardwareError("旧 launchd 服务仍未注销")
                }
                guard try controlProcessesStopped() else { throw HardwareError("旧后台或硬件进程尚未退出") }
                let recovery = try Worker(recoveryOnly: true)
                try recovery.run()
                guard !hasState("armed") else { throw HardwareError("自动恢复未确认，停止卸载/升级") }
                return
            } catch { lastError = error }
            usleep(100000)
        }
        throw HardwareError("后台尚未安全停止：\(lastError?.localizedDescription ?? "写入锁仍被占用")")
    }

    static func controlProcessesStopped() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "^/Library/PrivilegedHelperTools/local[.]hx10[.]coolmac[.]helper (--daemon|--worker|--recover-worker)$"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw HardwareError("无法确认旧后台和硬件进程已退出（pgrep \(process.terminationStatus)）")
        }
        return process.terminationStatus == 1
    }

    static func uninstall(onlyIfAppMissing: Bool = false) throws {
        let appExists = { FileManager.default.fileExists(atPath: Guardian.appBundlePath) }
        if onlyIfAppMissing && appExists() { return }
        let paths = ["/Library/LaunchDaemons/\(Product.service).plist", Product.installToolPath, Product.helperPath, Product.manifestPath]
        let verifyFiles = {
            for path in paths { try verifyRemovalTarget(path) }
        }
        do {
            let removed = try SafeUninstall.run(
                verifyFiles: verifyFiles,
                stopAndRestore: stopAndRestore,
                shouldRemove: {
                    if onlyIfAppMissing && appExists() {
                        try installService()
                        return false
                    }
                    return true
                },
                removeFiles: {
                    for path in paths {
                        try verifyRemovalTarget(path)
                        if unlink(path) != 0 && errno != ENOENT { throw HardwareError("无法删除已验证的后台文件：\(path)") }
                    }
                },
                removeState: {
                    guard !hasState("armed") else { throw HardwareError("恢复日志仍存在，拒绝清理状态") }
                    for name in ["commissioned", "fault", "writer.lock"] { try removeState(name) }
                    guard rmdir(Product.stateDirectory) == 0 else { throw HardwareError("恢复目录不为空，未删除未知文件") }
                }
            )
            if removed { print("后台已卸载，风扇已确认恢复系统自动") }
        } catch {
            let note = "后台自动卸载未完成：\(error.localizedDescription)"
            Logger(subsystem: Product.bundleID, category: "lifecycle").error("\(note, privacy: .public)")
            do { try putState("fault", text: note) }
            catch { FileHandle.standardError.write(Data(("卸载错误日志保存失败：\(error.localizedDescription)\n").utf8)) }
            throw error
        }
    }

    private static func verifyRemovalTarget(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw HardwareError("无法检查卸载目标：\(path)") }
            return
        }
        try assertRootPath(path)
    }
}

enum SafeUninstall {
    static func run(
        verifyFiles: () throws -> Void,
        stopAndRestore: () throws -> Void,
        shouldRemove: () throws -> Bool,
        removeFiles: () throws -> Void,
        removeState: () throws -> Void
    ) throws -> Bool {
        try verifyFiles()
        try stopAndRestore()
        guard try shouldRemove() else { return false }
        try verifyFiles()
        try removeFiles()
        try removeState()
        return true
    }
}
