import Darwin
import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

var databaseURL: URL {
    outputRoot.appendingPathComponent("bonds.sqlite3")
}

var backupsRoot: URL {
    StorageConfiguration.shared.backupsRoot
}

enum DatabaseError: Error, LocalizedError, Equatable {
    case openFailed(String)
    case statementFailed(String)
    case invalidRecordJSON
    case databaseLocked(String)
    case permissionDenied(String)
    case databaseCorrupted(String)
    case recoveryAborted(String)
    case incompatibleSchema(current: Int32, backup: Int32)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): return "SQLite open failed: \(message)"
        case let .statementFailed(message): return "SQLite statement failed: \(message)"
        case .invalidRecordJSON: return "SQLite record JSON encoding or decoding failed"
        case let .databaseLocked(message): return "SQLite database is locked: \(message)"
        case let .permissionDenied(message): return "SQLite permission denied: \(message)"
        case let .databaseCorrupted(message): return "SQLite database is corrupted: \(message)"
        case let .recoveryAborted(message): return "Database recovery aborted: \(message)"
        case let .incompatibleSchema(current, backup): return "Incompatible schema version: backup is version \(backup), current supported version is \(current)"
        case let .restoreFailed(message): return "Database restoration failed: \(message)"
        }
    }
}

/// Thread-safe, WAL-backed SQLite persistence layer for `BondRecord` storage.
/// Stores both indexed relational columns (for O(1) duplicate serial lookup and
/// resumable processing queries) and lossless JSON representations of every record.
final class DatabaseManager {
    static let schemaVersion: Int32 = 1

    private static var _shared: DatabaseManager?

    static func setSharedInstance(_ manager: DatabaseManager?) {
        _shared = manager
    }

