import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

let ciContext = CIContext(options: [.useSoftwareRenderer: false])

struct ImageEnhancementSettings {
    var autoContrastEnabled: Bool = true
    var manualContrast: Float = 1.20       // Range: 0.75 ... 2.20
    var manualBrightness: Float = 0.00     // Range: -0.25 ... 0.25
    var manualSharpness: Float = 0.35      // Range: 0.00 ... 1.00 (Focus assist / edge sharpness)
}

final class EnhancementController {
    static let shared = EnhancementController()
    private let lock = NSLock()
    private var _settings = ImageEnhancementSettings()
    private var _lastAutoParameters: (contrast: Float, brightness: Float) = (1.20, 0.0)

    var settings: ImageEnhancementSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    var lastAutoParameters: (contrast: Float, brightness: Float) {
        get { lock.lock(); defer { lock.unlock() }; return _lastAutoParameters }
        set { lock.lock(); _lastAutoParameters = newValue; lock.unlock() }
    }

    func update(_ mutate: (inout ImageEnhancementSettings) -> Void) {
        lock.lock()
        mutate(&_settings)
        lock.unlock()
    }
}

private func resolvedSampleExtent(for fullExtent: CGRect, region: CGRect?) -> CGRect {
    if let r = region {
        let candidate: CGRect
        if r.width <= 1.05 && r.height <= 1.05 && r.minX >= -0.05 && r.minY >= -0.05 && r.width > 0.05 && r.height > 0.05 {
            candidate = CGRect(
                x: fullExtent.minX + r.minX * fullExtent.width,
                y: fullExtent.minY + r.minY * fullExtent.height,
                width: r.width * fullExtent.width,
                height: r.height * fullExtent.height
            ).intersection(fullExtent)
        } else {
            candidate = r.intersection(fullExtent)
        }
        if !candidate.isNull && !candidate.isEmpty && candidate.width >= 16 && candidate.height >= 16 {
            return candidate
        }
    }
    let inset = fullExtent.insetBy(dx: fullExtent.width * 0.10, dy: fullExtent.height * 0.10)
    return inset.width >= 16 && inset.height >= 16 ? inset : fullExtent
}

private func applyEnhancementFilters(_ image: CGImage, contrast: Float, brightness: Float, saturation: Float, sharpness: Float) -> CGImage? {
    let original = CIImage(cgImage: image)
    let controls = CIFilter.colorControls()
    controls.inputImage = original
    controls.contrast = contrast
    controls.brightness = brightness
    controls.saturation = saturation
    guard let toned = controls.outputImage else { return nil }
    let sharpen = CIFilter.sharpenLuminance()
    sharpen.inputImage = toned
    sharpen.sharpness = sharpness
    let final = sharpen.outputImage ?? toned
    return ciContext.createCGImage(final, from: original.extent)
}

