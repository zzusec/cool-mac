import Foundation
import Testing

@testable import CoolMacUpdates

@Suite("版本与 build 判定")
struct UpdateVersionTests {
    @Test("更高版本且更高 build 是更新")
    func newerVersionAndBuild() throws {
        #expect(try UpdateVersion.isNewer(manifest: makeManifest(version: "1.3.0", build: 4), currentVersion: "1.2.0", currentBuild: 3))
    }

    @Test("版本相同但 build 递增仍算更新")
    func sameVersionHigherBuild() throws {
        #expect(try UpdateVersion.isNewer(manifest: makeManifest(version: "1.2.0", build: 4), currentVersion: "1.2.0", currentBuild: 3))
    }

    @Test("build 相同被拒绝")
    func sameBuildRejected() throws {
        expectThrowsSync(.notNewerThanCurrent(currentVersion: "1.2.0", currentBuild: 3)) {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.3.0", build: 3), currentVersion: "1.2.0", currentBuild: 3)
        }
    }

    @Test("build 更低被拒绝")
    func lowerBuildRejected() throws {
        expectThrowsSync(.notNewerThanCurrent(currentVersion: "1.2.0", currentBuild: 3)) {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.3.0", build: 2), currentVersion: "1.2.0", currentBuild: 3)
        }
    }

    @Test("版本降级即使 build 更高也被拒绝")
    func downgradeRejectedEvenWithHigherBuild() throws {
        expectThrowsSync(.notNewerThanCurrent(currentVersion: "1.2.0", currentBuild: 3)) {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.1.9", build: 9), currentVersion: "1.2.0", currentBuild: 3)
        }
    }

    @Test("版本与 build 完全相同被拒绝")
    func identicalRejected() throws {
        expectThrowsSync(.notNewerThanCurrent(currentVersion: "1.2.0", currentBuild: 3)) {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.2.0", build: 3), currentVersion: "1.2.0", currentBuild: 3)
        }
    }

    @Test("按数值逐段比较而不是按字符串")
    func comparesNumerically() throws {
        #expect(try UpdateVersion.isNewer(manifest: makeManifest(version: "1.10.0", build: 4), currentVersion: "1.9.9", currentBuild: 3))
        expectThrowsSync(.notNewerThanCurrent(currentVersion: "1.10.0", currentBuild: 3)) {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.9.9", build: 4), currentVersion: "1.10.0", currentBuild: 3)
        }
    }

    @Test("段数不同时缺失段按 0 处理")
    func shorterVersionIsPaddedWithZeros() throws {
        #expect(try UpdateVersion.isNewer(manifest: makeManifest(version: "1.2.1", build: 4), currentVersion: "1.2", currentBuild: 3))
        // 1.2 == 1.2.0，因此由 build 决定；build 更高即为升级。
        #expect(try UpdateVersion.isNewer(manifest: makeManifest(version: "1.2", build: 4), currentVersion: "1.2.0", currentBuild: 3))
        // 1.2 < 1.2.1，即使 build 更高也算降级。
        expectThrowsSync(.notNewerThanCurrent(currentVersion: "1.2.1", currentBuild: 3)) {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.2", build: 9), currentVersion: "1.2.1", currentBuild: 3)
        }
    }

    @Test("版本格式非法时抛出")
    func malformedVersionThrows() throws {
        for version in ["1.2.x", "1..2", ".1.2", "1.2.", "", "1.2-beta", "1,2", "١.٢"] {
            let error = captureSync {
                _ = try UpdateVersion.isNewer(manifest: makeManifest(version: version, build: 4), currentVersion: "1.2.0", currentBuild: 3)
            }
            #expect(error == .invalidVersionFormat(version), "候选版本 \(version) 应被判非法，实际 \(String(describing: error))")
        }
    }

    @Test("当前版本格式非法时抛出")
    func malformedCurrentVersionThrows() throws {
        let error = captureSync {
            _ = try UpdateVersion.isNewer(manifest: makeManifest(version: "1.3.0", build: 4), currentVersion: "1.2.x", currentBuild: 3)
        }
        #expect(error == .invalidVersionFormat("1.2.x"), "实际 \(String(describing: error))")
    }

    @Test("parse 返回数值分段")
    func parseReturnsSegments() throws {
        #expect(try UpdateVersion.parse("1.2.30") == [1, 2, 30])
        #expect(try UpdateVersion.parse("2") == [2])
    }
}

@Suite("更新源与主机策略")
struct UpdateSourceTests {
    @Test("固定清单地址使用 https 且落在 github.com")
    func manifestURLUsesFixedHost() {
        #expect(UpdateSource.allowedInitialHost == "github.com")
        #expect(UpdateSource.manifestURL.scheme == "https")
        #expect(UpdateSource.manifestURL.host == UpdateSource.allowedInitialHost)
    }

    @Test("资产主机白名单")
    func assetHostPolicy() {
        #expect(UpdateSource.isAllowedAssetHost("github.com"))
        #expect(UpdateSource.isAllowedAssetHost("GitHub.com"))
        #expect(UpdateSource.isAllowedAssetHost("objects.githubusercontent.com"))
        #expect(UpdateSource.isAllowedAssetHost("release-assets.githubusercontent.com"))

        #expect(!UpdateSource.isAllowedAssetHost(""))
        #expect(!UpdateSource.isAllowedAssetHost("githubusercontent.com"))
        #expect(!UpdateSource.isAllowedAssetHost("evilgithubusercontent.com"))
        #expect(!UpdateSource.isAllowedAssetHost("github.com.evil.example"))
        #expect(!UpdateSource.isAllowedAssetHost("evil.example.com"))
    }

