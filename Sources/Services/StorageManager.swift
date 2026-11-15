import AppKit
import CoreGraphics
import Foundation
import ImageIO

var isTestModeActive: Bool {
    ProcessInfo.processInfo.environment["BONDSCANNER_TEST_MODE"] == "1" || NSClassFromString("XCTestCase") != nil
}

final class StorageConfiguration {
    static let shared = StorageConfiguration()
    private let lock = NSLock()
    private var customOutputRoot: URL?
    private var customBackupsRoot: URL?

    var outputRoot: URL {
        lock.lock()
        defer { lock.unlock() }
        if let custom = customOutputRoot {
            return custom
        }
        if let env = ProcessInfo.processInfo.environment["BONDSCANNER_OUTPUT_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true)
    }

    var backupsRoot: URL {
        lock.lock()
        defer { lock.unlock() }
        if let custom = customBackupsRoot {
            return custom
        }
        if let env = ProcessInfo.processInfo.environment["BONDSCANNER_BACKUPS_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans_backups", isDirectory: true)
    }

    func setCustomOutputRoot(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customOutputRoot = url
    }

    func setCustomBackupsRoot(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customBackupsRoot = url
    }

    func setCustomRoots(outputRoot: URL?, backupsRoot: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customOutputRoot = outputRoot
        customBackupsRoot = backupsRoot
    }

    func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        customOutputRoot = nil
        customBackupsRoot = nil
    }
}

var outputRoot: URL {
    StorageConfiguration.shared.outputRoot
}

var photosRoot: URL {
    outputRoot.appendingPathComponent("photos", isDirectory: true)
}

var recordsURLDefault: URL {
    outputRoot.appendingPathComponent("records.json")
}

var csvURLDefault: URL {
    outputRoot.appendingPathComponent("bonds.csv")
}

var recordsURL: URL {
    ExportConfiguration.shared.recordsURL
}

var csvURL: URL {
    ExportConfiguration.shared.csvURL
}

var debugURL: URL {
    outputRoot.appendingPathComponent("scan-debug.log")
}

enum StorageError: Error, LocalizedError, Equatable {
    case productionAccessForbidden(String)

    var errorDescription: String? {
        switch self {
        case let .productionAccessForbidden(path):
            return "Production storage access forbidden during test mode: \(path)"
        }
    }
}

func isProductionStorageProtected() -> Bool {
    isTestModeActive
}

func isProductionStorageProtected(destination: URL) -> Bool {
    guard isTestModeActive else { return false }
    let defaultProd = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true).standardized.path
    let destPath = destination.standardized.path
    return destPath == defaultProd || destPath.hasPrefix(defaultProd + "/")
}

func addAssociatedPhotos(to record: inout BondRecord, newPhotos: [String]) {
    var existing = Set(record.associatedPhotos ?? [])
    for p in newPhotos where !p.isEmpty {
        if p != record.photo, p != record.sourcePhoto {
            existing.insert(p)
        }
    }
    record.associatedPhotos = existing.isEmpty ? nil : Array(existing).sorted()
}

func isPhotographReferenced(_ photoPath: String, excludingRecordId: String? = nil, among records: [BondRecord]) -> Bool {
    guard !photoPath.isEmpty else { return false }
    for r in records {
        if let excl = excludingRecordId, r.id == excl {
            continue
        }
        if r.photo == photoPath || r.sourcePhoto == photoPath {
            return true
        }
        if let fieldPhotos = r.fieldPhoto, fieldPhotos.values.contains(photoPath) {
            return true
        }
        if let assoc = r.associatedPhotos, assoc.contains(photoPath) {
            return true
        }
    }
    return false
}

@discardableResult
func safelyTrashPhotographs(for record: BondRecord, existingRecords: [BondRecord], root: URL = outputRoot) -> [String] {
    var trashed: [String] = []
    var candidatePhotos = Set<String>()
    if !record.photo.isEmpty {
        candidatePhotos.insert(record.photo)
    }
    if !record.sourcePhoto.isEmpty {
        candidatePhotos.insert(record.sourcePhoto)
    }
    if let assoc = record.associatedPhotos {
        for p in assoc where !p.isEmpty {
            candidatePhotos.insert(p)
        }
    }
    if let fieldPhotos = record.fieldPhoto {
        for p in fieldPhotos.values where !p.isEmpty {
            candidatePhotos.insert(p)
        }
    }

    for rel in candidatePhotos {
        if isPhotographReferenced(rel, excludingRecordId: record.id, among: existingRecords) {
            continue
        }
        let url = root.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.append(rel)
            } catch {
                ScanLog.shared.write("trashItem failed for \(rel): \(error.localizedDescription)")
            }
        }
    }
    return trashed
}

