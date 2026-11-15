import AppKit
@testable import BondScanner
import CoreGraphics
import SQLite3
import XCTest

final class DataSafetyAndRetentionTests: XCTestCase {
    private var tempDir: URL!
    private var testPhotosDir: URL!
    private var testDbURL: URL!
    private var testDb: DatabaseManager!
    private var customLogURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("datasafety-tests-\(UUID().uuidString)", isDirectory: true)
        let testOutputRoot = tempDir.appendingPathComponent("output", isDirectory: true)
        testPhotosDir = testOutputRoot.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: testPhotosDir, withIntermediateDirectories: true)
        testDbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        customLogURL = tempDir.appendingPathComponent("test-debug.log")
        ScanLog.shared.setCustomLogURL(customLogURL)

        StorageConfiguration.shared.setCustomRoots(
            outputRoot: testOutputRoot,
            backupsRoot: tempDir.appendingPathComponent("backups", isDirectory: true)
        )

        testDb = try? DatabaseManager(url: testDbURL)
        DatabaseManager.setSharedInstance(testDb)

        ExportConfiguration.shared.setCustomDestinations(
            records: tempDir.appendingPathComponent("records.json"),
            csv: tempDir.appendingPathComponent("bonds.csv")
        )
    }

    override func tearDown() {
        ScanLog.shared.resetToDefaults()
        ExportConfiguration.shared.resetToDefaults()
        StorageConfiguration.shared.resetToDefaults()
        DatabaseManager.setSharedInstance(nil)
        testDb = nil

        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
        super.tearDown()
    }

    private func createDummyImageFile(named name: String) -> (url: URL, relPath: String) {
        let photoURL = testPhotosDir.appendingPathComponent(name)
        let data = Data("SYNTHETIC_JPEG_DATA_\(name)".utf8)
        try? data.write(to: photoURL)
        return (photoURL, "photos/\(name)")
    }

    private func makeRecord(
        id: String = UUID().uuidString,
        serial: String = "C1234567890EE",
        series: String = "EE",
        denom: String = "50",
        month: String = "05",
        year: String = "1995",
        status: String = "OK",
        photo: String? = nil,
        sourcePhoto: String? = nil,
        associatedPhotos: [String]? = nil,
        fieldPhoto: [String: String]? = nil,
        fieldCaptureId: [String: String]? = nil,
        notes: String = ""
    ) -> BondRecord {
        let p = photo ?? "photos/photo_\(id.prefix(6)).jpg"
        let sp = sourcePhoto ?? p
        return BondRecord(
            id: id,
            capturedAt: "2026-11-14T12:00:00Z",
            series: series,
            serial: serial,
            issueMonth: month,
            issueYear: year,
            denomination: denom,
            owner: "John Doe",
            secondName: "",
            secondRole: "",
            address: "123 Main St",
            taxID: "",
            issuingAgent: "First National Bank",
            datingStamp: "MAY 1995",
            status: status,
            notes: notes,
            photo: p,
            sourcePhoto: sp,
            rawOCR: "SAVINGS BOND \(serial)",
            fieldPhoto: fieldPhoto,
            fieldCaptureId: fieldCaptureId,
            associatedPhotos: associatedPhotos
        )
    }

    // MARK: - 1. Protect Production Data During XCTest

    func testProductionStorageIsProtectedInTestMode() {
        XCTAssertTrue(isProductionStorageProtected())
    }

    func testDirectProductionDatabaseInitForbiddenInTestMode() {
        let prodDB = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans/bonds.sqlite3")
        XCTAssertThrowsError(try DatabaseManager(url: prodDB)) { error in
            guard let dbError = error as? DatabaseError, case .permissionDenied = dbError else {
                XCTFail("Expected DatabaseError.permissionDenied, got: \(error)")
                return
            }
        }
    }

    func testExportToProductionForbiddenInTestMode() {
        let sample = makeRecord(serial: "C123456789EE")
        let prodCSV = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans/bonds.csv")
        let prodJSON = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans/records.json")

        XCTAssertThrowsError(try exportCSV([sample], to: prodCSV)) { error in
            guard let storageError = error as? StorageError, case .productionAccessForbidden = storageError else {
                XCTFail("Expected StorageError.productionAccessForbidden, got: \(error)")
                return
            }
        }

        XCTAssertThrowsError(try exportJSON([sample], to: prodJSON)) { error in
            guard let storageError = error as? StorageError, case .productionAccessForbidden = storageError else {
                XCTFail("Expected StorageError.productionAccessForbidden, got: \(error)")
                return
            }
        }
    }

    func testScanLogGuardedInTestMode() {
        let prodLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans/scan-debug.log")
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: prodLog.path)[.size] as? UInt64) ?? 0
        let mtimeBefore = try? FileManager.default.attributesOfItem(atPath: prodLog.path)[.modificationDate] as? Date

        ScanLog.shared.resetToDefaults()
        StorageConfiguration.shared.resetToDefaults()
        ScanLog.shared.write("test log entry during unit test that must not write to production")

        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: prodLog.path)[.size] as? UInt64) ?? 0
        let mtimeAfter = try? FileManager.default.attributesOfItem(atPath: prodLog.path)[.modificationDate] as? Date

        XCTAssertEqual(sizeBefore, sizeAfter, "Production log must not grow in test mode")
        XCTAssertEqual(mtimeBefore, mtimeAfter, "Production log modification date must not change in test mode")

        // Restore custom roots
        StorageConfiguration.shared.setCustomRoots(
            outputRoot: tempDir.appendingPathComponent("output", isDirectory: true),
            backupsRoot: tempDir.appendingPathComponent("backups", isDirectory: true)
        )
        ScanLog.shared.setCustomLogURL(customLogURL)
        ScanLog.shared.write("test custom entry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: customLogURL.path))
    }

    func testApplicationLifecycleDoesNotTouchProduction() {
        let prodDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true)
        let entriesBefore = (try? FileManager.default.contentsOfDirectory(atPath: prodDir.path)) ?? []
        let prodDB = prodDir.appendingPathComponent("bonds.sqlite3")
        let dbMtimeBefore = try? FileManager.default.attributesOfItem(atPath: prodDB.path)[.modificationDate] as? Date

        let app = BondScannerApp()
        let didFinishNotification = Notification(name: NSApplication.didFinishLaunchingNotification)
        let willTerminateNotification = Notification(name: NSApplication.willTerminateNotification)

        app.applicationDidFinishLaunching(didFinishNotification)
        app.applicationWillTerminate(willTerminateNotification)

        let entriesAfter = (try? FileManager.default.contentsOfDirectory(atPath: prodDir.path)) ?? []
        let dbMtimeAfter = try? FileManager.default.attributesOfItem(atPath: prodDB.path)[.modificationDate] as? Date

        XCTAssertEqual(entriesBefore.sorted(), entriesAfter.sorted(), "No new files must be created in ~/BondScans during test lifecycle")
        XCTAssertEqual(dbMtimeBefore, dbMtimeAfter, "Production database must not be modified during test lifecycle")
    }

    // MARK: - 2. Photograph Ownership and Retention Tracking

    func testExactDuplicatePreservesOriginalPhotographsInAssociatedPhotos() throws {
        let (_, relPhoto1) = createDummyImageFile(named: "capture1.jpg")
        let (_, relPhoto2) = createDummyImageFile(named: "capture2.jpg")

        var original = makeRecord(
            id: "rec-1",
            serial: "C123456789EE",
            photo: relPhoto1,
            sourcePhoto: relPhoto1
        )
        try testDb.upsertRecord(original)

        let duplicate = makeRecord(
            id: "rec-2",
            serial: "C123456789EE",
            photo: relPhoto2,
            sourcePhoto: relPhoto2
        )

        let updatedFields = mergeBondRecord(
            from: duplicate,
            into: &original,
            contributingPhoto: relPhoto2,
            contributingSource: relPhoto2,
            captureId: "rec-2"
        )
        _ = updatedFields

        XCTAssertEqual(original.photo, relPhoto1)
        XCTAssertTrue(original.associatedPhotos?.contains(relPhoto2) ?? false, "Associated photos must contain duplicate photo")

        try testDb.upsertRecord(original)

        let fetched = try testDb.fetchRecord(id: "rec-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.associatedPhotos?.count, 1)
        XCTAssertEqual(fetched?.associatedPhotos?.first, relPhoto2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testPhotosDir.appendingPathComponent("capture1.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: testPhotosDir.appendingPathComponent("capture2.jpg").path))
    }

    func testDuplicateContributingNewFieldsPreservesProvenance() throws {
        let (_, relPhoto1) = createDummyImageFile(named: "capture1.jpg")
        let (_, relPhoto2) = createDummyImageFile(named: "capture2.jpg")

        var original = makeRecord(
            id: "rec-1",
            serial: "C123456789EE",
            month: "",
            year: "",
            photo: relPhoto1,
            sourcePhoto: relPhoto1
        )

        let duplicate = makeRecord(
            id: "rec-2",
            serial: "C123456789EE",
            month: "05",
            year: "1990",
            photo: relPhoto2,
            sourcePhoto: relPhoto2,
            fieldPhoto: ["issueMonth": relPhoto2, "issueYear": relPhoto2],
            fieldCaptureId: ["issueMonth": "rec-2", "issueYear": "rec-2"]
        )

        _ = mergeBondRecord(
            from: duplicate,
            into: &original,
            contributingPhoto: relPhoto2,
            contributingSource: relPhoto2,
            captureId: "rec-2"
        )

        XCTAssertEqual(original.issueMonth, "05")
        XCTAssertEqual(original.issueYear, "1990")
        XCTAssertEqual(original.fieldPhoto?["issueMonth"], relPhoto2, "Field photo provenance must point to capture2")
        XCTAssertEqual(original.fieldCaptureId?["issueMonth"], "rec-2")
        XCTAssertTrue(original.associatedPhotos?.contains(relPhoto2) ?? false)

        try testDb.upsertRecord(original)
        let loaded = try testDb.fetchRecord(id: "rec-1")
        XCTAssertEqual(loaded?.fieldPhoto?["issueMonth"], relPhoto2)
        XCTAssertEqual(loaded?.associatedPhotos, [relPhoto2])
    }

    func testManualDuplicateMergePreservesAllPhotographs() throws {
        let (_, relPhoto1) = createDummyImageFile(named: "target.jpg")
        let (_, relPhoto2) = createDummyImageFile(named: "dup.jpg")
        let (_, relPhoto3) = createDummyImageFile(named: "dup-assoc.jpg")

        let target = makeRecord(
            id: "target-1",
            serial: "C123456789EE",
            photo: relPhoto1,
            sourcePhoto: relPhoto1
        )

        let duplicate = makeRecord(
            id: "dup-1",
            serial: "C123456789EE",
            photo: relPhoto2,
            sourcePhoto: relPhoto2,
            associatedPhotos: [relPhoto3],
            fieldPhoto: ["serial": relPhoto2]
        )

        try testDb.upsertRecord(target)
        try testDb.upsertRecord(duplicate)

        let coordinator = ReviewCoordinator(records: [target, duplicate])
        let mergedTarget = try coordinator.confirmSameBond(primary: target, duplicate: duplicate)

        XCTAssertNil(try testDb.fetchRecord(id: "dup-1"))
        XCTAssertEqual(mergedTarget.id, "target-1")
        XCTAssertTrue(mergedTarget.associatedPhotos?.contains(relPhoto2) ?? false)
        XCTAssertTrue(mergedTarget.associatedPhotos?.contains(relPhoto3) ?? false)

        let reloaded = try testDb.fetchRecord(id: "target-1")
        XCTAssertTrue(reloaded?.associatedPhotos?.contains(relPhoto2) ?? false)
        XCTAssertTrue(reloaded?.associatedPhotos?.contains(relPhoto3) ?? false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testPhotosDir.appendingPathComponent("target.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: testPhotosDir.appendingPathComponent("dup.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: testPhotosDir.appendingPathComponent("dup-assoc.jpg").path))
    }

    func testSafelyTrashPhotographsDoesNotTrashSharedPhotographs() throws {
        let (photoURL, relPath) = createDummyImageFile(named: "shared.jpg")

        let recA = makeRecord(
            id: "rec-A",
            serial: "A111111111EE",
            photo: relPath
        )
        let recB = makeRecord(
            id: "rec-B",
            serial: "B222222222EE",
            associatedPhotos: [relPath]
        )

        try testDb.upsertRecord(recA)
        try testDb.upsertRecord(recB)

        // Attempting to trash recA's photo should NOT trash it because recB references it
        _ = safelyTrashPhotographs(for: recA, existingRecords: [recA, recB])
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path), "Shared photo must NOT be trashed while recB references it")

        // Now delete recB from DB as well
        try testDb.deleteRecord(id: "rec-B")
        // Now photo is unreferenced anywhere outside recA
        _ = safelyTrashPhotographs(for: recA, existingRecords: [recA])
        XCTAssertFalse(FileManager.default.fileExists(atPath: photoURL.path), "Unreferenced photo should be trashed")
    }

    func testLegacyJSONMigrationExtractsAssociatedPhotosFromNotes() throws {
        let (_, relPhoto) = createDummyImageFile(named: "migrated-dup.jpg")
        let legacyRecord = makeRecord(
            id: "legacy-1",
            serial: "C123456789EE",
            notes: "Duplicate scan photo preserved at \(relPhoto)"
        )

        let legacyJSONURL = tempDir.appendingPathComponent("legacy.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode([legacyRecord])
        try data.write(to: legacyJSONURL)

        let freshDbURL = tempDir.appendingPathComponent("fresh.sqlite3")
        let freshDb = try DatabaseManager(url: freshDbURL)

        let migrated = try freshDb.migrateFromJSONIfNeeded(jsonURL: legacyJSONURL)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.associatedPhotos, [relPhoto], "Migration must parse duplicate photo notes into associatedPhotos")
    }

    // MARK: - 3. Database and Photograph Complete Collection Recovery

    func testCompleteCollectionBackupAndRestore() throws {
        let (photo1URL, relPhoto1) = createDummyImageFile(named: "photo1.jpg")
        let (photo2URL, relPhoto2) = createDummyImageFile(named: "photo2.jpg")

        let rec1 = makeRecord(id: "b-1", serial: "A123456789EE", photo: relPhoto1)
        let rec2 = makeRecord(id: "b-2", serial: "B987654321EE", photo: relPhoto2, associatedPhotos: [relPhoto1])

        try testDb.upsertRecord(rec1)
        try testDb.upsertRecord(rec2)

        let backupDir = tempDir.appendingPathComponent("collection_backup", isDirectory: true)
        try testDb.backupCollection(to: backupDir, photosSourceDir: testPhotosDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.appendingPathComponent("backup_manifest.json").path))

        // Verify source collection was not modified
        XCTAssertEqual(try testDb.loadAllRecords().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo2URL.path))

        // Restore into a fresh destination directory
        let restoreDestDir = tempDir.appendingPathComponent("restored_dest", isDirectory: true)
        let restoreDBURL = restoreDestDir.appendingPathComponent("bonds.sqlite3")
        let restorePhotosDir = restoreDestDir.appendingPathComponent("photos", isDirectory: true)

        // 1. Without explicit authorization -> throws restoreFailed
        XCTAssertThrowsError(try testDb.restoreCollection(from: backupDir, destinationDBURL: restoreDBURL, destinationPhotosDir: restorePhotosDir, authorized: false)) { error in
            guard let dbError = error as? DatabaseError, case .restoreFailed = dbError else {
                XCTFail("Expected DatabaseError.restoreFailed, got: \(error)")
                return
            }
        }

        // 2. With authorization -> succeeds
        try testDb.restoreCollection(from: backupDir, destinationDBURL: restoreDBURL, destinationPhotosDir: restorePhotosDir, authorized: true)

        let restoredDb = try DatabaseManager(url: restoreDBURL)
        let restoredRecords = try restoredDb.loadAllRecords()
        XCTAssertEqual(restoredRecords.count, 2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: restorePhotosDir.appendingPathComponent("photo1.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restorePhotosDir.appendingPathComponent("photo2.jpg").path))
    }

    func testRestoreFailsSafelyAndPreservesExistingOnCorruption() throws {
        let (photoURL, relPhoto) = createDummyImageFile(named: "existing.jpg")
        let existingRec = makeRecord(id: "exist-1", serial: "E123456789EE", photo: relPhoto)
        try testDb.upsertRecord(existingRec)

        // Create an invalid/corrupted backup directory
        let badBackupDir = tempDir.appendingPathComponent("corrupted_backup", isDirectory: true)
        try FileManager.default.createDirectory(at: badBackupDir, withIntermediateDirectories: true)
        try Data("NOT_A_VALID_JSON".utf8).write(to: badBackupDir.appendingPathComponent("backup_manifest.json"))

        // Attempt restore into active collection
        XCTAssertThrowsError(try testDb.restoreCollection(from: badBackupDir, destinationDBURL: testDbURL, destinationPhotosDir: testPhotosDir, authorized: true))

        // Verify existing collection is completely preserved intact
        let activeRecords = try testDb.loadAllRecords()
        XCTAssertEqual(activeRecords.count, 1)
        XCTAssertEqual(activeRecords.first?.id, "exist-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
    }

    // MARK: - 4. Issue-Date OCR Multi-line and Dating Stamp Logic

    func testExtractIssueDateReadingWithAdjacentTwoDigitMonthAndYear() {
        let lines = [
            OCRLine(text: "04", confidence: 0.95, box: CGRect(x: 0.72, y: 0.70, width: 0.05, height: 0.03)),
            OCRLine(text: "1986", confidence: 0.95, box: CGRect(x: 0.71, y: 0.67, width: 0.07, height: 0.03)),
        ]

        let reading = extractIssueDateReading(lines, series: "EE")
        XCTAssertEqual(reading.value, "04/1986", "Must recognize 2-digit month on adjacent lines with year")
    }

    func testUSFormatBankDatingStampRecognition() {
        let stampLines = [
            OCRLine(text: "NORSTAR BANK OF UPSTATE NY", confidence: 0.9, box: CGRect(x: 0.6, y: 0.48, width: 0.3, height: 0.03)),
            OCRLine(text: "APR 14, 1986", confidence: 0.95, box: CGRect(x: 0.65, y: 0.45, width: 0.2, height: 0.03)),
        ]

        let stamp = extractDatingStamp(stampLines, series: "EE")
        XCTAssertNotNil(stamp, "Must recognize US format MMM DD, YYYY bank dating stamp")
        XCTAssertEqual(stamp?.year, "1986")
        XCTAssertEqual(stamp?.month, "04")
        XCTAssertEqual(stamp?.day, 14)
        XCTAssertTrue(stamp?.raw.contains("APR") ?? false)
    }
}
