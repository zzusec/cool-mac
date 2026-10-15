import CryptoKit
import Foundation

/// `gh` 调用：固定路径、固定仓库、显式文件参数，绝不经过 shell，也绝不递归上传目录。
enum ReleasePublish {
    static let ghPath = "/opt/homebrew/bin/gh"

    /// Homebrew installs `gh` as a symlink into the Cellar, so the fixed path is
    /// resolved to its real target before the regular-file check. The real file
    /// must still be a single-link regular executable — never a directory or a
    /// dangling link.
    static func resolvedGHPath() throws -> String {
        let resolved = URL(fileURLWithPath: ghPath).resolvingSymlinksInPath().path
        try ReleaseFile.requireExecutableFile(resolved, what: "gh")
        return resolved
    }

    struct Asset {
        let path: String
        let bytes: Int
        let sha256: String

        var display: String {
            "\(ReleaseFile.basename(path))（\(bytes) 字节，sha256 \(sha256)）\n      \(path)"
        }
    }

    static func asset(_ path: String, what: String, suffix: String) throws -> Asset {
        try ReleaseFile.requireRegularFile(path, what: what)
        guard ReleaseFile.basename(path).hasSuffix(suffix) else {
            throw ReleaseError("\(what)必须是 \(suffix) 文件，拒绝上传其他内容：\(path)")
        }
        let digest = try ReleaseFile.digest(path)
        return Asset(path: path, bytes: digest.bytes, sha256: digest.sha256)
    }

    static func run(version: String, notes: String, assets: [Asset]) throws {
        let executable = try resolvedGHPath()
        let tag = "v\(version)"
        var arguments = [
            "release", "create", tag,
            "--repo", ReleaseManifest.repository,
            "--title", "\(ReleaseManifest.productName) \(version)",
            "--notes", notes,
        ]
        arguments.append(contentsOf: assets.map(\.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ReleaseError("无法启动 \(executable)：\(error.localizedDescription)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(Data(text.utf8))
            throw ReleaseError("gh release create 失败（退出码 \(process.terminationStatus)）")
        }
        if !text.isEmpty { ReleaseOutput.note(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        ReleaseOutput.note("已创建 Release \(tag)：\(ReleaseManifest.repository)")
    }
}
