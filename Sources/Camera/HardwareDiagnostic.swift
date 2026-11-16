import AVFoundation
import Foundation

/// Opt-in hardware diagnostic report providing comprehensive camera and capture diagnostics
/// without logging or exposing any private bond information.
struct HardwareDiagnosticReport {
    let timestamp: Date
    let activeDeviceName: String
    let activeDeviceCategory: String
    let activeDeviceTransport: String
    let activeDeviceModelID: String
    let activeFormatDimensions: String
    let activeFormatSubtype: String
    let isPhotoOutputSupported: Bool
    let maxPhotoDimensions: String
    let supportedExposureModes: [String]
    let supportedFocusModes: [String]
    let supportedWhiteBalanceModes: [String]
    let hardwareExposureAdjustmentSupported: Bool
    let minExposureBias: Float
    let maxExposureBias: Float
    let smartExposureMode: String
    let totalConnectedCameras: Int
    let connectedCamerasSummary: [String]
    let totalCaptures: Int
    let averageCaptureLatencyMs: Double
    let averageOCRLatencyMs: Double

    init(
        timestamp: Date = Date(),
        activeDeviceName: String,
        activeDeviceCategory: String,
        activeDeviceTransport: String,
        activeDeviceModelID: String,
        activeFormatDimensions: String,
        activeFormatSubtype: String,
        isPhotoOutputSupported: Bool,
        maxPhotoDimensions: String,
        supportedExposureModes: [String],
        supportedFocusModes: [String],
        supportedWhiteBalanceModes: [String],
        hardwareExposureAdjustmentSupported: Bool,
        minExposureBias: Float,
        maxExposureBias: Float,
        smartExposureMode: String,
        totalConnectedCameras: Int,
        connectedCamerasSummary: [String],
        totalCaptures: Int,
        averageCaptureLatencyMs: Double,
        averageOCRLatencyMs: Double
    ) {
        self.timestamp = timestamp
        self.activeDeviceName = activeDeviceName
        self.activeDeviceCategory = activeDeviceCategory
        self.activeDeviceTransport = activeDeviceTransport
        self.activeDeviceModelID = activeDeviceModelID
        self.activeFormatDimensions = activeFormatDimensions
        self.activeFormatSubtype = activeFormatSubtype
        self.isPhotoOutputSupported = isPhotoOutputSupported
        self.maxPhotoDimensions = maxPhotoDimensions
        self.supportedExposureModes = supportedExposureModes
        self.supportedFocusModes = supportedFocusModes
        self.supportedWhiteBalanceModes = supportedWhiteBalanceModes
        self.hardwareExposureAdjustmentSupported = hardwareExposureAdjustmentSupported
        self.minExposureBias = minExposureBias
        self.maxExposureBias = maxExposureBias
        self.smartExposureMode = smartExposureMode
        self.totalConnectedCameras = totalConnectedCameras
        self.connectedCamerasSummary = connectedCamerasSummary
        self.totalCaptures = totalCaptures
        self.averageCaptureLatencyMs = averageCaptureLatencyMs
        self.averageOCRLatencyMs = averageOCRLatencyMs
    }

    var formattedText: String {
        let df = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("=== Bond Scanner Hardware Diagnostics ===")
        lines.append("Generated: \(df.string(from: timestamp))")
        lines.append("")
        lines.append("--- Active Camera ---")
        lines.append("Device Name: \(activeDeviceName)")
        lines.append("Category: \(activeDeviceCategory)")
        lines.append("Transport: \(activeDeviceTransport)")
        lines.append("Model ID: \(activeDeviceModelID)")
        lines.append("Active Format: \(activeFormatDimensions) (\(activeFormatSubtype))")
        lines.append("Photo Output Attached: \(isPhotoOutputSupported)")
        lines.append("Max Photo Dimensions: \(maxPhotoDimensions)")
        lines.append("")
        lines.append("--- Hardware Control Capabilities ---")
        lines.append("Exposure Modes: [\(supportedExposureModes.joined(separator: ", "))]")
        lines.append("Focus Modes: [\(supportedFocusModes.joined(separator: ", "))]")
        lines.append("White Balance: [\(supportedWhiteBalanceModes.joined(separator: ", "))]")
        lines.append("Hardware Exposure Bias Adjustment: \(hardwareExposureAdjustmentSupported ? "Supported (\(String(format: "%.1f", minExposureBias)) to +\(String(format: "%.1f", maxExposureBias)) EV)" : "Unsupported (Fixed / Auto-managed)")")
        lines.append("Smart Exposure Capture Mode: \(smartExposureMode)")
        lines.append("")
        lines.append("--- Connected Video Devices (\(totalConnectedCameras)) ---")
        for summary in connectedCamerasSummary {
            lines.append("• \(summary)")
        }
        lines.append("")
        lines.append("--- Anonymized Session Performance ---")
        lines.append("Total Captures: \(totalCaptures)")
        lines.append("Avg Capture Latency: \(String(format: "%.1f", averageCaptureLatencyMs)) ms")
        lines.append("Avg OCR Latency: \(String(format: "%.1f", averageOCRLatencyMs)) ms")
        lines.append("=========================================")
        return lines.joined(separator: "\n")
    }
}
