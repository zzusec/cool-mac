import Foundation

/// A verified manifest together with the exact bytes that were signed and the
/// downloaded package. The install tool re-verifies the envelope, so the original
/// bytes — not a re-encoding — must be what gets persisted for it.
public struct VerifiedUpdate: Sendable {
    public let manifest: UpdateManifest
    public let envelope: Data
    public let packageURL: URL

    public init(manifest: UpdateManifest, envelope: Data, packageURL: URL) {
        self.manifest = manifest
        self.envelope = envelope
        self.packageURL = packageURL
    }
}

/// Runs at most one check-and-download at a time and throttles automatic checks.
///
/// Concurrency contract: while a check is in flight, every additional caller
/// joins that same run and receives its result — the transport is touched once.
/// Between two *attempts* there is a minimum interval; a call inside that window
/// returns `nil` immediately instead of starting another check. Nothing here
/// blocks a thread: callers await, and a throttled or joined call never starts a
/// second transfer.
public actor UpdateController {
    /// Minimum spacing between two automatic checks.
    public static let defaultMinimumCheckInterval: Double = 6 * 60 * 60

    private let transport: UpdateTransport
    private let manifestURL: URL
    private let bundleID: String
    private let publicKeyBase64: String
    private let minimumCheckInterval: Double
    private let now: @Sendable () -> Date

    private var inFlight: Task<VerifiedUpdate?, Error>?
    private var inFlightID: UUID?
    private var lastAttemptAt: Date?

    public init(
        transport: UpdateTransport,
        manifestURL: URL,
        bundleID: String = UpdateSource.bundleID,
        publicKeyBase64: String = UpdatePublicKey.base64,
        minimumCheckInterval: Double = UpdateController.defaultMinimumCheckInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.manifestURL = manifestURL
        self.bundleID = bundleID
        self.publicKeyBase64 = publicKeyBase64
        self.minimumCheckInterval = minimumCheckInterval
        self.now = now
    }

    /// Checks for an update and, when one exists, downloads and verifies it into
    /// `directory`.
    ///
    /// - Parameter force: set by an explicit user action ("check now"). It skips
    ///   the throttle window but never the single-flight rule.
    /// - Returns: the verified manifest once its package is on disk, or `nil`
    ///   when there is nothing to install — the running build is current or
    ///   ahead, or the call fell inside the throttle window (see
    ///   `nextCheckDate()`). Verification and download failures throw.
    public func checkAndDownload(
        currentVersion: String,
        currentBuild: Int,
        into directory: URL,
        force: Bool = false,
        progress: (@Sendable (Int, Int64) -> Void)? = nil
    ) async throws -> UpdateManifest? {
        try await checkAndDownloadVerified(
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            into: directory,
            force: force,
            progress: progress
        )?.manifest
    }

    /// As `checkAndDownload`, but also returns the signed envelope bytes and the
    /// downloaded package location so the caller can hand them to the privileged
    /// installer without ever re-encoding the signed payload.
    public func checkAndDownloadVerified(
        currentVersion: String,
        currentBuild: Int,
        into directory: URL,
        force: Bool = false,
        progress: (@Sendable (Int, Int64) -> Void)? = nil
    ) async throws -> VerifiedUpdate? {
        if let existing = inFlight {
            return try await existing.value
        }
        if !force, let last = lastAttemptAt, now().timeIntervalSince(last) < minimumCheckInterval {
            return nil
        }

        let transport = self.transport
        let manifestURL = self.manifestURL
        let bundleID = self.bundleID
        let publicKeyBase64 = self.publicKeyBase64
        let id = UUID()

        let task = Task<VerifiedUpdate?, Error> {
            let checker = UpdateChecker(transport: transport, manifestURL: manifestURL, bundleID: bundleID, publicKeyBase64: publicKeyBase64)
            guard let verified = try await checker.checkVerified(currentVersion: currentVersion, currentBuild: currentBuild) else {
                return nil
            }
            let downloader = UpdateDownloader(transport: transport)
            let packageURL = try await downloader.download(verified.manifest, into: directory, progress: progress)
            return VerifiedUpdate(manifest: verified.manifest, envelope: verified.envelope, packageURL: packageURL)
        }

        inFlight = task
        inFlightID = id
        lastAttemptAt = now()

        defer {
            if inFlightID == id {
                inFlight = nil
                inFlightID = nil
            }
        }
        return try await task.value
    }

    /// When the last attempt started, successful or not.
    public func lastAttemptDate() -> Date? { lastAttemptAt }

    /// When the next automatic check may start.
    public func nextCheckDate() -> Date? { lastAttemptAt.map { $0.addingTimeInterval(minimumCheckInterval) } }

    /// True while a check-and-download is running.
    public func isChecking() -> Bool { inFlight != nil }
}
