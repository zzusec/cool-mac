import Foundation

/// 清凉风扇更新清单与发布工具（发布机专用）。
///
/// 只做三件事：生成并保管签名私钥（登录钥匙串）、对安装包签名写出 update.json、
/// 用固定的 gh 上传显式指定的三个文件。不安装、不提权、不执行 git 操作。
@main
struct ReleaseMain {
    static let usage = """
    用法：
      CoolMacRelease keygen [--force]
      CoolMacRelease sign --pkg <安装包> --version <x.y.z> --build <n> --notes <文件或文本> --out <update.json> [--url <https://…>] [--minimum-system <x.y>]
      CoolMacRelease publish --version <x.y.z> --pkg <安装包> --dmg <DMG> --manifest <update.json> --yes

    keygen   生成 Ed25519 私钥并存入登录钥匙串（service "\(ReleaseKeychain.service)"，account "\(ReleaseKeychain.account)"），
             只打印公钥 raw base64（内置到 Sources/CoolMacUpdates/UpdatePublicKey.swift）。已存在则报错，--force 才轮换。
             私钥不写入文件、不打印、不进仓库。
    sign     从钥匙串取私钥，对安装包计算 SHA256 与字节数，构造 payload（assetURL 默认指向
             https://github.com/\(ReleaseManifest.repository)/releases/download/v<version>/<包文件名>），
             签名后写出 update.json，并用 CoolMacUpdates 回验自检。缺少私钥时报错，绝不静默重新生成。
    publish  用固定的 \(ReleasePublish.ghPath) 创建 Release，只上传给出的 pkg、dmg、update.json 三个文件；
             上传前打印确切清单并要求 --yes。不执行 git add，不递归上传目录。

    退出码：0 成功；非 0 表示未完成，错误信息在 stderr。
    """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            guard let command = arguments.first else {
                print(usage)
                exit(2)
            }
            let rest = Array(arguments.dropFirst())
            switch command {
            case "keygen":
                try ReleaseCommands.keygen(try ReleaseArguments(rest, valueKeys: [], flagKeys: ["force"]))
            case "sign":
                try ReleaseCommands.sign(try ReleaseArguments(
                    rest,
                    valueKeys: ["pkg", "version", "build", "notes", "out", "url", "minimum-system"],
                    flagKeys: []
                ))
            case "publish":
                try ReleaseCommands.publish(try ReleaseArguments(
                    rest,
                    valueKeys: ["version", "pkg", "dmg", "manifest"],
                    flagKeys: ["yes"]
                ))
            case "help", "--help", "-h":
                print(usage)
            default:
                throw ReleaseError("未知子命令：\(command)\n\n\(usage)")
            }
        } catch let error as ReleaseError {
            ReleaseOutput.fail(error.description)
        } catch {
            ReleaseOutput.fail(error.localizedDescription)
        }
    }
}
