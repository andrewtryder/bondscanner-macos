import AppKit
@testable import BondScanner
import CoreGraphics
import SQLite3
import XCTest

final class ReviewWorkflowTests: XCTestCase {
    private actor SuspendedAI: BondAIAnalyzing {
        private var continuations: [String: CheckedContinuation<BondAIAnalysis, Never>] = [:]

        func analyze(record: BondRecord, imageURL: URL) async -> BondAIAnalysis {
            await withCheckedContinuation { continuation in
                continuations[record.id] = continuation
            }
        }

        func hasStarted(_ id: String) -> Bool {
            continuations[id] != nil
        }

        func resume(_ record: BondRecord, status: BondAIAnalysis.Status = .ready) {
            guard let continuation = continuations.removeValue(forKey: record.id) else { return }
            continuation.resume(returning: BondAIAnalysis(
                recordID: record.id, recordRevision: record.revision ?? 0,
                analyzedAt: Date(), runtime: "suspended-test",
                promptVersion: BondAIAnalysis.currentPromptVersion, status: status,
                suggestions: [], summary: "Controlled test result", failureKind: nil
            ))
        }
    }

    private struct SuggestingAI: BondAIAnalyzing {
        func analyze(record: BondRecord, imageURL: URL) async -> BondAIAnalysis {
            BondAIAnalysis(recordID: record.id, recordRevision: record.revision ?? 0, analyzedAt: Date(), runtime: "test", promptVersion: BondAIAnalysis.currentPromptVersion, status: .ready, suggestions: [BondAISuggestion(field: "serial", existingValue: record.serial, proposedValue: "C1234567890EE", abstained: false, evidence: "synthetic", imageRegion: nil, ambiguity: "test", assessment: .conflictingEvidence, requiresOriginalInspection: true)], summary: "Synthetic result", failureKind: nil)
        }
    }

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
        UserDefaults.standard.removeObject(forKey: "bondAIReviewQueue")
        UserDefaults.standard.removeObject(forKey: "bondAIReviewPaused")

        ExportConfiguration.shared.setCustomDestinations(
            records: tempDir.appendingPathComponent("records.json"),
            csv: tempDir.appendingPathComponent("bonds.csv")
        )
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        ExportConfiguration.shared.resetToDefaults()
        DatabaseManager.setSharedInstance(nil)
        UserDefaults.standard.removeObject(forKey: "bondAIReviewQueue")
        UserDefaults.standard.removeObject(forKey: "bondAIReviewPaused")
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

    func testAIReviewPersistsSuggestionsSeparatelyFromBondFields() async throws {
        var rec = makeSampleRecord(serial: "C123456789OEE", status: "REVIEW")
        rec.revision = 7
        let imageURL = tempDir.appendingPathComponent(rec.sourcePhoto)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: imageURL)
        try testDb.upsertRecord(rec)

        let coordinator = ReviewCoordinator(records: [rec], outputRoot: tempDir, aiAnalyzer: SuggestingAI())
        coordinator.enqueueAIReview(recordID: rec.id)
        try await Task.sleep(for: .milliseconds(150))

