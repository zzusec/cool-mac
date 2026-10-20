import CoolMacCore
import CoolMacUpdates
import Darwin
import Foundation

/// 清凉风扇特权安装工具（非驻留）。
///
/// 只接受 `--install <uuid>`；pkg 与清单都从固定缓存目录按该 UUID 拼出，
/// 因此调用方无法指定路径、URL 或命令。安装前用 CoolMacUpdates 重新验签清单、
/// 拒绝降级，并把 pkg 复制到 root 私有的暂存目录后对副本重新计算摘要。
@main
struct InstallToolMain {
    static func main() {
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)
        do {
            let uuid = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            guard geteuid() == 0 else {
                throw InstallError("必须以 root 运行（由 macOS 系统授权流程调用）；当前 EUID \(geteuid())")
            }
            try Installer(uuid: uuid).run()
        } catch let error as InstallError {
            FileHandle.standardError.write(Data(("CoolMacInstallTool: \(error.description)\n").utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data(("CoolMacInstallTool: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    /// 只接受一个规范 UUID（36 字符、带连字符、无花括号或前缀）。
    /// App 侧用的是 `UUID.uuidString`（大写），因此大小写都接受；
    /// 内部一律归一化为小写规范形式来拼缓存文件名（本机 APFS 默认大小写不敏感）。
    static func parseArguments(_ arguments: [String]) throws -> String {
        if arguments == ["--help"] || arguments == ["-h"] {
            print(InstallConstants.usage)
            exit(0)
        }
        guard arguments.count == 2, arguments[0] == "--install" else {
            throw InstallError("用法：\(InstallConstants.installToolPath) --install <uuid>（只接受一个规范 UUID，不接受路径、URL 或命令）")
        }
        let text = arguments[1]
        guard let uuid = UUID(uuidString: text),
              text.count == 36,
              text.lowercased() == uuid.uuidString.lowercased()
        else {
            throw InstallError("--install 的取值必须是规范 UUID（36 字符、带连字符，不含花括号或前缀）：\(text)")
        }
        return uuid.uuidString.lowercased()
    }
}

struct Installer {
    let uuid: String

    private var packagePath: String { InstallConstants.cacheDirectory + "/" + uuid + ".pkg" }
    private var manifestPath: String { InstallConstants.cacheDirectory + "/" + uuid + ".json" }
    private var stagingDirectory: String { InstallConstants.stagingRoot + "/staging-" + uuid }

    func run() throws {
        print("CoolMacInstallTool：uuid=\(uuid)")
        print("更新缓存目录（本机专用）：\(InstallConstants.cacheDirectory)")

        try InstallFileGuard.requireDirectoryChain(
            InstallConstants.cacheDirectory,
            finalOwner: InstallConstants.cacheOwnerUID
        )
        let envelope = try InstallFileGuard.readRegularFile(
            manifestPath,
            owner: InstallConstants.cacheOwnerUID,
            maximumBytes: InstallConstants.maximumManifestBytes,
            what: "更新清单"
        )
        let manifest = try ManifestGate.verify(envelope)
        try InstallGate.requirePackageDigestFormat(manifest)
        try InstallGate.requireUpgrade(to: manifest)

        let staged = try stage()
        defer { InstallFileGuard.removeStagingDirectory(stagingDirectory) }

        let stagedDigest = try InstallFileGuard.digest(
            staged,
            owner: 0,
            maximumBytes: InstallConstants.maximumPackageBytes,
            what: "暂存安装包"
        )
        guard stagedDigest.sha256 == manifest.assetSHA256, stagedDigest.bytes == manifest.assetBytes else {
            throw InstallError("暂存副本与已签名清单不一致：清单 \(manifest.assetSHA256)/\(manifest.assetBytes)，副本 \(stagedDigest.sha256)/\(stagedDigest.bytes)")
        }
        print("暂存副本已核对：\(stagedDigest.bytes) 字节，sha256 \(stagedDigest.sha256)")

        try runInstaller(package: staged)
        try verifyInstallation(manifest: manifest)
        print("安装完成：\(InstallConstants.appBundlePath) 已更新到 \(manifest.version)（build \(manifest.build)）")
    }

    /// 在 root 私有目录建立暂存副本；来源仍从固定缓存路径读取并逐项检查。
    private func stage() throws -> String {
        try InstallFileGuard.requireStagingRoot(InstallConstants.stagingRoot)
        try InstallFileGuard.createPrivateDirectory(stagingDirectory)
        let destination = stagingDirectory + "/" + uuid + ".pkg"
        try InstallFileGuard.copyRegularFile(
            from: packagePath,
            to: destination,
            owner: InstallConstants.cacheOwnerUID,
            maximumBytes: InstallConstants.maximumPackageBytes,
            what: "缓存安装包"
        )
        return destination
    }

    private func runInstaller(package: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: InstallConstants.installerPath)
        process.arguments = ["-pkg", package, "-target", "/"]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/var/root",
            "LC_ALL": "C",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw InstallError("无法启动 \(InstallConstants.installerPath)：\(error.localizedDescription)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            if !text.isEmpty { FileHandle.standardError.write(Data((text + "\n").utf8)) }
            throw InstallError("installer 安装失败（退出码 \(process.terminationStatus)）")
        }
        if !text.isEmpty { print(text) }
    }

    private func verifyInstallation(manifest: UpdateManifest) throws {
        let bundle = try InstallFileGuard.info(InstallConstants.appBundlePath)
        guard (bundle.st_mode & S_IFMT) == S_IFDIR, bundle.st_uid == 0 else {
            throw InstallError("安装后的 app 不是 root 拥有的普通目录：\(InstallConstants.appBundlePath)")
        }
        guard let installed = try InstallGate.installedVersion() else {
            throw InstallError("安装后未找到 \(InstallConstants.appBundlePath)")
        }
        guard installed.bundleID == Product.bundleID else {
            throw InstallError("安装后 app 的 bundle id 不是 \(Product.bundleID)：\(installed.bundleID)")
        }
        guard installed.version == manifest.version, installed.build == manifest.build else {
            throw InstallError("安装后版本与清单不符：期望 \(manifest.version)（build \(manifest.build)），实际 \(installed.version)（build \(installed.buildText)）")
        }
        print("已核对安装结果：\(installed.version)（build \(installed.buildText)）")
    }
}
