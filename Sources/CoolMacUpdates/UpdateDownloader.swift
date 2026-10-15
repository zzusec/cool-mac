import Foundation

/// Downloads a verified manifest's asset into a caller-owned directory.
///
/// Guarantees: the file name is generated locally (never taken from the
/// manifest), only the given directory is written, symbolic links are refused,
/// the bytes must match the signed length and SHA-256, and nothing is left
/// behind when any check fails. The payload is written as inert data — it is
/// never executed, loaded or inspected as code.
public struct UpdateDownloader: Sendable {
    /// Ceiling this build will accept for a package, independent of what a
    /// manifest declares.
    public static let maximumAssetBytes = 512 * 1024 * 1024
    /// Local file extension for the downloaded package.
    public static let fileExtension = "pkg"
    public static let defaultTimeout: Double = 600

    private let transport: UpdateTransport
    private let timeout: Double

    public init(transport: UpdateTransport, timeout: Double = UpdateDownloader.defaultTimeout) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Downloads and verifies `manifest`'s asset, returning the file it wrote
    /// inside `directory`.
    public func download(_ manifest: UpdateManifest, into directory: URL) async throws -> URL {
        try UpdateSource.validateInitialHost(manifest.assetURL)
        guard manifest.assetBytes > 0 else {
            throw UpdateError.invalidManifestJSON("assetBytes 必须为正整数：\(manifest.assetBytes)")
        }
        guard manifest.assetBytes <= Self.maximumAssetBytes else {
            throw UpdateError.assetTooLarge(limit: Self.maximumAssetBytes, reported: manifest.assetBytes)
        }
        guard UpdateDigest.isLowercaseHex64(manifest.assetSHA256) else {
            throw UpdateError.invalidManifestJSON("assetSHA256 必须是 64 位小写十六进制：\(manifest.assetSHA256)")
        }

        let fileManager = FileManager.default
        try validateDirectory(directory, fileManager: fileManager)
        let destination = directory.appendingPathComponent(Self.fileName(for: manifest))
        if isSymbolicLink(destination) {
            throw UpdateError.unsafeDestination("目标文件是符号链接：\(destination.path)")
        }

        let temporary = directory.appendingPathComponent(".coolmac-update-\(UUID().uuidString).partial")

        let data: Data
        do {
            let (payload, response) = try await transport.data(
                from: manifest.assetURL,
                byteLimit: manifest.assetBytes,
                timeout: timeout
            )
            try UpdateHTTP.validate(response)
            data = payload
        } catch {
            throw UpdateError.classify(error)
        }

        // Check the payload in memory first, so a bad package never reaches disk.
        if data.count > manifest.assetBytes {
            throw UpdateError.assetTooLarge(limit: manifest.assetBytes, reported: data.count)
        }
        try verify(bytes: data.count, digest: UpdateDigest.sha256Hex(data), against: manifest)

        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
        } catch {
            // A half-written file is still a file; do not leave it behind.
            remove(temporary)
            throw UpdateError.downloadFailed("写入临时文件失败：\(temporary.path)：\(error)")
        }

        // Re-check what actually landed on disk before publishing the file name.
        do {
            let written = try UpdateDigest.sha256Hex(contentsOf: temporary)
            try verify(bytes: written.bytes, digest: written.digest, against: manifest)
        } catch {
            remove(temporary)
            throw error
        }

        if rename(temporary.path, destination.path) != 0 {
            let reason = String(cString: strerror(errno))
            remove(temporary)
            throw UpdateError.downloadFailed("落盘失败：\(destination.path)：\(reason)")
        }
        return destination
    }

    /// Local, deterministic name: `CoolMac-<version>-<build>.pkg`. The version is
    /// re-serialized from its parsed numeric segments, so no manifest value can
    /// steer the path, introduce a separator or a `..` component.
    static func fileName(for manifest: UpdateManifest) -> String {
        let version = (try? UpdateVersion.parse(manifest.version))
            .map { $0.map(String.init).joined(separator: ".") } ?? "0"
        return "CoolMac-\(version)-\(manifest.build).\(UpdateDownloader.fileExtension)"
    }

    private func verify(bytes: Int, digest: String, against manifest: UpdateManifest) throws {
        guard bytes == manifest.assetBytes else {
            throw UpdateError.byteCountMismatch(expected: manifest.assetBytes, actual: bytes)
        }
        guard digest == manifest.assetSHA256.lowercased() else {
            throw UpdateError.digestMismatch(expected: manifest.assetSHA256, actual: digest)
        }
    }

    private func validateDirectory(_ directory: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UpdateError.unsafeDestination("下载目录不存在或不是目录：\(directory.path)")
        }
        if isSymbolicLink(directory) {
            throw UpdateError.unsafeDestination("下载目录是符号链接：\(directory.path)")
        }
    }

    /// Uses `lstat`, so a link is reported as a link rather than followed. A
    /// dangling link is caught too, because it is never followed either.
    private func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
