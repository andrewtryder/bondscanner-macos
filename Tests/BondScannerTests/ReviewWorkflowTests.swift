@testable import BondScanner
import CoreGraphics
import SQLite3
import XCTest

final class ReviewWorkflowTests: XCTestCase {
    private var tempDir: URL!
    private var testDbURL: URL!
    private var testDb: DatabaseManager!

    override func setUp() {
        super.setUp()
        ScanLog.shared.isEnabled = false
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("review-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        testDbURL = tempDir.appendingPathComponent("bonds.sqlite3")
        testDb = try? DatabaseManager(url: testDbURL)
        DatabaseManager.setSharedInstance(testDb)

        ExportConfiguration.shared.setCustomDestinations(
            records: tempDir.appendingPathComponent("records.json"),
            csv: tempDir.appendingPathComponent("bonds.csv")
        )
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        ExportConfiguration.shared.resetToDefaults()
        DatabaseManager.setSharedInstance(nil)
        testDb = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
            tempDir = nil
        }
        super.tearDown()
    }

    private func makeSampleRecord(
        id: String = UUID().uuidString,
        serial: String = "C1234567890EE",
        series: String = "EE",
        denom: String = "50",
        month: String = "05",
        year: String = "1995",
        status: String = "REVIEW",
        reviewReasons: [String]? = nil
    ) -> BondRecord {
        var r = BondRecord(
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
            notes: "",
            photo: "photos/sample_\(id.prefix(8)).jpg",
            sourcePhoto: "photos/original_\(id.prefix(8)).jpg",
            rawOCR: "UNITED STATES SAVINGS BOND SERIES EE \(serial) $50",
            fieldConfidence: ["serial": "uncertain", "denomination": "high", "issueDate": "high"]
        )
        r.reviewReasons = reviewReasons
        return r
    }

    // MARK: - 1. Editing and Saving Fields

