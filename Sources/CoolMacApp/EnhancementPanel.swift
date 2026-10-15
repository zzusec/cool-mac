import AppKit
import CoolMacCore

/// A fixed-size panel for the enhancement step. It is a separate window so the
/// status menu keeps its 220-point width and no long text is ever put in a menu.
@MainActor
final class EnhancementPanelController: NSWindowController {
    static let size = NSSize(width: 360, height: 246)

    private let slider = NSSlider(value: 0, minValue: 0, maxValue: Double(Enhancement.steps.count - 1), target: nil, action: nil)
    private let stepLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let baselineLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "在系统当前转速上增加；最高不超过额定上限的 80%。系统停转时按最低转速计算。接管期间不会低于系统要求的转速，异常时交还系统自动。")
    var onChange: ((Int) -> Void)?

    private var selectedIndex: Int {
        get { Int(slider.doubleValue.rounded()) }
        set { slider.doubleValue = Double(min(max(newValue, 0), Enhancement.steps.count - 1)) }
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "增强转速"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init(window: panel)

        guard let content = panel.contentView else { return }
        let title = NSTextField(labelWithString: "增强转速")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 20, y: 200, width: 200, height: 20)
        content.addSubview(title)

        stepLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        stepLabel.frame = NSRect(x: 20, y: 164, width: 320, height: 28)
        content.addSubview(stepLabel)

        slider.frame = NSRect(x: 20, y: 132, width: 320, height: 24)
        slider.numberOfTickMarks = Enhancement.steps.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel("增强档位")
        content.addSubview(slider)

        let ticks = NSTextField(labelWithString: "关闭    10%   20%   30%   40%   50%   60%   70%   80%")
        ticks.font = .systemFont(ofSize: 9)
        ticks.textColor = .secondaryLabelColor
        ticks.frame = NSRect(x: 20, y: 114, width: 320, height: 14)
        content.addSubview(ticks)

        for (label, y) in [(detailLabel, 86.0), (baselineLabel, 66.0)] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 20, y: y, width: 320, height: 16)
            content.addSubview(label)
        }

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.maximumNumberOfLines = 4
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.frame = NSRect(x: 20, y: 16, width: 320, height: 46)
        content.addSubview(noteLabel)

        render(enhancement: 0, baseline: nil, commanded: nil, ceiling: nil)
    }

    required init?(coder: NSCoder) { nil }

    func present(enhancement: Int, baseline: Double?, commanded: Double?, ceiling: Double?, relativeTo button: NSStatusBarButton?) {
        selectedIndex = Enhancement.steps.firstIndex(of: enhancement) ?? 0
        render(enhancement: enhancement, baseline: baseline, commanded: commanded, ceiling: ceiling)
        if let window, let button, let screen = button.window?.screen {
            let anchor = button.window!.convertToScreen(button.convert(button.bounds, to: nil))
            let origin = NSPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - Self.size.height - 6)
            window.setFrameOrigin(NSPoint(x: max(screen.visibleFrame.minX + 8, min(origin.x, screen.visibleFrame.maxX - Self.size.width - 8)), y: max(screen.visibleFrame.minY + 8, origin.y)))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh(baseline: Double?, commanded: Double?, ceiling: Double?) {
        render(enhancement: Enhancement.steps[selectedIndex], baseline: baseline, commanded: commanded, ceiling: ceiling)
    }

    private func render(enhancement: Int, baseline: Double?, commanded: Double?, ceiling: Double?) {
        stepLabel.stringValue = enhancement == 0 ? "关闭增强（系统自动）" : "＋\(enhancement)%"
        if enhancement == 0 {
            detailLabel.stringValue = "风扇完全交由系统自动控制。"
        } else if let baseline, baseline.isFinite, baseline > 0 {
            let requested = baseline * (1 + Double(enhancement) / 100)
            let capped = ceiling.map { min(requested, $0) } ?? requested
            detailLabel.stringValue = "系统基准 \(Int(baseline)) RPM → 目标约 \(Int(max(capped, baseline))) RPM"
        } else {
            detailLabel.stringValue = "等待系统基准读数…"
        }
        if let commanded, commanded.isFinite {
            baselineLabel.stringValue = "当前下发目标 \(Int(commanded)) RPM"
        } else {
            baselineLabel.stringValue = "当前未接管，风扇由系统控制"
        }
    }

    @objc private func sliderChanged() {
        let enhancement = Enhancement.steps[selectedIndex]
        render(enhancement: enhancement, baseline: nil, commanded: nil, ceiling: nil)
        onChange?(enhancement)
    }
}