/// Computes adaptive contrast and brightness parameters by sampling luminance
/// min/max and average within `region` (normalized Vision box or pixel rect).
func computeAutoContrastParameters(_ image: CGImage, region: CGRect? = nil) -> (contrast: Float, brightness: Float) {
    let ciImage = CIImage(cgImage: image)
    let fullExtent = ciImage.extent
    guard !fullExtent.isEmpty else { return (1.20, 0.0) }
    let sampleExtent = resolvedSampleExtent(for: fullExtent, region: region)
    let extentVector = CIVector(cgRect: sampleExtent)

    guard let minMaxFilter = CIFilter(name: "CIAreaMinMax", parameters: [
        kCIInputImageKey: ciImage,
        kCIInputExtentKey: extentVector
    ]),
    let minMaxOut = minMaxFilter.outputImage,
    let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
        kCIInputImageKey: ciImage,
        kCIInputExtentKey: extentVector
    ]),
    let avgOut = avgFilter.outputImage else {
        return (1.20, 0.0)
    }

    let rgb = CGColorSpaceCreateDeviceRGB()
    var minMaxBuf = [UInt8](repeating: 0, count: 8)
    minMaxBuf.withUnsafeMutableBytes { rawPtr in
        if let base = rawPtr.baseAddress {
            ciContext.render(
                minMaxOut,
                toBitmap: base,
                rowBytes: 8,
                bounds: CGRect(x: 0, y: 0, width: 2, height: 1),
                format: .RGBA8,
                colorSpace: rgb
            )
        }
    }

    var avgBuf = [UInt8](repeating: 0, count: 4)
    avgBuf.withUnsafeMutableBytes { rawPtr in
        if let base = rawPtr.baseAddress {
            ciContext.render(
                avgOut,
                toBitmap: base,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: rgb
            )
        }
    }

    let lMin = (0.299 * Float(minMaxBuf[0]) + 0.587 * Float(minMaxBuf[1]) + 0.114 * Float(minMaxBuf[2])) / 255.0
    let lMax = (0.299 * Float(minMaxBuf[4]) + 0.587 * Float(minMaxBuf[5]) + 0.114 * Float(minMaxBuf[6])) / 255.0
    let lAvg = (0.299 * Float(avgBuf[0]) + 0.587 * Float(avgBuf[1]) + 0.114 * Float(avgBuf[2])) / 255.0

    let lPaper = 0.60 * lAvg + 0.40 * lMax
    let lInk = 0.65 * lMin + 0.35 * lAvg
    let deltaL = max(Float(0.08), lPaper - lInk)

    let rawContrast = 0.52 / deltaL
    let contrast = min(Float(2.10), max(Float(1.12), rawContrast))
    let rawBrightness = (0.56 - lAvg) * 0.28
    let brightness = min(Float(0.08), max(Float(-0.10), rawBrightness))

    EnhancementController.shared.lastAutoParameters = (contrast, brightness)
    return (contrast, brightness)
}

func autoContrastAdjustedImage(_ image: CGImage, region: CGRect? = nil) -> CGImage? {
    let params = computeAutoContrastParameters(image, region: region)
    let sharpness = EnhancementController.shared.settings.manualSharpness
    return applyEnhancementFilters(image, contrast: params.contrast, brightness: params.brightness, saturation: 0.15, sharpness: sharpness)
}

func effectiveEnhancedImage(_ image: CGImage, region: CGRect? = nil) -> CGImage? {
    let cfg = EnhancementController.shared.settings
    if cfg.autoContrastEnabled {
        return autoContrastAdjustedImage(image, region: region)
    }
    return applyEnhancementFilters(image, contrast: cfg.manualContrast, brightness: cfg.manualBrightness, saturation: 0.25, sharpness: cfg.manualSharpness)
}

func upscaledImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let source = CIImage(cgImage: image)
    let lanczos = CIFilter.lanczosScaleTransform()
    lanczos.inputImage = source
    lanczos.scale = Float(scale)
    lanczos.aspectRatio = 1
    guard let scaled = lanczos.outputImage else { return nil }
    let contrast = CIFilter.colorControls()
    contrast.inputImage = scaled
    contrast.contrast = 1.45
    contrast.saturation = 0
    contrast.brightness = 0.03
    let sharpen = CIFilter.sharpenLuminance()
    sharpen.inputImage = contrast.outputImage
    sharpen.sharpness = 0.45
    guard let final = sharpen.outputImage else { return ciContext.createCGImage(scaled, from: scaled.extent) }
    return ciContext.createCGImage(final, from: final.extent)
}

func cornerCrops(_ image: CGImage) -> [CGImage] {
    let w = image.width, h = image.height
    let cw = max(80, Int(Double(w) * 0.32))
    let ch = max(80, Int(Double(h) * 0.38))
    let rects = [
        CGRect(x: 0, y: 0, width: cw, height: ch),
        CGRect(x: w - cw, y: 0, width: cw, height: ch),
        CGRect(x: 0, y: h - ch, width: cw, height: ch),
        CGRect(x: w - cw, y: h - ch, width: cw, height: ch)
    ]
    return rects.compactMap { image.cropping(to: $0) }
}

