import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

let databaseURL = outputRoot.appendingPathComponent("bonds.sqlite3")
let backupsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans_backups", isDirectory: true)

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
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    private let decoder = JSONDecoder()
    private let timestampFormatter = ISO8601DateFormatter()

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

    /// Validates SQLite database integrity at the specified URL using `PRAGMA integrity_check`.
    /// Returns true if the database exists and passes integrity check cleanly.
    /// Throws `DatabaseError.databaseCorrupted` if corruption is detected.
    /// Throws `DatabaseError.databaseLocked` if the database is locked.
    /// Throws `DatabaseError.permissionDenied` if the file cannot be accessed due to permissions.
    @discardableResult
    static func validateDatabaseIntegrity(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let testDb = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle = handle {
                sqlite3_close_v2(handle)
            }
            if rc == SQLITE_CORRUPT || rc == SQLITE_NOTADB {
                throw DatabaseError.databaseCorrupted("Database file header or structure corrupted: \(msg)")
            } else if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw DatabaseError.databaseLocked(msg)
            } else if rc == SQLITE_PERM || rc == SQLITE_READONLY || rc == SQLITE_CANTOPEN {
                throw DatabaseError.permissionDenied(msg)
            }
            throw DatabaseError.openFailed(msg)
        }
        defer { sqlite3_close_v2(testDb) }

        var stmt: OpaquePointer?
        let prepRc = sqlite3_prepare_v2(testDb, "PRAGMA integrity_check;", -1, &stmt, nil)
        guard prepRc == SQLITE_OK, let checkStmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(testDb))
            if prepRc == SQLITE_CORRUPT || prepRc == SQLITE_NOTADB {
                throw DatabaseError.databaseCorrupted(msg)
            }
            throw DatabaseError.statementFailed("integrity_check prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(checkStmt) }

        var integrityErrors: [String] = []
        while true {
            let step = sqlite3_step(checkStmt)
            if step == SQLITE_ROW {
                if let cStr = sqlite3_column_text(checkStmt, 0) {
                    let row = String(cString: cStr)
                    if row.lowercased() != "ok" {
                        integrityErrors.append(row)
                    }
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(testDb))
                if step == SQLITE_CORRUPT || step == SQLITE_NOTADB {
                    throw DatabaseError.databaseCorrupted(msg)
                }
                throw DatabaseError.statementFailed("integrity_check step failed: \(msg)")
            }
        }

        if !integrityErrors.isEmpty {
            throw DatabaseError.databaseCorrupted("integrity_check reported: \(integrityErrors.joined(separator: "; "))")
        }
        return true
    }

    /// Explicitly recovers a verified corrupted database by archiving the corrupt database,
    /// WAL, and SHM files to a timestamped backup location before creating a fresh replacement database.
    /// Will abort and refuse to replace the database if the file is NOT corrupted (e.g. locked or read-only).
    @discardableResult
    static func recoverDatabase(at url: URL) throws -> DatabaseManager {
        var isCorrupt = false
        do {
            _ = try validateDatabaseIntegrity(at: url)
        } catch DatabaseError.databaseCorrupted {
            isCorrupt = true
        } catch {
            throw DatabaseError.recoveryAborted("Cannot attempt recovery: database error is not corruption (\(error.localizedDescription)). Existing database, WAL, and SHM preserved.")
        }

        guard isCorrupt else {
            throw DatabaseError.recoveryAborted("Database at \(url.path) passed integrity check. Skipping recovery to preserve existing data.")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let corruptBackup = url.deletingLastPathComponent().appendingPathComponent("bonds_corrupt_\(timestamp).sqlite3")
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: corruptBackup)
        }
        if FileManager.default.fileExists(atPath: walURL.path) {
            let corruptWal = URL(fileURLWithPath: corruptBackup.path + "-wal")
            try FileManager.default.moveItem(at: walURL, to: corruptWal)
        }
        if FileManager.default.fileExists(atPath: shmURL.path) {
            let corruptShm = URL(fileURLWithPath: corruptBackup.path + "-shm")
            try FileManager.default.moveItem(at: shmURL, to: corruptShm)
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

    private func sqliteError(code: Int32, context: String) -> DatabaseError {
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

    private func prepare(_ sql: String) throws -> OpaquePointer? {
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

    /// Creates an atomic online backup of the SQLite database to `destinationURL`.
    /// Validates the created backup with SQLite `integrity_check` before returning.
    ///
    /// NOTE: A database backup alone preserves the structured SQLite records and metadata,
    /// but does NOT include the associated photograph files stored in ~/BondScans/photos.
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

        // Validate the backup file immediately with integrity_check
        do {
            _ = try DatabaseManager.validateDatabaseIntegrity(at: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw DatabaseError.statementFailed("Backup integrity check failed: \(error.localizedDescription)")
        }
    }

    /// Restores the database from a verified backup file at `backupURL`.
    /// Restores into a temporary database first, validates schema compatibility and
    /// integrity, and ensures that any restoration failure preserves the original DB, WAL, and SHM files.
    ///
    /// NOTE: A database backup alone preserves the structured SQLite records and metadata,
    /// but does NOT include the associated photograph files stored in ~/BondScans/photos.
    func restoreDatabase(from backupURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw DatabaseError.restoreFailed("Backup file does not exist at \(backupURL.path)")
        }

        // 1. Validate backup file integrity
        _ = try DatabaseManager.validateDatabaseIntegrity(at: backupURL)

        // 2. Verify schema compatibility
        var testHandle: OpaquePointer?
        let rc = sqlite3_open_v2(backupURL.path, &testHandle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let testDb = testHandle else {
            let msg = testHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let testHandle = testHandle {
                sqlite3_close_v2(testHandle)
            }
            throw DatabaseError.openFailed("Cannot inspect backup file: \(msg)")
        }
        defer { sqlite3_close_v2(testDb) }

        var userVer: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(testDb, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK, let vStmt = stmt {
            if sqlite3_step(vStmt) == SQLITE_ROW {
                userVer = sqlite3_column_int(vStmt, 0)
            }
            sqlite3_finalize(vStmt)
        }
        if userVer > DatabaseManager.schemaVersion {
            throw DatabaseError.incompatibleSchema(current: DatabaseManager.schemaVersion, backup: userVer)
        }

        // Verify required 'bonds' table exists in the backup
        var tableCheckStmt: OpaquePointer?
        if sqlite3_prepare_v2(testDb, "SELECT name FROM sqlite_master WHERE type='table' AND name='bonds';", -1, &tableCheckStmt, nil) == SQLITE_OK, let tcStmt = tableCheckStmt {
            let hasBonds = (sqlite3_step(tcStmt) == SQLITE_ROW)
            sqlite3_finalize(tcStmt)
            guard hasBonds else {
                throw DatabaseError.restoreFailed("Backup database does not contain the required 'bonds' table")
            }
        }

        // 3. Restore into a temporary staging database first
        let stagingURL = currentURL.deletingLastPathComponent().appendingPathComponent("restore_staging_\(UUID().uuidString).sqlite3")
        defer {
            let stagingWal = URL(fileURLWithPath: stagingURL.path + "-wal")
            let stagingShm = URL(fileURLWithPath: stagingURL.path + "-shm")
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: stagingWal)
            try? FileManager.default.removeItem(at: stagingShm)
        }

        try FileManager.default.copyItem(at: backupURL, to: stagingURL)
        let stagedDB = try DatabaseManager(url: stagingURL)
        _ = try stagedDB.count()
        try stagedDB.execute("PRAGMA wal_checkpoint(TRUNCATE);")

        // 4. Ensure restoration failures preserve the original DB, WAL, and SHM
        try? execute("PRAGMA wal_checkpoint(TRUNCATE);")
        if let currentDb = db {
            sqlite3_close_v2(currentDb)
            self.db = nil
        }

        let walURL = URL(fileURLWithPath: currentURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: currentURL.path + "-shm")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let preRestoreBackup = currentURL.deletingLastPathComponent().appendingPathComponent("bonds_prerestore_\(timestamp).sqlite3")
        let preRestoreWal = URL(fileURLWithPath: preRestoreBackup.path + "-wal")
        let preRestoreShm = URL(fileURLWithPath: preRestoreBackup.path + "-shm")

        var didBackupOriginal = false
        if FileManager.default.fileExists(atPath: currentURL.path) {
            try FileManager.default.moveItem(at: currentURL, to: preRestoreBackup)
            didBackupOriginal = true
        }
        if FileManager.default.fileExists(atPath: walURL.path) {
            try? FileManager.default.moveItem(at: walURL, to: preRestoreWal)
        }
        if FileManager.default.fileExists(atPath: shmURL.path) {
            try? FileManager.default.moveItem(at: shmURL, to: preRestoreShm)
        }

        do {
            try FileManager.default.copyItem(at: stagingURL, to: currentURL)

            // Reopen database
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            let openRc = sqlite3_open_v2(currentURL.path, &handle, flags, nil)
            guard openRc == SQLITE_OK, let opened = handle else {
                let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(openRc)"
                if let handle = handle {
                    sqlite3_close_v2(handle)
                }
                throw DatabaseError.openFailed(msg)
            }
            self.db = opened
            try configurePragmasAndSchema()

            // Success: Clean up safety backup
            if didBackupOriginal {
                try? FileManager.default.removeItem(at: preRestoreBackup)
                try? FileManager.default.removeItem(at: preRestoreWal)
                try? FileManager.default.removeItem(at: preRestoreShm)
            }
        } catch {
            // Roll back: restore original DB, WAL, SHM from safety backup
            try? FileManager.default.removeItem(at: currentURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            if didBackupOriginal && FileManager.default.fileExists(atPath: preRestoreBackup.path) {
                try? FileManager.default.moveItem(at: preRestoreBackup, to: currentURL)
                if FileManager.default.fileExists(atPath: preRestoreWal.path) {
                    try? FileManager.default.moveItem(at: preRestoreWal, to: walURL)
                }
                if FileManager.default.fileExists(atPath: preRestoreShm.path) {
                    try? FileManager.default.moveItem(at: preRestoreShm, to: shmURL)
                }
            }

            // Reopen original DB
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(currentURL.path, &handle, flags, nil) == SQLITE_OK, let opened = handle {
                self.db = opened
                try? configurePragmasAndSchema()
            }
            throw DatabaseError.restoreFailed("Restoration failed, original database preserved: \(error.localizedDescription)")
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
                let migrated = decoded.map { r -> BondRecord in
                    var rec = r
                    if rec.status == "REVIEW", rec.reviewReasons == nil || rec.reviewReasons?.isEmpty == true {
                        rec.reviewReasons = ["legacy_review: manual verification required"]
                    }
                    if !rec.notes.isEmpty {
                        let pattern = "Duplicate scan photo preserved at (photos/[^;\\n]+)"
                        if let re = try? NSRegularExpression(pattern: pattern) {
                            let ns = NSRange(rec.notes.startIndex ..< rec.notes.endIndex, in: rec.notes)
                            for match in re.matches(in: rec.notes, range: ns) {
                                if let range = Range(match.range(at: 1), in: rec.notes) {
                                    addAssociatedPhotos(to: &rec, newPhotos: [String(rec.notes[range])])
                                }
                            }
                        }
                    }
                    return rec
                }
                try upsertRecords(migrated)
                try? FileManager.default.removeItem(at: jsonURL)
                if let csvSrc = csvSourceURL, FileManager.default.fileExists(atPath: csvSrc.path) {
                    try? FileManager.default.removeItem(at: csvSrc)
                }
                ScanLog.shared.write("sqlite migration completed: imported \(decoded.count) records")
                return migrated
            }
        }

        return try loadAllRecords()
    }
}

struct CollectionBackupManifest: Codable, Equatable {
    let timestamp: String
    let schemaVersion: Int32
    let recordCount: Int
    let databaseFileName: String
    let photoFiles: [String]
}

extension DatabaseManager {
    /// Reads and decodes all BondRecords directly from a SQLite snapshot database.
    /// Ensures that backup manifests and photograph references correspond exactly to the database snapshot.
    static func loadRecordsFromSnapshot(at snapshotURL: URL) throws -> [BondRecord] {
        var inspectHandle: OpaquePointer?
        let inspectRc = sqlite3_open_v2(snapshotURL.path, &inspectHandle, SQLITE_OPEN_READONLY, nil)
        guard inspectRc == SQLITE_OK, let h = inspectHandle else {
            throw DatabaseError.openFailed("Cannot inspect backup snapshot database: code \(inspectRc)")
        }
        defer { sqlite3_close_v2(h) }

        var inspectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT record_json FROM bonds;", -1, &inspectStmt, nil) == SQLITE_OK, let s = inspectStmt else {
            throw DatabaseError.statementFailed("Failed to read records from backup snapshot")
        }
        defer { sqlite3_finalize(s) }

        var records: [BondRecord] = []
        let jsonDecoder = JSONDecoder()
        var recordIndex = 0
        while true {
            let step = sqlite3_step(s)
            if step == SQLITE_ROW {
                recordIndex += 1
                guard let cStr = sqlite3_column_text(s, 0) else {
                    throw DatabaseError.statementFailed("Malformed null record JSON at index \(recordIndex) in backup snapshot")
                }
                let json = String(cString: cStr)
                guard let data = json.data(using: .utf8), let rec = try? jsonDecoder.decode(BondRecord.self, from: data) else {
                    throw DatabaseError.statementFailed("Malformed record JSON at index \(recordIndex) in backup snapshot (decoding failed)")
                }
                records.append(rec)
            } else if step == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.statementFailed("Error reading snapshot database records: code \(step)")
            }
        }
        return records
    }

    /// Creates an atomic, complete collection backup covering both records and photograph files.
    /// Never modifies the source collection. Validates SQLite backup integrity.
    /// Publishes complete, immutable backup generations and atomically switches which generation is considered current.
    /// Safe against destructive cleanup: builds in staging and preserves existing generations.
    /// Uses atomic pointer publication: pre-syncs generation data, establishes top-level compatibility links,
    /// and atomically commits the 'current' pointer switch. The commit point is the successful rename() of 'current'.
    /// No failure after the commit point will delete the newly active generation.
    func backupCollection(
        to destinationDir: URL,
        photosSourceDir: URL = photosRoot,
        _injectedFailureDuringPublication: Bool = false,
        _injectedFailureAfterGenerationCommit: Bool = false
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if isProductionStorageProtected(destination: destinationDir) {
            throw DatabaseError.permissionDenied("Access to production destination is forbidden during test mode: \(destinationDir.path)")
        }

        // Live collection tree protection:
        // A backup should never be published into the live photos or data directory,
        // or anywhere within the active collection tree (root, ancestors, or descendants).
        let standardizedDest = destinationDir.standardized.path
        let standardizedOutput = outputRoot.standardized.path
        let standardizedPhotos = photosSourceDir.standardized.path
        let resolvedDest = destinationDir.resolvingSymlinksInPath().standardized.path
        let resolvedOutput = outputRoot.resolvingSymlinksInPath().standardized.path
        let resolvedPhotos = photosSourceDir.resolvingSymlinksInPath().standardized.path
        let resolvedDBDir = databaseURL.deletingLastPathComponent().resolvingSymlinksInPath().standardized.path

        func isTreeOverlap(dest: String, tree: String) -> Bool {
            dest == tree || dest.hasPrefix(tree + "/") || tree.hasPrefix(dest + "/")
        }

        if isTreeOverlap(dest: standardizedDest, tree: standardizedOutput) ||
            isTreeOverlap(dest: standardizedDest, tree: standardizedPhotos) ||
            isTreeOverlap(dest: resolvedDest, tree: resolvedOutput) ||
            isTreeOverlap(dest: resolvedDest, tree: resolvedPhotos) ||
            isTreeOverlap(dest: resolvedDest, tree: resolvedDBDir)
        {
            throw DatabaseError.permissionDenied("Refusing unsafe backup destination: cannot backup into or contain active collection tree: \(destinationDir.path)")
        }

        // Build backup entirely in an isolated, uniquely owned staging directory
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("backup_staging_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let dbBackupURL = stagingDir.appendingPathComponent("bonds.sqlite3")
        let manifestURL = stagingDir.appendingPathComponent("backup_manifest.json")
        let photosDestDir = stagingDir.appendingPathComponent("photos", isDirectory: true)

        // 1. Create SQLite snapshot
        try backupDatabase(to: dbBackupURL)

        // 2. Validate snapshot integrity
        _ = try DatabaseManager.validateDatabaseIntegrity(at: dbBackupURL)

        // 3. Derive records and photo inventory directly from the snapshot database
        let allRecords = try DatabaseManager.loadRecordsFromSnapshot(at: dbBackupURL)

        var referencedPhotos = Set<String>()
        for r in allRecords {
            if !r.photo.isEmpty {
                referencedPhotos.insert(r.photo)
            }
            if !r.sourcePhoto.isEmpty {
                referencedPhotos.insert(r.sourcePhoto)
            }
            if let assoc = r.associatedPhotos {
                for p in assoc where !p.isEmpty {
                    referencedPhotos.insert(p)
                }
            }
            if let fieldPhotos = r.fieldPhoto {
                for p in fieldPhotos.values where !p.isEmpty {
                    referencedPhotos.insert(p)
                }
            }
        }

        let sourceBaseDir = photosSourceDir.deletingLastPathComponent()
        var copiedPhotos: [String] = []
        if !referencedPhotos.isEmpty {
            try FileManager.default.createDirectory(at: photosDestDir, withIntermediateDirectories: true)
            for rel in referencedPhotos {
                // Strict path validation: reject absolute paths, .. traversal, and symlink escapes
                let sourceURL = try PathSecurity.validateSafeRelativePath(rel, within: sourceBaseDir)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw DatabaseError.statementFailed("Missing referenced source photograph: \(rel)")
                }
                let destURL = try PathSecurity.validateSafeRelativePath(rel, within: stagingDir)
                try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                }
                copiedPhotos.append(rel)
            }
        }

        let manifest = CollectionBackupManifest(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            schemaVersion: DatabaseManager.schemaVersion,
            recordCount: allRecords.count,
            databaseFileName: "bonds.sqlite3",
            photoFiles: copiedPhotos.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        // Final integrity check on snapshot before publication
        _ = try DatabaseManager.validateDatabaseIntegrity(at: dbBackupURL)

        // 4. Safe Publication Phase:
        // Publish complete, immutable backup generations and atomically switch which generation is considered current.
        // Never modify the last known-good generation in place.
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let generationsDir = destinationDir.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generationsDir, withIntermediateDirectories: true)

        let currentSymlink = destinationDir.appendingPathComponent("current")

        // If destinationDir contains legacy flat files (not symlinks), migrate them into an initial generation
        var statBuf = stat()
        if lstat(currentSymlink.path, &statBuf) != 0 {
            let existingEntries = try FileManager.default.contentsOfDirectory(at: destinationDir, includingPropertiesForKeys: nil)
            let nonGenEntries = existingEntries.filter { $0.lastPathComponent != "generations" && !$0.lastPathComponent.hasPrefix(".") }
            if !nonGenEntries.isEmpty {
                let initialGenDir = generationsDir.appendingPathComponent("gen_initial", isDirectory: true)
                try FileManager.default.createDirectory(at: initialGenDir, withIntermediateDirectories: true)
                for entry in nonGenEntries {
                    let dest = initialGenDir.appendingPathComponent(entry.lastPathComponent)
                    try FileManager.default.copyItem(at: entry, to: dest)
                }
                let legacyDB = initialGenDir.appendingPathComponent("bonds.sqlite3")
                if FileManager.default.fileExists(atPath: legacyDB.path) {
                    _ = try DatabaseManager.validateDatabaseIntegrity(at: legacyDB)
                }
                let tmpInitLink = destinationDir.appendingPathComponent(".current_init_\(UUID().uuidString)")
                try FileManager.default.createSymbolicLink(atPath: tmpInitLink.path, withDestinationPath: "generations/gen_initial")
                let initRenameRc = rename(tmpInitLink.path, currentSymlink.path)
                if initRenameRc != 0 {
                    let err = errno
                    try? FileManager.default.removeItem(at: tmpInitLink)
                    try? FileManager.default.removeItem(at: initialGenDir)
                    throw DatabaseError.statementFailed("Failed to initialize legacy generation pointer: errno \(err)")
                }
            }
        }

        let timestampStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let genID = "gen_\(timestampStr)_\(UUID().uuidString.prefix(8))"
        let genDir = generationsDir.appendingPathComponent(genID, isDirectory: true)
        var didCommitGeneration = false

        do {
            try FileManager.default.copyItem(at: stagingDir, to: genDir)

            // Verify integrity of the published database inside the new generation
            let publishedDB = genDir.appendingPathComponent("bonds.sqlite3")
            _ = try DatabaseManager.validateDatabaseIntegrity(at: publishedDB)

            // Flush database and generation directory metadata for power-loss durability before pointer switch
            let dbFd = open(publishedDB.path, O_RDONLY)
            if dbFd >= 0 {
                #if os(macOS)
                    _ = fcntl(dbFd, F_FULLFSYNC)
                #else
                    fsync(dbFd)
                #endif
                Darwin.close(dbFd)
            }
            let genFd = open(genDir.path, O_RDONLY)
            if genFd >= 0 {
                #if os(macOS)
                    _ = fcntl(genFd, F_FULLFSYNC)
                #else
                    fsync(genFd)
                #endif
                Darwin.close(genFd)
            }

            if _injectedFailureDuringPublication {
                throw DatabaseError.statementFailed("Injected publication failure for testing")
            }

            // Pre-prepare top-level compatibility symlinks before committing pointer switch
            let stagingItems = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
            for item in stagingItems {
                let itemName = item.lastPathComponent
                let topItem = destinationDir.appendingPathComponent(itemName)
                var needsLink = true
                if lstat(topItem.path, &statBuf) == 0 {
                    let isSymlink = (statBuf.st_mode & S_IFMT) == S_IFLNK
                    if isSymlink {
                        needsLink = false
                    } else {
                        try FileManager.default.removeItem(at: topItem)
                    }
                }
                if needsLink {
                    let tmpTop = destinationDir.appendingPathComponent(".top_tmp_\(itemName)_\(UUID().uuidString)")
                    try FileManager.default.createSymbolicLink(atPath: tmpTop.path, withDestinationPath: "current/\(itemName)")
                    let topRenameRc = rename(tmpTop.path, topItem.path)
                    if topRenameRc != 0 {
                        let err = errno
                        try? FileManager.default.removeItem(at: tmpTop)
                        throw DatabaseError.statementFailed("Failed to establish top-level compatibility link for \(itemName): errno \(err)")
                    }
                }
            }

            // Atomically switch 'current' pointer to this new immutable generation (COMMIT POINT)
            let tempCurrentSymlink = destinationDir.appendingPathComponent(".current_tmp_\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(atPath: tempCurrentSymlink.path, withDestinationPath: "generations/\(genID)")

            if lstat(currentSymlink.path, &statBuf) == 0 {
                let isSymlink = (statBuf.st_mode & S_IFMT) == S_IFLNK
                if !isSymlink {
                    try FileManager.default.removeItem(at: currentSymlink)
                }
            }

            let renameRc = rename(tempCurrentSymlink.path, currentSymlink.path)
            if renameRc != 0 {
                let err = errno
                try? FileManager.default.removeItem(at: tempCurrentSymlink)
                throw DatabaseError.statementFailed("Atomic generation switch failed: errno \(err)")
            }

            // COMMIT POINT: Generation switch succeeded!
            // From this point onward, genDir is the committed active generation and must NEVER be deleted.
            didCommitGeneration = true

            // Flush destination directory metadata after pointer switch
            let destFd = open(destinationDir.path, O_RDONLY)
            if destFd >= 0 {
                #if os(macOS)
                    _ = fcntl(destFd, F_FULLFSYNC)
                #else
                    fsync(destFd)
                #endif
                Darwin.close(destFd)
            }

            if _injectedFailureAfterGenerationCommit {
                throw DatabaseError.statementFailed("Injected failure after generation commit for testing")
            }

            ScanLog.shared.write("collection backup completed: generation=\(genID) records=\(allRecords.count) photos=\(copiedPhotos.count)")
        } catch {
            // Only clean up the new generation if failure occurred BEFORE the generation was committed.
            // Once committed, the active generation is preserved and never deleted.
            if !didCommitGeneration, FileManager.default.fileExists(atPath: genDir.path) {
                try? FileManager.default.removeItem(at: genDir)
            }
            throw error
        }
    }

    /// Restricts photograph restore destinations strictly to the intended photo subtree.
    static func validatePhotoDestination(for relativePath: String, within destinationPhotosDir: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.restoreFailed("Empty photograph path is invalid")
        }
        let subpath: String
        if trimmed.hasPrefix("photos/") {
            subpath = String(trimmed.dropFirst("photos/".count))
        } else if !trimmed.contains("/") {
            subpath = trimmed
        } else {
            throw DatabaseError.restoreFailed("Photograph destination '\(trimmed)' is outside the intended photos directory")
        }
        guard !subpath.isEmpty else {
            throw DatabaseError.restoreFailed("Photograph path cannot resolve to the root photos directory itself")
        }
        return try PathSecurity.validateSafeRelativePath(subpath, within: destinationPhotosDir)
    }

    /// Restores a complete collection backup after verifying database integrity,
    /// schema compatibility, and complete required photograph references.
    /// Requires explicit user authorization (authorized: true).
    /// Provides atomic rollback for BOTH SQLite database and photographs if any step fails.
    func restoreCollection(
        from backupDir: URL,
        destinationDBURL: URL = databaseURL,
        destinationPhotosDir: URL = photosRoot,
        authorized: Bool,
        _injectedFailureAfterDB: Bool = false,
        _injectedPreRestoreFailure: Bool = false,
        _injectedSafetyStagingFailure: Bool = false
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard authorized else {
            throw DatabaseError.restoreFailed("Explicit user authorization is required for collection restoration")
        }

        if isProductionStorageProtected(destination: destinationDBURL) {
            throw DatabaseError.permissionDenied("Access to production database destination is forbidden during test mode: \(destinationDBURL.path)")
        }
        if isProductionStorageProtected(destination: destinationPhotosDir) {
            throw DatabaseError.permissionDenied("Access to production photos destination is forbidden during test mode: \(destinationPhotosDir.path)")
        }

        let effectiveBackupDir: URL
        let currentLink = backupDir.appendingPathComponent("current")
        if FileManager.default.fileExists(atPath: currentLink.path) {
            effectiveBackupDir = currentLink.resolvingSymlinksInPath()
        } else {
            effectiveBackupDir = backupDir
        }

        let manifestURL = effectiveBackupDir.appendingPathComponent("backup_manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DatabaseError.restoreFailed("Missing backup_manifest.json in backup directory")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: CollectionBackupManifest
        do {
            manifest = try JSONDecoder().decode(CollectionBackupManifest.self, from: manifestData)
        } catch {
            throw DatabaseError.restoreFailed("Corrupt backup_manifest.json: \(error.localizedDescription)")
        }

        guard manifest.schemaVersion <= DatabaseManager.schemaVersion else {
            throw DatabaseError.incompatibleSchema(current: DatabaseManager.schemaVersion, backup: manifest.schemaVersion)
        }

        // Strict filename validation on manifest.databaseFileName
        let dbFileName = try PathSecurity.validateSafeFilename(manifest.databaseFileName)
        guard dbFileName.hasSuffix(".sqlite3") || dbFileName.hasSuffix(".db") else {
            throw DatabaseError.restoreFailed("Invalid manifest database filename extension: '\(manifest.databaseFileName)'")
        }
        let backupDBURL = try PathSecurity.validateSafeRelativePath(dbFileName, within: effectiveBackupDir)
        guard FileManager.default.fileExists(atPath: backupDBURL.path) else {
            throw DatabaseError.restoreFailed("Missing database file '\(manifest.databaseFileName)' in backup")
        }

        _ = try DatabaseManager.validateDatabaseIntegrity(at: backupDBURL)

        var inspectHandle: OpaquePointer?
        let inspectRc = sqlite3_open_v2(backupDBURL.path, &inspectHandle, SQLITE_OPEN_READONLY, nil)
        guard inspectRc == SQLITE_OK, let h = inspectHandle else {
            throw DatabaseError.openFailed("Cannot inspect backup database file: code \(inspectRc)")
        }
        defer { sqlite3_close_v2(h) }

        var inspectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT record_json FROM bonds;", -1, &inspectStmt, nil) == SQLITE_OK, let s = inspectStmt else {
            throw DatabaseError.statementFailed("Failed to read records from backup database")
        }
        defer { sqlite3_finalize(s) }

        var records: [BondRecord] = []
        let jsonDecoder = JSONDecoder()
        var recordIndex = 0
        while true {
            let step = sqlite3_step(s)
            if step == SQLITE_ROW {
                recordIndex += 1
                guard let cStr = sqlite3_column_text(s, 0) else {
                    throw DatabaseError.restoreFailed("Malformed null record JSON at index \(recordIndex) in backup database")
                }
                let json = String(cString: cStr)
                guard let data = json.data(using: .utf8), let rec = try? jsonDecoder.decode(BondRecord.self, from: data) else {
                    // Redacted error message: never include raw json string or private identifiers
                    throw DatabaseError.restoreFailed("Malformed record JSON at index \(recordIndex) in backup database (decoding failed)")
                }
                records.append(rec)
            } else if step == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.statementFailed("Error reading backup database records: code \(step)")
            }
        }

        guard records.count == manifest.recordCount else {
            throw DatabaseError.restoreFailed("Manifest record count (\(manifest.recordCount)) does not match decoded database record count (\(records.count))")
        }

        var requiredPhotos = Set<String>()
        for r in records {
            if !r.photo.isEmpty {
                requiredPhotos.insert(r.photo)
            }
            if !r.sourcePhoto.isEmpty {
                requiredPhotos.insert(r.sourcePhoto)
            }
            if let assoc = r.associatedPhotos {
                for p in assoc where !p.isEmpty {
                    requiredPhotos.insert(p)
                }
            }
            if let fieldPhotos = r.fieldPhoto {
                for p in fieldPhotos.values where !p.isEmpty {
                    requiredPhotos.insert(p)
                }
            }
        }

        // Strict path validation for every photograph reference in backup
        for rel in requiredPhotos {
            let photoInBackup = try PathSecurity.validateSafeRelativePath(rel, within: effectiveBackupDir)
            guard FileManager.default.fileExists(atPath: photoInBackup.path) else {
                throw DatabaseError.restoreFailed("Incomplete collection backup: missing photograph file '\(rel)'")
            }
            _ = try DatabaseManager.validatePhotoDestination(for: rel, within: destinationPhotosDir)
        }

        // Unified pre-restore safety copy for BOTH SQLite database and photograph files
        let stagingSafetyDir = FileManager.default.temporaryDirectory.appendingPathComponent("pre_restore_safety_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingSafetyDir, withIntermediateDirectories: true)
        var preserveSafetyDir = false
        defer {
            if !preserveSafetyDir {
                try? FileManager.default.removeItem(at: stagingSafetyDir)
            }
        }

        let dbSafetyDir = stagingSafetyDir.appendingPathComponent("db_safety", isDirectory: true)
        try FileManager.default.createDirectory(at: dbSafetyDir, withIntermediateDirectories: true)
        let photosSafetyDir = stagingSafetyDir.appendingPathComponent("photos_safety", isDirectory: true)

        let targetDBURL = destinationDBURL
        let targetDBWalURL = URL(fileURLWithPath: targetDBURL.path + "-wal")
        let targetDBShmURL = URL(fileURLWithPath: targetDBURL.path + "-shm")
        let isTargetingActiveDB = (targetDBURL == self.currentURL)

        // Complete photograph safety copy BEFORE touching active database connection
        var hadOriginalPhotos = false
        if FileManager.default.fileExists(atPath: destinationPhotosDir.path) {
            try FileManager.default.copyItem(at: destinationPhotosDir, to: photosSafetyDir)
            hadOriginalPhotos = true
        }

        var hadOriginalDB = false
        var hadOriginalWal = false
        var hadOriginalShm = false
        var didModifyTargetDB = false
        var didModifyTargetPhotos = false

        // From the moment the active connection is closed or modified, everything is wrapped in do/catch with recovery
        do {
            if isTargetingActiveDB {
                try? execute("PRAGMA wal_checkpoint(TRUNCATE);")
                if let activeHandle = db {
                    sqlite3_close_v2(activeHandle)
                    self.db = nil
                }
            }

            if _injectedSafetyStagingFailure {
                throw DatabaseError.restoreFailed("Injected safety staging failure for testing")
            }

            if FileManager.default.fileExists(atPath: targetDBURL.path) {
                let savedDB = dbSafetyDir.appendingPathComponent("bonds.sqlite3")
                try FileManager.default.copyItem(at: targetDBURL, to: savedDB)
                hadOriginalDB = true
            }
            if FileManager.default.fileExists(atPath: targetDBWalURL.path) {
                let savedWal = dbSafetyDir.appendingPathComponent("bonds.sqlite3-wal")
                try FileManager.default.copyItem(at: targetDBWalURL, to: savedWal)
                hadOriginalWal = true
            }
            if FileManager.default.fileExists(atPath: targetDBShmURL.path) {
                let savedShm = dbSafetyDir.appendingPathComponent("bonds.sqlite3-shm")
                try FileManager.default.copyItem(at: targetDBShmURL, to: savedShm)
                hadOriginalShm = true
            }

            if hadOriginalDB {
                let savedDB = dbSafetyDir.appendingPathComponent("bonds.sqlite3")
                _ = try DatabaseManager.validateDatabaseIntegrity(at: savedDB)
            }

            if _injectedPreRestoreFailure {
                throw DatabaseError.restoreFailed("Injected pre-restore failure after closing connection for testing")
            }

            // CRITICAL INVARIANT: Verified safety copy must exist before any original database modification
            if FileManager.default.fileExists(atPath: targetDBURL.path), !hadOriginalDB {
                throw DatabaseError.restoreFailed("Cannot modify original database: verified safety copy was not created")
            }

            // Step 1: Replace Database
            didModifyTargetDB = true
            let destDir = targetDBURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetDBURL.path) {
                try FileManager.default.removeItem(at: targetDBURL)
            }
            if FileManager.default.fileExists(atPath: targetDBWalURL.path) {
                try FileManager.default.removeItem(at: targetDBWalURL)
            }
            if FileManager.default.fileExists(atPath: targetDBShmURL.path) {
                try FileManager.default.removeItem(at: targetDBShmURL)
            }

            try FileManager.default.copyItem(at: backupDBURL, to: targetDBURL)
            _ = try DatabaseManager.validateDatabaseIntegrity(at: targetDBURL)

            if isTargetingActiveDB {
                var handle: OpaquePointer?
                let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                let openRc = sqlite3_open_v2(targetDBURL.path, &handle, flags, nil)
                guard openRc == SQLITE_OK, let opened = handle else {
                    let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(openRc)"
                    if let handle = handle {
                        sqlite3_close_v2(handle)
                    }
                    throw DatabaseError.openFailed("Failed reopening active database after restore: \(msg)")
                }
                self.db = opened
                try configurePragmasAndSchema()
            }

            if _injectedFailureAfterDB {
                throw DatabaseError.restoreFailed("Injected failure after database replacement for rollback testing")
            }

            // Step 2: Replace / copy photographs
            didModifyTargetPhotos = true
            try FileManager.default.createDirectory(at: destinationPhotosDir, withIntermediateDirectories: true)
            for rel in requiredPhotos {
                let src = try PathSecurity.validateSafeRelativePath(rel, within: effectiveBackupDir)
                let dst = try DatabaseManager.validatePhotoDestination(for: rel, within: destinationPhotosDir)
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            }

            ScanLog.shared.write("collection restore completed successfully: records=\(records.count) photos=\(requiredPhotos.count)")
        } catch {
            // Full atomic rollback for BOTH database and photographs with error propagation and safety preservation
            var rollbackFailed = false
            var rollbackErrors: [Error] = []

            // 1. Rollback photographs ONLY IF modified
            if didModifyTargetPhotos {
                do {
                    if FileManager.default.fileExists(atPath: destinationPhotosDir.path) {
                        try FileManager.default.removeItem(at: destinationPhotosDir)
                    }
                    if hadOriginalPhotos {
                        try FileManager.default.copyItem(at: photosSafetyDir, to: destinationPhotosDir)
                    }
                } catch {
                    rollbackFailed = true
                    rollbackErrors.append(error)
                    ScanLog.shared.write("CRITICAL: Failed to rollback photographs: \(error.localizedDescription)")
                }
            }

            // 2. Rollback database
            if isTargetingActiveDB, let activeHandle = db {
                sqlite3_close_v2(activeHandle)
                self.db = nil
            }

            if didModifyTargetDB {
                do {
                    if FileManager.default.fileExists(atPath: targetDBURL.path) {
                        try FileManager.default.removeItem(at: targetDBURL)
                    }
                    if FileManager.default.fileExists(atPath: targetDBWalURL.path) {
                        try FileManager.default.removeItem(at: targetDBWalURL)
                    }
                    if FileManager.default.fileExists(atPath: targetDBShmURL.path) {
                        try FileManager.default.removeItem(at: targetDBShmURL)
                    }

                    if hadOriginalDB {
                        let savedDB = dbSafetyDir.appendingPathComponent("bonds.sqlite3")
                        let savedWal = dbSafetyDir.appendingPathComponent("bonds.sqlite3-wal")
                        let savedShm = dbSafetyDir.appendingPathComponent("bonds.sqlite3-shm")
                        if FileManager.default.fileExists(atPath: savedDB.path) {
                            try FileManager.default.copyItem(at: savedDB, to: targetDBURL)
                        }
                        if hadOriginalWal, FileManager.default.fileExists(atPath: savedWal.path) {
                            try FileManager.default.copyItem(at: savedWal, to: targetDBWalURL)
                        }
                        if hadOriginalShm, FileManager.default.fileExists(atPath: savedShm.path) {
                            try FileManager.default.copyItem(at: savedShm, to: targetDBShmURL)
                        }
                    }
                } catch {
                    rollbackFailed = true
                    rollbackErrors.append(error)
                    ScanLog.shared.write("CRITICAL: Failed to rollback database files: \(error.localizedDescription)")
                }
            }

            // 3. Reopen active database handle if targeting active DB
            if isTargetingActiveDB, FileManager.default.fileExists(atPath: targetDBURL.path) {
                var handle: OpaquePointer?
                let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                let openRc = sqlite3_open_v2(targetDBURL.path, &handle, flags, nil)
                if openRc == SQLITE_OK, let opened = handle {
                    self.db = opened
                    do {
                        try configurePragmasAndSchema()
                    } catch {
                        rollbackFailed = true
                        rollbackErrors.append(error)
                        ScanLog.shared.write("CRITICAL: Failed configuring database pragmas during rollback: \(error.localizedDescription)")
                    }
                } else {
                    rollbackFailed = true
                    let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(openRc)"
                    if let handle = handle {
                        sqlite3_close_v2(handle)
                    }
                    let reopenErr = DatabaseError.openFailed("Failed reopening active database after rollback: \(msg)")
                    rollbackErrors.append(reopenErr)
                    ScanLog.shared.write("CRITICAL: \(reopenErr.localizedDescription)")
                }
            }

            if rollbackFailed {
                preserveSafetyDir = true
                ScanLog.shared.write("CRITICAL: Collection restore rollback failed. Preserved safety backup at: \(stagingSafetyDir.path)")
                throw DatabaseError.restoreFailed("CRITICAL: Restore rollback failed. Safety copy preserved at \(stagingSafetyDir.path). Recovery errors: \(rollbackErrors)")
            }

            throw error
        }
    }
}
