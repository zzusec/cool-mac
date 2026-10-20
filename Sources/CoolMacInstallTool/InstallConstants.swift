import CoolMacCore
import Darwin
import Foundation

/// 特权安装工具的全部固定位置。工具不接受任何路径、URL 或命令参数，
/// 所有位置都来自这里与 CoolMacCore/Product，避免任何调用方注入。
enum InstallConstants {
    /// 本机专用：固定为 UID 501 用户的更新缓存目录（与 identity.plist 的 authorizedUID 一致）。
    static let cacheDirectory = Product.updateCacheDirectoryAbsolute
    static let cacheOwnerUID: uid_t = 501
    static let stagingRoot = Product.stateDirectory
    static let installToolPath = Product.installToolPath
    static let appBundlePath = "/Applications/\(Product.name).app"
    static let appInfoPlistPath = "/Applications/\(Product.name).app/Contents/Info.plist"
    static let installerPath = "/usr/sbin/installer"
    static let maximumManifestBytes = 1 << 20
    static let maximumPackageBytes = 4 << 30

    static let usage = """
    用法：\(installToolPath) --install <uuid>

    非驻留的特权安装工具。只接受一个规范 UUID（36 字符、带连字符，大小写均可，内部归一化为小写），
    不接受任何路径、URL 或命令参数，并在固定的本机缓存目录读取 <uuid>.pkg 与 <uuid>.json：
      \(cacheDirectory)
    该目录固定属于本机用户 UID \(cacheOwnerUID)（本机专用，不支持其他用户或机器）。
    调用方必须先把已验签的 update.json 与已校验的 pkg 放到该目录，再传入同一个 UUID。

    流程：用 CoolMacUpdates 重新验签清单 → 拒绝降级 → 把 pkg 复制到 root 私有的
    \(stagingRoot)/staging-<uuid>（0700）→ 对副本重新计算 SHA256 与字节数并核对
    → 调用 \(installerPath) -pkg <副本> -target / → 核对 \(appBundlePath)
    的 CFBundleShortVersionString 与 CFBundleVersion。任何失败都以非 0 退出并清理暂存目录。

    本工具不联网、不执行缓存目录中的脚本或可执行文件、不修改 sudoers、不改动 SIP 或 Gatekeeper。
    """
}
