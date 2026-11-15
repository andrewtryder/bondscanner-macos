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
