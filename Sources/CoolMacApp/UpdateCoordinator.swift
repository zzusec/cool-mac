import AppKit
import CoolMacCore
import CoolMacUpdates

/// Owns the update check/download/install lifecycle. It is deliberately separate
/// from the one-second fan poll so network work can never delay lease renewal.
@MainActor
final class UpdateCoordinator {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(Int)
        case ready(UpdateManifest)
        case installing
        case installed(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    var onChange: ((State) -> Void)?

    /// Appends one line to a user-readable trace so a failed update can be
    /// explained without root and without guessing.
    nonisolated static func trace(_ line: String) {
        let path = (Product.updateCacheDirectoryAbsolute as NSString).appendingPathComponent("update-trace.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    /// Called when a user-requested check finishes with a verified update.
    var onVerifiedUpdate: ((UpdateManifest) -> Void)?
    /// True only while the user has the update window open. A background check
    /// must never pop a window over the user's work.
    var presentsWindow = false

    var hasPendingUpdate: Bool {
        if case .ready = state { return true }
        return false
    }

    private let controller: UpdateController
    private let downloadDirectory: URL
    private var task: Task<Void, Never>?
    private var lastCheck: Date?
    private var verified: VerifiedUpdate?
    private static let interval: TimeInterval = 6 * 3600

    var automaticEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "automaticUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "automaticUpdates") }
    }

    init() {
        controller = UpdateController(transport: URLSessionUpdateTransport(), manifestURL: UpdateSource.manifestURL)
        downloadDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Product.updateCacheDirectory, isDirectory: true)
    }

    func present(_ newState: State) {
        state = newState
        onChange?(newState)
    }

    func checkIfDue() {
        guard automaticEnabled else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        lastCheck = Date()
        check(autoInstall: false)
    }

    func check(autoInstall: Bool) {
        guard task == nil else { return }
        // A background check may already have downloaded and verified an update.
        // When the user then asks for one, install what is already staged instead
        // of silently doing nothing.
        if autoInstall, case .ready = state, let verified {
            onVerifiedUpdate?(verified.manifest)
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            self.present(.checking)
            defer { self.task = nil }
            do {
                try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let result = try await controller.checkAndDownloadVerified(
                    currentVersion: Product.version,
                    currentBuild: Product.build,
                    into: downloadDirectory,
                    force: true,
                    progress: { [weak self] received, expected in
                        guard expected > 0 else { return }
                        let percent = min(100, Int((Double(received) / Double(expected)) * 100))
                        Task { @MainActor [weak self] in self?.presentDownloading(percent) }
                    }
                )
                guard let result else {
                    self.verified = nil
                    self.present(.upToDate)
                    return
                }
                self.verified = result
                self.present(.ready(result.manifest))
                // A check the user asked for goes straight on to install. A
                // background check only notifies; it never installs on its own.
                if autoInstall { self.onVerifiedUpdate?(result.manifest) }
            } catch is CancellationError {
                self.present(.idle)
            } catch {
                self.present(.failed(error.localizedDescription))
            }
        }
    }

    /// Coalesces progress callbacks so the UI is not rebuilt per chunk.
    private func presentDownloading(_ percent: Int) {
        if case .downloading(let previous) = state, previous == percent { return }
        present(.downloading(percent))
    }

    /// Copies the verified package and its exact signed envelope into the fixed
    /// cache location the privileged installer reads, keyed by a fresh UUID, and
    /// hands that UUID to `apply`. Only the locally generated identifier crosses
    /// the privilege boundary — never a path. The outcome is confirmed by waiting
    /// for the new version to appear on disk, because the install replaces the
    /// running background service and the connection with it.
    func install(_ manifest: UpdateManifest, apply: @escaping @Sendable (UUID) async throws -> Void) {
        guard case .ready = state, let verified else { return }
        task = Task { [weak self] in
            guard let self else { return }
            self.present(.installing)
            defer { self.task = nil }
            // Canonical lowercase, matching what the protocol accepts.
            let identifier = UUID()
            do {
                let manager = FileManager.default
                let directory = URL(fileURLWithPath: Product.updateCacheDirectoryAbsolute, isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = directory.appendingPathComponent("\(identifier.uuidString).pkg")
                let envelope = directory.appendingPathComponent("\(identifier.uuidString).json")
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.copyItem(at: verified.packageURL, to: destination)
                try verified.envelope.write(to: envelope, options: .atomic)
                Self.trace("staged \(identifier) for \(manifest.version)；开始调用安装")
                try await apply(identifier)
                Self.trace("安装调用已返回；等待磁盘版本变为 \(manifest.version)")
                if await self.waitForInstalledVersion(manifest.version) {
                    self.present(.installed(manifest.version))
                } else {
                    self.present(.failed("安装未完成：磁盘上仍是旧版本。后台输出：\(Self.installerOutput(identifier))"))
                }
            } catch {
                Self.trace("安装失败：\(error.localizedDescription)")
                self.present(.failed(error.localizedDescription))
            }
        }
    }

    /// Tail of the installer's own output, so a failed update explains itself
    /// without needing root or a terminal.
    nonisolated static func installerOutput(_ identifier: UUID) -> String {
        let path = (Product.updateCacheDirectoryAbsolute as NSString)
            .appendingPathComponent("\(identifier.uuidString.lowercased()).log")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "（没有安装日志）"
        }
        let lines = text.split(separator: "\n").suffix(3).joined(separator: " / ")
        return lines.isEmpty ? "（安装日志为空）" : lines
    }

    /// Polls the installed bundle until it reports `version`, or the deadline
    /// passes. The install replaces the background service, so this is the only
    /// reliable confirmation that it actually landed.
    private func waitForInstalledVersion(_ version: String, timeout: Double = 300) async -> Bool {
        let bundle = URL(fileURLWithPath: "/Applications/\(Product.name).app")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let installed = Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String,
               installed == version {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
