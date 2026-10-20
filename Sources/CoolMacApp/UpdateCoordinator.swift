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
    private(set) var requiresInstallConfirmation = false
    var onChange: ((State) -> Void)?

    /// Appends one line to a user-readable trace so a failed update can be
    /// explained without root and without guessing.
    private func trace(_ line: String) {
        let path = downloadDirectory.appendingPathComponent("update-trace.log").path
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
    /// Delivers a verified update and whether it came from the automatic check.
    var onVerifiedUpdate: ((UpdateManifest, Bool) -> Void)?
    /// True only while the user has the update window open. A background check
    /// must never pop a window over the user's work.
    var presentsWindow = false

    var hasPendingUpdate: Bool {
        if case .ready = state { return true }
        return false
    }

    typealias Fetch = @Sendable (URL, @escaping @Sendable (Int, Int64) -> Void) async throws -> VerifiedUpdate?
    private let fetch: Fetch
    private let defaults: UserDefaults
    private let downloadDirectory: URL
    private var task: Task<Void, Never>?
    private var installing = false
    private var lastCheck: Date?
    private var verified: VerifiedUpdate?
    private static let interval: TimeInterval = 6 * 3600

    var automaticEnabled: Bool {
        get { defaults.object(forKey: "automaticUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticUpdates") }
    }

    init(defaults: UserDefaults = .standard, downloadDirectory: URL? = nil, fetch: Fetch? = nil) {
        self.defaults = defaults
        self.downloadDirectory = downloadDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Product.updateCacheDirectory, isDirectory: true)
        let controller = UpdateController(transport: URLSessionUpdateTransport(), manifestURL: UpdateSource.manifestURL)
        self.fetch = fetch ?? { directory, progress in
            try await controller.checkAndDownloadVerified(
                currentVersion: Product.version, currentBuild: Product.build,
                into: directory, force: true, progress: progress)
        }
    }

    var needsAttention: Bool {
        if case .failed = state { return true }
        return hasPendingUpdate
    }

    func present(_ newState: State) {
        state = newState
        onChange?(newState)
    }

    func checkIfDue() {
        guard automaticEnabled, task == nil, !installing else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        lastCheck = Date()
        check(autoInstall: true, automatic: true)
    }

    func check(autoInstall: Bool, automatic: Bool = false) {
        guard task == nil, !installing else { return }
        if autoInstall, case .ready = state, let verified {
            if !automatic || automaticEnabled { onVerifiedUpdate?(verified.manifest, automatic) }
            return
        }
        present(.checking)
        task = Task { [weak self] in
            guard let self else { return }
            var pending: UpdateManifest?
            do {
                try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let result = try await fetch(downloadDirectory, { [weak self] received, expected in
                    guard expected > 0 else { return }
                    let percent = min(100, Int((Double(received) / Double(expected)) * 100))
                    Task { @MainActor [weak self] in self?.presentDownloading(percent) }
                })
                self.verified = result
                if let result {
                    self.present(.ready(result.manifest))
                    pending = result.manifest
                } else {
                    self.present(.upToDate)
                }
            } catch is CancellationError {
                self.present(.idle)
            } catch {
                self.present(.failed(error.localizedDescription))
            }
            // Release the check before its callback can start the install.
            self.task = nil
            if let pending, autoInstall, !automatic || self.automaticEnabled {
                self.onVerifiedUpdate?(pending, automatic)
            }
        }
    }

    /// Coalesces progress callbacks so the UI is not rebuilt per chunk.
    private func presentDownloading(_ percent: Int) {
        switch state {
        case .checking, .downloading: break
        default: return
        }
        if case .downloading(let previous) = state, previous == percent { return }
        present(.downloading(percent))
    }

    /// Copies the verified package and its exact signed envelope into the fixed
    /// cache location the privileged installer reads, keyed by a fresh UUID, and
    /// hands that UUID to `apply`. Only the locally generated identifier crosses
    /// the privilege boundary — never a path. The outcome is confirmed by waiting
    /// for the new version to appear on disk, because the install replaces the
    /// running background service and the connection with it. Preparation and
    /// completion are awaited under the same install lock.
    func install(
        _ manifest: UpdateManifest,
        automatic: Bool = false,
        prepare: @MainActor () async throws -> Void,
        apply: @MainActor (UUID) async throws -> Void,
        confirm: (@MainActor (UUID, UpdateManifest) async -> Bool)? = nil
    ) async {
        guard task == nil, !installing, case .ready = state,
              let verified, verified.manifest == manifest else { return }
        guard !automatic || automaticEnabled else { return }
        installing = true
        present(.installing)
        defer { installing = false }
        let identifier = UUID()
        do {
            try await prepare()
            // A preference changed while restoring must still stop automatic installation.
            guard !automatic || automaticEnabled else { present(.ready(manifest)); return }
            let manager = FileManager.default
            let destination = downloadDirectory.appendingPathComponent("\(identifier.uuidString.lowercased()).pkg")
            let envelope = downloadDirectory.appendingPathComponent("\(identifier.uuidString.lowercased()).json")
            try manager.copyItem(at: verified.packageURL, to: destination)
            try verified.envelope.write(to: envelope, options: .atomic)
            trace("staged \(identifier) for \(manifest.version) build \(manifest.build)；开始调用安装")
            requiresInstallConfirmation = true
            try await apply(identifier)
            let completed: Bool
            if let confirm { completed = await confirm(identifier, manifest) }
            else { completed = await waitForInstalledVersion(manifest, identifier: identifier) }
            if completed {
                requiresInstallConfirmation = false
                present(.installed(manifest.version))
            }
            else { present(.failed("安装未完成：未确认完整安装结果。后台输出：\(Self.installerOutput(identifier))")) }
        } catch {
            trace("安装失败：\(error.localizedDescription)")
            present(.failed(error.localizedDescription))
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

    /// Version alone can appear before postinstall completes. Require both fresh
    /// metadata and the install tool's final success marker before relaunching.
    static func installationCompleted(bundle: URL, log: URL, manifest: UpdateManifest) -> Bool {
        guard AppInstallation.matches(at: bundle, version: manifest.version, build: manifest.build),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains {
            $0 == "安装完成：/Applications/\(Product.name).app 已更新到 \(manifest.version)（build \(manifest.build)）"
        }
    }

    private func waitForInstalledVersion(_ manifest: UpdateManifest, identifier: UUID, timeout: Double = 300) async -> Bool {
        let bundle = URL(fileURLWithPath: "/Applications/\(Product.name).app")
        let log = downloadDirectory.appendingPathComponent("\(identifier.uuidString.lowercased()).log")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.installationCompleted(bundle: bundle, log: log, manifest: manifest) { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
