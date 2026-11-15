import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SQLite3

var isTestModeActive: Bool {
    ProcessInfo.processInfo.environment["BONDSCANNER_TEST_MODE"] == "1" || NSClassFromString("XCTestCase") != nil
}

final class StorageConfiguration {
    static let shared = StorageConfiguration()
    private let lock = NSLock()
    private var customOutputRoot: URL?
    private var customBackupsRoot: URL?
    private var customProductionRoot: URL?
    private var launchOutputRoot: URL?

    static var defaultOutputRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true)
    }

    var outputRoot: URL {
        lock.lock()
        defer { lock.unlock() }
        if let custom = customOutputRoot {
            return custom
        }
        if let env = ProcessInfo.processInfo.environment["BONDSCANNER_OUTPUT_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return launchOutputRoot ?? Self.defaultOutputRoot
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

    var productionRoot: URL {
        lock.lock()
        defer { lock.unlock() }
        if let custom = customProductionRoot {
            return custom
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true)
    }

    func setCustomOutputRoot(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customOutputRoot = url
    }

    /// Called before startup initializes the database or other collection services.
    /// Never change this in response to a Settings action during a running session.
    func setLaunchOutputRoot(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        launchOutputRoot = url
    }

    func setCustomBackupsRoot(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customBackupsRoot = url
    }

    func setCustomProductionRoot(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        customProductionRoot = url
    }

    func setCustomRoots(outputRoot: URL?, backupsRoot: URL?, productionRoot: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        customOutputRoot = outputRoot
        customBackupsRoot = backupsRoot
        customProductionRoot = productionRoot
    }

    func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        customOutputRoot = nil
        customBackupsRoot = nil
        customProductionRoot = nil
        launchOutputRoot = nil
    }
}

enum CollectionSwitchAction: String, Codable {
    case copy, open, new
}

struct PendingCollectionSwitch: Codable, Equatable {
    let sourcePath: String
    let destinationPath: String
    let action: CollectionSwitchAction
}

struct CollectionLocationState: Codable, Equatable {
    var activePath: String?
    var pending: PendingCollectionSwitch?
}

/// One defaults value keeps the active location and pending request together.
/// Tests inject a separate defaults suite and never read the production preference.
final class CollectionLocationPreferences {
    private let defaults: UserDefaults
    private let key = "collectionLocationState.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> CollectionLocationState {
        guard let value = defaults.object(forKey: key) else {
            return CollectionLocationState(activePath: nil, pending: nil)
        }
        guard let data = value as? Data else {
            throw DatabaseError.restoreFailed("The saved collection location is invalid.")
        }
        do {
            return try JSONDecoder().decode(CollectionLocationState.self, from: data)
        } catch {
            throw DatabaseError.restoreFailed("The saved collection location could not be decoded.")
        }
    }

    func save(_ state: CollectionLocationState) throws {
        try defaults.set(JSONEncoder().encode(state), forKey: key)
    }

    /// Publish the preference only after the requested collection has been verified.
    func applyPending(backups: URL) throws -> URL {
        var state = try load()
        guard let request = state.pending else {
            throw DatabaseError.restoreFailed("No collection change is pending.")
        }
        let previous = state.activePath ?? StorageConfiguration.defaultOutputRoot.path
        guard request.sourcePath == previous else {
            throw DatabaseError.restoreFailed("The pending change does not match the saved collection location.")
        }
        let destination = try CollectionSwitchCoordinator.apply(request, backups: backups)
        state.activePath = destination.path
        state.pending = nil
        try save(state)
        return destination
    }
}

/// Read-only checks performed before a directory can become an active collection.
/// In particular, a missing database is never interpreted as an empty collection.
enum CollectionValidator {
    private static func fail(_ message: String) -> DatabaseError {
        .restoreFailed(message)
    }

