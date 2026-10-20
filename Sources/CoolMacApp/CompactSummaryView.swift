import AppKit

@MainActor
final class CompactSummaryView: NSView {
    static let width: CGFloat = 220
    private let temperatureLabel = NSTextField(labelWithString: "—°C")
    private let fanLabel = NSTextField(labelWithString: "— RPM")
    private let enhancementLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 36))
        // Every frame is fixed so changing values can never resize the menu.
        temperatureLabel.frame = NSRect(x: 16, y: 8, width: 68, height: 20)
        fanLabel.frame = NSRect(x: 86, y: 8, width: 86, height: 20)
        enhancementLabel.frame = NSRect(x: 174, y: 8, width: 30, height: 20)
        for label in [temperatureLabel, fanLabel, enhancementLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            addSubview(label)
        }
        fanLabel.alignment = .right
        enhancementLabel.alignment = .right
        temperatureLabel.setAccessibilityLabel("芯片温度")
        fanLabel.setAccessibilityLabel("风扇转速")
        enhancementLabel.setAccessibilityLabel("增强档位")
    }

    required init?(coder: NSCoder) { nil }

    func update(temperature: Double?, rpm: Double?, enhancement: Int) {
        let temperatureText = temperature.flatMap { $0.isFinite ? String(format: "%.0f°C", $0) : nil } ?? "—°C"
        let fanText = rpm.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.0f RPM", $0) : nil } ?? "— RPM"
        // "＋" is full width, so only the digits are kept to fit the fixed frame.
        let enhancementText = enhancement > 0 ? "+\(enhancement)%" : ""
        if temperatureLabel.stringValue != temperatureText { temperatureLabel.stringValue = temperatureText }
        if fanLabel.stringValue != fanText { fanLabel.stringValue = fanText }
        if enhancementLabel.stringValue != enhancementText { enhancementLabel.stringValue = enhancementText }
    }
}
