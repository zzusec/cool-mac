import CoolMacCore
import CoolMacUpdates
import Foundation

/// 唯一的清单验签入口：公钥与格式由 CoolMacUpdates 决定，本工具不再自行实现签名校验。
enum ManifestGate {
    static func verify(_ envelope: Data) throws -> UpdateManifest {
        do {
            return try UpdateManifestVerifier.verify(
                envelope: envelope,
                publicKeyBase64: UpdatePublicKey.base64,
                bundleID: Product.bundleID
            )
        } catch {
            throw InstallError("更新清单验签失败：\(error.localizedDescription)")
        }
    }
}

enum InstallGate {
    struct Installed {
        let bundleID: String
        let version: String
        /// 已安装 app 的 CFBundleVersion；无法解析为整数时为 nil（早期安装包写的是 "1.0.0"）。
        let build: Int?
        let buildText: String
    }

    private static let hexCharacters = Set("0123456789abcdef")

    /// schema、bundleID、架构与最低系统版本由 CoolMacUpdates 在验签时判定；
    /// 这里只确认后续核对副本所依赖的摘要与字节数可用。
    static func requirePackageDigestFormat(_ manifest: UpdateManifest) throws {
        guard manifest.assetSHA256.count == 64, manifest.assetSHA256.allSatisfy({ hexCharacters.contains($0) }) else {
            throw InstallError("清单中的 SHA256 不是 64 位小写十六进制：\(manifest.assetSHA256)")
        }
        guard manifest.assetBytes > 0, manifest.assetBytes <= InstallConstants.maximumPackageBytes else {
            throw InstallError("清单中的字节数不合法：\(manifest.assetBytes)")
        }
    }

    /// 读取已安装 app 的版本；返回 nil 表示 app 不存在（首次安装）。
    static func installedVersion() throws -> Installed? {
        guard let value = try InstallFileGuard.infoIfPresent(InstallConstants.appInfoPlistPath) else {
            return nil
        }
        guard (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1, value.st_uid == 0 else {
            throw InstallError("已安装 app 的 Info.plist 不安全（要求 root 拥有的普通单链接文件）：\(InstallConstants.appInfoPlistPath)")
        }
        let data = try InstallFileGuard.readRegularFile(
            InstallConstants.appInfoPlistPath,
            owner: 0,
            maximumBytes: 1 << 20,
            what: "已安装 app 的 Info.plist"
        )
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw InstallError("已安装 app 的 Info.plist 无法解析：\(error.localizedDescription)")
        }
        guard let dictionary = plist as? [String: Any] else {
            throw InstallError("已安装 app 的 Info.plist 不是字典：\(InstallConstants.appInfoPlistPath)")
        }
        guard let bundleID = dictionary["CFBundleIdentifier"] as? String else {
            throw InstallError("已安装 app 的 Info.plist 缺少 CFBundleIdentifier")
        }
        guard let version = dictionary["CFBundleShortVersionString"] as? String else {
            throw InstallError("已安装 app 的 Info.plist 缺少 CFBundleShortVersionString")
        }
        let buildText: String
        if let number = dictionary["CFBundleVersion"] as? NSNumber {
            buildText = number.stringValue
        } else if let text = dictionary["CFBundleVersion"] as? String {
            buildText = text
        } else {
            throw InstallError("已安装 app 的 Info.plist 缺少 CFBundleVersion")
        }
        return Installed(
            bundleID: bundleID,
            version: version,
            build: Int(buildText),
            buildText: buildText
        )
    }

    /// 拒绝降级与重复安装；版本比较由 CoolMacUpdates 统一判定。
    static func requireUpgrade(to manifest: UpdateManifest) throws {
        guard manifest.build >= 1 else {
            throw InstallError("清单 build 必须是正整数：\(manifest.build)")
        }
        guard let installed = try installedVersion() else {
            print("未检测到已安装的 \(InstallConstants.appBundlePath)，按首次安装处理。")
            return
        }
        guard installed.bundleID == Product.bundleID else {
            throw InstallError("已安装 app 的 bundle id 不是 \(Product.bundleID)：\(installed.bundleID)")
        }
        // 早期安装包的 CFBundleVersion 可能不是整数（本机现装的是 "1.0.0"）。此时无法按
        // build 排序，但也绝不能因此放行：改为要求版本号严格递增。
        if let installedBuild = installed.build {
            // UpdateVersion.isNewer 在“不是更新版本”时抛错而不是返回 false，
            // 因此这里必须区分降级与版本格式非法，不能把两者混成一句话。
            do {
                _ = try UpdateVersion.isNewer(
                    manifest: manifest,
                    currentVersion: installed.version,
                    currentBuild: installedBuild
                )
            } catch UpdateError.notNewerThanCurrent {
                throw InstallError("拒绝降级或重复安装：目标 \(manifest.version)（build \(manifest.build)）不高于已安装 \(installed.version)（build \(installed.buildText)）")
            } catch {
                throw InstallError("版本比较失败：\(error.localizedDescription)")
            }
        } else {
            print("警告：已安装 app 的 CFBundleVersion 不是整数（\(installed.buildText)），本次要求版本号严格递增。")
            try requireStrictlyNewerVersion(manifest.version, than: installed.version, installedBuildText: installed.buildText)
        }
        print("版本升级：\(installed.version)（build \(installed.buildText)）→ \(manifest.version)（build \(manifest.build)）")
    }

    /// 已安装 build 不可解析时的降级门：要求版本号严格递增（缺失段按 0 补齐）。
    private static func requireStrictlyNewerVersion(
        _ offered: String,
        than current: String,
        installedBuildText: String
    ) throws {
        let offeredSegments: [Int]
        let currentSegments: [Int]
        do {
            offeredSegments = try UpdateVersion.parse(offered)
            currentSegments = try UpdateVersion.parse(current)
        } catch {
            throw InstallError("版本比较失败：\(error.localizedDescription)")
        }
        let count = max(offeredSegments.count, currentSegments.count)
        for index in 0..<count {
            let left = index < offeredSegments.count ? offeredSegments[index] : 0
            let right = index < currentSegments.count ? currentSegments[index] : 0
            if left != right {
                guard left > right else {
                    throw InstallError("拒绝降级：目标 \(offered) 低于已安装 \(current)（build \(installedBuildText)）")
                }
                return
            }
        }
        throw InstallError("拒绝重复安装：目标版本与已安装版本相同（\(offered)，build \(installedBuildText)）")
    }
}
