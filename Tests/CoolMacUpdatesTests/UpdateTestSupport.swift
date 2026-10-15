import CryptoKit
import Foundation
import Testing

@testable import CoolMacUpdates

// Shared fixtures. Every test signs its own payload with a freshly generated
// Ed25519 key pair, so the suite never depends on the placeholder public key and
// never touches the network.

let testBundleID = "local.hx10.coolmac"
let testAssetURLString = "https://github.com/zzusec/cool-mac/releases/download/v1.2.0/CoolMac.pkg"
let testAsset = Data("CoolMac test package payload".utf8)

func testAssetDigest() -> String { UpdateDigest.sha256Hex(testAsset) }

func makeKey() -> Curve25519.Signing.PrivateKey { Curve25519.Signing.PrivateKey() }

func publicKeyBase64(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

/// Builds the UTF-8 JSON payload exactly as the release side would publish it.
func manifestPayload(
    schema: Int = 1,
    bundleID: String = testBundleID,
    version: String = "1.2.0",
    build: Int = 3,
    minimumSystemVersion: String = "14.0",
    architectures: [String] = ["arm64"],
    assetURL: String = testAssetURLString,
    assetBytes: Int = testAsset.count,
    assetSHA256: String = UpdateDigest.sha256Hex(testAsset),
    notes: String = "测试更新"
) throws -> Data {
    let object: [String: Any] = [
        "schema": schema,
        "bundleID": bundleID,
        "version": version,
        "build": build,
        "minimumSystemVersion": minimumSystemVersion,
        "architectures": architectures,
        "assetURL": assetURL,
        "assetBytes": assetBytes,
        "assetSHA256": assetSHA256,
        "notes": notes,
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// Drops a field from a payload, to exercise structurally invalid manifests.
func manifestPayloadWithout(_ field: String, version: String = "1.2.0") throws -> Data {
    var object = try JSONSerialization.jsonObject(with: manifestPayload(version: version)) as? [String: Any] ?? [:]
    object.removeValue(forKey: field)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func envelopeJSON(payload: String, signature: String) throws -> Data {
    let object: [String: String] = ["payload": payload, "signature": signature]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// The published `update.json`: base64 payload plus signature over the payload's
/// decoded bytes.
func signedEnvelope(payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
    try envelopeJSON(
        payload: payload.base64EncodedString(),
        signature: try key.signature(for: payload).base64EncodedString()
    )
}

/// Flips the last payload byte, leaving the signature untouched.
func tampered(_ data: Data) -> Data {
    var copy = data
    copy[copy.count - 1] = copy[copy.count - 1] ^ 0xFF
    return copy
}

func flipped(_ data: Data) -> Data {
    var copy = data
    copy[0] = copy[0] ^ 0xFF
    return copy
}

func makeManifest(
    schema: Int = 1,
    bundleID: String = testBundleID,
    version: String = "1.2.0",
    build: Int = 3,
    minimumSystemVersion: String = "14.0",
    architectures: [String] = ["arm64"],
    assetURL: String = testAssetURLString,
    assetBytes: Int = testAsset.count,
    assetSHA256: String = UpdateDigest.sha256Hex(testAsset),
    notes: String = "测试更新"
) -> UpdateManifest {
    UpdateManifest(
        schema: schema,
        bundleID: bundleID,
        version: version,
        build: build,
        minimumSystemVersion: minimumSystemVersion,
        architectures: architectures,
        assetURL: URL(string: assetURL)!,
        assetBytes: assetBytes,
        assetSHA256: assetSHA256,
        notes: notes
    )
}

func httpResponse(_ url: URL, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

// MARK: - Fake transport

/// Serves canned responses per URL and records every call. No sockets involved.
final class FakeTransport: UpdateTransport, @unchecked Sendable {
    struct Call: Sendable {
        let url: URL
        let byteLimit: Int
        let timeout: Double
    }

    private let lock = NSLock()
    private var routes: [String: Result<(Data, URLResponse), Error>] = [:]
    private var calls: [Call] = []
    private var delay: Double = 0
    private var enforcesByteLimit = true

    func route(_ url: URL, data: Data, status: Int = 200, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        routes[url.absoluteString] = .success((data, httpResponse(url, status: status, headers: headers)))
    }

    func route(_ url: URL, error: Error) {
        lock.lock(); defer { lock.unlock() }
        routes[url.absoluteString] = .failure(error)
    }

    /// Makes overlapping calls observable in single-flight tests.
    func setDelay(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        delay = seconds
    }

    /// When false the transport hands back oversized data, standing in for a
    /// transport that ignores its own limit.
    func setEnforcesByteLimit(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enforcesByteLimit = value
    }

    var recordedCalls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func callCount(for url: URL) -> Int {
        recordedCalls.filter { $0.url == url }.count
    }

    func data(from url: URL, byteLimit: Int, timeout: Double) async throws -> (Data, URLResponse) {
        let plan = record(url: url, byteLimit: byteLimit, timeout: timeout)
        if plan.pause > 0 {
            try await Task.sleep(nanoseconds: UInt64(plan.pause * 1_000_000_000))
        }
        switch plan.entry {
        case .success(let payload):
            if plan.strict && payload.0.count > byteLimit {
                throw UpdateError.assetTooLarge(limit: byteLimit, reported: payload.0.count)
            }
            return payload
        case .failure(let error):
            throw error
        case nil:
            throw URLError(.unsupportedURL)
        }
    }

    /// Locking happens here rather than in the async method, where `NSLock` is
    /// deliberately unavailable.
    private func record(url: URL, byteLimit: Int, timeout: Double) -> (entry: Result<(Data, URLResponse), Error>?, pause: Double, strict: Bool) {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(url: url, byteLimit: byteLimit, timeout: timeout))
        return (routes[url.absoluteString], delay, enforcesByteLimit)
    }
}

// MARK: - Clock

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Filesystem

func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("coolmac-updates-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func directoryContents(_ directory: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.sorted()
}

/// Runs `operation` and requires it to throw exactly `expected`.
func expectThrows(
    _ expected: UpdateError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("期望抛出 \(expected)，但调用成功返回", sourceLocation: sourceLocation)
    } catch let error as UpdateError {
        #expect(error == expected, "期望 \(expected)，实际 \(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("期望 UpdateError，实际抛出 \(error)", sourceLocation: sourceLocation)
    }
}

/// Requires `operation` to throw some `UpdateError`, and hands it back.
func captureUpdateError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> Void
) async -> UpdateError? {
    do {
        try await operation()
        Issue.record("期望抛出 UpdateError，但调用成功返回", sourceLocation: sourceLocation)
        return nil
    } catch let error as UpdateError {
        return error
    } catch {
        Issue.record("期望 UpdateError，实际抛出 \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Synchronous twin of `expectThrowsSync`'s async counterpart, for the
/// verifier's non-async API.
func expectThrowsSync(
    _ expected: UpdateError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("期望抛出 \(expected)，但调用成功返回", sourceLocation: sourceLocation)
    } catch let error as UpdateError {
        #expect(error == expected, "期望 \(expected)，实际 \(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("期望 UpdateError，实际抛出 \(error)", sourceLocation: sourceLocation)
    }
}

/// Synchronous twin of `captureUpdateError`.
func captureSync(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () throws -> Void
) -> UpdateError? {
    do {
        try operation()
        Issue.record("期望抛出 UpdateError，但调用成功返回", sourceLocation: sourceLocation)
        return nil
    } catch let error as UpdateError {
        return error
    } catch {
        Issue.record("期望 UpdateError，实际抛出 \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// True when the failure is the "structurally unusable manifest" family, whose
/// associated value carries a diagnostic string rather than a fixed constant.
func isInvalidManifestJSON(_ error: UpdateError?) -> Bool {
    guard let error else { return false }
    if case .invalidManifestJSON = error { return true }
    return false
}
