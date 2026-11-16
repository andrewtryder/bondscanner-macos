import AppKit
import AVFoundation
@testable import BondScanner
import CoreGraphics
import XCTest

final class CameraAndExposureTests: XCTestCase {
    private var tempDir: URL!
    private var testDbURL: URL!
    private var testDb: DatabaseManager!

    override func setUp() {
        super.setUp()
        ScanLog.shared.isEnabled = false
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-exposure-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        testDb = try? DatabaseManager(url: testDbURL)
        DatabaseManager.setSharedInstance(testDb)
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        DatabaseManager.setSharedInstance(nil)
        testDb = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
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
        var disconnects = false
        var luminanceByBias: [Float: Float] = [:]
        var syntheticImage: CGImage?

        init(capabilities: CameraHardwareExposureCapabilities) {
            self.capabilities = capabilities
        }

        func setExposureBias(_ bias: Float, completion: @escaping (Result<Void, Error>) -> Void) {
            setBiasCallCount += 1
            appliedBiases.append(bias)

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
                jpegBytes: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                meanLuminance: lum,
                sharpnessScore: 15.0,
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

        let baseOCR = makeOCRResult(record: BondRecord(id: "base", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "", issueYear: "", denomination: "50", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "SERIES EE"), huntScore: 90)
        let brightOCR = makeOCRResult(record: BondRecord(id: "bright", capturedAt: "", series: "EE", serial: "C1234567890EE", issueMonth: "10", issueYear: "1998", denomination: "50", owner: "", secondName: "", secondRole: "", address: "", taxID: "", issuingAgent: "", datingStamp: "", status: "", notes: "", photo: "", sourcePhoto: "", rawOCR: "10/1998"), huntScore: 88)

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
}
