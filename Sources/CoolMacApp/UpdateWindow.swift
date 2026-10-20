import AppKit
import CoolMacCore
import CoolMacUpdates

/// A fixed-size window so no long text ever reaches the 220-point status menu.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 400, height: 250)

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let notesLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let installButton = NSButton(title: "安装并重启…", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let automaticCheckbox = NSButton(checkboxWithTitle: "自动下载并安装更新（每 6 小时检查）", target: nil, action: nil)

    var onCheck: (() -> Void)?
    var onInstall: ((UpdateManifest) -> Void)?
    var onToggleAutomatic: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private var manifest: UpdateManifest?

    init() {
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable],
                             backing: .buffered,
                             defer: false)
        window.title = "软件更新"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        guard let content = window.contentView else { return }

        let title = NSTextField(labelWithString: "\(Product.name) · 当前 \(Product.version)（构建 \(Product.build)）")
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

        progressBar.frame = NSRect(x: 20, y: 104, width: 360, height: 12)
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.controlSize = .small
        progressBar.isHidden = true
        progressBar.setAccessibilityLabel("下载进度")
        content.addSubview(progressBar)

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

    func render(state: UpdateCoordinator.State, automatic: Bool) {
        manifest = nil
        notesLabel.stringValue = ""
        automaticCheckbox.state = automatic ? .on : .off
        automaticCheckbox.isEnabled = true
        switch state {
        case .idle:
            statusLabel.stringValue = "尚未检查"
            detailLabel.stringValue = "更新包需要发布者签名验证通过后才会安装。"
        case .checking:
            statusLabel.stringValue = "正在检查…"
            detailLabel.stringValue = ""
        case .upToDate:
            statusLabel.stringValue = "已是最新版本"
            detailLabel.stringValue = "当前 \(Product.version)（构建 \(Product.build)）。"
        case .downloading(let percent):
            statusLabel.stringValue = "正在下载 \(percent)%"
            detailLabel.stringValue = "下载完成后会校验签名与摘要；安装前先安全交还系统自动。"
        case .ready(let value):
            statusLabel.stringValue = "发现新版本 \(value.version)（构建 \(value.build)）"
            detailLabel.stringValue = "已通过签名与摘要验证。安装前会确认风扇已交还系统自动，再由后台安装并自动重启应用。"
            notesLabel.stringValue = value.notes
            manifest = value
        case .installing:
            statusLabel.stringValue = "正在安装…"
            detailLabel.stringValue = "正在安全交还系统自动并由后台安装，完成后会自动重启应用，无需额外管理员授权。"
            automaticCheckbox.isEnabled = false
        case .installed(let version):
            statusLabel.stringValue = "已安装 \(version)"
            detailLabel.stringValue = "即将自动重启\(Product.name)。重启后请重新运行安全自检。"
        case .failed(let message):
            statusLabel.stringValue = "更新未完成"
            detailLabel.stringValue = message
        }
        if case .downloading(let percent) = state {
            progressBar.isHidden = false
            progressBar.doubleValue = Double(percent)
        } else {
            progressBar.isHidden = true
        }
        installButton.isEnabled = manifest != nil
        let busy: Bool
        switch state {
        case .checking, .downloading, .installing, .installed: busy = true
        default: busy = false
        }
        checkButton.isEnabled = !busy
    }

    func present(state: UpdateCoordinator.State, automatic: Bool, relativeTo button: NSStatusBarButton?) {
        render(state: state, automatic: automatic)
        if let window, let button, let screen = button.window?.screen {
            let anchor = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
            let origin = NSPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - Self.size.height - 6)
            window.setFrameOrigin(NSPoint(x: max(screen.visibleFrame.minX + 8, min(origin.x, screen.visibleFrame.maxX - Self.size.width - 8)), y: max(screen.visibleFrame.minY + 8, origin.y)))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func check() { onCheck?() }
    @objc private func install() { if let manifest { onInstall?(manifest) } }
    @objc private func toggleAutomatic() { onToggleAutomatic?(automaticCheckbox.state == .on) }
}