    /// Only a genuinely empty folder or an explicit legacy JSON collection may
    /// initialize a previously absent database on a first launch.
    static func validateFirstLaunch(root: URL) throws {
        guard !isProductionStorageProtected(destination: root) else {
            throw fail("Production storage is protected during tests.")
        }
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &directory) else { return }
        guard directory.boolValue else { throw fail("The collection location is not a folder.") }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw fail("The collection folder cannot be a symbolic link.")
        }
        let names = try fm.contentsOfDirectory(atPath: root.path)
        for name in ["bonds.sqlite3", "bonds.sqlite3-wal", "bonds.sqlite3-shm", "records.json", "bonds.csv", "scan-debug.log", "photos"] {
            guard (try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent(name).path)) == nil else {
                throw fail("The collection contains an unsafe symbolic link: \(name)")
            }
        }
        let jsonURL = root.appendingPathComponent("records.json")
        if names.contains("records.json") {
            let values = try jsonURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw fail("The legacy export is not a regular file.") }
            let records = try JSONDecoder().decode([BondRecord].self, from: Data(contentsOf: jsonURL))
            if !records.isEmpty {
                return
            }
        }
        for name in names {
            if name == "records.json" {
                continue
            }
            if name == "photos" {
                let photos = root.appendingPathComponent(name, isDirectory: true)
                let values = try photos.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true, try fm.contentsOfDirectory(atPath: photos.path).isEmpty {
                    continue
                }
            }
            throw fail("The database is missing but the folder contains files. They were left untouched; restore the collection before continuing.")
        }
    }

    static func validate(root: URL, backups: URL) throws -> [BondRecord] {
        let fm = FileManager.default
        guard root.isFileURL, !isProductionStorageProtected(destination: root) else {
            throw fail("Collection location is not accessible in test mode or is not a local file URL.")
        }
        let rootPath = root.standardizedFileURL.path
        let backupPath = backups.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        func contains(_ parent: String, _ child: String) -> Bool {
            parent == child || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
        }
        guard !contains(resolvedRoot, backupPath), !contains(backupPath, resolvedRoot)
        else {
            throw fail("The collection and backup locations must not overlap.")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw fail("The collection folder is missing or is not a directory: \(rootPath)")
        }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isWritableKey])
        guard rootValues.isSymbolicLink != true, rootValues.isWritable == true else {
            throw fail("The collection folder must be writable and cannot be a symbolic link.")
        }
        // SQLite and the export/log writers must never follow links into another tree.
        for name in ["bonds.sqlite3", "bonds.sqlite3-wal", "bonds.sqlite3-shm", "records.json", "bonds.csv", "scan-debug.log", "photos"] {
            let path = root.appendingPathComponent(name).path
            guard (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else {
                throw fail("The collection contains an unsafe symbolic link: \(name)")
            }
            var childIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &childIsDirectory) {
                guard childIsDirectory.boolValue == (name == "photos") else {
                    throw fail("The collection contains an unexpected item at \(name).")
                }
                if name != "photos" {
                    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { throw fail("The collection contains a non-regular file at \(name).") }
                    let attributes = try fm.attributesOfItem(atPath: path)
                    if let links = attributes[.referenceCount] as? NSNumber, links.intValue > 1 {
                        throw fail("The collection contains a hard-linked writable file at \(name).")
                    }
                }
            }
        }
        let dbURL = root.appendingPathComponent("bonds.sqlite3")
        guard fm.fileExists(atPath: dbURL.path) else {
            throw fail("The selected folder does not contain bonds.sqlite3.")
        }
        let dbValues = try dbURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
        guard dbValues.isRegularFile == true, dbValues.isSymbolicLink != true, dbValues.isWritable == true else {
            throw fail("The collection database must be a writable regular file, not a symbolic link.")
        }
        _ = try DatabaseManager.validateDatabaseIntegrity(at: dbURL)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle = db else {
            if let db = db {
                sqlite3_close_v2(db)
            }
            throw fail("The collection database could not be opened.")
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement = statement
        else {
            throw fail("The collection schema could not be read.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int(statement, 0) == DatabaseManager.schemaVersion
        else {
            throw fail("The collection database has an incompatible schema version.")
        }
        var columnsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(bonds);", -1, &columnsStatement, nil) == SQLITE_OK,
              let columnsStatement = columnsStatement
        else {
            throw fail("The collection's bond table could not be inspected.")
        }
        defer { sqlite3_finalize(columnsStatement) }
        var columns = Set<String>()
        var hasPrimaryKey = false
        while true {
            let step = sqlite3_step(columnsStatement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW, let name = sqlite3_column_text(columnsStatement, 1) else {
                throw fail("The collection's bond table is malformed.")
            }
            let column = String(cString: name)
            columns.insert(column)
            if column == "id", sqlite3_column_int(columnsStatement, 5) == 1 {
                hasPrimaryKey = true
            }
        }
        let requiredColumns: Set = ["id", "sort_order", "captured_at", "series", "serial_number", "normalized_serial",
                                    "issue_month", "issue_year", "denomination", "status", "registered_owner", "second_name",
                                    "second_role", "address", "tax_id", "issuing_agent", "dating_stamp", "notes", "photo_path",
                                    "source_photo_path", "raw_ocr", "record_json", "updated_at"]
        guard hasPrimaryKey, requiredColumns.isSubset(of: columns) else {
            throw fail("The collection's bond table is incompatible with this version of Bond Scanner.")
        }
        // INSERT OR REPLACE is safe only for the schema the app owns. Extra
        // triggers, tables, or unique constraints could delete unrelated rows.
        var objectsStatement: OpaquePointer?
        let objectsSQL = "SELECT COUNT(*) FROM sqlite_master WHERE (type = 'trigger' AND tbl_name = 'bonds') OR (type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'bonds');"
        guard sqlite3_prepare_v2(handle, objectsSQL, -1, &objectsStatement, nil) == SQLITE_OK,
              let objectsStatement = objectsStatement
        else {
            throw fail("The collection schema could not be inspected.")
        }
        defer { sqlite3_finalize(objectsStatement) }
        guard sqlite3_step(objectsStatement) == SQLITE_ROW, sqlite3_column_int(objectsStatement, 0) == 0 else {
            throw fail("The collection contains unsupported database tables or triggers.")
        }
        var indexesStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA index_list(bonds);", -1, &indexesStatement, nil) == SQLITE_OK,
              let indexesStatement = indexesStatement
        else {
            throw fail("The collection indexes could not be inspected.")
        }
        defer { sqlite3_finalize(indexesStatement) }
        while true {
            let step = sqlite3_step(indexesStatement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW, let origin = sqlite3_column_text(indexesStatement, 3) else {
                throw fail("The collection indexes are malformed.")
            }
            if sqlite3_column_int(indexesStatement, 2) != 0, String(cString: origin) != "pk" {
                throw fail("The collection contains an unsupported unique index.")
            }
        }
        var recordsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id, record_json FROM bonds;", -1, &recordsStatement, nil) == SQLITE_OK,
              let recordsStatement = recordsStatement
        else {
            throw fail("The collection records could not be read.")
        }
        defer { sqlite3_finalize(recordsStatement) }
        var records: [BondRecord] = []
        var recordIDs = Set<String>()
        while true {
            let step = sqlite3_step(recordsStatement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW,
                  let id = sqlite3_column_text(recordsStatement, 0),
                  let json = sqlite3_column_text(recordsStatement, 1),
                  let data = String(cString: json).data(using: .utf8),
                  let record = try? JSONDecoder().decode(BondRecord.self, from: data),
                  !record.id.isEmpty, record.id == String(cString: id), recordIDs.insert(record.id).inserted
            else {
                throw fail("The collection contains malformed or inconsistent records.")
            }
            records.append(record)
        }
        for record in records {
            var paths = [record.photo, record.sourcePhoto]
            paths.append(contentsOf: record.associatedPhotos ?? [])
            paths.append(contentsOf: record.fieldPhoto.map { Array($0.values) } ?? [])
            for path in Set(paths.filter { !$0.isEmpty }) {
                guard path.hasPrefix("photos/") else {
                    throw fail("A photograph reference is outside the photos folder: \(path)")
                }
                let url = try PathSecurity.validateSafeRelativePath(path, within: root)
                guard fm.fileExists(atPath: url.path) else {
                    throw fail("A referenced photograph is missing: \(path)")
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw fail("A photograph is not a regular file: \(path)")
                }
            }
        }
        return records
    }
}

/// Applies a request only during startup, before any shared database or capture work exists.
enum CollectionSwitchCoordinator {
    private static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DatabaseError.restoreFailed("Could not open a staged item for synchronization: \(url.path)") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DatabaseError.restoreFailed("Could not synchronize a staged item: \(url.path)") }
    }

    private static func syncTree(_ root: URL) throws {
        var directories: [URL] = [root]
        var enumerationError: Error?
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw DatabaseError.restoreFailed("Could not inspect staged files for synchronization.") }
        for case let item as URL in items {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw DatabaseError.restoreFailed("Staging contains a symbolic link.") }
            if values.isRegularFile == true {
                try sync(item)
            } else if values.isDirectory == true {
                directories.append(item)
            } else {
                throw DatabaseError.restoreFailed("Staging contains an unsupported file.")
            }
        }
        if let error = enumerationError {
            throw error
        }
        for directory in directories.reversed() {
            try sync(directory)
        }
    }

    private static func filesMatch(_ source: URL, _ destination: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forReadingFrom: destination)
        defer { try? output.close() }
        while true {
            let original = try input.read(upToCount: 1_048_576) ?? Data()
            let copied = try output.read(upToCount: 1_048_576) ?? Data()
            if original != copied {
                return false
            }
            if original.isEmpty {
                return true
            }
        }
    }

    static func apply(_ request: PendingCollectionSwitch, backups: URL, failAfterSnapshot: Bool = false) throws -> URL {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: request.sourcePath, isDirectory: true).standardizedFileURL
        let destination = URL(fileURLWithPath: request.destinationPath, isDirectory: true).standardizedFileURL
        guard source.path == request.sourcePath, destination.path == request.destinationPath,
              source.path != destination.path,
              !isProductionStorageProtected(destination: source), !isProductionStorageProtected(destination: destination)
        else {
            throw DatabaseError.restoreFailed("Invalid or protected collection location.")
        }
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedBackups = backups.resolvingSymlinksInPath().standardizedFileURL.path
        func overlaps(_ a: String, _ b: String) -> Bool {
            a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/") || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
        }
        guard !overlaps(resolvedSource, resolvedDestination), !overlaps(resolvedBackups, resolvedDestination) else {
            throw DatabaseError.restoreFailed("The source, destination, and backup folders must not overlap.")
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue else {
            throw DatabaseError.restoreFailed("The selected destination folder is unavailable.")
        }
        let destinationValues = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isWritableKey])
        guard destinationValues.isSymbolicLink != true, destinationValues.isWritable == true else {
            throw DatabaseError.restoreFailed("The destination must be writable and cannot be a symbolic link.")
        }
        if request.action == .open {
            _ = try CollectionValidator.validate(root: destination, backups: backups)
            return destination
        }
        guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else {
            throw DatabaseError.restoreFailed("The destination is not empty. No files were overwritten.")
        }
        let staging = destination.appendingPathComponent(".bondscanner-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        if request.action == .copy {
            let sourceRecords = try CollectionValidator.validate(root: source, backups: backups)
            // Reject symlinks and special files before copying any source tree.
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else {
                throw DatabaseError.restoreFailed("Could not inspect the source collection.")
            }
            for case let item as URL in enumerator {
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                    throw DatabaseError.restoreFailed("The source collection contains a symbolic link or unsupported file: \(item.path)")
                }
            }
            if let error = enumerationError {
                throw error
            }
            let db = try DatabaseManager(url: source.appendingPathComponent("bonds.sqlite3"))
            try db.backupDatabase(to: staging.appendingPathComponent("bonds.sqlite3"))
            db.close()
            if failAfterSnapshot {
                throw DatabaseError.restoreFailed("Injected copy interruption.")
            }
            for name in try fm.contentsOfDirectory(atPath: source.path) where !["bonds.sqlite3", "bonds.sqlite3-wal", "bonds.sqlite3-shm"].contains(name) {
                try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            var verifyError: Error?
            guard let copies = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], errorHandler: { _, error in
                verifyError = error
                return false
            }) else {
                throw DatabaseError.restoreFailed("Could not inspect the copied collection.")
            }
            let stagingPrefix = staging.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            for case let copy as URL in copies {
                let values = try copy.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw DatabaseError.restoreFailed("A copied file is a symbolic link.") }
                let resolvedCopy = copy.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedCopy.hasPrefix(stagingPrefix) else { throw DatabaseError.restoreFailed("A copied file escaped staging.") }
                let relative = String(resolvedCopy.dropFirst(stagingPrefix.count))
                if relative == "bonds.sqlite3" {
                    continue
                }
                if values.isRegularFile == true {
                    let original = try PathSecurity.validateSafeRelativePath(relative, within: source)
                    guard try filesMatch(original, copy) else {
                        throw DatabaseError.restoreFailed("A copied file differs from its source: \(relative)")
                    }
                }
            }
            if let error = verifyError {
                throw error
            }
            let copiedRecords = try CollectionValidator.validate(root: staging, backups: backups)
            guard copiedRecords.sorted(by: { $0.id < $1.id }) == sourceRecords.sorted(by: { $0.id < $1.id }) else {
                throw DatabaseError.restoreFailed("The source changed while the collection was copied. The original remains active.")
            }
        } else {
            let db = try DatabaseManager(url: staging.appendingPathComponent("bonds.sqlite3"))
            db.close()
            _ = try CollectionValidator.validate(root: staging, backups: backups)
        }
        try syncTree(staging)
        // Never replace a file: if publication is interrupted, leave any published
        // files in place and retain the old active preference for recovery.
        for name in try fm.contentsOfDirectory(atPath: staging.path) {
            try fm.moveItem(at: staging.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        _ = try CollectionValidator.validate(root: destination, backups: backups)
        try sync(destination)
        return destination
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
    let configuredProd = StorageConfiguration.shared.productionRoot.standardized.path
    let defaultHomeProd = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true).standardized.path
    let destPath = destination.standardized.path
    if destPath == configuredProd || destPath.hasPrefix(configuredProd + "/")
        || destPath == defaultHomeProd || destPath.hasPrefix(defaultHomeProd + "/")
    {
        return true
    }
    // A temporary-looking path can still point at production through a symlink.
    let resolvedDest = destination.resolvingSymlinksInPath().standardized.path
    let resolvedConfigured = configuredProd == defaultHomeProd ? defaultHomeProd : StorageConfiguration.shared.productionRoot.resolvingSymlinksInPath().standardized.path
    if resolvedDest == resolvedConfigured || resolvedDest.hasPrefix(resolvedConfigured + "/")
        || resolvedDest == defaultHomeProd || resolvedDest.hasPrefix(defaultHomeProd + "/")
    {
        return true
    }
    // Tests may write only beneath the process's temporary directory. This also
    // protects a user's custom production collection without reading its settings.
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardized.path
    return !resolvedDest.hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/")
}

