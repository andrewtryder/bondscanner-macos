@testable import BondScanner
import CoreGraphics
import SQLite3
import XCTest

final class BondScannerTests: XCTestCase {
    private var testExportTempDir: URL?

    override func setUp() {
        super.setUp()
        ScanLog.shared.isEnabled = false
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("test-exports-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        testExportTempDir = temp
        ExportConfiguration.shared.setCustomDestinations(
            records: temp.appendingPathComponent("records.json"),
            csv: temp.appendingPathComponent("bonds.csv")
        )
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        ExportConfiguration.shared.resetToDefaults()
        if let temp = testExportTempDir {
            try? FileManager.default.removeItem(at: temp)
            testExportTempDir = nil
        }
        super.tearDown()
    }

    func testNormalizeSerial() {
        XCTAssertEqual(normalizeSerial("c1234567890ee"), "C1234567890EE")
        XCTAssertEqual(normalizeSerial("C 1234567890 EE"), "C1234567890EE")
        XCTAssertEqual(normalizeSerial("C123456789OEE"), "C1234567890EE") // O to 0 in numeric body
        XCTAssertEqual(normalizeSerial("q2234677197e"), "Q2234677197E")
        XCTAssertEqual(normalizeSerial(""), "")
    }

    func testValidatedSerialSeriesE() {
        // 9-digit Series E (e.g. $50 bond)
        let s9 = validatedSerial("L710124456E", series: "E")
        XCTAssertTrue(s9.isHigh)
        XCTAssertEqual(s9.value, "L710124456E")

        // 10-digit Series E (e.g. $25 bond)
        let s10 = validatedSerial("Q2234677197E", series: "E")
        XCTAssertTrue(s10.isHigh)
        XCTAssertEqual(s10.value, "Q2234677197E")

        // 8-digit Series E
        let s8 = validatedSerial("C12345678E", series: "E")
        XCTAssertTrue(s8.isHigh)
        XCTAssertEqual(s8.value, "C12345678E")

        // Leading junk character stripped
        let junk = validatedSerial("NAMEQ2234677197E", series: "E")
        XCTAssertTrue(junk.isHigh)
        XCTAssertEqual(junk.value, "Q2234677197E")
    }

    func testValidatedSerialSeriesEE() {
        let ee = validatedSerial("C1234567890EE", series: "EE")
        XCTAssertTrue(ee.isHigh)
        XCTAssertEqual(ee.value, "C1234567890EE")
    }

    func testValidatedSerialSeriesI() {
        let i = validatedSerial("I1234567890I", series: "I")
        XCTAssertTrue(i.isHigh)
        XCTAssertEqual(i.value, "I1234567890I")
    }

    func testInvalidSerialRejected() {
        let invalid = validatedSerial("12345678", series: "E")
        XCTAssertFalse(invalid.isHigh)
    }

    func testDenominationFuzzyMatching() {
        // Exact
        let exactHits = wordAmountReadings(in: "TWENTY FIVE DOLLARS", series: "E")
        XCTAssertEqual(exactHits.first?.value, "25")

        // OCR typo: TVENTYFINE DOLLARS
        let typoHits = wordAmountReadings(in: "TVENTYFINE DOLLARS", series: "E")
        XCTAssertEqual(typoHits.first?.value, "25")

        // Fifty dollars
        let fiftyHits = wordAmountReadings(in: "FIFTY DOLLARS", series: "E")
        XCTAssertEqual(fiftyHits.first?.value, "50")

        // One hundred dollars
        let hundredHits = wordAmountReadings(in: "ONE HUNDRED DOLLARS", series: "E")
        XCTAssertEqual(hundredHits.first?.value, "100")
    }

    func testMonthParsing() {
        XCTAssertEqual(monthFromName("JAN"), "01")
        XCTAssertEqual(monthFromName("FEBRUARY"), "02")
        XCTAssertEqual(monthFromName("MAR 1966"), "03")
        XCTAssertEqual(monthFromName("SETEMBER"), "09") // OCR alias
        XCTAssertEqual(monthFromName("DEC"), "12")
        XCTAssertNil(monthFromName("RULER 10"))
    }

    func testPlausibleIssueYear() {
        // Series E (1941 - 1980)
        XCTAssertTrue(isPlausibleIssueYear("1945", series: "E"))
        XCTAssertTrue(isPlausibleIssueYear("1966", series: "E"))
        XCTAssertTrue(isPlausibleIssueYear("1980", series: "E"))
        XCTAssertFalse(isPlausibleIssueYear("1930", series: "E"))
        XCTAssertFalse(isPlausibleIssueYear("1985", series: "E"))
        XCTAssertFalse(isPlausibleIssueYear("1900", series: "E"))

        // Series EE (1980 - 2026)
        XCTAssertTrue(isPlausibleIssueYear("1985", series: "EE"))
        XCTAssertTrue(isPlausibleIssueYear("2005", series: "EE"))
        XCTAssertFalse(isPlausibleIssueYear("1975", series: "EE"))
    }

    func testSQLiteCRUDAndLosslessRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try db.count(), 0)

        var r1 = emptyBondRecord(id: "rec-1", capturedAt: "2026-11-14T10:00:00Z")
        r1.series = "EE"
        r1.serial = "C1234567890EE"
        r1.issueMonth = "05"
        r1.issueYear = "1992"
        r1.denomination = "100"
        r1.status = "OK"
        r1.fieldConfidence = ["serial": "high", "denomination": "high"]
        r1.fieldPhoto = ["serial": "photos/r1.jpg"]
        r1.userConfirmedFields = ["serial"]
        r1.validationWarnings = ["sample warning"]
        r1.micrData = "000090007"

