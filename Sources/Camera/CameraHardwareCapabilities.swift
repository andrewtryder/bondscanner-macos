import AVFoundation
import Foundation

/// Modes for Smart Exposure Capture.
enum SmartExposureMode: String, Codable, CaseIterable, Equatable {
    case automatic = "Automatic"
    case off = "Off"

    static let defaultsKey = "smartExposureMode"

    var title: String {
        switch self {
        case .automatic:
            return "Automatic — Multi-Exposure when supported"
        case .off:
            return "Off — Single-Photo Capture"
        }
    }
}

/// Persistent store for Smart Exposure Capture setting.
final class SmartExposurePreferences {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SmartExposureMode.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadMode() -> SmartExposureMode {
        guard let raw = defaults.string(forKey: key),
              let mode = SmartExposureMode(rawValue: raw)
        else {
            return .automatic // Default is Automatic
        }
        return mode
    }

    func saveMode(_ mode: SmartExposureMode) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

/// Represents the inspected exposure and hardware bracketing capabilities of an active camera.
struct CameraHardwareExposureCapabilities: Equatable {
    let supportsHardwareAdjustment: Bool
    let minBias: Float
    let maxBias: Float
    let currentBias: Float
    let supportsAutoExposure: Bool
    let supportsLockedExposure: Bool
    let isHardwareBracketingSupported: Bool
    let statusDescription: String

    init(
        supportsHardwareAdjustment: Bool,
        minBias: Float,
        maxBias: Float,
        currentBias: Float = 0.0,
        supportsAutoExposure: Bool = true,
        supportsLockedExposure: Bool = true,
        isHardwareBracketingSupported: Bool = false,
        statusDescription: String = ""
    ) {
        self.supportsHardwareAdjustment = supportsHardwareAdjustment
        self.minBias = minBias
        self.maxBias = maxBias
        self.currentBias = currentBias
        self.supportsAutoExposure = supportsAutoExposure
        self.supportsLockedExposure = supportsLockedExposure
        self.isHardwareBracketingSupported = isHardwareBracketingSupported
        self.statusDescription = statusDescription
    }

    /// Computes clamped exposure bracketing targets.
    ///
    /// Suggested engineering targets:
    /// - Baseline: 0.0 EV
    /// - Darker: -0.7 EV
    /// - Brighter: +0.7 EV
    ///
    /// If hardware does not support adjustment, returns only [0.0] (single baseline capture).
    func targetExposureBiases(requestedMode: SmartExposureMode) -> [Float] {
        guard requestedMode == .automatic, isHardwareBracketingSupported, supportsHardwareAdjustment else {
            return [0.0]
        }
        let darker = max(minBias, -0.7)
        let brighter = min(maxBias, 0.7)

        // Ensure darker and brighter are genuinely different from baseline and each other
        if darker < -0.1, brighter > 0.1, darker < brighter {
            return [0.0, darker, brighter]
        } else if darker < -0.1 {
            return [0.0, darker]
        } else if brighter > 0.1 {
            return [0.0, brighter]
        }
        return [0.0]
    }

    /// Inspects an AVCaptureDevice dynamically and safely without throwing or crashing.
    static func inspect(device: AVCaptureDevice?) -> CameraHardwareExposureCapabilities {
        guard let device = device else {
            return CameraHardwareExposureCapabilities(
                supportsHardwareAdjustment: false,
                minBias: 0,
                maxBias: 0,
                currentBias: 0,
                supportsAutoExposure: false,
                supportsLockedExposure: false,
                isHardwareBracketingSupported: false,
                statusDescription: "No camera connected"
            )
        }

        let autoExp = device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose)
        let lockedExp = device.isExposureModeSupported(.locked)

        var minBias: Float = 0.0
        var maxBias: Float = 0.0
        var curBias: Float = 0.0
        let supportsBias = BondScanGetExposureBiasCapabilities(device, &minBias, &maxBias, &curBias)

        let isBracketing = supportsBias && (maxBias - minBias >= 0.4)
        let statusDesc: String
        if isBracketing {
            statusDesc = "Hardware exposure adjustment supported (\(String(format: "%.1f", minBias)) to +\(String(format: "%.1f", maxBias)) EV)."
        } else {
            statusDesc = "Hardware exposure adjustment unavailable on active camera; Smart Exposure uses standard single capture."
        }

        return CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: supportsBias,
            minBias: minBias,
            maxBias: maxBias,
            currentBias: curBias,
            supportsAutoExposure: autoExp,
            supportsLockedExposure: lockedExp,
            isHardwareBracketingSupported: isBracketing,
            statusDescription: statusDesc
        )
    }
}
