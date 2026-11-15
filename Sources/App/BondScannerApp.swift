import AppKit
import AudioToolbox
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import Vision
#if canImport(FoundationModels)
    import FoundationModels
#endif

final class BondScannerApp: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    private var window: NSWindow!
    private var preview: PreviewView!
    private var statusLabel: NSTextField!
    private var countLabel: NSTextField!
    private var lastLabel: NSTextField!
    private var autoButton: NSButton!
    private var fastButton: NSButton!
    private var drawerButton: NSButton!
    private var bondsDrawer: BondsDrawerView!
    private var drawerWidthConstraint: NSLayoutConstraint!
    private var drawerVisible = true
    private var reviewWindowController: ReviewWindowController?
    private var aiLabel: NSTextField!
    private var focusLabel: NSTextField!
    private var focusInfo = "Focus: awaiting camera"
    private var captureDevice: AVCaptureDevice?
    private var nextAutoAllowedAt: TimeInterval = 0
    private var lastHuntAt: TimeInterval = 0
    private var huntRunning = false
    private var huntHits = 0
    private var noBondChecks = 0
    private var lastDiagnosticAt: TimeInterval = 0
    private var lastVideoLogAt: TimeInterval = 0
    private var session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var photoCaptureSupported = false
    private var chosenFormatWidth = 0
    private var chosenFormatHeight = 0
    private var chosenFormatSubtype = ""
    private var chosenDeviceFormat: AVCaptureDevice.Format?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var deliveredFrameLogged = false
    private var resolutionSettled = false
    private var didReassertFormat = false
    private var didTryHigherFormat = false
    private var latestImage: CGImage?
    private var records: [BondRecord] = []
    private var isProcessing = false
    private var automatic = true
    private var fastScanEnabled = true
    private var lockedAfterCapture = false
    private var frameAnalysisInterval: TimeInterval {
        fastScanEnabled ? 0.25 : 0.55
    }

    private var textHuntInterval: TimeInterval {
        fastScanEnabled ? 0.75 : 1.40
    }

    private var requiredHuntHits: Int {
        fastScanEnabled ? 1 : 2
    }

    private var emptyRearmFramesThreshold: Int {
        fastScanEnabled ? 3 : 6
    }

    private var retryCooldownInterval: TimeInterval {
        fastScanEnabled ? 0.45 : 1.20
    }

    private var rejectCooldownInterval: TimeInterval {
        fastScanEnabled ? 1.20 : 3.00
    }

    /// Normalized serial of the most recently captured bond. Never logged.
    private var lastCapturedSerial = ""
    /// True after a photograph is saved and before OCR has reported its serial.
    private var awaitingSerialFromCapture = false
    private var autoFillRecordId: String?
    private var autoFillAttempts = 0
    private let autoFillMaxAttempts = 4
    private var autoFillRect: CGRect?
    private var autoFillGoneFrames = 0
    private var emptyFrames = 0
    private var priorRect: CGRect?
    private var stableFrames = 0
    private var lastAnalyzeAt: TimeInterval = 0
    private var keyMonitor: Any?
    private let cameraQueue = DispatchQueue(label: "bondscanner.camera", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "bondscanner.analysis", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "bondscanner.ocr", qos: .userInitiated)
    private let saveQueue = DispatchQueue(label: "bondscanner.save", qos: .userInitiated)
    private var photoRequests: [Int64: (automatic: Bool, requestedAt: TimeInterval)] = [:]

    private struct OCRJobContext {
        let id: String
        let originalURL: URL
        let automatic: Bool
        let focusIssueDate: Bool
        let recentIssueDates: [(month: String, year: String)]
        let captureRequestedAt: TimeInterval
        let enqueuedAt: TimeInterval
    }

    private var ocrPending: [OCRJobContext] = []
    private var ocrBusy = false

    private struct PerformanceDiagnostics {
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

    private var diagnostics = PerformanceDiagnostics()

    private var activeHuntToken: UUID?
    private var activeHuntTimestamp: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSClassFromString("XCTestCase") != nil {
            return
        }
        do {
            try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
            let db = try DatabaseManager.initializeShared(url: databaseURL)
            records = try db.migrateFromJSONIfNeeded(jsonURL: recordsURL)
            for i in records.indices {
                applyRequiredStatus(&records[i])
            }
            if let latest = records.max(by: { $0.capturedAt < $1.capturedAt }) {
                let serial = normalizeSerial(latest.serial)
                if !serial.isEmpty {
                    lastCapturedSerial = serial
                }
            }
            try writeRecords(records)
        } catch let err as DatabaseError {
            switch err {
            case let .databaseCorrupted(detail):
                showCorruptionErrorWithRecoveryOption(detail: detail)
                return
            case let .databaseLocked(detail):
                showStartupError("Database is locked by another process: \(detail).\nPlease close any other running instances.")
                return
            case let .permissionDenied(detail):
                showStartupError("Cannot access database due to permissions: \(detail).\nPlease check permissions for ~/BondScans.")
                return
            default:
                showStartupError("Database error: \(err.localizedDescription)")
                return
            }
        } catch {
            showStartupError("Could not open ~/BondScans: \(error.localizedDescription)")
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
        requestCameraAccess()
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
        ScanLog.shared.write("app quit")
        flushAutomaticExports(records: records)
        session.stopRunning()
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Bond Scanner")
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
        let refocus = NSMenuItem(title: "Request Refocus", action: #selector(refocusCamera), keyEquivalent: "r")
        refocus.target = self
        cameraMenu.addItem(refocus)
        cameraItem.submenu = cameraMenu
        bar.addItem(cameraItem)
        NSApp.mainMenu = bar
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openReviewWorkflow() {
        reviewWindowController?.showReviewWindow(selectingRecordId: nil, filter: .allReview)
    }

    @objc private func toggleAutomaticAIReview(_ sender: NSMenuItem) {
        ReviewCoordinator.automaticAIEnabled.toggle()
        sender.state = ReviewCoordinator.automaticAIEnabled ? .on : .off
        status(ReviewCoordinator.automaticAIEnabled
            ? "On-device AI will prepare suggestions for new REVIEW records."
            : "Automatic on-device AI review is off. Manual analysis remains available.")
    }

    @objc private func analyzeExistingReviews() {
        reviewWindowController?.coordinator.analyzeExistingReviews()
        reviewWindowController?.showReviewWindow(selectingRecordId: nil, filter: .allReview)
    }

    @objc private func pauseAIReviewQueue() { reviewWindowController?.coordinator.pauseAIReview() }
    @objc private func resumeAIReviewQueue() { reviewWindowController?.coordinator.resumeAIReview() }
    @objc private func cancelAIReviewQueue() { reviewWindowController?.coordinator.cancelAIReview() }

    @objc private func refocusCamera() {
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

    private func setAutoContrast(enabled: Bool) {
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

    private func applyManualContrastBrightness(contrast: Float, brightness: Float) {
        EnhancementController.shared.update {
            $0.autoContrastEnabled = false
            $0.manualContrast = contrast
            $0.manualBrightness = brightness
        }
    }

    private func applyManualFocusPosition(_ position: Float) {
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
                focusLabel?.stringValue = focusInfo + "  |  Debug: ~/BondScans/scan-debug.log"
            }
        }
    }

    @objc private func openDebugLog() {
        ScanLog.shared.write("user opened debug log")
        NSWorkspace.shared.open(debugURL)
    }

    private func label(_ text: String, size: CGFloat = 15, bold: Bool = false) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        view.textColor = NSColor.labelColor
        view.lineBreakMode = .byTruncatingTail
        return view
    }

    private func makeButton(_ text: String, action: Selector) -> NSButton {
        let b = NSButton(title: text, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 14)
        return b
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Bond Scanner — 100% Local"
        window.center()
        window.minSize = NSSize(width: 1050, height: 660)
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let reviewCoord = ReviewCoordinator(records: records)
        let rwc = ReviewWindowController(coordinator: reviewCoord)
        rwc.onRecordsChanged = { [weak self] updatedRecords in
            guard let self = self else { return }
            self.records = updatedRecords
            self.bondsDrawer?.updateRecords(updatedRecords)
            self.updateCount()
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
        drawerWidthConstraint = bondsDrawer.widthAnchor.constraint(equalToConstant: 420)

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
        root.addSubview(preview)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let scanButton = makeButton("Scan now (Space)", action: #selector(scanNow))
        autoButton = makeButton("Auto: ON", action: #selector(toggleAuto))
        fastButton = makeButton("Fast: ON", action: #selector(toggleFastScan))
        let importButton = makeButton("Import…", action: #selector(importPhotos))
        let exportButton = makeButton("Export CSV…", action: #selector(exportCSVAction))
        let folderButton = makeButton("Open folder", action: #selector(openFolder))
        let undoButton = makeButton("Undo last", action: #selector(undoLast))
        let resetButton = makeButton("Re-arm", action: #selector(rearm))
        let reviewButton = makeButton("Review…", action: #selector(openReviewWorkflow))
        let logButton = makeButton("Log", action: #selector(openDebugLog))
        drawerButton = makeButton("Bonds: ON", action: #selector(toggleDrawer))
        let quitButton = makeButton("Quit", action: #selector(quitApp))
        for b in [scanButton, autoButton!, fastButton!, resetButton, reviewButton, importButton, exportButton, folderButton, undoButton, logButton, drawerButton!, quitButton] {
            toolbar.addArrangedSubview(b)
        }
        root.addSubview(toolbar)

        countLabel = label("0 scanned", size: 21, bold: true)
        statusLabel = label("Starting webcam…", size: 17)
        lastLabel = label("Hold a bond steady inside the yellow guide.", size: 14)
        aiLabel = label("OCR: Apple Vision (offline)", size: 12)
        focusLabel = label("Focus: checking camera…  |  Debug: ~/BondScans/scan-debug.log", size: 12)
        for v in [countLabel!, statusLabel!, lastLabel!, aiLabel!, focusLabel!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bondsDrawer.topAnchor.constraint(equalTo: root.topAnchor),
            bondsDrawer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bondsDrawer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            drawerWidthConstraint,

            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: bondsDrawer.leadingAnchor, constant: -16),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            preview.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 15),
            preview.trailingAnchor.constraint(equalTo: bondsDrawer.leadingAnchor, constant: -15),
            preview.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -14),
            countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            countLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: bondsDrawer.leadingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: lastLabel.topAnchor, constant: -5),
            lastLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            lastLabel.trailingAnchor.constraint(equalTo: bondsDrawer.leadingAnchor, constant: -20),
            lastLabel.bottomAnchor.constraint(equalTo: aiLabel.topAnchor, constant: -5),
            aiLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            aiLabel.bottomAnchor.constraint(equalTo: focusLabel.topAnchor, constant: -4),
            focusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            focusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
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

    private func showStartupError(_ error: String) {
        let alert = NSAlert()
        alert.messageText = "Bond Scanner could not start"
        alert.informativeText = error
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func showCorruptionErrorWithRecoveryOption(detail: String) {
        let alert = NSAlert()
        alert.messageText = "Bond Scanner Database Corrupted"
        alert.informativeText = "The database file at ~/BondScans/bonds.sqlite3 failed integrity checks (\(detail)).\n\nWould you like to recover the database? The existing database and WAL/SHM files will be preserved in a timestamped archive before a clean replacement database is created."
        alert.addButton(withTitle: "Recover Database")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                let recovered = try DatabaseManager.recoverDatabase(at: databaseURL)
                DatabaseManager.setSharedInstance(recovered)
                records = []
                showRecoveryNotice()
            } catch {
                showStartupError("Database recovery failed: \(error.localizedDescription)")
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    private func showRecoveryNotice() {
        let alert = NSAlert()
        alert.messageText = "Database Recovery Completed"
        alert.informativeText = "The corrupted database, WAL, and SHM files were safely archived in ~/BondScans.\nA fresh inventory has been initialized."
        alert.runModal()
    }

    private func status(_ text: String) {
        if Thread.isMainThread {
            statusLabel?.stringValue = text
        } else {
            DispatchQueue.main.async { [weak self] in self?.statusLabel?.stringValue = text }
        }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    if allowed {
                        self?.startCamera()
                    } else {
                        self?.status("Camera permission denied. Use Import photos or enable access in System Settings.")
                    }
                }
            }
        default:
            status("Camera permission denied. Enable Bond Scanner in System Settings → Privacy & Security → Camera.")
        }
    }

    @discardableResult
    private func bondScanTry(_ description: String, _ work: @escaping () -> Void) -> Bool {
        var error: NSError?
        let ok = BondScanTry(work, &error)
        if !ok {
            let detail = error?.localizedDescription ?? "Objective-C exception"
            ScanLog.shared.write("\(description) failed: \(detail); will fall back rather than abort")
        }
        return ok
    }

    /// Apply a device format inside the caller's beginConfiguration/commitConfiguration.
    /// Reads back the actual activeFormat afterward. Never sets photo dimensions
    /// that are not in the CURRENT activeFormat.supportedMaxPhotoDimensions.
    /// Objective-C exceptions are caught so the process cannot abort.
    @discardableResult
    private func applyDeviceFormat(_ format: AVCaptureDevice.Format, on camera: AVCaptureDevice, reason: String) -> Bool {
        let dims = formatDimensions(format)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let desired = desiredFPSForFormatDimensions(dims.width, dims.height)
        var applyFailed = false
        let ok = bondScanTry("\(reason) set activeFormat \(dims.width)x\(dims.height)") {
            do {
                try camera.lockForConfiguration()
                camera.activeFormat = format
                if let frame = preferredFrameDuration(for: format, desiredFPS: desired) {
                    camera.activeVideoMinFrameDuration = frame.duration
                    camera.activeVideoMaxFrameDuration = frame.duration
                    ScanLog.shared.write("\(reason) format=\(dims.width)x\(dims.height) subtype=\(sub) fps=\(String(format: "%.2f", frame.fps)) raw_mbps=\(String(format: "%.0f", estimatedMegabitsPerSecond(width: Int(dims.width), height: Int(dims.height), fps: frame.fps)))")
                } else {
                    ScanLog.shared.write("\(reason) format=\(dims.width)x\(dims.height) subtype=\(sub) fps=device-default")
                }
                camera.unlockForConfiguration()
            } catch {
                applyFailed = true
                camera.unlockForConfiguration()
                ScanLog.shared.write("\(reason) lockForConfiguration failed")
            }
        }
        if !ok || applyFailed {
            return false
        }
        // Trust the format the device actually kept, not the one we requested.
        let actual = camera.activeFormat
        let actualDims = formatDimensions(actual)
        let actualSub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(actual.formatDescription))
        chosenDeviceFormat = actual
        chosenFormatWidth = Int(actualDims.width)
        chosenFormatHeight = Int(actualDims.height)
        chosenFormatSubtype = actualSub
        if Int(actualDims.width) != Int(dims.width) || Int(actualDims.height) != Int(dims.height) {
            ScanLog.shared.write("\(reason) requested \(dims.width)x\(dims.height) but activeFormat is \(actualDims.width)x\(actualDims.height) subtype=\(actualSub)")
        }
        bondScanTry("\(reason) video output settings") {
            self.applyVideoOutputSettings(width: Int(actualDims.width), height: Int(actualDims.height), subtype: actualSub)
        }
        applyPhotoOutputDimensions()
        return true
    }

    private func applyVideoOutputSettings(width: Int, height: Int, subtype: String) {
        guard let output = videoDataOutput else { return }
        let pixelFormat: OSType
        let lower = subtype.lowercased()
        if lower == "420v" {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } else if lower == "420f" {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        } else if lower == "yuvs" {
            pixelFormat = kCVPixelFormatType_422YpCbCr8_yuvs
        } else if lower == "jpeg" || lower == "mjpa" || lower == "mjpb" || lower == "mjpg" {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } else {
            pixelFormat = kCVPixelFormatType_32BGRA
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        output.videoSettings = settings
        ScanLog.shared.write("video output settings \(width)x\(height) pixel_format=\(subtype)")
    }

    /// Set maxPhotoDimensions only to a value listed on the CURRENT
    /// activeFormat.supportedMaxPhotoDimensions. Must be called inside
    /// beginConfiguration/commitConfiguration on the session queue when
    /// the session is already running.
    private func applyPhotoOutputDimensions() {
        guard photoCaptureSupported else { return }
        if #available(macOS 13.0, *) {
            guard let camera = captureDevice else { return }
            let format = camera.activeFormat
            let supported = format.supportedMaxPhotoDimensions
            let listed = supported.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
            let current = photoOutput.maxPhotoDimensions
            guard let best = largestSupportedPhotoDimensions(for: format),
                  photoDimension(best, isIn: supported),
                  best.width > 0, best.height > 0
            else {
                ScanLog.shared.write("photo output supportedMaxPhotoDimensions is empty or unusable for activeFormat \(formatDimensions(format).width)x\(formatDimensions(format).height); stills may match the video frame (current max_photo=\(current.width)x\(current.height))")
                return
            }
            if current.width == best.width, current.height == best.height {
                ScanLog.shared.write("photo output max_photo already \(best.width)x\(best.height) from supported=[\(listed)]")
                return
            }
            // If a leftover value from a previous format is not in the new
            // list, do not leave it set — but only replace it with a value
            // that IS in the current list, and only inside an ObjC try/catch.
            let applied = bondScanTry("set maxPhotoDimensions \(best.width)x\(best.height)") {
                self.photoOutput.maxPhotoDimensions = best
            }
            if applied {
                let now = self.photoOutput.maxPhotoDimensions
                ScanLog.shared.write("photo output max_photo=\(now.width)x\(now.height) from supported=[\(listed)]")
            } else {
                ScanLog.shared.write("left maxPhotoDimensions unchanged after rejection; current=\(current.width)x\(current.height) supported=[\(listed)]")
            }
        }
    }

    private func logActiveFormatState(_ camera: AVCaptureDevice, at moment: String) {
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(camera.activeFormat.formatDescription))
        ScanLog.shared.write("\(moment) active_format=\(dims.width)x\(dims.height) subtype=\(sub) session_preset=\(session.sessionPreset.rawValue) photo_output=\(photoCaptureSupported)")
    }

    /// One-shot re-assert after startRunning, only if the active format
    /// dimensions actually drifted from what we chose. Do not treat a High
    /// preset name as a reason to fight the device again.
    private func reassertChosenFormatIfNeeded(afterStart: Bool) {
        guard !resolutionSettled, let camera = captureDevice, let format = chosenDeviceFormat, !didReassertFormat else { return }
        let dims = formatDimensions(camera.activeFormat)
        if Int(dims.width) == chosenFormatWidth, Int(dims.height) == chosenFormatHeight {
            return
        }
        didReassertFormat = true
        didTryHigherFormat = true
        ScanLog.shared.write("re-asserting format after \(afterStart ? "startRunning" : "setup"); was \(dims.width)x\(dims.height) preset=\(session.sessionPreset.rawValue)")
        session.beginConfiguration()
        let ok = applyDeviceFormat(format, on: camera, reason: "re-assert")
        if !ok {
            apply1080Fallback(on: camera, reason: "re-assert-fallback")
        }
        session.commitConfiguration()
        logActiveFormatState(camera, at: afterStart ? "after_reassert" : "after_setup_reassert")
    }

    @discardableResult
    private func apply1080Fallback(on camera: AVCaptureDevice, reason: String) -> Bool {
        guard let format = select1080FallbackFormat(from: camera.formats) else {
            ScanLog.shared.write("\(reason): no 1920x1080 format is available")
            return false
        }
        return applyDeviceFormat(format, on: camera, reason: reason)
    }

    /// After at most one attempt at a higher format, accept the size the
    /// device is actually delivering (typically 1920x1080 for uncompressed 420v).
    private func handleDeliveredResolutionMismatch(deliveredWidth: Int, deliveredHeight: Int) {
        if resolutionSettled {
            return
        }
        guard let camera = captureDevice else {
            resolutionSettled = true
            return
        }
        let raw = estimatedMegabitsPerSecond(width: chosenFormatWidth, height: chosenFormatHeight, fps: desiredFPSForFormatDimensions(Int32(chosenFormatWidth), Int32(chosenFormatHeight)))
        // A single optional retry was already used at startRunning if the
        // format drifted. Do not try 2560/2048 uncompressed — they need even
        // more bandwidth and previously crashed when photo dimensions were
        // set from a format the session did not keep.
        if !didTryHigherFormat, let hoped = chosenDeviceFormat,
           chosenFormatWidth != deliveredWidth || chosenFormatHeight != deliveredHeight,
           formatIsMJPEG(hoped)
        {
            didTryHigherFormat = true
            ScanLog.shared.write("delivered \(deliveredWidth)x\(deliveredHeight) is smaller than chosen \(chosenFormatWidth)x\(chosenFormatHeight); re-asserting MJPEG format once (est raw \(String(format: "%.0f", raw)) Mbps)")
            session.beginConfiguration()
            let ok = applyDeviceFormat(hoped, on: camera, reason: "mismatch-reassert")
            if !ok {
                apply1080Fallback(on: camera, reason: "mismatch-fallback")
                resolutionSettled = true
            }
            session.commitConfiguration()
            deliveredFrameLogged = false
            return
        }
        acceptDeliveredResolution(deliveredWidth: deliveredWidth, deliveredHeight: deliveredHeight)
    }

    private func acceptDeliveredResolution(deliveredWidth: Int, deliveredHeight: Int) {
        resolutionSettled = true
        didTryHigherFormat = true
        guard let camera = captureDevice else { return }
        let actual = camera.activeFormat
        let d = formatDimensions(actual)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(actual.formatDescription))
        chosenDeviceFormat = actual
        chosenFormatWidth = Int(d.width)
        chosenFormatHeight = Int(d.height)
        chosenFormatSubtype = sub
        session.beginConfiguration()
        bondScanTry("accepted-resolution video settings") {
            self.applyVideoOutputSettings(width: Int(d.width), height: Int(d.height), subtype: sub)
        }
        applyPhotoOutputDimensions()
        session.commitConfiguration()
        logActiveFormatState(camera, at: "accepted_delivered")
        let hoped = "\(deliveredWidth)x\(deliveredHeight)"
        ScanLog.shared.write("hardware/USB could not deliver a 2K uncompressed video frame (got \(hoped); activeFormat is \(d.width)x\(d.height) subtype=\(sub)). Uncompressed 420v above 1080p exceeds this camera's USB 2.0 ceiling (~480 Mbps). Accepting \(d.width)x\(d.height). Preview and stills will use this size; OCR relies on crop, upscale, and multi-frame reads.")
    }

    private func startCamera() {
        let devices = videoCaptureDevices()
        ScanLog.shared.write("video devices found=\(devices.count)")
        guard let camera = devices.first(where: { $0.uniqueID.lowercased().contains("1bcf0b26") || $0.localizedName.lowercased().contains("nexigo") }) ?? devices.first else {
            status("No webcam found. Plug in the NexiGo, then relaunch; you can still import photos.")
            return
        }
        do {
            captureDevice = camera
            logAllCameraFormats(camera)
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            // .inputPriority is unavailable on macOS. Do not set .high: that lets
            // the session override a later activeFormat and deliver 1920x1080.
            // Set activeFormat AFTER inputs and outputs are attached, then lock it.
            guard session.canAddInput(input) else { throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"]) }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: cameraQueue)
            guard session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Video output unavailable"]) }
            session.addOutput(output)
            videoDataOutput = output

            photoCaptureSupported = false
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoCaptureSupported = true
                let codecs = photoOutput.availablePhotoCodecTypes.map { $0.rawValue }.joined(separator: ",")
                ScanLog.shared.write("photo output attached codecs=[\(codecs)]")
            } else {
                ScanLog.shared.write("photo output not supported; stills will use the latest video frame")
            }

            if let best = selectBestCaptureFormat(from: camera.formats) {
                let d = formatDimensions(best)
                let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(best.formatDescription))
                ScanLog.shared.write("selecting format \(d.width)x\(d.height) subtype=\(sub) mjpeg=\(formatIsMJPEG(best))")
                if !applyDeviceFormat(best, on: camera, reason: "chosen") {
                    ScanLog.shared.write("requested camera format unavailable; falling back to 1920x1080")
                    if !apply1080Fallback(on: camera, reason: "chosen-fallback") {
                        ScanLog.shared.write("1080p fallback also failed; leaving the device default")
                    }
                }
            }

            let continuous = camera.isFocusModeSupported(.continuousAutoFocus)
            let autoFocus = camera.isFocusModeSupported(.autoFocus)
            let pointSupported = camera.isFocusPointOfInterestSupported
            let continuousExp = camera.isExposureModeSupported(.continuousAutoExposure)
            let continuousWB = camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
            do {
                try camera.lockForConfiguration()
                if pointSupported {
                    camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                if continuous {
                    camera.focusMode = .continuousAutoFocus
                } else if autoFocus {
                    camera.focusMode = .autoFocus
                }
                if camera.isExposurePointOfInterestSupported {
                    camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                if continuousExp {
                    camera.exposureMode = .continuousAutoExposure
                }
                if continuousWB {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                camera.unlockForConfiguration()
            } catch { ScanLog.shared.write("could not configure autofocus or exposure (camera may manage them internally)") }
            logCameraControls(camera)
            focusInfo = continuous ? "Focus: continuous autofocus requested" :
                (autoFocus ? "Focus: one-shot autofocus requested" : "Focus: webcam controls unavailable / hardware-managed")
            focusLabel.stringValue = focusInfo + "  |  Debug: ~/BondScans/scan-debug.log"

            session.commitConfiguration()
            logActiveFormatState(camera, at: "after_commit")
            ScanLog.shared.write("camera=\(camera.localizedName) uid_matches_nexigo=\(camera.localizedName.lowercased().contains("nexigo")) continuous_focus=\(continuous) one_shot_focus=\(autoFocus) focus_point=\(pointSupported)")
            status("Camera: \(camera.localizedName). Finding bond outline or printed text…")
            deliveredFrameLogged = false
            resolutionSettled = false
            didReassertFormat = false
            didTryHigherFormat = false
            cameraQueue.async {
                self.session.startRunning()
                self.reassertChosenFormatIfNeeded(afterStart: true)
            }
        } catch { status("Camera error: \(error.localizedDescription)") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAnalyzeAt > frameAnalysisInterval else { return }
        lastAnalyzeAt = now
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        if !deliveredFrameLogged {
            deliveredFrameLogged = true
            if let camera = captureDevice {
                logActiveFormatState(camera, at: "first_frame")
            }
            ScanLog.shared.write("delivered video frame=\(cg.width)x\(cg.height) chosen_format=\(chosenFormatWidth)x\(chosenFormatHeight) subtype=\(chosenFormatSubtype) photo_output=\(photoCaptureSupported)")
            if !resolutionSettled, cg.width != chosenFormatWidth || cg.height != chosenFormatHeight {
                let width = cg.width, height = cg.height
                cameraQueue.async { [weak self] in
                    self?.handleDeliveredResolutionMismatch(deliveredWidth: width, deliveredHeight: height)
                }
            } else if !resolutionSettled {
                resolutionSettled = true
                ScanLog.shared.write("delivered video frame matches chosen \(cg.width)x\(cg.height); resolution settled")
            }
        }
        if now - lastVideoLogAt > 15.0 {
            ScanLog.shared.write("receiving video frames=\(cg.width)x\(cg.height) auto=\(automatic)")
            lastVideoLogAt = now
        }
        let rect = detectBond(cg)
        let autoContrastParams: (contrast: Float, brightness: Float)? = EnhancementController.shared.settings.autoContrastEnabled
            ? computeAutoContrastParameters(cg, region: rect)
            : nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.latestImage = cg
            if let auto = autoContrastParams {
                self.preview.reflectAutoContrast(contrast: auto.contrast, brightness: auto.brightness)
            }
            if self.automatic {
                self.handleRectangle(rect, frame: cg)
            } else {
                self.preview.sourceSize = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
                self.preview.showDetected(rect)
            }
        }
    }

    private func handleRectangle(_ rect: CGRect?, frame: CGImage) {
        preview.sourceSize = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        preview.showDetected(rect)
        let now = Date().timeIntervalSince1970
        // During an auto-fill retry, a removed or replaced bond must end the
        // retry immediately. "Still some paper in view" is not the same bond.
        if autoFillRecordId != nil, !lockedAfterCapture {
            if let rect = rect {
                autoFillGoneFrames = 0
                if let start = autoFillRect, rectangleChangedForScene(rect, start) {
                    endAutoFill(reason: "rectangle changed")
                    stableFrames = 0
                    priorRect = rect
                } else if autoFillRect == nil {
                    autoFillRect = rect
                }
            } else {
                autoFillGoneFrames += 1
                if autoFillGoneFrames >= 2 {
                    endAutoFill(reason: "bond removed")
                    stableFrames = 0
                    priorRect = nil
                }
            }
        }
        if lockedAfterCapture {
            // The bond is still in view if a paper outline is visible — do not re-arm.
            if rect != nil {
                emptyFrames = 0
                noBondChecks = 0
            } else {
                emptyFrames += 1
                if fastScanEnabled, emptyFrames >= emptyRearmFramesThreshold, !isProcessing {
                    lockedAfterCapture = false
                    emptyFrames = 0
                    noBondChecks = 0
                    huntHits = 0
                    priorRect = nil
                    autoFillRecordId = nil
                    autoFillAttempts = 0
                    autoFillRect = nil
                    autoFillGoneFrames = 0
                    status("Ready for next bond. Slide the next bond in…")
                    ScanLog.shared.write("re-armed after bond removed (fast outline clear)")
                    return
                }
            }
            scheduleTextHunt(frame, forRearm: true, rectangleVisible: rect != nil)
            return
        }
        guard automatic, !isProcessing, now >= nextAutoAllowedAt else { return }
        if let rect = rect {
            let maxShift: CGFloat = fastScanEnabled ? 0.025 : 0.05
            let maxScale: CGFloat = fastScanEnabled ? 0.04 : 0.075
            if let prior = priorRect,
               abs(rect.midX - prior.midX) < maxShift,
               abs(rect.midY - prior.midY) < maxShift,
               abs(rect.width - prior.width) < maxScale,
               abs(rect.height - prior.height) < maxScale
            {
                stableFrames += 1
            } else {
                stableFrames = 1
            }
            priorRect = rect
            if stableFrames >= 2 {
                stableFrames = 0
                huntHits = 0
                ScanLog.shared.write("auto capture: stable outline; OCR starts")
                performScan(frame, automaticScan: true)
                return
            }
        } else {
            stableFrames = 0
            priorRect = nil
        }
        if now - lastDiagnosticAt > 4 {
            ScanLog.shared.write("hunting: rectangle=\(rect != nil) stable_frames=\(stableFrames) locked=\(lockedAfterCapture)")
            lastDiagnosticAt = now
        }
        scheduleTextHunt(frame, forRearm: false)
    }

    private func scheduleTextHunt(_ frame: CGImage, forRearm: Bool, rectangleVisible: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard !huntRunning, !isProcessing, now - lastHuntAt > textHuntInterval else { return }
        lastHuntAt = now
        huntRunning = true
        let huntToken = UUID()
        activeHuntToken = huntToken
        activeHuntTimestamp = now
        if !forRearm {
            status("Hunting for the bond: checking text and all four rotations…")
        }
        analysisQueue.async { [weak self] in
            let probe = probeForBond(frame)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.huntRunning = false
                guard self.activeHuntToken == huntToken else {
                    ScanLog.shared.write("ocr hunt: superseded by newer request")
                    return
                }
                let elapsed = Date().timeIntervalSince1970 - now
                if elapsed > 1.8 {
                    ScanLog.shared.write("ocr hunt: rejected stale probe results elapsed=\(String(format: "%.2f", elapsed))s")
                    return
                }
                let hasBond = probe.found && probe.score >= 52 && probe.lines >= 4
                // For re-arm, treat any bond signal, moderate score, or visible outline as "still present".
                // The stricter hasBond threshold previously re-armed while a Series E was still in view.
                let stillPresent = probe.found || probe.score >= 20 || rectangleVisible
                ScanLog.shared.write("ocr hunt: score=\(probe.score) lines=\(probe.lines) bond_signal=\(probe.found) accepted=\(hasBond) still_present=\(stillPresent) rearm_check=\(forRearm)")
                if forRearm {
                    guard self.lockedAfterCapture else { return }
                    let viewedSerial = probe.serial
                    let lastSerial = self.lastCapturedSerial
                    let sameAsLast = !viewedSerial.isEmpty && !lastSerial.isEmpty
                        && (serialsMatchForMerge(viewedSerial, lastSerial).exact
                            || serialsMatchForMerge(viewedSerial, lastSerial).near)
                    let newBondSerial = !viewedSerial.isEmpty && !sameAsLast
                    if newBondSerial, !self.awaitingSerialFromCapture, !self.isProcessing {
                        self.lockedAfterCapture = false
                        self.noBondChecks = 0
                        self.huntHits = 0
                        self.priorRect = nil
                        self.autoFillRecordId = nil
                        self.autoFillAttempts = 0
                        self.autoFillRect = nil
                        self.autoFillGoneFrames = 0
                        self.status("New bond detected — holding for focus…")
                        ScanLog.shared.write("re-armed: serial in view is not the last captured bond")
                        return
                    }
                    if stillPresent {
                        self.noBondChecks = 0
                    } else {
                        self.noBondChecks += 1
                    }
                    if self.noBondChecks >= 2 {
                        self.lockedAfterCapture = false
                        self.noBondChecks = 0
                        self.huntHits = 0
                        self.priorRect = nil
                        self.autoFillRecordId = nil
                        self.autoFillAttempts = 0
                        self.autoFillRect = nil
                        self.autoFillGoneFrames = 0
                        self.status("Ready for next bond. Hunting for edges or text…")
                        ScanLog.shared.write("re-armed after two empty OCR checks")
                    } else if stillPresent {
                        if newBondSerial, self.awaitingSerialFromCapture {
                            ScanLog.shared.write("re-arm deferred: waiting for captured serial")
                        } else if sameAsLast {
                            ScanLog.shared.write("re-arm deferred: same serial still in view")
                        } else {
                            ScanLog.shared.write("re-arm deferred: bond still in view")
                        }
                    }
                    return
                }
                guard !self.lockedAfterCapture, !self.isProcessing, self.automatic else { return }
                if hasBond {
                    self.huntHits += 1
                    self.status("Bond text found (\(self.huntHits)/\(self.requiredHuntHits)). Hold steady…")
                    if self.huntHits >= self.requiredHuntHits {
                        self.huntHits = 0
                        ScanLog.shared.write("auto capture: fallback OCR detected bond without stable outline")
                        self.performScan(self.latestImage ?? frame, automaticScan: true)
                    }
                } else {
                    self.huntHits = 0
                    self.status("No readable bond yet — adjust distance/light or press Space to capture for review.")
                }
            }
        }
    }

    @objc private func scanNow() {
        // Manual capture never waits on rectangle detection or an in-flight OCR job.
        requestPhotograph(automatic: false)
    }

    private func performScan(_ image: CGImage, automaticScan: Bool) {
        if automaticScan {
            guard !isProcessing else { return }
            requestPhotograph(automatic: true, fallback: image)
            return
        }
        requestPhotograph(automatic: false, fallback: image)
    }

    private func requestPhotograph(automatic: Bool, fallback: CGImage? = nil) {
        let requestedAt = Date().timeIntervalSince1970
        if photoCaptureSupported, session.isRunning {
            let settings = AVCapturePhotoSettings()
            if #available(macOS 13.0, *) {
                let max = photoOutput.maxPhotoDimensions
                let supported = captureDevice?.activeFormat.supportedMaxPhotoDimensions ?? []
                if max.width > 0, max.height > 0, photoDimension(max, isIn: supported) {
                    settings.maxPhotoDimensions = max
                }
            }
            photoRequests[settings.uniqueID] = (automatic: automatic, requestedAt: requestedAt)
            if automatic {
                isProcessing = true
            } else {
                lockedAfterCapture = true
            }
            let waiting = ocrPending.count + (ocrBusy ? 1 : 0)
            ScanLog.shared.write("photograph requested mode=\(automatic ? "auto" : "manual") via=photoOutput ocr_queue=\(waiting)")
            photoOutput.capturePhoto(with: settings, delegate: self)
            if !automatic {
                status(waiting > 0
                    ? "Capturing photograph… (\(waiting) still being read)."
                    : "Capturing full-resolution photograph…")
            }
            return
        }
        let image = fallback ?? latestImage
        guard let image = image else {
            if automatic {
                isProcessing = false
            } else {
                status("No image from camera yet.")
            }
            return
        }
        if automatic {
            isProcessing = true
        } else {
            lockedAfterCapture = true
        }
        ScanLog.shared.write("photograph requested mode=\(automatic ? "auto" : "manual") via=videoFrame frame=\(image.width)x\(image.height)")
        finishCapture(image: image, jpegBytes: nil, automatic: automatic, requestedAt: requestedAt)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let uniqueID = photo.resolvedSettings.uniqueID
        let dims = photo.resolvedSettings.photoDimensions
        let failure = error
        let jpeg = (failure == nil) ? photo.fileDataRepresentation() : nil
        let cg = (failure == nil) ? photo.cgImageRepresentation() : nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let requestInfo = self.photoRequests.removeValue(forKey: uniqueID)
            let automatic = requestInfo?.automatic ?? false
            let requestedAt = requestInfo?.requestedAt ?? Date().timeIntervalSince1970
            if failure != nil {
                ScanLog.shared.write("photo output failed; falling back to video frame")
                if let frame = self.latestImage {
                    self.finishCapture(image: frame, jpegBytes: nil, automatic: automatic, requestedAt: requestedAt)
                } else if automatic {
                    self.isProcessing = false
                } else {
                    self.status("Photograph capture failed and no video frame is available.")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                }
                return
            }
            ScanLog.shared.write("photo output captured \(dims.width)x\(dims.height)")
            let image = cg ?? jpeg.flatMap { cgImageFromData($0) }
            guard let image = image else {
                if let frame = self.latestImage {
                    self.finishCapture(image: frame, jpegBytes: nil, automatic: automatic, requestedAt: requestedAt)
                } else if automatic {
                    self.isProcessing = false
                } else {
                    self.status("Photograph could not be decoded.")
                    self.preview.captureFlash(color: .systemRed)
                }
                return
            }
            self.finishCapture(image: image, jpegBytes: jpeg, automatic: automatic, requestedAt: requestedAt)
        }
    }

    private func shouldFocusIssueDate() -> Bool {
        // When the bond still in view is only missing a confident issue date,
        // auto-retry zooms the date box (more crops, higher upscale, more variants).
        if let aid = autoFillRecordId, let existing = records.first(where: { $0.id == aid }) {
            return requiredFieldsMissing(existing).contains("issue date")
        }
        return false
    }

    private func applySequenceFlag(_ record: inout BondRecord) {
        // Sequence disagreement is surfaced as date_check=uncertain in the CSV.
        // It must not force REVIEW now that a valid serial and face value are enough for green.
        applyRequiredStatus(&record)
    }

    private func finishCapture(image: CGImage, jpegBytes: Data?, automatic: Bool, requestedAt: TimeInterval) {
        commitOriginalAndEnqueue(image: image, jpegBytes: jpegBytes, automatic: automatic, requestedAt: requestedAt)
    }

    private func commitOriginalAndEnqueue(image: CGImage, jpegBytes: Data?, automatic: Bool = false, requestedAt: TimeInterval = Date().timeIntervalSince1970) {
        let id = UUID().uuidString
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let filename = "\(capturedAt.replacingOccurrences(of: ":", with: "-"))_\(id.prefix(8)).jpg"
        let originalRel = "photos/original_" + filename
        let processedRel = "photos/" + filename
        let originalURL = outputRoot.appendingPathComponent(originalRel)
        let width = image.width
        let height = image.height

        let quality = evaluateImageQuality(image)
        var qualityNotes: [String] = []
        if quality.isBlurry {
            qualityNotes.append("blurry (sharpness: \(String(format: "%.1f", quality.sharpnessScore)))")
        }
        if quality.isUnderExposed {
            qualityNotes.append("underexposed (mean: \(String(format: "%.1f", quality.meanLuminance)))")
        }
        if quality.isOverExposed {
            qualityNotes.append("overexposed (mean: \(String(format: "%.1f", quality.meanLuminance)))")
        }

        saveQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = jpegBytes ?? jpegData(image) else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.status("SAVE FAILED: could not encode the photograph.")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph encode failed")
                }
                return
            }
            do {
                try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
                try data.write(to: originalURL, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.status("SAVE FAILED: \(error.localizedDescription)")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph save failed")
                }
                return
            }
            DispatchQueue.main.async {
                let captureLatencyMs = (Date().timeIntervalSince1970 - requestedAt) * 1000.0
                self.diagnostics.totalCaptures += 1
                self.diagnostics.totalCaptureTimeMs += captureLatencyMs

                var record = emptyBondRecord(id: id, capturedAt: capturedAt)
                record.photo = processedRel
                record.sourcePhoto = originalRel
                if !qualityNotes.isEmpty {
                    record.notes = "Quality: \(qualityNotes.joined(separator: ", "))"
                }
                let previous = self.records
                self.records.append(record)
                do { try saveRecordLive(record, allRecords: self.records, sortOrder: self.records.count - 1) }
                catch {
                    self.isProcessing = false
                    self.records = previous
                    self.status("DATABASE SAVE FAILED: \(error.localizedDescription). Photo preserved on disk.")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph record write failed; photo file preserved on disk")
                    return
                }
                self.updateCount()
                self.preview.captureFlash(color: .systemBlue)
                NSSound(named: NSSound.Name("Glass"))?.play()
                self.isProcessing = false
                self.lockedAfterCapture = true
                self.awaitingSerialFromCapture = true
                self.emptyFrames = 0
                let waiting = self.ocrPending.count + (self.ocrBusy ? 1 : 0)
                self.diagnostics.highWaterQueueDepth = max(self.diagnostics.highWaterQueueDepth, waiting + 1)
                if waiting == 0 {
                    self.status("Captured (\(width)×\(height))! Slide next bond in — reading in background…")
                } else {
                    self.status("Captured (\(width)×\(height))! Slide next bond in (\(waiting) in OCR queue).")
                }
                self.lastLabel.stringValue = "Last: photograph saved, OCR pending…"
                ScanLog.shared.write("original saved status=PROCESSING frame=\(width)x\(height) bytes=\(data.count) total=\(self.records.count) capture_latency_ms=\(String(format: "%.1f", captureLatencyMs)) ocr_queue=\(waiting + 1) hwm=\(self.diagnostics.highWaterQueueDepth) sharpness=\(String(format: "%.1f", quality.sharpnessScore)) lum=\(String(format: "%.1f", quality.meanLuminance))")
                self.enqueueOCR(id: id, originalURL: originalURL, automatic: automatic, requestedAt: requestedAt)
            }
        }
    }

    private func enqueueOCR(id: String, originalURL: URL, automatic: Bool, requestedAt: TimeInterval = Date().timeIntervalSince1970) {
        let focus = shouldFocusIssueDate()
        let recent = recentScanIssueDates(before: ISO8601DateFormatter().string(from: Date()), among: records)
        let job = OCRJobContext(
            id: id,
            originalURL: originalURL,
            automatic: automatic,
            focusIssueDate: focus,
            recentIssueDates: recent,
            captureRequestedAt: requestedAt,
            enqueuedAt: Date().timeIntervalSince1970
        )
        ocrPending.append(job)
        pumpOCR()
    }

    private func pumpOCR() {
        guard !ocrBusy, let job = ocrPending.first else { return }
        ocrPending.removeFirst()
        ocrBusy = true
        reviewWindowController?.coordinator.setAIBackgroundWorkDeferred(true)
        let remaining = ocrPending.count
        status("Reading the saved photograph with Apple Vision OCR…" + (remaining > 0 ? " (\(remaining) waiting)." : ""))
        ocrQueue.async { [weak self] in
            guard let self = self else { return }
            guard let image = cgImageFromFile(job.originalURL) else {
                DispatchQueue.main.async {
                    self.markOCRFailed(id: job.id, message: "Could not read the saved photograph for OCR. The original file is still in the output folder.")
                    self.ocrBusy = false
                    self.pumpOCR()
                    self.reviewWindowController?.coordinator.setAIBackgroundWorkDeferred(self.ocrBusy || !self.ocrPending.isEmpty)
                }
                return
            }
            let ocrStartTime = Date().timeIntervalSince1970
            ScanLog.shared.write("ocr of saved photograph started frame=\(image.width)x\(image.height)")
            let result = scanImage(image, focusIssueDate: job.focusIssueDate, recentIssueDates: job.recentIssueDates)
            let processingMs = (Date().timeIntervalSince1970 - ocrStartTime) * 1000.0
            DispatchQueue.main.async {
                self.diagnostics.totalOCRCompleted += 1
                self.diagnostics.totalProcessingTimeMs += processingMs
                ScanLog.shared.write("ocr finished processing_ms=\(String(format: "%.1f", processingMs)) avg_ocr_ms=\(String(format: "%.1f", self.diagnostics.averageOCRLatencyMs)) bpm=\(String(format: "%.1f", self.diagnostics.throughputBondsPerMinute)) queue_remaining=\(self.ocrPending.count)")
                self.applyOCR(result, to: job.id)
                self.ocrBusy = false
                self.pumpOCR()
                self.reviewWindowController?.coordinator.setAIBackgroundWorkDeferred(self.ocrBusy || !self.ocrPending.isEmpty)
            }
        }
    }

    private func markOCRFailed(id: String, message: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records[index]
        updated.status = "REVIEW"
        updated.notes = message
        updated.revision = (updated.revision ?? 0) + 1
        let dest = outputRoot.appendingPathComponent(updated.photo)
        let src = outputRoot.appendingPathComponent(updated.sourcePhoto)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: src, to: dest)
        }
        var proposed = records
        proposed[index] = updated
        do {
            try saveRecordLive(updated, allRecords: proposed, sortOrder: index)
            records = proposed
        } catch {
            status("OCR failure state could not be saved: \(error.localizedDescription). Photo preserved.")
            ScanLog.shared.write("ocr failure state write failed; photo preserved")
            return
        }
        updateCount()
        preview.captureFlash(color: .systemRed)
        status(message)
        awaitingSerialFromCapture = false
        ScanLog.shared.write("ocr failed; original photograph preserved")
    }

    private func writeProcessedImage(_ image: CGImage, to relative: String, fallbackSource: String) {
        let dest = outputRoot.appendingPathComponent(relative)
        let original = outputRoot.appendingPathComponent(fallbackSource)
        do {
            if let data = jpegData(image) {
                try data.write(to: dest, options: .atomic)
            } else if FileManager.default.fileExists(atPath: original.path) {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: original, to: dest)
            }
        } catch {
            ScanLog.shared.write("processed photograph write issue; original is preserved")
            if !FileManager.default.fileExists(atPath: dest.path), FileManager.default.fileExists(atPath: original.path) {
                try? FileManager.default.copyItem(at: original, to: dest)
            }
        }
    }

    private func trashCapturePhotos(_ record: BondRecord) {
        for rel in [record.photo, record.sourcePhoto] where !rel.isEmpty {
            let usedElsewhere = records.contains { other in
                other.id != record.id && (
                    other.photo == rel || other.sourcePhoto == rel
                        || (other.fieldPhoto ?? [:]).values.contains(rel)
                )
            }
            if usedElsewhere {
                continue
            }
            let url = outputRoot.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    private func priorRecord(for incoming: BondRecord) -> BondRecord? {
        // Indexed SQLite normalized-serial lookup first.
        if let indexedMatches = try? DatabaseManager.shared.findRecordsByNormalizedSerial(incoming.serial, excludingId: incoming.id) {
            for candidate in indexedMatches {
                let match = records.first(where: { $0.id == candidate.id }) ?? candidate
                if canMergeCapture(incoming, into: match) {
                    return match
                }
            }
        }
        // Exact normalized serial in-memory fallback.
        if let match = recordMatchingSerial(incoming.serial, in: records, excluding: incoming.id),
           canMergeCapture(incoming, into: match)
        {
            return match
        }
        // Auto-fill / "still in view" is never a reason to merge on its own.
        return nil
    }

    private func endAutoFill(reason: String) {
        guard autoFillRecordId != nil else { return }
        ScanLog.shared.write("auto fill ended: \(reason)")
        autoFillRecordId = nil
        autoFillAttempts = 0
        autoFillRect = nil
        autoFillGoneFrames = 0
    }

    private func presentRecord(_ record: BondRecord, flash: NSColor, message: String, automatic: Bool, contributed: Bool, isNew: Bool) {
        var record = record
        let priorStatus = record.status
        let priorNotes = record.notes
        applySequenceFlag(&record)
        if record.status != priorStatus || record.notes != priorNotes,
           let idx = records.firstIndex(where: { $0.id == record.id })
        {
            records[idx] = record
            try? saveRecordLive(record, allRecords: records, sortOrder: idx)
        }
        updateCount()
        let serialDisplay = record.serial.isEmpty ? "unreadable serial" : record.serial
        lastLabel.stringValue = "Last: \(record.series) \(serialDisplay) | \(record.issueMonth)/\(record.issueYear) | $\(record.denomination) | \(record.status)"
        let captured = normalizeSerial(record.serial)
        if !captured.isEmpty {
            lastCapturedSerial = captured
        }
        awaitingSerialFromCapture = false
        preview.captureFlash(color: flash)
        status(message)
        emptyFrames = 0
        // AI is suggestion-only and queued after normal OCR/capture has completed.
        // It never runs on the capture or Vision queues.
        if contributed, record.status == "REVIEW" {
            reviewWindowController?.coordinator.automaticallyReviewIfEligible(record)
        }
        if automatic {
            if isNew {
                autoFillRecordId = record.id; autoFillAttempts = 1
            } else {
                autoFillAttempts += 1
            }
            autoFillRecordId = record.id
            if requiredFieldsComplete(record) {
                lockedAfterCapture = true
                autoFillAttempts = autoFillMaxAttempts
                autoFillRect = nil
                ScanLog.shared.write("auto fill complete required_fields=all attempts=\(autoFillAttempts)")
            } else if autoFillAttempts >= autoFillMaxAttempts {
                lockedAfterCapture = true
                autoFillRect = nil
                ScanLog.shared.write("auto fill exhausted attempts=\(autoFillAttempts) missing=\(requiredFieldsMissing(record).joined(separator: ","))")
            } else {
                lockedAfterCapture = false
                if autoFillRect == nil {
                    autoFillRect = priorRect
                }
                nextAutoAllowedAt = Date().timeIntervalSince1970 + retryCooldownInterval
                ScanLog.shared.write("auto fill retry attempts=\(autoFillAttempts)/\(autoFillMaxAttempts) missing=\(requiredFieldsMissing(record).joined(separator: ","))")
            }
        } else {
            lockedAfterCapture = true
        }
    }

    private func applyOCR(_ result: OCRResult, to id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            ScanLog.shared.write("ocr result ignored; record no longer present")
            return
        }
        let row = records[index]
        var incoming = result.record
        incoming.id = row.id
        incoming.capturedAt = row.capturedAt
        incoming.sourcePhoto = row.sourcePhoto
        incoming.photo = row.photo
        incoming.revision = (row.revision ?? 0) + 1
        applyRequiredStatus(&incoming)

        // Prevent stale OCR jobs from overwriting newer user changes
        if row.status != "PROCESSING" {
            var preserved = row
            _ = mergeBondRecord(from: incoming, into: &preserved,
                                contributingPhoto: row.photo,
                                contributingSource: row.sourcePhoto,
                                captureId: row.id)
            incoming = preserved
        }

        if let aid = autoFillRecordId, let target = records.first(where: { $0.id == aid }),
           aid != incoming.id, !canMergeCapture(incoming, into: target)
        {
            let reason = normalizeSerial(incoming.serial).isEmpty
                ? "serial unreadable on retry; saving as new record"
                : "serial does not match retry target; saving as new record"
            endAutoFill(reason: reason)
        }

        // DUPLICATE CONSOLIDATION: Exact, validated serial match with no conflicting fields
        // Prioritized before near-matches so valid captures are not misclassified as near-duplicates
        if let prior = priorRecord(for: incoming), let priorIndex = records.firstIndex(where: { $0.id == prior.id }) {
            var merged = records[priorIndex]
            let filled = mergeBondRecord(from: incoming, into: &merged,
                                         contributingPhoto: incoming.photo,
                                         contributingSource: incoming.sourcePhoto,
                                         captureId: incoming.id)
            if filled.isEmpty {
                // Exact match with no new fields. Keep the original photograph on disk. Never trash it!
                let preserveNote = "Duplicate scan photo preserved at \(incoming.sourcePhoto)"
                merged.notes = merged.notes.isEmpty ? preserveNote : "\(merged.notes); \(preserveNote)"
                let previous = records
                records.removeAll { $0.id == incoming.id }
                if let idx = records.firstIndex(where: { $0.id == prior.id }) {
                    records[idx] = merged
                }
                do {
                    try mergeRecordLive(deleteId: incoming.id, updatedRecord: merged, allRecords: records, sortOrder: priorIndex)
                    ScanLog.shared.write("duplicate consolidated atomically into prior id=\(prior.id.prefix(8)); photo preserved")
                    presentRecord(merged, flash: .systemOrange,
                                  message: "Same bond — no new required fields. Photograph preserved.",
                                  automatic: false, contributed: false, isNew: false)
                } catch {
                    records = previous
                    status("Atomic duplicate merge failed: \(error.localizedDescription). Photo preserved.")
                    preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("atomic duplicate merge failed; photo preserved")
                }
                return
            }
            writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
            let previous = records
            records.removeAll { $0.id == incoming.id }
            let targetIndex: Int
            if let idx = records.firstIndex(where: { $0.id == prior.id }) {
                records[idx] = merged
                targetIndex = idx
            } else {
                records.append(merged)
                targetIndex = records.count - 1
            }
            do {
                try mergeRecordLive(deleteId: incoming.id, updatedRecord: merged, allRecords: records, sortOrder: targetIndex)
            } catch {
                records = previous
                status("OCR results could not be merged: \(error.localizedDescription). Photo preserved.")
                preview.captureFlash(color: .systemRed)
                NSSound.beep()
                ScanLog.shared.write("atomic merge failed; photo preserved")
                return
            }
            let fieldList = filled.joined(separator: ", ")
            ScanLog.shared.write("merged fields=\(fieldList) into existing record atomically; photograph kept (prior id=\(prior.id.prefix(8))) status=\(merged.status)")
            let flash: NSColor = requiredFieldsComplete(merged) ? .systemGreen : .systemYellow
            let message = requiredFieldsComplete(merged)
                ? "Updated the existing record with \(fieldList). All required fields verified. Remove the bond."
                : "Updated the existing record with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", "))."
            presentRecord(merged, flash: flash, message: message, automatic: false, contributed: true, isNew: false)
            return
        }

        // DUPLICATE SAFETY: OCR-confusable near-match handling (Priority 2)
        // Never automatically merge near-matches. Preserve as a separate record for user review with structured review reason.
        if let near = findNearMatchRecord(incoming, in: records, excluding: incoming.id) {
            writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
            annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
            var reasons = Set(incoming.reviewReasons ?? [])
            reasons.insert("near_match: \(near.id)")
            incoming.reviewReasons = Array(reasons).sorted()
            incoming.status = "REVIEW"
            let nearNote = "Near-match with existing record (id: \(near.id.prefix(8))) — preserved as separate record for user review"
            if !incoming.notes.contains(nearNote) {
                incoming.notes = incoming.notes.isEmpty ? nearNote : "\(incoming.notes); \(nearNote)"
            }
            let previous = records
            records[index] = incoming
            do {
                try saveRecordLive(incoming, allRecords: records, sortOrder: index)
                ScanLog.shared.write("near match preserved as separate review record; photo preserved (near id=\(near.id.prefix(8)))")
                presentRecord(incoming, flash: .systemYellow,
                              message: "Near-match detected. Preserved as separate record for user review.",
                              automatic: false, contributed: true, isNew: true)
                return
            } catch {
                records = previous
                status("Near-match record could not be saved: \(error.localizedDescription)")
                preview.captureFlash(color: .systemRed)
                NSSound.beep()
                ScanLog.shared.write("near-match record write failed; photograph preserved")
                return
            }
        }

        writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
        annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
        applyRequiredStatus(&incoming)
        let previous = records
        records[index] = incoming
        do { try saveRecordLive(incoming, allRecords: records, sortOrder: index) }
        catch {
            records = previous
            status("OCR results could not be saved: \(error.localizedDescription)")
            preview.captureFlash(color: .systemRed)
            NSSound.beep()
            ScanLog.shared.write("ocr record write failed; original photograph preserved")
            return
        }
        ScanLog.shared.write("scan updated status=\(incoming.status) fields_nonempty=\([incoming.series, incoming.serial, incoming.issueMonth, incoming.issueYear, incoming.denomination].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
        let flash: NSColor = incoming.status == "OK" ? .systemGreen : .systemYellow
        let message = incoming.status == "OK"
            ? "OCR complete — verified. Remove the bond, then show the next one."
            : "OCR complete — review needed (\(requiredFieldsMissing(incoming).joined(separator: ", "))). Remove the bond, then show the next one."
        presentRecord(incoming, flash: flash, message: message, automatic: false, contributed: true, isNew: true)
    }

    private func handleOCR(_ result: OCRResult, auto: Bool) {
        var incoming = result.record
        applyRequiredStatus(&incoming)

        if auto, autoFillRecordId == nil, !result.bondTextFound || result.huntScore < 45 {
            nextAutoAllowedAt = Date().timeIntervalSince1970 + rejectCooldownInterval
            ScanLog.shared.write("auto scan rejected: low OCR evidence score=\(result.huntScore) count=\(result.lineCount)")
            isProcessing = false
            status("Not readable — improve lighting/focus, reposition, or press Space to save for review.")
            return
        }

        // Never merge a retry into the auto-fill target unless this capture's
        // own serial matches. A mismatch or unreadable serial ends the retry
        // and is saved as a new record below.
        if auto, let aid = autoFillRecordId, let target = records.first(where: { $0.id == aid }), !canMergeCapture(incoming, into: target) {
            let reason = normalizeSerial(incoming.serial).isEmpty
                ? "serial unreadable on retry; saving as new record"
                : "serial does not match retry target; saving as new record"
            endAutoFill(reason: reason)
        }

        // DUPLICATE SAFETY: OCR-confusable near-match handling
        // Never automatically merge near-matches. Preserve as a separate record for user review.
        if let near = findNearMatchRecord(incoming, in: records, excluding: incoming.id) {
            let filename = "\(incoming.capturedAt.replacingOccurrences(of: ":", with: "-"))_\(incoming.id.prefix(8)).jpg"
            incoming.photo = "photos/" + filename
            incoming.sourcePhoto = "photos/original_" + filename
            annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
            incoming.status = "REVIEW"
            let nearNote = "Near-match with existing record (id: \(near.id.prefix(8))) — preserved as separate record for user review"
            incoming.notes = incoming.notes.isEmpty ? nearNote : "\(incoming.notes); \(nearNote)"
            do {
                guard let original = jpegData(result.originalImage) else {
                    throw NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original JPEG encoding failed"])
                }
                try original.write(to: outputRoot.appendingPathComponent(incoming.sourcePhoto), options: .atomic)
                writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
                let previous = records
                records.append(incoming)
                do { try saveRecordLive(incoming, allRecords: records, sortOrder: records.count - 1) }
                catch { records = previous; throw error }
                ScanLog.shared.write("near match preserved as separate review record; photo preserved (near id=\(near.id.prefix(8)))")
                isProcessing = false
                presentRecord(incoming, flash: .systemYellow,
                              message: "Near-match detected. Preserved as separate record for user review.",
                              automatic: auto, contributed: true, isNew: true)
                return
            } catch {
                ScanLog.shared.write("near-match save failed")
                status("SAVE FAILED: \(error.localizedDescription)")
                NSSound.beep()
                isProcessing = false
                return
            }
        }

        // DUPLICATE CONSOLIDATION: Exact, validated serial match with no conflicting fields
        if let prior = priorRecord(for: incoming), let priorIndex = records.firstIndex(where: { $0.id == prior.id }) {
            var merged = records[priorIndex]
            let filled = mergeBondRecord(from: incoming, into: &merged, contributingPhoto: "", contributingSource: "", captureId: incoming.id)
            let filename = "\(incoming.capturedAt.replacingOccurrences(of: ":", with: "-"))_\(incoming.id.prefix(8)).jpg"
            incoming.photo = "photos/" + filename
            incoming.sourcePhoto = "photos/original_" + filename

            do {
                guard let original = jpegData(result.originalImage) else {
                    throw NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original JPEG encoding failed"])
                }
                try original.write(to: outputRoot.appendingPathComponent(incoming.sourcePhoto), options: .atomic)

                if filled.isEmpty {
                    let preserveNote = "Duplicate scan photo preserved at \(incoming.sourcePhoto)"
                    merged.notes = merged.notes.isEmpty ? preserveNote : "\(merged.notes); \(preserveNote)"
                    records[priorIndex] = merged
                    try saveRecordLive(merged, allRecords: records, sortOrder: priorIndex)
                    ScanLog.shared.write("duplicate photo saved; no new required fields (prior id=\(prior.id.prefix(8)))")
                    isProcessing = false
                    if auto {
                        presentRecord(merged, flash: .systemOrange,
                                      message: requiredFieldsComplete(merged)
                                          ? "Same bond already verified. Remove it before the next one."
                                          : "Same bond — no new required fields. Trying again…",
                                      automatic: auto, contributed: false, isNew: false)
                    } else {
                        presentRecord(merged, flash: .systemOrange,
                                      message: "Same bond — no new required fields. Photograph preserved.",
                                      automatic: false, contributed: false, isNew: false)
                    }
                    return
                }

                // Contributing retry: point new fields at this photo
                writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
                merged = records[priorIndex]
                let filled2 = mergeBondRecord(from: incoming, into: &merged,
                                              contributingPhoto: incoming.photo,
                                              contributingSource: incoming.sourcePhoto,
                                              captureId: incoming.id)
                records[priorIndex] = merged
                try saveRecordLive(merged, allRecords: records, sortOrder: priorIndex)
                let fieldList = (filled2.isEmpty ? filled : filled2).joined(separator: ", ")
                ScanLog.shared.write("merged fields=\(fieldList) into existing record; photograph kept (prior id=\(prior.id.prefix(8))) status=\(merged.status)")
                isProcessing = false
                let flash: NSColor = requiredFieldsComplete(merged) ? .systemGreen : .systemYellow
                let message: String
                if requiredFieldsComplete(merged) {
                    message = "Updated the existing record with \(fieldList). All required fields verified. Remove the bond."
                } else if auto, autoFillAttempts + 1 < autoFillMaxAttempts {
                    message = "Updated with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", ")). Trying another photograph…"
                } else {
                    message = "Updated with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", "))."
                }
                NSSound(named: NSSound.Name("Glass"))?.play()
                presentRecord(merged, flash: flash, message: message, automatic: auto, contributed: true, isNew: false)
            } catch {
                ScanLog.shared.write("scan save failed")
                status("SAVE FAILED: \(error.localizedDescription)")
                NSSound.beep()
                isProcessing = false
            }
            return
        }

        let filename = "\(incoming.capturedAt.replacingOccurrences(of: ":", with: "-"))_\(incoming.id.prefix(8)).jpg"
        incoming.photo = "photos/" + filename
        incoming.sourcePhoto = "photos/original_" + filename
        annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
        applyRequiredStatus(&incoming)
        do {
            guard let original = jpegData(result.originalImage) else { throw NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original JPEG encoding failed"]) }
            try original.write(to: outputRoot.appendingPathComponent(incoming.sourcePhoto), options: .atomic)
            writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
            let previous = records
            records.append(incoming)
            do { try saveRecordLive(incoming, allRecords: records, sortOrder: records.count - 1) }
            catch { records = previous; throw error }
            ScanLog.shared.write("scan saved status=\(incoming.status) fields_nonempty=\([incoming.series, incoming.serial, incoming.issueMonth, incoming.issueYear, incoming.denomination].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
            NSSound(named: NSSound.Name("Glass"))?.play()
            let flash: NSColor = incoming.status == "OK" ? .systemGreen : .systemYellow
            let message: String
            if incoming.status == "OK" {
                message = "Saved! All required fields verified. Remove the bond, then show the next one."
            } else if auto {
                message = "Saved. Still missing \(requiredFieldsMissing(incoming).joined(separator: ", ")). Trying another photograph…"
            } else {
                message = "Saved for REVIEW (\(requiredFieldsMissing(incoming).joined(separator: ", "))). Remove bond, then show the next one."
            }
            isProcessing = false
            presentRecord(incoming, flash: flash, message: message, automatic: auto, contributed: true, isNew: true)
        } catch {
            ScanLog.shared.write("scan save failed")
            status("SAVE FAILED: \(error.localizedDescription)")
            NSSound.beep()
            isProcessing = false
        }
    }


    private func updateCount() {
        let processing = records.filter { $0.status == "PROCESSING" }.count
        let duplicates = records.filter { $0.status == "DUPLICATE" }.count
        let reviews = records.filter { $0.status != "OK" && $0.status != "PROCESSING" && $0.status != "DUPLICATE" }.count
        let verified = records.filter { $0.status == "OK" }.count
        var text = "\(records.count) captured  •  \(verified) verified  •  \(reviews) need review"
        if duplicates > 0 {
            text += "  •  \(duplicates) duplicate"
        }
        if processing > 0 {
            text += "  •  \(processing) reading"
        }
        countLabel.stringValue = text
        bondsDrawer?.updateRecords(records)
        reviewWindowController?.coordinator.setAllRecords(records)
    }

    @objc private func toggleAuto() {
        automatic.toggle()
        autoButton.title = automatic ? "Auto: ON" : "Auto: OFF"
        ScanLog.shared.write("automatic mode toggled to \(automatic)")
        status(automatic ? "Automatic scanning on. Remove each bond after the confirmation flash." : "Manual mode. Press Space to scan each bond.")
    }

    @objc private func toggleFastScan() {
        fastScanEnabled.toggle()
        fastButton.title = fastScanEnabled ? "Fast: ON" : "Fast: OFF"
        ScanLog.shared.write("fast scan toggled to \(fastScanEnabled)")
        status(fastScanEnabled
            ? "Fast Scan on: quicker frame lock and immediate re-arm when a bond is removed."
            : "Fast Scan off: standard stabilization and OCR re-arm timing.")
    }

    @objc private func toggleDrawer() {
        drawerVisible.toggle()
        drawerButton.title = drawerVisible ? "Bonds: ON" : "Bonds: OFF"
        bondsDrawer.isHidden = !drawerVisible
        drawerWidthConstraint.constant = drawerVisible ? 420 : 0
    }

    private func openBondPhoto(_ record: BondRecord) {
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

    @objc private func openFolder() {
        NSWorkspace.shared.open(outputRoot)
    }

    @objc private func exportCSVAction() {
        let panel = NSSavePanel()
        panel.title = "Export Bonds to CSV"
        panel.nameFieldStringValue = "bonds.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            do {
                try exportCSV(self.records, to: url)
                ScanLog.shared.write("user exported csv count=\(self.records.count)")
                self.status("Exported \(self.records.count) bond records to \(url.lastPathComponent).")
            } catch {
                ScanLog.shared.write("csv export failed")
                self.status("CSV export failed: \(error.localizedDescription)")
            }
        }
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    @objc private func rearm() {
        lockedAfterCapture = false
        stableFrames = 0
        priorRect = nil
        emptyFrames = 0
        huntHits = 0
        noBondChecks = 0
        autoFillRecordId = nil
        autoFillAttempts = 0
        autoFillRect = nil
        autoFillGoneFrames = 0
        awaitingSerialFromCapture = false
        ScanLog.shared.write("manual re-arm")
        status("Ready for next bond. Hold steady inside the guide.")
    }

    @objc private func undoLast() {
        guard let last = records.last else { return }
        let alert = NSAlert()
        alert.messageText = "Undo the last bond?"
        alert.informativeText = "Removes the last spreadsheet row and moves its photograph to the Trash."
        alert.addButton(withTitle: "Undo")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        records.removeLast()
        do {
            try deleteRecordLive(id: last.id, allRecords: records)
            let image = outputRoot.appendingPathComponent(last.photo)
            if FileManager.default.fileExists(atPath: image.path) {
                try? FileManager.default.trashItem(at: image, resultingItemURL: nil)
            }
            let original = outputRoot.appendingPathComponent(last.sourcePhoto)
            if FileManager.default.fileExists(atPath: original.path) {
                try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
            }
            updateCount()
            lockedAfterCapture = false
            awaitingSerialFromCapture = false
            if let previous = records.max(by: { $0.capturedAt < $1.capturedAt }) {
                lastCapturedSerial = normalizeSerial(previous.serial)
            } else {
                lastCapturedSerial = ""
            }
            status("Undid last scan. Ready.")
        } catch {
            records.append(last)
            status("Cannot undo: \(error.localizedDescription)")
        }
    }

    @objc private func importPhotos() {
        let picker = NSOpenPanel()
        picker.title = "Import test bond photos"
        picker.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importFiles(picker.urls)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        status("Importing \(urls.count) photos…")
        // Save each original immediately, then let the shared OCR queue process them.
        func next(_ index: Int) {
            guard index < urls.count else {
                self.status("Import finished. Photographs are saved; OCR continues in the background.")
                return
            }
            let url = urls[index]
            self.saveQueue.async { [weak self] in
                guard let self = self else { return }
                guard let image = cgImageFromFile(url) else {
                    DispatchQueue.main.async { next(index + 1) }
                    return
                }
                DispatchQueue.main.async {
                    self.commitOriginalAndEnqueue(image: image, jpegBytes: nil)
                    next(index + 1)
                }
            }
        }
        next(0)
    }
}
