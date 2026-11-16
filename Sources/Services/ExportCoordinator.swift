import Foundation

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
