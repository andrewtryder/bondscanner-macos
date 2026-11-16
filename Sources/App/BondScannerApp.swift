import AppKit
import AudioToolbox
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import Vision
#if canImport(FoundationModels)
    import FoundationModels
#endif

enum CollectionStartupCancelled: Error {
    case cancelled
}

final class BondScannerApp: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    /// Explicit hosted-test guard. This is evaluated before any production path,
    /// including database initialization, logging, exports, and camera setup.
    let isTestMode = ProcessInfo.processInfo.environment["BONDSCANNER_TEST_MODE"] == "1"
    var window: NSWindow!
    var preview: PreviewView!
    var statusLabel: NSTextField!
    var capturedChip: StatChipView!
    var verifiedChip: StatChipView!
    var reviewChip: StatChipView!
    var duplicateChip: StatChipView!
    var readingChip: StatChipView!
    var lastLabel: NSTextField!
    var autoButton: NSButton!
    var fastButton: NSButton!
    var bondsDrawer: BondsDrawerView!
    var drawerWidthConstraint: NSLayoutConstraint!
    var drawerVisible = true
    static let drawerWidth: CGFloat = 500
    var reviewWindowController: ReviewWindowController?
    var didStartCollection = false
    var collectionLockFD: Int32 = -1
    var settingsWindow: NSWindow?
    var settingsLocationLabel: NSTextField?
    var aiLabel: NSTextField!
    var focusLabel: NSTextField!
    var focusInfo = "Focus: awaiting camera"
    var captureDevice: AVCaptureDevice?
    var currentDeviceInput: AVCaptureDeviceInput?
    var currentExposureCapabilities: CameraHardwareExposureCapabilities = .inspect(device: nil)
    var webcamPreferences = WebcamPreferences()
    var smartExposurePreferences = SmartExposurePreferences()
    var captureTransactionCoordinator = CaptureTransactionCoordinator()
    var pendingReconnectionDeviceID: String?
    var stabilizationStartTime: TimeInterval = 0
    var priorFrameLuminance: Float = 0
    var isCameraSwitching = false
    var connectedDeviceDescriptors: [WebcamDescriptor] = []
    var cameraSubmenu: NSMenu?
    var settingsCameraPopUp: NSPopUpButton?
    var settingsSmartExposurePopUp: NSPopUpButton?
    var settingsCameraStatusLabel: NSTextField?
    var nextAutoAllowedAt: TimeInterval = 0
    var lastHuntAt: TimeInterval = 0
    var huntRunning = false
    var huntHits = 0
    var noBondChecks = 0
    var lastDiagnosticAt: TimeInterval = 0
    var lastVideoLogAt: TimeInterval = 0
    var session: AVCaptureSession!
    var photoOutput: AVCapturePhotoOutput!
    var photoCaptureSupported = false
    var chosenFormatWidth = 0
    var chosenFormatHeight = 0
    var chosenFormatSubtype = ""
    var chosenDeviceFormat: AVCaptureDevice.Format?
    var videoDataOutput: AVCaptureVideoDataOutput?
    var deliveredFrameLogged = false
    var resolutionSettled = false
    var didReassertFormat = false
    var didTryHigherFormat = false
    var latestImage: CGImage?
    var records: [BondRecord] = []
    var isProcessing = false
    var automatic = true
    var fastScanEnabled = true
    var lockedAfterCapture = false
    var frameAnalysisInterval: TimeInterval {
        fastScanEnabled ? 0.25 : 0.55
    }

    var textHuntInterval: TimeInterval {
        fastScanEnabled ? 0.75 : 1.40
    }

    var requiredHuntHits: Int {
        fastScanEnabled ? 1 : 2
    }

    var emptyRearmFramesThreshold: Int {
        fastScanEnabled ? 3 : 6
    }

    var retryCooldownInterval: TimeInterval {
        fastScanEnabled ? 0.45 : 1.20
    }

    var rejectCooldownInterval: TimeInterval {
        fastScanEnabled ? 1.20 : 3.00
    }

    /// Normalized serial of the most recently captured bond. Never logged.
    var lastCapturedSerial = ""
    /// True after a photograph is saved and before OCR has reported its serial.
    var awaitingSerialFromCapture = false
    var autoFillRecordId: String?
    var autoFillAttempts = 0
    let autoFillMaxAttempts = 4
    var autoFillRect: CGRect?
    var autoFillGoneFrames = 0
    var emptyFrames = 0
    var priorRect: CGRect?
    var stableFrames = 0
    var lastAnalyzeAt: TimeInterval = 0
    var keyMonitor: Any?
    let cameraQueue = DispatchQueue(label: "bondscanner.camera", qos: .userInitiated)
    let analysisQueue = DispatchQueue(label: "bondscanner.analysis", qos: .userInitiated)
    let ocrQueue = DispatchQueue(label: "bondscanner.ocr", qos: .userInitiated)
    let saveQueue = DispatchQueue(label: "bondscanner.save", qos: .userInitiated)
    struct PhotoRequestInfo {
        let automatic: Bool
        let requestedAt: TimeInterval
        var biasEV: Float = 0.0
        var completion: ((Result<CapturedExposure, Error>) -> Void)?
    }

    var photoRequests: [Int64: PhotoRequestInfo] = [:]

    struct OCRJobContext {
        let id: String
        let originalURL: URL
        let automatic: Bool
        let focusIssueDate: Bool
        let recentIssueDates: [(month: String, year: String)]
        let captureRequestedAt: TimeInterval
        let enqueuedAt: TimeInterval
        var bracketedExposures: [(biasEV: Float, url: URL, relativePath: String)] = []
    }

    var ocrPending: [OCRJobContext] = []
    var ocrBusy = false

    struct PerformanceDiagnostics {
        var totalCaptures: Int = 0
        var totalOCRCompleted: Int = 0
        var totalCaptureTimeMs: Double = 0
        var totalProcessingTimeMs: Double = 0
        var highWaterQueueDepth: Int = 0
        var sessionStartTime: TimeInterval = Date().timeIntervalSince1970

        var averageCaptureLatencyMs: Double {
            totalCaptures > 0 ? totalCaptureTimeMs / Double(totalCaptures) : 0
        }

        var averageOCRLatencyMs: Double {
            totalOCRCompleted > 0 ? totalProcessingTimeMs / Double(totalOCRCompleted) : 0
        }

        var throughputBondsPerMinute: Double {
            let minutes = max(0.05, (Date().timeIntervalSince1970 - sessionStartTime) / 60.0)
            return Double(totalOCRCompleted) / minutes
        }
    }

    var diagnostics = PerformanceDiagnostics()

    var activeHuntToken: UUID?
    var activeHuntTimestamp: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isTestMode || NSClassFromString("XCTestCase") != nil {
            return
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        {
            showStartupError("Another Bond Scanner instance is already running. Quit it before opening or switching collections.")
            return
        }
        do {
            try prepareCollectionLocation()
        } catch is CollectionStartupCancelled {
            NSApp.terminate(nil)
            return
        } catch {
            showStartupError("The collection location could not be opened. No other collection was selected.\n\n\(error.localizedDescription)")
            return
        }
        do {
            let databaseAlreadyExists = FileManager.default.fileExists(atPath: databaseURL.path)
            if !databaseAlreadyExists {
                try CollectionValidator.validateFirstLaunch(root: outputRoot)
            }
            try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
            let db = try DatabaseManager.initializeShared(url: databaseURL)
            if databaseAlreadyExists {
                records = try db.loadAllRecords()
                // An existing empty database and a populated legacy export are ambiguous.
                // Do not import or overwrite that file without a recovery decision.
                if records.isEmpty, FileManager.default.fileExists(atPath: recordsURL.path) {
                    let data = try Data(contentsOf: recordsURL)
                    let legacyRecords = try JSONDecoder().decode([BondRecord].self, from: data)
                    guard legacyRecords.isEmpty else {
                        throw DatabaseError.restoreFailed("The database is empty but records.json contains records. Both files were preserved; resolve the mismatch before starting.")
                    }
                }
            } else {
                records = try db.migrateFromJSONIfNeeded(jsonURL: recordsURL)
            }
            if !databaseAlreadyExists {
                for i in records.indices {
                    applyRequiredStatus(&records[i])
                }
            }
            if let latest = records.max(by: { $0.capturedAt < $1.capturedAt }) {
                let serial = normalizeSerial(latest.serial)
                if !serial.isEmpty {
                    lastCapturedSerial = serial
                }
            }
            try writeRecords(records)
            if ProcessInfo.processInfo.environment["BONDSCANNER_OUTPUT_ROOT"] == nil {
                let preferences = CollectionLocationPreferences()
                var state = try preferences.load()
                if state.activePath == nil {
                    state.activePath = outputRoot.standardizedFileURL.path
                    try preferences.save(state)
                }
            }
            session = AVCaptureSession()
            photoOutput = AVCapturePhotoOutput()
            didStartCollection = true
        } catch let err as DatabaseError {
            switch err {
            case let .databaseCorrupted(detail):
                showCorruptionErrorWithRecoveryOption(detail: detail)
                return
            case let .databaseLocked(detail):
                showStartupError("Database is locked by another process: \(detail).\nPlease close any other running instances.")
                return
            case let .permissionDenied(detail):
                showStartupError("Cannot access database due to permissions: \(detail).\nPlease check permissions for \(outputRoot.path).")
                return
            default:
                showStartupError("Database error: \(err.localizedDescription)")
                return
            }
        } catch {
            showStartupError("Could not open \(outputRoot.path): \(error.localizedDescription)")
            return
        }
        setupMenu()
        makeWindow()
        ScanLog.shared.write("app launch: version=2.1 records=\(records.count) no OCR text or identifiers logged")
        updateCount()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 {
                self?.scanNow(); return nil
            } // Space
            return event
        }
        // A development-only override permits UI validation with synthetic data
        // without starting a camera or capturing real photographs.
        if ProcessInfo.processInfo.environment["BONDSCANNER_DISABLE_CAMERA"] != "1" {
            requestCameraAccess()
        }
        for record in records where record.status == "PROCESSING" {
            let url = outputRoot.appendingPathComponent(record.sourcePhoto)
            if FileManager.default.fileExists(atPath: url.path) {
                ScanLog.shared.write("resuming OCR for a photograph saved before the last quit")
                enqueueOCR(id: record.id, originalURL: url, automatic: false)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        defer {
            if collectionLockFD >= 0 {
                close(collectionLockFD)
                collectionLockFD = -1
            }
        }
        if isTestMode || NSClassFromString("XCTestCase") != nil || !didStartCollection {
            return
        }
        ScanLog.shared.write("app quit")
        flushAutomaticExports(records: records)
        session.stopRunning()
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Bond Scanner")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Bond Scanner", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let reviewMenuItem = NSMenuItem(title: "Review Unresolved Bonds…", action: #selector(openReviewWorkflow), keyEquivalent: "r")
        reviewMenuItem.keyEquivalentModifierMask = [.command, .option]
        reviewMenuItem.target = self
        fileMenu.addItem(reviewMenuItem)
        let exportCSVMenuItem = NSMenuItem(title: "Export CSV…", action: #selector(exportCSVAction), keyEquivalent: "e")
        exportCSVMenuItem.target = self
        fileMenu.addItem(exportCSVMenuItem)
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)
        let reviewAIItem = NSMenuItem(title: "On-Device AI", action: nil, keyEquivalent: "")
        let reviewAIMenu = NSMenu(title: "On-Device AI")
        let automaticAI = NSMenuItem(title: "Automatically Analyze REVIEW Records", action: #selector(toggleAutomaticAIReview(_:)), keyEquivalent: "")
        automaticAI.target = self
        automaticAI.state = ReviewCoordinator.automaticAIEnabled ? .on : .off
        automaticAI.toolTip = "Uses Apple’s on-device model only. It creates unverified suggestions and never changes bond fields automatically."
        reviewAIMenu.addItem(automaticAI)
        let analyzeBacklog = NSMenuItem(title: "Analyze Existing Reviews", action: #selector(analyzeExistingReviews), keyEquivalent: "")
        analyzeBacklog.target = self
        reviewAIMenu.addItem(analyzeBacklog)
        let pauseAI = NSMenuItem(title: "Pause AI Review Queue", action: #selector(pauseAIReviewQueue), keyEquivalent: "")
        pauseAI.target = self
        reviewAIMenu.addItem(pauseAI)
        let resumeAI = NSMenuItem(title: "Resume AI Review Queue", action: #selector(resumeAIReviewQueue), keyEquivalent: "")
        resumeAI.target = self
        reviewAIMenu.addItem(resumeAI)
        let cancelAI = NSMenuItem(title: "Cancel AI Review Queue", action: #selector(cancelAIReviewQueue), keyEquivalent: "")
        cancelAI.target = self
        reviewAIMenu.addItem(cancelAI)
        reviewAIItem.submenu = reviewAIMenu
        bar.addItem(reviewAIItem)
        let debugItem = NSMenuItem()
        let debugMenu = NSMenu(title: "Debug")
        let open = NSMenuItem(title: "Open Debug Log", action: #selector(openDebugLog), keyEquivalent: "")
        open.target = self
        debugMenu.addItem(open)
        debugItem.submenu = debugMenu
        bar.addItem(debugItem)
        let cameraItem = NSMenuItem()
        let cameraMenu = NSMenu(title: "Camera")
        cameraItem.submenu = cameraMenu
        bar.addItem(cameraItem)
        cameraSubmenu = cameraMenu
        refreshCameraMenu()
        NSApp.mainMenu = bar
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func openReviewWorkflow() {
        reviewWindowController?.showReviewWindow(selectingRecordId: nil, filter: .allReview)
    }

    @objc func toggleAutomaticAIReview(_ sender: NSMenuItem) {
        ReviewCoordinator.automaticAIEnabled.toggle()
        sender.state = ReviewCoordinator.automaticAIEnabled ? .on : .off
        status(ReviewCoordinator.automaticAIEnabled
            ? "On-device AI will prepare suggestions for new REVIEW records."
            : "Automatic on-device AI review is off. Manual analysis remains available.")
    }

    @objc func analyzeExistingReviews() {
        reviewWindowController?.coordinator.analyzeExistingReviews()
        reviewWindowController?.showReviewWindow(selectingRecordId: nil, filter: .allReview)
    }

    @objc func pauseAIReviewQueue() {
        reviewWindowController?.coordinator.pauseAIReview()
    }

    @objc func resumeAIReviewQueue() {
        reviewWindowController?.coordinator.resumeAIReview()
    }

    @objc func cancelAIReviewQueue() {
        reviewWindowController?.coordinator.cancelAIReview()
    }

    @objc func refocusCamera() {
        guard let camera = captureDevice else { status("No webcam available to refocus."); return }
        let supportsSingle = camera.isFocusModeSupported(.autoFocus)
        let supportsContinuous = camera.isFocusModeSupported(.continuousAutoFocus)
        guard supportsSingle || supportsContinuous else {
            ScanLog.shared.write("refocus requested but webcam exposes no software-controlled focus")
            status("Webcam provides no macOS focus control. Adjust distance or use vendor controls.")
            return
        }
        do {
            try camera.lockForConfiguration()
            if camera.isFocusPointOfInterestSupported {
                camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if supportsSingle {
                if camera.isFocusModeSupported(.locked) {
                    camera.focusMode = .locked
                }
                camera.focusMode = .autoFocus
            } else {
                camera.focusMode = .continuousAutoFocus
            }
            camera.unlockForConfiguration()
            ScanLog.shared.write("manual refocus request sent to webcam")
            status("Requested camera refocus at center. Hold the bond still.")
        } catch {
            ScanLog.shared.write("refocus camera configuration failed")
            status("Could not request focus from the webcam.")
        }
    }

    func setAutoContrast(enabled: Bool) {
        EnhancementController.shared.update { $0.autoContrastEnabled = enabled }
        ScanLog.shared.write("auto contrast toggled to \(enabled)")
        if enabled {
            if let frame = latestImage {
                let autoParams = computeAutoContrastParameters(frame, region: priorRect)
                preview.reflectAutoContrast(contrast: autoParams.contrast, brightness: autoParams.brightness)
            }
            status("Auto-Contrast enabled.")
        } else {
            status("Manual brightness/contrast override active.")
        }
    }

    func applyManualContrastBrightness(contrast: Float, brightness: Float) {
        EnhancementController.shared.update {
            $0.autoContrastEnabled = false
            $0.manualContrast = contrast
            $0.manualBrightness = brightness
        }
    }

    func applyManualFocusPosition(_ position: Float) {
        EnhancementController.shared.update { $0.manualSharpness = position }
        if let camera = captureDevice {
            var lockedHardware = false
            bondScanTry("lock camera focus") {
                if camera.isFocusModeSupported(.locked) {
                    do {
                        try camera.lockForConfiguration()
                        camera.focusMode = .locked
                        camera.unlockForConfiguration()
                        lockedHardware = true
                    } catch {
                        lockedHardware = false
                    }
                }
            }
            if lockedHardware {
                focusInfo = "Focus: locked for fixed stand (edge assist \(String(format: "%.2f", position)))"
                focusLabel?.stringValue = focusInfo
            }
        }
    }

    @objc func openDebugLog() {
        ScanLog.shared.write("user opened debug log")
        NSWorkspace.shared.open(debugURL)
    }

    func label(_ text: String, size: CGFloat = 15, bold: Bool = false) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        view.textColor = NSColor.labelColor
        view.lineBreakMode = .byTruncatingTail
        return view
    }

    func symbolImage(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Bond Scanner"
        window.center()
        window.minSize = NSSize(width: 1050, height: 660)
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let toolbar = NSToolbar(identifier: "BondScannerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let reviewCoord = ReviewCoordinator(records: records)
        let rwc = ReviewWindowController(coordinator: reviewCoord)
        rwc.onRecordsChanged = { [weak self] updatedRecords in
            let apply: () -> Void = {
                guard let self = self else { return }
                self.records = updatedRecords
                self.updateCount(syncReviewCoordinator: false)
            }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
        reviewWindowController = rwc

        bondsDrawer = BondsDrawerView(frame: .zero)
        bondsDrawer.translatesAutoresizingMaskIntoConstraints = false
        bondsDrawer.onCollapseRequested = { [weak self] in self?.toggleDrawer() }
        bondsDrawer.onOpenPhotoRequested = { [weak self] record in self?.openBondPhoto(record) }
        bondsDrawer.onReviewRequested = { [weak self] record in
            self?.reviewWindowController?.showReviewWindow(selectingRecordId: record.id)
        }
        bondsDrawer.onReviewNextRequested = { [weak self] in
            self?.reviewWindowController?.showReviewWindow(selectingRecordId: nil, filter: .allReview)
        }
        root.addSubview(bondsDrawer)
        drawerWidthConstraint = bondsDrawer.widthAnchor.constraint(equalToConstant: Self.drawerWidth)

        preview = PreviewView(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.videoLayer.session = session
        preview.onAutoContrastChanged = { [weak self] enabled in self?.setAutoContrast(enabled: enabled) }
        preview.onManualAdjustmentsChanged = { [weak self] contrast, brightness in self?.applyManualContrastBrightness(contrast: contrast, brightness: brightness) }
        preview.onFocusSliderChanged = { [weak self] position in self?.applyManualFocusPosition(position) }
        preview.onAutoFocusRequested = { [weak self] in self?.refocusCamera() }
        let initialSettings = EnhancementController.shared.settings
        preview.applyVideoLayerFilter(
            contrast: initialSettings.manualContrast,
            brightness: initialSettings.manualBrightness,
            sharpness: initialSettings.manualSharpness
        )
        preview.layer?.cornerRadius = 14
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        root.addSubview(preview)

        // Status strip: live counts as chips, then the current status and last-scan lines.
        capturedChip = StatChipView(symbol: "tray.full.fill", caption: "Captured", tint: .systemBlue)
        verifiedChip = StatChipView(symbol: "checkmark.seal.fill", caption: "Verified", tint: .systemGreen)
        reviewChip = StatChipView(symbol: "exclamationmark.triangle.fill", caption: "Need review", tint: .systemOrange)
        duplicateChip = StatChipView(symbol: "doc.on.doc.fill", caption: "Duplicate", tint: .systemPurple)
        readingChip = StatChipView(symbol: "text.viewfinder", caption: "Reading", tint: .systemTeal)
        let chipRow = NSStackView(views: [capturedChip!, verifiedChip!, reviewChip!, duplicateChip!, readingChip!])
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 8
        duplicateChip.isHidden = true
        readingChip.isHidden = true

        statusLabel = label("Starting webcam\u{2026}", size: 15)
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        lastLabel = label("Hold a bond steady inside the guide corners.", size: 13)
        lastLabel.textColor = .secondaryLabelColor
        aiLabel = label("OCR: Apple Vision (offline)", size: 11)
        focusLabel = label("Focus: checking camera\u{2026}", size: 11)
        for footer in [aiLabel!, focusLabel!] {
            footer.textColor = .tertiaryLabelColor
        }
        let footerRow = NSStackView(views: [aiLabel!, focusLabel!])
        footerRow.orientation = .horizontal
        footerRow.alignment = .firstBaseline
        footerRow.spacing = 14

        let infoStack = NSStackView(views: [chipRow, statusLabel!, lastLabel!, footerRow])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 6
        infoStack.setCustomSpacing(10, after: chipRow)
        infoStack.setCustomSpacing(10, after: lastLabel)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(infoStack)
        for v in [statusLabel!, lastLabel!, focusLabel!] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(lessThanOrEqualTo: infoStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            bondsDrawer.topAnchor.constraint(equalTo: root.topAnchor),
            bondsDrawer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bondsDrawer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            drawerWidthConstraint,

            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            preview.trailingAnchor.constraint(equalTo: bondsDrawer.leadingAnchor, constant: -16),
            preview.bottomAnchor.constraint(equalTo: infoStack.topAnchor, constant: -14),

            infoStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            infoStack.trailingAnchor.constraint(equalTo: bondsDrawer.leadingAnchor, constant: -20),
            infoStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                aiLabel.stringValue = SystemLanguageModel.default.isAvailable
                    ? "OCR: Apple Vision + Apple Intelligence (all on-device)"
                    : "OCR: Apple Vision (Apple Intelligence model unavailable; still offline)"
            }
        #endif
    }

    func status(_ text: String) {
        if Thread.isMainThread {
            statusLabel?.stringValue = text
        } else {
            DispatchQueue.main.async { [weak self] in self?.statusLabel?.stringValue = text }
        }
    }

    func updateCount(syncReviewCoordinator: Bool = true) {
        let processing = records.filter { $0.status == "PROCESSING" }.count
        let duplicates = records.filter { $0.status == "DUPLICATE" }.count
        let reviews = records.filter { $0.status != "OK" && $0.status != "PROCESSING" && $0.status != "DUPLICATE" }.count
        let verified = records.filter { $0.status == "OK" }.count
        capturedChip.setValue(records.count)
        verifiedChip.setValue(verified)
        reviewChip.setValue(reviews)
        duplicateChip.setValue(duplicates)
        duplicateChip.isHidden = duplicates == 0
        readingChip.setValue(processing)
        readingChip.isHidden = processing == 0
        bondsDrawer?.updateRecords(records)
        if syncReviewCoordinator {
            reviewWindowController?.coordinator.setAllRecords(records)
        }
    }

    @objc func toggleAuto() {
        automatic.toggle()
        autoButton.state = automatic ? .on : .off
        ScanLog.shared.write("automatic mode toggled to \(automatic)")
        status(automatic ? "Automatic scanning on. Remove each bond after the confirmation flash." : "Manual mode. Press Space to scan each bond.")
    }

    @objc func toggleFastScan() {
        fastScanEnabled.toggle()
        fastButton.state = fastScanEnabled ? .on : .off
        ScanLog.shared.write("fast scan toggled to \(fastScanEnabled)")
        status(fastScanEnabled
            ? "Fast Scan on: quicker frame lock and immediate re-arm when a bond is removed."
            : "Fast Scan off: standard stabilization and OCR re-arm timing.")
    }

    @objc func toggleDrawer() {
        drawerVisible.toggle()
        bondsDrawer.isHidden = !drawerVisible
        drawerWidthConstraint.constant = drawerVisible ? Self.drawerWidth : 0
    }

    func openBondPhoto(_ record: BondRecord) {
        let relative = record.photo.isEmpty ? record.sourcePhoto : record.photo
        guard !relative.isEmpty else {
            status("No saved photo path for that record.")
            return
        }
        let url = outputRoot.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            status("Saved photo not found on disk.")
        }
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(outputRoot)
    }
}
