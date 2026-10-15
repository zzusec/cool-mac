import CryptoKit
import Foundation
import Testing

@testable import CoolMacUpdates

@Suite("检查器")
struct UpdateCheckerTests {
    private func makeChecker(
        _ transport: FakeTransport,
        key: Curve25519.Signing.PrivateKey,
        manifestURL: URL = UpdateSource.manifestURL,
        bundleID: String = testBundleID
    ) -> UpdateChecker {
        UpdateChecker(
            transport: transport,
            manifestURL: manifestURL,
            bundleID: bundleID,
            publicKeyBase64: publicKeyBase64(key)
        )
    }

    private func routeSignedManifest(
        _ transport: FakeTransport,
        key: Curve25519.Signing.PrivateKey,
        manifestURL: URL = UpdateSource.manifestURL,
        payload: Data? = nil
    ) throws {
        let body = try payload ?? manifestPayload()
        transport.route(manifestURL, data: try signedEnvelope(payload: body, key: key))
    }

    @Test("有新版时返回清单")
    func returnsManifestWhenNewer() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeSignedManifest(transport, key: key)

        let manifest = try await makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)

        #expect(manifest?.version == "1.2.0")
        #expect(manifest?.build == 3)
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 1)
        #expect(transport.recordedCalls.first?.byteLimit == UpdateChecker.maximumManifestBytes)
    }

    @Test("build 相同时返回 nil")
    func returnsNilWhenBuildIsCurrent() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeSignedManifest(transport, key: key)

        let manifest = try await makeChecker(transport, key: key).check(currentVersion: "1.2.0", currentBuild: 3)

        #expect(manifest == nil)
    }

    @Test("版本与 build 都更高时才返回清单")
    func returnsNilOnDowngrade() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeSignedManifest(transport, key: key, payload: try manifestPayload(version: "1.1.0", build: 9))

        let manifest = try await makeChecker(transport, key: key).check(currentVersion: "1.2.0", currentBuild: 3)

        #expect(manifest == nil)
    }

    @Test("当前版本格式非法时报错而不是当作无新版")
    func malformedCurrentVersionThrows() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeSignedManifest(transport, key: key)

        let error = await captureUpdateError {
            _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.2.x", currentBuild: 3)
        }
        #expect(error == .invalidVersionFormat("1.2.x"), "实际 \(String(describing: error))")
    }

    @Test("清单地址不在 github.com 上时联网前即拒绝")
    func disallowedManifestURLRejectedBeforeFetch() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        let hostile = URL(string: "https://evil.example.com/update.json")!
        let insecure = URL(string: "http://github.com/update.json")!

        for url in [hostile, insecure] {
            let error = await captureUpdateError {
                _ = try await self.makeChecker(transport, key: key, manifestURL: url).check(currentVersion: "1.1.0", currentBuild: 2)
            }
            #expect(error == .disallowedURLHost(url.absoluteString), "实际 \(String(describing: error))")
        }
        #expect(transport.recordedCalls.isEmpty)
    }

    @Test("签名无效时报错")
    func invalidSignatureThrows() async throws {
        let key = makeKey()
        let other = makeKey()
        let transport = FakeTransport()
        transport.route(UpdateSource.manifestURL, data: try signedEnvelope(payload: try manifestPayload(), key: other))

        let error = await captureUpdateError {
            _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)
        }
        #expect(error == .invalidSignature, "实际 \(String(describing: error))")
    }

    @Test("bundleID 不匹配时报错")
    func bundleIDMismatchThrows() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeSignedManifest(transport, key: key, payload: try manifestPayload(bundleID: "com.example.other"))

        let error = await captureUpdateError {
            _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)
        }
        #expect(error == .bundleIDMismatch(expected: testBundleID, found: "com.example.other"), "实际 \(String(describing: error))")
    }

    @Test("可以按调用方指定的 bundleID 校验")
    func customBundleIDIsHonoured() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeSignedManifest(transport, key: key, payload: try manifestPayload(bundleID: "com.example.other"))

        let manifest = try await makeChecker(transport, key: key, bundleID: "com.example.other").check(currentVersion: "1.1.0", currentBuild: 2)

        #expect(manifest?.bundleID == "com.example.other")
    }

    @Test("HTTP 错误状态报下载失败")
    func httpFailureThrows() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        transport.route(UpdateSource.manifestURL, data: Data("{}".utf8), status: 404)

        let error = await captureUpdateError {
            _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)
        }
        guard case .downloadFailed = error else {
            Issue.record("期望 downloadFailed，实际 \(String(describing: error))")
            return
        }
    }

    @Test("传输层失败被分类为超时/取消/失败，UpdateError 原样传递")
    func transportFailuresAreClassified() async throws {
        let key = makeKey()
        let hostile = UpdateError.disallowedURLHost("https://evil.example.com/x")
        let cases: [(Error, UpdateError)] = [
            (URLError(.timedOut), .downloadTimedOut),
            (URLError(.cancelled), .downloadCancelled),
            (CancellationError(), .downloadCancelled),
            (URLError(.cannotConnectToHost), .downloadFailed("")),
            (hostile, hostile),
            (UpdateError.assetTooLarge(limit: 1, reported: 2), .assetTooLarge(limit: 1, reported: 2)),
        ]
        for (thrown, expected) in cases {
            let transport = FakeTransport()
            transport.route(UpdateSource.manifestURL, error: thrown)
            let error = await captureUpdateError {
                _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)
            }
            if case .downloadFailed = expected {
                guard case .downloadFailed = error else {
                    Issue.record("\(thrown) 应报 downloadFailed，实际 \(String(describing: error))")
                    continue
                }
            } else {
                #expect(error == expected, "\(thrown) 应为 \(expected)，实际 \(String(describing: error))")
            }
        }
    }

    @Test("清单超过体积上限时被拒")
    func oversizedManifestRejected() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        let oversized = Data(repeating: 0x7B, count: UpdateChecker.maximumManifestBytes + 1)
        transport.route(UpdateSource.manifestURL, data: try signedEnvelope(payload: oversized, key: key))

        let error = await captureUpdateError {
            _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)
        }
        guard case .assetTooLarge(let limit, let reported) = error else {
            Issue.record("期望 assetTooLarge，实际 \(String(describing: error))")
            return
        }
        #expect(limit == UpdateChecker.maximumManifestBytes)
        #expect(reported > limit, "实际 \(reported)")
    }

    @Test("被篡改的清单不会返回")
    func tamperedManifestIsRejected() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        let payload = try manifestPayload()
        let envelope = try envelopeJSON(
            payload: tampered(payload).base64EncodedString(),
            signature: try key.signature(for: payload).base64EncodedString()
        )
        transport.route(UpdateSource.manifestURL, data: envelope)

        let error = await captureUpdateError {
            _ = try await self.makeChecker(transport, key: key).check(currentVersion: "1.1.0", currentBuild: 2)
        }
        #expect(error == .invalidSignature, "实际 \(String(describing: error))")
    }
}

