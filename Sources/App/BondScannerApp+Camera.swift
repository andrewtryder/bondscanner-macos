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

    func startCamera() {
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
            focusLabel.stringValue = focusInfo

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
}
