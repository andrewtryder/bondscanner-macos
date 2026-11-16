import Darwin
import Foundation
import SQLite3

extension DatabaseManager {
    /// Validates SQLite database integrity at the specified URL using `PRAGMA integrity_check`.
    /// Returns true if the database exists and passes integrity check cleanly.
    /// Throws `DatabaseError.databaseCorrupted` if corruption is detected.
    /// Throws `DatabaseError.databaseLocked` if the database is locked.
    /// Throws `DatabaseError.permissionDenied` if the file cannot be accessed due to permissions.
    @discardableResult
    static func validateDatabaseIntegrity(at url: URL) throws -> Bool {
        guard !isProductionStorageProtected(destination: url) else {
            throw DatabaseError.permissionDenied("Database inspection outside temporary test storage is forbidden during test mode.")
        }
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

        guard !isProductionStorageProtected(destination: jsonURL),
              csvSourceURL.map({ !isProductionStorageProtected(destination: $0) }) ?? true,
              backupRootURL.map({ !isProductionStorageProtected(destination: $0) }) ?? true
        else {
            throw DatabaseError.permissionDenied("Migration paths are protected during test mode.")
        }

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
