import Foundation
import AppKit
import AVFoundation
import QuartzCore

final class PreviewView: NSView {
    let videoLayer = AVCaptureVideoPreviewLayer()
    let guide = CAShapeLayer()
    let detected = CAShapeLayer()
    let flash = CALayer()
    var sourceSize = CGSize(width: 16, height: 9)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
        guide.fillColor = NSColor.clear.cgColor
        guide.strokeColor = NSColor.systemYellow.cgColor
        guide.lineWidth = 3
        guide.lineDashPattern = [14, 8]
        layer?.addSublayer(guide)
        detected.fillColor = NSColor.clear.cgColor
        detected.strokeColor = NSColor.systemGreen.cgColor
        detected.lineWidth = 5
        layer?.addSublayer(detected)
        flash.backgroundColor = NSColor.systemGreen.cgColor
        flash.opacity = 0
        layer?.addSublayer(flash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        flash.frame = bounds
        let frame = bounds.insetBy(dx: bounds.width * 0.065, dy: bounds.height * 0.17)
        guide.path = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
        detected.frame = bounds
        CATransaction.commit()
    }

    func showDetected(_ observation: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let b = observation {
            let imageFrame = AVMakeRect(aspectRatio: sourceSize, insideRect: bounds)
            let box = CGRect(x: imageFrame.minX + b.minX * imageFrame.width,
                             y: imageFrame.minY + b.minY * imageFrame.height,
                             width: b.width * imageFrame.width,
                             height: b.height * imageFrame.height)
            detected.path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)
        } else { detected.path = nil }
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
}
