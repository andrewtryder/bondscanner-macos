import Foundation
import AppKit
import CoreGraphics
import ImageIO

let outputRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true)
let photosRoot = outputRoot.appendingPathComponent("photos", isDirectory: true)
let recordsURL = outputRoot.appendingPathComponent("records.json")
let csvURL = outputRoot.appendingPathComponent("bonds.csv")
let debugURL = outputRoot.appendingPathComponent("scan-debug.log")

func sanitizeCSV(_ value: String) -> String {
    // Prevent spreadsheet formula injection from untrusted OCR strings.
    var v = value
    if let first = v.first, "=+-@".contains(first) { v = "'" + v }
    return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

func formatCSV(for records: [BondRecord]) -> String {
    let cols = ["id", "captured_at", "series", "serial_number", "issue_month", "issue_year", "date_check",
                "face_value_usd", "registered_owner", "second_name", "second_role",
                "address", "tax_id", "issuing_agent", "dating_stamp", "status", "notes", "photo", "source_photo", "raw_ocr"]
    let rows: [[String]] = records.map { r in
        [r.id, r.capturedAt, r.series, r.serial, r.issueMonth, r.issueYear, dateCheck(for: r, among: records),
         r.denomination, r.owner, r.secondName, r.secondRole,
         r.address, r.taxID, r.issuingAgent, r.datingStamp,
         r.status, r.notes, r.photo, r.sourcePhoto, r.rawOCR]
    }
    return ([cols.map(sanitizeCSV).joined(separator: ",")] + rows.map {
        $0.map(sanitizeCSV).joined(separator: ",")
    }).joined(separator: "\r\n") + "\r\n"
}

func exportCSV(_ records: [BondRecord], to url: URL = csvURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let csv = formatCSV(for: records)
    try csv.write(to: url, atomically: true, encoding: .utf8)
}

func exportJSON(_ records: [BondRecord], to url: URL = recordsURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(records)
    try jsonData.write(to: url, options: .atomic)
}

// MARK: - Automatic Mirror Exports (Debounced Live Sync)

private let exportSyncQueue = DispatchQueue(label: "bondscanner.export-sync", qos: .utility)
private var pendingExportWorkItem: DispatchWorkItem?
private let exportLock = NSLock()

/// Automatically synchronizes the authoritative record collection to `records.json` and `bonds.csv`.
/// Uses a short debounce delay to coalesce rapid sequential updates into a single atomic write.
func scheduleAutomaticExports(records: [BondRecord], delay: TimeInterval = 0.35) {
    exportLock.lock()
    defer { exportLock.unlock() }
    pendingExportWorkItem?.cancel()
    let snapshot = records
    let item = DispatchWorkItem {
        do {
            try exportJSON(snapshot)
            try exportCSV(snapshot)
            ScanLog.shared.write("automatic export synced count=\(snapshot.count)")
        } catch {
            ScanLog.shared.write("automatic export failed: \(error.localizedDescription)")
        }
    }
    pendingExportWorkItem = item
    exportSyncQueue.asyncAfter(deadline: .now() + delay, execute: item)
}

/// Flushes any pending automatic export synchronously (e.g. before application termination).
func flushAutomaticExports(records: [BondRecord]) {
    exportLock.lock()
    pendingExportWorkItem?.cancel()
    pendingExportWorkItem = nil
    exportLock.unlock()
    do {
        try exportJSON(records)
        try exportCSV(records)
        ScanLog.shared.write("flush export synced count=\(records.count)")
    } catch {
        ScanLog.shared.write("flush export failed: \(error.localizedDescription)")
    }
}

func saveRecordLive(_ record: BondRecord, allRecords: [BondRecord], sortOrder: Int? = nil) throws {
    try DatabaseManager.shared.upsertRecord(record, sortOrder: sortOrder)
    scheduleAutomaticExports(records: allRecords)
}

func deleteRecordLive(id: String, allRecords: [BondRecord]) throws {
    try DatabaseManager.shared.deleteRecord(id: id)
    scheduleAutomaticExports(records: allRecords)
}

func mergeRecordLive(deleteId: String, updatedRecord: BondRecord, allRecords: [BondRecord], sortOrder: Int? = nil) throws {
    try DatabaseManager.shared.atomicMerge(deleteId: deleteId, updatedRecord: updatedRecord, sortOrder: sortOrder)
    scheduleAutomaticExports(records: allRecords)
}

func writeRecords(_ records: [BondRecord]) throws {
    try DatabaseManager.shared.upsertRecords(records)
    scheduleAutomaticExports(records: records)
}

func jpegData(_ image: CGImage) -> Data? {
    return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.93])
}

func cgImageFromFile(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: true] as CFDictionary) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func cgImageFromData(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func emptyBondRecord(id: String, capturedAt: String) -> BondRecord {
    return BondRecord(id: id, capturedAt: capturedAt,
        series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
        owner: "", secondName: "", secondRole: "", address: "", taxID: "",
        issuingAgent: "", datingStamp: "", status: "PROCESSING",
        notes: "Photograph saved; OCR pending", photo: "", sourcePhoto: "", rawOCR: "")
}