func centerBandCrop(_ image: CGImage) -> CGImage? {
    let w = image.width, h = image.height
    let rect = CGRect(
        x: Int(Double(w) * 0.06),
        y: Int(Double(h) * 0.25),
        width: Int(Double(w) * 0.88),
        height: Int(Double(h) * 0.50)
    )
    return image.cropping(to: rect)
}

func visionBoxToCG(_ box: CGRect, image: CGImage) -> CGRect {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    return CGRect(x: box.minX * w, y: (1 - box.maxY) * h,
                  width: box.width * w, height: box.height * h)
}

func highContrastImage(_ image: CGImage, contrast: Float, brightness: Float = 0) -> CGImage? {
    let controls = CIFilter.colorControls()
    controls.inputImage = CIImage(cgImage: image)
    controls.contrast = contrast
    controls.brightness = brightness
    controls.saturation = 0
    guard let out = controls.outputImage else { return nil }
    return ciContext.createCGImage(out, from: out.extent)
}

func dateBoxVariants(_ crop: CGImage, intensive: Bool) -> [(String, CGImage)] {
    var out: [(String, CGImage)] = [("raw", crop)]
    if let up2 = upscaledImage(crop, scale: 2.2) { out.append(("up2", up2)) }
    if let up3 = upscaledImage(crop, scale: 3.0) { out.append(("up3", up3)) }
    if let faint = adjustedForFaintPrinting(crop) {
        out.append(("faint", faint))
        if let fu = upscaledImage(faint, scale: 2.6) { out.append(("faint-up", fu)) }
    }
    if let auto = autoContrastAdjustedImage(crop, region: nil) {
        out.append(("auto", auto))
        if let au = upscaledImage(auto, scale: 2.6) { out.append(("auto-up", au)) }
    }
    if let hi = highContrastImage(crop, contrast: 1.7, brightness: 0.05) {
        out.append(("hi", hi))
        if let hu = upscaledImage(hi, scale: 2.5) { out.append(("hi-up", hu)) }
    }
    if intensive {
        if let up4 = upscaledImage(crop, scale: 3.6) { out.append(("up4", up4)) }
        if let darker = highContrastImage(crop, contrast: 2.0, brightness: -0.08),
           let du = upscaledImage(darker, scale: 3.0) {
            out.append(("dark-up", du))
        }
    }
    return out
}

func rotateCG(_ cg: CGImage, exif: Int) -> CGImage? {
    let image = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(exif))
    return ciContext.createCGImage(image, from: image.extent)
}

/// Pixel-space aspect (longer/shorter) of a Vision rectangle. Normalized
/// bounding boxes are not usable for aspect: they ignore the image's 16:9 shape.
func rectanglePixelGeometry(_ rectangle: VNRectangleObservation, image: CGImage) -> (width: CGFloat, height: CGFloat, aspect: CGFloat, areaFraction: CGFloat) {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    let rw = (dist(pt(rectangle.topLeft), pt(rectangle.topRight)) + dist(pt(rectangle.bottomLeft), pt(rectangle.bottomRight))) / 2
    let rh = (dist(pt(rectangle.topLeft), pt(rectangle.bottomLeft)) + dist(pt(rectangle.topRight), pt(rectangle.bottomRight))) / 2
    let longS = max(rw, rh)
    let shortS = max(min(rw, rh), 1)
    let area = rw * rh
    return (rw, rh, longS / shortS, area / (w * h))
}

