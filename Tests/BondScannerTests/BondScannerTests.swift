import XCTest
import CoreGraphics
@testable import BondScanner

final class BondScannerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ScanLog.shared.isEnabled = false
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
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
}
