import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

let databaseURL = outputRoot.appendingPathComponent("bonds.sqlite3")
let backupsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans_backups", isDirectory: true)

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case invalidRecordJSON

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "SQLite open failed: \(message)"
        case .statementFailed(let message): return "SQLite statement failed: \(message)"
        case .invalidRecordJSON: return "SQLite record JSON encoding or decoding failed"
        }
    }
}

/// Thread-safe, WAL-backed SQLite persistence layer for `BondRecord` storage.
/// Stores both indexed relational columns (for O(1) duplicate serial lookup and
/// resumable processing queries) and lossless JSON representations of every record.
final class DatabaseManager {
    static let schemaVersion: Int32 = 1

    static let shared: DatabaseManager = {
        do {
            return try DatabaseManager(url: databaseURL)
        } catch {
            ScanLog.shared.write("database primary init failed: \(error.localizedDescription), attempting recovery")
            if let recovered = try? DatabaseManager.recoverDatabase(at: databaseURL) {
                return recovered
            }
            let fallbackURL = FileManager.default.temporaryDirectory.appendingPathComponent("bonds_fallback_\(UUID().uuidString).sqlite3")
            if let fallback = try? DatabaseManager(url: fallbackURL) {
                ScanLog.shared.write("database initialized with temporary fallback: \(fallbackURL.path)")
                return fallback
            }
            let inMemoryURL = URL(fileURLWithPath: ":memory:")
            if let inMemory = try? DatabaseManager(url: inMemoryURL) {
                ScanLog.shared.write("database initialized with in-memory fallback")
                return inMemory
            }
            fatalError("Unrecoverable SQLite database failure: \(error.localizedDescription)")
        }
    }()

    private(set) var currentURL: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()
    private let decoder = JSONDecoder()
    private let timestampFormatter = ISO8601DateFormatter()

    init(url: URL) throws {
        self.currentURL = url
        if url.path != ":memory:" {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle = handle { sqlite3_close_v2(handle) }
            throw DatabaseError.openFailed(msg)
        }
        self.db = opened

        try configurePragmasAndSchema()
    }

    deinit {
        lock.lock()
        if let db = db {
            sqlite3_close_v2(db)
            self.db = nil
        }
        lock.unlock()
    }

