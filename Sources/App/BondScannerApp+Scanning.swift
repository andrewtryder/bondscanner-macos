import AppKit
import AudioToolbox
import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import Vision

extension BondScannerApp {
    func handleRectangle(_ rect: CGRect?, frame: CGImage) {
        preview?.sourceSize = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        preview?.showDetected(rect)
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
            let gate = evaluateAutomaticCaptureStabilization(frame: frame, rect: rect, now: now)
            if gate.ready {
                stableFrames = 0
                stabilizationStartTime = 0
                huntHits = 0
                ScanLog.shared.write("auto capture: stable outline (sharpness=\(String(format: "%.3f", gate.quality.sharpnessScore)) timeoutReached=\(gate.timeoutReached)); OCR starts")
                performScan(frame, automaticScan: true)
                return
            }
        } else {
            if huntHits == 0 {
                stableFrames = 0
                stabilizationStartTime = 0
            }
            priorRect = nil
        }
        if now - lastDiagnosticAt > 4 {
            ScanLog.shared.write("hunting: rectangle=\(rect != nil) stable_frames=\(stableFrames) locked=\(lockedAfterCapture)")
            lastDiagnosticAt = now
        }
        scheduleTextHunt(frame, forRearm: false)
    }

    func evaluateAutomaticCaptureStabilization(
        frame: CGImage,
        rect: CGRect?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> (ready: Bool, quality: ImageQualityReport, timeoutReached: Bool) {
        let maxShift: CGFloat = fastScanEnabled ? 0.025 : 0.05
        let maxScale: CGFloat = fastScanEnabled ? 0.04 : 0.075
        let quality = evaluateImageQuality(frame, region: rect)
        let minSharpness: Float = fastScanEnabled
            ? ImageQualityReport.fastScanSharpnessThreshold
            : ImageQualityReport.standardSharpnessThreshold
        let isSharp = quality.isSharp || quality.sharpnessScore >= minSharpness
        let motionDelta = abs(quality.meanLuminance - priorFrameLuminance)
        let isMotionLow = motionDelta < 0.12
        priorFrameLuminance = quality.meanLuminance
        let isAutofocusSettled = (captureDevice?.isAdjustingFocus != true)

        let isPositionStable: Bool
        if let rect = rect {
            if let prior = priorRect,
               abs(rect.midX - prior.midX) < maxShift,
               abs(rect.midY - prior.midY) < maxShift,
               abs(rect.width - prior.width) < maxScale,
               abs(rect.height - prior.height) < maxScale
            {
                isPositionStable = true
            } else {
                isPositionStable = false
            }
            priorRect = rect
        } else {
            priorRect = nil
            isPositionStable = true
        }

        if stabilizationStartTime == 0 {
            stabilizationStartTime = now
        }

        if isPositionStable, isMotionLow, isAutofocusSettled {
            stableFrames += 1
        } else {
            stableFrames = 1
        }

        let elapsedStabilizing = now - stabilizationStartTime
        let boundedTimeoutReached = elapsedStabilizing >= (fastScanEnabled ? 0.8 : 1.2) && isSharp
        let ready = (stableFrames >= 2 && isSharp) || boundedTimeoutReached
        return (ready, quality, boundedTimeoutReached)
    }

    func scheduleTextHunt(_ frame: CGImage, forRearm: Bool, rectangleVisible: Bool = false) {
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
                self.handleAutomaticTextDetection(hasBond: hasBond, frame: frame)
            }
        }
    }

    func handleAutomaticTextDetection(hasBond: Bool, frame: CGImage) {
        let now = Date().timeIntervalSince1970
        guard !lockedAfterCapture, !isProcessing, automatic, now >= nextAutoAllowedAt else { return }
        if hasBond {
            huntHits += 1
            if huntHits >= requiredHuntHits {
                let captureFrame = latestImage ?? frame
                let gate = evaluateAutomaticCaptureStabilization(frame: captureFrame, rect: nil, now: now)
                if gate.ready {
                    stableFrames = 0
                    stabilizationStartTime = 0
                    huntHits = 0
                    ScanLog.shared.write("auto capture: fallback OCR stabilized (sharpness=\(String(format: "%.3f", gate.quality.sharpnessScore)) timeoutReached=\(gate.timeoutReached))")
                    performScan(captureFrame, automaticScan: true)
                } else {
                    status("Bond text found — stabilizing before capture…")
                }
            } else {
                status("Bond text found (\(huntHits)/\(requiredHuntHits)). Hold steady…")
            }
        } else {
            huntHits = 0
            if priorRect == nil {
                stableFrames = 0
                stabilizationStartTime = 0
            }
            status("No readable bond yet — adjust distance/light or press Space to capture for review.")
        }
    }

    @objc func scanNow() {
        // Manual capture never waits on rectangle detection or an in-flight OCR job.
        requestPhotograph(automatic: false)
    }

    func performScan(_ image: CGImage, automaticScan: Bool) {
        if automaticScan {
            guard !isProcessing else { return }
            requestPhotograph(automatic: true, fallback: image)
            return
        }
        requestPhotograph(automatic: false, fallback: image)
    }

    func requestPhotograph(automatic: Bool, fallback: CGImage? = nil) {
        let requestedAt = Date().timeIntervalSince1970
        let mode = smartExposurePreferences.loadMode()
        let targetBiases = currentExposureCapabilities.targetExposureBiases(requestedMode: mode)

        if targetBiases.count > 1, photoCaptureSupported, session != nil, session.isRunning, let camera = captureDevice {
            // Multi-exposure Smart Exposure capture via tested ExposureBracketController
            guard let transaction = captureTransactionCoordinator.startTransaction(
                automatic: automatic,
                targetBiases: targetBiases,
                deviceUniqueID: camera.uniqueID,
                sessionGeneration: cameraSessionGeneration
            ) else {
                return
            }
            if automatic {
                isProcessing = true
            } else {
                lockedAfterCapture = true
            }
            ScanLog.shared.write("smart exposure bracket started targets=\(targetBiases)")
            status("Smart Exposure: capturing multi-exposure sequence (\(targetBiases.count) exposures)…")

            executeMultiExposureCapture(transaction: transaction, camera: camera, requestedAt: requestedAt, fallback: fallback)
            return
        }

        // Single photo capture (standard path)
        if photoCaptureSupported, session != nil, session.isRunning {
            guard let transaction = captureTransactionCoordinator.startTransaction(
                automatic: automatic,
                targetBiases: [0.0],
                deviceUniqueID: captureDevice?.uniqueID,
                sessionGeneration: cameraSessionGeneration
            ) else {
                return
            }
            let settings = AVCapturePhotoSettings()
            if #available(macOS 13.0, *) {
                let max = photoOutput.maxPhotoDimensions
                let supported = captureDevice?.activeFormat.supportedMaxPhotoDimensions ?? []
                if max.width > 0, max.height > 0, photoDimension(max, isIn: supported) {
                    settings.maxPhotoDimensions = max
                }
            }
            photoRequests[settings.uniqueID] = PhotoRequestInfo(
                transactionId: transaction.id,
                sessionGeneration: transaction.sessionGeneration,
                deviceUniqueID: transaction.deviceUniqueID,
                automatic: automatic,
                requestedAt: requestedAt,
                biasEV: 0.0,
                completion: nil
            )
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

    func captureOnePhoto(
        transaction: CaptureTransaction,
        biasEV: Float,
        fallback: CGImage?,
        completion: @escaping (Result<CapturedExposure, Error>) -> Void
    ) {
        guard !transaction.isCancelled,
              transaction.sessionGeneration == cameraSessionGeneration
        else {
            completion(.failure(ExposureBracketError.captureCancelled))
            return
        }

        if photoCaptureSupported, session != nil, session.isRunning {
            let settings = AVCapturePhotoSettings()
            if #available(macOS 13.0, *) {
                let max = photoOutput.maxPhotoDimensions
                let supported = captureDevice?.activeFormat.supportedMaxPhotoDimensions ?? []
                if max.width > 0, max.height > 0, photoDimension(max, isIn: supported) {
                    settings.maxPhotoDimensions = max
                }
            }
            photoRequests[settings.uniqueID] = PhotoRequestInfo(
                transactionId: transaction.id,
                sessionGeneration: transaction.sessionGeneration,
                deviceUniqueID: transaction.deviceUniqueID,
                automatic: transaction.automatic,
                requestedAt: Date().timeIntervalSince1970,
                biasEV: biasEV,
                completion: completion
            )
            photoOutput.capturePhoto(with: settings, delegate: self)
            return
        }

        if let image = fallback ?? latestImage {
            let quality = evaluateImageQuality(image)
            let exp = CapturedExposure(
                biasEV: biasEV,
                image: image,
                jpegBytes: nil,
                capturedAt: Date().timeIntervalSince1970,
                meanLuminance: quality.meanLuminance,
                sharpnessScore: quality.sharpnessScore,
                isBaseline: biasEV == 0.0
            )
            completion(.success(exp))
        } else {
            completion(.failure(NSError(domain: "Camera", code: 5, userInfo: [NSLocalizedDescriptionKey: "No video frame available"])))
        }
    }

    func executeMultiExposureCapture(
        transaction: CaptureTransaction,
        camera: AVCaptureDevice,
        requestedAt: TimeInterval,
        fallback: CGImage?
    ) {
        let adapter = AVCaptureExposureAdapter(
            device: camera,
            capabilities: currentExposureCapabilities,
            settlingTimeout: exposureBracketController.timeoutSeconds,
            workQueue: cameraQueue
        ) { [weak self] bias, done in
            DispatchQueue.main.async {
                guard let self = self else {
                    done(.failure(ExposureBracketError.captureCancelled))
                    return
                }
                self.captureOnePhoto(transaction: transaction, biasEV: bias, fallback: fallback, completion: done)
            }
        }

        exposureBracketController.executeBracket(transaction: transaction, camera: adapter) { [weak self] bracketResult in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleBracketCompletion(transaction: transaction, result: bracketResult)
            }
        }
    }

    private func isCurrentCaptureTransaction(_ transaction: CaptureTransaction) -> Bool {
        !transaction.isCancelled
            && transaction.sessionGeneration == cameraSessionGeneration
            && captureTransactionCoordinator.isTransactionActive(id: transaction.id)
    }

    func handleBracketCompletion(transaction: CaptureTransaction, result: Result<[CapturedExposure], Error>) {
        guard isCurrentCaptureTransaction(transaction) else {
            captureTransactionCoordinator.finishTransaction(id: transaction.id)
            ScanLog.shared.write("ignoring obsolete bracket completion id=\(transaction.id.uuidString.prefix(8)) gen=\(transaction.sessionGeneration) currentGen=\(cameraSessionGeneration)")
            return
        }

        switch result {
        case let .failure(error):
            captureTransactionCoordinator.finishTransaction(id: transaction.id)
            isProcessing = false
            if (error as? ExposureBracketError) == .captureCancelled || transaction.isCancelled {
                ScanLog.shared.write("smart exposure bracket cancelled id=\(transaction.id.uuidString.prefix(8))")
                checkPendingCameraSwitchAfterCapture()
                return
            }
            status("Smart Exposure failed: \(error.localizedDescription)")
            preview?.captureFlash(color: .systemRed)
            checkPendingCameraSwitchAfterCapture()
        case let .success(exposures):
            transaction.replaceExposures(exposures)
            finishMultiExposureCapture(transaction: transaction)
        }
    }

    func finishMultiExposureCapture(transaction: CaptureTransaction) {
        guard isCurrentCaptureTransaction(transaction) else {
            captureTransactionCoordinator.finishTransaction(id: transaction.id)
            ScanLog.shared.write("ignoring obsolete finishMultiExposureCapture id=\(transaction.id.uuidString.prefix(8)) gen=\(transaction.sessionGeneration) currentGen=\(cameraSessionGeneration)")
            return
        }
        guard let baseline = transaction.baselineExposure else {
            captureTransactionCoordinator.finishTransaction(id: transaction.id)
            isProcessing = false
            status("Capture failed: No exposures captured.")
            checkPendingCameraSwitchAfterCapture()
            return
        }

        if transaction.capturedExposures.count <= 1 {
            captureTransactionCoordinator.finishTransaction(id: transaction.id)
            finishCapture(image: baseline.image, jpegBytes: baseline.jpegBytes, automatic: transaction.automatic, requestedAt: transaction.requestedAt)
            checkPendingCameraSwitchAfterCapture()
            return
        }

        let id = transaction.id.uuidString
        let capturedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: transaction.requestedAt))
        let baseFilename = "\(capturedAt.replacingOccurrences(of: ":", with: "-"))_\(id.prefix(8)).jpg"
        let primaryOriginalRel = "photos/original_" + baseFilename
        let primaryProcessedRel = "photos/" + baseFilename
        let primaryOriginalURL = outputRoot.appendingPathComponent(primaryOriginalRel)
        let primaryProcessedURL = outputRoot.appendingPathComponent(primaryProcessedRel)

        var savedBracketed: [(biasEV: Float, url: URL, relativePath: String)] = []
        var qualityNotes: [String] = []

        let quality = evaluateImageQuality(baseline.image)
        if quality.isBlurry {
            qualityNotes.append("blurry (\(String(format: "%.3f", quality.sharpnessScore)))")
        }
        if quality.isUnderExposed {
            qualityNotes.append("underexposed")
        }
        if quality.isOverExposed {
            qualityNotes.append("overexposed")
        }

        saveQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)

                guard let baseData = baseline.jpegBytes ?? jpegData(baseline.image) else {
                    throw NSError(domain: "Save", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode baseline photo"])
                }
                try baseData.write(to: primaryOriginalURL, options: .atomic)
                // Ensure the primary processed path also exists immediately so the record
                // never references a missing file before or during OCR.
                try baseData.write(to: primaryProcessedURL, options: .atomic)

                for exp in transaction.capturedExposures where !exp.isBaseline {
                    let biasStr = String(format: "%+.1fEV", exp.biasEV)
                    let bracketFilename = "original_\(capturedAt.replacingOccurrences(of: ":", with: "-"))_\(id.prefix(8))_\(biasStr).jpg"
                    let bracketRel = "photos/" + bracketFilename
                    let bracketURL = outputRoot.appendingPathComponent(bracketRel)
                    if let expData = exp.jpegBytes ?? jpegData(exp.image) {
                        try expData.write(to: bracketURL, options: .atomic)
                        savedBracketed.append((biasEV: exp.biasEV, url: bracketURL, relativePath: bracketRel))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let isCurrent = self.isCurrentCaptureTransaction(transaction)
                    self.captureTransactionCoordinator.finishTransaction(id: transaction.id)
                    guard isCurrent else {
                        ScanLog.shared.write("ignoring obsolete multi-exposure save failure id=\(transaction.id.uuidString.prefix(8))")
                        return
                    }
                    self.isProcessing = false
                    self.status("SAVE FAILED: \(error.localizedDescription)")
                    self.preview?.captureFlash(color: .systemRed)
                    NSSound.beep()
                    self.checkPendingCameraSwitchAfterCapture()
                }
                return
            }

            DispatchQueue.main.async {
                let isCurrent = self.isCurrentCaptureTransaction(transaction)
                self.captureTransactionCoordinator.finishTransaction(id: transaction.id)
                guard isCurrent else {
                    ScanLog.shared.write("ignoring obsolete multi-exposure save completion id=\(transaction.id.uuidString.prefix(8)) gen=\(transaction.sessionGeneration) currentGen=\(self.cameraSessionGeneration)")
                    return
                }

                let captureLatencyMs = (Date().timeIntervalSince1970 - transaction.requestedAt) * 1000.0
                self.diagnostics.totalCaptures += 1
                self.diagnostics.totalCaptureTimeMs += captureLatencyMs

                var record = emptyBondRecord(id: id, capturedAt: capturedAt)
                record.photo = primaryProcessedRel
                record.sourcePhoto = primaryOriginalRel
                let bracketedPaths = savedBracketed.map(\.relativePath)
                record.associatedPhotos = bracketedPaths.isEmpty ? nil : bracketedPaths
                if !qualityNotes.isEmpty {
                    record.notes = "Quality: \(qualityNotes.joined(separator: ", "))"
                }
                let countStr = "Multi-Exposure (\(transaction.capturedExposures.count) captures)"
                record.notes = record.notes.isEmpty ? countStr : "\(record.notes) • \(countStr)"

                let previous = self.records
                self.records.append(record)
                do {
                    try saveRecordLive(record, allRecords: self.records, sortOrder: self.records.count - 1)
                } catch {
                    self.isProcessing = false
                    self.records = previous
                    self.status("DATABASE SAVE FAILED: \(error.localizedDescription). Photos preserved.")
                    self.preview?.captureFlash(color: .systemRed)
                    NSSound.beep()
                    self.checkPendingCameraSwitchAfterCapture()
                    return
                }

                self.updateCount()
                self.preview?.captureFlash(color: .systemBlue)
                NSSound(named: NSSound.Name("Glass"))?.play()
                self.isProcessing = false
                self.lockedAfterCapture = true
                self.awaitingSerialFromCapture = true
                self.emptyFrames = 0

                let waiting = self.ocrPending.count + (self.ocrBusy ? 1 : 0)
                self.diagnostics.highWaterQueueDepth = max(self.diagnostics.highWaterQueueDepth, waiting + 1)
                self.status("Smart Exposure captured (\(transaction.capturedExposures.count) photos)! Reading in background…")
                self.lastLabel?.stringValue = "Last: multi-exposure saved, OCR pending…"

                let focus = self.shouldFocusIssueDate()
                let recent = recentScanIssueDates(before: ISO8601DateFormatter().string(from: Date()), among: self.records)
                let job = OCRJobContext(
                    id: id,
                    originalURL: primaryOriginalURL,
                    automatic: transaction.automatic,
                    focusIssueDate: focus,
                    recentIssueDates: recent,
                    captureRequestedAt: transaction.requestedAt,
                    enqueuedAt: Date().timeIntervalSince1970,
                    bracketedExposures: savedBracketed
                )
                self.ocrPending.append(job)
                self.pumpOCR()
                self.checkPendingCameraSwitchAfterCapture()
            }
        }
    }

    func shouldFocusIssueDate() -> Bool {
        // When the bond still in view is only missing a confident issue date,
        // auto-retry zooms the date box (more crops, higher upscale, more variants).
        if let aid = autoFillRecordId, let existing = records.first(where: { $0.id == aid }) {
            return requiredFieldsMissing(existing).contains("issue date")
        }
        return false
    }

    func applySequenceFlag(_ record: inout BondRecord) {
        // Sequence disagreement is surfaced as date_check=uncertain in the CSV.
        // It must not force REVIEW now that a valid serial and face value are enough for green.
        applyRequiredStatus(&record)
    }

    func finishCapture(image: CGImage, jpegBytes: Data?, automatic: Bool, requestedAt: TimeInterval) {
        commitOriginalAndEnqueue(image: image, jpegBytes: jpegBytes, automatic: automatic, requestedAt: requestedAt)
    }

    func commitOriginalAndEnqueue(image: CGImage, jpegBytes: Data?, automatic: Bool = false, requestedAt: TimeInterval = Date().timeIntervalSince1970) {
        let id = UUID().uuidString
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let filename = "\(capturedAt.replacingOccurrences(of: ":", with: "-"))_\(id.prefix(8)).jpg"
        let originalRel = "photos/original_" + filename
        let processedRel = "photos/" + filename
        let originalURL = outputRoot.appendingPathComponent(originalRel)
        let processedURL = outputRoot.appendingPathComponent(processedRel)
        let width = image.width
        let height = image.height

        let quality = evaluateImageQuality(image)
        var qualityNotes: [String] = []
        if quality.isBlurry {
            qualityNotes.append("blurry (sharpness: \(String(format: "%.3f", quality.sharpnessScore)))")
        }
        if quality.isUnderExposed {
            qualityNotes.append("underexposed (mean: \(String(format: "%.2f", quality.meanLuminance)))")
        }
        if quality.isOverExposed {
            qualityNotes.append("overexposed (mean: \(String(format: "%.2f", quality.meanLuminance)))")
        }

        saveQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = jpegBytes ?? jpegData(image) else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.status("SAVE FAILED: could not encode the photograph.")
                    self.preview?.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph encode failed")
                }
                return
            }
            do {
                try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
                try data.write(to: originalURL, options: .atomic)
                try data.write(to: processedURL, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.status("SAVE FAILED: \(error.localizedDescription)")
                    self.preview?.captureFlash(color: .systemRed)
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
                    self.preview?.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph record write failed; photo file preserved on disk")
                    return
                }
                self.updateCount()
                self.preview?.captureFlash(color: .systemBlue)
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
                self.lastLabel?.stringValue = "Last: photograph saved, OCR pending…"
                ScanLog.shared.write("original saved status=PROCESSING frame=\(width)x\(height) bytes=\(data.count) total=\(self.records.count) capture_latency_ms=\(String(format: "%.1f", captureLatencyMs)) ocr_queue=\(waiting + 1) hwm=\(self.diagnostics.highWaterQueueDepth) sharpness=\(String(format: "%.3f", quality.sharpnessScore)) lum=\(String(format: "%.2f", quality.meanLuminance))")
                self.enqueueOCR(id: id, originalURL: originalURL, automatic: automatic, requestedAt: requestedAt)
            }
        }
    }

    func enqueueOCR(
        id: String,
        originalURL: URL,
        automatic: Bool,
        requestedAt: TimeInterval = Date().timeIntervalSince1970,
        associatedPhotos: [String]? = nil
    ) {
        let focus = shouldFocusIssueDate()
        let recent = recentScanIssueDates(before: ISO8601DateFormatter().string(from: Date()), among: records)
        var bracketed: [(biasEV: Float, url: URL, relativePath: String)] = []
        if let assoc = associatedPhotos {
            for rel in assoc where rel.hasSuffix("EV.jpg") {
                let url = outputRoot.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) {
                    let parsedBias = Self.parseBiasEV(fromRelativePath: rel)
                    bracketed.append((biasEV: parsedBias, url: url, relativePath: rel))
                }
            }
        }
        let job = OCRJobContext(
            id: id,
            originalURL: originalURL,
            automatic: automatic,
            focusIssueDate: focus,
            recentIssueDates: recent,
            captureRequestedAt: requestedAt,
            enqueuedAt: Date().timeIntervalSince1970,
            bracketedExposures: bracketed
        )
        ocrPending.append(job)
        pumpOCR()
    }

    private static func parseBiasEV(fromRelativePath relativePath: String) -> Float {
        let name = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        guard let lastUnderscore = name.lastIndex(of: "_") else { return 0.0 }
        let suffix = name[name.index(after: lastUnderscore)...].replacingOccurrences(of: "EV", with: "")
        return Float(suffix) ?? 0.0
    }

    func pumpOCR() {
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
            let baselineResult = scanImage(image, focusIssueDate: job.focusIssueDate, recentIssueDates: job.recentIssueDates)

            if !job.bracketedExposures.isEmpty {
                var bracketedResults: [(biasEV: Float, result: OCRResult, photoRel: String)] = []
                for b in job.bracketedExposures {
                    if let bImg = cgImageFromFile(b.url) {
                        let bRes = scanImage(bImg, focusIssueDate: job.focusIssueDate, recentIssueDates: job.recentIssueDates)
                        bracketedResults.append((biasEV: b.biasEV, result: bRes, photoRel: b.relativePath))
                    }
                }
                let processingMs = (Date().timeIntervalSince1970 - ocrStartTime) * 1000.0
                DispatchQueue.main.async {
                    self.diagnostics.totalOCRCompleted += 1
                    self.diagnostics.totalProcessingTimeMs += processingMs
                    ScanLog.shared.write("multi-exposure ocr finished exposures=\(job.bracketedExposures.count + 1) processing_ms=\(String(format: "%.1f", processingMs))")
                    let basePhotoRel = "photos/original_" + job.originalURL.lastPathComponent.replacingOccurrences(of: "original_", with: "")
                    self.applyMultiExposureOCR(
                        baselineResult: baselineResult,
                        baselinePhotoRel: basePhotoRel,
                        bracketedResults: bracketedResults,
                        to: job.id,
                        automatic: job.automatic
                    )
                    self.ocrBusy = false
                    self.pumpOCR()
                    self.reviewWindowController?.coordinator.setAIBackgroundWorkDeferred(self.ocrBusy || !self.ocrPending.isEmpty)
                }
                return
            }

            let processingMs = (Date().timeIntervalSince1970 - ocrStartTime) * 1000.0
            DispatchQueue.main.async {
                self.diagnostics.totalOCRCompleted += 1
                self.diagnostics.totalProcessingTimeMs += processingMs
                ScanLog.shared.write("ocr finished processing_ms=\(String(format: "%.1f", processingMs)) avg_ocr_ms=\(String(format: "%.1f", self.diagnostics.averageOCRLatencyMs)) bpm=\(String(format: "%.1f", self.diagnostics.throughputBondsPerMinute)) queue_remaining=\(self.ocrPending.count)")
                self.applyOCR(baselineResult, to: job.id, automatic: job.automatic)
                self.ocrBusy = false
                self.pumpOCR()
                self.reviewWindowController?.coordinator.setAIBackgroundWorkDeferred(self.ocrBusy || !self.ocrPending.isEmpty)
            }
        }
    }

    func markOCRFailed(id: String, message: String) {
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
        preview?.captureFlash(color: .systemRed)
        status(message)
        awaitingSerialFromCapture = false
        ScanLog.shared.write("ocr failed; original photograph preserved")
    }

    func writeProcessedImage(_ image: CGImage, to relative: String, fallbackSource: String) {
        guard !relative.isEmpty else { return }
        let dest = outputRoot.appendingPathComponent(relative)
        let original = outputRoot.appendingPathComponent(fallbackSource)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = jpegData(image) {
                try data.write(to: dest, options: .atomic)
            } else if !fallbackSource.isEmpty, FileManager.default.fileExists(atPath: original.path) {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: original, to: dest)
            }
        } catch {
            ScanLog.shared.write("processed photograph write issue; original is preserved")
            if !FileManager.default.fileExists(atPath: dest.path),
               !fallbackSource.isEmpty,
               FileManager.default.fileExists(atPath: original.path)
            {
                try? FileManager.default.copyItem(at: original, to: dest)
            }
        }
    }

    func trashCapturePhotos(_ record: BondRecord) {
        _ = try? safelyTrashPhotographs(for: record, existingRecords: records, database: DatabaseManager.shared, root: outputRoot)
    }

    func priorRecord(for incoming: BondRecord) -> BondRecord? {
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

    func endAutoFill(reason: String) {
        guard autoFillRecordId != nil else { return }
        ScanLog.shared.write("auto fill ended: \(reason)")
        autoFillRecordId = nil
        autoFillAttempts = 0
        autoFillRect = nil
        autoFillGoneFrames = 0
    }

    func presentRecord(_ record: BondRecord, flash: NSColor, message: String, automatic: Bool, contributed: Bool, isNew: Bool) {
        var record = record
        let priorStatus = record.status
        let priorNotes = record.notes
        applySequenceFlag(&record)
        if record.status != priorStatus || record.notes != priorNotes,
           let idx = records.firstIndex(where: { $0.id == record.id })
        {
            let previous = records
            records[idx] = record
            do {
                try saveRecordLive(record, allRecords: records, sortOrder: idx)
            } catch {
                records = previous
                status("DATABASE SAVE FAILED: \(error.localizedDescription)")
                preview?.captureFlash(color: .systemRed)
                NSSound.beep()
                ScanLog.shared.write("presentRecord save failed; rolling back in-memory state")
                return
            }
        }
        updateCount()
        let serialDisplay = record.serial.isEmpty ? "unreadable serial" : record.serial
        lastLabel?.stringValue = "Last: \(record.series) \(serialDisplay) | \(record.issueMonth)/\(record.issueYear) | $\(record.denomination) | \(record.status)"
        let captured = normalizeSerial(record.serial)
        if !captured.isEmpty {
            lastCapturedSerial = captured
        }
        awaitingSerialFromCapture = false
        preview?.captureFlash(color: flash)
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

    func applyOCR(_ result: OCRResult, to id: String, automatic: Bool = false) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            ScanLog.shared.write("ocr result ignored; record no longer present")
            return
        }
        let row = records[index]
        var incoming = result.record
        incoming.id = row.id
        incoming.capturedAt = row.capturedAt
        incoming.sourcePhoto = row.sourcePhoto
        if row.photo.isEmpty {
            incoming.photo = row.sourcePhoto.replacingOccurrences(of: "photos/original_", with: "photos/")
        } else {
            incoming.photo = row.photo
        }
        if let rowAssoc = row.associatedPhotos, !rowAssoc.isEmpty {
            addAssociatedPhotos(to: &incoming, newPhotos: rowAssoc)
        }
        if !row.notes.isEmpty, row.notes != "Photograph saved; OCR pending", !incoming.notes.contains(row.notes) {
            incoming.notes = incoming.notes.isEmpty ? row.notes : "\(row.notes); \(incoming.notes)"
        }
        incoming.revision = (row.revision ?? 0) + 1
        applyRequiredStatus(&incoming)

        // Prevent stale OCR jobs from overwriting newer user changes
        if row.status != "PROCESSING" {
            var preserved = row
            _ = mergeBondRecord(from: incoming, into: &preserved,
                                contributingPhoto: incoming.photo,
                                contributingSource: incoming.sourcePhoto,
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

        // Always persist the processed image so `incoming.photo` resolves on disk across all paths
        writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)

        // DUPLICATE CONSOLIDATION: Exact, validated serial match with no conflicting fields
        // Prioritized before near-matches so valid captures are not misclassified as near-duplicates
        if let prior = priorRecord(for: incoming), let priorIndex = records.firstIndex(where: { $0.id == prior.id }) {
            var merged = records[priorIndex]
            let filled = mergeBondRecord(from: incoming, into: &merged,
                                         contributingPhoto: incoming.photo,
                                         contributingSource: incoming.sourcePhoto,
                                         captureId: incoming.id)
            let incomingFieldPhotos = Array((incoming.fieldPhoto ?? [:]).values)
            if filled.isEmpty {
                // Exact match with no new fields. Keep the original photograph on disk. Never trash it!
                let preserveNote = "Duplicate scan photo preserved at \(incoming.sourcePhoto)"
                merged.notes = merged.notes.isEmpty ? preserveNote : "\(merged.notes); \(preserveNote)"
                addAssociatedPhotos(
                    to: &merged,
                    newPhotos: [incoming.sourcePhoto, incoming.photo] + (incoming.associatedPhotos ?? []) + incomingFieldPhotos
                )
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
                                  automatic: automatic, contributed: false, isNew: false)
                    checkPendingCameraSwitchAfterCapture()
                } catch {
                    records = previous
                    status("Atomic duplicate merge failed: \(error.localizedDescription). Photo preserved.")
                    preview?.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("atomic duplicate merge failed; photo preserved")
                    checkPendingCameraSwitchAfterCapture()
                }
                return
            }
            addAssociatedPhotos(
                to: &merged,
                newPhotos: [incoming.sourcePhoto, incoming.photo] + (incoming.associatedPhotos ?? []) + incomingFieldPhotos
            )
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
                preview?.captureFlash(color: .systemRed)
                NSSound.beep()
                ScanLog.shared.write("atomic merge failed; photo preserved")
                checkPendingCameraSwitchAfterCapture()
                return
            }
            let fieldList = filled.joined(separator: ", ")
            ScanLog.shared.write("merged fields=\(fieldList) into existing record atomically; photograph kept (prior id=\(prior.id.prefix(8))) status=\(merged.status)")
            let flash: NSColor = requiredFieldsComplete(merged) ? .systemGreen : .systemYellow
            let message = requiredFieldsComplete(merged)
                ? "Updated the existing record with \(fieldList). Automatic validation passed. Remove the bond."
                : "Updated the existing record with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", "))."
            presentRecord(merged, flash: flash, message: message, automatic: automatic, contributed: true, isNew: false)
            checkPendingCameraSwitchAfterCapture()
            return
        }

        // DUPLICATE SAFETY: OCR-confusable near-match handling (Priority 2)
        // Never automatically merge near-matches. Preserve as a separate record for user review with structured review reason.
        if let near = findNearMatchRecord(incoming, in: records, excluding: incoming.id) {
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
                              automatic: automatic, contributed: true, isNew: true)
                checkPendingCameraSwitchAfterCapture()
                return
            } catch {
                records = previous
                status("Near-match record could not be saved: \(error.localizedDescription)")
                preview?.captureFlash(color: .systemRed)
                NSSound.beep()
                ScanLog.shared.write("near-match record write failed; photograph preserved")
                checkPendingCameraSwitchAfterCapture()
                return
            }
        }

        annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
        applyRequiredStatus(&incoming)
        let previous = records
        records[index] = incoming
        do { try saveRecordLive(incoming, allRecords: records, sortOrder: index) }
        catch {
            records = previous
            status("OCR results could not be saved: \(error.localizedDescription)")
            preview?.captureFlash(color: .systemRed)
            NSSound.beep()
            ScanLog.shared.write("ocr record write failed; original photograph preserved")
            checkPendingCameraSwitchAfterCapture()
            return
        }
        ScanLog.shared.write("scan updated status=\(incoming.status) fields_nonempty=\([incoming.series, incoming.serial, incoming.issueMonth, incoming.issueYear, incoming.denomination].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
        let flash: NSColor = incoming.status == "OK" ? .systemGreen : .systemYellow
        let message = incoming.status == "OK"
            ? "OCR complete — automatic validation passed. Remove the bond, then show the next one."
            : "OCR complete — review needed (\(requiredFieldsMissing(incoming).joined(separator: ", "))). Remove the bond, then show the next one."
        let isNew = (incoming.userConfirmedFields ?? []).isEmpty
        presentRecord(incoming, flash: flash, message: message, automatic: automatic, contributed: true, isNew: isNew)
        checkPendingCameraSwitchAfterCapture()
    }

    func applyMultiExposureOCR(
        baselineResult: OCRResult,
        baselinePhotoRel: String,
        bracketedResults: [(biasEV: Float, result: OCRResult, photoRel: String)],
        to id: String,
        automatic: Bool = false
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            ScanLog.shared.write("multi-exposure ocr result ignored; record no longer present")
            return
        }
        let baseRecord = records[index]

        let evalResult = MultiExposureOCREvaluator.evaluate(
            baselineResult: baselineResult,
            baselinePhotoRel: baselinePhotoRel,
            bracketedResults: bracketedResults,
            baseRecord: baseRecord
        )

        let anyBondText = baselineResult.bondTextFound || bracketedResults.contains(where: \.result.bondTextFound)
        let reconciledOCR = OCRResult(
            record: evalResult.reconciledRecord,
            image: baselineResult.image,
            originalImage: baselineResult.originalImage,
            huntScore: baselineResult.huntScore,
            lineCount: baselineResult.lineCount,
            rectified: baselineResult.rectified,
            bondTextFound: anyBondText
        )

        applyOCR(reconciledOCR, to: id, automatic: automatic)
    }

    func handleOCR(_ result: OCRResult, auto: Bool) {
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
                                          ? "Same bond already validated. Remove it before the next one."
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
                addAssociatedPhotos(to: &merged, newPhotos: [incoming.sourcePhoto, incoming.photo] + (incoming.associatedPhotos ?? []))
                records[priorIndex] = merged
                try saveRecordLive(merged, allRecords: records, sortOrder: priorIndex)
                let fieldList = (filled2.isEmpty ? filled : filled2).joined(separator: ", ")
                ScanLog.shared.write("merged fields=\(fieldList) into existing record; photograph kept (prior id=\(prior.id.prefix(8))) status=\(merged.status)")
                isProcessing = false
                let flash: NSColor = requiredFieldsComplete(merged) ? .systemGreen : .systemYellow
                let message: String
                if requiredFieldsComplete(merged) {
                    message = "Updated the existing record with \(fieldList). Automatic validation passed. Remove the bond."
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
                message = "Saved! Automatic validation passed. Remove the bond, then show the next one."
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

    @objc func exportCSVAction() {
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

    @objc func rearm() {
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

    @objc func undoLast() {
        guard let last = records.last else { return }
        let alert = NSAlert()
        alert.messageText = "Undo the last bond?"
        alert.informativeText = "Removes the last spreadsheet row and moves its photograph to the Trash."
        alert.addButton(withTitle: "Undo")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let remaining = records.dropLast()
        do {
            try deleteRecordLive(id: last.id, allRecords: Array(remaining))
            records.removeLast()
            _ = try? safelyTrashPhotographs(for: last, existingRecords: records, database: DatabaseManager.shared, root: outputRoot)
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
            status("Cannot undo: \(error.localizedDescription)")
        }
    }

    @objc func importPhotos() {
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

    func importFiles(_ urls: [URL]) {
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
