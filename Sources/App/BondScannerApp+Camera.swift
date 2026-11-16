import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

extension BondScannerApp {
    func requestCameraAccess() {
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
    func bondScanTry(_ description: String, _ work: @escaping () -> Void) -> Bool {
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
    func applyDeviceFormat(_ format: AVCaptureDevice.Format, on camera: AVCaptureDevice, reason: String) -> Bool {
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

    func applyVideoOutputSettings(width: Int, height: Int, subtype: String) {
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
    func applyPhotoOutputDimensions() {
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

    func logActiveFormatState(_ camera: AVCaptureDevice, at moment: String) {
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(camera.activeFormat.formatDescription))
        ScanLog.shared.write("\(moment) active_format=\(dims.width)x\(dims.height) subtype=\(sub) session_preset=\(session.sessionPreset.rawValue) photo_output=\(photoCaptureSupported)")
    }

    /// One-shot re-assert after startRunning, only if the active format
    /// dimensions actually drifted from what we chose. Do not treat a High
    /// preset name as a reason to fight the device again.
    func reassertChosenFormatIfNeeded(afterStart: Bool) {
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
    func apply1080Fallback(on camera: AVCaptureDevice, reason: String) -> Bool {
        guard let format = select1080FallbackFormat(from: camera.formats) else {
            ScanLog.shared.write("\(reason): no 1920x1080 format is available")
            return false
        }
        return applyDeviceFormat(format, on: camera, reason: reason)
    }

    /// After at most one attempt at a higher format, accept the size the
    /// device is actually delivering (typically 1920x1080 for uncompressed 420v).
    func handleDeliveredResolutionMismatch(deliveredWidth: Int, deliveredHeight: Int) {
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

    func acceptDeliveredResolution(deliveredWidth: Int, deliveredHeight: Int) {
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

    func cancelInFlightCaptures(reason: String) {
        if let cancelled = captureTransactionCoordinator.cancelActiveTransaction() {
            ScanLog.shared.write("cancelled active capture transaction=\(cancelled.id.uuidString.prefix(8)) reason=\(reason)")
        }
        let pending = photoRequests
        photoRequests.removeAll()
        for (_, req) in pending {
            req.completion?(.failure(ExposureBracketError.captureCancelled))
        }
        isProcessing = false
    }

    func startCamera() {
        setupCameraNotifications()
        cameraSessionGeneration &+= 1
        let generation = cameraSessionGeneration
        let selection = webcamPreferences.loadSelection()

        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            let devices = videoCaptureDevices()
            let descriptors = devices.map { WebcamResolver.makeDescriptor(from: $0) }
            ScanLog.shared.write("video devices found=\(devices.count) descriptors=\(descriptors.map(\.displayNameWithCategory))")

            let resolution = WebcamResolver.resolveActiveCamera(selection: selection, available: descriptors)
            guard let chosenDescriptor = resolution.selected,
                  let camera = devices.first(where: { $0.uniqueID == chosenDescriptor.id })
            else {
                DispatchQueue.main.async {
                    guard self.cameraSessionGeneration == generation else { return }
                    self.connectedDeviceDescriptors = descriptors
                    self.captureDevice = nil
                    self.currentDeviceInput = nil
                    self.currentExposureCapabilities = .inspect(device: nil)
                    self.status("No camera available. Connect a webcam or built-in camera; you can still import photos.")
                    self.focusInfo = "Focus: no camera available"
                    self.focusLabel?.stringValue = self.focusInfo
                    self.refreshCameraMenu()
                    self.refreshSettingsCamera()
                }
                return
            }

            DispatchQueue.main.async {
                if self.cameraSessionGeneration == generation {
                    self.connectedDeviceDescriptors = descriptors
                }
            }
            self.configureAndStartCameraOnQueue(camera, descriptor: chosenDescriptor, generation: generation)
        }
    }

    func attachAndStartCamera(_ camera: AVCaptureDevice, descriptor: WebcamDescriptor) {
        cameraSessionGeneration &+= 1
        let generation = cameraSessionGeneration
        cameraQueue.async { [weak self] in
            self?.configureAndStartCameraOnQueue(camera, descriptor: descriptor, generation: generation)
        }
    }

    /// Runs strictly on `cameraQueue` so session reconfiguration and startup are serialized.
    func configureAndStartCameraOnQueue(_ camera: AVCaptureDevice, descriptor: WebcamDescriptor, generation: UInt64) {
        guard cameraSessionGeneration == generation else {
            ScanLog.shared.write("camera configuration superseded before start for '\(descriptor.localizedName)'")
            return
        }
        do {
            captureDevice = camera
            let inspectedCapabilities = CameraHardwareExposureCapabilities.inspect(device: camera)
            currentExposureCapabilities = inspectedCapabilities
            logAllCameraFormats(camera)
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            if let old = currentDeviceInput {
                session.removeInput(old)
            }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"])
            }
            session.addInput(input)
            currentDeviceInput = input

            if videoDataOutput == nil {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: cameraQueue)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Video output unavailable"])
                }
                session.addOutput(output)
                videoDataOutput = output
            }

            photoCaptureSupported = false
            if !session.outputs.contains(where: { $0 === photoOutput }) {
                if session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                    photoCaptureSupported = true
                    let codecs = photoOutput.availablePhotoCodecTypes.map { $0.rawValue }.joined(separator: ",")
                    ScanLog.shared.write("photo output attached codecs=[\(codecs)]")
                } else {
                    ScanLog.shared.write("photo output not supported; stills will use the latest video frame")
                }
            } else {
                photoCaptureSupported = true
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
            } catch {
                ScanLog.shared.write("could not configure autofocus or exposure (camera may manage them internally)")
            }
            logCameraControls(camera)
            let nextFocusInfo = continuous ? "Focus: continuous autofocus requested" :
                (autoFocus ? "Focus: one-shot autofocus requested" : "Focus: webcam controls unavailable / hardware-managed")

            session.commitConfiguration()
            logActiveFormatState(camera, at: "after_commit")
            ScanLog.shared.write("camera=\(camera.localizedName) category=\(descriptor.category.rawValue) continuous_focus=\(continuous) one_shot_focus=\(autoFocus) focus_point=\(pointSupported) hardware_exposure=\(inspectedCapabilities.supportsHardwareAdjustment)")

            deliveredFrameLogged = false
            resolutionSettled = false
            didReassertFormat = false
            didTryHigherFormat = false

            if !session.isRunning {
                session.startRunning()
            }
            reassertChosenFormatIfNeeded(afterStart: true)

            DispatchQueue.main.async {
                guard self.cameraSessionGeneration == generation else { return }
                self.focusInfo = nextFocusInfo
                self.focusLabel?.stringValue = nextFocusInfo
                self.status("Camera: [\(descriptor.category.displayBadge)] \(descriptor.localizedName). Finding bond outline or printed text…")
                self.isCameraSwitching = false
                self.refreshCameraMenu()
                self.refreshSettingsCamera()
            }
        } catch {
            DispatchQueue.main.async {
                guard self.cameraSessionGeneration == generation else { return }
                self.isCameraSwitching = false
                self.status("Camera error: \(error.localizedDescription)")
                self.refreshCameraMenu()
                self.refreshSettingsCamera()
            }
        }
    }

    /// Safely switches camera to the selected device, draining active captures if necessary.
    func switchCamera(to descriptor: WebcamDescriptor, isExplicit: Bool = false) {
        if isExplicit {
            webcamPreferences.saveSelection(.explicit(uniqueID: descriptor.id))
        }

        if captureDevice?.uniqueID == descriptor.id, !isCameraSwitching {
            refreshCameraMenu()
            refreshSettingsCamera()
            return
        }

        // If a capture transaction is running, defer switch until capture transaction completes
        if captureTransactionCoordinator.isBusy || isProcessing {
            pendingReconnectionDeviceID = descriptor.id
            ScanLog.shared.write("camera switch to '\(descriptor.localizedName)' deferred: capture in progress")
            return
        }

        isCameraSwitching = true
        cameraSessionGeneration &+= 1
        let generation = cameraSessionGeneration
        cancelInFlightCaptures(reason: "switching to \(descriptor.localizedName)")

        cameraQueue.async { [weak self] in
            guard let self = self, self.cameraSessionGeneration == generation else { return }
            let devices = videoCaptureDevices()
            guard let newDevice = devices.first(where: { $0.uniqueID == descriptor.id }) else {
                DispatchQueue.main.async {
                    guard self.cameraSessionGeneration == generation else { return }
                    self.isCameraSwitching = false
                    self.status("Selected camera '\(descriptor.localizedName)' is not available.")
                    self.refreshCameraMenu()
                    self.refreshSettingsCamera()
                }
                return
            }

            self.configureAndStartCameraOnQueue(newDevice, descriptor: descriptor, generation: generation)
            ScanLog.shared.write("successfully switched camera to '\(descriptor.localizedName)' [\(descriptor.category.rawValue)]")
        }
    }

    func setupCameraNotifications() {
        NotificationCenter.default.removeObserver(self, name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVCaptureDevice.wasDisconnectedNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleCameraConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleCameraDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
    }

    @objc func handleCameraConnected(_ notification: Notification) {
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            let devices = videoCaptureDevices()
            let descriptors = devices.map { WebcamResolver.makeDescriptor(from: $0) }
            DispatchQueue.main.async {
                self.connectedDeviceDescriptors = descriptors
                self.refreshCameraMenu()
                self.refreshSettingsCamera()

                let selection = self.webcamPreferences.loadSelection()
                let resolution = WebcamResolver.resolveActiveCamera(selection: selection, available: self.connectedDeviceDescriptors)

                guard let best = resolution.selected else { return }

                // If the best available device is different from current active device, switch to it safely
                if self.captureDevice?.uniqueID != best.id {
                    ScanLog.shared.write("preferred camera connected or available: '\(best.localizedName)' [\(best.category.rawValue)]")
                    self.switchCamera(to: best, isExplicit: false)
                }
            }
        }
    }

    @objc func handleCameraDisconnected(_ notification: Notification) {
        guard let disconnectedDevice = notification.object as? AVCaptureDevice else { return }
        let disconnectedID = disconnectedDevice.uniqueID
        let disconnectedName = disconnectedDevice.localizedName

        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            let devices = videoCaptureDevices()
            let descriptors = devices.map { WebcamResolver.makeDescriptor(from: $0) }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                ScanLog.shared.write("camera disconnected: '\(disconnectedName)' (uid: \(disconnectedID))")
                self.connectedDeviceDescriptors = descriptors
                self.refreshCameraMenu()
                self.refreshSettingsCamera()

                // If the disconnected device was the active camera, failover safely
                if self.captureDevice?.uniqueID == disconnectedID {
                    self.cameraSessionGeneration &+= 1
                    let generation = self.cameraSessionGeneration
                    self.cancelInFlightCaptures(reason: "active camera disconnected")

                    let selection = self.webcamPreferences.loadSelection()
                    let resolution = WebcamResolver.resolveActiveCamera(selection: selection, available: self.connectedDeviceDescriptors)

                    if let fallback = resolution.selected,
                       let fallbackDevice = devices.first(where: { $0.uniqueID == fallback.id })
                    {
                        self.status("Selected camera disconnected. Active camera: [\(fallback.category.displayBadge)] \(fallback.localizedName).")
                        self.cameraQueue.async { [weak self] in
                            self?.configureAndStartCameraOnQueue(fallbackDevice, descriptor: fallback, generation: generation)
                        }
                    } else {
                        self.captureDevice = nil
                        self.currentDeviceInput = nil
                        self.currentExposureCapabilities = .inspect(device: nil)
                        self.status("Active camera disconnected. No remaining cameras; you can still import photos.")
                        self.focusInfo = "Focus: camera disconnected"
                        self.focusLabel?.stringValue = self.focusInfo
                        self.refreshCameraMenu()
                        self.refreshSettingsCamera()
                    }
                }
            }
        }
    }