    static func recoverDatabase(at url: URL) throws -> DatabaseManager {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let corruptBackup = url.deletingLastPathComponent().appendingPathComponent("bonds_corrupt_\(timestamp).sqlite3")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: url, to: corruptBackup)
        }
        if FileManager.default.fileExists(atPath: walURL.path) {
            let corruptWal = URL(fileURLWithPath: corruptBackup.path + "-wal")
            try? FileManager.default.moveItem(at: walURL, to: corruptWal)
        }
        if FileManager.default.fileExists(atPath: shmURL.path) {
            let corruptShm = URL(fileURLWithPath: corruptBackup.path + "-shm")
            try? FileManager.default.moveItem(at: shmURL, to: corruptShm)
        }
        ScanLog.shared.write("corrupted database moved to \(corruptBackup.lastPathComponent); initializing clean database")
        return try DatabaseManager(url: url)
    }

    func currentSchemaVersion() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            throw sqliteError(code: step, context: "currentSchemaVersion")
        }
        return sqlite3_column_int(stmt, 0)
    }

    private func configurePragmasAndSchema() throws {
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")

        let currentVersion = try currentSchemaVersion()
        if currentVersion == 0 {
            let schemaSQL = """
            CREATE TABLE IF NOT EXISTS bonds (
                id TEXT PRIMARY KEY,
                sort_order INTEGER NOT NULL DEFAULT 0,
                captured_at TEXT NOT NULL,
                series TEXT NOT NULL DEFAULT '',
                serial_number TEXT NOT NULL DEFAULT '',
                normalized_serial TEXT NOT NULL DEFAULT '',
                issue_month TEXT NOT NULL DEFAULT '',
                issue_year TEXT NOT NULL DEFAULT '',
                denomination TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT '',
                registered_owner TEXT NOT NULL DEFAULT '',
                second_name TEXT NOT NULL DEFAULT '',
                second_role TEXT NOT NULL DEFAULT '',
                address TEXT NOT NULL DEFAULT '',
                tax_id TEXT NOT NULL DEFAULT '',
                issuing_agent TEXT NOT NULL DEFAULT '',
                dating_stamp TEXT NOT NULL DEFAULT '',
                notes TEXT NOT NULL DEFAULT '',
                photo_path TEXT NOT NULL DEFAULT '',
                source_photo_path TEXT NOT NULL DEFAULT '',
                raw_ocr TEXT NOT NULL DEFAULT '',
                record_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_bonds_normalized_serial ON bonds(normalized_serial);
            CREATE INDEX IF NOT EXISTS idx_bonds_status ON bonds(status);
            CREATE INDEX IF NOT EXISTS idx_bonds_captured_at ON bonds(captured_at);
            CREATE INDEX IF NOT EXISTS idx_bonds_sort_order ON bonds(sort_order);
            """
            try execute(schemaSQL)
            try execute("PRAGMA user_version = \(DatabaseManager.schemaVersion);")
        } else if currentVersion < DatabaseManager.schemaVersion {
            // Future schema migrations can be placed here incrementally
            try execute("PRAGMA user_version = \(DatabaseManager.schemaVersion);")
        }
    }

    private func sqliteError(code: Int32, context: String) -> DatabaseError {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
        return .statementFailed("\(context): \(msg)")
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "code \(rc)"
            if let errMsg = errMsg { sqlite3_free(errMsg) }
            throw DatabaseError.statementFailed(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            if let stmt = stmt { sqlite3_finalize(stmt) }
            throw sqliteError(code: rc, context: "prepare")
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) throws {
        let rc = value.withCString { cStr in
            sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT)
        }
        if rc != SQLITE_OK {
            throw sqliteError(code: rc, context: "bind_text(\(index))")
        }
    }

    private func decodeRecords(from stmt: OpaquePointer?) throws -> [BondRecord] {
        var results: [BondRecord] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                guard let cStr = sqlite3_column_text(stmt, 0) else {
                    throw DatabaseError.invalidRecordJSON
                }
                let jsonStr = String(cString: cStr)
                guard let data = jsonStr.data(using: .utf8) else {
                    throw DatabaseError.invalidRecordJSON
                }
                let record = try decoder.decode(BondRecord.self, from: data)
                results.append(record)
            } else if step == SQLITE_DONE {
                break
            } else {
                throw sqliteError(code: step, context: "step")
            }
        }
        return results
    }

    func count() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT COUNT(*) FROM bonds;")
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            throw sqliteError(code: step, context: "count")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func loadAllRecords() throws -> [BondRecord] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT record_json FROM bonds ORDER BY sort_order ASC, rowid ASC;")
        defer { sqlite3_finalize(stmt) }
        return try decodeRecords(from: stmt)
    }

    private func existingSortOrder(for id: String) throws -> Int? {
        let stmt = try prepare("SELECT sort_order FROM bonds WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id)
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        } else if step == SQLITE_DONE {
            return nil
        } else {
            throw sqliteError(code: step, context: "existingSortOrder")
        }
    }

    private func nextSortOrder() throws -> Int {
        let stmt = try prepare("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM bonds;")
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            throw sqliteError(code: step, context: "nextSortOrder")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func upsertRecordInternal(_ record: BondRecord, sortOrder: Int?) throws {
        let effectiveSortOrder: Int
        if let provided = sortOrder {
            effectiveSortOrder = provided
        } else if let existing = try existingSortOrder(for: record.id) {
            effectiveSortOrder = existing
        } else {
            effectiveSortOrder = try nextSortOrder()
        }

        let jsonData = try encoder.encode(record)
        guard let recordJSON = String(data: jsonData, encoding: .utf8) else {
            throw DatabaseError.invalidRecordJSON
        }

        let sql = """
        INSERT OR REPLACE INTO bonds (
            id, sort_order, captured_at, series, serial_number, normalized_serial,
            issue_month, issue_year, denomination, status, registered_owner,
            second_name, second_role, address, tax_id, issuing_agent, dating_stamp,
            notes, photo_path, source_photo_path, raw_ocr, record_json, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        let normSerial = normalizeSerial(record.serial)
        let updatedAt = timestampFormatter.string(from: Date())

        try bindText(stmt, index: 1, value: record.id)
        if sqlite3_bind_int64(stmt, 2, Int64(effectiveSortOrder)) != SQLITE_OK {
            throw sqliteError(code: SQLITE_ERROR, context: "bind_int64(2)")
        }
        try bindText(stmt, index: 3, value: record.capturedAt)
        try bindText(stmt, index: 4, value: record.series)
        try bindText(stmt, index: 5, value: record.serial)
        try bindText(stmt, index: 6, value: normSerial)
        try bindText(stmt, index: 7, value: record.issueMonth)
        try bindText(stmt, index: 8, value: record.issueYear)
        try bindText(stmt, index: 9, value: record.denomination)
        try bindText(stmt, index: 10, value: record.status)
        try bindText(stmt, index: 11, value: record.owner)
        try bindText(stmt, index: 12, value: record.secondName)
        try bindText(stmt, index: 13, value: record.secondRole)
        try bindText(stmt, index: 14, value: record.address)
        try bindText(stmt, index: 15, value: record.taxID)
        try bindText(stmt, index: 16, value: record.issuingAgent)
        try bindText(stmt, index: 17, value: record.datingStamp)
        try bindText(stmt, index: 18, value: record.notes)
        try bindText(stmt, index: 19, value: record.photo)
        try bindText(stmt, index: 20, value: record.sourcePhoto)
        try bindText(stmt, index: 21, value: record.rawOCR)
        try bindText(stmt, index: 22, value: recordJSON)
        try bindText(stmt, index: 23, value: updatedAt)

        let step = sqlite3_step(stmt)
        if step != SQLITE_DONE {
            throw sqliteError(code: step, context: "upsertRecord")
        }
    }

    func upsertRecord(_ record: BondRecord, sortOrder: Int? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try upsertRecordInternal(record, sortOrder: sortOrder)
    }

    func upsertRecords(_ records: [BondRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if records.isEmpty {
                try execute("DELETE FROM bonds;")
            } else {
                // Remove stale IDs not present in the authoritative array
                let incomingIds = Set(records.map(\.id))
                var staleIds: [String] = []
                let selectIdsStmt = try prepare("SELECT id FROM bonds;")
                defer { sqlite3_finalize(selectIdsStmt) }
                while true {
                    let step = sqlite3_step(selectIdsStmt)
                    if step == SQLITE_ROW {
                        if let cStr = sqlite3_column_text(selectIdsStmt, 0) {
                            let existingId = String(cString: cStr)
                            if !incomingIds.contains(existingId) {
                                staleIds.append(existingId)
                            }
                        }
                    } else if step == SQLITE_DONE {
                        break
                    } else {
                        throw sqliteError(code: step, context: "upsertRecords select ids")
                    }
                }
                for staleId in staleIds {
                    try deleteRecordInternal(id: staleId)
                }
                for (index, record) in records.enumerated() {
                    try upsertRecordInternal(record, sortOrder: index)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func deleteRecordInternal(id: String) throws {
        let stmt = try prepare("DELETE FROM bonds WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id)
        let step = sqlite3_step(stmt)
        if step != SQLITE_DONE {
            throw sqliteError(code: step, context: "deleteRecord")
        }
    }

    func deleteRecord(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try deleteRecordInternal(id: id)
    }

    /// Atomically deletes an old record and updates/upserts a consolidated record within
    /// a single SQLite transaction. Either both changes commit, or all roll back.
    func atomicMerge(deleteId: String, updatedRecord: BondRecord, sortOrder: Int? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteRecordInternal(id: deleteId)
            try upsertRecordInternal(updatedRecord, sortOrder: sortOrder)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Creates an atomic online backup of the SQLite database to `destinationURL`.
    func backupDatabase(to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        let destDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let escapedPath = destinationURL.path.replacingOccurrences(of: "'", with: "''")
        try execute("VACUUM INTO '\(escapedPath)';")
    }

    /// Restores the database from a verified backup file at `backupURL`.
    func restoreDatabase(from backupURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw DatabaseError.statementFailed("Backup file does not exist at \(backupURL.path)")
        }

        // Verify the backup can be read as a valid database
        var testHandle: OpaquePointer?
        let rc = sqlite3_open_v2(backupURL.path, &testHandle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let testDb = testHandle else {
            if let testHandle = testHandle { sqlite3_close_v2(testHandle) }
            throw DatabaseError.openFailed("Invalid backup file at \(backupURL.path)")
        }
        sqlite3_close_v2(testDb)

        // Close current connection
        if let currentDb = db {
            sqlite3_close_v2(currentDb)
            self.db = nil
        }

        let walURL = URL(fileURLWithPath: currentURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: currentURL.path + "-shm")
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            try FileManager.default.removeItem(at: currentURL)
        }

        try FileManager.default.copyItem(at: backupURL, to: currentURL)

        // Reopen database
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openRc = sqlite3_open_v2(currentURL.path, &handle, flags, nil)
        guard openRc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(openRc)"
            if let handle = handle { sqlite3_close_v2(handle) }
            throw DatabaseError.openFailed(msg)
        }
        self.db = opened
        try configurePragmasAndSchema()
    }

    func findRecordsByNormalizedSerial(_ rawSerial: String, excludingId: String? = nil) throws -> [BondRecord] {
        let key = normalizeSerial(rawSerial)
        guard !key.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT record_json FROM bonds WHERE normalized_serial = ? AND id != ? ORDER BY sort_order ASC, rowid ASC;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: key)
        try bindText(stmt, index: 2, value: excludingId ?? "")
        return try decodeRecords(from: stmt)
    }

    func pendingOCRRecords() throws -> [BondRecord] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT record_json FROM bonds WHERE status = 'PROCESSING' ORDER BY sort_order ASC, rowid ASC;")
        defer { sqlite3_finalize(stmt) }
        return try decodeRecords(from: stmt)
    }

    @discardableResult
    func migrateFromJSONIfNeeded(jsonURL: URL, csvSourceURL: URL? = csvURL, backupRootURL: URL? = backupsRoot) throws -> [BondRecord] {
        lock.lock()
        defer { lock.unlock() }

        if try count() == 0, FileManager.default.fileExists(atPath: jsonURL.path) {
            let data = try Data(contentsOf: jsonURL)
            let decoded = try decoder.decode([BondRecord].self, from: data)
            if !decoded.isEmpty {
                if let backupRootURL = backupRootURL {
                    let backupDir = backupRootURL.appendingPathComponent("pre-sqlite-migration", isDirectory: true)
                    try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

                    let jsonBackup = backupDir.appendingPathComponent(jsonURL.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: jsonBackup.path) {
                        try FileManager.default.copyItem(at: jsonURL, to: jsonBackup)
                    }

                    if let csvSrc = csvSourceURL, FileManager.default.fileExists(atPath: csvSrc.path) {
                        let csvBackup = backupDir.appendingPathComponent(csvSrc.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: csvBackup.path) {
                            try FileManager.default.copyItem(at: csvSrc, to: csvBackup)
                        }
                    }
                }
                try upsertRecords(decoded)
                try? FileManager.default.removeItem(at: jsonURL)
                if let csvSrc = csvSourceURL, FileManager.default.fileExists(atPath: csvSrc.path) {
                    try? FileManager.default.removeItem(at: csvSrc)
                }
                ScanLog.shared.write("sqlite migration completed: imported \(decoded.count) records")
                return decoded
            }
        }

        return try loadAllRecords()
    }
}
