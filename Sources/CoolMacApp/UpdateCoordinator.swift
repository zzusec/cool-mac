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
        check()
    }

    func check() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            self.present(.checking)
            defer { self.task = nil }
            do {
                try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let result = try await controller.checkAndDownloadVerified(currentVersion: Product.version, currentBuild: Product.build, into: downloadDirectory, force: true)
                guard let result else {
                    self.verified = nil
                    self.present(.upToDate)
                    return
                }
                self.verified = result
                self.present(.ready(result.manifest))
            } catch is CancellationError {
                self.present(.idle)
            } catch {
                self.present(.failed(error.localizedDescription))
            }
        }
    }

    /// Copies the verified package and its exact signed envelope into the fixed
    /// cache location the privileged installer reads, keyed by a fresh UUID, and
    /// hands that UUID to `authorization`. Only the locally generated identifier
    /// crosses the privilege boundary — never a path.
    func install(_ manifest: UpdateManifest, authorization: @escaping @Sendable (UUID) async throws -> Void) {
        guard case .ready = state, let verified else { return }
        task = Task { [weak self] in
            guard let self else { return }
            self.present(.installing)
            defer { self.task = nil }
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
                try await authorization(identifier)
                self.present(.installed(manifest.version))
            } catch {
                self.present(.failed(error.localizedDescription))
            }
        }
    }
}
