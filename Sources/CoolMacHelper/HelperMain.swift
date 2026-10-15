import Foundation
import Darwin
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

    static func launchctl(_ arguments: [String], allowMissing: Bool = false) throws {
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
                let recovery = try Worker(recoveryOnly: true)
                try recovery.run()
                guard !hasState("armed") else { throw HardwareError("自动恢复未确认，停止卸载/升级") }
                return
            } catch { lastError = error }
            usleep(100000)
        }
        throw HardwareError("后台尚未安全停止：\(lastError?.localizedDescription ?? "写入锁仍被占用")")
    }

    static func uninstall() throws {
        try stopAndRestore()
        for path in ["/Library/LaunchDaemons/\(Product.service).plist", Product.manifestPath] {
            try assertRootPath(path)
            try FileManager.default.removeItem(atPath: path)
        }
        for name in ["commissioned", "fault", "armed", "writer.lock"] { try removeState(name) }
        guard rmdir(Product.stateDirectory) == 0 else { throw HardwareError("恢复目录不为空，未删除未知文件") }
        try FileManager.default.removeItem(atPath: Product.helperPath)
        print("后台已卸载，风扇已确认恢复系统自动；应用可从 Applications 手动移除")
    }
}
