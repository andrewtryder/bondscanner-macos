import AppKit
import AVFoundation
import CoreImage
import Foundation
import QuartzCore

final class PreviewView: NSView {
    private let previewSurface = NSView()
    let videoLayer = AVCaptureVideoPreviewLayer()
    let guide = CAShapeLayer()
    let detected = CAShapeLayer()
    let flash = CALayer()
    var sourceSize = CGSize(width: 16, height: 9)

    var onAutoContrastChanged: ((Bool) -> Void)?
    var onManualAdjustmentsChanged: ((Float, Float) -> Void)?
    var onFocusSliderChanged: ((Float) -> Void)?
    var onAutoFocusRequested: (() -> Void)?

    private let hudContainer = NSVisualEffectView()
    private let autoContrastCheckbox = NSButton(checkboxWithTitle: "Auto-Contrast", target: nil, action: nil)
    private let modeValueLabel = NSTextField(labelWithString: "Auto (1.20×)")
    private let brightnessSlider = NSSlider(value: 0.0, minValue: -0.25, maxValue: 0.25, target: nil, action: nil)
    private let brightnessValueLabel = NSTextField(labelWithString: "+0.00")
    private let contrastSlider = NSSlider(value: 1.20, minValue: 0.75, maxValue: 2.20, target: nil, action: nil)
    private let contrastValueLabel = NSTextField(labelWithString: "1.20×")
    private let focusButton = NSButton(title: "AF", target: nil, action: nil)
    private let focusSlider = NSSlider(value: 0.35, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let focusValueLabel = NSTextField(labelWithString: "Auto")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewSurface.wantsLayer = true
        previewSurface.layerUsesCoreImageFilters = true
        previewSurface.autoresizingMask = [.width, .height]
        previewSurface.frame = bounds
        addSubview(previewSurface)

        videoLayer.videoGravity = .resizeAspect
        previewSurface.layer?.addSublayer(videoLayer)

        guide.fillColor = NSColor.clear.cgColor
        guide.strokeColor = NSColor.systemYellow.cgColor
        guide.lineWidth = 3
        guide.lineDashPattern = [14, 8]
        previewSurface.layer?.addSublayer(guide)

        detected.fillColor = NSColor.clear.cgColor
        detected.strokeColor = NSColor.systemGreen.cgColor
        detected.lineWidth = 5
        previewSurface.layer?.addSublayer(detected)

        flash.backgroundColor = NSColor.systemGreen.cgColor
        flash.opacity = 0
        previewSurface.layer?.addSublayer(flash)

        setupHUD()
        applyVideoLayerFilter(contrast: 1.20, brightness: 0.0, sharpness: 0.35)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHUD() {
        hudContainer.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.material = .hudWindow
        hudContainer.blendingMode = .withinWindow
        hudContainer.state = .active
        hudContainer.wantsLayer = true
        hudContainer.layer?.cornerRadius = 10
        hudContainer.layer?.borderWidth = 1
        hudContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        hudContainer.layer?.zPosition = 100
        addSubview(hudContainer)

        autoContrastCheckbox.target = self
        autoContrastCheckbox.action = #selector(handleAutoToggle)
        autoContrastCheckbox.state = .on
        autoContrastCheckbox.controlSize = .small
        autoContrastCheckbox.font = NSFont.systemFont(ofSize: 11, weight: .semibold)

        modeValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        modeValueLabel.textColor = .secondaryLabelColor
        modeValueLabel.alignment = .right

        let topRow = NSStackView(views: [autoContrastCheckbox, NSView(), modeValueLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6

        func configureRowLabel(_ text: String, width: CGFloat) -> NSTextField {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = NSFont.systemFont(ofSize: 11)
            lbl.textColor = .labelColor
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: width).isActive = true
            return lbl
        }

        func configureValueLabel(_ lbl: NSTextField) {
            lbl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .right
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: 42).isActive = true
        }

        brightnessSlider.target = self
        brightnessSlider.action = #selector(handleContrastBrightnessSlider)
        brightnessSlider.controlSize = .small
        brightnessSlider.isContinuous = true
        configureValueLabel(brightnessValueLabel)
        let brightnessRow = NSStackView(views: [configureRowLabel("Brightness", width: 64), brightnessSlider, brightnessValueLabel])
        brightnessRow.orientation = .horizontal
        brightnessRow.alignment = .centerY
        brightnessRow.spacing = 6

        contrastSlider.target = self
        contrastSlider.action = #selector(handleContrastBrightnessSlider)
        contrastSlider.controlSize = .small
        contrastSlider.isContinuous = true
        configureValueLabel(contrastValueLabel)
        let contrastRow = NSStackView(views: [configureRowLabel("Contrast", width: 64), contrastSlider, contrastValueLabel])
        contrastRow.orientation = .horizontal
        contrastRow.alignment = .centerY
        contrastRow.spacing = 6

        focusButton.target = self
        focusButton.action = #selector(handleAutoFocusButton)
        focusButton.bezelStyle = .inline
        focusButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        focusButton.translatesAutoresizingMaskIntoConstraints = false
        focusButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

        focusSlider.target = self
        focusSlider.action = #selector(handleFocusSlider)
        focusSlider.controlSize = .small
        focusSlider.isContinuous = true
        configureValueLabel(focusValueLabel)
        let focusRow = NSStackView(views: [configureRowLabel("Focus", width: 34), focusButton, focusSlider, focusValueLabel])
        focusRow.orientation = .horizontal
        focusRow.alignment = .centerY
        focusRow.spacing = 4

        let stack = NSStackView(views: [topRow, brightnessRow, contrastRow, focusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            hudContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            hudContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hudContainer.widthAnchor.constraint(equalToConstant: 268),

            stack.topAnchor.constraint(equalTo: hudContainer.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: hudContainer.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor, constant: -10),

            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            brightnessRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contrastRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            focusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewSurface.frame = bounds
        videoLayer.frame = previewSurface.bounds
        flash.frame = previewSurface.bounds
        let frame = previewSurface.bounds.insetBy(dx: previewSurface.bounds.width * 0.065, dy: previewSurface.bounds.height * 0.17)
        guide.path = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
        detected.frame = previewSurface.bounds
        CATransaction.commit()
    }

    func showDetected(_ observation: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let b = observation {
            let imageFrame = AVMakeRect(aspectRatio: sourceSize, insideRect: previewSurface.bounds)
            let box = CGRect(x: imageFrame.minX + b.minX * imageFrame.width,
                             y: imageFrame.minY + b.minY * imageFrame.height,
                             width: b.width * imageFrame.width,
                             height: b.height * imageFrame.height)
            detected.path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)
        } else {
            detected.path = nil
        }
        CATransaction.commit()
    }

    func captureFlash(color: NSColor = .systemGreen) {
        flash.removeAllAnimations()
        flash.backgroundColor = color.cgColor
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.6
        animation.toValue = 0
        animation.duration = 0.55
        flash.add(animation, forKey: "capture")
    }

    func applyVideoLayerFilter(contrast: Float, brightness: Float, sharpness: Float) {
        var filters: [CIFilter] = []
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setDefaults()
            colorControls.name = "colorControls"
            colorControls.setValue(contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(1.0, forKey: kCIInputSaturationKey)
            filters.append(colorControls)
        }
        if sharpness > 0.01, let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setDefaults()
            sharpen.name = "sharpenLuminance"
            sharpen.setValue(sharpness, forKey: kCIInputSharpnessKey)
            filters.append(sharpen)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.filters = filters
        CATransaction.commit()
    }

    func reflectAutoContrast(contrast: Float, brightness: Float) {
        contrastSlider.floatValue = contrast
        brightnessSlider.floatValue = brightness
        contrastValueLabel.stringValue = String(format: "%.2f×", contrast)
        brightnessValueLabel.stringValue = String(format: "%+.2f", brightness)
        modeValueLabel.stringValue = String(format: "Auto (%.2f×)", contrast)
        autoContrastCheckbox.state = .on
        applyVideoLayerFilter(contrast: contrast, brightness: brightness, sharpness: focusSlider.floatValue)
    }

    @objc private func handleAutoToggle() {
        let enabled = autoContrastCheckbox.state == .on
        modeValueLabel.stringValue = enabled
            ? String(format: "Auto (%.2f×)", contrastSlider.floatValue)
            : "Manual"
        onAutoContrastChanged?(enabled)
    }

    @objc private func handleContrastBrightnessSlider() {
        let contrast = contrastSlider.floatValue
        let brightness = brightnessSlider.floatValue
        autoContrastCheckbox.state = .off
        modeValueLabel.stringValue = "Manual"
        contrastValueLabel.stringValue = String(format: "%.2f×", contrast)
        brightnessValueLabel.stringValue = String(format: "%+.2f", brightness)
        applyVideoLayerFilter(contrast: contrast, brightness: brightness, sharpness: focusSlider.floatValue)
        onManualAdjustmentsChanged?(contrast, brightness)
    }

    @objc private func handleFocusSlider() {
        let sharpness = focusSlider.floatValue
        focusValueLabel.stringValue = String(format: "%.2f", sharpness)
        applyVideoLayerFilter(contrast: contrastSlider.floatValue, brightness: brightnessSlider.floatValue, sharpness: sharpness)
        onFocusSliderChanged?(sharpness)
    }

    @objc private func handleAutoFocusButton() {
        focusValueLabel.stringValue = "Auto"
        onAutoFocusRequested?()
    }
}
