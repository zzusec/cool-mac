import CryptoKit
import Foundation
import Testing

@testable import CoolMacUpdates

@Suite("清单验签")
struct ManifestVerificationTests {
    private let hostArchitecture = "arm64"
    private let hostSystemVersion = "14.5"

    private func verify(_ envelope: Data, key: Curve25519.Signing.PrivateKey, bundleID: String = testBundleID) throws -> UpdateManifest {
        try UpdateManifestVerifier.verify(
            envelope: envelope,
            publicKeyBase64: publicKeyBase64(key),
            bundleID: bundleID,
            hostArchitecture: hostArchitecture,
            hostSystemVersion: hostSystemVersion
        )
    }

    private func verifyError(_ envelope: Data, key: Curve25519.Signing.PrivateKey, bundleID: String = testBundleID) -> UpdateError? {
        captureSync {
            _ = try UpdateManifestVerifier.verify(
                envelope: envelope,
                publicKeyBase64: publicKeyBase64(key),
                bundleID: bundleID,
                hostArchitecture: hostArchitecture,
                hostSystemVersion: hostSystemVersion
            )
        }
    }

    @Test("正确签名的清单通过并逐字段还原")
    func validManifestVerifies() throws {
        let key = makeKey()
        let payload = try manifestPayload(version: "1.4.2", build: 7, notes: "修复散热曲线")
        let envelope = try signedEnvelope(payload: payload, key: key)

        let manifest = try verify(envelope, key: key)

        #expect(manifest.schema == 1)
        #expect(manifest.bundleID == testBundleID)
        #expect(manifest.version == "1.4.2")
        #expect(manifest.build == 7)
        #expect(manifest.minimumSystemVersion == "14.0")
        #expect(manifest.architectures == ["arm64"])
        #expect(manifest.assetURL.absoluteString == testAssetURLString)
        #expect(manifest.assetBytes == testAsset.count)
        #expect(manifest.assetSHA256 == testAssetDigest())
        #expect(manifest.notes == "修复散热曲线")
    }

    @Test("篡改 payload 后签名失败")
    func tamperedPayloadFails() throws {
        let key = makeKey()
        let payload = try manifestPayload()
        let envelope = try envelopeJSON(
            payload: tampered(payload).base64EncodedString(),
            signature: try key.signature(for: payload).base64EncodedString()
        )
        expectThrowsSync(.invalidSignature) { _ = try self.verify(envelope, key: key) }
    }

    @Test("篡改签名后校验失败")
    func tamperedSignatureFails() throws {
        let key = makeKey()
        let payload = try manifestPayload()
        let envelope = try envelopeJSON(
            payload: payload.base64EncodedString(),
            signature: flipped(try key.signature(for: payload)).base64EncodedString()
        )
        expectThrowsSync(.invalidSignature) { _ = try self.verify(envelope, key: key) }
    }

    @Test("用另一把私钥签名时校验失败")
    func wrongKeyFails() throws {
        let envelope = try signedEnvelope(payload: try manifestPayload(), key: makeKey())
        expectThrowsSync(.invalidSignature) { _ = try self.verify(envelope, key: makeKey()) }
    }