    @Test("跳转主机只允许 CDN 后缀")
    func redirectHostPolicy() {
        #expect(UpdateSource.isAllowedRedirectHost("objects.githubusercontent.com"))
        // GitHub redirects releases/latest/download/... within github.com itself.
        #expect(UpdateSource.isAllowedRedirectHost("github.com"))
        #expect(!UpdateSource.isAllowedRedirectHost("githubusercontent.com"))
        #expect(!UpdateSource.isAllowedRedirectHost("evil.githubusercontent.com.attacker.example"))
        #expect(!UpdateSource.isAllowedRedirectHost(""))
    }

    @Test("完整资产 URL 校验要求 https 与白名单主机")
    func assetURLPolicy() {
        #expect(UpdateSource.isAllowedAssetURL(URL(string: testAssetURLString)!))
        #expect(!UpdateSource.isAllowedAssetURL(URL(string: "http://github.com/x.pkg")!))
        #expect(!UpdateSource.isAllowedAssetURL(URL(string: "https://evil.example.com/x.pkg")!))
    }
}

@Suite("传输层与跳转策略")
struct TransportTests {
    private let session = URLSession(configuration: .ephemeral)

    private func decide(_ target: String) -> (allowed: Bool, target: String) {
        TransferGuard.redirectDecision(for: URLRequest(url: URL(string: target)!))
    }

    @Test("跳转到 CDN 的 https 地址被允许")
    func redirectToCDNAllowed() {
        #expect(decide("https://objects.githubusercontent.com/asset.pkg").allowed)
        #expect(decide("https://release-assets.githubusercontent.com/asset.pkg").allowed)
        // `releases/latest/download/...` redirects inside github.com before the
        // bytes come from the CDN, so the same host must stay allowed.
        #expect(decide("https://github.com/zzusec/cool-mac/releases/download/v1/asset.pkg").allowed)
    }

    @Test("跳转到非白名单主机被拒绝")
    func redirectToForeignHostBlocked() {
        for target in [
            "https://evil.example.com/asset.pkg",
            "https://githubusercontent.com/asset.pkg",
            "https://evilgithubusercontent.com/asset.pkg",
            "http://objects.githubusercontent.com/asset.pkg",
        ] {
            let decision = decide(target)
            #expect(!decision.allowed, "\(target) 不应被允许")
            #expect(decision.target == target)
        }
    }

    @Test("委托回调拦住跳转并记下目标")
    func delegateBlocksRedirect() async {
        let guardrail = TransferGuard(byteLimit: 1024)
        let task = session.dataTask(with: URL(string: "https://github.com/start")!)
        let response = httpResponse(URL(string: "https://github.com/start")!, status: 302)
        let request = URLRequest(url: URL(string: "https://evil.example.com/asset.pkg")!)

        let forwarded: URLRequest? = await withCheckedContinuation { continuation in
            guardrail.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { result in
                continuation.resume(returning: result)
            }
        }
        #expect(forwarded == nil)
        #expect(guardrail.blockedRedirectTarget == "https://evil.example.com/asset.pkg")
    }

    @Test("委托回调放行 CDN 跳转")
    func delegateAllowsCDNRedirect() async {
        let guardrail = TransferGuard(byteLimit: 1024)
        let task = session.dataTask(with: URL(string: "https://github.com/start")!)
        let response = httpResponse(URL(string: "https://github.com/start")!, status: 302)
        let request = URLRequest(url: URL(string: "https://objects.githubusercontent.com/asset.pkg")!)

        let forwarded: URLRequest? = await withCheckedContinuation { continuation in
            guardrail.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { result in
                continuation.resume(returning: result)
            }
        }
        #expect(forwarded?.url?.host == "objects.githubusercontent.com")
        #expect(guardrail.blockedRedirectTarget == nil)
    }

    @Test("超出字节上限时记下越界并取消任务")
    func guardRecordsByteOverflow() async {
        let guardrail = TransferGuard(byteLimit: 8)
        let task = session.dataTask(with: URL(string: "https://github.com/start")!)
        guardrail.urlSession(session, dataTask: task, didReceive: Data(repeating: 0, count: 4))
        #expect(!guardrail.didExceedByteLimit)
        guardrail.urlSession(session, dataTask: task, didReceive: Data(repeating: 0, count: 5))
        #expect(guardrail.didExceedByteLimit)
    }

    @Test("非正的字节上限被直接拒绝")
    func nonPositiveByteLimitRejected() async {
        let transport = URLSessionUpdateTransport()
        for limit in [0, -1] {
            let error = await captureUpdateError {
                _ = try await transport.data(from: URL(string: "https://github.com/x")!, byteLimit: limit, timeout: 1)
            }
            #expect(error == .assetTooLarge(limit: limit, reported: 0), "实际 \(String(describing: error))")
        }
    }

    @Test("默认配置不携带凭据与 Cookie")
    func configurationIsCredentialFree() {
        let configuration = URLSessionUpdateTransport.credentialFreeConfiguration
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpAdditionalHeaders == nil || configuration.httpAdditionalHeaders?.isEmpty == true)
    }

    @Test("无参 init 可用且符合 UpdateTransport")
    func noArgumentInitWorks() {
        let transport: any UpdateTransport = URLSessionUpdateTransport()
        #expect(type(of: transport) == URLSessionUpdateTransport.self)
    }
}