/// US Series E/EE paper bonds are about 2.1–2.4:1. A 12-inch ruler is long and
/// thin (often 8:1 or more) and must not win over the bond.
func bondRectangleScore(_ rectangle: VNRectangleObservation, image: CGImage) -> Double {
    let g = rectanglePixelGeometry(rectangle, image: image)
    // Reject ruler-like strips and tiny scraps.
    if g.aspect > 3.6 || g.aspect < 1.45 { return -1 }
    if g.areaFraction < 0.08 || g.areaFraction > 0.92 { return -1 }
    if g.width < 400 || g.height < 160 { return -1 }
    var score = Double(rectangle.confidence) * 4
    let aspectError = abs(g.aspect - 2.25)
    if g.aspect >= 2.05 && g.aspect <= 2.50 { score += 14 - aspectError * 10 }
    else if g.aspect >= 1.80 && g.aspect <= 2.85 { score += 7 - aspectError * 4 }
    else { score += 1 }
    if g.areaFraction >= 0.12 && g.areaFraction <= 0.72 { score += 5 }
    score += min(Double(g.areaFraction), 0.6) * 3
    return score
}

// Read broad potential outlines (front/back, rotated, different denominations).
// Prefer a bond-shaped rectangle (~2.1–2.4:1) over a long thin ruler.
func rectangleCandidates(_ image: CGImage) -> [VNRectangleObservation] {
    let request = VNDetectRectanglesRequest()
    // Detection is slightly broader than the bond window so perspective-skewed
    // bonds still appear; bondRectangleScore then drops rulers.
    request.minimumAspectRatio = 0.22
    request.maximumAspectRatio = 0.90
    request.minimumSize = 0.12
    request.minimumConfidence = 0.18
    request.quadratureTolerance = 43
    request.maximumObservations = 12
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
    catch { ScanLog.shared.write("rectangle detection exception; falling back to text"); return [] }
    let scored = (request.results ?? []).map { ($0, bondRectangleScore($0, image: image)) }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
    if !scored.isEmpty {
        let g = rectanglePixelGeometry(scored[0].0, image: image)
        ScanLog.shared.write("bond rectangle picked aspect=\(String(format: "%.2f", g.aspect)) area=\(String(format: "%.2f", g.areaFraction)) score=\(String(format: "%.1f", scored[0].1)) of \(scored.count)")
    }
    return scored.map { $0.0 }
}

func rectify(_ image: CGImage, using rectangle: VNRectangleObservation) -> CGImage? {
    let source = CIImage(cgImage: image)
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let correction = CIFilter.perspectiveCorrection()
    correction.inputImage = source
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
    correction.topLeft = point(rectangle.topLeft)
    correction.topRight = point(rectangle.topRight)
    correction.bottomLeft = point(rectangle.bottomLeft)
    correction.bottomRight = point(rectangle.bottomRight)
    guard let out = correction.outputImage,
          let cg = ciContext.createCGImage(out, from: out.extent),
          cg.width > 450, cg.height > 200 else { return nil }
    return cg
}

func detectBond(_ image: CGImage) -> CGRect? {
    return rectangleCandidates(image).first?.boundingBox
}

func adjustedForFaintPrinting(_ image: CGImage) -> CGImage? {
    let original = CIImage(cgImage: image)
    let contrast = CIFilter.colorControls()
    contrast.inputImage = original
    contrast.contrast = 1.38
    contrast.saturation = 0.1
    let sharpen = CIFilter.sharpenLuminance()
    sharpen.inputImage = contrast.outputImage
    sharpen.sharpness = 0.35
    guard let final = sharpen.outputImage else { return nil }
    return ciContext.createCGImage(final, from: final.extent)
}

func fallbackBondCrop(_ image: CGImage) -> CGImage? {
    // Inset the frame so a ruler laid along a table edge is usually excluded
    // when rectangle detection finds nothing.
    let center = CGRect(x: Int(Double(image.width) * 0.07),
                        y: Int(Double(image.height) * 0.10),
                        width: Int(Double(image.width) * 0.86),
                        height: Int(Double(image.height) * 0.80))
    return image.cropping(to: center)
}