    @Test("公钥不是 32 字节 raw 时失败")
    func malformedPublicKeyFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(), key: key)
        let candidates = [
            "",
            "not base64 !!",
            Data(repeating: 0, count: 16).base64EncodedString(),
            Data(repeating: 0, count: 33).base64EncodedString(),
            Data(repeating: 7, count: 31).base64EncodedString(),
        ]
        for candidate in candidates {
            let error = captureSync {
                _ = try UpdateManifestVerifier.verify(
                    envelope: envelope, publicKeyBase64: candidate, bundleID: testBundleID,
                    hostArchitecture: self.hostArchitecture, hostSystemVersion: self.hostSystemVersion
                )
            }
            #expect(error == .invalidPublicKey, "候选公钥 \(candidate.prefix(10)) 应被拒绝，实际 \(String(describing: error))")
        }
    }

    @Test("内置公钥不会接受无关私钥的签名")
    func builtInPublicKeyRejectsForeignSignatures() throws {
        let envelope = try signedEnvelope(payload: try manifestPayload(), key: makeKey())
        let error = captureSync {
            _ = try UpdateManifestVerifier.verify(
                envelope: envelope, publicKeyBase64: UpdatePublicKey.base64, bundleID: testBundleID,
                hostArchitecture: self.hostArchitecture, hostSystemVersion: self.hostSystemVersion
            )
        }
        #expect(error == .invalidSignature || error == .invalidPublicKey, "实际 \(String(describing: error))")
    }

    @Test("schema 不是 1 时拒绝")
    func unsupportedSchemaFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(schema: 2), key: key)
        expectThrowsSync(.unsupportedSchema(2)) { _ = try self.verify(envelope, key: key) }
    }

    @Test("bundleID 不匹配时拒绝")
    func foreignBundleIDFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(bundleID: "com.example.other"), key: key)
        expectThrowsSync(.bundleIDMismatch(expected: testBundleID, found: "com.example.other")) {
            _ = try self.verify(envelope, key: key)
        }
    }

    @Test("架构不含本机架构时拒绝")
    func incompatibleArchitectureFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(architectures: ["x86_64"]), key: key)
        expectThrowsSync(.unsupportedArchitecture("arm64")) { _ = try self.verify(envelope, key: key) }
    }

    @Test("架构列表为空时拒绝")
    func emptyArchitectureListFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(architectures: []), key: key)
        expectThrowsSync(.unsupportedArchitecture("arm64")) { _ = try self.verify(envelope, key: key) }
    }

    @Test("系统版本低于 minimumSystemVersion 时拒绝")
    func systemVersionTooOldFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(minimumSystemVersion: "15.0"), key: key)
        expectThrowsSync(.systemVersionTooOld(required: "15.0", current: hostSystemVersion)) {
            _ = try self.verify(envelope, key: key)
        }
    }

    @Test("恰好等于 minimumSystemVersion 时通过")
    func exactMinimumSystemVersionPasses() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(minimumSystemVersion: "14.5"), key: key)
        let manifest = try verify(envelope, key: key)
        #expect(manifest.minimumSystemVersion == "14.5")
    }

    @Test("信封不是 JSON 时拒绝")
    func garbageEnvelopeFails() throws {
        let error = verifyError(Data("这不是 JSON".utf8), key: makeKey())
        #expect(isInvalidManifestJSON(error), "实际 \(String(describing: error))")
    }

    @Test("signature 不是合法 base64 时拒绝")
    func nonBase64SignatureFails() throws {
        let payload = try manifestPayload()
        let envelope = try envelopeJSON(payload: payload.base64EncodedString(), signature: "%%% 非 base64 %%%")
        let error = verifyError(envelope, key: makeKey())
        #expect(isInvalidManifestJSON(error), "实际 \(String(describing: error))")
    }

    @Test("payload 不是合法 base64 时拒绝")
    func nonBase64PayloadFails() throws {
        let envelope = try envelopeJSON(payload: "****", signature: Data(repeating: 1, count: 64).base64EncodedString())
        let error = verifyError(envelope, key: makeKey())
        #expect(isInvalidManifestJSON(error), "实际 \(String(describing: error))")
    }

    @Test("payload 缺少必需字段时拒绝")
    func missingPayloadFieldFails() throws {
        let key = makeKey()
        let fields = ["schema", "bundleID", "version", "build", "minimumSystemVersion", "architectures", "assetURL", "assetBytes", "assetSHA256", "notes"]
        for field in fields {
            let envelope = try signedEnvelope(payload: try manifestPayloadWithout(field), key: key)
            let error = verifyError(envelope, key: key)
            #expect(isInvalidManifestJSON(error), "缺少 \(field) 时应为 invalidManifestJSON，实际 \(String(describing: error))")
        }
    }

    @Test("字段类型不符时拒绝")
    func wrongFieldTypeFails() throws {
        let key = makeKey()
        let payload = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "bundleID": testBundleID, "version": "1.2.0", "build": "3",
            "minimumSystemVersion": "14.0", "architectures": ["arm64"],
            "assetURL": testAssetURLString, "assetBytes": testAsset.count,
            "assetSHA256": testAssetDigest(), "notes": "",
        ] as [String: Any], options: [.sortedKeys])
        let envelope = try signedEnvelope(payload: payload, key: key)
        let error = verifyError(envelope, key: key)
        #expect(isInvalidManifestJSON(error), "build 为字符串时应为 invalidManifestJSON，实际 \(String(describing: error))")
    }

    @Test("assetURL 不在 github.com 上时拒绝")
    func nonGithubAssetURLFails() throws {
        let key = makeKey()
        let urls = [
            "https://evil.example.com/CoolMac.pkg",
            "https://objects.githubusercontent.com/CoolMac.pkg",
            "https://githubusercontent.com/CoolMac.pkg",
            "https://evilgithubusercontent.com/CoolMac.pkg",
        ]
        for url in urls {
            let envelope = try signedEnvelope(payload: try manifestPayload(assetURL: url), key: key)
            expectThrowsSync(.disallowedURLHost(url)) { _ = try self.verify(envelope, key: key) }
        }
    }

    @Test("assetURL 使用 http 时拒绝")
    func httpAssetURLFails() throws {
        let key = makeKey()
        let url = "http://github.com/zzusec/cool-mac/releases/download/v1.2.0/CoolMac.pkg"
        let envelope = try signedEnvelope(payload: try manifestPayload(assetURL: url), key: key)
        expectThrowsSync(.disallowedURLHost(url)) { _ = try self.verify(envelope, key: key) }
    }

    @Test("摘要格式非法时拒绝")
    func malformedDigestFails() throws {
        let key = makeKey()
        let digest = testAssetDigest()
        let candidates = [digest.uppercased(), String(digest.dropLast()), digest + "0", "z" + String(digest.dropFirst()), ""]
        for candidate in candidates {
            let envelope = try signedEnvelope(payload: try manifestPayload(assetSHA256: candidate), key: key)
            let error = verifyError(envelope, key: key)
            #expect(isInvalidManifestJSON(error), "摘要 \(candidate) 应被拒绝，实际 \(String(describing: error))")
        }
    }

    @Test("assetBytes 非正数时拒绝")
    func nonPositiveAssetBytesFails() throws {
        let key = makeKey()
        for bytes in [0, -1] {
            let envelope = try signedEnvelope(payload: try manifestPayload(assetBytes: bytes), key: key)
            let error = verifyError(envelope, key: key)
            #expect(isInvalidManifestJSON(error), "assetBytes=\(bytes) 应被拒绝，实际 \(String(describing: error))")
        }
    }

    @Test("build 非正数时拒绝")
    func nonPositiveBuildFails() throws {
        let key = makeKey()
        for build in [0, -5] {
            let envelope = try signedEnvelope(payload: try manifestPayload(build: build), key: key)
            let error = verifyError(envelope, key: key)
            #expect(isInvalidManifestJSON(error), "build=\(build) 应被拒绝，实际 \(String(describing: error))")
        }
    }

    @Test("payload 中 version 格式非法时拒绝")
    func malformedVersionInPayloadFails() throws {
        let key = makeKey()
        for version in ["1.2.x", "1..2", "1.2.", "", "1.2-beta", "v1.2.0"] {
            let envelope = try signedEnvelope(payload: try manifestPayload(version: version), key: key)
            let error = verifyError(envelope, key: key)
            #expect(error == .invalidVersionFormat(version), "version=\(version) 应被判为非法格式，实际 \(String(describing: error))")
        }
    }

    @Test("minimumSystemVersion 格式非法时拒绝")
    func malformedMinimumSystemVersionFails() throws {
        let key = makeKey()
        let envelope = try signedEnvelope(payload: try manifestPayload(minimumSystemVersion: "14.x"), key: key)
        let error = verifyError(envelope, key: key)
        #expect(isInvalidManifestJSON(error), "实际 \(String(describing: error))")
    }

    @Test("先验签再信任字段：签名无效时不会先报字段错误")
    func signatureIsCheckedBeforeFields() throws {
        let key = makeKey()
        // schema、bundleID 与 assetURL 都是错的，但签名同样无效：必须先报签名错误。
        let payload = try manifestPayload(schema: 99, bundleID: "com.example.other", assetURL: "https://evil.example.com/x.pkg")
        let envelope = try envelopeJSON(
            payload: tampered(payload).base64EncodedString(),
            signature: try key.signature(for: payload).base64EncodedString()
        )
        expectThrowsSync(.invalidSignature) { _ = try self.verify(envelope, key: key) }
    }

    @Test("本机架构与系统版本来自运行环境")
    func hostFactsReflectRuntime() throws {
        #expect(["arm64", "x86_64"].contains(UpdateManifestVerifier.hostArchitecture))
        let segments = try UpdateVersion.parse(UpdateManifestVerifier.hostSystemVersion)
        #expect(segments.count == 3)
    }
}
