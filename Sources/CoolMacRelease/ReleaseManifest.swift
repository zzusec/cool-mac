import CoolMacUpdates
import CryptoKit
import Foundation

/// update.json 的线上 payload。键名与线上格式（已定契约）逐字一致，
/// 与 CoolMacUpdates/UpdateManifest 的解码键相同；改名会立刻在自检中被发现。
struct ReleasePayload: Codable, Sendable {
    let architectures: [String]
    let assetBytes: Int
    let assetSHA256: String
    let assetURL: String
    let build: Int
    let bundleID: String
    let minimumSystemVersion: String
    let notes: String
    let schema: Int
    let version: String
}

/// 线上信封：payload 与 signature 均为 base64。
struct ReleaseEnvelope: Codable, Sendable {
    let payload: String
    let signature: String
}

enum ReleaseManifest {
    static let schema = UpdateManifest.currentSchema
    static let bundleID = "local.hx10.coolmac"
    static let repository = "zzusec/cool-mac"
    static let productName = "清凉风扇"
    static let defaultMinimumSystemVersion = "14.0"
    /// 发布资产必须来自固定仓库的 Release 页面。
    static let releasePathPrefix = "/\(repository)/releases/download/"

    /// 稳定序列化：键按字母序，不转义斜杠，保证同一输入产生同一字节序列。
    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw ReleaseError("序列化清单失败：\(error.localizedDescription)")
        }
    }

    /// 签名覆盖 payload 解码后的原始字节，随后写入 update.json。
    static func envelope(payload: ReleasePayload, privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let payloadData = try canonicalJSON(payload)
        let signature: Data
        do {
            signature = try privateKey.signature(for: payloadData)
        } catch {
            throw ReleaseError("Ed25519 签名失败：\(error.localizedDescription)")
        }
        let envelope = ReleaseEnvelope(
            payload: payloadData.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
        var data = try canonicalJSON(envelope)
        data.append(0x0a)
        return data
    }

    /// 用与 App / 安装工具相同的 CoolMacUpdates 实现回验刚写出的清单。
    /// 这一步把线上格式、键名、schema、bundleID 的漂移在发布时暴露出来。
    static func selfCheck(_ envelope: Data, publicKeyBase64: String) throws -> UpdateManifest {
        do {
            return try UpdateManifestVerifier.verify(
                envelope: envelope,
                publicKeyBase64: publicKeyBase64,
                bundleID: bundleID
            )
        } catch {
            throw ReleaseError("生成的清单未通过 CoolMacUpdates 验签自检：\(error.localizedDescription)")
        }
    }

    /// 读取并验签一份已存在的 update.json（publish 用）。
    static func loadVerified(_ path: String, publicKeyBase64: String) throws -> UpdateManifest {
        let data = try ReleaseFile.read(path, what: "更新清单")
        return try selfCheck(data, publicKeyBase64: publicKeyBase64)
    }

    static func defaultAssetURL(version: String, packagePath: String) throws -> String {
        let name = ReleaseFile.basename(packagePath)
        guard !name.isEmpty, !name.hasPrefix(".") else {
            throw ReleaseError("安装包文件名不安全：\(name)")
        }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ReleaseError("无法编码安装包文件名：\(name)")
        }
        return "https://github.com/\(repository)/releases/download/v\(version)/\(encoded)"
    }

    /// 只接受本仓库 Release 页面上、且文件名与安装包一致、主机被 CoolMacUpdates 允许的 https 地址。
    static func validateAssetURL(_ text: String, packagePath: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else {
            throw ReleaseError("assetURL 必须是带主机的 https 地址：\(text)")
        }
        guard UpdateSource.isAllowedAssetHost(host) else {
            throw ReleaseError("assetURL 主机不在允许的更新主机内（\(host)）：\(text)")
        }
        guard url.path.hasPrefix(releasePathPrefix) else {
            throw ReleaseError("assetURL 必须指向 \(repository) 的 Release 资产（期望路径前缀 \(releasePathPrefix)）：\(text)")
        }
        guard url.lastPathComponent == ReleaseFile.basename(packagePath) else {
            throw ReleaseError("assetURL 的文件名（\(url.lastPathComponent)）与安装包（\(ReleaseFile.basename(packagePath))）不一致：\(text)")
        }
        guard url.query == nil, url.fragment == nil else {
            throw ReleaseError("assetURL 不允许带查询串或片段：\(text)")
        }
        return url
    }

    static func validateDottedVersion(_ value: String, what: String) throws {
        let pattern = #"^[0-9]+(\.[0-9]+){1,2}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw ReleaseError("\(what)必须是点分数字（如 1.2 或 1.2.3）：\(value)")
        }
    }
}
