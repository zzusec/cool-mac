# 清凉风扇

本机 Mac14,7 / Apple M2 的原生 macOS 菜单栏风扇工具。交付 DMG，菜单栏常驻、不占 Dock。

## 安全与范围

- 不修改 SIP、系统热保护、电源模式，不调用现有 Macs Fan Control helper。
- 测试默认无硬件副作用；真实写入只能由经过正常管理员授权安装的 root-owned helper 执行。
- 不收集密码，不改 sudoers，不提供任意命令、路径、SMC key 或 RPM 的特权 IPC。
- 未知传感器/类型、过期数据、写入或回读失败必须可见；不能显示伪成功。
- 先验证恢复系统自动，再允许接管；监督进程与可替换 SMC worker 隔离。
- helper 和 GUI 单进程故障需要真实验证恢复，驱动/整机失效不承诺即时复位。
- 控制冲突停止争用，不终止或卸载其他软件。
- 所有下发目标夹在额定上限的 80% 以内（含温控曲线与强力散热）；档位只加不减，绝不低于系统要求的转速。
- 增强档位由 root worker 校验，不只依赖界面；异常一律交还系统自动。
- 只有应用 GUI 联网，风扇 helper 不联网、不接受 URL/路径/命令。
- 更新由已常驻的 root 后台执行（界面只传本机 UUID），因此更新不再要求管理员密码；后台仍会重新验签、拒降级、用 root 私有暂存目录核对副本后才调用系统安装器。
- 后台派生子进程时，argv 里每个字符串都必须来自 `withCString`；对 Swift 字符串做隐式指针转换得到的指针在那一行结束即失效，会传出坏参数。
- 更新包必须先通过 Ed25519 清单签名与 SHA-256 校验；特权安装工具只收本机 UUID，重验签并对 root 私有副本核对后才调用系统安装器。
- 私钥只存登录钥匙串，不写入项目、不打印、不上传。

## 工程

SwiftPM，Swift 6，macOS 14+，arm64。系统框架为 AppKit、IOKit、Security、ServiceManagement、CryptoKit。风扇后台无网络；仅更新检查使用 URLSession。

`Scripts/test-core.sh` 是纯测试入口；`swift build -c release` 构建。`Scripts/build-app.sh` 组装签名 app；`Scripts/package-dmg.sh` 打包；`Scripts/release.sh` 签名清单并发布。打包、安装与启动分开，不静默修改系统。

## 协作范围

Core 策略/测试、CIPC 客户端、硬件层/worker、UI/打包分开编辑。并行代理不得修改未分配文件或执行 sudo、安装服务、SMC 写入。主代理整合及最终验证。
