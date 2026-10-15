import Foundation
import Testing

@testable import CoolMacUpdates

@Suite("下载、校验与落盘")
struct UpdateDownloaderTests {
    private func transport(with asset: Data = testAsset) -> FakeTransport {
        let transport = FakeTransport()
        transport.route(URL(string: testAssetURLString)!, data: asset)
        return transport
    }

    private func download(
        _ manifest: UpdateManifest,
        using transport: FakeTransport,
        into directory: URL
    ) async -> Result<URL, UpdateError> {
        do {
            let url = try await UpdateDownloader(transport: transport).download(manifest, into: directory)
            return .success(url)
        } catch let error as UpdateError {
            return .failure(error)
        } catch {
            return .failure(.downloadFailed("非 UpdateError：\(error)"))
        }
    }

    @Test("校验通过时写入本地命名文件")
    func happyPathWritesVerifiedFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()

        let result = await download(makeManifest(), using: transport, into: directory)

        let url = try result.get()
        #expect(url.lastPathComponent == "CoolMac-1.2.0-3.pkg")
        #expect(url.deletingLastPathComponent().path == directory.path)
        let written = try Data(contentsOf: url)
        #expect(written == testAsset)
        #expect(directoryContents(directory) == ["CoolMac-1.2.0-3.pkg"])
        #expect(transport.callCount(for: URL(string: testAssetURLString)!) == 1)
        #expect(transport.recordedCalls.first?.byteLimit == testAsset.count)
    }

    @Test("文件名由本地生成，远端版本无法注入路径")
    func fileNameIsGeneratedLocally() {
        #expect(UpdateDownloader.fileName(for: makeManifest(version: "1.2.0", build: 3)) == "CoolMac-1.2.0-3.pkg")
        #expect(UpdateDownloader.fileName(for: makeManifest(version: "1.2", build: 3)) == "CoolMac-1.2-3.pkg")
        for hostile in ["../../etc/passwd", "..", "../..", "1.2.0/../../evil", "1.2.0 beta", "1.2.0\n3", ""] {
            let name = UpdateDownloader.fileName(for: makeManifest(version: hostile, build: 3))
            #expect(!name.contains("/"), "版本 \(hostile) 生成了含分隔符的文件名：\(name)")
            #expect(!name.contains(".."), "版本 \(hostile) 生成了含 .. 的文件名：\(name)")
            #expect(name.hasPrefix("CoolMac-") && name.hasSuffix("-3.pkg"))
        }
    }

    @Test("字节数不符时拒绝且不留下文件")
    func byteCountMismatchLeavesNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport(with: Data(repeating: 0x41, count: 10))

        let result = await download(makeManifest(assetBytes: 20), using: transport, into: directory)

        #expect(result.errorValue == .byteCountMismatch(expected: 20, actual: 10))
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("摘要不符时拒绝且不留下文件")
    func digestMismatchLeavesNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport(with: Data(repeating: 0x41, count: testAsset.count))

        let result = await download(makeManifest(), using: transport, into: directory)

        let error = try #require(result.errorValue)
        guard case .digestMismatch(let expected, let actual) = error else {
            Issue.record("期望 digestMismatch，实际 \(error)")
            return
        }
        #expect(expected == testAssetDigest())
        #expect(actual == UpdateDigest.sha256Hex(Data(repeating: 0x41, count: testAsset.count)))
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("声明体积超过本机上限时拒绝且不发起下载")
    func declaredSizeOverCeilingRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()

        let manifest = makeManifest(assetBytes: UpdateDownloader.maximumAssetBytes + 1)
        let result = await download(manifest, using: transport, into: directory)

        #expect(result.errorValue == .assetTooLarge(limit: UpdateDownloader.maximumAssetBytes, reported: UpdateDownloader.maximumAssetBytes + 1))
        #expect(transport.recordedCalls.isEmpty)
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("传输层无视上限返回超大内容时仍被拒绝")
    func oversizedPayloadRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeTransport()
        transport.setEnforcesByteLimit(false)
        transport.route(URL(string: testAssetURLString)!, data: Data(repeating: 0x41, count: 4096))

        let result = await download(makeManifest(assetBytes: 16, assetSHA256: UpdateDigest.sha256Hex(Data(repeating: 0x41, count: 4096))), using: transport, into: directory)

        #expect(result.errorValue == .assetTooLarge(limit: 16, reported: 4096))
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("传输层严格执行上限时把超限报为包过大")
    func transportEnforcedLimitReportsTooLarge() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeTransport()
        transport.route(URL(string: testAssetURLString)!, data: Data(repeating: 0x41, count: 4096))

        let result = await download(makeManifest(assetBytes: 16), using: transport, into: directory)

        #expect(result.errorValue == .assetTooLarge(limit: 16, reported: 4096))
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("超时、取消与一般网络错误分别报错")
    func transferFailuresAreClassified() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: testAssetURLString)!
        let cases: [(Error, UpdateError)] = [
            (URLError(.timedOut), .downloadTimedOut),
            (URLError(.cancelled), .downloadCancelled),
            (CancellationError(), .downloadCancelled),
            (UpdateError.downloadCancelled, .downloadCancelled),
            (URLError(.cannotConnectToHost), .downloadFailed("")),
        ]
        for (thrown, expected) in cases {
            let transport = FakeTransport()
            transport.route(url, error: thrown)
            let result = await download(makeManifest(), using: transport, into: directory)
            let error = try #require(result.errorValue)
            if case .downloadFailed = expected {
                guard case .downloadFailed = error else {
                    Issue.record("\(thrown) 应报 downloadFailed，实际 \(error)")
                    continue
                }
            } else {
                #expect(error == expected, "\(thrown) 应为 \(expected)，实际 \(error)")
            }
            #expect(directoryContents(directory).isEmpty)
        }
    }

    @Test("HTTP 非 2xx 报下载失败")
    func httpErrorStatusFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeTransport()
        transport.route(URL(string: testAssetURLString)!, data: testAsset, status: 500)

        let result = await download(makeManifest(), using: transport, into: directory)

        guard case .downloadFailed = try #require(result.errorValue) else {
            Issue.record("期望 downloadFailed，实际 \(String(describing: result.errorValue))")
            return
        }
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("非 github 主机与 http 地址在下载前被拒")
    func disallowedAssetURLRejectedBeforeFetch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport()

        for url in ["https://evil.example.com/CoolMac.pkg", "http://github.com/CoolMac.pkg", "https://objects.githubusercontent.com/CoolMac.pkg"] {
            let result = await download(makeManifest(assetURL: url), using: transport, into: directory)
            #expect(result.errorValue == .disallowedURLHost(url), "\(url) 应被拒，实际 \(String(describing: result.errorValue))")
        }
        #expect(transport.recordedCalls.isEmpty)
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("下载目录不存在时拒绝")
    func missingDirectoryRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("不存在")
        let transport = transport()

        let result = await download(makeManifest(), using: transport, into: missing)

        guard case .unsafeDestination = try #require(result.errorValue) else {
            Issue.record("期望 unsafeDestination，实际 \(String(describing: result.errorValue))")
            return
        }
        #expect(transport.recordedCalls.isEmpty)
    }

    @Test("下载目录本身是符号链接时拒绝")
    func symlinkedDirectoryRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let transport = transport()

        let result = await download(makeManifest(), using: transport, into: link)

        guard case .unsafeDestination = try #require(result.errorValue) else {
            Issue.record("期望 unsafeDestination，实际 \(String(describing: result.errorValue))")
            return
        }
        #expect(transport.recordedCalls.isEmpty)
        #expect(directoryContents(real).isEmpty)
    }

    @Test("目标文件是符号链接时拒绝且不触碰被指向的文件")
    func symlinkedDestinationRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let victim = directory.appendingPathComponent("victim.txt")
        try Data("重要内容".utf8).write(to: victim)
        let destination = directory.appendingPathComponent(UpdateDownloader.fileName(for: makeManifest()))
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)
        let transport = transport()

        let result = await download(makeManifest(), using: transport, into: directory)

        guard case .unsafeDestination = try #require(result.errorValue) else {
            Issue.record("期望 unsafeDestination，实际 \(String(describing: result.errorValue))")
            return
        }
        #expect(transport.recordedCalls.isEmpty, "符号链接应在发起下载前就被拒绝")
        let victimContents = try Data(contentsOf: victim)
        #expect(victimContents == Data("重要内容".utf8))
        #expect(directoryContents(directory) == ["victim.txt", "CoolMac-1.2.0-3.pkg"].sorted())
    }

    @Test("悬空符号链接同样被拒绝")
    func danglingSymlinkRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(UpdateDownloader.fileName(for: makeManifest()))
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: directory.appendingPathComponent("不存在").path)
        let transport = transport()

        let result = await download(makeManifest(), using: transport, into: directory)

        guard case .unsafeDestination = try #require(result.errorValue) else {
            Issue.record("期望 unsafeDestination，实际 \(String(describing: result.errorValue))")
            return
        }
        #expect(transport.recordedCalls.isEmpty)
    }

    @Test("覆盖已存在的普通文件是允许的")
    func existingRegularFileIsReplaced() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(UpdateDownloader.fileName(for: makeManifest()))
        try Data("旧的包内容".utf8).write(to: destination)
        let transport = transport()

        let result = await download(makeManifest(), using: transport, into: directory)

        let url = try result.get()
        let written = try Data(contentsOf: url)
        #expect(written == testAsset)
        #expect(directoryContents(directory) == ["CoolMac-1.2.0-3.pkg"])
    }

    @Test("失败后不留下临时文件")
    func temporaryFileRemovedOnFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = transport(with: Data(repeating: 0x41, count: 10))

        let result = await download(makeManifest(assetBytes: 20), using: transport, into: directory)

        #expect(result.errorValue != nil)
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("只写指定目录")
    func writesOnlyIntoGivenDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transport = transport()

        _ = await download(makeManifest(), using: transport, into: directory)

        #expect(directoryContents(root) == ["downloads"])
        #expect(directoryContents(directory) == ["CoolMac-1.2.0-3.pkg"])
    }

    @Test("下载内容不会被当作可执行文件执行")
    func payloadIsWrittenAsInertData() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = Data("#!/bin/sh\ntouch /tmp/should-not-exist\n".utf8)
        let transport = FakeTransport()
        transport.route(URL(string: testAssetURLString)!, data: script)
        let manifest = makeManifest(assetBytes: script.count, assetSHA256: UpdateDigest.sha256Hex(script))

        let result = await download(manifest, using: transport, into: directory)

        let url = try result.get()
        let written = try Data(contentsOf: url)
        #expect(written == script)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect((permissions?.intValue ?? 0) & 0o111 == 0, "下载的文件不应带可执行位")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/should-not-exist"))
    }
}

private extension Result where Success == URL, Failure == UpdateError {
    var errorValue: UpdateError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
