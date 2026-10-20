import CryptoKit
import Darwin
import Foundation

struct InstallError: Error, CustomStringConvertible {
    let description: String

    init(_ message: String) {
        description = message
    }
}

/// 文件与目录检查：一律用 lstat/open(O_NOFOLLOW) 判定，拒绝符号链接、硬链接、
/// 非预期属主和可被非属主写入的目标。
enum InstallFileGuard {
    static func info(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw InstallError("无法读取 \(path)：\(String(cString: strerror(errno)))")
        }
        return value
    }

    static func infoIfPresent(_ path: String) throws -> stat? {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw InstallError("无法读取 \(path)：\(String(cString: strerror(errno)))")
        }
        return value
    }

    /// 逐段检查绝对路径：每段都必须是真实目录（拒绝符号链接），且不可由非属主写入。
    static func requireDirectoryChain(_ path: String, finalOwner: uid_t) throws {
        guard path.hasPrefix("/") else {
            throw InstallError("路径必须是绝对路径：\(path)")
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw InstallError("路径为空：\(path)")
        }
        var current = ""
        for (index, component) in components.enumerated() {
            current += "/" + component
            let value = try info(current)
            guard (value.st_mode & S_IFMT) == S_IFDIR else {
                throw InstallError("路径组件不是普通目录（拒绝符号链接）：\(current)")
            }
            guard (value.st_mode & 0o022) == 0 else {
                throw InstallError("路径组件允许非属主写入：\(current)")
            }
            if index == components.count - 1, value.st_uid != finalOwner {
                throw InstallError("目录不属于 UID \(finalOwner)：\(current)（本机专用路径）")
            }
        }
    }

    private static func requireSafeRegularFile(
        _ value: stat,
        path: String,
        what: String,
        owner: uid_t,
        maximumBytes: Int
    ) throws {
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw InstallError("\(what)不是普通文件（拒绝目录或符号链接）：\(path)")
        }
        guard value.st_nlink == 1 else {
            throw InstallError("\(what)硬链接数不为 1：\(path)")
        }
        guard value.st_uid == owner else {
            throw InstallError("\(what)不属于预期属主（期望 UID \(owner)，实际 \(value.st_uid)）：\(path)")
        }
        guard (value.st_mode & 0o022) == 0 else {
            throw InstallError("\(what)允许非属主写入：\(path)")
        }
        guard value.st_size > 0, value.st_size <= Int64(maximumBytes) else {
            throw InstallError("\(what)大小不合法（\(value.st_size) 字节）：\(path)")
        }
    }

    /// 打开并检查一个受信来源的普通文件（不跟随符号链接）。
    private static func openSafe(
        _ path: String,
        what: String,
        owner: uid_t,
        maximumBytes: Int
    ) throws -> (descriptor: Int32, info: stat) {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InstallError("无法打开\(what)：\(path)：\(String(cString: strerror(errno)))")
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw InstallError("无法检查\(what)：\(path)：\(message)")
        }
        do {
            try requireSafeRegularFile(value, path: path, what: what, owner: owner, maximumBytes: maximumBytes)
        } catch {
            close(descriptor)
            throw error
        }
        return (descriptor, value)
    }

    static func readRegularFile(
        _ path: String,
        owner: uid_t,
        maximumBytes: Int,
        what: String
    ) throws -> Data {
        let (descriptor, value) = try openSafe(path, what: what, owner: owner, maximumBytes: maximumBytes)
        defer { close(descriptor) }
        var data = Data()
        data.reserveCapacity(Int(value.st_size))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw InstallError("读取\(what)失败：\(path)：\(String(cString: strerror(errno)))")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count == Int(value.st_size) else {
            throw InstallError("\(what)读取长度与文件大小不一致：\(path)")
        }
        return data
    }

    static func digest(
        _ path: String,
        owner: uid_t,
        maximumBytes: Int,
        what: String
    ) throws -> (bytes: Int, sha256: String) {
        let (descriptor, value) = try openSafe(path, what: what, owner: owner, maximumBytes: maximumBytes)
        defer { close(descriptor) }
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw InstallError("读取\(what)失败：\(path)：\(String(cString: strerror(errno)))")
            }
            hasher.update(data: Data(buffer[0..<count]))
            total += count
        }
        guard total == Int(value.st_size) else {
            throw InstallError("\(what)读取长度与文件大小不一致：\(path)")
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// 复制到新建的 root 私有目标文件（O_EXCL，权限 0600），并 fsync。
    static func copyRegularFile(
        from source: String,
        to destination: String,
        owner: uid_t,
        maximumBytes: Int,
        what: String
    ) throws {
        let (sourceDescriptor, sourceInfo) = try openSafe(
            source,
            what: what,
            owner: owner,
            maximumBytes: maximumBytes
        )
        defer { close(sourceDescriptor) }
        let destinationDescriptor = open(
            destination,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard destinationDescriptor >= 0 else {
            throw InstallError("无法创建暂存文件 \(destination)：\(String(cString: strerror(errno)))")
        }
        defer { close(destinationDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var total = 0
        while true {
            let count = read(sourceDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw InstallError("读取\(what)失败：\(source)：\(String(cString: strerror(errno)))")
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { pointer -> Int in
                    write(destinationDescriptor, pointer.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw InstallError("写入暂存文件失败：\(destination)：\(String(cString: strerror(errno)))")
                }
                guard written > 0 else {
                    throw InstallError("写入暂存文件未推进：\(destination)")
                }
                offset += written
            }
            total += count
        }
        guard total == Int(sourceInfo.st_size) else {
            throw InstallError("暂存副本长度与来源不一致（\(total) / \(sourceInfo.st_size)）：\(destination)")
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw InstallError("暂存副本未落盘：\(destination)：\(String(cString: strerror(errno)))")
        }
    }

    /// 暂存根目录（/var/db/CoolMac）：必须是 root 拥有、非属主不可写；缺失时按 0700 创建。
    static func requireStagingRoot(_ path: String) throws {
        if let existing = try infoIfPresent(path) {
            guard (existing.st_mode & S_IFMT) == S_IFDIR, existing.st_uid == 0, (existing.st_mode & 0o022) == 0 else {
                throw InstallError("暂存根目录不安全（要求 root 拥有的普通目录且不可由非 root 写入）：\(path)")
            }
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let parentInfo = try info(parent)
        guard (parentInfo.st_mode & S_IFMT) == S_IFDIR, parentInfo.st_uid == 0, (parentInfo.st_mode & 0o022) == 0 else {
            throw InstallError("暂存根目录的父目录不安全：\(parent)")
        }
        guard mkdir(path, 0o700) == 0 else {
            throw InstallError("无法创建暂存根目录 \(path)：\(String(cString: strerror(errno)))")
        }
        let created = try info(path)
        guard (created.st_mode & S_IFMT) == S_IFDIR, created.st_uid == 0, (created.st_mode & 0o777) == 0o700 else {
            throw InstallError("暂存根目录创建后权限不符（期望 root:0700）：\(path)")
        }
    }

    /// 新建 root 私有暂存目录；已存在同名目录时先确认它是 root 拥有的普通目录再删除重建。
    static func createPrivateDirectory(_ path: String) throws {
        if let existing = try infoIfPresent(path) {
            guard (existing.st_mode & S_IFMT) == S_IFDIR, existing.st_uid == 0 else {
                throw InstallError("暂存路径已存在且不安全：\(path)")
            }
            removeStagingDirectory(path)
            guard try infoIfPresent(path) == nil else {
                throw InstallError("未能清理旧的暂存目录：\(path)")
            }
        }
        guard mkdir(path, 0o700) == 0 else {
            throw InstallError("无法创建暂存目录 \(path)：\(String(cString: strerror(errno)))")
        }
        let created = try info(path)
        guard (created.st_mode & S_IFMT) == S_IFDIR, created.st_uid == 0, (created.st_mode & 0o777) == 0o700 else {
            throw InstallError("暂存目录权限不符（期望 root:0700）：\(path)")
        }
    }

    /// 只删除本工具在固定暂存根目录下创建的 `staging-<uuid>` 目录。
    static func removeStagingDirectory(_ path: String) {
        let prefix = InstallConstants.stagingRoot + "/staging-"
        guard path.hasPrefix(prefix) else { return }
        guard let value = try? info(path), (value.st_mode & S_IFMT) == S_IFDIR, value.st_uid == 0 else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            FileHandle.standardError.write(Data((
                "CoolMacInstallTool: 警告：未能清理暂存目录 \(path)：\(error.localizedDescription)\n"
            ).utf8))
        }
    }
}
