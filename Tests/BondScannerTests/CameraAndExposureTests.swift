import AppKit
import AVFoundation
@testable import BondScanner
import CoreGraphics
import XCTest

final class CameraAndExposureTests: XCTestCase {
    private var rootSandboxDir: URL!
    private var tempDir: URL!
    private var backupsDir: URL!
    private var testDbURL: URL!
    private var testDb: DatabaseManager!

    override func setUp() {
        super.setUp()
        ScanLog.shared.isEnabled = false
        rootSandboxDir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-exposure-tests-\(UUID().uuidString)", isDirectory: true)
        tempDir = rootSandboxDir.appendingPathComponent("output", isDirectory: true)
        backupsDir = rootSandboxDir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        StorageConfiguration.shared.setCustomRoots(outputRoot: tempDir, backupsRoot: backupsDir)
        ExportConfiguration.shared.setCustomDestinations(
            records: tempDir.appendingPathComponent("records.json"),
            csv: tempDir.appendingPathComponent("bonds.csv")
        )
        testDbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        testDb = try? DatabaseManager(url: testDbURL)
        DatabaseManager.setSharedInstance(testDb)
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        ExportConfiguration.shared.resetToDefaults()
        StorageConfiguration.shared.resetToDefaults()
        DatabaseManager.setSharedInstance(nil)
        testDb = nil
        if let dir = rootSandboxDir {
            try? FileManager.default.removeItem(at: dir)
            rootSandboxDir = nil
            tempDir = nil
            backupsDir = nil
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func createTestCGImage(width: Int = 200, height: Int = 100, grayValue: UInt8 = 128) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: grayValue, count: width * height)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return context.makeImage()!
    }

