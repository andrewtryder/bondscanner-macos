import Foundation
import AVFoundation
import CoreMedia

func fourCharCodeString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    if let s = String(bytes: bytes, encoding: .ascii),
       s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value < 127 }) {
        return s
    }
    return String(format: "0x%08X", code)
}

func formatIsMJPEG(_ format: AVCaptureDevice.Format) -> Bool {
    let name = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased()
    return name == "jpeg" || name == "mjpa" || name == "mjpb" || name == "mjpg"
}

func formatDimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
    return CMVideoFormatDescriptionGetDimensions(format.formatDescription)
}

func videoCaptureDevices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
        types.append(.external)
    } else {
        types.append(AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown"))
    }
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    return discovery.devices
}

func selectBestCaptureFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
    let usable = formats.filter { format in
        let d = formatDimensions(format)
        return d.width >= 1280 && d.height >= 720 && d.width <= 4096 && d.height <= 4096
    }
    // MJPEG (compressed) can carry 2K over USB 2.0. Uncompressed 420v above
    // 1920x1080 is past this camera's USB 2.0 ceiling (~480 Mbps), so prefer
    // 1080p 420v when MJPEG is not advertised.
    let uncompressedCap = 1920 * 1080
    func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int, Int) {
        let d = formatDimensions(format)
        let pixels = Int(d.width) * Int(d.height)
        let mjpeg = formatIsMJPEG(format) ? 1 : 0
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased()
        let four20 = (sub == "420v" || sub == "420f") ? 1 : 0
        let effective: Int
        if mjpeg == 1 {
            effective = pixels
        } else if pixels > uncompressedCap {
            effective = 0
        } else {
            effective = pixels
        }
        return (mjpeg, effective, four20, pixels)
    }
    return usable.max { a, b in
        let sa = score(a), sb = score(b)
        if sa.0 != sb.0 { return sa.0 < sb.0 }
        if sa.1 != sb.1 { return sa.1 < sb.1 }
        if sa.2 != sb.2 { return sa.2 < sb.2 }
        return sa.3 < sb.3
    }
}

func select1080FallbackFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
    let matches = formats.filter { format in
        let d = formatDimensions(format)
        return d.width == 1920 && d.height == 1080
    }
    return matches.first(where: { format in
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased()
        return sub == "420v" || sub == "420f"
    }) ?? matches.first
}

func photoDimension(_ dims: CMVideoDimensions, isIn supported: [CMVideoDimensions]) -> Bool {
    return supported.contains { $0.width == dims.width && $0.height == dims.height }
}

func logAllCameraFormats(_ camera: AVCaptureDevice) {
    for (index, format) in camera.formats.enumerated() {
        let d = formatDimensions(format)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let fps = format.videoSupportedFrameRateRanges.map { range in
            String(format: "%.2f-%.2f", range.minFrameRate, range.maxFrameRate)
        }.joined(separator: ",")
        ScanLog.shared.write("camera format[\(index)] \(d.width)x\(d.height) subtype=\(sub) fps=[\(fps)]")
    }
}

func logCameraControls(_ camera: AVCaptureDevice) {
    func modeName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoFocus: return "autoFocus"
        case .continuousAutoFocus: return "continuousAutoFocus"
        @unknown default: return "other"
        }
    }
    func expName(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoExpose: return "autoExpose"
        case .continuousAutoExposure: return "continuousAutoExposure"
        case .custom: return "custom"
        @unknown default: return "other"
        }
    }
    func wbName(_ mode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoWhiteBalance: return "autoWhiteBalance"
        case .continuousAutoWhiteBalance: return "continuousAutoWhiteBalance"
        @unknown default: return "other"
        }
    }
    let focusModes: [AVCaptureDevice.FocusMode] = [.continuousAutoFocus, .autoFocus, .locked]
    let expModes: [AVCaptureDevice.ExposureMode] = [.continuousAutoExposure, .autoExpose, .locked, .custom]
    let wbModes: [AVCaptureDevice.WhiteBalanceMode] = [.continuousAutoWhiteBalance, .autoWhiteBalance, .locked]
    let focusSupported = focusModes.filter { camera.isFocusModeSupported($0) }.map(modeName).joined(separator: ",")
    let expSupported = expModes.filter { camera.isExposureModeSupported($0) }.map(expName).joined(separator: ",")
    let wbSupported = wbModes.filter { camera.isWhiteBalanceModeSupported($0) }.map(wbName).joined(separator: ",")
    ScanLog.shared.write("focus supported=[\(focusSupported)] current=\(modeName(camera.focusMode)) point_of_interest=\(camera.isFocusPointOfInterestSupported)")
    ScanLog.shared.write("exposure supported=[\(expSupported)] current=\(expName(camera.exposureMode)) point_of_interest=\(camera.isExposurePointOfInterestSupported)")
    ScanLog.shared.write("white_balance supported=[\(wbSupported)] current=\(wbName(camera.whiteBalanceMode))")
}

func preferredFrameDuration(for format: AVCaptureDevice.Format, desiredFPS: Double) -> (duration: CMTime, fps: Double)? {
    let ranges = format.videoSupportedFrameRateRanges
    guard !ranges.isEmpty else { return nil }
    var bestRange = ranges[0]
    var bestFPS = min(bestRange.maxFrameRate, max(bestRange.minFrameRate, desiredFPS))
    var bestDelta = abs(bestFPS - desiredFPS)
    for range in ranges {
        let fps: Double
        if range.minFrameRate <= desiredFPS && desiredFPS <= range.maxFrameRate {
            fps = desiredFPS
        } else if range.maxFrameRate <= desiredFPS {
            fps = range.maxFrameRate
        } else {
            fps = range.minFrameRate
        }
        let delta = abs(fps - desiredFPS)
        if delta < bestDelta || (delta == bestDelta && fps <= desiredFPS && bestFPS > desiredFPS) {
            bestRange = range
            bestFPS = fps
            bestDelta = delta
        }
    }
    var duration = CMTime(seconds: 1.0 / max(bestFPS, 1), preferredTimescale: 600)
    if CMTimeCompare(duration, bestRange.minFrameDuration) < 0 { duration = bestRange.minFrameDuration }
    if CMTimeCompare(duration, bestRange.maxFrameDuration) > 0 { duration = bestRange.maxFrameDuration }
    let fps = 1.0 / CMTimeGetSeconds(duration)
    return (duration, fps)
}

func desiredFPSForFormatDimensions(_ width: Int32, _ height: Int32) -> Double {
    let pixels = Int(width) * Int(height)
    if pixels >= 2592 * 1944 { return 10 }
    if pixels >= 2048 * 1536 { return 15 }
    return 30
}

func estimatedMegabitsPerSecond(width: Int, height: Int, fps: Double, bytesPerPixel: Double = 1.5) -> Double {
    return Double(width) * Double(height) * bytesPerPixel * fps * 8.0 / 1_000_000.0
}

func largestSupportedPhotoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
    if #available(macOS 13.0, *) {
        let supported = format.supportedMaxPhotoDimensions
        return supported.max { a, b in
            Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }
    }
    return nil
}
