import CryptoKit
import Foundation

/// Authenticates `update.json` and then validates the signed payload.
///
/// Order matters and is deliberate: the signature is checked over the raw
/// payload bytes *before* any payload field is decoded or trusted. A payload
/// that fails any later check is reported as an error, never as an empty result.
public enum UpdateManifestVerifier {
    /// The architecture of the running process, as spelled in manifests.
    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// The running macOS version, as a dotted numeric string.
    public static var hostSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Verifies against this machine's architecture and OS version.
    public static func verify(envelope: Data, publicKeyBase64: String, bundleID: String) throws -> UpdateManifest {
        try verify(
            envelope: envelope,
            publicKeyBase64: publicKeyBase64,
            bundleID: bundleID,
            hostArchitecture: hostArchitecture,
            hostSystemVersion: hostSystemVersion
        )
    }

    /// Verifies against an explicitly supplied host, for tests and for callers
    /// that speak for another machine.
    public static func verify(
        envelope: Data,
        publicKeyBase64: String,
        bundleID: String,
        hostArchitecture: String,
        hostSystemVersion: String
    ) throws -> UpdateManifest {
        let (payload, signature) = try decodeEnvelope(envelope)
        let key = try decodePublicKey(publicKeyBase64)
        guard key.isValidSignature(signature, for: payload) else {
            throw UpdateError.invalidSignature
        }

        // Only past this point may payload content be read.
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: payload)
        } catch {
            throw UpdateError.invalidManifestJSON("payload 字段不完整或类型不符：\(error)")
        }

        guard manifest.schema == UpdateManifest.currentSchema else {
            throw UpdateError.unsupportedSchema(manifest.schema)
        }
        guard manifest.bundleID == bundleID else {
            throw UpdateError.bundleIDMismatch(expected: bundleID, found: manifest.bundleID)
        }
        guard manifest.architectures.contains(hostArchitecture) else {
            throw UpdateError.unsupportedArchitecture(hostArchitecture)
        }

        let required: [Int]
        do {
            required = try UpdateVersion.parse(manifest.minimumSystemVersion)
        } catch {
            throw UpdateError.invalidManifestJSON("minimumSystemVersion 格式非法：\(manifest.minimumSystemVersion)")
        }
        let running = try UpdateVersion.parse(hostSystemVersion)
        guard UpdateVersion.compare(running, required) >= 0 else {
            throw UpdateError.systemVersionTooOld(required: manifest.minimumSystemVersion, current: hostSystemVersion)
        }

        // Version, size and digest must be well formed before anyone acts on them.
        _ = try UpdateVersion.parse(manifest.version)
        guard manifest.build > 0 else {
            throw UpdateError.invalidManifestJSON("build 必须为正整数：\(manifest.build)")
        }
        guard manifest.assetBytes > 0 else {
            throw UpdateError.invalidManifestJSON("assetBytes 必须为正整数：\(manifest.assetBytes)")
        }
        guard UpdateDigest.isLowercaseHex64(manifest.assetSHA256) else {
            throw UpdateError.invalidManifestJSON("assetSHA256 必须是 64 位小写十六进制：\(manifest.assetSHA256)")
        }
        try UpdateSource.validateInitialHost(manifest.assetURL)

        return manifest
    }

    private static func decodeEnvelope(_ envelope: Data) throws -> (payload: Data, signature: Data) {
        let decoded: UpdateEnvelope
        do {
            decoded = try JSONDecoder().decode(UpdateEnvelope.self, from: envelope)
        } catch {
            throw UpdateError.invalidManifestJSON("信封不是 {\"payload\",\"signature\"} 形式的 JSON：\(error)")
        }
        guard let payload = Data(base64Encoded: decoded.payload) else {
            throw UpdateError.invalidManifestJSON("payload 不是合法 base64")
        }
        guard let signature = Data(base64Encoded: decoded.signature) else {
            throw UpdateError.invalidManifestJSON("signature 不是合法 base64")
        }
        return (payload, signature)
    }

    private static func decodePublicKey(_ base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: base64), raw.count == 32 else {
            throw UpdateError.invalidPublicKey
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw UpdateError.invalidPublicKey
        }
    }
}
