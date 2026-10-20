import CryptoKit
import Darwin
import Foundation

/// 发布工具的错误。所有失败都必须能定位到具体检查，不允许静默降级。
struct ReleaseError: Error, CustomStringConvertible {
    let description: String

    init(_ message: String) {
        description = message
    }
}

enum ReleaseOutput {
    static func note(_ message: String) {
        print(message)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("错误：\(message)\n").utf8))
        exit(1)
    }
}

/// 极简参数解析：只接受显式声明的 `--键 值` 与 `--开关`，拒绝未知参数、重复参数和空值。
struct ReleaseArguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], valueKeys: Set<String>, flagKeys: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("--"), token.count > 2 else {
                throw ReleaseError("无法识别的参数：\(token)")
            }
            let key = String(token.dropFirst(2))
            if flagKeys.contains(key) {
                guard flags.insert(key).inserted else { throw ReleaseError("\(token) 重复出现") }
                continue
            }
            guard valueKeys.contains(key) else { throw ReleaseError("无法识别的参数：\(token)") }
            guard index < arguments.count else { throw ReleaseError("\(token) 缺少取值") }
            let value = arguments[index]
            index += 1
            guard !value.isEmpty else { throw ReleaseError("\(token) 的取值为空") }
            guard values.updateValue(value, forKey: key) == nil else { throw ReleaseError("\(token) 重复出现") }
        }
    }

    func value(_ key: String) -> String? { values[key] }

    func require(_ key: String) throws -> String {
        guard let value = values[key] else { throw ReleaseError("缺少必需参数 --\(key)") }
        return value
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

/// 只读的文件检查与摘要计算。拒绝目录、符号链接与多硬链接，避免把非预期内容当成发布资产。
enum ReleaseFile {
    static func info(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw ReleaseError("无法读取 \(path)：\(String(cString: strerror(errno)))")
        }
        return value
    }

    static func infoIfPresent(_ path: String) throws -> stat? {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw ReleaseError("无法读取 \(path)：\(String(cString: strerror(errno)))")
        }
        return value
    }

    static func requireRegularFile(_ path: String, what: String) throws {
        let value = try info(path)
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw ReleaseError("\(what)不是普通文件（拒绝目录或符号链接）：\(path)")
        }
        guard value.st_nlink == 1 else {
            throw ReleaseError("\(what)硬链接数不为 1：\(path)")
        }
        guard value.st_size > 0 else {
            throw ReleaseError("\(what)为空：\(path)")
        }
    }

    static func requireExecutableFile(_ path: String, what: String) throws {
        try requireRegularFile(path, what: what)
        guard access(path, X_OK) == 0 else {
            throw ReleaseError("\(what)不可执行：\(path)")
        }
    }

    /// 流式计算字节数与 SHA-256，不把大文件读进内存。
    static func digest(_ path: String) throws -> (bytes: Int, sha256: String) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw ReleaseError("无法打开 \(path)：\(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw ReleaseError("读取 \(path) 失败：\(error.localizedDescription)")
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += chunk.count
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func read(_ path: String, what: String) throws -> Data {
        try requireRegularFile(path, what: what)
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ReleaseError("读取\(what)失败：\(path)：\(error.localizedDescription)")
        }
    }

    /// 写出结果文件：拒绝覆盖符号链接或目录，写入采用原子替换。
    static func write(_ data: Data, to path: String) throws {
        if let existing = try infoIfPresent(path) {
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw ReleaseError("拒绝覆盖非普通文件：\(path)")
            }
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw ReleaseError("写入 \(path) 失败：\(error.localizedDescription)")
        }
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
