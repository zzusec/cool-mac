import Foundation
import Darwin
import CoolMacCore
import CoolMacHardware

let helperEncoder = JSONEncoder()
let helperDecoder = JSONDecoder()

func encodeLine<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    return data
}

func assertRootPath(_ path: String, executable: Bool = false) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o022 == 0,
          !executable || info.st_mode & 0o111 != 0 else {
        throw HardwareError("安装权限或文件类型不安全：\(path)")
    }
}

func verifyInstalledHelper() throws {
    guard geteuid() == 0 else { throw HardwareError("后台组件必须由系统管理员安装后运行") }
    let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    guard ownPath == Product.helperPath else { throw HardwareError("拒绝从非安装目录运行高权限组件") }
    try assertRootPath(Product.helperPath, executable: true)
    try assertRootPath(Product.manifestPath)
    for path in ["/Library/PrivilegedHelperTools", "/Library/Application Support/CoolMac"] {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o022 == 0 else {
            throw HardwareError("安装父目录权限不安全：\(path)")
        }
    }
}

func createStateDirectory() throws {
    let path = Product.stateDirectory
    var info = stat()
    if lstat(path, &info) != 0 {
        guard errno == ENOENT, mkdir(path, 0o700) == 0 else { throw HardwareError("无法建立恢复状态目录") }
    }
    guard lstat(path, &info) == 0, info.st_uid == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else {
        throw HardwareError("恢复目录权限不安全")
    }
}

func statePath(_ name: String) -> String { Product.stateDirectory + "/" + name }

func putState(_ name: String, text: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: statePath(name)), options: .atomic)
    guard chmod(statePath(name), 0o600) == 0 else { throw HardwareError("无法保护恢复状态权限") }
}

func removeState(_ name: String) throws {
    let path = statePath(name)
    if unlink(path) != 0 && errno != ENOENT { throw HardwareError("无法清除状态：\(name)") }
}

func hasState(_ name: String) -> Bool { FileManager.default.fileExists(atPath: statePath(name)) }

final class LineBuffer {
    private var data = Data()
    func append(_ chunk: Data) throws -> [Data] {
        data.append(chunk)
        guard data.count <= 131072 else { throw HardwareError("内部消息超出大小限制") }
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 10) {
            let line = data.prefix(upTo: newline)
            guard line.count <= 65536 else { throw HardwareError("内部消息超出大小限制") }
            if !line.isEmpty { lines.append(Data(line)) }
            data.removeSubrange(...newline)
        }
        return lines
    }
}
