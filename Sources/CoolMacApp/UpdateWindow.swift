import AppKit
import CoolMacCore
import CoolMacUpdates

/// A fixed-size window so no long text ever reaches the 220-point status menu.
@MainActor
final class UpdateWindowController: NSWindowController {
    static let size = NSSize(width: 400, height: 250)

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let notesLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let installButton = NSButton(title: "安装并重启…", target: nil, action: nil)
    private let automaticCheckbox = NSButton(checkboxWithTitle: "自动检查更新（每 6 小时）", target: nil, action: nil)

    var onCheck: (() -> Void)?
    var onInstall: ((UpdateManifest) -> Void)?
    var onToggleAutomatic: ((Bool) -> Void)?

    private var manifest: UpdateManifest?

    init() {
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
        window.title = "软件更新"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        guard let content = window.contentView else { return }

        let title = NSTextField(labelWithString: "\(Product.name) \(Product.version)（\(Product.build)）")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 210, width: 360, height: 18)
        content.addSubview(title)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.frame = NSRect(x: 20, y: 182, width: 360, height: 20)
        content.addSubview(statusLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.frame = NSRect(x: 20, y: 140, width: 360, height: 38)
        content.addSubview(detailLabel)

        notesLabel.font = .systemFont(ofSize: 11)
        notesLabel.textColor = .secondaryLabelColor
        notesLabel.maximumNumberOfLines = 3
        notesLabel.lineBreakMode = .byWordWrapping
        notesLabel.frame = NSRect(x: 20, y: 96, width: 360, height: 40)
        content.addSubview(notesLabel)

        automaticCheckbox.frame = NSRect(x: 20, y: 66, width: 360, height: 20)
        automaticCheckbox.target = self
        automaticCheckbox.action = #selector(toggleAutomatic)
        content.addSubview(automaticCheckbox)

        checkButton.frame = NSRect(x: 20, y: 20, width: 110, height: 32)
        checkButton.target = self
        checkButton.action = #selector(check)
        checkButton.keyEquivalent = "\r"
        content.addSubview(checkButton)

        installButton.frame = NSRect(x: 240, y: 20, width: 140, height: 32)
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(install)
        installButton.isEnabled = false
        content.addSubview(installButton)
    }

    required init?(coder: NSCoder) { nil }

    func present(state: UpdateCoordinator.State, automatic: Bool, relativeTo button: NSStatusBarButton?) {
        automaticCheckbox.state = automatic ? .on : .off
        switch state {
        case .idle:
            statusLabel.stringValue = "尚未检查"
            detailLabel.stringValue = "更新包需要发布者签名验证通过后才会安装。"
            notesLabel.stringValue = ""
            manifest = nil
        case .checking:
            statusLabel.stringValue = "正在检查…"
            detailLabel.stringValue = ""
            notesLabel.stringValue = ""
        case .upToDate:
            statusLabel.stringValue = "已是最新版本"
            detailLabel.stringValue = "当前 \(Product.version)（\(Product.build)）。"
            notesLabel.stringValue = ""
            manifest = nil
        case .downloading(let percent):
            statusLabel.stringValue = "正在下载 \(percent)%"
            detailLabel.stringValue = ""
        case .ready(let value):
            statusLabel.stringValue = "发现新版本 \(value.version)（\(value.build)）"
            detailLabel.stringValue = "已下载并通过签名与摘要验证。安装需要 macOS 管理员授权，安装前会先确认风扇已交还系统自动。"
            notesLabel.stringValue = value.notes
            manifest = value
        case .installing:
            statusLabel.stringValue = "正在安装…"
            detailLabel.stringValue = "请按系统提示完成管理员授权。"
        case .installed(let version):
            statusLabel.stringValue = "已安装 \(version)"
            detailLabel.stringValue = "请退出并重新打开\(Product.name)，然后重新运行一次安全自检。"
            notesLabel.stringValue = ""
            manifest = nil
        case .failed(let message):
            statusLabel.stringValue = "更新未完成"
            detailLabel.stringValue = message
            notesLabel.stringValue = ""
            manifest = nil
        }
        installButton.isEnabled = manifest != nil
        let busy: Bool
        switch state {
        case .checking, .installing, .installed: busy = true
        default: busy = false
        }
        checkButton.isEnabled = !busy
        if let window, let button, let screen = button.window?.screen {
            let anchor = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
            let origin = NSPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - Self.size.height - 6)
            window.setFrameOrigin(NSPoint(x: max(screen.visibleFrame.minX + 8, min(origin.x, screen.visibleFrame.maxX - Self.size.width - 8)), y: max(screen.visibleFrame.minY + 8, origin.y)))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func check() { onCheck?() }
    @objc private func install() { if let manifest { onInstall?(manifest) } }
    @objc private func toggleAutomatic() { onToggleAutomatic?(automaticCheckbox.state == .on) }
}
