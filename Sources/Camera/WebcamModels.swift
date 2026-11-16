import AVFoundation
import Foundation

/// Categorizes video capture devices based on transport type and hardware classification.
enum WebcamCategory: String, Codable, CaseIterable, Equatable {
    case usbWebcam = "USB Webcam"
    case builtIn = "Built-in Camera"
    case continuity = "Continuity Camera"
    case external = "External Camera"

    var displayBadge: String {
        switch self {
        case .usbWebcam: return "USB"
        case .builtIn: return "Built-in"
        case .continuity: return "Continuity"
        case .external: return "External"
        }
    }
}

/// A lightweight, decoupled description of a video capture device.
struct WebcamDescriptor: Identifiable, Equatable, Hashable {
    let id: String
    let localizedName: String
    let category: WebcamCategory
    let modelID: String
    let manufacturer: String
    let isConnected: Bool
    let transportType: Int32

    init(
        id: String,
        localizedName: String,
        category: WebcamCategory,
        modelID: String = "",
        manufacturer: String = "",
        isConnected: Bool = true,
        transportType: Int32 = 0
    ) {
        self.id = id
        self.localizedName = localizedName
        self.category = category
        self.modelID = modelID
        self.manufacturer = manufacturer
        self.isConnected = isConnected
        self.transportType = transportType
    }

    var displayNameWithCategory: String {
        "[\(category.displayBadge)] \(localizedName)"
    }
}

/// User selection mode: either Automatic (prefer USB) or an explicit camera uniqueID.
enum WebcamSelection: Equatable {
    case automaticPreferUSB
    case explicit(uniqueID: String)

    static let defaultsKey = "preferredWebcamUniqueID"
    static let automaticValue = "automatic"

    var rawValue: String {
        switch self {
        case .automaticPreferUSB:
            return Self.automaticValue
        case let .explicit(id):
            return id
        }
    }

    init(rawValue: String?) {
        guard let rawValue = rawValue, !rawValue.isEmpty, rawValue != Self.automaticValue else {
            self = .automaticPreferUSB
            return
        }
        self = .explicit(uniqueID: rawValue)
    }
}

/// Persistent store for webcam selection.
final class WebcamPreferences {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = WebcamSelection.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadSelection() -> WebcamSelection {
        let raw = defaults.string(forKey: key)
        return WebcamSelection(rawValue: raw)
    }

    func saveSelection(_ selection: WebcamSelection) {
        switch selection {
        case .automaticPreferUSB:
            defaults.set(WebcamSelection.automaticValue, forKey: key)
        case let .explicit(id):
            defaults.set(id, forKey: key)
        }
    }
}

/// Pure resolution logic for choosing the active camera among available devices.
enum WebcamResolver {
    /// Resolves the best available device given current user selection and available devices.
    ///
    /// Resolution rules:
    /// 1. If explicit selection is provided and matching device is available and connected, select it.
    /// 2. Otherwise (or if explicit is missing/disconnected or selection is automatic):
    ///    - First available physical USB webcam (.usbWebcam)
    ///    - Otherwise first available other external camera (.external)
    ///    - Otherwise first available built-in camera (.builtIn)
    ///    - Otherwise first available device of any category
    ///    - Otherwise nil
    static func resolveActiveCamera(
        selection: WebcamSelection,
        available: [WebcamDescriptor]
    ) -> (selected: WebcamDescriptor?, isExplicitMatch: Bool) {
        let connected = available.filter(\.isConnected)
        guard !connected.isEmpty else {
            return (nil, false)
        }

        if case let .explicit(targetID) = selection, let matched = connected.first(where: { $0.id == targetID }) {
            return (matched, true)
        }

        // Automatic order:
        // 1. USB Webcam
        if let usb = connected.first(where: { $0.category == .usbWebcam }) {
            return (usb, false)
        }
        // 2. External camera
        if let ext = connected.first(where: { $0.category == .external }) {
            return (ext, false)
        }
        // 3. Built-in camera
        if let builtIn = connected.first(where: { $0.category == .builtIn }) {
            return (builtIn, false)
        }
        // 4. Any remaining connected camera (e.g. continuity)
        return (connected.first, false)
    }

    /// Categorizes an AVFoundation AVCaptureDevice.
    static func categorize(device: AVCaptureDevice) -> WebcamCategory {
        var isContinuity = false
        if #available(macOS 14.0, *) {
            if device.deviceType == .continuityCamera {
                isContinuity = true
            }
        }
        return categorize(
            localizedName: device.localizedName,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            transportType: device.transportType,
            isBuiltInDeviceType: device.deviceType == .builtInWideAngleCamera,
            isContinuityDeviceType: isContinuity
        )
    }

    /// Pure classification helper preferring verified transport information over generic display names.
    static func categorize(
        localizedName: String,
        modelID: String,
        manufacturer: String,
        transportType: Int32,
        isBuiltInDeviceType: Bool = false,
        isContinuityDeviceType: Bool = false
    ) -> WebcamCategory {
        if isContinuityDeviceType {
            return .continuity
        }

        let nameLower = localizedName.lowercased()
        let modelLower = modelID.lowercased()
        let mfgLower = manufacturer.lowercased()

        if nameLower.contains("continuity") || modelLower.contains("continuity")
            || nameLower.contains("iphone") || nameLower.contains("ipad")
        {
            return .continuity
        }

        // 1651274862 is 'bltn' in ASCII (kIOAudioDeviceTransportTypeBuiltIn)
        if isBuiltInDeviceType || transportType == 1_651_274_862 {
            return .builtIn
        }

        // Physical USB Transport:
        // 1970496032 is 'usb ' in ASCII (kIOAudioDeviceTransportTypeUSB).
        // Prefer verified transport or explicit UVC/USB hardware identifiers; do not classify
        // as physical USB merely because the display name contains "webcam".
        if transportType == 1_970_496_032
            || modelLower.contains("uvc")
            || modelLower.contains("usb")
            || mfgLower.contains("usb")
            || nameLower.contains("usb")
        {
            return .usbWebcam
        }

        // If device is external and not built-in / continuity, default to external
        return .external
    }

    /// Creates a descriptor from an AVCaptureDevice.
    static func makeDescriptor(from device: AVCaptureDevice) -> WebcamDescriptor {
        let category = categorize(device: device)
        return WebcamDescriptor(
            id: device.uniqueID,
            localizedName: device.localizedName,
            category: category,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            isConnected: device.isConnected,
            transportType: device.transportType
        )
    }
}
