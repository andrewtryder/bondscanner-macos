import AppKit

/// Compact "pill" showing an SF Symbol, a live count, and a caption (e.g. "12 Verified").
/// Used in the scanner window's status strip in place of one long text line.
final class StatChipView: NSView {
    private let iconView = NSImageView()
    private let valueLabel = NSTextField(labelWithString: "0")
    private let captionLabel: NSTextField
    private let tint: NSColor

    init(symbol: String, caption: String, tint: NSColor) {
        self.tint = tint
        captionLabel = NSTextField(labelWithString: caption)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: caption)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = tint

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .labelColor
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [iconView, valueLabel, captionLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(caption): 0")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Update the displayed count.
    func setValue(_ value: Int) {
        valueLabel.stringValue = "\(value)"
        setAccessibilityLabel("\(captionLabel.stringValue): \(value)")
    }

    /// The tinted background is resolved in updateLayer so it follows light/dark changes.
    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        }
    }
}
