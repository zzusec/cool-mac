# 清凉风扇

Apple Silicon（arm64）、macOS 14+ 的原生右上角菜单栏工具，不占 Dock。当前交付是本地构建版本，硬件支持与真实风扇控制以本机安全自检为准；不能保证机身不发烫。更积极散热会增加噪声和电池消耗，读数是芯片温度，不是机身表面温度。

## 安装与使用

在 [Releases](https://github.com/zzusec/cool-mac/releases) 下载最新 DMG，双击其中的「安装清凉风扇.pkg」，通过 macOS Installer 的系统管理员授权安装。它同时安装 root-owned 的 `/Applications/清凉风扇.app` 与后台组件。也可先拖 app 到 Applications，但控制风扇仍须安装同一 DMG 中的 pkg；pkg 会替换为对应签名的 root-owned app。安装/升级前先退出应用，完成 Installer 后正常打开 app，不从 DMG 常驻运行。

后台默认仅监测。首次启用控制前先退出其他风扇控制工具，再点击「设置 → 安全自检…」；验证短时升速及恢复系统自动后才允许接管。本机已完成真实自检和多个强退/暂停恢复检查，逐项证据见 `VALIDATION.md`，未测项不冒充通过。强力散热最多 2 分钟；可自行启用「登录时启动」。授权固定为本机 UID 501 和本次最终签名的 GUI/CLI。

## 增强转速

「设置 → 增强转速…」打开固定宽度面板，用滑块按 10% 一档在**系统当前转速之上**增加转速，可选关闭或 10%…80%。档位只加不减：目标不低于系统当时要求的转速；所有由本程序下发的目标（含温控曲线与强力散热）都夹在额定上限的 80% 以内。系统停转时基准按最低转速计算，因此非零档位会让风扇保持转动。

Apple Silicon 没有「系统目标 + 偏移」接口，本程序只能接管风扇，接管期间系统不再管理它。因此增强期间会定期交还系统数秒以重新读取基准并确认系统仍能接管；传感器异常、写入或回读不符、实测转速不响应、温度 ≥90°C、热压力严重、检测到其他控制器或界面失联时，一律交还系统自动。此时系统可用满转速，不受 80% 限制。

## 自动升级

应用启动后及每 6 小时自动检查 GitHub Releases（`zzusec/cool-mac`），发现兼容新版会自动下载。更新清单用 Ed25519 签名，包按 SHA-256 与精确长度校验；签名、摘要或版本任一项不符都不会安装。安装通过「设置 → 检查更新…」进行，需 macOS 管理员授权，不承诺免提示静默安装。

安装前会先撤销控制并确认系统自动，未确认就中止。安装由固定的 root-owned 更新工具执行：它只接收本机生成的 UUID，不联网、不接受路径或命令，会先把包复制到 root 私有目录并对副本重新校验，再调用系统安装器。安装完成后需退出并重新打开应用，并重新运行一次安全自检。

发布新版本（本机执行，私钥只存在登录钥匙串，不进入仓库）：

```sh
/Users/hx10/cool-mac/Scripts/release.sh --version 1.1.5 --build 7 --notes <文件>
```

更新工具固定读取 `/Users/hx10/Library/Application Support/CoolMac/Updates`（本机专用路径），该目录属于桌面用户，因此工具必须重新验签与校验副本后才能安装。

异常时点「系统自动」，确认真实恢复后再继续；GUI 失联或后台故障会撤销许可并尝试复位，不把恢复失败显示成成功。驱动或整机失效时不能保证即时复位，必要时重启 Mac 并检查实际转速。只读诊断无需管理员权限：

```sh
"/Applications/清凉风扇.app/Contents/Helpers/coolmacctl" diagnose
```

卸载先使用菜单「卸载后台组件…」并完成系统授权；确认系统自动恢复后再删除 Applications 中的 app，不直接删除仍在工作的 helper。

app 使用 ad-hoc 签名及 Hardened Runtime；pkg 无 Developer ID Installer 证书签名，均未通过 Apple 公证，不是 Apple 官方软件。若被系统阻止，只在确认来源后使用「系统设置 → 隐私与安全性」的系统选项，不关闭 Gatekeeper/SIP，不设置 NOPASSWD，不在脚本中收密码。

## 本机构建

以下脚本仅生成产物，禁止以 root/sudo 执行；安装与启动是独立步骤。固定项目路径为 `/Users/hx10/cool-mac`，构建使用本机 CLT Swift 6、arm64 release、`--jobs 2`。

```sh
/Users/hx10/cool-mac/Scripts/build-app.sh
/Users/hx10/cool-mac/Scripts/package-dmg.sh --skip-build
# 或一次完成构建和打包：
/Users/hx10/cool-mac/Scripts/package-dmg.sh
```

脚本按 helper/CLI → app 顺序签名，严格验证签名及 runtime（无额外 entitlements），签后运行只读 diagnose，再从最终签名自动生成 CDHash manifest。pkg 的 Bom 会校验 root:wheel、不可用户写、helper 755、plist/manifest 644；DMG 会校验并只读挂载检查内容，然后卸载。只清理经过固定路径检查的本项目 dist/staging 产物，不修改系统目录 ACL。

后台固定位置为 `/Library/PrivilegedHelperTools/local.hx10.coolmac.helper`、`/Library/Application Support/CoolMac/identity.plist`、`/Library/LaunchDaemons/local.hx10.coolmac.helper.plist`。升级 preinstall 先验证既有 root-owned 文件和父目录再调用固定 `--prepare-upgrade`；postinstall 只执行新安装的可信 helper `--install-service`，不以 root 启动 GUI。首次没有 helper 可正常安装；恢复或权限检查失败会阻止后续步骤。DMG 候选包生成成功不等于安装、真实控制和故障恢复验收完成。