    private func createSharpBondPatternCGImage(width: Int = 400, height: Int = 200) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 235, count: height * bytesPerRow)
        for y in stride(from: 20, to: height - 20, by: 12) {
            for x in 20 ..< (width - 20) where (x / 6) % 2 == 0 {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = 20
                pixels[offset + 1] = 20
                pixels[offset + 2] = 20
                pixels[offset + 3] = 255
            }
        }
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func makeOCRResult(record: BondRecord, huntScore: Int = 90) -> OCRResult {
        let dummy = createTestCGImage()
        return OCRResult(
            record: record,
            image: dummy,
            originalImage: dummy,
            huntScore: huntScore,
            lineCount: 5,
            rectified: false,
            bondTextFound: true
        )
    }

    // MARK: - Mock Camera Controller

    private final class MockCameraController: CameraExposureControlling {
        var capabilities: CameraHardwareExposureCapabilities
        var setBiasCallCount = 0
        var appliedBiases: [Float] = []
        var restoreExposureCallCount = 0
        var captureCallCount = 0

        var biasFails = false
        var settlingTimesOut = false
        var hangsWithoutCallbackOnNonZeroBias = false
        var hangsWithoutCallbackOnBaselineCapture = false
        var disconnects = false
        var onStepStarted: ((Float) -> Void)?
        var luminanceByBias: [Float: Float] = [:]
        var syntheticImage: CGImage?

        init(capabilities: CameraHardwareExposureCapabilities) {
            self.capabilities = capabilities
        }

        func setExposureBias(_ bias: Float, completion: @escaping (Result<Void, Error>) -> Void) {
            setBiasCallCount += 1
            appliedBiases.append(bias)
            onStepStarted?(bias)

            if hangsWithoutCallbackOnNonZeroBias {
                // Intentionally never invoke completion to test ExposureBracketController timeout
                return
            }
            if disconnects {
                completion(.failure(ExposureBracketError.deviceDisconnected))
                return
            }
            if settlingTimesOut {
                completion(.failure(ExposureBracketError.exposureSettlingTimedOut))
                return
            }
            if biasFails || !capabilities.supportsHardwareAdjustment {
                completion(.failure(ExposureBracketError.hardwareAdjustmentUnsupported))
                return
            }
            completion(.success(()))
        }

        func restoreExposure(completion: @escaping () -> Void) {
            restoreExposureCallCount += 1
            completion()
        }

        func captureStillPhoto(for bias: Float, completion: @escaping (Result<CapturedExposure, Error>) -> Void) {
            captureCallCount += 1
            onStepStarted?(bias)
            if bias == 0.0, hangsWithoutCallbackOnBaselineCapture {
                // Intentionally never invoke completion to test baseline capture timeout
                return
            }
            if disconnects {
                completion(.failure(ExposureBracketError.deviceDisconnected))
                return
            }

            let lum = luminanceByBias[bias] ?? (0.50 + bias * 0.15)
            let colorSpace = CGColorSpaceCreateDeviceGray()
            var pixels = [UInt8](repeating: UInt8(max(0, min(255, lum * 255.0))), count: 200 * 100)
            let ctx = CGContext(data: &pixels, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 200, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let img = syntheticImage ?? ctx.makeImage()!

            let exp = CapturedExposure(
                biasEV: bias,
                image: img,
                jpegBytes: jpegData(img),
                meanLuminance: lum,
                sharpnessScore: 0.045,
                isBaseline: bias == 0.0
            )
            completion(.success(exp))
        }
    }

    // MARK: - Camera Selection Tests

    func testUSBCameraPreferredOverBuiltIn() {
        let builtIn = WebcamDescriptor(id: "built-in-uid", localizedName: "FaceTime HD Camera", category: .builtIn)
        let usbCam = WebcamDescriptor(id: "usb-webcam-uid", localizedName: "NexiGo N940 2K Webcam", category: .usbWebcam)
        let devices = [builtIn, usbCam]

        let resolution = WebcamResolver.resolveActiveCamera(selection: .automaticPreferUSB, available: devices)
        XCTAssertEqual(resolution.selected?.id, usbCam.id)
        XCTAssertEqual(resolution.selected?.category, .usbWebcam)
        XCTAssertFalse(resolution.isExplicitMatch)
    }

    func testExplicitlySelectedBuiltInCameraHonored() {
        let builtIn = WebcamDescriptor(id: "built-in-uid", localizedName: "FaceTime HD Camera", category: .builtIn)
        let usbCam = WebcamDescriptor(id: "usb-webcam-uid", localizedName: "NexiGo N940 2K Webcam", category: .usbWebcam)
        let devices = [builtIn, usbCam]

        let resolution = WebcamResolver.resolveActiveCamera(selection: .explicit(uniqueID: builtIn.id), available: devices)
        XCTAssertEqual(resolution.selected?.id, builtIn.id)
        XCTAssertEqual(resolution.selected?.category, .builtIn)
        XCTAssertTrue(resolution.isExplicitMatch)
    }

    func testPersistedCameraRestoredAcrossLaunches() throws {
        let defaultsKey = "testCameraDefaults_\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsKey))
        defer { testDefaults.removePersistentDomain(forName: defaultsKey) }

        let prefs1 = WebcamPreferences(defaults: testDefaults, key: defaultsKey)
        prefs1.saveSelection(.explicit(uniqueID: "saved-device-unique-id"))

        let prefs2 = WebcamPreferences(defaults: testDefaults, key: defaultsKey)
        let loaded = prefs2.loadSelection()
        XCTAssertEqual(loaded, .explicit(uniqueID: "saved-device-unique-id"))
    }

    func testMissingSelectedCameraFallsBackSafely() {
        let builtIn = WebcamDescriptor(id: "built-in-uid", localizedName: "FaceTime HD Camera", category: .builtIn)
        let devices = [builtIn]

        let resolution = WebcamResolver.resolveActiveCamera(selection: .explicit(uniqueID: "unplugged-usb-cam"), available: devices)
        XCTAssertEqual(resolution.selected?.id, builtIn.id)
        XCTAssertFalse(resolution.isExplicitMatch)
    }

    func testCameraDisconnectAndReconnect() {
        let builtIn = WebcamDescriptor(id: "built-in-uid", localizedName: "FaceTime HD Camera", category: .builtIn)
        let usbCam = WebcamDescriptor(id: "usb-webcam-uid", localizedName: "NexiGo N940 2K Webcam", category: .usbWebcam)

        // 1. Initial with both available: chooses USB
        var available = [builtIn, usbCam]
        var res = WebcamResolver.resolveActiveCamera(selection: .automaticPreferUSB, available: available)
        XCTAssertEqual(res.selected?.id, usbCam.id)

        // 2. Disconnect USB: falls back to Built-In
        available = [builtIn]
        res = WebcamResolver.resolveActiveCamera(selection: .automaticPreferUSB, available: available)
        XCTAssertEqual(res.selected?.id, builtIn.id)

        // 3. Reconnect USB: returns to preferred USB
        available = [builtIn, usbCam]
        res = WebcamResolver.resolveActiveCamera(selection: .automaticPreferUSB, available: available)
        XCTAssertEqual(res.selected?.id, usbCam.id)
    }

    func testCameraSelectionWhileCaptureIsActive() throws {
        let coordinator = CaptureTransactionCoordinator()
        let transaction = coordinator.startTransaction(automatic: true, targetBiases: [0.0])
        XCTAssertNotNil(transaction)
        XCTAssertTrue(coordinator.isBusy)

        // Attempting to start another transaction while busy returns nil
        let secondTransaction = coordinator.startTransaction(automatic: true, targetBiases: [0.0])
        XCTAssertNil(secondTransaction)

        // Finishing the transaction frees the coordinator
        try coordinator.finishTransaction(id: XCTUnwrap(transaction?.id))
        XCTAssertFalse(coordinator.isBusy)
    }

    func testNoCameraImportOnlyBehavior() {
        let resolution = WebcamResolver.resolveActiveCamera(selection: .automaticPreferUSB, available: [])
        XCTAssertNil(resolution.selected)
        XCTAssertFalse(resolution.isExplicitMatch)
    }

    // MARK: - Exposure & Bracketing Tests

    func testThreeExposureSequenceOnCapableMockCamera() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let targets = capabilities.targetExposureBiases(requestedMode: .automatic)
        XCTAssertEqual(targets, [0.0, -0.7, 0.7])

        let mockCam = MockCameraController(capabilities: capabilities)
        mockCam.luminanceByBias = [0.0: 0.50, -0.7: 0.35, 0.7: 0.65]

        let transaction = CaptureTransaction(automatic: true, targetBiases: targets)
        let bracketController = ExposureBracketController()

        let expectation = expectation(description: "Three-exposure bracket completed")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case let .success(exposures):
                XCTAssertEqual(exposures.count, 3)
                XCTAssertEqual(exposures[0].biasEV, 0.0)
                XCTAssertEqual(exposures[1].biasEV, -0.7)
                XCTAssertEqual(exposures[2].biasEV, 0.7)
                XCTAssertTrue(transaction.haveGenuinelyDifferentExposures())
            case let .failure(err):
                XCTFail("Unexpected bracket failure: \(err)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockCam.setBiasCallCount, 2)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)
    }

    func testUnsupportedHardwareFallsBackToOnePhotograph() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: false,
            minBias: 0.0,
            maxBias: 0.0,
            isHardwareBracketingSupported: false
        )
        let targets = capabilities.targetExposureBiases(requestedMode: .automatic)
        XCTAssertEqual(targets, [0.0])

        let mockCam = MockCameraController(capabilities: capabilities)
        let transaction = CaptureTransaction(automatic: true, targetBiases: targets)
        let bracketController = ExposureBracketController()

        let expectation = expectation(description: "Fallback single photo completed")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case let .success(exposures):
                XCTAssertEqual(exposures.count, 1)
                XCTAssertEqual(exposures[0].biasEV, 0.0)
            case let .failure(err):
                XCTFail("Unexpected failure: \(err)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockCam.setBiasCallCount, 0)
    }

    func testExposureBiasClamping() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -0.3,
            maxBias: 0.4,
            isHardwareBracketingSupported: true
        )
        let targets = capabilities.targetExposureBiases(requestedMode: .automatic)
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets[0], 0.0)
        XCTAssertEqual(targets[1], -0.3, accuracy: 0.001)
        XCTAssertEqual(targets[2], 0.4, accuracy: 0.001)
    }

    func testExposureChangeNotTakingEffect() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        // Device ignores bias: reports same luminance 0.50 regardless of bias
        mockCam.luminanceByBias = [0.0: 0.50, -0.7: 0.50, 0.7: 0.50]

        let targets = capabilities.targetExposureBiases(requestedMode: .automatic)
        let transaction = CaptureTransaction(automatic: true, targetBiases: targets)
        let bracketController = ExposureBracketController()

        let expectation = expectation(description: "Bracket completed with ignored exposure fallback")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case let .success(exposures):
                // Falling back to baseline only when differences are insignificant
                XCTAssertEqual(exposures.count, 1)
                XCTAssertEqual(exposures[0].biasEV, 0.0)
            case let .failure(err):
                XCTFail("Unexpected failure: \(err)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)
    }

    func testTimeoutDuringExposureSettling() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        mockCam.settlingTimesOut = true

        let targets = capabilities.targetExposureBiases(requestedMode: .automatic)
        let transaction = CaptureTransaction(automatic: true, targetBiases: targets)
        let bracketController = ExposureBracketController()

        let expectation = expectation(description: "Timeout during settling handled")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case let .success(exposures):
                // Baseline was captured before timeout
                XCTAssertEqual(exposures.count, 1)
                XCTAssertEqual(exposures[0].biasEV, 0.0)
            case let .failure(err):
                XCTAssertEqual(err as? ExposureBracketError, .exposureSettlingTimedOut)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)
    }

    func testCameraDisconnectDuringBracketing() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        mockCam.disconnects = true

        let targets = capabilities.targetExposureBiases(requestedMode: .automatic)
        let transaction = CaptureTransaction(automatic: true, targetBiases: targets)
        let bracketController = ExposureBracketController()

        let expectation = expectation(description: "Disconnect handled safely")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case .success:
                XCTFail("Should not succeed when disconnected on first step")
            case let .failure(err):
                XCTAssertEqual(err as? ExposureBracketError, .deviceDisconnected)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)
    }

    func testCancellationAndShutdown() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        let transaction = CaptureTransaction(automatic: true, targetBiases: [0.0, -0.7, 0.7])
        transaction.cancel()

        let bracketController = ExposureBracketController()
        let expectation = expectation(description: "Cancelled transaction handled")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case .success:
                XCTFail("Cancelled transaction should fail")
            case let .failure(err):
                XCTAssertEqual(err as? ExposureBracketError, .captureCancelled)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)
    }

    func testPreviousExposureConfigurationRestored() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        let transaction = CaptureTransaction(automatic: true, targetBiases: [0.0, -0.7, 0.7])
        let bracketController = ExposureBracketController()

        let expectation = expectation(description: "Restoration verified")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertGreaterThanOrEqual(mockCam.restoreExposureCallCount, 1)
    }

    // MARK: - OCR and Persistence Tests

    func testOneRecordPerBracket() {
        let baseRecord = BondRecord(
            id: "bracket-test-1",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        let baseOCR = makeOCRResult(record: BondRecord(id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "05", issueYear: "1995", denomination: "50", owner: "John Doe", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "SERIES EE C1234567890EE"), huntScore: 90)
        let darkOCR = makeOCRResult(record: BondRecord(id: "dark", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "05", issueYear: "1995", denomination: "50", owner: "John Doe", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "First Bank", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "First Bank"), huntScore: 85)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: baseOCR,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [(-0.7, darkOCR, "photos/original_sample_-0.7EV.jpg")],
            baseRecord: baseRecord
        )

        // Exactly one record returned
        XCTAssertEqual(eval.reconciledRecord.id, baseRecord.id)
        XCTAssertEqual(eval.reconciledRecord.series, "EE")
        XCTAssertEqual(eval.reconciledRecord.serial, "C1234567890EE")
        XCTAssertEqual(eval.reconciledRecord.issuingAgent, "First Bank")
    }

    func testCorrectPhotographicProvenance() {
        let baseRecord = BondRecord(
            id: "provenance-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        var bRec = BondRecord(id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "", issueYear: "", denomination: "50", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "SERIES EE")
        bRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high"]
        let baseOCR = makeOCRResult(record: bRec, huntScore: 90)

        var brRec = BondRecord(id: "bright", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "10", issueYear: "1998", denomination: "50", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "10/1998")
        brRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]
        let brightOCR = makeOCRResult(record: brRec, huntScore: 88)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: baseOCR,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [(0.7, brightOCR, "photos/original_sample_+0.7EV.jpg")],
            baseRecord: baseRecord
        )

        let record = eval.reconciledRecord
        XCTAssertEqual(record.fieldPhoto?["series"], "photos/original_sample.jpg")
        XCTAssertEqual(record.fieldPhoto?["issueMonth"], "photos/original_sample_+0.7EV.jpg")
        XCTAssertEqual(record.fieldPhoto?["issueYear"], "photos/original_sample_+0.7EV.jpg")
        XCTAssertEqual(record.fieldSource?["issueMonth"], "exposure_+0.7EV")
        XCTAssertEqual(record.fieldConfidence?["issueDate"], "high")
    }

    func testContradictoryOCRValuesTriggerReview() {
        let baseRecord = BondRecord(
            id: "conflict-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        var bRec = BondRecord(id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "05", issueYear: "1995", denomination: "50", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "")
        bRec.fieldConfidence = ["denomination": "high"]
        let baseOCR = makeOCRResult(record: bRec, huntScore: 90)

        var dRec = BondRecord(id: "dark", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "05", issueYear: "1995", denomination: "100", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "")
        dRec.fieldConfidence = ["denomination": "high"]
        let darkOCR = makeOCRResult(record: dRec, huntScore: 85)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: baseOCR,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [(-0.7, darkOCR, "photos/original_sample_-0.7EV.jpg")],
            baseRecord: baseRecord
        )

        let record = eval.reconciledRecord
        XCTAssertTrue((record.reviewReasons ?? []).contains(where: { $0.contains("exposure_conflict: denomination") }))
        XCTAssertEqual(record.status, "REVIEW")
    }

    func testConfirmedUserValuesPreserved() {
        var baseRecord = BondRecord(
            id: "confirmed-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "EE", serial: "C9999999999EE", issueMonth: "01", issueYear: "1990", denomination: "1000",
            owner: "Human Confirmed", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "OK", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )
        baseRecord.userConfirmedFields = ["serial", "denomination", "owner"]

        let ocrCandidate = makeOCRResult(record: BondRecord(id: "c", capturedAt: "", series: "I", serial: "C0000000000EE", issueMonth: "12", issueYear: "2000", denomination: "50", owner: "Machine OCR", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: ""), huntScore: 95)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: ocrCandidate,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [],
            baseRecord: baseRecord
        )

        let record = eval.reconciledRecord
        XCTAssertEqual(record.serial, "C9999999999EE")
        XCTAssertEqual(record.denomination, "1000")
        XCTAssertEqual(record.owner, "Human Confirmed")
    }

    func testDatabaseWriteFailuresDoNotDestroyCaptures() {
        let photoFile = tempDir.appendingPathComponent("photos/original_sample.jpg")
        try? FileManager.default.createDirectory(at: photoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([1, 2, 3, 4]).write(to: photoFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: photoFile.path))

        // Opening a directory as a database URL fails
        let dirAsDbURL = tempDir.appendingPathComponent("dir_as_db")
        try? FileManager.default.createDirectory(at: dirAsDbURL, withIntermediateDirectories: true)
        let closedDb = try? DatabaseManager(url: dirAsDbURL)
        XCTAssertNil(closedDb)

        // Photo file remains safely preserved
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoFile.path))
    }

    func testOriginalPhotographsRemainAccessibleAfterRestart() {
        let rel = "photos/original_restart_test.jpg"
        let fileURL = tempDir.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sampleBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try? sampleBytes.write(to: fileURL)

        // Simulate restart by resolving against tempDir afresh
        let reopenedURL = tempDir.appendingPathComponent(rel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopenedURL.path))
        let readBytes = try? Data(contentsOf: reopenedURL)
        XCTAssertEqual(readBytes, sampleBytes)
    }

    func testNoXCTestAccessToProductionCollectionFiles() {
        let homeScans = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans")
        let homeSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BondScanner")

        // Ensure tempDir is completely disjoint from user home production paths
        XCTAssertFalse(tempDir.path.hasPrefix(homeScans.path))
        XCTAssertFalse(tempDir.path.hasPrefix(homeSupport.path))
    }

    // MARK: - Regression Tests

    func testCameraFormatAndFallbackResolutionSelection() {
        // Test 1080p fallback
        let fallbackFormat = select1080FallbackFormat(from: [])
        XCTAssertNil(fallbackFormat)
    }

    func testHardwareDiagnosticGeneration() {
        let diag = HardwareDiagnosticReport(
            activeDeviceName: "Test NexiGo Webcam",
            activeDeviceCategory: "USB Webcam",
            activeDeviceTransport: "usb ",
            activeDeviceModelID: "UVC Camera",
            activeFormatDimensions: "1920x1080",
            activeFormatSubtype: "420v",
            isPhotoOutputSupported: true,
            maxPhotoDimensions: "1920x1080",
            supportedExposureModes: ["continuousAutoExposure"],
            supportedFocusModes: ["continuousAutoFocus"],
            supportedWhiteBalanceModes: ["continuousAutoWhiteBalance"],
            hardwareExposureAdjustmentSupported: false,
            minExposureBias: 0.0,
            maxExposureBias: 0.0,
            smartExposureMode: "Automatic",
            totalConnectedCameras: 1,
            connectedCamerasSummary: ["[USB] Test NexiGo Webcam"],
            totalCaptures: 12,
            averageCaptureLatencyMs: 45.2,
            averageOCRLatencyMs: 230.1
        )

        let text = diag.formattedText
        XCTAssertTrue(text.contains("Test NexiGo Webcam"))
        XCTAssertTrue(text.contains("Hardware Exposure Bias Adjustment: Unsupported"))
        // Check zero private bond fields are present in diagnostic
        XCTAssertFalse(text.contains("serial"))
        XCTAssertFalse(text.contains("John Doe"))
    }

    // MARK: - Code Review Regression & Integration Tests

    func testCameraNamedWebcamWithoutUSBTransportClassifiedAsExternal() {
        // A non-USB external/virtual camera whose name contains "Webcam" must be .external, not .usbWebcam
        let nonUSB = WebcamResolver.categorize(
            localizedName: "Studio Virtual Webcam",
            modelID: "VirtualCam-1",
            manufacturer: "Acme Video",
            transportType: 0
        )
        XCTAssertEqual(nonUSB, .external)

        // A physical USB camera with verified 'usb ' transport (1_970_496_032) is .usbWebcam
        let physicalUSB = WebcamResolver.categorize(
            localizedName: "NexiGo N940P",
            modelID: "VendorID_1234",
            manufacturer: "NexiGo",
            transportType: 1_970_496_032
        )
        XCTAssertEqual(physicalUSB, .usbWebcam)

        // Built-in camera transport ('bltn' = 1_651_274_862) is .builtIn
        let builtIn = WebcamResolver.categorize(
            localizedName: "FaceTime HD Camera",
            modelID: "AppleCamera",
            manufacturer: "Apple Inc.",
            transportType: 1_651_274_862
        )
        XCTAssertEqual(builtIn, .builtIn)
    }

    func testMissingHardwareCallbackTimesOutAndRestoresExposure() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        mockCam.hangsWithoutCallbackOnNonZeroBias = true

        let transaction = CaptureTransaction(automatic: true, targetBiases: [0.0, -0.7, 0.7])
        let bracketController = ExposureBracketController(timeoutSeconds: 0.12)

        let exp = expectation(description: "Hanging callback timed out by controller")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case let .success(exposures):
                // Baseline was captured before -0.7 EV hung; controller restores exposure and falls back to baseline
                XCTAssertEqual(exposures.count, 1)
                XCTAssertEqual(exposures.first?.biasEV, 0.0)
                XCTAssertEqual(transaction.capturedExposures.count, 1)
            case let .failure(err):
                XCTFail("Expected fallback to captured baseline on secondary step timeout, got: \(err)")
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)

        // Also test when baseline capture itself never invokes its callback
        let mockCam2 = MockCameraController(capabilities: capabilities)
        mockCam2.hangsWithoutCallbackOnBaselineCapture = true
        let transaction2 = CaptureTransaction(automatic: true, targetBiases: [0.0, -0.7, 0.7])
        let exp2 = expectation(description: "Baseline hanging callback timed out")
        bracketController.executeBracket(transaction: transaction2, camera: mockCam2) { result in
            switch result {
            case .success:
                XCTFail("Expected timeout failure when baseline callback never arrives")
            case let .failure(err):
                XCTAssertEqual(err as? ExposureBracketError, .exposureSettlingTimedOut)
            }
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2.0)
        XCTAssertEqual(mockCam2.restoreExposureCallCount, 1)
    }

    func testMidFlightCancellationDuringBracketStepAbortsAndRestores() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        let transaction = CaptureTransaction(automatic: true, targetBiases: [0.0, -0.7, 0.7])
        mockCam.onStepStarted = { bias in
            if bias == -0.7 {
                transaction.cancel()
            }
        }

        let bracketController = ExposureBracketController(timeoutSeconds: 0.5)
        let exp = expectation(description: "Mid-flight cancellation aborts")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            switch result {
            case .success:
                XCTFail("Expected cancelled error when transaction is cancelled mid-flight")
            case let .failure(err):
                XCTAssertEqual(err as? ExposureBracketError, .captureCancelled)
            }
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(mockCam.restoreExposureCallCount, 1)
    }

    func testIgnoredExposureChangesSyncTransactionExposuresToBaselineOnly() {
        let capabilities = CameraHardwareExposureCapabilities(
            supportsHardwareAdjustment: true,
            minBias: -2.0,
            maxBias: 2.0,
            isHardwareBracketingSupported: true
        )
        let mockCam = MockCameraController(capabilities: capabilities)
        mockCam.luminanceByBias = [0.0: 0.50, -0.7: 0.505, 0.7: 0.495]

        let transaction = CaptureTransaction(automatic: true, targetBiases: [0.0, -0.7, 0.7])
        let bracketController = ExposureBracketController()

        let exp = expectation(description: "Unchanged exposures discarded from transaction")
        bracketController.executeBracket(transaction: transaction, camera: mockCam) { result in
            if case let .success(exposures) = result {
                XCTAssertEqual(exposures.count, 1)
                XCTAssertEqual(transaction.capturedExposures.count, 1)
                XCTAssertEqual(transaction.capturedExposures.first?.biasEV, 0.0)
            } else {
                XCTFail("Expected baseline-only success")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testMissingAlternateConfidenceDefaultsToUncertainAndDoesNotPromote() {
        let baseRecord = BondRecord(
            id: "conf-default-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        var baseRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE",
            issueMonth: "", issueYear: "", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "SERIES EE"
        )
        baseRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high"]
        let baseOCR = makeOCRResult(record: baseRec)

        // Alternate has issueMonth/issueYear and a different serial, but NO fieldConfidence metadata (nil)
        let altRecWithoutConfidence = BondRecord(
            id: "alt", capturedAt: "", series: "EE", serial: "C9999999999EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "05/1995"
        )
        let altOCR = makeOCRResult(record: altRecWithoutConfidence)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: baseOCR,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [(-0.7, altOCR, "photos/original_sample_-0.7EV.jpg")],
            baseRecord: baseRecord
        )

        let reconciled = eval.reconciledRecord
        // Missing confidence on alternate must NOT enrich missing issueMonth/issueYear or promote them to high
        XCTAssertEqual(reconciled.issueMonth, "")
        XCTAssertEqual(reconciled.issueYear, "")
        XCTAssertNil(reconciled.fieldConfidence?["issueDate"])
    }

    func testUncertainAlternateReadingDoesNotReplaceUncertainBaseline() {
        let baseRecord = BondRecord(
            id: "uncertain-replace-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        var baseRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        baseRec.fieldConfidence = [
            "series": "high",
            "serial": "uncertain",
            "denomination": "high",
            "issueDate": "uncertain",
        ]
        let baseOCR = makeOCRResult(record: baseRec)

        var altRec = BondRecord(
            id: "alt", capturedAt: "", series: "EE", serial: "C1234567898EE",
            issueMonth: "06", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        altRec.fieldConfidence = [
            "series": "high",
            "serial": "uncertain",
            "denomination": "high",
            "issueDate": "uncertain",
        ]
        let altOCR = makeOCRResult(record: altRec)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: baseOCR,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [(-0.7, altOCR, "photos/original_sample_-0.7EV.jpg")],
            baseRecord: baseRecord
        )

        let reconciled = eval.reconciledRecord
        // Baseline values must be retained; uncertain alternate readings must not replace them
        XCTAssertEqual(reconciled.serial, "C1234567890EE")
        XCTAssertEqual(reconciled.issueMonth, "05")
        XCTAssertEqual(reconciled.fieldConfidence?["serial"], "uncertain")
        XCTAssertEqual(reconciled.fieldConfidence?["issueDate"], "uncertain")
        XCTAssertEqual(reconciled.status, "REVIEW")
        XCTAssertTrue((reconciled.reviewReasons ?? []).contains(where: { $0.contains("exposure_conflict: serial") }))
        XCTAssertTrue((reconciled.reviewReasons ?? []).contains(where: { $0.contains("exposure_conflict: issueMonth") }))
    }

    func testStabilizationSharpnessGateRejectsBlurryFramesAndAcceptsSharpFrames() {
        let app = BondScannerApp()
        app.automatic = true
        app.fastScanEnabled = true
        app.isProcessing = false
        app.lockedAfterCapture = false

        let rect = CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70)

        // 1. Uniform blurry frame: sharpnessScore == 0.0 (< fastScanSharpnessThreshold 0.012)
        let blurryFrame = createTestCGImage(width: 400, height: 200, grayValue: 128)
        let blurryQuality = evaluateImageQuality(blurryFrame, region: rect)
        XCTAssertFalse(blurryQuality.isSharp)
        XCTAssertLessThan(blurryQuality.sharpnessScore, ImageQualityReport.fastScanSharpnessThreshold)

        app.handleRectangle(rect, frame: blurryFrame)
        app.handleRectangle(rect, frame: blurryFrame)
        app.handleRectangle(rect, frame: blurryFrame)
        XCTAssertFalse(app.isProcessing, "Blurry frames must never pass the sharpness gate")

        // Even after bounded timeout elapses, a blurry frame must not trigger capture
        app.stabilizationStartTime = Date().timeIntervalSince1970 - 5.0
        app.handleRectangle(rect, frame: blurryFrame)
        XCTAssertFalse(app.isProcessing, "Bounded timeout fallback must still require sharpness")

        // 2. Sharp frame with high-contrast edges: quality.isSharp == true (normalized score >= 0.015)
        let sharpFrame = createSharpBondPatternCGImage(width: 400, height: 200)
        let sharpQuality = evaluateImageQuality(sharpFrame, region: rect)
        XCTAssertTrue(sharpQuality.isSharp)
        XCTAssertGreaterThanOrEqual(sharpQuality.sharpnessScore, ImageQualityReport.standardSharpnessThreshold)
        XCTAssertLessThanOrEqual(sharpQuality.sharpnessScore, 1.0)

        app.stableFrames = 0
        app.priorRect = nil
        app.stabilizationStartTime = 0
        app.nextAutoAllowedAt = 0

        // Frame 1 establishes priorRect (stableFrames = 1)
        app.handleRectangle(rect, frame: sharpFrame)
        XCTAssertEqual(app.stableFrames, 1)
        XCTAssertFalse(app.isProcessing)

        // Frame 2 is position-stable, low-motion, and sharp -> triggers automatic capture!
        app.handleRectangle(rect, frame: sharpFrame)
        XCTAssertTrue(app.isProcessing, "Sharp, stable frames must pass the normalized sharpness gate and trigger capture")
    }

    func testUntrackedAndCancelledPhotoCallbacksAreRejectedNotSavedAsManualCapture() throws {
        let app = BondScannerApp()
        let img = createSharpBondPatternCGImage(width: 300, height: 150)
        let dims = CMVideoDimensions(width: 300, height: 150)

        // 1. Untracked callback (no matching entry in photoRequests) must be ignored
        app.handlePhotoCaptureCallback(
            uniqueID: 99999,
            dimensions: dims,
            jpegData: jpegData(img),
            cgImage: img,
            error: nil
        )
        XCTAssertTrue(app.records.isEmpty, "Untracked photo callback must not default to a manual capture")

        // 2. Cancelled transaction callback must be ignored
        let tx = try XCTUnwrap(app.captureTransactionCoordinator.startTransaction(
            automatic: false,
            targetBiases: [0.0],
            deviceUniqueID: "cam-1",
            sessionGeneration: app.cameraSessionGeneration
        ))
        var callbackResult: Result<CapturedExposure, Error>?
        app.photoRequests[1001] = BondScannerApp.PhotoRequestInfo(
            transactionId: tx.id,
            sessionGeneration: app.cameraSessionGeneration,
            deviceUniqueID: nil,
            automatic: false,
            requestedAt: Date().timeIntervalSince1970,
            biasEV: 0.0,
            completion: { callbackResult = $0 }
        )
        app.cancelInFlightCaptures(reason: "unit test cancellation")
        if case let .failure(err) = callbackResult {
            XCTAssertEqual(err as? ExposureBracketError, .captureCancelled)
        } else {
            XCTFail("Cancelling in-flight captures must notify pending request completion")
        }

        // Late arrival of hardware callback 1001 after cancellation
        app.handlePhotoCaptureCallback(
            uniqueID: 1001,
            dimensions: dims,
            jpegData: jpegData(img),
            cgImage: img,
            error: nil
        )
        XCTAssertTrue(app.records.isEmpty, "Cancelled photo callback must be ignored")

        // 3. Superseded cameraSessionGeneration callback must be ignored
        let tx2 = try XCTUnwrap(app.captureTransactionCoordinator.startTransaction(
            automatic: false,
            targetBiases: [0.0],
            deviceUniqueID: nil,
            sessionGeneration: app.cameraSessionGeneration
        ))
        app.photoRequests[1002] = BondScannerApp.PhotoRequestInfo(
            transactionId: tx2.id,
            sessionGeneration: app.cameraSessionGeneration,
            deviceUniqueID: nil,
            automatic: false,
            requestedAt: Date().timeIntervalSince1970,
            biasEV: 0.0,
            completion: nil
        )
        // Simulate camera switch incrementing generation before callback arrives
        app.cameraSessionGeneration &+= 1
        app.handlePhotoCaptureCallback(
            uniqueID: 1002,
            dimensions: dims,
            jpegData: jpegData(img),
            cgImage: img,
            error: nil
        )
        XCTAssertTrue(app.records.isEmpty, "Callback from superseded camera session generation must be ignored")
        app.captureTransactionCoordinator.finishTransaction(id: tx2.id)
    }

    func testMultiExposureExactDuplicateConsolidatesIntoExistingRecord() throws {
        let app = BondScannerApp()
        let img = createSharpBondPatternCGImage(width: 300, height: 150)

        // Create existing record in app and SQLite (missing issueMonth/issueYear)
        try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
        let priorOrig = "photos/original_prior.jpg"
        let priorProc = "photos/prior.jpg"
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(priorOrig))
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(priorProc))

        var existing = BondRecord(
            id: "existing-bond-1",
            capturedAt: "2026-11-15T10:00:00Z",
            series: "EE",
            serial: "L1234567890EE",
            issueMonth: "",
            issueYear: "",
            denomination: "50",
            owner: "JANE DOE",
            secondName: "",
            secondRole: "",
            address: "",
            taxID: "",
            issuingAgent: "",
            datingStamp: "",
            status: "OK",
            notes: "",
            photo: priorProc,
            sourcePhoto: priorOrig,
            rawOCR: "SERIES EE L1234567890EE",
            fieldPhoto: ["series": priorOrig, "serial": priorOrig, "denomination": priorOrig],
            fieldConfidence: ["series": "high", "serial": "high", "denomination": "high"]
        )
        applyRequiredStatus(&existing)
        app.records = [existing]
        try saveRecordLive(existing, allRecords: app.records, sortOrder: 0)

        // Create incoming PROCESSING record from a multi-exposure capture of the SAME bond
        let incomingOrig = "photos/original_incoming.jpg"
        let incomingProc = "photos/incoming.jpg"
        let incomingPlus = "photos/original_incoming_+0.7EV.jpg"
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(incomingOrig))
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(incomingPlus))

        var incomingPlaceholder = emptyBondRecord(id: "incoming-multi-1", capturedAt: "2026-11-15T10:05:00Z")
        incomingPlaceholder.photo = incomingProc
        incomingPlaceholder.sourcePhoto = incomingOrig
        incomingPlaceholder.associatedPhotos = [incomingPlus]
        app.records.append(incomingPlaceholder)
        try saveRecordLive(incomingPlaceholder, allRecords: app.records, sortOrder: 1)

        var baseRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "L1234567890EE",
            issueMonth: "", issueYear: "", denomination: "50",
            owner: "JANE DOE", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "SERIES EE L1234567890EE"
        )
        baseRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high"]
        let baseOCR = OCRResult(record: baseRec, image: img, originalImage: img, huntScore: 90, lineCount: 5, rectified: true, bondTextFound: true)

        var brightRec = BondRecord(
            id: "bright", capturedAt: "", series: "EE", serial: "L1234567890EE",
            issueMonth: "08", issueYear: "1996", denomination: "50",
            owner: "JANE DOE", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "08/1996"
        )
        brightRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]
        let brightOCR = OCRResult(record: brightRec, image: img, originalImage: img, huntScore: 88, lineCount: 5, rectified: true, bondTextFound: true)

        app.applyMultiExposureOCR(
            baselineResult: baseOCR,
            baselinePhotoRel: incomingOrig,
            bracketedResults: [(0.7, brightOCR, incomingPlus)],
            to: "incoming-multi-1"
        )

        // Must consolidate into the single existing record (never leaving a duplicate row)
        XCTAssertEqual(app.records.count, 1)
        let merged = try XCTUnwrap(app.records.first)
        XCTAssertEqual(merged.id, "existing-bond-1")
        XCTAssertEqual(merged.issueMonth, "08")
        XCTAssertEqual(merged.issueYear, "1996")
        XCTAssertEqual(merged.fieldPhoto?["issueMonth"], incomingPlus)
        XCTAssertTrue((merged.associatedPhotos ?? []).contains(incomingOrig))
        XCTAssertTrue((merged.associatedPhotos ?? []).contains(incomingPlus))

        let dbRecords = try testDb.loadAllRecords()
        XCTAssertEqual(dbRecords.count, 1)
        XCTAssertEqual(dbRecords.first?.id, "existing-bond-1")
        XCTAssertEqual(dbRecords.first?.issueMonth, "08")
    }

    func testMultiExposureNearMatchPreservedAsSeparateReviewRecord() throws {
        let app = BondScannerApp()
        let img = createSharpBondPatternCGImage(width: 300, height: 150)
        try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)

        let priorOrig = "photos/original_near1.jpg"
        let priorProc = "photos/near1.jpg"
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(priorOrig))
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(priorProc))

        var existing = BondRecord(
            id: "near-existing-1",
            capturedAt: "2026-11-15T10:00:00Z",
            series: "EE",
            serial: "L1234567890EE",
            issueMonth: "05",
            issueYear: "1995",
            denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "OK", notes: "",
            photo: priorProc, sourcePhoto: priorOrig, rawOCR: "",
            fieldConfidence: ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]
        )
        applyRequiredStatus(&existing)
        app.records = [existing]
        try saveRecordLive(existing, allRecords: app.records, sortOrder: 0)

        let incomingOrig = "photos/original_near2.jpg"
        let incomingProc = "photos/near2.jpg"
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(incomingOrig))

        var incomingPlaceholder = emptyBondRecord(id: "near-incoming-2", capturedAt: "2026-11-15T10:02:00Z")
        incomingPlaceholder.photo = incomingProc
        incomingPlaceholder.sourcePhoto = incomingOrig
        app.records.append(incomingPlaceholder)
        try saveRecordLive(incomingPlaceholder, allRecords: app.records, sortOrder: 1)

        // Single confusable character difference: '0' vs '8' at last digit
        var nearRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "L1234567898EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        nearRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]
        let nearOCR = OCRResult(record: nearRec, image: img, originalImage: img, huntScore: 92, lineCount: 5, rectified: true, bondTextFound: true)

        app.applyMultiExposureOCR(
            baselineResult: nearOCR,
            baselinePhotoRel: incomingOrig,
            bracketedResults: [],
            to: "near-incoming-2"
        )

        XCTAssertEqual(app.records.count, 2)
        let savedNear = try XCTUnwrap(app.records.first(where: { $0.id == "near-incoming-2" }))
        XCTAssertEqual(savedNear.status, "REVIEW")
        XCTAssertTrue((savedNear.reviewReasons ?? []).contains("near_match: near-existing-1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(savedNear.photo).path))
    }

    func testMultiExposureDatabaseWriteFailureRollsBackInMemoryStateAndNeverSuppressesError() throws {
        let app = BondScannerApp()
        let img = createSharpBondPatternCGImage(width: 300, height: 150)
        try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)

        let origRel = "photos/original_dbfail.jpg"
        let procRel = "photos/dbfail.jpg"
        try XCTUnwrap(jpegData(img)).write(to: tempDir.appendingPathComponent(origRel))

        var placeholder = emptyBondRecord(id: "dbfail-1", capturedAt: "2026-11-15T11:00:00Z")
        placeholder.photo = procRel
        placeholder.sourcePhoto = origRel
        app.records = [placeholder]
        try saveRecordLive(placeholder, allRecords: app.records, sortOrder: 0)

        // Force DatabaseManager writes to fail by closing the underlying database connection
        testDb.close()

        var ocrRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "L1234567890EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        ocrRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]
        let ocrRes = OCRResult(record: ocrRec, image: img, originalImage: img, huntScore: 90, lineCount: 5, rectified: true, bondTextFound: true)

        app.applyMultiExposureOCR(
            baselineResult: ocrRes,
            baselinePhotoRel: origRel,
            bracketedResults: [],
            to: "dbfail-1"
        )

        // Because the SQLite write failed, in-memory records must roll back to the pre-save state (status == "PROCESSING")
        XCTAssertEqual(app.records.first?.status, "PROCESSING")
        // And both original and processed photographs remain preserved on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(origRel).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(procRel).path))
    }

    func testMultiExposureAllStoredPhotographReferencesResolveAfterOCRRestartBackupAndRestore() throws {
        let app = BondScannerApp()
        let baseImg = createSharpBondPatternCGImage(width: 320, height: 160)
        let darkImg = createTestCGImage(width: 320, height: 160, grayValue: 80)
        let brightImg = createTestCGImage(width: 320, height: 160, grayValue: 200)

        let transaction = CaptureTransaction(
            automatic: false,
            targetBiases: [0.0, -0.7, 0.7]
        )
        transaction.addExposure(CapturedExposure(
            biasEV: 0.0,
            image: baseImg,
            jpegBytes: jpegData(baseImg),
            meanLuminance: 0.50,
            sharpnessScore: 0.05,
            isBaseline: true
        ))
        transaction.addExposure(CapturedExposure(
            biasEV: -0.7,
            image: darkImg,
            jpegBytes: jpegData(darkImg),
            meanLuminance: 0.31,
            sharpnessScore: 0.04,
            isBaseline: false
        ))
        transaction.addExposure(CapturedExposure(
            biasEV: 0.7,
            image: brightImg,
            jpegBytes: jpegData(brightImg),
            meanLuminance: 0.78,
            sharpnessScore: 0.04,
            isBaseline: false
        ))

        // Prevent automatic background OCR from racing with our controlled step-by-step assertions
        app.ocrBusy = true
        app.finishMultiExposureCapture(transaction: transaction)

        let savedExp = expectation(description: "Multi-exposure files and PROCESSING record saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            savedExp.fulfill()
        }
        wait(for: [savedExp], timeout: 2.0)

        let processingRecord = try XCTUnwrap(app.records.first)
        XCTAssertEqual(processingRecord.id, transaction.id.uuidString)

        // 1. Even BEFORE OCR runs (while PROCESSING), every photo path on the record must exist on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(processingRecord.photo).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(processingRecord.sourcePhoto).path))
        for assoc in processingRecord.associatedPhotos ?? [] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(assoc).path))
        }

        // 2. Run multi-exposure OCR reconciliation through production applyMultiExposureOCR
        let bracketedJob = try XCTUnwrap(app.ocrPending.first)
        var baseRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "L1234567890EE",
            issueMonth: "", issueYear: "", denomination: "50",
            owner: "JOHN SMITH", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "SERIES EE L1234567890EE"
        )
        baseRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high"]
        let baseOCR = OCRResult(record: baseRec, image: baseImg, originalImage: baseImg, huntScore: 95, lineCount: 6, rectified: true, bondTextFound: true)

        var darkRec = BondRecord(
            id: "dark", capturedAt: "", series: "EE", serial: "L1234567890EE",
            issueMonth: "11", issueYear: "1999", denomination: "50",
            owner: "JOHN SMITH", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "FEDERAL RESERVE", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "11/1999 FEDERAL RESERVE"
        )
        darkRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]
        let darkOCR = OCRResult(record: darkRec, image: darkImg, originalImage: darkImg, huntScore: 90, lineCount: 5, rectified: true, bondTextFound: true)

        let bracketInput: [(biasEV: Float, result: OCRResult, photoRel: String)] = bracketedJob.bracketedExposures.map { item in
            (biasEV: item.biasEV, result: darkOCR, photoRel: item.relativePath)
        }

        app.applyMultiExposureOCR(
            baselineResult: baseOCR,
            baselinePhotoRel: processingRecord.sourcePhoto,
            bracketedResults: bracketInput,
            to: processingRecord.id
        )

        func assertAllPhotosExist(for record: BondRecord, in root: URL, context: String) {
            XCTAssertFalse(record.photo.isEmpty, "photo empty in \(context)")
            XCTAssertFalse(record.sourcePhoto.isEmpty, "sourcePhoto empty in \(context)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.photo).path), "Missing record.photo (\(record.photo)) in \(context)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.sourcePhoto).path), "Missing record.sourcePhoto (\(record.sourcePhoto)) in \(context)")
            for assoc in record.associatedPhotos ?? [] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(assoc).path), "Missing associatedPhoto (\(assoc)) in \(context)")
            }
            for (field, path) in record.fieldPhoto ?? [:] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "Missing fieldPhoto[\(field)] (\(path)) in \(context)")
            }
        }

        // Verify after OCR
        let postOCRRecord = try XCTUnwrap(app.records.first)
        XCTAssertEqual(postOCRRecord.status, "OK")
        XCTAssertEqual(postOCRRecord.issueMonth, "11")
        XCTAssertEqual(postOCRRecord.issueYear, "1999")
        assertAllPhotosExist(for: postOCRRecord, in: tempDir, context: "after OCR")

        // 3. Simulate application restart by reopening SQLite database from disk
        let reopenedDB = try DatabaseManager(url: testDbURL)
        let restartedRecords = try reopenedDB.loadAllRecords()
        XCTAssertEqual(restartedRecords.count, 1)
        let restartedRecord = try XCTUnwrap(restartedRecords.first)
        assertAllPhotosExist(for: restartedRecord, in: tempDir, context: "after restart")

        // 4. Create backup and verify all referenced photographs exist in backup
        let backupURL = backupsDir.appendingPathComponent("multi_exp_backup", isDirectory: true)
        try reopenedDB.backupCollection(
            to: backupURL,
            photosSourceDir: tempDir.appendingPathComponent("photos", isDirectory: true)
        )
        assertAllPhotosExist(for: restartedRecord, in: backupURL, context: "inside backup archive")

        // 5. Restore backup into a clean collection root and verify every photograph reference resolves
        let restoredRoot = rootSandboxDir.appendingPathComponent("restored_collection", isDirectory: true)
        let restoredPhotosDir = restoredRoot.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: restoredPhotosDir, withIntermediateDirectories: true)
        let restoredDBURL = restoredRoot.appendingPathComponent("bonds.sqlite3")
        let restoredDB = try DatabaseManager(url: restoredDBURL)
        try restoredDB.restoreCollection(
            from: backupURL,
            destinationDBURL: restoredDBURL,
            destinationPhotosDir: restoredPhotosDir,
            authorized: true
        )
        let restoredRecords = try restoredDB.loadAllRecords()
        XCTAssertEqual(restoredRecords.count, 1)
        let restoredRecord = try XCTUnwrap(restoredRecords.first)
        XCTAssertEqual(restoredRecord.serial, "L1234567890EE")
        XCTAssertEqual(restoredRecord.issueMonth, "11")
        XCTAssertEqual(restoredRecord.issueYear, "1999")
        assertAllPhotosExist(for: restoredRecord, in: restoredRoot, context: "after restore")
    }

    func testConflictingHighConfidenceAlternateOverUncertainBaselineRequiresReview() {
        let baseRecord = BondRecord(
            id: "conflict-promote-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        var baseRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "C1234567890EE"
        )
        baseRec.fieldConfidence = [
            "series": "high",
            "serial": "uncertain",
            "denomination": "high",
            "issueDate": "high",
        ]
        let baseOCR = makeOCRResult(record: baseRec)

        var altRec = BondRecord(
            id: "alt", capturedAt: "", series: "EE", serial: "C9876543210EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: "C9876543210EE"
        )
        altRec.fieldConfidence = [
            "series": "high",
            "serial": "high",
            "denomination": "high",
            "issueDate": "high",
        ]
        let altOCR = makeOCRResult(record: altRec)

        let eval = MultiExposureOCREvaluator.evaluate(
            baselineResult: baseOCR,
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [(0.7, altOCR, "photos/original_sample_+0.7EV.jpg")],
            baseRecord: baseRecord
        )

        let record = eval.reconciledRecord
        XCTAssertNotNil(eval.conflictingFields["serial"])
        XCTAssertEqual(record.previousExtracted?["serial"], "C1234567890EE")
        XCTAssertEqual(record.sourcePhoto, "photos/original_sample.jpg")
        XCTAssertEqual(record.fieldPhoto?["serial"], "photos/original_sample_+0.7EV.jpg")
        XCTAssertTrue((record.reviewReasons ?? []).contains(where: { $0.contains("exposure_conflict: serial") }))
        XCTAssertEqual(record.status, "REVIEW")
    }

    func testIssueDatePrefersCoordinatedPairAndFlagsSplitExposureAssembly() {
        let baseRecord = BondRecord(
            id: "date-coord-test",
            capturedAt: "2026-11-15T12:00:00Z",
            series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "PROCESSING", notes: "",
            photo: "photos/sample.jpg", sourcePhoto: "photos/original_sample.jpg", rawOCR: ""
        )

        var baseRec = BondRecord(
            id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE",
            issueMonth: "05", issueYear: "", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        baseRec.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueMonth": "high"]

        var darkYearOnly = BondRecord(
            id: "dark", capturedAt: "", series: "EE", serial: "C1234567890EE",
            issueMonth: "", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        darkYearOnly.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueYear": "high"]

        var brightFullPair = BondRecord(
            id: "bright", capturedAt: "", series: "EE", serial: "C1234567890EE",
            issueMonth: "05", issueYear: "1995", denomination: "50",
            owner: "", secondName: "", secondRole: "", address: "", taxID: "",
            issuingAgent: "", datingStamp: "", status: "", notes: "",
            photo: "", sourcePhoto: "", rawOCR: ""
        )
        brightFullPair.fieldConfidence = ["series": "high", "serial": "high", "denomination": "high", "issueDate": "high"]

        // 1. Coordinated complete pair from +0.7EV is preferred over split assembly
        let preferredEval = MultiExposureOCREvaluator.evaluate(
            baselineResult: makeOCRResult(record: baseRec),
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [
                (-0.7, makeOCRResult(record: darkYearOnly), "photos/original_sample_-0.7EV.jpg"),
                (0.7, makeOCRResult(record: brightFullPair), "photos/original_sample_+0.7EV.jpg"),
            ],
            baseRecord: baseRecord
        )
        let preferred = preferredEval.reconciledRecord
        XCTAssertEqual(preferred.issueMonth, "05")
        XCTAssertEqual(preferred.issueYear, "1995")
        XCTAssertEqual(preferred.fieldPhoto?["issueMonth"], "photos/original_sample_+0.7EV.jpg")
        XCTAssertEqual(preferred.fieldPhoto?["issueYear"], "photos/original_sample_+0.7EV.jpg")
        XCTAssertEqual(preferred.fieldConfidence?["issueDate"], "high")
        XCTAssertEqual(preferred.status, "OK")

        // 2. When no single exposure has a complete pair, split assembly retains uncertainty & requires review
        let splitEval = MultiExposureOCREvaluator.evaluate(
            baselineResult: makeOCRResult(record: baseRec),
            baselinePhotoRel: "photos/original_sample.jpg",
            bracketedResults: [
                (-0.7, makeOCRResult(record: darkYearOnly), "photos/original_sample_-0.7EV.jpg"),
            ],
            baseRecord: baseRecord
        )
        let split = splitEval.reconciledRecord
        XCTAssertEqual(split.issueMonth, "05")
        XCTAssertEqual(split.issueYear, "1995")
        XCTAssertEqual(split.fieldConfidence?["issueDate"], "uncertain")
        XCTAssertTrue((split.reviewReasons ?? []).contains(where: { $0.contains("exposure_split_date") }))
        XCTAssertEqual(split.status, "REVIEW")
    }

    func testTextDetectionFallbackRoutesThroughStabilizationGate() {
        let app = BondScannerApp()
        app.automatic = true
        app.fastScanEnabled = true
        app.isProcessing = false
        app.lockedAfterCapture = false
        app.nextAutoAllowedAt = 0

        // 1. Blurry frame must be rejected by the stabilization gate even on repeated text hits or timeout
        let blurryFrame = createTestCGImage(width: 400, height: 200, grayValue: 128)
        app.handleAutomaticTextDetection(hasBond: true, frame: blurryFrame)
        app.handleAutomaticTextDetection(hasBond: true, frame: blurryFrame)
        app.stabilizationStartTime = Date().timeIntervalSince1970 - 5.0
        app.handleAutomaticTextDetection(hasBond: true, frame: blurryFrame)
        XCTAssertFalse(app.isProcessing, "Blurry text-detection frames must not bypass stabilization")

        // 2. Sharp frame still requires stabilization (does not trigger on first hit alone)
        let sharpFrame = createSharpBondPatternCGImage(width: 400, height: 200)
        app.stableFrames = 0
        app.stabilizationStartTime = 0
        app.huntHits = 0
        app.priorRect = nil

        app.handleAutomaticTextDetection(hasBond: true, frame: sharpFrame)
        XCTAssertEqual(app.stableFrames, 1)
        XCTAssertFalse(app.isProcessing, "First text-detection hit must stabilize before capturing")

        app.handleAutomaticTextDetection(hasBond: true, frame: sharpFrame)
        XCTAssertTrue(app.isProcessing, "Second stable sharp text-detection hit should trigger automatic capture")
    }

    func testObsoleteBracketCompletionDoesNotClearNewerTransactionProcessingState() throws {
        let app = BondScannerApp()
        app.cameraSessionGeneration = 1
        let oldTx = try XCTUnwrap(app.captureTransactionCoordinator.startTransaction(
            automatic: true,
            targetBiases: [0.0, -0.7, 0.7],
            deviceUniqueID: "cam-old",
            sessionGeneration: 1
        ))
        app.isProcessing = true

        // Simulate cancellation & camera failover to generation 2 with a new active capture
        app.cancelInFlightCaptures(reason: "camera failover")
        app.cameraSessionGeneration = 2
        let newTx = try XCTUnwrap(app.captureTransactionCoordinator.startTransaction(
            automatic: true,
            targetBiases: [0.0, -0.7, 0.7],
            deviceUniqueID: "cam-new",
            sessionGeneration: 2
        ))
        app.isProcessing = true

        // Late error completions from the old transaction must not clear the new transaction's state
        app.handleBracketCompletion(transaction: oldTx, result: .failure(ExposureBracketError.captureCancelled))
        XCTAssertTrue(app.isProcessing)
        XCTAssertTrue(app.captureTransactionCoordinator.isTransactionActive(id: newTx.id))

        app.handleBracketCompletion(transaction: oldTx, result: .failure(ExposureBracketError.exposureSettlingTimedOut))
        XCTAssertTrue(app.isProcessing)
        XCTAssertTrue(app.captureTransactionCoordinator.isTransactionActive(id: newTx.id))
    }
}