enum PathSecurity {
    /// Validates that `relativePath` is strictly relative, contains no path traversal (..),
    /// no leading slash, and when resolved against `baseDirectory`, remains strictly within `baseDirectory`
    /// without escaping via symlinks.
    @discardableResult
    static func validateSafeRelativePath(_ relativePath: String, within baseDirectory: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.restoreFailed("Empty path is invalid")
        }
        guard !trimmed.hasPrefix("/") else {
            throw DatabaseError.restoreFailed("Absolute paths are rejected: \(trimmed)")
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains("..") || components.contains(".") || components.contains("") {
            throw DatabaseError.restoreFailed("Path traversal or malformed components rejected: \(trimmed)")
        }

        let combinedURL = baseDirectory.appendingPathComponent(trimmed).standardized

        // Walk backwards to find closest existing ancestor to reliably resolve symlinks
        // even when trailing destination components do not exist yet.
        var curr = combinedURL
        var unverified: [String] = []
        while !FileManager.default.fileExists(atPath: curr.path), curr.path != "/" {
            unverified.insert(curr.lastPathComponent, at: 0)
            curr = curr.deletingLastPathComponent()
        }
        var resolvedCombined = curr.resolvingSymlinksInPath().standardized
        for c in unverified {
            resolvedCombined = resolvedCombined.appendingPathComponent(c)
        }
        resolvedCombined = resolvedCombined.standardized

        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardized
        let basePrefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
        guard resolvedCombined.path.hasPrefix(basePrefix) || resolvedCombined.path == resolvedBase.path else {
            throw DatabaseError.restoreFailed("Path resolves outside base directory: \(trimmed)")
        }
        return combinedURL
    }

