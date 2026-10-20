import CryptoKit
import Foundation
import Security

/// 更新私钥的唯一存放位置：登录钥匙串的 generic password 条目。
///
/// 私钥从不写入文件、stdout 或仓库；`keygen` 只打印公钥 raw base64。
/// 首次由新二进制读取该条目时，macOS 可能弹出钥匙串授权框；选择「始终允许」
/// 后，重新构建（CDHash 变化）会再次询问，这是钥匙串 ACL 的既有行为。
enum ReleaseKeychain {
    static let service = "local.hx10.coolmac.update"
    static let account = "coolmac"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 返回 nil 表示钥匙串中没有该条目；其他情况一律抛出，不猜测、不重建。
    static func loadPrivateKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw ReleaseError("钥匙串条目不是预期的数据格式（service=\(service) account=\(account)）")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw ReleaseError("读取钥匙串失败（service=\(service) account=\(account)）：OSStatus \(status)")
        }
    }

    static func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey? {
        guard let data = try loadPrivateKeyData() else { return nil }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw ReleaseError("钥匙串中的更新私钥不可用（\(data.count) 字节）：\(error.localizedDescription)")
        }
    }

    static func store(_ privateKey: Curve25519.Signing.PrivateKey, force: Bool) throws {
        if try loadPrivateKeyData() != nil {
            guard force else {
                throw ReleaseError("登录钥匙串已存在更新私钥（service=\(service) account=\(account)），拒绝覆盖；确需轮换请显式传 --force")
            }
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ReleaseError("删除既有更新私钥失败：OSStatus \(status)")
            }
        }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = privateKey.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        attributes[kSecAttrLabel as String] = "清凉风扇更新签名私钥"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ReleaseError("写入登录钥匙串失败：OSStatus \(status)")
        }
    }
}