    static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(url: URL(string: "file::memory:")!, inMemory: true)
    }

    @discardableResult
    static func initializeShared(url: URL = databaseURL) throws -> DatabaseManager {
        let manager = try DatabaseManager(url: url)
        _shared = manager
        return manager
    }

    static var shared: DatabaseManager {
        if let existing = _shared {
            return existing
        }
        if isTestModeActive {
            do {
                let manager = try DatabaseManager.inMemory()
                _shared = manager
                return manager
            } catch {
                fatalError("Failed to initialize test-mode in-memory database: \(error.localizedDescription)")
            }
        }
        do {
            let manager = try DatabaseManager(url: databaseURL)
            _shared = manager
            return manager
        } catch {
            ScanLog.shared.write("database primary init failed: \(error.localizedDescription)")
            fatalError("Unrecoverable SQLite database failure: \(error.localizedDescription)")
        }
    }

    private(set) var currentURL: URL
    let isInMemory: Bool
    var db: OpaquePointer?
    let lock = NSRecursiveLock()
    let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    let decoder = JSONDecoder()
    let timestampFormatter = ISO8601DateFormatter()

    init(url: URL = databaseURL, inMemory: Bool = false) throws {
        let resolvedInMemory = inMemory || url.path == ":memory:" || url.absoluteString == "file::memory:" || url.absoluteString == "sqlite::memory:"
        self.isInMemory = resolvedInMemory
        self.currentURL = resolvedInMemory ? URL(string: "file::memory:")! : url

        if !resolvedInMemory {
            if isProductionStorageProtected(destination: url) {
                throw DatabaseError.permissionDenied("Access to production database is forbidden during test mode: \(url.path)")
            }
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openPath = resolvedInMemory ? ":memory:" : url.path
        let rc = sqlite3_open_v2(openPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle = handle {
                sqlite3_close_v2(handle)
            }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw DatabaseError.databaseLocked(msg)
            } else if rc == SQLITE_READONLY || rc == SQLITE_PERM || rc == SQLITE_CANTOPEN {
                throw DatabaseError.permissionDenied(msg)
            } else if rc == SQLITE_CORRUPT || rc == SQLITE_NOTADB {
                throw DatabaseError.databaseCorrupted(msg)
            }
            throw DatabaseError.openFailed(msg)
        }
        self.db = opened

        if !resolvedInMemory, sqlite3_db_readonly(opened, "main") == 1 {
            sqlite3_close_v2(opened)
            self.db = nil
            throw DatabaseError.permissionDenied("Database at \(url.path) is read-only (insufficient write permissions)")
        }

        try configurePragmasAndSchema()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let active = db {
            sqlite3_close_v2(active)
            self.db = nil
        }
    }

    deinit {
        close()
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

    func configurePragmasAndSchema() throws {
        if isInMemory {
            try execute("PRAGMA journal_mode = MEMORY;")
        } else {
            try execute("PRAGMA journal_mode = WAL;")
        }
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
        } else {
            // Verify read-write capability and lock availability immediately on open
            try execute("BEGIN IMMEDIATE; ROLLBACK;")
        }
    }

    func sqliteError(code: Int32, context: String) -> DatabaseError {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            return .databaseLocked("\(context): \(msg)")
        } else if code == SQLITE_READONLY || code == SQLITE_PERM || code == SQLITE_CANTOPEN {
            return .permissionDenied("\(context): \(msg)")
        } else if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .databaseCorrupted("\(context): \(msg)")
        }
        return .statementFailed("\(context): \(msg)")
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "code \(rc)"
            if let errMsg = errMsg {
                sqlite3_free(errMsg)
            }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw DatabaseError.databaseLocked(msg)
            } else if rc == SQLITE_READONLY || rc == SQLITE_PERM || rc == SQLITE_CANTOPEN {
                throw DatabaseError.permissionDenied(msg)
            } else if rc == SQLITE_CORRUPT || rc == SQLITE_NOTADB {
                throw DatabaseError.databaseCorrupted(msg)
            }
            throw DatabaseError.statementFailed(msg)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            if let stmt = stmt {
                sqlite3_finalize(stmt)
            }
            throw sqliteError(code: rc, context: "prepare")
        }
        return stmt
    }

    func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) throws {
        let rc = value.withCString { cStr in
            sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT)
        }
        if rc != SQLITE_OK {
            throw sqliteError(code: rc, context: "bind_text(\(index))")
        }
    }

    func decodeRecords(from stmt: OpaquePointer?) throws -> [BondRecord] {
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
                var record = try decoder.decode(BondRecord.self, from: data)
                if record.status == "REVIEW" && (record.reviewReasons == nil || record.reviewReasons?.isEmpty == true) {
                    record.reviewReasons = ["legacy_review: manual verification required"]
                }
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

    func fetchRecord(id: String) throws -> BondRecord? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT record_json FROM bonds WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id)
        let records = try decodeRecords(from: stmt)
        return records.first
    }

    /// Authoritatively checks whether a photograph is referenced by any record in the database
    /// across photo_path, source_photo_path, associatedPhotos, and fieldPhoto.
    func isPhotographReferenced(_ photoPath: String, excludingRecordId: String? = nil) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let normalized = photoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let escapedSlash = normalized.replacingOccurrences(of: "/", with: "\\/")
        var sql = "SELECT id, record_json FROM bonds WHERE (photo_path = ? OR source_photo_path = ? OR record_json LIKE ? OR record_json LIKE ?)"
        if excludingRecordId != nil {
            sql += " AND id != ?"
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bindText(stmt, index: 1, value: normalized)
        try bindText(stmt, index: 2, value: normalized)
        try bindText(stmt, index: 3, value: "%\(normalized)%")
        try bindText(stmt, index: 4, value: "%\(escapedSlash)%")
        if let excl = excludingRecordId {
            try bindText(stmt, index: 5, value: excl)
        }

        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                guard let jsonCStr = sqlite3_column_text(stmt, 1) else {
                    // Fail closed if record JSON is unexpectedly null
                    return true
                }
                let jsonString = String(cString: jsonCStr)
                guard let data = jsonString.data(using: .utf8),
                      let record = try? decoder.decode(BondRecord.self, from: data)
                else {
                    if jsonString.contains(normalized) {
                        return true
                    }
                    throw DatabaseError.invalidRecordJSON
                }
                if record.photo == normalized || record.sourcePhoto == normalized {
                    return true
                }
                if let assoc = record.associatedPhotos, assoc.contains(normalized) {
                    return true
                }
                if let fieldPhotos = record.fieldPhoto, fieldPhotos.values.contains(normalized) {
                    return true
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                throw sqliteError(code: step, context: "isPhotographReferenced step")
            }
        }
        return false
    }

    func existingSortOrder(for id: String) throws -> Int? {
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

    func nextSortOrder() throws -> Int {
        let stmt = try prepare("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM bonds;")
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            throw sqliteError(code: step, context: "nextSortOrder")
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func upsertRecordInternal(_ record: BondRecord, sortOrder: Int?) throws {
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

    func deleteRecordInternal(id: String) throws {
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

    /// Atomically updates two records within a single SQLite transaction (e.g. for Keep Separate resolution).
    /// Either both records persist successfully, or neither does (complete rollback).
    func atomicUpdateKeepSeparate(recordA: BondRecord, recordB: BondRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try upsertRecordInternal(recordA, sortOrder: nil)
            try upsertRecordInternal(recordB, sortOrder: nil)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
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
}