    func checkPendingCameraSwitchAfterCapture() {
        guard let pendingID = pendingReconnectionDeviceID else { return }
        pendingReconnectionDeviceID = nil
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            let devices = videoCaptureDevices()
            let descriptors = devices.map { WebcamResolver.makeDescriptor(from: $0) }
            DispatchQueue.main.async {
                self.connectedDeviceDescriptors = descriptors
                if let target = descriptors.first(where: { $0.id == pendingID }) {
                    ScanLog.shared.write("applying deferred camera switch to '\(target.localizedName)'")
                    self.switchCamera(to: target, isExplicit: false)
                }
            }
        }
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

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let uniqueID = photo.resolvedSettings.uniqueID
        let dims = photo.resolvedSettings.photoDimensions
        let failure = error
        let jpeg = (failure == nil) ? photo.fileDataRepresentation() : nil
        let cg = (failure == nil) ? photo.cgImageRepresentation() : nil
        DispatchQueue.main.async { [weak self] in
            self?.handlePhotoCaptureCallback(
                uniqueID: uniqueID,
                dimensions: dims,
                jpegData: jpeg,
                cgImage: cg,
                error: failure
            )
        }
    }

    /// Processes a photo output callback on the main thread, rejecting untracked, cancelled, or superseded requests.
    func handlePhotoCaptureCallback(
        uniqueID: Int64,
        dimensions: CMVideoDimensions,
        jpegData jpeg: Data?,
        cgImage cg: CGImage?,
        error failure: Error?
    ) {
        guard let requestInfo = photoRequests.removeValue(forKey: uniqueID) else {
            ScanLog.shared.write("ignoring untracked or stale photo callback id=\(uniqueID)")
            return
        }

        let generationMatches = requestInfo.sessionGeneration == cameraSessionGeneration
        let deviceMatches = requestInfo.deviceUniqueID == nil || requestInfo.deviceUniqueID == captureDevice?.uniqueID
        let transactionActive = captureTransactionCoordinator.isTransactionActive(id: requestInfo.transactionId)

        guard generationMatches, deviceMatches, transactionActive else {
            ScanLog.shared.write("ignoring stale photo callback for cancelled or superseded transaction=\(requestInfo.transactionId.uuidString.prefix(8))")
            requestInfo.completion?(.failure(ExposureBracketError.captureCancelled))
            return
        }

        let automatic = requestInfo.automatic
        let requestedAt = requestInfo.requestedAt
        let biasEV = requestInfo.biasEV

        if let completion = requestInfo.completion {
            if let failure = failure {
                completion(.failure(failure))
                return
            }
            guard let image = cg ?? jpeg.flatMap({ cgImageFromData($0) }) else {
                completion(.failure(NSError(domain: "Camera", code: 4, userInfo: [NSLocalizedDescriptionKey: "Photograph could not be decoded"])))
                return
            }
            let quality = evaluateImageQuality(image)
            let exp = CapturedExposure(
                biasEV: biasEV,
                image: image,
                jpegBytes: jpeg,
                capturedAt: Date().timeIntervalSince1970,
                meanLuminance: quality.meanLuminance,
                sharpnessScore: quality.sharpnessScore,
                isBaseline: biasEV == 0.0
            )
            completion(.success(exp))
            return
        }

        captureTransactionCoordinator.finishTransaction(id: requestInfo.transactionId)

        if failure != nil {
            ScanLog.shared.write("photo output failed; falling back to video frame")
            if let frame = latestImage {
                finishCapture(image: frame, jpegBytes: nil, automatic: automatic, requestedAt: requestedAt)
                checkPendingCameraSwitchAfterCapture()
            } else {
                if automatic {
                    isProcessing = false
                } else {
                    status("Photograph capture failed and no video frame is available.")
                    preview?.captureFlash(color: .systemRed)
                    NSSound.beep()
                }
                checkPendingCameraSwitchAfterCapture()
            }
            return
        }
        ScanLog.shared.write("photo output captured \(dimensions.width)x\(dimensions.height)")
        let image = cg ?? jpeg.flatMap { cgImageFromData($0) }
        guard let image = image else {
            if let frame = latestImage {
                finishCapture(image: frame, jpegBytes: nil, automatic: automatic, requestedAt: requestedAt)
                checkPendingCameraSwitchAfterCapture()
            } else {
                if automatic {
                    isProcessing = false
                } else {
                    status("Photograph could not be decoded.")
                    preview?.captureFlash(color: .systemRed)
                }
                checkPendingCameraSwitchAfterCapture()
            }
            return
        }
        finishCapture(image: image, jpegBytes: jpeg, automatic: automatic, requestedAt: requestedAt)
        checkPendingCameraSwitchAfterCapture()
    }

    // MARK: - Camera Menu & Settings Controls

    func refreshCameraMenu() {
        guard let cameraMenu = cameraSubmenu else { return }
        cameraMenu.removeAllItems()

        // 1. Select Webcam submenu
        let selectItem = NSMenuItem(title: "Select Webcam…", action: nil, keyEquivalent: "")
        let selectMenu = NSMenu(title: "Select Webcam")

        let autoItem = NSMenuItem(
            title: "Automatic — Prefer USB Webcam (Recommended)",
            action: #selector(selectAutomaticWebcam),
            keyEquivalent: ""
        )
        autoItem.target = self
        let currentSelection = webcamPreferences.loadSelection()
        autoItem.state = (currentSelection == .automaticPreferUSB) ? .on : .off
        selectMenu.addItem(autoItem)
        selectMenu.addItem(NSMenuItem.separator())

        if connectedDeviceDescriptors.isEmpty {
            let noneItem = NSMenuItem(title: "No Cameras Connected", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            selectMenu.addItem(noneItem)
        } else {
            for descriptor in connectedDeviceDescriptors {
                let item = NSMenuItem(
                    title: descriptor.displayNameWithCategory,
                    action: #selector(selectExplicitWebcam(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = descriptor
                let isCurrent = (captureDevice?.uniqueID == descriptor.id)
                item.state = isCurrent ? .on : .off
                selectMenu.addItem(item)
            }
        }
        selectItem.submenu = selectMenu
        cameraMenu.addItem(selectItem)

        // 2. Smart Exposure Capture submenu
        let exposureItem = NSMenuItem(title: "Smart Exposure Capture", action: nil, keyEquivalent: "")
        let exposureMenu = NSMenu(title: "Smart Exposure Capture")

        let currentMode = smartExposurePreferences.loadMode()
        let autoExpItem = NSMenuItem(
            title: "Automatic — Multi-Exposure when supported",
            action: #selector(selectSmartExposureModeAuto),
            keyEquivalent: ""
        )
        autoExpItem.target = self
        autoExpItem.state = (currentMode == .automatic) ? .on : .off
        exposureMenu.addItem(autoExpItem)

        let offExpItem = NSMenuItem(
            title: "Off — Single-Photo Capture",
            action: #selector(selectSmartExposureModeOff),
            keyEquivalent: ""
        )
        offExpItem.target = self
        offExpItem.state = (currentMode == .off) ? .on : .off
        exposureMenu.addItem(offExpItem)

        exposureMenu.addItem(NSMenuItem.separator())

        let infoItem = NSMenuItem(
            title: currentExposureCapabilities.statusDescription,
            action: nil,
            keyEquivalent: ""
        )
        infoItem.isEnabled = false
        exposureMenu.addItem(infoItem)

        exposureItem.submenu = exposureMenu
        cameraMenu.addItem(exposureItem)

        cameraMenu.addItem(NSMenuItem.separator())

        // 3. Request Refocus
        let refocus = NSMenuItem(title: "Request Refocus", action: #selector(refocusCamera), keyEquivalent: "r")
        refocus.target = self
        cameraMenu.addItem(refocus)

        // 4. Hardware Diagnostics
        let diagItem = NSMenuItem(title: "Hardware Diagnostics…", action: #selector(showHardwareDiagnostics), keyEquivalent: "d")
        diagItem.keyEquivalentModifierMask = [.command, .control]
        diagItem.target = self
        cameraMenu.addItem(diagItem)
    }

    @objc func selectAutomaticWebcam() {
        webcamPreferences.saveSelection(.automaticPreferUSB)
        let selection = webcamPreferences.loadSelection()
        let resolution = WebcamResolver.resolveActiveCamera(selection: selection, available: connectedDeviceDescriptors)
        if let best = resolution.selected {
            switchCamera(to: best, isExplicit: false)
        }
        refreshCameraMenu()
        refreshSettingsCamera()
    }

    @objc func selectExplicitWebcam(_ sender: NSMenuItem) {
        guard let descriptor = sender.representedObject as? WebcamDescriptor else { return }
        switchCamera(to: descriptor, isExplicit: true)
        refreshCameraMenu()
        refreshSettingsCamera()
    }

    @objc func selectSmartExposureModeAuto() {
        smartExposurePreferences.saveMode(.automatic)
        refreshCameraMenu()
        refreshSettingsCamera()
        status("Smart Exposure set to Automatic. Multi-exposure will be used when supported by hardware.")
    }

    @objc func selectSmartExposureModeOff() {
        smartExposurePreferences.saveMode(.off)
        refreshCameraMenu()
        refreshSettingsCamera()
        status("Smart Exposure turned Off. Standard single-photo capture will be used.")
    }

    @objc func showHardwareDiagnostics() {
        let activeName = captureDevice?.localizedName ?? "None"
        let activeCategory = captureDevice.map { WebcamResolver.categorize(device: $0).rawValue } ?? "None"
        let transportStr = captureDevice.map { d -> String in
            let t = d.transportType
            let bytes = [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
            return String(bytes: bytes, encoding: .ascii) ?? String(t)
        } ?? "None"
        let modelStr = captureDevice?.modelID ?? "None"
        let dims = captureDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let dimsStr = dims.map { "\($0.width)x\($0.height)" } ?? "None"
        let subStr = chosenFormatSubtype.isEmpty ? "None" : chosenFormatSubtype
        let maxPhotoStr = photoOutput != nil ? "\(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height)" : "N/A"

        var expModes: [String] = []
        if let camera = captureDevice {
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                expModes.append("continuousAutoExposure")
            }
            if camera.isExposureModeSupported(.autoExpose) {
                expModes.append("autoExpose")
            }
            if camera.isExposureModeSupported(.locked) {
                expModes.append("locked")
            }
            if camera.isExposureModeSupported(.custom) {
                expModes.append("custom")
            }
        }

        var focusModes: [String] = []
        if let camera = captureDevice {
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                focusModes.append("continuousAutoFocus")
            }
            if camera.isFocusModeSupported(.autoFocus) {
                focusModes.append("autoFocus")
            }
            if camera.isFocusModeSupported(.locked) {
                focusModes.append("locked")
            }
        }

        var wbModes: [String] = []
        if let camera = captureDevice {
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                wbModes.append("continuousAutoWhiteBalance")
            }
            if camera.isWhiteBalanceModeSupported(.autoWhiteBalance) {
                wbModes.append("autoWhiteBalance")
            }
            if camera.isWhiteBalanceModeSupported(.locked) {
                wbModes.append("locked")
            }
        }

        let summary = connectedDeviceDescriptors.map { "\($0.displayNameWithCategory) (id: \($0.id.prefix(12))...)" }

        let report = HardwareDiagnosticReport(
            activeDeviceName: activeName,
            activeDeviceCategory: activeCategory,
            activeDeviceTransport: transportStr,
            activeDeviceModelID: modelStr,
            activeFormatDimensions: dimsStr,
            activeFormatSubtype: subStr,
            isPhotoOutputSupported: photoCaptureSupported,
            maxPhotoDimensions: maxPhotoStr,
            supportedExposureModes: expModes,
            supportedFocusModes: focusModes,
            supportedWhiteBalanceModes: wbModes,
            hardwareExposureAdjustmentSupported: currentExposureCapabilities.supportsHardwareAdjustment,
            minExposureBias: currentExposureCapabilities.minBias,
            maxExposureBias: currentExposureCapabilities.maxBias,
            smartExposureMode: smartExposurePreferences.loadMode().rawValue,
            totalConnectedCameras: connectedDeviceDescriptors.count,
            connectedCamerasSummary: summary,
            totalCaptures: diagnostics.totalCaptures,
            averageCaptureLatencyMs: diagnostics.averageCaptureLatencyMs,
            averageOCRLatencyMs: diagnostics.averageOCRLatencyMs
        )

        ScanLog.shared.write("Hardware diagnostics requested:\n\(report.formattedText)")

        let alert = NSAlert()
        alert.messageText = "Hardware Diagnostics"
        alert.informativeText = report.formattedText
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Report")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.formattedText, forType: .string)
        }
    }
}