@Suite("更新控制器：单飞与节流")
struct UpdateControllerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeController(
        _ transport: FakeTransport,
        key: Curve25519.Signing.PrivateKey,
        clock: MutableClock,
        minimumCheckInterval: Double = UpdateController.defaultMinimumCheckInterval
    ) -> UpdateController {
        UpdateController(
            transport: transport,
            manifestURL: UpdateSource.manifestURL,
            bundleID: testBundleID,
            publicKeyBase64: publicKeyBase64(key),
            minimumCheckInterval: minimumCheckInterval,
            now: { clock.now }
        )
    }

    private func routeAll(_ transport: FakeTransport, key: Curve25519.Signing.PrivateKey, payload: Data? = nil) throws {
        let body = try payload ?? manifestPayload()
        transport.route(UpdateSource.manifestURL, data: try signedEnvelope(payload: body, key: key))
        transport.route(URL(string: testAssetURLString)!, data: testAsset)
    }

    @Test("并发调用只触发一次检查与下载")
    func concurrentCallsRunOnce() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        transport.setDelay(0.2)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        async let first = controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        async let second = controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        async let third = controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        let results = try await [first, second, third]

        #expect(transport.callCount(for: UpdateSource.manifestURL) == 1, "清单只应被拉取一次")
        #expect(transport.callCount(for: URL(string: testAssetURLString)!) == 1, "资产只应被下载一次")
        for result in results {
            #expect(result?.version == "1.2.0")
        }
        #expect(directoryContents(directory) == ["CoolMac-1.2.0-3.pkg"])
    }

    @Test("并发调用拿到的是同一份清单")
    func concurrentCallsShareTheSameResult() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        transport.setDelay(0.1)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        async let first = controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        async let second = controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(a != nil)
    }

    @Test("节流窗口内不再发起检查")
    func throttlesWithinWindow() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        let second = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)

        #expect(first?.version == "1.2.0")
        #expect(second == nil, "节流窗口内应返回 nil")
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 1)
        #expect(transport.callCount(for: URL(string: testAssetURLString)!) == 1)

        let next = await controller.nextCheckDate()
        let lastAttempt = await controller.lastAttemptDate()
        #expect(next == start.addingTimeInterval(UpdateController.defaultMinimumCheckInterval))
        #expect(lastAttempt == start)
    }

    @Test("超过最小间隔后重新检查")
    func checksAgainAfterInterval() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        clock.advance(UpdateController.defaultMinimumCheckInterval - 1)
        let throttled = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        #expect(throttled == nil)
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 1)

        clock.advance(2)
        let after = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        #expect(after?.version == "1.2.0")
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 2)
    }

    @Test("可注入的间隔为 0 时不节流")
    func zeroIntervalDoesNotThrottle() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock, minimumCheckInterval: 0)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)

        #expect(transport.callCount(for: UpdateSource.manifestURL) == 2)
    }

    @Test("force 跳过节流但不跳过单飞")
    func forceBypassesThrottle() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        let throttled = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        #expect(throttled == nil)

        let forced = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory, force: true)
        #expect(forced?.version == "1.2.0")
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 2)
    }

    @Test("无新版时返回 nil 且不下载")
    func noUpdateReturnsNilWithoutDownloading() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try await controller.checkAndDownload(currentVersion: "1.2.0", currentBuild: 3, into: directory)

        #expect(manifest == nil)
        #expect(transport.callCount(for: URL(string: testAssetURLString)!) == 0)
        #expect(directoryContents(directory).isEmpty)
    }

    @Test("有新版时文件已通过校验并落在目标目录")
    func updateIsDownloadedAndVerified() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)

        let url = try #require(manifest).assetURL
        #expect(url.absoluteString == testAssetURLString)
        let written = try Data(contentsOf: directory.appendingPathComponent("CoolMac-1.2.0-3.pkg"))
        #expect(written == testAsset)
    }

    @Test("摘要不符时抛错、不留文件，且失败后仍可重试")
    func downloadFailurePropagatesAndRetries() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        transport.route(URL(string: testAssetURLString)!, data: Data(repeating: 0x41, count: testAsset.count))
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock, minimumCheckInterval: 60)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let error = await captureUpdateError {
            _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        }
        guard case .digestMismatch = error else {
            Issue.record("期望 digestMismatch，实际 \(String(describing: error))")
            return
        }
        #expect(directoryContents(directory).isEmpty)
        #expect(await controller.isChecking() == false)

        clock.advance(120)
        transport.route(URL(string: testAssetURLString)!, data: testAsset)
        let retried = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        #expect(retried?.version == "1.2.0")
        #expect(directoryContents(directory) == ["CoolMac-1.2.0-3.pkg"])
    }

    @Test("失败后并发调用不会卡住后续检查")
    func failedRunReleasesTheSingleFlightSlot() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        transport.route(UpdateSource.manifestURL, data: try signedEnvelope(payload: try manifestPayload(), key: key))
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock, minimumCheckInterval: 0)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for _ in 0..<2 {
            let error = await captureUpdateError {
                _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
            }
            #expect(error != nil)
        }
        #expect(await controller.isChecking() == false)
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 2)
    }

    @Test("签名无效时抛错且不下载")
    func invalidSignatureThrowsWithoutDownloading() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        transport.route(UpdateSource.manifestURL, data: try signedEnvelope(payload: try manifestPayload(), key: makeKey()))
        transport.route(URL(string: testAssetURLString)!, data: testAsset)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let error = await captureUpdateError {
            _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        }
        #expect(error == .invalidSignature, "实际 \(String(describing: error))")
        #expect(transport.callCount(for: URL(string: testAssetURLString)!) == 0)
        #expect(directoryContents(directory).isEmpty)
        #expect(transport.callCount(for: UpdateSource.manifestURL) == 1)
    }

    @Test("清单地址不合法时抛错且不发起任何请求")
    func disallowedManifestURLThrows() async throws {
        let transport = FakeTransport()
        let clock = MutableClock(start)
        let controller = UpdateController(
            transport: transport,
            manifestURL: URL(string: "https://evil.example.com/update.json")!,
            bundleID: testBundleID,
            publicKeyBase64: publicKeyBase64(makeKey()),
            minimumCheckInterval: 0,
            now: { clock.now }
        )
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let error = await captureUpdateError {
            _ = try await controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        }
        #expect(error == .disallowedURLHost("https://evil.example.com/update.json"), "实际 \(String(describing: error))")
        #expect(transport.recordedCalls.isEmpty)
    }

    @Test("调用方不会被阻塞：检查期间其他任务照常推进")
    func doesNotBlockTheCaller() async throws {
        let key = makeKey()
        let transport = FakeTransport()
        try routeAll(transport, key: key)
        transport.setDelay(0.2)
        let clock = MutableClock(start)
        let controller = makeController(transport, key: key, clock: clock)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = Date()
        async let check = controller.checkAndDownload(currentVersion: "1.1.0", currentBuild: 2, into: directory)
        try await Task.sleep(nanoseconds: 20_000_000)
        let elapsedWhileChecking = Date().timeIntervalSince(started)
        #expect(elapsedWhileChecking < 0.15, "检查期间调用方应能继续执行，实际耗时 \(elapsedWhileChecking)")
        _ = try await check
    }
}
