import CryptoKit
import Foundation
import Testing
@testable import CoolMacUpdates

/// A transport that reports progress chunk by chunk, standing in for a real
/// URLSession download so the plumbing can be checked without a network.
private struct ChunkedTransport: UpdateTransport {
    let payload: Data
    let expected: Int64

    func data(from url: URL, byteLimit: Int, timeout: Double) async throws -> (Data, URLResponse) {
        (payload, response(url: url))
    }

    func download(
        from url: URL,
        byteLimit: Int,
        timeout: Double,
        progress: @escaping @Sendable (Int, Int64) -> Void
    ) async throws -> (Data, URLResponse) {
        progress(0, expected)
        var sent = 0
        for chunk in stride(from: 0, to: payload.count, by: 4) {
            let end = min(chunk + 4, payload.count)
            sent += end - chunk
            progress(sent, expected)
            try await Task.sleep(nanoseconds: 200_000)
        }
        return (payload, response(url: url))
    }

    private func response(url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

/// A transport that only implements `data`, to prove the protocol's default
/// `download` still reports the start and the end.
private struct PlainTransport: UpdateTransport {
    let payload: Data

    func data(from url: URL, byteLimit: Int, timeout: Double) async throws -> (Data, URLResponse) {
        (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func manifest(for payload: Data, url: URL) -> UpdateManifest {
    UpdateManifest(
        bundleID: "local.hx10.coolmac",
        version: "9.9.9",
        build: 99,
        minimumSystemVersion: "14.0",
        architectures: ["arm64"],
        assetURL: url,
        assetBytes: payload.count,
        assetSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
        notes: ""
    )
}

@Test func chunkedProgressIsForwardedWithTheAnnouncedLength() async throws {
    let payload = Data(repeating: 0x41, count: 64)
    let url = URL(string: "https://github.com/zzusec/cool-mac/releases/download/v9/CoolMac.pkg")!
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("coolmac-progress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = Recorder()
    _ = try await UpdateDownloader(transport: ChunkedTransport(payload: payload, expected: 64))
        .download(manifest(for: payload, url: url), into: directory) { received, expected in
            recorder.record(received: received, expected: expected)
        }

    let samples = recorder.samples
    #expect(samples.count >= 4)
    #expect(samples.allSatisfy { $0.expected == 64 })
    #expect(samples.map(\.received) == samples.map(\.received).sorted())
    #expect(samples.last?.received == 64)
}

@Test func defaultImplementationStillReportsStartAndEnd() async throws {
    let payload = Data(repeating: 0x42, count: 32)
    let url = URL(string: "https://github.com/zzusec/cool-mac/releases/download/v9/CoolMac.pkg")!
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("coolmac-progress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recorder = Recorder()
    _ = try await UpdateDownloader(transport: PlainTransport(payload: payload))
        .download(manifest(for: payload, url: url), into: directory) { received, expected in
            recorder.record(received: received, expected: expected)
        }

    let samples = recorder.samples
    #expect(samples.first?.received == 0)
    #expect(samples.last?.received == payload.count)
}

/// Progress callbacks arrive off the main thread, so the record is locked.
private final class Recorder: @unchecked Sendable {
    struct Sample { let received: Int; let expected: Int64 }
    private let lock = NSLock()
    private var storage: [Sample] = []

    func record(received: Int, expected: Int64) {
        lock.lock(); defer { lock.unlock() }
        storage.append(Sample(received: received, expected: expected))
    }

    var samples: [Sample] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
