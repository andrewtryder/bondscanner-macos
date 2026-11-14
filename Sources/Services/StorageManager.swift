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

func writeRecords(_ records: [BondRecord]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(records)
    try jsonData.write(to: recordsURL, options: .atomic)
    let cols = ["id", "captured_at", "series", "serial_number", "issue_month", "issue_year", "date_check",
                "face_value_usd", "registered_owner", "second_name", "second_role",
                "address", "tax_id", "issuing_agent", "dating_stamp", "status", "notes", "photo", "source_photo", "raw_ocr"]
    let rows: [[String]] = records.map { r in
        [r.id, r.capturedAt, r.series, r.serial, r.issueMonth, r.issueYear, dateCheck(for: r, among: records),
         r.denomination, r.owner, r.secondName, r.secondRole,
         r.address, r.taxID, r.issuingAgent, r.datingStamp,
         r.status, r.notes, r.photo, r.sourcePhoto, r.rawOCR]
    }
    let csv = ([cols.map(sanitizeCSV).joined(separator: ",")] + rows.map {
        $0.map(sanitizeCSV).joined(separator: ",")
    }).joined(separator: "\r\n") + "\r\n"
    try csv.write(to: csvURL, atomically: true, encoding: .utf8)
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
