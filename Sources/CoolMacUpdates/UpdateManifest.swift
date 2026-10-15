import CryptoKit
import Foundation

/// The signed description of an available update.
///
/// Every field is attacker-controlled until `UpdateManifestVerifier` has checked
/// the envelope signature, so no value here may be trusted before that call.
public struct UpdateManifest: Sendable, Equatable, Codable {
    /// Schema version this build understands. Unknown schemas are refused.
    public static let currentSchema = 1

    public let schema: Int
    public let bundleID: String
    /// Dotted numeric version, compared segment by segment.
    public let version: String
    /// Monotonic build number. Must strictly increase.
    public let build: Int
    public let minimumSystemVersion: String
    public let architectures: [String]
    public let assetURL: URL
    public let assetBytes: Int
    /// Lowercase hex SHA-256 of the asset bytes.
    public let assetSHA256: String
    public let notes: String

    public init(
        schema: Int = UpdateManifest.currentSchema,
        bundleID: String,
        version: String,
        build: Int,
        minimumSystemVersion: String,
        architectures: [String],
        assetURL: URL,
        assetBytes: Int,
        assetSHA256: String,
        notes: String
    ) {
        self.schema = schema
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures
        self.assetURL = assetURL
        self.assetBytes = assetBytes
        self.assetSHA256 = assetSHA256
        self.notes = notes
    }
}

/// `update.json` as published: a base64 payload plus an Ed25519 signature over
/// the payload's decoded bytes.
struct UpdateEnvelope: Codable {
    let payload: String
    let signature: String
}

/// SHA-256 helpers shared by the verifier and the downloader.
enum UpdateDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isLowercaseHex64(_ text: String) -> Bool {
        guard text.count == 64 else { return false }
        return text.allSatisfy { character in
            character.isASCII && (character.isNumber || (character >= "a" && character <= "f"))
        }
    }

    /// Streams a file through SHA-256 without loading it into memory again.
    static func sha256Hex(contentsOf url: URL) throws -> (bytes: Int, digest: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += chunk.count
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