    func testEditingAndSavingFields() throws {
        let rec = makeSampleRecord(status: "REVIEW", reviewReasons: ["missing_required: serial"])
        try testDb.upsertRecord(rec)

        let coordinator = ReviewCoordinator(records: [rec])
        coordinator.selectRecord(id: rec.id)

        let updated = try coordinator.saveRecord(
            record: rec,
            userEdits: ["serial": "C9876543210EE", "owner": "Jane Smith"],
            confirmedFields: ["serial", "owner"]
        )

        XCTAssertEqual(updated.serial, "C9876543210EE")
        XCTAssertEqual(updated.owner, "Jane Smith")
        XCTAssertTrue(updated.userConfirmedFields?.contains("serial") == true)
        XCTAssertTrue(updated.userConfirmedFields?.contains("owner") == true)

        // Verify persisted in SQLite
        let loaded = try testDb.loadAllRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.serial, "C9876543210EE")
        XCTAssertEqual(loaded.first?.owner, "Jane Smith")
    }

    // MARK: - 2. Manual Field Confirmation

    func testManualFieldConfirmationSatisfiesConfidence() {
        var rec = makeSampleRecord(
            serial: "C1234567890EE",
            denom: "50",
            status: "REVIEW"
        )
        rec.fieldConfidence = ["serial": "uncertain", "denomination": "uncertain"]
        applyRequiredStatus(&rec)
        XCTAssertEqual(rec.status, "REVIEW")

        // User explicitly confirms fields without retyping
        rec.userConfirmedFields = ["serial", "denomination"]
        applyRequiredStatus(&rec)
        XCTAssertEqual(rec.status, "OK", "Explicit user confirmation satisfies required field confidence")
    }

    // MARK: - 3. Review Reason Resolution

    func testReviewReasonResolution() throws {
        let rec = makeSampleRecord(
            status: "REVIEW",
            reviewReasons: ["legacy_review: manual verification required"]
        )
        try testDb.upsertRecord(rec)

        let coordinator = ReviewCoordinator(records: [rec])
        coordinator.selectRecord(id: rec.id)

        let resolved = try coordinator.saveRecord(
            record: rec,
            userEdits: [:],
            confirmedFields: ["serial", "denomination", "issueDate"],
            resolvedReasons: ["legacy_review: manual verification required"]
        )

        XCTAssertFalse(resolved.reviewReasons?.contains("legacy_review: manual verification required") ?? false)
        XCTAssertEqual(resolved.status, "OK")
    }

    // MARK: - 4. Legacy REVIEW Records Preserved

    func testLegacyReviewRecordsPreserved() {
        var legacy = makeSampleRecord(status: "REVIEW", reviewReasons: nil)
        legacy.userConfirmedFields = nil
        // Even with high-confidence mock readings, legacy review status must not silently clear to OK
        legacy.fieldConfidence = ["serial": "high", "denomination": "high", "issueDate": "high"]

        applyRequiredStatus(&legacy)
        XCTAssertEqual(legacy.status, "REVIEW", "Legacy review records must not silently become OK without confirmation")
        XCTAssertTrue(legacy.reviewReasons?.contains(where: { $0.hasPrefix("legacy_review") }) == true)
    }

    // MARK: - 5. Save & Next Navigation

    func testSaveAndNextNavigation() throws {
        let rec1 = makeSampleRecord(id: "rec1", serial: "C1111111111EE", status: "REVIEW")
        let rec2 = makeSampleRecord(id: "rec2", serial: "C2222222222EE", status: "REVIEW")
        let rec3 = makeSampleRecord(id: "rec3", serial: "C3333333333EE", status: "OK")

        try testDb.upsertRecords([rec1, rec2, rec3])

        let coordinator = ReviewCoordinator(records: [rec1, rec2, rec3])
        coordinator.selectRecord(id: "rec1")

        XCTAssertEqual(coordinator.currentRecordId, "rec1")
        XCTAssertEqual(coordinator.progress.remainingCount, 2)

        // Save & Next on rec1
        let next = try coordinator.saveAndNext(
            record: rec1,
            userEdits: ["serial": "C1111111111EE"],
            confirmedFields: ["serial", "denomination", "issueDate"],
            resolvedReasons: ["legacy_review: manual verification required"]
        )

        XCTAssertEqual(next?.id, "rec2", "Save & Next automatically selects next unresolved record")
        XCTAssertEqual(coordinator.currentRecordId, "rec2")
        XCTAssertEqual(coordinator.progress.reviewedInSession, 1)
    }

    // MARK: - 6. Selection Stability During Asynchronous Updates

    func testSelectionStabilityDuringAsynchronousUpdates() throws {
        let recA = makeSampleRecord(id: "recA", serial: "C1111111111EE")
        let recB = makeSampleRecord(id: "recB", serial: "C2222222222EE")
        try testDb.upsertRecords([recA, recB])

        let coordinator = ReviewCoordinator(records: [recA, recB])
        coordinator.selectRecord(id: "recB")
        XCTAssertEqual(coordinator.currentRecordId, "recB")

        // Simulate asynchronous background OCR completing a new scan recC
        let recC = makeSampleRecord(id: "recC", serial: "C3333333333EE")
        coordinator.setAllRecords([recA, recB, recC])

        XCTAssertEqual(coordinator.currentRecordId, "recB", "Selection must remain on recB despite background updates")
    }

    // MARK: - 7. Validation After Field Edits

    func testValidationAfterFieldEdits() {
        var rec = makeSampleRecord(serial: "C12345678E", series: "E", denom: "100", month: "05", year: "1995")
        let reportInvalid = BondValidationRules.validateBond(record: rec)
        XCTAssertFalse(reportInvalid.seriesDateConsistency.status == .consistent)
        XCTAssertTrue(reportInvalid.hardErrors.contains(where: { $0.contains("discontinued") }))

        // Correct year to valid Series E year
        rec.issueYear = "1975"
        let reportValid = BondValidationRules.validateBond(record: rec)
        XCTAssertEqual(reportValid.seriesDateConsistency.status, .consistent)
        XCTAssertTrue(reportValid.hardErrors.isEmpty)
    }

    // MARK: - 8. Duplicate Keep Separate

    func testDuplicateKeepSeparate() throws {
        let rec1 = makeSampleRecord(id: "rec1", serial: "C1234567890EE", status: "REVIEW")
        let rec2 = makeSampleRecord(id: "rec2", serial: "C123456789OEE", status: "REVIEW")
        try testDb.upsertRecords([rec1, rec2])

        let coordinator = ReviewCoordinator(records: [rec1, rec2])
        try coordinator.keepSeparate(record: rec1, candidate: rec2)

        let loaded = try testDb.loadAllRecords()
        XCTAssertEqual(loaded.count, 2, "Both records must be preserved when kept separate")

        let r1 = loaded.first(where: { $0.id == "rec1" })
        let r2 = loaded.first(where: { $0.id == "rec2" })
        XCTAssertTrue(r1?.resolvedReviewReasons?.contains("near_match") == true)
        XCTAssertTrue(r2?.resolvedReviewReasons?.contains("near_match") == true)
    }

    // MARK: - 9. Duplicate Consolidation Atomic Merge

    func testDuplicateConsolidationAtomicMerge() throws {
        var primary = makeSampleRecord(id: "prim", serial: "C1234567890EE", status: "REVIEW")
        primary.photo = "photos/photo_prim.jpg"
        primary.sourcePhoto = "photos/orig_prim.jpg"
        primary.userConfirmedFields = ["serial"]

        var duplicate = makeSampleRecord(id: "dup", serial: "C123456789OEE", status: "REVIEW")
        duplicate.photo = "photos/photo_dup.jpg"
        duplicate.sourcePhoto = "photos/orig_dup.jpg"
        duplicate.userConfirmedFields = ["owner"]

        try testDb.upsertRecords([primary, duplicate])

        let coordinator = ReviewCoordinator(records: [primary, duplicate])
        let merged = try coordinator.confirmSameBond(
            primary: primary,
            duplicate: duplicate,
            preferredEdits: ["owner": "John Merged"]
        )

        // Verify duplicate was removed and primary consolidated
        let loaded = try testDb.loadAllRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "prim")
        XCTAssertEqual(loaded.first?.owner, "John Merged")

        // Verify both photos are durably preserved
        XCTAssertTrue(merged.associatedPhotos?.contains("photos/photo_dup.jpg") == true)
        XCTAssertTrue(merged.associatedPhotos?.contains("photos/orig_dup.jpg") == true)

        // Verify union of user confirmed fields
        XCTAssertTrue(merged.userConfirmedFields?.contains("serial") == true)
        XCTAssertTrue(merged.userConfirmedFields?.contains("owner") == true)
    }

    // MARK: - 10. Atomic Merge Failure and Rollback

    func testAtomicMergeFailureAndRollback() throws {
        let primary = makeSampleRecord(id: "p1", serial: "C1234567890EE")
        let duplicate = makeSampleRecord(id: "d1", serial: "C123456789OEE")
        let testRollbackURL = tempDir.appendingPathComponent("rollback_test.sqlite3")
        let rollbackDb = try DatabaseManager(url: testRollbackURL)
        try rollbackDb.upsertRecords([primary, duplicate])
        XCTAssertEqual(try rollbackDb.count(), 2)

        // Enable query_only to simulate write failure mid-transaction
        try rollbackDb.execute("PRAGMA query_only = ON;")
        XCTAssertThrowsError(try rollbackDb.atomicMerge(deleteId: "d1", updatedRecord: primary)) { error in
            XCTAssertNotNil(error)
        }

        // Disable query_only and verify database was rolled back and still contains both records
        try rollbackDb.execute("PRAGMA query_only = OFF;")
        let loaded = try rollbackDb.loadAllRecords()
        XCTAssertEqual(loaded.count, 2, "Failed atomic merge must roll back completely without deleting records")
    }

    // MARK: - 11. Database Persistence Across Restart

    func testDatabasePersistenceAcrossRestart() throws {
        let rec = makeSampleRecord(id: "persist1", serial: "C5555555555EE", status: "REVIEW")
        try testDb.upsertRecord(rec)

        let coordinator = ReviewCoordinator(records: [rec])
        try coordinator.saveRecord(
            record: rec,
            userEdits: ["serial": "C7777777777EE"],
            confirmedFields: ["serial"]
        )

        // Simulate application restart: open fresh DatabaseManager instance on same file
        let newDbInstance = try DatabaseManager(url: testDbURL)
        let loaded = try newDbInstance.loadAllRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.serial, "C7777777777EE")
        XCTAssertTrue(loaded.first?.userConfirmedFields?.contains("serial") == true)
    }

    // MARK: - 12. Export Freshness After Review Changes

    func testExportFreshnessAfterReviewChanges() throws {
        let rec = makeSampleRecord(id: "exp1", serial: "C9999999999EE", status: "REVIEW")
        try testDb.upsertRecord(rec)

        let coordinator = ReviewCoordinator(records: [rec])
        _ = try coordinator.saveRecord(
            record: rec,
            userEdits: ["owner": "Verified Owner Name"],
            confirmedFields: ["owner"]
        )

        // Flush export to disk
        ExportCoordinator.shared.flush(records: coordinator.allRecords)

        let csvURL = tempDir.appendingPathComponent("bonds.csv")
        let csvContent = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csvContent.contains("Verified Owner Name"), "CSV export must contain freshly saved edits")
    }

    // MARK: - 13. Stalled Processing Recovery

    func testStalledProcessingRecovery() throws {
        let stalled = makeSampleRecord(id: "stall1", status: "PROCESSING")
        try testDb.upsertRecord(stalled)

        let coordinator = ReviewCoordinator(records: [stalled])
        let recovered = try coordinator.recoverStalledProcessing(record: stalled)

        XCTAssertEqual(recovered.status, "REVIEW")
        XCTAssertTrue(recovered.reviewReasons?.contains(where: { $0.contains("stalled_processing") }) == true)
    }
}