    /// Verifies that a filename contains no directory separators or traversal components.
    static func validateSafeFilename(_ filename: String) throws -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.restoreFailed("Filename cannot be empty")
        }
        guard !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.contains("..") else {
            throw DatabaseError.restoreFailed("Invalid filename containing path separators or traversal: \(trimmed)")
        }
        return trimmed
    }
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
func safelyTrashPhotographs(
    for record: BondRecord,
    existingRecords: [BondRecord],
    database: DatabaseManager? = nil,
    root: URL = outputRoot
) throws -> [String] {
    if isProductionStorageProtected(destination: root) {
        throw StorageError.productionAccessForbidden("Cannot trash photographs in production storage during test mode: \(root.path)")
    }
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

    var photosToTrash: [(rel: String, url: URL)] = []

    for rel in candidatePhotos {
        // Authoritative database check if database is available; otherwise fallback to in-memory array.
        // MUST NOT fail open: any database error must propagate and prevent deletion.
        if let db = database {
            let isReferenced = try db.isPhotographReferenced(rel, excludingRecordId: record.id)
            if isReferenced {
                continue
            }
        } else if isPhotographReferenced(rel, excludingRecordId: record.id, among: existingRecords) {
            continue
        }

        // Strict path validation: reject absolute paths, .. traversal, and symlink escapes outside root.
        // Requires directory boundary matching to prevent matching similarly named sibling directories.
        guard let url = try? PathSecurity.validateSafeRelativePath(rel, within: root) else {
            ScanLog.shared.write("Attempted unsafe photograph path rejected: \(rel)")
            continue
        }
        if isProductionStorageProtected(destination: url) {
            throw StorageError.productionAccessForbidden("Cannot trash production photograph in test mode: \(url.path)")
        }

        photosToTrash.append((rel: rel, url: url))
    }

    for item in photosToTrash where FileManager.default.fileExists(atPath: item.url.path) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            trashed.append(item.rel)
        } catch {
            ScanLog.shared.write("trashItem failed for \(item.rel): \(error.localizedDescription)")
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
