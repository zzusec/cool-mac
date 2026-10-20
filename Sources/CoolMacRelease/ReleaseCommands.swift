import CoolMacUpdates
import CryptoKit
import Foundation

enum ReleaseCommands {
    /// 生成 Ed25519 私钥存入登录钥匙串，只打印公钥。
    static func keygen(_ arguments: ReleaseArguments) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        try ReleaseKeychain.store(privateKey, force: arguments.has("force"))
        ReleaseOutput.note("更新私钥已存入登录钥匙串：service \(ReleaseKeychain.service)，account \(ReleaseKeychain.account)")
        ReleaseOutput.note("私钥未写入任何文件，也不会被打印；如丢失只能重新 keygen 并重新内置公钥。")
        ReleaseOutput.note("公钥（32 字节 raw 的 base64，请内置到 Sources/CoolMacUpdates/UpdatePublicKey.swift）：")
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())
    }

    /// 对安装包计算摘要并签名，写出 update.json。
    static func sign(_ arguments: ReleaseArguments) throws {
        let packagePath = try arguments.require("pkg")
        let version = try arguments.require("version")
        let buildText = try arguments.require("build")
        let notesArgument = try arguments.require("notes")
        let outputPath = try arguments.require("out")
        try ReleaseManifest.validateDottedVersion(version, what: "--version")
        guard let build = Int(buildText), build >= 1 else {
            throw ReleaseError("--build 必须是正整数：\(buildText)")
        }
        let minimumSystem = arguments.value("minimum-system") ?? ReleaseManifest.defaultMinimumSystemVersion
        try ReleaseManifest.validateDottedVersion(minimumSystem, what: "--minimum-system")
        // 先校验全部输入（含 pkg 摘要与 URL），最后才取私钥：缺私钥仍然报错，
        // 但输入错误不会因为钥匙串状态而被掩盖。
        try ReleaseFile.requireRegularFile(packagePath, what: "安装包")
        let notes = try resolveNotes(notesArgument)
        let digest = try ReleaseFile.digest(packagePath)
        let urlText = try arguments.value("url")
            ?? ReleaseManifest.defaultAssetURL(version: version, packagePath: packagePath)
        let assetURL = try ReleaseManifest.validateAssetURL(urlText, packagePath: packagePath)
        guard let privateKey = try ReleaseKeychain.loadPrivateKey() else {
            throw ReleaseError("登录钥匙串中没有更新私钥（service \(ReleaseKeychain.service) account \(ReleaseKeychain.account)）；请先运行 keygen。本工具不会自动生成或覆盖私钥。")
        }

        let payload = ReleasePayload(
            architectures: ["arm64"],
            assetBytes: digest.bytes,
            assetSHA256: digest.sha256,
            assetURL: assetURL.absoluteString,
            build: build,
            bundleID: ReleaseManifest.bundleID,
            minimumSystemVersion: minimumSystem,
            notes: notes,
            schema: ReleaseManifest.schema,
            version: version
        )
        let envelope = try ReleaseManifest.envelope(payload: payload, privateKey: privateKey)
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let verified = try ReleaseManifest.selfCheck(envelope, publicKeyBase64: publicKeyBase64)
        guard verified.schema == ReleaseManifest.schema,
              verified.bundleID == ReleaseManifest.bundleID,
              verified.version == version,
              verified.build == build,
              verified.assetSHA256 == digest.sha256,
              verified.assetBytes == digest.bytes,
              verified.notes == notes
        else {
            throw ReleaseError("自检结果与待签名内容不一致，已放弃写出清单")
        }
        try ReleaseFile.write(envelope, to: outputPath)

        ReleaseOutput.note("清单已写出并通过 CoolMacUpdates 验签自检：\(outputPath)")
        ReleaseOutput.note("  版本：\(version)（build \(build)）")
        ReleaseOutput.note("  架构：arm64，最低系统：macOS \(minimumSystem)")
        ReleaseOutput.note("  资产：\(packagePath)")
        ReleaseOutput.note("  字节：\(digest.bytes)")
        ReleaseOutput.note("  SHA256：\(digest.sha256)")
        ReleaseOutput.note("  URL：\(assetURL.absoluteString)")
        ReleaseOutput.note("签名私钥来自登录钥匙串，未落盘。下一步：CoolMacRelease publish --version \(version) --pkg \(packagePath) --dmg <dmg> --manifest \(outputPath) --yes")
    }

    /// 创建 Release 并只上传显式给出的三个文件。
    static func publish(_ arguments: ReleaseArguments) throws {
        let version = try arguments.require("version")
        let packagePath = try arguments.require("pkg")
        let diskImagePath = try arguments.require("dmg")
        let manifestPath = try arguments.require("manifest")
        try ReleaseManifest.validateDottedVersion(version, what: "--version")
        guard ReleaseFile.basename(manifestPath) == "update.json" else {
            throw ReleaseError("--manifest 的文件名必须是 update.json（App 按固定名称拉取）：\(manifestPath)")
        }
        let package = try ReleasePublish.asset(packagePath, what: "安装包", suffix: ".pkg")
        let diskImage = try ReleasePublish.asset(diskImagePath, what: "DMG", suffix: ".dmg")
        let manifest = try ReleasePublish.asset(manifestPath, what: "更新清单", suffix: ".json")
        guard ReleaseFile.basename(diskImagePath).contains(version) else {
            throw ReleaseError("DMG 文件名不含版本 \(version)，可能是旧产物：\(diskImagePath)")
        }

        let payload = try loadPayload(manifestPath)
        if let privateKey = try ReleaseKeychain.loadPrivateKey() {
            let verified = try ReleaseManifest.loadVerified(
                manifestPath,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
            guard verified.schema == payload.schema,
                  verified.bundleID == payload.bundleID,
                  verified.version == payload.version,
                  verified.build == payload.build,
                  verified.assetSHA256 == payload.assetSHA256,
                  verified.assetBytes == payload.assetBytes,
                  verified.notes == payload.notes
            else {
                throw ReleaseError("update.json 经 CoolMacUpdates 解码后与原始负载不一致，拒绝上传")
            }
            ReleaseOutput.note("update.json 已用 CoolMacUpdates 重新验签通过。")
        } else {
            ReleaseOutput.note("警告：登录钥匙串中没有更新私钥，未能在上传前重新验签 update.json（仍会核对版本与摘要）。")
        }
        guard payload.version == version else {
            throw ReleaseError("update.json 的版本（\(payload.version)）与 --version（\(version)）不一致")
        }
        guard payload.bundleID == ReleaseManifest.bundleID else {
            throw ReleaseError("update.json 的 bundleID 不是 \(ReleaseManifest.bundleID)：\(payload.bundleID)")
        }
        guard payload.assetSHA256 == package.sha256, payload.assetBytes == package.bytes else {
            throw ReleaseError("update.json 记录的摘要与安装包不符：清单 \(payload.assetSHA256)/\(payload.assetBytes)，实际 \(package.sha256)/\(package.bytes)")
        }
        guard let assetURL = URL(string: payload.assetURL), assetURL.lastPathComponent == ReleaseFile.basename(packagePath) else {
            throw ReleaseError("update.json 的 assetURL 文件名与安装包不一致：\(payload.assetURL)")
        }

        ReleaseOutput.note("即将在 \(ReleaseManifest.repository) 创建 Release v\(version)，并上传以下 3 个文件（仅这三个）：")
        ReleaseOutput.note("  1) 安装包 \(package.display)")
        ReleaseOutput.note("  2) DMG   \(diskImage.display)")
        ReleaseOutput.note("  3) 清单  \(manifest.display)")
        ReleaseOutput.note("更新说明：\(payload.notes)")
        ReleaseOutput.note("本工具不执行任何 git 操作，不递归上传目录，不上传 identity.plist 或其他产物。")
        guard arguments.has("yes") else {
            throw ReleaseError("未指定 --yes，已取消上传；以上文件均未上传")
        }
        try ReleasePublish.run(version: version, notes: payload.notes, assets: [package, diskImage, manifest])
    }

    /// `--notes` 既接受文件路径也接受字面文本；路径存在但不是普通文件时直接报错，不静默当作文本。
    static func resolveNotes(_ value: String) throws -> String {
        if let info = try ReleaseFile.infoIfPresent(value) {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw ReleaseError("--notes 指向的不是普通文件：\(value)")
            }
            let data = try ReleaseFile.read(value, what: "更新说明")
            guard let text = String(data: data, encoding: .utf8) else {
                throw ReleaseError("更新说明文件不是 UTF-8 文本：\(value)")
            }
            return try requireNonEmptyNotes(text, source: value)
        }
        return try requireNonEmptyNotes(value, source: "命令行文本")
    }

    private static func requireNonEmptyNotes(_ text: String, source: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReleaseError("更新说明为空（来源：\(source)）")
        }
        return trimmed
    }

    /// 直接解码 update.json（不验签），用于上传前核对版本与摘要。
    static func loadPayload(_ path: String) throws -> ReleasePayload {
        let data = try ReleaseFile.read(path, what: "更新清单")
        let envelope: ReleaseEnvelope
        do {
            envelope = try JSONDecoder().decode(ReleaseEnvelope.self, from: data)
        } catch {
            throw ReleaseError("update.json 不是合法的信封 JSON：\(error.localizedDescription)")
        }
        guard let payloadData = Data(base64Encoded: envelope.payload) else {
            throw ReleaseError("update.json 的 payload 不是合法 base64")
        }
        do {
            return try JSONDecoder().decode(ReleasePayload.self, from: payloadData)
        } catch {
            throw ReleaseError("update.json 的 payload 不是合法负载：\(error.localizedDescription)")
        }
    }
}