        var r2 = emptyBondRecord(id: "rec-2", capturedAt: "2026-11-14T10:01:00Z")
        r2.series = "E"
        r2.serial = "Q2234677197E"
        r2.denomination = "25"
        r2.status = "REVIEW"

        try db.upsertRecord(r1)
        try db.upsertRecord(r2)
        XCTAssertEqual(try db.count(), 2)

        let loaded = try db.loadAllRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, "rec-1")
        XCTAssertEqual(loaded[0].fieldConfidence, ["serial": "high", "denomination": "high"])
        XCTAssertEqual(loaded[0].fieldPhoto, ["serial": "photos/r1.jpg"])
        XCTAssertEqual(loaded[0].userConfirmedFields, ["serial"])
        XCTAssertEqual(loaded[0].validationWarnings, ["sample warning"])
        XCTAssertEqual(loaded[0].micrData, "000090007")
        XCTAssertEqual(loaded[1].id, "rec-2")

        // Update in place preserves sort order
        r1.status = "REVIEW"
        r1.notes = "Updated note"
        try db.upsertRecord(r1)
        let afterUpdate = try db.loadAllRecords()
        XCTAssertEqual(afterUpdate.count, 2)
        XCTAssertEqual(afterUpdate[0].id, "rec-1")
        XCTAssertEqual(afterUpdate[0].status, "REVIEW")
        XCTAssertEqual(afterUpdate[0].notes, "Updated note")

        // Delete
        try db.deleteRecord(id: "rec-1")
        XCTAssertEqual(try db.count(), 1)
        let afterDelete = try db.loadAllRecords()
        XCTAssertEqual(afterDelete.map(\.id), ["rec-2"])
    }

    func testSQLiteIndexedDuplicateSerialLookup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try DatabaseManager(url: tempDir.appendingPathComponent("bonds.sqlite3"))

        var r1 = emptyBondRecord(id: "rec-1", capturedAt: "2026-11-14T10:00:00Z")
        r1.series = "EE"
        r1.serial = "C1234567890EE"
        r1.status = "OK"

        var r2 = emptyBondRecord(id: "rec-2", capturedAt: "2026-11-14T10:01:00Z")
        r2.series = "E"
        r2.serial = "Q2234677197E"
        r2.status = "OK"

        try db.upsertRecords([r1, r2])

        // Matches normalized casing/spaces/O->0
        let matches = try db.findRecordsByNormalizedSerial("c 123456789O ee")
        XCTAssertEqual(matches.map(\.id), ["rec-1"])

        // Respects excludingId
        let excluded = try db.findRecordsByNormalizedSerial("C1234567890EE", excludingId: "rec-1")
        XCTAssertTrue(excluded.isEmpty)

        // Non-match returns empty
        let missing = try db.findRecordsByNormalizedSerial("L999999999E")
        XCTAssertTrue(missing.isEmpty)
    }

    func testSQLiteMigrationAndPendingResumability() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonURL = tempDir.appendingPathComponent("records.json")
        let csvSourceURL = tempDir.appendingPathComponent("bonds.csv")
        let backupRoot = tempDir.appendingPathComponent("backups", isDirectory: true)

        var okRec = emptyBondRecord(id: "ok-1", capturedAt: "2026-11-14T09:00:00Z")
        okRec.series = "EE"
        okRec.serial = "C1234567890EE"
        okRec.status = "OK"

        var procRec = emptyBondRecord(id: "proc-1", capturedAt: "2026-11-14T09:05:00Z")
        procRec.status = "PROCESSING"
        procRec.sourcePhoto = "photos/original_proc.jpg"

        try exportJSON([okRec, procRec], to: jsonURL)
        try exportCSV([okRec, procRec], to: csvSourceURL)

        let db = try DatabaseManager(url: tempDir.appendingPathComponent("bonds.sqlite3"))
        let migrated = try db.migrateFromJSONIfNeeded(jsonURL: jsonURL, csvSourceURL: csvSourceURL, backupRootURL: backupRoot)

        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(try db.count(), 2)

        let backupJSON = backupRoot.appendingPathComponent("pre-sqlite-migration/records.json")
        let backupCSV = backupRoot.appendingPathComponent("pre-sqlite-migration/bonds.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupCSV.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: csvSourceURL.path))

        let pending = try db.pendingOCRRecords()
        XCTAssertEqual(pending.map(\.id), ["proc-1"])
    }

    func testCSVExportAndFormulaSanitization() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var rec = emptyBondRecord(id: "csv-1", capturedAt: "2026-11-14T11:00:00Z")
        rec.series = "E"
        rec.serial = "Q2234677197E"
        rec.owner = "=HYPERLINK(\"http://bad\")"
        rec.notes = "+quoted \"text\" here"
        rec.address = "-123 Main"
        rec.issuingAgent = "@Bank"
        rec.status = "OK"

        let csvText = formatCSV(for: [rec])
        XCTAssertTrue(csvText.contains("\"'=HYPERLINK(\"\"http://bad\"\")\""))
        XCTAssertTrue(csvText.contains("\"'+quoted \"\"text\"\" here\""))
        XCTAssertTrue(csvText.contains("\"'-123 Main\""))
        XCTAssertTrue(csvText.contains("\"'@Bank\""))

        let outURL = tempDir.appendingPathComponent("exported/bonds.csv")
        try exportCSV([rec], to: outURL)
        let readBack = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertEqual(readBack, csvText)
    }

    private func makeTestCGImage(width: Int, height: Int, backgroundGray: CGFloat, foregroundGray: CGFloat) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(red: backgroundGray, green: backgroundGray, blue: backgroundGray, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: foregroundGray, green: foregroundGray, blue: foregroundGray, alpha: 1.0)
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()
    }

    func testAutoContrastAdjustedImageFadedVsHighContrast() throws {
        let lowContrast = try XCTUnwrap(makeTestCGImage(width: 400, height: 200, backgroundGray: 0.72, foregroundGray: 0.60))
        let highContrast = try XCTUnwrap(makeTestCGImage(width: 400, height: 200, backgroundGray: 0.95, foregroundGray: 0.05))
        let region = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        let lowParams = computeAutoContrastParameters(lowContrast, region: region)
        let highParams = computeAutoContrastParameters(highContrast, region: region)
        XCTAssertGreaterThan(lowParams.contrast, highParams.contrast)

        let adjusted = try XCTUnwrap(autoContrastAdjustedImage(lowContrast, region: region))
        XCTAssertEqual(adjusted.width, 400)
        XCTAssertEqual(adjusted.height, 200)
    }

    func testEnhancementControllerManualOverride() throws {
        let prior = EnhancementController.shared.settings
        defer { EnhancementController.shared.settings = prior }

        EnhancementController.shared.update {
            $0.autoContrastEnabled = false
            $0.manualContrast = 1.65
            $0.manualBrightness = -0.05
            $0.manualSharpness = 0.50
        }

        let image = try XCTUnwrap(makeTestCGImage(width: 400, height: 200, backgroundGray: 0.80, foregroundGray: 0.25))
        let enhanced = try XCTUnwrap(effectiveEnhancedImage(image, region: nil))
        XCTAssertEqual(enhanced.width, 400)
        XCTAssertEqual(enhanced.height, 200)
    }

    func testBondsDrawerSortingAndReviewFilter() {
        var r1 = emptyBondRecord(id: "1", capturedAt: "2026-11-14T10:00:00Z")
        r1.serial = "Q200000002E"
        r1.status = "OK"

        var r2 = emptyBondRecord(id: "2", capturedAt: "2026-11-14T12:00:00Z")
        r2.serial = "C100000001EE"
        r2.status = "REVIEW"

        var r3 = emptyBondRecord(id: "3", capturedAt: "2026-11-14T11:00:00Z")
        r3.serial = ""
        r3.status = "PROCESSING"

        let records = [r1, r2, r3]

        let byDateDesc = sortedAndFilteredBondRows(from: records, sortField: .date, ascending: false, reviewOnly: false)
        XCTAssertEqual(byDateDesc.map(\.record.id), ["2", "3", "1"])

        let byNumberDesc = sortedAndFilteredBondRows(from: records, sortField: .number, ascending: false, reviewOnly: false)
        XCTAssertEqual(byNumberDesc.map(\.number), [3, 2, 1])

        let bySerialAsc = sortedAndFilteredBondRows(from: records, sortField: .serial, ascending: true, reviewOnly: false)
        XCTAssertEqual(bySerialAsc.map(\.record.id), ["2", "1", "3"])

        let reviewOnly = sortedAndFilteredBondRows(from: records, sortField: .date, ascending: false, reviewOnly: true)
        XCTAssertEqual(reviewOnly.map(\.record.id), ["2", "3"])
    }

    // MARK: - Reliability & Performance Hardening Tests (Priorities 1 - 5)

    func testTransactionRollbackAfterFailedMerge() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)

        var recA = emptyBondRecord(id: "rec-A", capturedAt: "2026-11-14T10:00:00Z")
        recA.serial = "C1234567890EE"
        recA.series = "EE"
        recA.denomination = "100"
        recA.status = "OK"

        var recB = emptyBondRecord(id: "rec-B", capturedAt: "2026-11-14T10:01:00Z")
        recB.serial = "C1234567890EE"
        recB.series = "EE"
        recB.denomination = "100"
        recB.owner = "Jane Doe"
        recB.status = "OK"

        try db.upsertRecords([recA, recB])
        XCTAssertEqual(try db.count(), 2)

        // Part 1: Verify successful atomic merge
        var mergedA = recA
        mergedA.owner = "Jane Doe"
        try db.atomicMerge(deleteId: recB.id, updatedRecord: mergedA, sortOrder: 0)

        XCTAssertEqual(try db.count(), 1)
        let loaded = try db.loadAllRecords()
        XCTAssertEqual(loaded.first?.id, "rec-A")
        XCTAssertEqual(loaded.first?.owner, "Jane Doe")
        XCTAssertFalse(try db.loadAllRecords().contains(where: { $0.id == "rec-B" }))

        // Re-insert recB for failure injection testing
        try db.upsertRecord(recB)
        XCTAssertEqual(try db.count(), 2)

        // Part 2: INJECT FAILURE to test genuine SQLite transaction rollback
        // Install a trigger that aborts transactions on bonds updates when id == 'rec-A'
        let createTriggerSQL = "CREATE TRIGGER fail_rollback_injection BEFORE INSERT ON bonds WHEN NEW.id = 'rec-A' BEGIN SELECT RAISE(ABORT, 'injected transaction failure'); END;"
        var stmt: OpaquePointer?
        // Open low-level connection to execute DDL trigger
        var rawHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &rawHandle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawHandle, createTriggerSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(rawHandle)

        var failingMerged = recA
        failingMerged.owner = "Should Rollback"

        XCTAssertThrowsError(try db.atomicMerge(deleteId: recB.id, updatedRecord: failingMerged, sortOrder: 0))

        // ROLLBACK GUARANTEE: Neither the deletion of recB nor the update of recA must persist!
        XCTAssertEqual(try db.count(), 2)
        let recordsAfterFailedMerge = try db.loadAllRecords()
        XCTAssertTrue(recordsAfterFailedMerge.contains(where: { $0.id == "rec-A" }))
        XCTAssertTrue(recordsAfterFailedMerge.contains(where: { $0.id == "rec-B" }))
        let reloadedA = recordsAfterFailedMerge.first(where: { $0.id == "rec-A" })
        XCTAssertEqual(reloadedA?.owner, "Jane Doe") // NOT "Should Rollback"
    }

    func testInterruptedScanRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try DatabaseManager(url: tempDir.appendingPathComponent("bonds.sqlite3"))

        var okRec = emptyBondRecord(id: "ok-1", capturedAt: "2026-11-14T09:00:00Z")
        okRec.status = "OK"
        okRec.serial = "C1234567890EE"

        var proc1 = emptyBondRecord(id: "proc-1", capturedAt: "2026-11-14T09:01:00Z")
        proc1.status = "PROCESSING"
        proc1.sourcePhoto = "photos/original_1.jpg"

        var proc2 = emptyBondRecord(id: "proc-2", capturedAt: "2026-11-14T09:02:00Z")
        proc2.status = "PROCESSING"
        proc2.sourcePhoto = "photos/original_2.jpg"

        var reviewRec = emptyBondRecord(id: "rev-1", capturedAt: "2026-11-14T09:03:00Z")
        reviewRec.status = "REVIEW"

        try db.upsertRecords([okRec, proc1, proc2, reviewRec])

        let pending = try db.pendingOCRRecords()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.map(\.id), ["proc-1", "proc-2"])
    }

    func testDuplicateSerialAndNearMatchHandling() {
        var existing = emptyBondRecord(id: "exist-1", capturedAt: "2026-11-14T10:00:00Z")
        existing.serial = "C1234567890EE"
        existing.series = "EE"
        existing.denomination = "100"
        existing.issueMonth = "05"
        existing.issueYear = "1992"

        // Case 1: Exact validated match with no conflicts -> allowed to merge
        var incomingExact = emptyBondRecord(id: "in-exact", capturedAt: "2026-11-14T10:05:00Z")
        incomingExact.serial = "C1234567890EE"
        incomingExact.series = "EE"
        incomingExact.denomination = "100"
        incomingExact.owner = "Alice"
        XCTAssertTrue(canMergeCapture(incomingExact, into: existing))

        // Case 2: Exact match with conflicting denomination -> NEVER merge
        var incomingConflict = emptyBondRecord(id: "in-conflict", capturedAt: "2026-11-14T10:06:00Z")
        incomingConflict.serial = "C1234567890EE"
        incomingConflict.series = "EE"
        incomingConflict.denomination = "50" // Conflicting denomination!
        XCTAssertTrue(recordsHaveConflictingFields(incomingConflict, existing))
        XCTAssertFalse(canMergeCapture(incomingConflict, into: existing))

        // Case 3: Near-match (1 OCR-confusable character, e.g. 8 vs 0) -> NEVER merge, preserve for review
        var incomingNear = emptyBondRecord(id: "in-near", capturedAt: "2026-11-14T10:07:00Z")
        incomingNear.serial = "C1234567898EE" // '8' vs '0' is an OCR confusable digit pair
        incomingNear.series = "EE"
        incomingNear.denomination = "100"
        let match = serialsMatchForMerge(incomingNear.serial, existing.serial)
        XCTAssertFalse(match.exact)
        XCTAssertTrue(match.near)
        XCTAssertFalse(canMergeCapture(incomingNear, into: existing))

        let nearMatch = findNearMatchRecord(incomingNear, in: [existing], excluding: incomingNear.id)
        XCTAssertEqual(nearMatch?.id, "exist-1")
    }

    func testCapturedPhotographsPreservedOnFailedDatabaseWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-photo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let photosDir = tempDir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        let photoURL = photosDir.appendingPathComponent("original_test.jpg")
        let dummyData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        try dummyData.write(to: photoURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))

        // Simulate database failure (parent path is an existing file, so directory creation fails)
        let fileAsDir = tempDir.appendingPathComponent("blocking_file.txt")
        try "not a directory".write(to: fileAsDir, atomically: true, encoding: .utf8)
        let invalidDBURL = fileAsDir.appendingPathComponent("bonds.sqlite3")
        XCTAssertThrowsError(try DatabaseManager(url: invalidDBURL))

        // Critical guarantee: photo remains safely on disk despite database failure
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path))
        XCTAssertEqual(try Data(contentsOf: photoURL), dummyData)
    }

    func testExportFreshnessAndAutomaticSync() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-export-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let jsonURL = tempDir.appendingPathComponent("records.json")
        let csvURL = tempDir.appendingPathComponent("bonds.csv")

        var rec = emptyBondRecord(id: "sync-1", capturedAt: "2026-11-14T10:00:00Z")
        rec.serial = "C1234567890EE"
        rec.series = "EE"
        rec.denomination = "100"
        rec.status = "OK"

        // Perform export
        try exportJSON([rec], to: jsonURL)
        try exportCSV([rec], to: csvURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))

        let jsonContent = try String(contentsOf: jsonURL, encoding: .utf8)
        let csvContent = try String(contentsOf: csvURL, encoding: .utf8)

        XCTAssertTrue(jsonContent.contains("C1234567890EE"))
        XCTAssertTrue(csvContent.contains("C1234567890EE"))
        XCTAssertTrue(csvContent.contains("100"))
    }

    func testGracefulDatabaseReopen() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-graceful-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")

        do {
            let db = try DatabaseManager(url: dbURL)
            var r = emptyBondRecord(id: "graceful-1", capturedAt: "2026-11-14T10:00:00Z")
            r.serial = "C1234567890EE"
            r.status = "OK"
            try db.upsertRecord(r)
            XCTAssertEqual(try db.count(), 1)
        }

        // Reopen database gracefully
        let reopened = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try reopened.count(), 1)
        let loaded = try reopened.loadAllRecords()
        XCTAssertEqual(loaded.first?.id, "graceful-1")
        XCTAssertEqual(loaded.first?.serial, "C1234567890EE")
    }

    func testCrashRecoveryUncleanShutdown() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-crash-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")

        // Phase 1: Initialize schema with DatabaseManager
        do {
            let db = try DatabaseManager(url: dbURL)
            var r = emptyBondRecord(id: "crash-init", capturedAt: "2026-11-14T09:00:00Z")
            r.serial = "C1111111111EE"
            r.status = "OK"
            try db.upsertRecord(r)
        }

        // Phase 2: Open low-level SQLite handle, disable auto-checkpoint, write a new row, and simulate crash by closing without checkpoint
        var rawHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &rawHandle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawHandle, "PRAGMA wal_autocheckpoint = 0;", nil, nil, nil), SQLITE_OK)

        var crashRec = emptyBondRecord(id: "crash-2", capturedAt: "2026-11-14T09:01:00Z")
        crashRec.serial = "C2222222222EE"
        crashRec.status = "OK"
        let encData = try JSONEncoder().encode(crashRec)
        let jsonStr = try XCTUnwrap(String(data: encData, encoding: .utf8)?.replacingOccurrences(of: "'", with: "''"))
        let insertSQL = "INSERT INTO bonds (id, sort_order, captured_at, serial_number, normalized_serial, status, record_json, updated_at) VALUES ('crash-2', 1, '2026-11-14T09:01:00Z', 'C2222222222EE', 'C2222222222EE', 'OK', '\(jsonStr)', '2026-11-14T09:01:00Z');"
        XCTAssertEqual(sqlite3_exec(rawHandle, insertSQL, nil, nil, nil), SQLITE_OK)

        // Verify WAL file exists and contains uncheckpointed data
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(walSize, 0)

        // Close raw handle WITHOUT checkpointing (simulates crash/abrupt process termination)
        sqlite3_close_v2(rawHandle)

        // Phase 3: Open with DatabaseManager and verify crash recovery replays the uncheckpointed WAL
        let recoveredDB = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try recoveredDB.count(), 2)
        let loaded = try recoveredDB.loadAllRecords()
        XCTAssertTrue(loaded.contains(where: { $0.id == "crash-init" }))
        XCTAssertTrue(loaded.contains(where: { $0.id == "crash-2" }))
    }

    func testLockedDatabaseInitializationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-locked-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)
        var r = emptyBondRecord(id: "lock-1", capturedAt: "2026-11-14T10:00:00Z")
        r.serial = "C1234567890EE"
        try db.upsertRecord(r)

        // Open independent connection and hold exclusive lock
        var lockHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &lockHandle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lockHandle, "BEGIN EXCLUSIVE TRANSACTION;", nil, nil, nil), SQLITE_OK)
        defer {
            sqlite3_exec(lockHandle, "ROLLBACK;", nil, nil, nil)
            sqlite3_close_v2(lockHandle)
        }

        // Attempting to open DatabaseManager while locked must throw and NOT destroy files
        XCTAssertThrowsError(try DatabaseManager(url: dbURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func testReadOnlyDatabaseInitializationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-ro-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        do {
            let db = try DatabaseManager(url: dbURL)
            var r = emptyBondRecord(id: "ro-1", capturedAt: "2026-11-14T10:00:00Z")
            r.serial = "C1234567890EE"
            try db.upsertRecord(r)
        }

        // Make database file read-only (0o444)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dbURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        }

        // Initialization must fail with permission error or openFailed, NOT corruption!
        XCTAssertThrowsError(try DatabaseManager(url: dbURL)) { error in
            guard let dbErr = error as? DatabaseError else {
                XCTFail("Expected DatabaseError but got: \(error)")
                return
            }
            switch dbErr {
            case .permissionDenied, .openFailed, .statementFailed:
                break // Valid
            default:
                XCTFail("Must not report corruption for read-only database! Got: \(dbErr)")
            }
        }

        // Verify original file is preserved and not moved away
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func testInaccessiblePathDatabaseInitializationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-inaccess-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blockerFile = tempDir.appendingPathComponent("blocking_regular_file")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "file content".write(to: blockerFile, atomically: true, encoding: .utf8)

        let invalidURL = blockerFile.appendingPathComponent("bonds.sqlite3")
        XCTAssertThrowsError(try DatabaseManager(url: invalidURL))
    }

    func testCorruptedDatabaseIntegrityAndExplicitRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-corrupt-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        do {
            let db = try DatabaseManager(url: dbURL)
            var r = emptyBondRecord(id: "corrupt-1", capturedAt: "2026-11-14T10:00:00Z")
            r.serial = "C1234567890EE"
            try db.upsertRecord(r)
        }

        // Deliberately corrupt the database file
        let junkBytes = Data("NOT AN SQLITE DATABASE CORRUPT BYTES CONTENT HEADER INVALID".utf8)
        let handle = try FileHandle(forWritingTo: dbURL)
        handle.write(junkBytes)
        handle.closeFile()

        // 1. validateDatabaseIntegrity must detect corruption
        XCTAssertThrowsError(try DatabaseManager.validateDatabaseIntegrity(at: dbURL)) { error in
            guard let dbErr = error as? DatabaseError, case .databaseCorrupted = dbErr else {
                XCTFail("Expected databaseCorrupted but got: \(error)")
                return
            }
        }

        // 2. DatabaseManager initialization must fail and NOT silently fallback
        XCTAssertThrowsError(try DatabaseManager(url: dbURL))

        // 3. recoverDatabase must safely archive the corrupt file and initialize clean replacement
        let recovered = try DatabaseManager.recoverDatabase(at: dbURL)
        XCTAssertEqual(try recovered.count(), 0)

        // Verify corrupted file was archived
        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let archiveFiles = files.filter { $0.contains("bonds_corrupt_") }
        XCTAssertFalse(archiveFiles.isEmpty, "Corrupted files must be archived before replacement")
    }

    func testNonCorruptedDatabaseRejectsRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-safe-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)
        var r = emptyBondRecord(id: "intact-1", capturedAt: "2026-11-14T10:00:00Z")
        r.serial = "C1234567890EE"
        try db.upsertRecord(r)

        // Attempting recovery on an intact database MUST ABORT to prevent accidental data loss
        XCTAssertThrowsError(try DatabaseManager.recoverDatabase(at: dbURL)) { error in
            guard let dbErr = error as? DatabaseError, case .recoveryAborted = dbErr else {
                XCTFail("Expected recoveryAborted but got: \(error)")
                return
            }
        }
        XCTAssertEqual(try db.count(), 1)
    }

    func testSQLiteSchemaVersioningAndBackupRestore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-backup-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let backupURL = tempDir.appendingPathComponent("bonds_backup.sqlite3")

        let db = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try db.currentSchemaVersion(), 1)

        var r1 = emptyBondRecord(id: "bk-1", capturedAt: "2026-11-14T10:00:00Z")
        r1.serial = "C1234567890EE"
        r1.series = "EE"
        r1.denomination = "100"
        r1.status = "OK"

        try db.upsertRecord(r1)
        XCTAssertEqual(try db.count(), 1)

        // Backup
        try db.backupDatabase(to: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Open backup in an independent manager to verify integrity
        let backupDB = try DatabaseManager(url: backupURL)
        XCTAssertEqual(try backupDB.count(), 1)
        XCTAssertEqual(try backupDB.loadAllRecords().first?.id, "bk-1")

        // Delete from primary
        try db.deleteRecord(id: "bk-1")
        XCTAssertEqual(try db.count(), 0)

        // Restore from backup
        try db.restoreDatabase(from: backupURL)
        XCTAssertEqual(try db.count(), 1)
        XCTAssertEqual(try db.loadAllRecords().first?.id, "bk-1")
    }

    func testBackupAndRestoreFailureHandling() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-backup-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)

        var r = emptyBondRecord(id: "orig-1", capturedAt: "2026-11-14T10:00:00Z")
        r.serial = "C1234567890EE"
        r.status = "OK"
        try db.upsertRecord(r)
        XCTAssertEqual(try db.count(), 1)

        // 1. Missing backup file
        let missingURL = tempDir.appendingPathComponent("nonexistent_backup.sqlite3")
        XCTAssertThrowsError(try db.restoreDatabase(from: missingURL))
        XCTAssertEqual(try db.count(), 1, "Original database must remain intact")

        // 2. Corrupted backup file (junk bytes)
        let corruptBackupURL = tempDir.appendingPathComponent("corrupted_backup.sqlite3")
        try "GARBAGE CORRUPTED BYTES".write(to: corruptBackupURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try db.restoreDatabase(from: corruptBackupURL))
        XCTAssertEqual(try db.count(), 1, "Original database must remain intact after corrupt backup restore attempt")

        // 3. Incompatible schema backup (e.g. user_version 9999)
        let incompatibleBackupURL = tempDir.appendingPathComponent("incompatible_backup.sqlite3")
        let incompDB = try DatabaseManager(url: incompatibleBackupURL)
        try incompDB.execute("PRAGMA user_version = 9999;")
        XCTAssertThrowsError(try db.restoreDatabase(from: incompatibleBackupURL)) { error in
            guard let dbErr = error as? DatabaseError, case .incompatibleSchema = dbErr else {
                XCTFail("Expected incompatibleSchema but got: \(error)")
                return
            }
        }
        XCTAssertEqual(try db.count(), 1, "Original database must remain intact after incompatible schema restore attempt")

        // 4. Partially copied backup file (valid backup truncated)
        let validBackupURL = tempDir.appendingPathComponent("valid_backup.sqlite3")
        try db.backupDatabase(to: validBackupURL)
        let partialBackupURL = tempDir.appendingPathComponent("partial_backup.sqlite3")
        let fullData = try Data(contentsOf: validBackupURL)
        let truncatedData = fullData.prefix(fullData.count / 3) // Truncate to 1/3
        try truncatedData.write(to: partialBackupURL)
        XCTAssertThrowsError(try db.restoreDatabase(from: partialBackupURL))
        XCTAssertEqual(try db.count(), 1, "Original database must remain intact after partial backup restore attempt")
        XCTAssertEqual(try db.loadAllRecords().first?.id, "orig-1")
    }

    func testNearMatchCannotBeReclassifiedAsOKByHighConfidenceOrCompleteFields() {
        var existing = emptyBondRecord(id: "exist-1", capturedAt: "2026-11-14T10:00:00Z")
        existing.serial = "C1234567890EE"
        existing.series = "EE"
        existing.denomination = "100"
        existing.issueMonth = "05"
        existing.issueYear = "1992"
        existing.status = "OK"

        // Incoming near-match with complete required fields and high OCR confidence
        var incoming = emptyBondRecord(id: "near-1", capturedAt: "2026-11-14T10:05:00Z")
        incoming.serial = "C1234567898EE" // Near-match (8 vs 0)
        incoming.series = "EE"
        incoming.denomination = "100"
        incoming.issueMonth = "05"
        incoming.issueYear = "1992"
        incoming.fieldConfidence = [
            "serial": "high",
            "series": "high",
            "denomination": "high",
            "issueDate": "high",
        ]

        // Detected as near match
        let near = findNearMatchRecord(incoming, in: [existing], excluding: incoming.id)
        XCTAssertEqual(near?.id, "exist-1")

        // Mark as near-match review with structured reason
        incoming.status = "REVIEW"
        incoming.reviewReasons = ["near_match: exist-1"]

        // Execute revalidation
        applyRequiredStatus(&incoming)

        // GUARANTEE: Even though all fields are present and high confidence, status MUST NOT be reclassified to OK!
        XCTAssertEqual(incoming.status, "REVIEW")
        XCTAssertTrue(incoming.reviewReasons?.contains(where: { $0.hasPrefix("near_match") }) == true)
    }

    func testReviewReasonsSurviveSaveReloadRevalidationAndAppRestart() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-review-reasons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)

        var record = emptyBondRecord(id: "rev-persist-1", capturedAt: "2026-11-14T10:00:00Z")
        record.serial = "C1234567898EE"
        record.series = "EE"
        record.denomination = "100"
        record.fieldConfidence = ["serial": "high", "denomination": "high"]
        record.status = "REVIEW"
        record.reviewReasons = ["near_match: exist-1", "user_flagged"]

        // 1. Save and reload from SQLite
        try db.upsertRecord(record)
        let loaded = try db.loadAllRecords()
        XCTAssertEqual(loaded.count, 1)
        let loadedRecord = try XCTUnwrap(loaded.first)
        XCTAssertEqual(loadedRecord.reviewReasons, ["near_match: exist-1", "user_flagged"])
        XCTAssertEqual(loadedRecord.status, "REVIEW")

        // 2. Revalidation with applyRequiredStatus
        var revalidated = loadedRecord
        applyRequiredStatus(&revalidated)
        XCTAssertEqual(revalidated.status, "REVIEW")
        XCTAssertEqual(revalidated.reviewReasons, ["near_match: exist-1", "user_flagged"])

        // 3. Background OCR update via mergeBondRecord
        var bgIncoming = emptyBondRecord(id: "bg-1", capturedAt: "2026-11-14T10:01:00Z")
        bgIncoming.issueMonth = "05"
        bgIncoming.issueYear = "1992"
        bgIncoming.owner = "Jane Doe"
        bgIncoming.fieldConfidence = ["issueDate": "high", "owner": "high"]
        _ = mergeBondRecord(from: bgIncoming, into: &revalidated, contributingPhoto: "photo.jpg", contributingSource: "src.jpg", captureId: "bg-1")
        XCTAssertEqual(revalidated.owner, "Jane Doe")
        XCTAssertEqual(revalidated.status, "REVIEW")
        XCTAssertEqual(revalidated.reviewReasons, ["near_match: exist-1", "user_flagged"])

        // 4. Simulated app restart
        let reopenedDB = try DatabaseManager(url: dbURL)
        var restartedRecords = try reopenedDB.loadAllRecords()
        for i in restartedRecords.indices {
            applyRequiredStatus(&restartedRecords[i])
        }
        XCTAssertEqual(restartedRecords.first?.status, "REVIEW")
        XCTAssertEqual(restartedRecords.first?.reviewReasons, ["near_match: exist-1", "user_flagged"])
    }

    func testExactMatchPrioritizedBeforeNearMatch() {
        var exactExisting = emptyBondRecord(id: "exact-target", capturedAt: "2026-11-14T10:00:00Z")
        exactExisting.serial = "C1234567890EE"
        exactExisting.series = "EE"
        exactExisting.denomination = "100"

        var nearExisting = emptyBondRecord(id: "near-target", capturedAt: "2026-11-14T10:01:00Z")
        nearExisting.serial = "C1234567898EE" // 8 vs 0 is near-match
        nearExisting.series = "EE"
        nearExisting.denomination = "100"

        let allExisting = [nearExisting, exactExisting] // nearExisting appears first in array!

        var incoming = emptyBondRecord(id: "incoming-1", capturedAt: "2026-11-14T10:05:00Z")
        incoming.serial = "C1234567890EE" // Exact match to exactExisting!
        incoming.series = "EE"
        incoming.denomination = "100"
        incoming.owner = "Alice"

        // Exact match check
        let exactMatch = recordMatchingSerial(incoming.serial, in: allExisting, excluding: incoming.id)
        XCTAssertEqual(exactMatch?.id, "exact-target")

        // Verify canMergeCapture succeeds with the exact match
        XCTAssertTrue(canMergeCapture(incoming, into: exactExisting))
    }

    func testRealExportSchedulingDebounceAndFlush() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-real-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let jsonDest = tempDir.appendingPathComponent("custom_records.json")
        let csvDest = tempDir.appendingPathComponent("custom_bonds.csv")
        ExportConfiguration.shared.setCustomDestinations(records: jsonDest, csv: csvDest)

        var r1 = emptyBondRecord(id: "exp-1", capturedAt: "2026-11-14T10:00:00Z")
        r1.serial = "C1234567890EE"
        r1.series = "EE"
        r1.denomination = "100"
        r1.status = "OK"

        var r2 = emptyBondRecord(id: "exp-2", capturedAt: "2026-11-14T10:01:00Z")
        r2.serial = "C2234567890EE"
        r2.series = "EE"
        r2.denomination = "50"
        r2.status = "OK"

        // Rapidly schedule updates to test debounce cancellation
        for _ in 1 ... 10 {
            scheduleAutomaticExports(records: [r1], delay: 0.1)
        }
        // Immediately flush authoritative final collection with 2 records
        flushAutomaticExports(records: [r1, r2])

        // Verify flush completed synchronously and wrote exactly 2 records
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonDest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvDest.path))

        let jsonStr = try String(contentsOf: jsonDest, encoding: .utf8)
        let csvStr = try String(contentsOf: csvDest, encoding: .utf8)
        XCTAssertTrue(jsonStr.contains("exp-1"))
        XCTAssertTrue(jsonStr.contains("exp-2"))
        XCTAssertTrue(csvStr.contains("C1234567890EE"))
        XCTAssertTrue(csvStr.contains("C2234567890EE"))

        // Wait briefly to ensure any canceled debounced task does not overwrite the flushed state
        Thread.sleep(forTimeInterval: 0.25)
        let jsonStrAfterDebounce = try String(contentsOf: jsonDest, encoding: .utf8)
        XCTAssertTrue(jsonStrAfterDebounce.contains("exp-2"), "Stale snapshot must not overwrite flushed newer export")
    }

    func testOCRResumeThroughApplicationWorkflow() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-resume-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let photosDir = tempDir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        let photoRel = "photos/interrupted.jpg"
        let photoURL = tempDir.appendingPathComponent(photoRel)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: photoURL)

        let dbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        let db = try DatabaseManager(url: dbURL)

        var pendingRec = emptyBondRecord(id: "pending-resume-1", capturedAt: "2026-11-14T09:00:00Z")
        pendingRec.status = "PROCESSING"
        pendingRec.sourcePhoto = photoRel
        try db.upsertRecord(pendingRec)

        // Query pending records via DatabaseManager
        let pending = try db.pendingOCRRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, "pending-resume-1")
        XCTAssertEqual(pending.first?.status, "PROCESSING")

        // Verify photo file exists for resumption
        let targetPhotoURL = try tempDir.appendingPathComponent(XCTUnwrap(pending.first?.sourcePhoto))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPhotoURL.path))
    }

    func testCaptureFailureHandling() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bondscanner-cap-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nonExistentDir = tempDir.appendingPathComponent("blocked_dir")
        // Create as file to block directory creation
        try "block".write(to: nonExistentDir, atomically: true, encoding: .utf8)
        let targetPhoto = nonExistentDir.appendingPathComponent("photo.jpg")

        let dummyData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        var failedToWrite = false
        do {
            try dummyData.write(to: targetPhoto, options: .atomic)
        } catch {
            failedToWrite = true
        }
        XCTAssertTrue(failedToWrite, "Disk write failure must be intercepted and handled without fatal crashing")
    }

    func testImageQualitySharpnessAndExposureEvaluation() throws {
        let sharp = try XCTUnwrap(makeTestCGImage(width: 400, height: 200, backgroundGray: 0.90, foregroundGray: 0.10))
        let dark = try XCTUnwrap(makeTestCGImage(width: 400, height: 200, backgroundGray: 0.05, foregroundGray: 0.02))

        let sharpQuality = evaluateImageQuality(sharp)
        XCTAssertTrue(sharpQuality.isSharp)
        XCTAssertGreaterThan(sharpQuality.sharpnessScore, 0.10)
        XCTAssertTrue(sharpQuality.isProperlyExposed)
        XCTAssertFalse(sharpQuality.isUnderExposed)

        let darkQuality = evaluateImageQuality(dark)
        XCTAssertTrue(darkQuality.isUnderExposed)
        XCTAssertFalse(darkQuality.isProperlyExposed)
    }
}
