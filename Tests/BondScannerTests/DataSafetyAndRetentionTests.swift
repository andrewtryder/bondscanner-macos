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
        let fakeProdRoot = tempDir.appendingPathComponent("fake_prod", isDirectory: true)
        StorageConfiguration.shared.setCustomProductionRoot(fakeProdRoot)
        XCTAssertTrue(isProductionStorageProtected(destination: fakeProdRoot))
        XCTAssertTrue(isProductionStorageProtected(destination: fakeProdRoot.appendingPathComponent("bonds.sqlite3")))
    }

    func testDirectProductionDatabaseInitForbiddenInTestMode() {
        let fakeProdRoot = tempDir.appendingPathComponent("fake_prod_db", isDirectory: true)
        StorageConfiguration.shared.setCustomProductionRoot(fakeProdRoot)
        let prodDB = fakeProdRoot.appendingPathComponent("bonds.sqlite3")
        XCTAssertThrowsError(try DatabaseManager(url: prodDB)) { error in
            guard let dbError = error as? DatabaseError, case .permissionDenied = dbError else {
                XCTFail("Expected DatabaseError.permissionDenied, got: \(error)")
                return
            }
        }
    }

    func testExportToProductionForbiddenInTestMode() {
        let sample = makeRecord(serial: "C123456789EE")
        let fakeProdRoot = tempDir.appendingPathComponent("fake_prod_export", isDirectory: true)
        StorageConfiguration.shared.setCustomProductionRoot(fakeProdRoot)
        let prodCSV = fakeProdRoot.appendingPathComponent("bonds.csv")
        let prodJSON = fakeProdRoot.appendingPathComponent("records.json")

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
        let fakeProdRoot = tempDir.appendingPathComponent("fake_prod_log", isDirectory: true)
        let fakeProdLog = fakeProdRoot.appendingPathComponent("scan-debug.log")
        StorageConfiguration.shared.setCustomProductionRoot(fakeProdRoot)
        ScanLog.shared.resetToDefaults()

        ScanLog.shared.write("test log entry during unit test that must not write to production")

        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeProdLog.path), "ScanLog in test mode must not write to configured production log")

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
        let fakeProdRoot = tempDir.appendingPathComponent("fake_prod_lifecycle", isDirectory: true)
        StorageConfiguration.shared.setCustomProductionRoot(fakeProdRoot)

        let app = BondScannerApp()
        let didFinishNotification = Notification(name: NSApplication.didFinishLaunchingNotification)
        let willTerminateNotification = Notification(name: NSApplication.willTerminateNotification)

        app.applicationDidFinishLaunching(didFinishNotification)
        app.applicationWillTerminate(willTerminateNotification)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeProdRoot.path), "No production directory or files must be created during test lifecycle")
    }

    func testSharedDatabaseFallsBackToInMemoryInTestMode() throws {
        DatabaseManager.setSharedInstance(nil)
        let shared = DatabaseManager.shared
        XCTAssertTrue(shared.isInMemory, "DatabaseManager.shared must fall back to in-memory mode when test mode is active")
        XCTAssertEqual(shared.currentURL.absoluteString, "file::memory:")

        // Verify that no file named ':memory:' was created on disk in the working directory
        let cwdMemory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(":memory:")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwdMemory.path), "Must not create a literal ':memory:' file on disk")

        let rec = makeRecord(id: "mem-1", serial: "M123456789EE")
        try shared.upsertRecord(rec)
        let fetched = try shared.fetchRecord(id: "mem-1")
        XCTAssertEqual(fetched?.serial, "M123456789EE")

        DatabaseManager.setSharedInstance(testDb)
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
        _ = try? safelyTrashPhotographs(for: recA, existingRecords: [recA, recB], database: testDb, root: StorageConfiguration.shared.outputRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path), "Shared photo must NOT be trashed while recB references it")

        // Now delete recB from DB as well
        try testDb.deleteRecord(id: "rec-B")
        // Now photo is unreferenced anywhere outside recA
        _ = try? safelyTrashPhotographs(for: recA, existingRecords: [recA], database: testDb, root: StorageConfiguration.shared.outputRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photoURL.path), "Unreferenced photo should be trashed")
    }

    func testSafelyTrashPhotographsAuthoritativeDatabaseCheck() throws {
        let (photoURL, relPhoto) = createDummyImageFile(named: "authoritative.jpg")
        let existing = makeRecord(id: "rec-auth", serial: "AUTH12345EE", photo: relPhoto)
        try testDb.upsertRecord(existing)

        let candidateToDelete = makeRecord(id: "other-rec", photo: relPhoto)
        // Pass empty in-memory array, but pass database
        let trashed = try safelyTrashPhotographs(for: candidateToDelete, existingRecords: [], database: testDb, root: StorageConfiguration.shared.outputRoot)

        XCTAssertTrue(trashed.isEmpty, "Photograph must not be trashed when referenced in the database, even if existingRecords array is empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
    }

    func testSafelyTrashPhotographsRejectsPathTraversalAndProduction() throws {
        let fakeProdRoot = tempDir.appendingPathComponent("fake_prod_trash", isDirectory: true)
        StorageConfiguration.shared.setCustomProductionRoot(fakeProdRoot)

        let record = makeRecord(id: "traversal", photo: "../../secret.jpg")
        let trashed = try safelyTrashPhotographs(for: record, existingRecords: [], database: testDb, root: StorageConfiguration.shared.outputRoot)
        XCTAssertTrue(trashed.isEmpty, "Path traversal photo must not be trashed")

        XCTAssertThrowsError(try safelyTrashPhotographs(for: record, existingRecords: [], database: testDb, root: fakeProdRoot)) { error in
            guard let storageError = error as? StorageError, case .productionAccessForbidden = storageError else {
                XCTFail("Expected StorageError.productionAccessForbidden, got: \(error)")
                return
            }
        }
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

    func testBackupFailurePreservesPreexistingFilesInDestination() throws {
        let callerDestDir = tempDir.appendingPathComponent("caller_backup_dest", isDirectory: true)
        try FileManager.default.createDirectory(at: callerDestDir, withIntermediateDirectories: true)
        let canaryFile = callerDestDir.appendingPathComponent("important_user_file.txt")
        try Data("DO_NOT_DELETE".utf8).write(to: canaryFile)

        // Create a record that references a missing photo so backup fails
        let missingRecord = makeRecord(id: "rec-missing", serial: "X123456789EE", photo: "photos/non_existent.jpg")
        try testDb.upsertRecord(missingRecord)

        XCTAssertThrowsError(try testDb.backupCollection(to: callerDestDir, photosSourceDir: testPhotosDir))

        // Verify the caller directory and canary file were NOT deleted on failure
        XCTAssertTrue(FileManager.default.fileExists(atPath: callerDestDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canaryFile.path))
        let content = try? String(contentsOf: canaryFile, encoding: .utf8)
        XCTAssertEqual(content, "DO_NOT_DELETE")
    }

    func testBackupRefusesCollectionRootAsDestination() throws {
        let collectionRoot = StorageConfiguration.shared.outputRoot
        XCTAssertThrowsError(try testDb.backupCollection(to: collectionRoot, photosSourceDir: testPhotosDir)) { error in
            guard let dbError = error as? DatabaseError, case .permissionDenied = dbError else {
                XCTFail("Expected DatabaseError.permissionDenied, got: \(error)")
                return
            }
        }
    }

    func testRestoreRollbackOnPhotoCopyFailure() throws {
        let (originalPhotoURL, relOriginalPhoto) = createDummyImageFile(named: "orig_photo.jpg")
        let origRec = makeRecord(id: "orig-1", serial: "ORIG123456EE", photo: relOriginalPhoto)
        try testDb.upsertRecord(origRec)

        // Create a valid backup in backupDir with a different record
        let (_, relBackupPhoto) = createDummyImageFile(named: "backup_photo.jpg")
        let backupRec = makeRecord(id: "backup-1", serial: "BACKUP98765EE", photo: relBackupPhoto)
        let tempBackupDBURL = tempDir.appendingPathComponent("temp_for_backup.sqlite3")
        let tempBackupDB = try DatabaseManager(url: tempBackupDBURL)
        try tempBackupDB.upsertRecord(backupRec)

        let validBackupDir = tempDir.appendingPathComponent("valid_backup_source", isDirectory: true)
        try tempBackupDB.backupCollection(to: validBackupDir, photosSourceDir: testPhotosDir)

        // Inject failure after database replacement but before photo copy finishes
        XCTAssertThrowsError(
            try testDb.restoreCollection(
                from: validBackupDir,
                destinationDBURL: testDbURL,
                destinationPhotosDir: testPhotosDir,
                authorized: true,
                _injectedFailureAfterDB: true
            )
        ) { error in
            guard let dbError = error as? DatabaseError, case .restoreFailed = dbError else {
                XCTFail("Expected DatabaseError.restoreFailed, got: \(error)")
                return
            }
        }

        // Verify active database rolled back to original records
        let recordsAfterRollback = try testDb.loadAllRecords()
        XCTAssertEqual(recordsAfterRollback.count, 1)
        XCTAssertEqual(recordsAfterRollback.first?.id, "orig-1")
        XCTAssertEqual(recordsAfterRollback.first?.serial, "ORIG123456EE")

        // Verify original photo remains intact
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPhotoURL.path))
    }

    func testRestoreFailsWhenManifestRecordCountMismatchesDatabase() throws {
        let (_, relPhoto) = createDummyImageFile(named: "test_mismatch.jpg")
        let rec = makeRecord(id: "rec-mm", serial: "MM12345678EE", photo: relPhoto)
        try testDb.upsertRecord(rec)

        let backupDir = tempDir.appendingPathComponent("mismatch_manifest_backup", isDirectory: true)
        try testDb.backupCollection(to: backupDir, photosSourceDir: testPhotosDir)

        // Tamper manifest with wrong record count
        let manifestURL = backupDir.appendingPathComponent("backup_manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CollectionBackupManifest.self, from: manifestData)
        let tampered = CollectionBackupManifest(
            timestamp: manifest.timestamp,
            schemaVersion: manifest.schemaVersion,
            recordCount: manifest.recordCount + 10,
            databaseFileName: manifest.databaseFileName,
            photoFiles: manifest.photoFiles
        )
        try JSONEncoder().encode(tampered).write(to: manifestURL)

        let restoreDBURL = tempDir.appendingPathComponent("tampered_restore.sqlite3")
        let restorePhotosDir = tempDir.appendingPathComponent("tampered_photos", isDirectory: true)

        XCTAssertThrowsError(try testDb.restoreCollection(from: backupDir, destinationDBURL: restoreDBURL, destinationPhotosDir: restorePhotosDir, authorized: true)) { error in
            guard let dbError = error as? DatabaseError, case .restoreFailed = dbError else {
                XCTFail("Expected DatabaseError.restoreFailed, got: \(error)")
                return
            }
        }
    }

    func testRestoreFailsOnMalformedRecordJSON() throws {
        let badDBURL = tempDir.appendingPathComponent("malformed_json.sqlite3")
        let badDB = try DatabaseManager(url: badDBURL)
        let sensitiveJSON = "{ \"id\": \"bad-1\", \"owner\": \"CONFIDENTIAL_NAME\", \"serial\": \"SECRET_SERIAL_999\" INVALID_SYNTAX"
        let escaped = sensitiveJSON.replacingOccurrences(of: "'", with: "''")
        try badDB.execute("INSERT INTO bonds (id, sort_order, captured_at, updated_at, record_json) VALUES ('bad-1', 1, 'now', 'now', '\(escaped)');")

        let badBackupDir = tempDir.appendingPathComponent("bad_backup_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: badBackupDir, withIntermediateDirectories: true)
        try badDB.backupDatabase(to: badBackupDir.appendingPathComponent("bonds.sqlite3"))

        let manifest = CollectionBackupManifest(
            timestamp: "2026-11-15T00:00:00Z",
            schemaVersion: 1,
            recordCount: 1,
            databaseFileName: "bonds.sqlite3",
            photoFiles: []
        )
        try JSONEncoder().encode(manifest).write(to: badBackupDir.appendingPathComponent("backup_manifest.json"))

        let restoreDBURL = tempDir.appendingPathComponent("restore_fail.sqlite3")
        let restorePhotosDir = tempDir.appendingPathComponent("photos_fail", isDirectory: true)

        XCTAssertThrowsError(try testDb.restoreCollection(from: badBackupDir, destinationDBURL: restoreDBURL, destinationPhotosDir: restorePhotosDir, authorized: true)) { error in
            guard let dbError = error as? DatabaseError, case let .restoreFailed(msg) = dbError else {
                XCTFail("Expected DatabaseError.restoreFailed, got: \(error)")
                return
            }
            XCTAssertTrue(msg.contains("index 1"), "Error message should report record index: \(msg)")
            XCTAssertFalse(msg.contains("CONFIDENTIAL_NAME"), "Error message MUST NOT leak private owner data: \(msg)")
            XCTAssertFalse(msg.contains("SECRET_SERIAL_999"), "Error message MUST NOT leak serial number: \(msg)")
        }
    }

    func testBackupPublicationFailurePreservesExistingValidBackup() throws {
        let backupDestDir = tempDir.appendingPathComponent("publication_test_dest", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDestDir, withIntermediateDirectories: true)

        // 1. Create a valid original backup generation at backupDestDir
        let (_, relPhoto1) = createDummyImageFile(named: "gen1_photo.jpg")
        let rec1 = makeRecord(id: "rec-gen1", serial: "GEN1-11111EE", photo: relPhoto1)
        let db1URL = tempDir.appendingPathComponent("db_gen1.sqlite3")
        let db1 = try DatabaseManager(url: db1URL)
        try db1.upsertRecord(rec1)
        try db1.backupCollection(to: backupDestDir, photosSourceDir: testPhotosDir)

        // Verify generation 1 backup exists and is valid
        let publishedManifestURL = backupDestDir.appendingPathComponent("backup_manifest.json")
        let publishedDBURL = backupDestDir.appendingPathComponent("bonds.sqlite3")
        let publishedPhoto1URL = backupDestDir.appendingPathComponent(relPhoto1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedManifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedDBURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedPhoto1URL.path))
        let gen1Records = try DatabaseManager.loadRecordsFromSnapshot(at: publishedDBURL)
        XCTAssertEqual(gen1Records.count, 1)
        XCTAssertEqual(gen1Records.first?.id, "rec-gen1")

        // 2. Attempt a second backup from a different collection with injected failure during publication
        let (_, relPhoto2) = createDummyImageFile(named: "gen2_photo.jpg")
        let rec2 = makeRecord(id: "rec-gen2", serial: "GEN2-22222EE", photo: relPhoto2)
        let db2URL = tempDir.appendingPathComponent("db_gen2.sqlite3")
        let db2 = try DatabaseManager(url: db2URL)
        try db2.upsertRecord(rec2)

        XCTAssertThrowsError(
            try db2.backupCollection(
                to: backupDestDir,
                photosSourceDir: testPhotosDir,
                _injectedFailureDuringPublication: true
            )
        )

        // 3. Verify generation 1 backup was preserved completely and not corrupted or deleted
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedManifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedDBURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publishedPhoto1URL.path))
        // Verify gen2 photo was rolled back / not present
        let publishedPhoto2URL = backupDestDir.appendingPathComponent(relPhoto2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publishedPhoto2URL.path))

        // Verify published DB in destination still contains gen1 records
        let restoredGen1Records = try DatabaseManager.loadRecordsFromSnapshot(at: publishedDBURL)
        XCTAssertEqual(restoredGen1Records.count, 1)
        XCTAssertEqual(restoredGen1Records.first?.id, "rec-gen1")
        XCTAssertEqual(restoredGen1Records.first?.serial, "GEN1-11111EE")
    }

    func testSafelyTrashPhotographsFailsClosedOnDatabaseError() throws {
        let (photoURL, relPhoto) = createDummyImageFile(named: "fail_closed_photo.jpg")
        let rec = makeRecord(id: "rec-fail-closed", photo: relPhoto)
        try testDb.upsertRecord(rec)

        // Close active database handle to simulate SQLite error/unavailability
        let brokenDBURL = tempDir.appendingPathComponent("broken.sqlite3")
        let brokenDB = try DatabaseManager(url: brokenDBURL)
        brokenDB.close()

        let candidate = makeRecord(id: "rec-del", photo: relPhoto)
        XCTAssertThrowsError(
            try safelyTrashPhotographs(
                for: candidate,
                existingRecords: [],
                database: brokenDB,
                root: StorageConfiguration.shared.outputRoot
            )
        )

        // Verify photo was NOT deleted (failed closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path), "Photograph must not be deleted when database check fails")
    }

    func testSafelyTrashPhotographsRejectsSiblingDirectory() throws {
        let fakeRoot = tempDir.appendingPathComponent("fake_storage_root", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeRoot, withIntermediateDirectories: true)

        let siblingDir = tempDir.appendingPathComponent("fake_storage_root_sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        let siblingPhoto = siblingDir.appendingPathComponent("secret.jpg")
        try Data("SIBLING".utf8).write(to: siblingPhoto)

        let record = makeRecord(id: "rec-sibling", photo: "../fake_storage_root_sibling/secret.jpg")
        let trashed = try safelyTrashPhotographs(for: record, existingRecords: [], database: testDb, root: fakeRoot)
        XCTAssertTrue(trashed.isEmpty, "Sibling directory photo must not be trashed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingPhoto.path))
    }

    func testRestorePreStagingFailureReopensActiveDatabase() throws {
        let (origPhotoURL, relOrigPhoto) = createDummyImageFile(named: "orig_prestaging.jpg")
        let origRec = makeRecord(id: "rec-orig-pre", serial: "ORIG-PRE-111", photo: relOrigPhoto)
        try testDb.upsertRecord(origRec)

        // Create a valid backup
        let backupDir = tempDir.appendingPathComponent("valid_backup_for_prestaging", isDirectory: true)
        try testDb.backupCollection(to: backupDir, photosSourceDir: testPhotosDir)

        // Restore with injected failure right after closing handle during pre-staging
        XCTAssertThrowsError(
            try testDb.restoreCollection(
                from: backupDir,
                destinationDBURL: testDbURL,
                destinationPhotosDir: testPhotosDir,
                authorized: true,
                _injectedPreRestoreFailure: true
            )
        )

        // Verify active database connection was reopened and is still fully functional
        let loaded = try testDb.loadAllRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "rec-orig-pre")
        XCTAssertTrue(FileManager.default.fileExists(atPath: origPhotoURL.path))
    }

    func testStrictPathValidationRejectsTraversalAndSymlinkEscapes() throws {
        let baseDir = tempDir.appendingPathComponent("path_sec_base", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Absolute path rejected
        XCTAssertThrowsError(try PathSecurity.validateSafeRelativePath("/etc/passwd", within: baseDir))

        // Traversal rejected
        XCTAssertThrowsError(try PathSecurity.validateSafeRelativePath("../outside.txt", within: baseDir))
        XCTAssertThrowsError(try PathSecurity.validateSafeRelativePath("photos/../../outside.txt", within: baseDir))

        // Symlink escape rejected
        let outsideDir = tempDir.appendingPathComponent("outside_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let symlinkInBase = baseDir.appendingPathComponent("symlink_escape")
        try FileManager.default.createSymbolicLink(at: symlinkInBase, withDestinationURL: outsideDir)

        XCTAssertThrowsError(try PathSecurity.validateSafeRelativePath("symlink_escape/secret.txt", within: baseDir))

        // Invalid filenames rejected
        XCTAssertThrowsError(try PathSecurity.validateSafeFilename("../evil.sqlite3"))
        XCTAssertThrowsError(try PathSecurity.validateSafeFilename("sub/evil.sqlite3"))
        XCTAssertThrowsError(try PathSecurity.validateSafeFilename("/evil.sqlite3"))
        XCTAssertEqual(try PathSecurity.validateSafeFilename("bonds.sqlite3"), "bonds.sqlite3")
    }

    func testBackupRejectsPathTraversalInRecordPhotos() throws {
        let traversalRec = makeRecord(id: "rec-trav", serial: "TRAV12345EE", photo: "../../secret.jpg")
        try testDb.upsertRecord(traversalRec)

        let backupDir = tempDir.appendingPathComponent("trav_backup_dest", isDirectory: true)
        XCTAssertThrowsError(try testDb.backupCollection(to: backupDir, photosSourceDir: testPhotosDir))
    }

    func testRestoreRejectsManifestWithTraversalOrEscape() throws {
        let validBackupDir = tempDir.appendingPathComponent("valid_backup_sec", isDirectory: true)
        let (_, relPhoto) = createDummyImageFile(named: "sec_test.jpg")
        let rec = makeRecord(id: "rec-sec", serial: "SEC123456EE", photo: relPhoto)
        let secDBURL = tempDir.appendingPathComponent("sec_db.sqlite3")
        let secDB = try DatabaseManager(url: secDBURL)
        try secDB.upsertRecord(rec)
        try secDB.backupCollection(to: validBackupDir, photosSourceDir: testPhotosDir)

        // Tamper manifest databaseFileName with path traversal
        let manifestURL = validBackupDir.appendingPathComponent("backup_manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(CollectionBackupManifest.self, from: manifestData)
        manifest = CollectionBackupManifest(
            timestamp: manifest.timestamp,
            schemaVersion: manifest.schemaVersion,
            recordCount: manifest.recordCount,
            databaseFileName: "../escaped.sqlite3",
            photoFiles: manifest.photoFiles
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let restoreDBURL = tempDir.appendingPathComponent("sec_restore.sqlite3")
        let restorePhotosDir = tempDir.appendingPathComponent("sec_photos", isDirectory: true)

        XCTAssertThrowsError(
            try testDb.restoreCollection(
                from: validBackupDir,
                destinationDBURL: restoreDBURL,
                destinationPhotosDir: restorePhotosDir,
                authorized: true
            )
        )
    }

    func testBackupDerivesInventoryDirectlyFromSnapshot() throws {
        let (photoURL, relPhoto) = createDummyImageFile(named: "snapshot_derive.jpg")
        let rec = makeRecord(id: "rec-snap", serial: "SNAP12345EE", photo: relPhoto)
        try testDb.upsertRecord(rec)

        let backupDir = tempDir.appendingPathComponent("snapshot_derive_backup", isDirectory: true)
        try testDb.backupCollection(to: backupDir, photosSourceDir: testPhotosDir)

        let manifestURL = backupDir.appendingPathComponent("backup_manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CollectionBackupManifest.self, from: manifestData)

        let backupDBURL = backupDir.appendingPathComponent("bonds.sqlite3")
        let snapshotRecords = try DatabaseManager.loadRecordsFromSnapshot(at: backupDBURL)

        XCTAssertEqual(manifest.recordCount, snapshotRecords.count)
        XCTAssertEqual(manifest.photoFiles, [relPhoto])
        XCTAssertEqual(snapshotRecords.first?.id, "rec-snap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
    }

    func testRestoreSafetyStagingFailureDoesNotDeleteOriginalDatabase() throws {
        let (origPhotoURL, relOrigPhoto) = createDummyImageFile(named: "orig_staging_fail.jpg")
        let origRec = makeRecord(id: "rec-staging-fail", serial: "STAGING-FAIL-001", photo: relOrigPhoto)
        try testDb.upsertRecord(origRec)

        // Create a valid backup to restore from
        let validBackupDir = tempDir.appendingPathComponent("valid_backup_for_safety_fail", isDirectory: true)
        try testDb.backupCollection(to: validBackupDir, photosSourceDir: testPhotosDir)

        // Inject failure during safety staging copy
        XCTAssertThrowsError(
            try testDb.restoreCollection(
                from: validBackupDir,
                destinationDBURL: testDbURL,
                destinationPhotosDir: testPhotosDir,
                authorized: true,
                _injectedSafetyStagingFailure: true
            )
        )

        // CRITICAL INVARIANT: Original database file MUST NOT be deleted
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDbURL.path), "Original database file must exist after safety staging failure")

        // Active connection must remain open and queryable
        let loaded = try testDb.loadAllRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "rec-staging-fail")
        XCTAssertEqual(loaded.first?.serial, "STAGING-FAIL-001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: origPhotoURL.path))
    }

    func testBackupPublicationRejectsDestinationsWithinActiveCollectionTree() throws {
        let testOutputRoot = StorageConfiguration.shared.outputRoot

        // 1. Direct collection root
        XCTAssertThrowsError(try testDb.backupCollection(to: testOutputRoot, photosSourceDir: testPhotosDir))

        // 2. Photos directory
        XCTAssertThrowsError(try testDb.backupCollection(to: testPhotosDir, photosSourceDir: testPhotosDir))

        // 3. Nested subfolder inside active collection
        let nestedInsideRoot = testOutputRoot.appendingPathComponent("nested_backups/backup_1", isDirectory: true)
        XCTAssertThrowsError(try testDb.backupCollection(to: nestedInsideRoot, photosSourceDir: testPhotosDir))

        // 4. Nested subfolder inside photos
        let nestedInsidePhotos = testPhotosDir.appendingPathComponent("sub_photos", isDirectory: true)
        XCTAssertThrowsError(try testDb.backupCollection(to: nestedInsidePhotos, photosSourceDir: testPhotosDir))

        // 5. Database directory
        let dbDir = testDbURL.deletingLastPathComponent()
        XCTAssertThrowsError(try testDb.backupCollection(to: dbDir, photosSourceDir: testPhotosDir))

        // 6. Symlink inside temp pointing into live photos directory
        let symlinkDest = tempDir.appendingPathComponent("symlink_to_photos", isDirectory: true)
        try? FileManager.default.createSymbolicLink(atPath: symlinkDest.path, withDestinationPath: testPhotosDir.path)
        XCTAssertThrowsError(try testDb.backupCollection(to: symlinkDest, photosSourceDir: testPhotosDir))
    }

    func testRestoreRejectsPhotographPathOutsidePhotosSubtree() throws {
        let validBackupDir = tempDir.appendingPathComponent("valid_backup_subtree_test", isDirectory: true)
        let (_, relPhoto) = createDummyImageFile(named: "subtree_ok.jpg")
        let rec = makeRecord(id: "rec-subtree", serial: "SUBTREE-111", photo: relPhoto)
        try testDb.upsertRecord(rec)
        try testDb.backupCollection(to: validBackupDir, photosSourceDir: testPhotosDir)

        // Mutate the backup database record so that photo references a file outside 'photos/' subtree
        let manifestURL = validBackupDir.appendingPathComponent("backup_manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CollectionBackupManifest.self, from: manifestData)

        let backupDBURL = validBackupDir.appendingPathComponent(manifest.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backupDBURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let maliciousRecord = makeRecord(id: "rec-malicious", serial: "EVIL-666", photo: "escaped_root.txt")
        let encoder = JSONEncoder()
        let maliciousData = try encoder.encode(maliciousRecord)
        let maliciousJSON = try XCTUnwrap(String(data: maliciousData, encoding: .utf8))

        var stmt: OpaquePointer?
        let updateSQL = "UPDATE bonds SET record_json = ? WHERE id = 'rec-subtree';"
        XCTAssertEqual(sqlite3_prepare_v2(handle, updateSQL, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, (maliciousJSON as NSString).utf8String, -1, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(handle)

        let restoreDestDir = tempDir.appendingPathComponent("subtree_restore_dest", isDirectory: true)
        let restoreDBURL = restoreDestDir.appendingPathComponent("bonds.sqlite3")
        let restorePhotosDir = restoreDestDir.appendingPathComponent("photos", isDirectory: true)

        // Restoration MUST fail and reject photograph destinations outside photos subtree
        XCTAssertThrowsError(
            try testDb.restoreCollection(
                from: validBackupDir,
                destinationDBURL: restoreDBURL,
                destinationPhotosDir: restorePhotosDir,
                authorized: true
            )
        )

        // Verify no file was written to restoreDestDir outside photos directory
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreDestDir.appendingPathComponent("escaped_root.txt").path))
    }

    func testBackupCrashSafeGenerationsSwitch() throws {
        let backupDestDir = tempDir.appendingPathComponent("atomic_gen_test_dest", isDirectory: true)

        let (_, relPhoto1) = createDummyImageFile(named: "gen1.jpg")
        let rec1 = makeRecord(id: "rec-gen1", serial: "GEN1-A", photo: relPhoto1)
        try testDb.upsertRecord(rec1)
        try testDb.backupCollection(to: backupDestDir, photosSourceDir: testPhotosDir)

        let generationsDir = backupDestDir.appendingPathComponent("generations")
        let currentLink = backupDestDir.appendingPathComponent("current")
        XCTAssertTrue(FileManager.default.fileExists(atPath: generationsDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLink.path))

        let gen1Entries = (try? FileManager.default.contentsOfDirectory(atPath: generationsDir.path)) ?? []
        XCTAssertEqual(gen1Entries.count, 1)
        let gen1Name = gen1Entries[0]

        // Read destination symlink target of current
        var buf = [CChar](repeating: 0, count: 1024)
        let len = readlink(currentLink.path, &buf, buf.count)
        XCTAssertGreaterThan(len, 0)
        let target = String(cString: buf)
        XCTAssertEqual(target, "generations/\(gen1Name)")

        // Add second record and backup again
        let (_, relPhoto2) = createDummyImageFile(named: "gen2.jpg")
        let rec2 = makeRecord(id: "rec-gen2", serial: "GEN2-B", photo: relPhoto2)
        try testDb.upsertRecord(rec2)
        try testDb.backupCollection(to: backupDestDir, photosSourceDir: testPhotosDir)

        let gen2Entries = (try? FileManager.default.contentsOfDirectory(atPath: generationsDir.path)) ?? []
        XCTAssertEqual(gen2Entries.count, 2, "Both immutable generations must be preserved")

        let len2 = readlink(currentLink.path, &buf, buf.count)
        XCTAssertGreaterThan(len2, 0)
        let target2 = String(cString: buf)
        XCTAssertNotEqual(target, target2, "Current symlink must atomically switch to new generation")
        XCTAssertTrue(target2.hasPrefix("generations/gen_"))

        // Top level bonds.sqlite3 resolves to gen 2 (2 records)
        let snapshotRecords = try DatabaseManager.loadRecordsFromSnapshot(at: backupDestDir.appendingPathComponent("bonds.sqlite3"))
        XCTAssertEqual(snapshotRecords.count, 2)
    }

    func testCompleteSyntheticCollectionRestoration() throws {
        // Create an entirely synthetic collection
        let synthCollectionDir = tempDir.appendingPathComponent("synthetic_collection", isDirectory: true)
        let synthOutputRoot = synthCollectionDir.appendingPathComponent("output", isDirectory: true)
        let synthPhotosDir = synthOutputRoot.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: synthPhotosDir, withIntermediateDirectories: true)
        let synthDBURL = synthCollectionDir.appendingPathComponent("bonds.sqlite3")

        let synthDB = try DatabaseManager(url: synthDBURL)

        var createdPhotos: [String] = []
        var originalPhotoData: [String: Data] = [:]
        for i in 1 ... 5 {
            let photoName = "synth_bond_\(i).jpg"
            let photoURL = synthPhotosDir.appendingPathComponent(photoName)
            let testPayload = "SYNTHETIC_IMAGE_BYTES_FOR_BOND_\(i)_\(UUID().uuidString)"
            let payloadData = Data(testPayload.utf8)
            try payloadData.write(to: photoURL)
            createdPhotos.append("photos/\(photoName)")
            originalPhotoData[photoName] = payloadData

            let rec = makeRecord(
                id: "synth-rec-\(i)",
                serial: "SYNTH\(i)000000EE",
                series: i % 2 == 0 ? "I" : "EE",
                denom: "\(i * 50)",
                photo: "photos/\(photoName)",
                notes: "Synthetic collection bond #\(i)"
            )
            try synthDB.upsertRecord(rec)
        }

        let synthBackupDir = tempDir.appendingPathComponent("synthetic_backup", isDirectory: true)
        try synthDB.backupCollection(to: synthBackupDir, photosSourceDir: synthPhotosDir)

        // Verify backup manifest and structure
        let manifestURL = synthBackupDir.appendingPathComponent("backup_manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CollectionBackupManifest.self, from: manifestData)
        XCTAssertEqual(manifest.recordCount, 5)
        XCTAssertEqual(manifest.photoFiles.count, 5)

        // Restore into an entirely synthetic fresh destination
        let freshRestoreDir = tempDir.appendingPathComponent("fresh_synthetic_restore", isDirectory: true)
        let freshDBURL = freshRestoreDir.appendingPathComponent("bonds.sqlite3")
        let freshPhotosDir = freshRestoreDir.appendingPathComponent("photos", isDirectory: true)

        let restoreManager = try DatabaseManager(url: freshDBURL)
        try restoreManager.restoreCollection(
            from: synthBackupDir,
            destinationDBURL: freshDBURL,
            destinationPhotosDir: freshPhotosDir,
            authorized: true
        )

        let restoredRecords = try restoreManager.loadAllRecords()
        XCTAssertEqual(restoredRecords.count, 5)

        // Verify all 5 photographs exist with complete byte-for-byte equality
        for i in 1 ... 5 {
            let photoName = "synth_bond_\(i).jpg"
            let photoURL = freshPhotosDir.appendingPathComponent(photoName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
            let restoredData = try Data(contentsOf: photoURL)
            XCTAssertEqual(restoredData, originalPhotoData[photoName], "Restored photo \(photoName) must match original byte-for-byte")
        }

        // Verify restored database is functional for mutations
        let newRec = makeRecord(id: "synth-post-restore", serial: "POST12345EE")
        try restoreManager.upsertRecord(newRec)
        XCTAssertEqual(try restoreManager.loadAllRecords().count, 6)
    }

    func testBackupPostCommitFailurePreservesActiveCommittedGeneration() throws {
        let backupDestDir = tempDir.appendingPathComponent("post_commit_fail_dest", isDirectory: true)

        let (_, relPhoto) = createDummyImageFile(named: "post_commit_photo.jpg")
        let rec = makeRecord(id: "rec-post-commit", serial: "POST-COMMIT-999", photo: relPhoto)
        try testDb.upsertRecord(rec)

        // Backup with injected failure AFTER pointer commit
        XCTAssertThrowsError(
            try testDb.backupCollection(
                to: backupDestDir,
                photosSourceDir: testPhotosDir,
                _injectedFailureAfterGenerationCommit: true
            )
        )

        // CRITICAL INVARIANT: The committed generation MUST NOT be deleted by catch block
        let currentLink = backupDestDir.appendingPathComponent("current")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLink.path), "Current pointer must exist and not be dangling")

        var buf = [CChar](repeating: 0, count: 1024)
        let len = readlink(currentLink.path, &buf, buf.count)
        XCTAssertGreaterThan(len, 0)
        let target = String(cString: buf)
        XCTAssertTrue(target.hasPrefix("generations/gen_"))

        let committedGenDir = backupDestDir.appendingPathComponent(target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedGenDir.path), "Committed generation directory must be preserved on post-commit failure")

        // Destination database must be intact and queryable through current pointer
        let snapshotRecords = try DatabaseManager.loadRecordsFromSnapshot(at: backupDestDir.appendingPathComponent("bonds.sqlite3"))
        XCTAssertEqual(snapshotRecords.count, 1)
        XCTAssertEqual(snapshotRecords.first?.id, "rec-post-commit")
        XCTAssertEqual(snapshotRecords.first?.serial, "POST-COMMIT-999")
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

    func testExtractIssueDateRejectsDistantNumbers() {
        // Month at top-left, year at bottom-right (spatially separated)
        let distantLines = [
            OCRLine(text: "05", confidence: 0.9, box: CGRect(x: 0.1, y: 0.9, width: 0.05, height: 0.03)),
            OCRLine(text: "1995", confidence: 0.9, box: CGRect(x: 0.85, y: 0.15, width: 0.08, height: 0.03)),
        ]
        let reading = extractIssueDateReading(distantLines, series: "EE")
        XCTAssertNotEqual(reading.value, "05/1995", "Distant numbers must not be paired as an issue date")
    }

    func testExtractIssueDateRejectsRulerTicksOrNumbersWithoutYear() {
        let rulerLines = [
            OCRLine(text: "1 2 3 4 5 6 7 8 9 10 11 12", confidence: 0.85, box: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.02)),
            OCRLine(text: "04", confidence: 0.9, box: CGRect(x: 0.7, y: 0.7, width: 0.04, height: 0.02)),
        ]
        let reading = extractIssueDateReading(rulerLines, series: "EE")
        XCTAssertTrue(reading.value.isEmpty, "Ruler ticks or solo month numbers without year must not produce issue date")
    }

    func testExtractIssueDatePenalizesCompetingDatingStampLine() {
        let stampLines = [
            OCRLine(text: "DATING STAMP 14 APR 1986", confidence: 0.95, box: CGRect(x: 0.65, y: 0.45, width: 0.25, height: 0.03)),
        ]
        let reading = extractIssueDateReading(stampLines, series: "EE")
        XCTAssertTrue(reading.value.isEmpty || !reading.isHigh, "Dating stamp line must not produce high confidence issue date")
    }
}