        let updated = try XCTUnwrap(coordinator.allRecords.first)
        XCTAssertEqual(updated.serial, "C123456789OEE", "AI must never overwrite a bond field")
        XCTAssertEqual(updated.aiAnalysis?.recordRevision, 7)
        XCTAssertEqual(updated.aiAnalysis?.suggestions.first?.proposedValue, "C1234567890EE")
    }

    func testSuspendedAIAdvancesAfterRecordIsDeletedDuringInference() async throws {
        var first = makeSampleRecord(id: "first", status: "REVIEW")
        var second = makeSampleRecord(id: "second", status: "REVIEW")
        first.revision = 3; second.revision = 4
        for record in [first, second] {
            let imageURL = tempDir.appendingPathComponent(record.sourcePhoto)
            try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: imageURL)
            try testDb.upsertRecord(record)
        }
        let analyzer = SuspendedAI()
        let coordinator = ReviewCoordinator(records: [first, second], outputRoot: tempDir, aiAnalyzer: analyzer)
        coordinator.enqueueAIReview(recordID: first.id)
        coordinator.enqueueAIReview(recordID: second.id)
        for _ in 0 ..< 50 where !(await analyzer.hasStarted(first.id)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstStarted = await analyzer.hasStarted(first.id)
        XCTAssertTrue(firstStarted)

        coordinator.setAllRecords([second]) // simulates a merge/delete while inference is suspended
        await analyzer.resume(first)
        for _ in 0 ..< 50 where !(await analyzer.hasStarted(second.id)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondStarted = await analyzer.hasStarted(second.id)
        XCTAssertTrue(secondStarted, "Deleted work must always release the queue")
        await analyzer.resume(second)
        for _ in 0 ..< 50 where coordinator.allRecords.first?.aiAnalysis == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.allRecords.first?.aiAnalysis?.recordRevision, second.revision)
    }

    func testSuspendedAIRejectsRevisionChangedDuringInference() async throws {
        var record = makeSampleRecord(status: "REVIEW")
        record.revision = 10
        let imageURL = tempDir.appendingPathComponent(record.sourcePhoto)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: imageURL)
        try testDb.upsertRecord(record)
        let analyzer = SuspendedAI()
        let coordinator = ReviewCoordinator(records: [record], outputRoot: tempDir, aiAnalyzer: analyzer)
        coordinator.enqueueAIReview(recordID: record.id)
        for _ in 0 ..< 50 where !(await analyzer.hasStarted(record.id)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try coordinator.saveRecord(record: record, userEdits: ["owner": "Changed while AI ran"], confirmedFields: ["owner"])
        await analyzer.resume(record)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(coordinator.allRecords.first?.aiAnalysis, "Stale AI output must not publish")
        XCTAssertEqual(coordinator.allRecords.first?.owner, "Changed while AI ran")
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

        // Verifyrecovered status and review reason
        XCTAssertEqual(recovered.status, "REVIEW")
        XCTAssertTrue(recovered.reviewReasons?.contains(where: { $0.contains("stalled_processing") }) == true)
    }

    // MARK: - 14. Unsaved Draft Survives Unrelated OCR Completion & Detects Concurrent Conflict

    func testUnsavedDraftSurvivesUnrelatedOCRCompletion() throws {
        let recA = makeSampleRecord(id: "recA", serial: "C1111111111EE", status: "REVIEW")
        let recB = makeSampleRecord(id: "recB", serial: "C2222222222EE", status: "REVIEW")
        try testDb.upsertRecords([recA, recB])

        let coordinator = ReviewCoordinator(records: [recA, recB], outputRoot: tempDir)
        let controller = ReviewWindowController(coordinator: coordinator)
        controller.suppressModalAlerts = true
        coordinator.selectRecord(id: "recA")

        // User makes an unsaved edit to recA in the editor
        controller.editorView.applyFieldEdit(field: "owner", value: "Unsaved Draft Owner")
        controller.editorView.applyFieldEdit(field: "serial", value: "C9999999999EE")
        XCTAssertTrue(controller.editorView.hasUnsavedChanges)
        XCTAssertEqual(controller.editorView.activeDraft?.recordId, "recA")

        // Unrelated background OCR completes for recB and a new scan recC arrives
        var updatedB = recB
        updatedB.owner = "Background Scanned Owner B"
        updatedB.status = "OK"
        let recC = makeSampleRecord(id: "recC", serial: "C3333333333EE", status: "REVIEW")

        coordinator.setAllRecords([recA, updatedB, recC])

        // Verify unsaved draft on recA is completely intact
        XCTAssertEqual(coordinator.currentRecordId, "recA")
        XCTAssertTrue(controller.editorView.hasUnsavedChanges)
        XCTAssertEqual(controller.editorView.pendingEdits["owner"], "Unsaved Draft Owner")
        XCTAssertEqual(controller.editorView.pendingEdits["serial"], "C9999999999EE")
        XCTAssertEqual(controller.editorView.textField(forKey: "owner")?.stringValue, "Unsaved Draft Owner")
        XCTAssertEqual(controller.editorView.textField(forKey: "serial")?.stringValue, "C9999999999EE")
        XCTAssertFalse(controller.editorView.isShowingConflictBanner)

        // Now simulate a genuine concurrent external edit to the SELECTED record (recA)
        var externallyModifiedA = recA
        externallyModifiedA.owner = "External Concurrent Owner"
        externallyModifiedA.revision = 2
        coordinator.setAllRecords([externallyModifiedA, updatedB, recC])

        // Draft values must NOT be silently overwritten; conflict banner is shown for non-destructive resolution
        XCTAssertEqual(controller.editorView.textField(forKey: "owner")?.stringValue, "Unsaved Draft Owner")
        XCTAssertEqual(controller.editorView.pendingEdits["owner"], "Unsaved Draft Owner")
        XCTAssertTrue(controller.editorView.isShowingConflictBanner, "Genuine concurrent edit to selected record must surface conflict banner")
    }

    // MARK: - 15. Unsaved Draft Survives Review Queue Refresh

    func testUnsavedDraftSurvivesReviewQueueRefresh() throws {
        let rec1 = makeSampleRecord(id: "rec1", serial: "C1111111111EE", status: "REVIEW", reviewReasons: ["missing_required: serial"])
        let rec2 = makeSampleRecord(id: "rec2", serial: "C2222222222EE", status: "REVIEW", reviewReasons: ["near_match: rec1"])
        try testDb.upsertRecords([rec1, rec2])

        let coordinator = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        let controller = ReviewWindowController(coordinator: coordinator)
        controller.suppressModalAlerts = true
        coordinator.selectRecord(id: "rec1")

        controller.editorView.applyFieldEdit(field: "address", value: "742 Evergreen Terrace")
        XCTAssertTrue(controller.editorView.hasUnsavedChanges)

        // Trigger queue filter & progress refreshes while rec1 remains in the queue
        coordinator.activeFilter = .missingSerial
        XCTAssertEqual(coordinator.currentRecordId, "rec1")
        XCTAssertTrue(controller.editorView.hasUnsavedChanges)
        XCTAssertEqual(controller.editorView.pendingEdits["address"], "742 Evergreen Terrace")
        XCTAssertEqual(controller.editorView.textField(forKey: "address")?.stringValue, "742 Evergreen Terrace")

        coordinator.activeFilter = .allReview
        XCTAssertEqual(coordinator.currentRecordId, "rec1")
        XCTAssertEqual(controller.editorView.pendingEdits["address"], "742 Evergreen Terrace")
    }

    // MARK: - 16. Failed Save Prevents Navigation and Window Closure

    func testFailedSavePreventsNavigationAndWindowClosure() throws {
        let rec1 = makeSampleRecord(id: "rec1", serial: "C1111111111EE", status: "REVIEW")
        let rec2 = makeSampleRecord(id: "rec2", serial: "C2222222222EE", status: "REVIEW")
        try testDb.upsertRecords([rec1, rec2])

        let coordinator = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        let controller = ReviewWindowController(coordinator: coordinator)
        controller.suppressModalAlerts = true
        // When prompted about unsaved changes, simulate user clicking "Save Changes"
        controller.unsavedChangesPromptHandler = { .alertFirstButtonReturn }

        coordinator.selectRecord(id: "rec1")
        controller.editorView.applyFieldEdit(field: "owner", value: "Draft That Fails To Save")

        // Force SQLite database into query_only mode so persistence fails
        try testDb.execute("PRAGMA query_only = ON;")
        defer { try? testDb.execute("PRAGMA query_only = OFF;") }

        // 1. Direct Save & Next must fail and NOT navigate to rec2
        let saveAndNextSucceeded = controller.reviewEditorDidRequestSave(controller.editorView, andNext: true)
        XCTAssertFalse(saveAndNextSucceeded)
        XCTAssertEqual(coordinator.currentRecordId, "rec1", "Must not navigate away after a failed Save & Next")
        XCTAssertEqual(controller.editorView.pendingEdits["owner"], "Draft That Fails To Save", "Draft content must be preserved after save error")
        XCTAssertEqual(coordinator.allRecords.first(where: { $0.id == "rec1" })?.owner, "John Doe", "In-memory collection must not be mutated when DB persistence fails")

        // 2. Requesting Next (which prompts to save unsaved changes) must NOT advance when save fails
        controller.reviewEditorDidRequestNext(controller.editorView)
        XCTAssertEqual(coordinator.currentRecordId, "rec1", "Next navigation must be blocked when save fails")

        // 3. Attempting to close the window must return false when save fails
        let shouldClose = try controller.windowShouldClose(XCTUnwrap(controller.window))
        XCTAssertFalse(shouldClose, "Window must not close when saving unsaved changes fails")
        XCTAssertTrue(controller.editorView.hasUnsavedChanges)
    }

    // MARK: - 17. Save & Next Traversal With Unresolved and Resolved Records

    func testSaveAndNextTraversalWithUnresolvedAndResolvedRecords() throws {
        let rec1 = makeSampleRecord(id: "rec1", serial: "C1111111111EE", status: "REVIEW", reviewReasons: ["legacy_review: manual verification required"])
        let rec2 = makeSampleRecord(id: "rec2", serial: "C2222222222EE", status: "REVIEW", reviewReasons: ["legacy_review: manual verification required"])
        let rec3 = makeSampleRecord(id: "rec3", serial: "C3333333333EE", status: "REVIEW", reviewReasons: ["legacy_review: manual verification required"])
        try testDb.upsertRecords([rec1, rec2, rec3])

        let coordinator = ReviewCoordinator(records: [rec1, rec2, rec3], outputRoot: tempDir)
        let controller = ReviewWindowController(coordinator: coordinator)
        controller.suppressModalAlerts = true

        // Start at rec1, skip forward to rec2 without resolving rec1
        coordinator.selectRecord(id: "rec1")
        _ = coordinator.nextRecord()
        XCTAssertEqual(coordinator.currentRecordId, "rec2")

        // Resolve rec2 via Save & Next: must advance forward to rec3 (NOT jump back to index 0 / rec1!)
        controller.editorView.confirmCurrentOrAllValidFields()
        let savedRec2 = try coordinator.saveAndNext(
            record: rec2,
            userEdits: [:],
            confirmedFields: ["serial", "denomination", "issueDate"],
            resolvedReasons: ["legacy_review: manual verification required"]
        )
        XCTAssertEqual(savedRec2?.id, "rec3", "Save & Next from rec2 must move forward to rec3 instead of restarting at rec1")
        XCTAssertEqual(coordinator.currentRecordId, "rec3")

        // Resolve rec3 via Save & Next: since rec1 is still unresolved earlier in the queue, it wraps to rec1
        let savedRec3 = try coordinator.saveAndNext(
            record: rec3,
            userEdits: [:],
            confirmedFields: ["serial", "denomination", "issueDate"],
            resolvedReasons: ["legacy_review: manual verification required"]
        )
        XCTAssertEqual(savedRec3?.id, "rec1", "After reaching end of queue, Save & Next wraps to remaining unresolved rec1")

        // Resolve final unresolved record rec1 via controller Save & Next -> triggers end-of-queue completion state
        if let rec1Latest = coordinator.currentRecord {
            controller.editorView.setRecord(rec1Latest, progress: coordinator.progress)
        }
        controller.editorView.confirmCurrentOrAllValidFields()
        controller.editorView.markReasonResolved("legacy_review: manual verification required")
        let finalSaveSuccess = controller.reviewEditorDidRequestSave(controller.editorView, andNext: true)
        XCTAssertTrue(finalSaveSuccess)
        XCTAssertTrue(controller.editorView.isShowingQueueCompleted, "End-of-queue completion banner must appear when all queue items are resolved")
        XCTAssertEqual(coordinator.progress.remainingCount, 0)
    }

    // MARK: - 18. Keep Separate Clears Specific Near-Match Reasons & Prevents Re-Flagging

    func testKeepSeparateClearsSpecificNearMatchReasons() throws {
        var rec1 = makeSampleRecord(
            id: "cand-alpha-1111",
            serial: "C1234567890EE",
            status: "REVIEW",
            reviewReasons: ["near_match: cand-beta-2222"]
        )
        rec1.fieldConfidence = ["serial": "high", "denomination": "high", "issueDate": "high"]

        var rec2 = makeSampleRecord(
            id: "cand-beta-2222",
            serial: "C1234567898EE",
            status: "REVIEW",
            reviewReasons: ["near_match: cand-alpha-1111"]
        )
        rec2.fieldConfidence = ["serial": "high", "denomination": "high", "issueDate": "high"]

        try testDb.upsertRecords([rec1, rec2])

        let coordinator = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        coordinator.selectRecord(id: rec1.id)
        XCTAssertEqual(coordinator.findDuplicateCandidate(for: rec1)?.id, rec2.id)

        // Execute Keep Separate
        try coordinator.keepSeparate(record: rec1, candidate: rec2)

        let updated1 = try XCTUnwrap(coordinator.allRecords.first(where: { $0.id == rec1.id }))
        let updated2 = try XCTUnwrap(coordinator.allRecords.first(where: { $0.id == rec2.id }))

        // Specific near_match: <id> reasons must be cleared and status promoted to OK
        XCTAssertFalse(updated1.reviewReasons?.contains(where: { $0.hasPrefix("near_match") }) ?? false)
        XCTAssertFalse(updated2.reviewReasons?.contains(where: { $0.hasPrefix("near_match") }) ?? false)
        XCTAssertEqual(updated1.status, "OK")
        XCTAssertEqual(updated2.status, "OK")

        // Pair decision must be persisted
        XCTAssertTrue(updated1.resolvedReviewReasons?.contains("keep_separate: \(rec2.id)") == true)
        XCTAssertTrue(updated2.resolvedReviewReasons?.contains("keep_separate: \(rec1.id)") == true)

        // Previously resolved pair must NOT be repeatedly flagged by findNearMatchRecord or findDuplicateCandidate
        XCTAssertNil(findNearMatchRecord(updated1, in: [updated1, updated2], excluding: updated1.id))
        XCTAssertNil(findNearMatchRecord(updated2, in: [updated1, updated2], excluding: updated2.id))
        XCTAssertNil(coordinator.findDuplicateCandidate(for: updated1))
    }

    // MARK: - 19. Keep Separate Rollback on Second Record Update Failing

    func testKeepSeparateRollbackOnSecondRecordUpdateFailing() throws {
        let rec1 = makeSampleRecord(
            id: "ks-rec-1",
            serial: "C1234567890EE",
            status: "REVIEW",
            reviewReasons: ["near_match: ks-rec-2"]
        )
        let rec2 = makeSampleRecord(
            id: "ks-rec-2",
            serial: "C1234567898EE",
            status: "REVIEW",
            reviewReasons: ["near_match: ks-rec-1"]
        )
        try testDb.upsertRecords([rec1, rec2])

        // Install a SQLite trigger that aborts when updating the second record (ks-rec-2)
        let triggerSQL = """
        CREATE TRIGGER abort_on_second_record BEFORE INSERT ON bonds
        WHEN NEW.id = 'ks-rec-2'
        BEGIN
            SELECT RAISE(ABORT, 'simulated failure on second record in Keep Separate');
        END;
        """
        var rawHandle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(testDbURL.path, &rawHandle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(rawHandle, triggerSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(rawHandle)

        let coordinator = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        XCTAssertThrowsError(try coordinator.keepSeparate(record: rec1, candidate: rec2))

        // Verify transactional rollback: neither rec1 nor rec2 was modified in SQLite or in memory
        let loaded = try testDb.loadAllRecords()
        let dbRec1 = try XCTUnwrap(loaded.first(where: { $0.id == "ks-rec-1" }))
        let dbRec2 = try XCTUnwrap(loaded.first(where: { $0.id == "ks-rec-2" }))

        XCTAssertNil(dbRec1.resolvedReviewReasons, "First record update must roll back when second record update fails")
        XCTAssertNil(dbRec2.resolvedReviewReasons)
        XCTAssertEqual(dbRec1.reviewReasons, ["near_match: ks-rec-2"])
        XCTAssertEqual(dbRec2.reviewReasons, ["near_match: ks-rec-1"])

        let memRec1 = try XCTUnwrap(coordinator.allRecords.first(where: { $0.id == "ks-rec-1" }))
        XCTAssertNil(memRec1.resolvedReviewReasons, "In-memory state must remain untouched on failed Keep Separate transaction")
    }

    // MARK: - 20. Duplicate Merge With Conflicting Confirmed Values

    func testDuplicateMergeWithConflictingConfirmedValues() throws {
        var primary = makeSampleRecord(id: "merge-prim", serial: "C1234567890EE", status: "REVIEW")
        primary.owner = "Alice Confirmed"
        primary.address = "100 Primary Ave"
        primary.photo = "photos/prim_rect.jpg"
        primary.sourcePhoto = "photos/prim_orig.jpg"
        primary.associatedPhotos = ["photos/prim_extra.jpg"]
        primary.userConfirmedFields = ["serial", "owner", "address"]

        var duplicate = makeSampleRecord(id: "merge-dup", serial: "C1234567890EE", status: "REVIEW")
        duplicate.owner = "Bob Confirmed" // Conflicts with primary's confirmed owner!
        duplicate.address = "200 Duplicate Blvd" // Unconfirmed on duplicate
        duplicate.secondName = "Charlie CoOwner" // Confirmed on duplicate, empty on primary
        duplicate.photo = "photos/dup_rect.jpg"
        duplicate.sourcePhoto = "photos/dup_orig.jpg"
        duplicate.associatedPhotos = ["photos/dup_extra.jpg"]
        duplicate.userConfirmedFields = ["owner", "secondName"]

        try testDb.upsertRecords([primary, duplicate])
        let coordinator = ReviewCoordinator(records: [primary, duplicate], outputRoot: tempDir)

        // 1. Attempting merge without resolving the conflicting confirmed 'owner' field must throw
        XCTAssertThrowsError(try coordinator.confirmSameBond(primary: primary, duplicate: duplicate, preferredEdits: [:])) { error in
            guard case let ReviewError.conflictingConfirmedValues(field, pVal, cVal) = error else {
                XCTFail("Expected conflictingConfirmedValues error, got \(error)")
                return
            }
            XCTAssertEqual(field, "owner")
            XCTAssertEqual(pVal, "Alice Confirmed")
            XCTAssertEqual(cVal, "Bob Confirmed")
        }

        // 2. Resolving the conflict explicitly succeeds, retains confirmed status only for retained/selected values, and preserves all photos
        let merged = try coordinator.confirmSameBond(
            primary: primary,
            duplicate: duplicate,
            preferredEdits: ["owner": "Bob Confirmed"]
        )

        XCTAssertEqual(merged.owner, "Bob Confirmed")
        XCTAssertEqual(merged.address, "100 Primary Ave")
        XCTAssertEqual(merged.secondName, "Charlie CoOwner")

        let confirmed = Set(merged.userConfirmedFields ?? [])
        XCTAssertTrue(confirmed.contains("serial"), "Retained primary confirmed field stays confirmed")
        XCTAssertTrue(confirmed.contains("owner"), "Explicitly resolved field is confirmed")
        XCTAssertTrue(confirmed.contains("address"), "Retained primary confirmed address stays confirmed")
        XCTAssertTrue(confirmed.contains("secondName"), "Inherited confirmed field from duplicate (where primary was empty) stays confirmed")

        // Verify all associated photos from both records are preserved
        let allPreservedPhotos = Set([merged.photo, merged.sourcePhoto] + (merged.associatedPhotos ?? []))
        XCTAssertTrue(allPreservedPhotos.contains("photos/prim_rect.jpg"))
        XCTAssertTrue(allPreservedPhotos.contains("photos/prim_orig.jpg"))
        XCTAssertTrue(allPreservedPhotos.contains("photos/prim_extra.jpg"))
        XCTAssertTrue(allPreservedPhotos.contains("photos/dup_rect.jpg"))
        XCTAssertTrue(allPreservedPhotos.contains("photos/dup_orig.jpg"))
        XCTAssertTrue(allPreservedPhotos.contains("photos/dup_extra.jpg"))
    }

    // MARK: - 21. OCR Reprocess Finishing After a Manual Edit

    @MainActor
    func testOCRReprocessFinishingAfterManualEdit() async throws {
        // Create a valid synthetic image file on disk for reprocessing
        let photosDir = tempDir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let photoRel = "photos/reprocess_sample.png"
        let photoURL = tempDir.appendingPathComponent(photoRel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: 600,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        let cgImg = try XCTUnwrap(ctx.makeImage())
        let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: 600, height: 300))
        let tiffData = try XCTUnwrap(nsImg.tiffRepresentation)
        let bmp = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bmp.representation(using: .png, properties: [:]))
        try pngData.write(to: photoURL)

        var rec1 = makeSampleRecord(id: "reproc-1", serial: "C1234567890EE", status: "REVIEW")
        rec1.photo = photoRel
        rec1.sourcePhoto = photoRel
        rec1.owner = "Original OCR Owner"
        rec1.userConfirmedFields = ["serial"]
        rec1.revision = 1

        let rec2 = makeSampleRecord(id: "reproc-2", serial: "C2222222222EE", status: "REVIEW")
        try testDb.upsertRecords([rec1, rec2])

        let coordinator = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        let controller = ReviewWindowController(coordinator: coordinator)
        controller.suppressModalAlerts = true
        coordinator.selectRecord(id: "reproc-1")

        // User edits owner in the active draft and also saves an intermediate update to rec1 while OCR is running
        controller.editorView.applyFieldEdit(field: "owner", value: "Manual Draft Owner Edit")
        _ = try coordinator.saveRecord(
            record: rec1,
            userEdits: ["address": "Persisted Mid-Flight Address"],
            confirmedFields: ["serial", "address"]
        )

        // User switches selection to rec2 before reprocess finishes
        coordinator.selectRecord(id: "reproc-2")
        XCTAssertEqual(coordinator.currentRecordId, "reproc-2")

        // Finish reprocessing rec1 with active user edits passed
        let result = try await coordinator.reprocessPhoto(
            for: rec1,
            userActiveEdits: ["owner": "Manual Draft Owner Edit"]
        )

        // 1. Selection must remain on rec2 (never hijacked back to rec1)
        XCTAssertEqual(coordinator.currentRecordId, "reproc-2", "Completed OCR reprocess must not hijack selection away from current record")

        // 2. Persisted mid-flight edit ('address') and confirmed 'serial' on latest record must be preserved
        XCTAssertEqual(result.updated.address, "Persisted Mid-Flight Address")
        XCTAssertEqual(result.updated.serial, "C1234567890EE")
        XCTAssertGreaterThanOrEqual(result.updated.revision ?? 0, 3)
    }

    // MARK: - 22. Shortcut Routing With an Active Text Field

    func testShortcutRoutingWithActiveTextField() throws {
        var rec1 = makeSampleRecord(id: "short-1", serial: "C1111111111EE", status: "REVIEW")
        rec1.fieldConfidence = ["serial": "uncertain", "denomination": "high", "issueDate": "high"]
        let rec2 = makeSampleRecord(id: "short-2", serial: "C2222222222EE", status: "REVIEW")
        try testDb.upsertRecords([rec1, rec2])

        let coordinator = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        let controller = ReviewWindowController(coordinator: coordinator)
        controller.suppressModalAlerts = true
        controller.showReviewWindow(selectingRecordId: "short-1")

        // Give photoView two synthetic images so Toggle Photo, Rotate, and Zoom can be verified
        let dummyImg = NSImage(size: NSSize(width: 400, height: 200))
        controller.photoView.setImages(original: dummyImg, processed: dummyImg)

        let window = try XCTUnwrap(controller.window)
        let serialField = try XCTUnwrap(controller.editorView.textField(forKey: "serial"))
        _ = window.makeFirstResponder(serialField)

        func keyEvent(_ chars: String, keyCode: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        // 1. ⌘K (Confirm Field) while serialField is focused
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("k")))
        XCTAssertTrue(controller.editorView.pendingConfirmedFields.contains("serial"), "⌘K must confirm the focused text field")

        // 2. ⌘T (Toggle Photo)
        XCTAssertFalse(controller.photoView.showingProcessed)
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("t")))
        XCTAssertTrue(controller.photoView.showingProcessed, "⌘T must toggle between original and processed photo")

        // 3. ⌘R (Rotate Clockwise)
        XCTAssertEqual(controller.photoView.rotationQuarterTurns, 0)
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("r")))
        XCTAssertEqual(controller.photoView.rotationQuarterTurns, 1, "⌘R must rotate photo 90 degrees clockwise")

        // 4. ⌘=, ⌘-, ⌘0 (Zoom In, Out, Fit)
        let initialZoom = controller.photoView.currentZoomScale
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("=")))
        let zoomedIn = controller.photoView.currentZoomScale
        XCTAssertGreaterThan(zoomedIn, initialZoom, "⌘= must zoom in")
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("-")))
        XCTAssertLessThan(controller.photoView.currentZoomScale, zoomedIn, "⌘- must zoom out")
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("0")))

        // 5. ⌘S (Save) while text field is active
        controller.editorView.applyFieldEdit(field: "owner", value: "Keyboard Saved Owner")
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("s")))
        XCTAssertFalse(controller.editorView.hasUnsavedChanges, "⌘S must save active draft")
        XCTAssertEqual(coordinator.allRecords.first(where: { $0.id == "short-1" })?.owner, "Keyboard Saved Owner")

        // 6. ⌘] (Next) and ⌘[ (Previous)
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("]")))
        XCTAssertEqual(coordinator.currentRecordId, "short-2", "⌘] must navigate to next record")
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("[")))
        XCTAssertEqual(coordinator.currentRecordId, "short-1", "⌘[ must navigate to previous record")

        // 7. ⌘⏎ (Save & Next)
        controller.editorView.applyFieldEdit(field: "owner", value: "Save And Next Owner")
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("\r", keyCode: 36)))
        XCTAssertEqual(coordinator.currentRecordId, "short-2", "⌘⏎ must save current record and advance")
        XCTAssertEqual(coordinator.allRecords.first(where: { $0.id == "short-1" })?.owner, "Save And Next Owner")
    }

    // MARK: - 23. Full Review State Survives App Restart

    func testReviewStateSurvivesAppRestart() throws {
        var rec1 = makeSampleRecord(
            id: "restart-1",
            serial: "C1234567890EE",
            status: "REVIEW",
            reviewReasons: ["near_match: restart-2", "legacy_review: manual verification required"]
        )
        rec1.fieldConfidence = ["serial": "uncertain", "denomination": "high", "issueDate": "high"]

        var rec2 = makeSampleRecord(
            id: "restart-2",
            serial: "C1234567898EE",
            status: "REVIEW",
            reviewReasons: ["near_match: restart-1"]
        )
        rec2.fieldConfidence = ["serial": "high", "denomination": "high", "issueDate": "high"]

        try testDb.upsertRecords([rec1, rec2])

        // Session 1: Keep Separate on rec1 & rec2, then edit and confirm rec1
        let coordinator1 = ReviewCoordinator(records: [rec1, rec2], outputRoot: tempDir)
        try coordinator1.keepSeparate(record: rec1, candidate: rec2)

        let latestRec1 = try XCTUnwrap(coordinator1.allRecords.first(where: { $0.id == "restart-1" }))
        _ = try coordinator1.saveRecord(
            record: latestRec1,
            userEdits: ["owner": "Restart Verified Owner"],
            confirmedFields: ["serial", "denomination", "issueDate", "owner"],
            resolvedReasons: Set(latestRec1.resolvedReviewReasons ?? []).union(["legacy_review: manual verification required"]),
            acknowledgedWarnings: ["series_date_warning"]
        )

        // Session 2: Simulate full application restart with a fresh DatabaseManager and ReviewCoordinator
        let restartedDb = try DatabaseManager(url: testDbURL)
        DatabaseManager.setSharedInstance(restartedDb)
        let reloadedRecords = try restartedDb.loadAllRecords()
        let coordinator2 = ReviewCoordinator(records: reloadedRecords, outputRoot: tempDir)

        let r1After = try XCTUnwrap(coordinator2.allRecords.first(where: { $0.id == "restart-1" }))
        let r2After = try XCTUnwrap(coordinator2.allRecords.first(where: { $0.id == "restart-2" }))

        XCTAssertEqual(r1After.status, "OK")
        XCTAssertEqual(r2After.status, "OK")
        XCTAssertEqual(r1After.owner, "Restart Verified Owner")
        XCTAssertTrue(r1After.userConfirmedFields?.contains("serial") == true)
        XCTAssertTrue(r1After.userConfirmedFields?.contains("owner") == true)
        XCTAssertTrue(r1After.resolvedReviewReasons?.contains("keep_separate: restart-2") == true)
        XCTAssertTrue(r2After.resolvedReviewReasons?.contains("keep_separate: restart-1") == true)
        XCTAssertTrue(r1After.acknowledgedWarnings?.contains("series_date_warning") == true)
        XCTAssertGreaterThanOrEqual(r1After.revision ?? 0, 2)
        XCTAssertEqual(coordinator2.progress.remainingCount, 0, "Resolved review queue state must survive app restart")
    }

    // MARK: - 24. Main-Thread Delegate Safety & Non-Overlapping Review UI Layout

    @MainActor
    func testReprocessAndAIReviewInvokeDelegateStrictlyOnMainThread() async throws {
        final class DelegateThreadSpy: ReviewCoordinatorDelegate {
            private let lock = NSLock()
            var didUpdateRecordsThreads: [Bool] = []
            var didSelectRecordThreads: [Bool] = []
            var didChangeProgressThreads: [Bool] = []
            var didUpdateSelectedRecordThreads: [Bool] = []

            func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateRecords records: [BondRecord]) {
                lock.lock(); didUpdateRecordsThreads.append(Thread.isMainThread); lock.unlock()
            }

            func reviewCoordinator(_ coordinator: ReviewCoordinator, didSelectRecord record: BondRecord?) {
                lock.lock(); didSelectRecordThreads.append(Thread.isMainThread); lock.unlock()
            }

            func reviewCoordinator(_ coordinator: ReviewCoordinator, didChangeProgress progress: ReviewProgress) {
                lock.lock(); didChangeProgressThreads.append(Thread.isMainThread); lock.unlock()
            }

            func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateSelectedRecord record: BondRecord) {
                lock.lock(); didUpdateSelectedRecordThreads.append(Thread.isMainThread); lock.unlock()
            }
        }

        let photosDir = tempDir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let photoRel = "photos/reprocess_main_thread.png"
        let photoURL = tempDir.appendingPathComponent(photoRel)

        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: 400,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let cgImg = try XCTUnwrap(ctx.makeImage())
        let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: 400, height: 200))
        let tiffData = try XCTUnwrap(nsImg.tiffRepresentation)
        let bmp = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bmp.representation(using: .png, properties: [:]))
        try pngData.write(to: photoURL)

        var rec = makeSampleRecord(id: "mainthread-1", serial: "C123456789OEE", status: "REVIEW")
        rec.photo = photoRel
        rec.sourcePhoto = photoRel
        rec.revision = 1
        try testDb.upsertRecord(rec)

        let spy = DelegateThreadSpy()
        let coordinator = ReviewCoordinator(records: [rec], outputRoot: tempDir, aiAnalyzer: SuggestingAI())
        coordinator.delegate = spy
        coordinator.selectRecord(id: rec.id)

        coordinator.enqueueAIReview(recordID: rec.id, force: true)
        for _ in 0 ..< 50 where coordinator.allRecords.first?.aiAnalysis == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let latest = try XCTUnwrap(coordinator.allRecords.first(where: { $0.id == rec.id }))
        _ = try await coordinator.reprocessPhoto(for: latest, userActiveEdits: [:])
        let refreshed = try XCTUnwrap(coordinator.allRecords.first(where: { $0.id == rec.id }))
        _ = try await Task.detached {
            try await coordinator.reprocessPhoto(for: refreshed, userActiveEdits: [:])
        }.value

        XCTAssertFalse(spy.didUpdateRecordsThreads.isEmpty)
        XCTAssertFalse(spy.didChangeProgressThreads.isEmpty)
        XCTAssertFalse(spy.didUpdateSelectedRecordThreads.isEmpty)
        XCTAssertTrue(spy.didUpdateRecordsThreads.allSatisfy { $0 }, "didUpdateRecords must run on main thread")
        XCTAssertTrue(spy.didSelectRecordThreads.allSatisfy { $0 }, "didSelectRecord must run on main thread")
        XCTAssertTrue(spy.didChangeProgressThreads.allSatisfy { $0 }, "didChangeProgress must run on main thread")
        XCTAssertTrue(spy.didUpdateSelectedRecordThreads.allSatisfy { $0 }, "didUpdateSelectedRecord must run on main thread")
    }

    @MainActor
    func testReviewEditorViewLayoutHasNoOverlappingButtonsOrDuplicatedAIProgress() {
        let editor = ReviewEditorView(frame: NSRect(x: 0, y: 0, width: 530, height: 700))
        let rec = makeSampleRecord(id: "layout-1", serial: "C1234567890EE", status: "REVIEW")
        let progress = ReviewProgress(reviewedInSession: 1, totalInQueue: 3, remainingCount: 2)
        editor.setRecord(rec, candidate: nil, progress: progress)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 530, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor

        func assertNoCollisions(size: NSSize) {
            window.setContentSize(size)
            editor.frame = NSRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            editor.layoutSubtreeIfNeeded()

            let bottomButtons: [(String, NSView)] = [
                ("reprocessBtn", editor.reprocessBtn),
                ("aiAnalyzeBtn", editor.aiAnalyzeBtn),
                ("confirmAllBtn", editor.confirmAllBtn),
                ("revertBtn", editor.revertBtn),
                ("saveBtn", editor.saveBtn),
                ("saveAndNextBtn", editor.saveAndNextBtn),
            ]
            let frames = bottomButtons.map { ($0.0, editor.convert($0.1.bounds, from: $0.1)) }
            for (name, frame) in frames {
                XCTAssertGreaterThan(frame.width, 0, "\(name) must have non-zero width at \(size)")
                XCTAssertGreaterThan(frame.height, 0, "\(name) must have non-zero height at \(size)")
            }
            for i in 0 ..< frames.count {
                for j in (i + 1) ..< frames.count {
                    XCTAssertFalse(
                        frames[i].1.intersects(frames[j].1),
                        "Bottom buttons \(frames[i].0) and \(frames[j].0) must not overlap at \(size)"
                    )
                }
            }

            let progressFrame = editor.convert(editor.progressLabel.bounds, from: editor.progressLabel)
            let backlogFrame = editor.convert(editor.analyzeBacklogBtn.bounds, from: editor.analyzeBacklogBtn)
            let prevFrame = editor.convert(editor.prevBtn.bounds, from: editor.prevBtn)
            let nextFrame = editor.convert(editor.nextBtn.bounds, from: editor.nextBtn)

            XCTAssertFalse(progressFrame.intersects(backlogFrame), "progressLabel must not overlap analyzeBacklogBtn at \(size)")
            XCTAssertFalse(progressFrame.intersects(prevFrame), "progressLabel must not overlap prevBtn at \(size)")
            XCTAssertFalse(progressFrame.intersects(nextFrame), "progressLabel must not overlap nextBtn at \(size)")
            XCTAssertFalse(backlogFrame.intersects(prevFrame), "analyzeBacklogBtn must not overlap prevBtn at \(size)")
            XCTAssertFalse(prevFrame.intersects(nextFrame), "prevBtn must not overlap nextBtn at \(size)")
        }

        assertNoCollisions(size: NSSize(width: 530, height: 700))
        assertNoCollisions(size: NSSize(width: 420, height: 600))

        editor.updateProgress(progress)
        editor.updateAIProgress("AI reviewing: 1 of 2 — 1 suggestions ready, 0 unresolved")
        editor.updateAIProgress("AI reviewing: 2 of 2 — 2 suggestions ready, 0 unresolved")
        let occurrences = editor.progressLabel.stringValue.components(separatedBy: "AI reviewing:").count - 1
        XCTAssertEqual(occurrences, 1, "AI progress must replace prior AI status instead of appending repeatedly")
        XCTAssertTrue(editor.progressLabel.stringValue.contains("2 of 2"))

        editor.updateAIProgress("")
        XCTAssertEqual(editor.progressLabel.stringValue, progress.displayString)
    }
}
