import Foundation

/// Fetches and authenticates the published manifest, then decides whether it
/// offers something newer than what is running.
public struct UpdateChecker: Sendable {
    /// A manifest envelope is a few hundred bytes; anything larger is refused
    /// before it is parsed.
    public static let maximumManifestBytes = 256 * 1024
    public static let defaultTimeout: Double = 30

    private let transport: UpdateTransport
    private let manifestURL: URL
    private let bundleID: String
    private let publicKeyBase64: String
    private let timeout: Double

    public init(
        transport: UpdateTransport,
        manifestURL: URL,
        bundleID: String = UpdateSource.bundleID,
        publicKeyBase64: String = UpdatePublicKey.base64,
        timeout: Double = UpdateChecker.defaultTimeout
    ) {
        self.transport = transport
        self.manifestURL = manifestURL
        self.bundleID = bundleID
        self.publicKeyBase64 = publicKeyBase64
        self.timeout = timeout
    }

    /// Returns the verified manifest when it is a genuine upgrade, `nil` when the
    /// running build is already current or ahead. A malformed, unsigned or
    /// unsupported manifest throws.
    public func check(currentVersion: String, currentBuild: Int) async throws -> UpdateManifest? {
        try await checkVerified(currentVersion: currentVersion, currentBuild: currentBuild)?.manifest
    }

    /// As `check`, but keeps the exact signed envelope bytes so a privileged
    /// installer can re-verify the same payload the app already accepted.
    public func checkVerified(currentVersion: String, currentBuild: Int) async throws -> (manifest: UpdateManifest, envelope: Data)? {
        // Refuse a hostile source before opening a connection.
        try UpdateSource.validateInitialHost(manifestURL)

        let envelope: Data
        do {
            let (data, response) = try await transport.data(
                from: manifestURL,
                byteLimit: UpdateChecker.maximumManifestBytes,
                timeout: timeout
            )
            try UpdateHTTP.validate(response)
            envelope = data
        } catch {
            throw UpdateError.classify(error)
        }

        let manifest = try UpdateManifestVerifier.verify(
            envelope: envelope,
            publicKeyBase64: publicKeyBase64,
            bundleID: bundleID
        )

        do {
            _ = try UpdateVersion.isNewer(manifest: manifest, currentVersion: currentVersion, currentBuild: currentBuild)
        } catch {
            if let updateError = error as? UpdateError, updateError.isNotNewerThanCurrent { return nil }
            throw error
        }
        return (manifest, envelope)
    }
}