func sanitizeCSV(_ value: String) -> String {
    // Prevent spreadsheet formula injection from untrusted OCR strings.
    var v = value
    if let first = v.first, "=+-@".contains(first) {
        v = "'" + v
    }
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
    guard !isProductionStorageProtected(destination: url) else {
        throw StorageError.productionAccessForbidden(url.path)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let csv = formatCSV(for: records)
    try csv.write(to: url, atomically: true, encoding: .utf8)
}

func exportJSON(_ records: [BondRecord], to url: URL = recordsURL) throws {
    guard !isProductionStorageProtected(destination: url) else {
        throw StorageError.productionAccessForbidden(url.path)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(records)
    try jsonData.write(to: url, options: .atomic)
}

// MARK: - Automatic Mirror Exports (Debounced Live Sync & Serialized Flush)

final class ExportConfiguration {
    static let shared = ExportConfiguration()
    private let lock = NSLock()
    private var customRecordsURL: URL?
    private var customCSVURL: URL?

    var recordsURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return customRecordsURL ?? recordsURLDefault
    }

    var csvURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return customCSVURL ?? csvURLDefault
    }

    func setCustomDestinations(records: URL?, csv: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customRecordsURL = records
        customCSVURL = csv
    }

    func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        customRecordsURL = nil
        customCSVURL = nil
    }
}

/// Serializes and coordinates mirror exports (JSON + CSV).
/// Enforces single-threaded disk writes, debounces rapid successive updates,
/// prevents stale snapshots from overwriting newer writes, and executes flushes synchronously.
final class ExportCoordinator {
    static let shared = ExportCoordinator()

    private let syncQueue = DispatchQueue(label: "bondscanner.export-sync", qos: .utility)
    private let lock = NSLock()
    private var pendingWorkItem: DispatchWorkItem?
    private var currentScheduledVersion: UInt64 = 0
    private var lastCompletedVersion: UInt64 = 0

    func schedule(records: [BondRecord], delay: TimeInterval = 0.35) {
        lock.lock()
        currentScheduledVersion += 1
        let version = currentScheduledVersion
        pendingWorkItem?.cancel()
        let snapshot = records

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if version <= self.lastCompletedVersion {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            self.performExport(snapshot: snapshot, version: version, logPrefix: "automatic export")
        }

        pendingWorkItem = item
        lock.unlock()

        syncQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flush(records: [BondRecord]) {
        lock.lock()
        currentScheduledVersion += 1
        let version = currentScheduledVersion
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        let snapshot = records
        lock.unlock()

        syncQueue.sync {
            self.performExport(snapshot: snapshot, version: version, logPrefix: "flush export")
        }
    }

    private func performExport(snapshot: [BondRecord], version: UInt64, logPrefix: String) {
        let destRecordsURL = ExportConfiguration.shared.recordsURL
        let destCSVURL = ExportConfiguration.shared.csvURL
        guard !isProductionStorageProtected(destination: destRecordsURL),
              !isProductionStorageProtected(destination: destCSVURL)
        else {
            ScanLog.shared.write("\(logPrefix) skipped: production destinations protected during test mode")
            return
        }
        do {
            try exportJSON(snapshot, to: destRecordsURL)
            try exportCSV(snapshot, to: destCSVURL)
            lock.lock()
            if version > lastCompletedVersion {
                lastCompletedVersion = version
            }
            lock.unlock()
            ScanLog.shared.write("\(logPrefix) synced count=\(snapshot.count) version=\(version)")
        } catch {
            ScanLog.shared.write("\(logPrefix) failed: \(error.localizedDescription)")
        }
    }
}

/// Automatically synchronizes the authoritative record collection to `records.json` and `bonds.csv`.
/// Uses a short debounce delay to coalesce rapid sequential updates into a single atomic write.
func scheduleAutomaticExports(records: [BondRecord], delay: TimeInterval = 0.35) {
    ExportCoordinator.shared.schedule(records: records, delay: delay)
}

/// Flushes any pending automatic export synchronously (e.g. before application termination).
func flushAutomaticExports(records: [BondRecord]) {
    ExportCoordinator.shared.flush(records: records)
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
