import AppKit
import Foundation

protocol ReviewCoordinatorDelegate: AnyObject {
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateRecords records: [BondRecord])
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didSelectRecord record: BondRecord?)
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didChangeProgress progress: ReviewProgress)
}

/// Central coordinator for the Bond Review and Correction workflow.
/// Manages review filtering, durable SQLite persistence, atomic duplicate resolution,
/// photo caching, and selection stability across background OCR operations.
final class ReviewCoordinator {
    weak var delegate: ReviewCoordinatorDelegate?

    private(set) var allRecords: [BondRecord] = []
    private(set) var currentRecordId: String?
    var activeFilter: ReviewFilterCategory = .allReview {
        didSet {
            recalculateQueue()
        }
    }

    private var queueRecordIds: [String] = []
    private var initialSessionQueueCount: Int = 0
    private var reviewedInSessionCount: Int = 0

    /// High performance image cache for smooth queue navigation
    private let imageCache = NSCache<NSString, NSImage>()

    init(records: [BondRecord] = []) {
        imageCache.countLimit = 15
        self.allRecords = records
        recalculateQueue(resetSessionMetrics: true)
    }

    // MARK: - Queue & Selection Management

    func setAllRecords(_ records: [BondRecord]) {
        self.allRecords = records
        recalculateQueue(resetSessionMetrics: false)

        // Selection stability: ensure currentRecordId is still valid or fallback gracefully
        if let currentId = currentRecordId {
            if let updated = allRecords.first(where: { $0.id == currentId }) {
                delegate?.reviewCoordinator(self, didSelectRecord: updated)
            } else {
                currentRecordId = queueRecordIds.first
                delegate?.reviewCoordinator(self, didSelectRecord: currentRecord)
            }
        }
    }

    var currentRecord: BondRecord? {
        guard let id = currentRecordId else { return nil }
        return allRecords.first(where: { $0.id == id })
    }

    var queuedRecords: [BondRecord] {
        let set = Set(queueRecordIds)
        // Maintain queue order
        var map: [String: BondRecord] = [:]
        for r in allRecords where set.contains(r.id) {
            map[r.id] = r
        }
        return queueRecordIds.compactMap { map[$0] }
    }

    var progress: ReviewProgress {
        let remaining = allRecords.filter { $0.status == "REVIEW" || $0.status == "DUPLICATE" }.count
        let total = max(initialSessionQueueCount, reviewedInSessionCount + remaining)
        return ReviewProgress(
            reviewedInSession: reviewedInSessionCount,
            totalInQueue: total,
            remainingCount: remaining
        )
    }

    func recalculateQueue(resetSessionMetrics: Bool = false) {
        let matching = allRecords.filter { activeFilter.matches(record: $0) }
        queueRecordIds = matching.map(\.id)

        if resetSessionMetrics {
            initialSessionQueueCount = matching.count
            reviewedInSessionCount = 0
        }

        delegate?.reviewCoordinator(self, didChangeProgress: progress)
    }

    func selectRecord(id: String) {
        guard allRecords.contains(where: { $0.id == id }) else { return }
        currentRecordId = id
        delegate?.reviewCoordinator(self, didSelectRecord: currentRecord)
        preloadAdjacentPhotos()
    }

    func nextRecord() -> BondRecord? {
        guard let currentId = currentRecordId,
              let idx = queueRecordIds.firstIndex(of: currentId),
              idx + 1 < queueRecordIds.count
        else {
            return nil
        }
        selectRecord(id: queueRecordIds[idx + 1])
        return currentRecord
    }

    func previousRecord() -> BondRecord? {
        guard let currentId = currentRecordId,
              let idx = queueRecordIds.firstIndex(of: currentId),
              idx > 0
        else {
            return nil
        }
        selectRecord(id: queueRecordIds[idx - 1])
        return currentRecord
    }

    func nextUnresolvedRecord(excludingCurrent: Bool = true) -> BondRecord? {
        for id in queueRecordIds {
            if excludingCurrent, id == currentRecordId {
                continue
            }
            if let record = allRecords.first(where: { $0.id == id }), record.status == "REVIEW" || record.status == "DUPLICATE" {
                return record
            }
        }
        return nil
    }

    // MARK: - Saving & Validating Edits

    /// Persists edits to a bond record atomically to SQLite and updates review state.
    @discardableResult
    func saveRecord(
        record: BondRecord,
        userEdits: [String: String],
        confirmedFields: Set<String>,
        resolvedReasons: Set<String> = [],
        acknowledgedWarnings: Set<String> = []
    ) throws -> BondRecord {
        var updated = record

        // 1. Apply user field edits
        for (field, value) in userEdits {
            switch field {
            case "series": updated.series = value
            case "serial": updated.serial = value
            case "denomination": updated.denomination = value
            case "issueMonth": updated.issueMonth = value
            case "issueYear": updated.issueYear = value
            case "owner": updated.owner = value
            case "secondName": updated.secondName = value
            case "secondRole": updated.secondRole = value
            case "address": updated.address = value
            case "taxID": updated.taxID = value
            case "issuingAgent": updated.issuingAgent = value
            case "datingStamp": updated.datingStamp = value
            case "notes": updated.notes = value
            default: break
            }
        }

        // 2. Track user confirmed fields durably
        var allConfirmed = Set(updated.userConfirmedFields ?? [])
        for field in confirmedFields {
            allConfirmed.insert(field)
        }
        // Any explicitly edited field is automatically confirmed
        for field in userEdits.keys {
            allConfirmed.insert(field)
        }
        updated.userConfirmedFields = allConfirmed.isEmpty ? nil : Array(allConfirmed).sorted()

        // 3. Track resolved review reasons
        var allResolved = Set(updated.resolvedReviewReasons ?? [])
        for reason in resolvedReasons {
            allResolved.insert(reason)
        }
        updated.resolvedReviewReasons = allResolved.isEmpty ? nil : Array(allResolved).sorted()

        // 4. Track acknowledged warnings
        var allAck = Set(updated.acknowledgedWarnings ?? [])
        for warning in acknowledgedWarnings {
            allAck.insert(warning)
        }
        updated.acknowledgedWarnings = allAck.isEmpty ? nil : Array(allAck).sorted()

        // 5. Re-run official validation and status calculation
        let previousStatus = updated.status
        applyRequiredStatus(&updated)

        // 6. Update in-memory allRecords array
        if let idx = allRecords.firstIndex(where: { $0.id == updated.id }) {
            allRecords[idx] = updated
        }

        // 7. Persist to SQLite & schedule export
        try saveRecordLive(updated, allRecords: allRecords)

        // 8. Track review session progress
        if previousStatus == "REVIEW" && updated.status == "OK" {
            reviewedInSessionCount += 1
        }

        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
        delegate?.reviewCoordinator(self, didSelectRecord: updated)
        return updated
    }

    /// Performs Save on current changes, then immediately navigates to the next unresolved record in queue.
    func saveAndNext(
        record: BondRecord,
        userEdits: [String: String],
        confirmedFields: Set<String>,
        resolvedReasons: Set<String> = [],
        acknowledgedWarnings: Set<String> = []
    ) throws -> BondRecord? {
        _ = try saveRecord(
            record: record,
            userEdits: userEdits,
            confirmedFields: confirmedFields,
            resolvedReasons: resolvedReasons,
            acknowledgedWarnings: acknowledgedWarnings
        )

        // Find next unresolved review record
        if let next = nextUnresolvedRecord(excludingCurrent: true) {
            selectRecord(id: next.id)
            return next
        } else if let fallbackNext = nextRecord() {
            return fallbackNext
        }
        return nil
    }

    // MARK: - Duplicate Resolution

    func findDuplicateCandidate(for record: BondRecord) -> BondRecord? {
        // 1. Explicit candidate ID if stored
        if let candId = record.duplicateCandidateId,
           let cand = allRecords.first(where: { $0.id == candId })
        {
            return cand
        }

        // 2. Parse candidate ID from notes (e.g. "(id: abc12345)")
        if let match = record.notes.range(of: "\\(id:\\s*([a-zA-Z0-9_-]+)\\)", options: .regularExpression) {
            let sub = String(record.notes[match])
            let cleanId = sub.replacingOccurrences(of: "(id:", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let cand = allRecords.first(where: { $0.id.hasPrefix(cleanId) || cleanId.hasPrefix($0.id) }) {
                return cand
            }
        }

        // 3. Fallback: Search using existing near match finder
        return findNearMatchRecord(record, in: allRecords, excluding: record.id)
    }

    /// Resolves near-match conflict by keeping both records separate.
    func keepSeparate(record: BondRecord, candidate: BondRecord) throws {
        var rec = record
        var cand = candidate

        var rSet = Set(rec.resolvedReviewReasons ?? [])
        rSet.insert("near_match")
        rec.resolvedReviewReasons = Array(rSet).sorted()

        var cSet = Set(cand.resolvedReviewReasons ?? [])
        cSet.insert("near_match")
        cand.resolvedReviewReasons = Array(cSet).sorted()

        applyRequiredStatus(&rec)
        applyRequiredStatus(&cand)

        if let idx = allRecords.firstIndex(where: { $0.id == rec.id }) {
            allRecords[idx] = rec
        }
        if let idx = allRecords.firstIndex(where: { $0.id == cand.id }) {
            allRecords[idx] = cand
        }

        try saveRecordLive(rec, allRecords: allRecords)
        try saveRecordLive(cand, allRecords: allRecords)

        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
        delegate?.reviewCoordinator(self, didSelectRecord: rec)
    }

    /// Merges candidate duplicate bond into the primary bond atomically in SQLite.
    func confirmSameBond(
        primary: BondRecord,
        duplicate: BondRecord,
        preferredEdits: [String: String] = [:]
    ) throws -> BondRecord {
        var merged = primary

        // 1. Apply any preferred field choices
        for (field, value) in preferredEdits {
            switch field {
            case "series": merged.series = value
            case "serial": merged.serial = value
            case "denomination": merged.denomination = value
            case "issueMonth": merged.issueMonth = value
            case "issueYear": merged.issueYear = value
            case "owner": merged.owner = value
            case "secondName": merged.secondName = value
            case "secondRole": merged.secondRole = value
            case "address": merged.address = value
            case "taxID": merged.taxID = value
            case "issuingAgent": merged.issuingAgent = value
            case "datingStamp": merged.datingStamp = value
            case "notes": merged.notes = value
            default: break
            }
        }

        // 2. Preserve photos durably
        var photos = Set(merged.associatedPhotos ?? [])
        if !duplicate.photo.isEmpty && duplicate.photo != merged.photo {
            photos.insert(duplicate.photo)
        }
        if !duplicate.sourcePhoto.isEmpty && duplicate.sourcePhoto != merged.sourcePhoto {
            photos.insert(duplicate.sourcePhoto)
        }
        if let dupAssoc = duplicate.associatedPhotos {
            for p in dupAssoc {
                photos.insert(p)
            }
        }
        merged.associatedPhotos = photos.isEmpty ? nil : Array(photos).sorted()

        // 3. Union user confirmed fields
        var confirmed = Set(merged.userConfirmedFields ?? [])
        if let dupConfirmed = duplicate.userConfirmedFields {
            for f in dupConfirmed {
                confirmed.insert(f)
            }
        }
        for f in preferredEdits.keys {
            confirmed.insert(f)
        }
        merged.userConfirmedFields = confirmed.isEmpty ? nil : Array(confirmed).sorted()

        // 4. Resolve near_match reason
        var resolved = Set(merged.resolvedReviewReasons ?? [])
        resolved.insert("near_match")
        merged.resolvedReviewReasons = Array(resolved).sorted()

        // 5. Re-run validation status
        applyRequiredStatus(&merged)

        // 6. Execute atomic merge in SQLite (deletes duplicate, updates primary)
        try DatabaseManager.shared.atomicMerge(deleteId: duplicate.id, updatedRecord: merged)

        // 7. Update in-memory state
        allRecords.removeAll(where: { $0.id == duplicate.id })
        if let idx = allRecords.firstIndex(where: { $0.id == merged.id }) {
            allRecords[idx] = merged
        }
        scheduleAutomaticExports(records: allRecords)

        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
        delegate?.reviewCoordinator(self, didSelectRecord: merged)
        return merged
    }

    // MARK: - Stalled Processing Recovery

    func recoverStalledProcessing(record: BondRecord) throws -> BondRecord {
        var updated = record
        updated.status = "REVIEW"
        var reasons = Set(updated.reviewReasons ?? [])
        reasons.insert("stalled_processing: OCR interrupted")
        updated.reviewReasons = Array(reasons).sorted()
        applyRequiredStatus(&updated)

        if let idx = allRecords.firstIndex(where: { $0.id == updated.id }) {
            allRecords[idx] = updated
        }
        try saveRecordLive(updated, allRecords: allRecords)
        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
        delegate?.reviewCoordinator(self, didSelectRecord: updated)
        return updated
    }

    // MARK: - Reprocessing OCR

    /// Asynchronously re-runs Vision OCR on the record's original photograph.
    /// Never overwrites user-confirmed fields.
    func reprocessPhoto(for record: BondRecord) async throws -> (updated: BondRecord, suggestions: [String: String]) {
        let photoRel = record.sourcePhoto.isEmpty ? record.photo : record.sourcePhoto
        guard !photoRel.isEmpty else {
            throw NSError(domain: "BondScanner", code: 404, userInfo: [NSLocalizedDescriptionKey: "No saved photo file found for record"])
        }
        let url = outputRoot.appendingPathComponent(photoRel)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "BondScanner", code: 404, userInfo: [NSLocalizedDescriptionKey: "Photo file does not exist at \(url.path)"])
        }

        guard let cgImg = cgImageFromFile(url) else {
            throw NSError(domain: "BondScanner", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not decode photograph image"])
        }

        // Run OCR on background utility thread
        let ocrResult: OCRResult = await Task.detached(priority: .userInitiated) {
            scanImage(cgImg)
        }.value

        var updated = record
        var suggestions: [String: String] = [:]
        let confirmed = Set(updated.userConfirmedFields ?? [])

        let ocrRec = ocrResult.record
        let fields: [(key: String, ocrVal: String, currVal: String)] = [
            ("series", ocrRec.series, updated.series),
            ("serial", ocrRec.serial, updated.serial),
            ("denomination", ocrRec.denomination, updated.denomination),
            ("issueMonth", ocrRec.issueMonth, updated.issueMonth),
            ("issueYear", ocrRec.issueYear, updated.issueYear),
            ("owner", ocrRec.owner, updated.owner),
            ("secondName", ocrRec.secondName, updated.secondName),
            ("address", ocrRec.address, updated.address),
            ("issuingAgent", ocrRec.issuingAgent, updated.issuingAgent),
            ("datingStamp", ocrRec.datingStamp, updated.datingStamp),
        ]

        for item in fields {
            guard !item.ocrVal.isEmpty else { continue }
            if confirmed.contains(item.key) {
                // If user confirmed, do NOT overwrite, but provide as suggestion if different
                if item.ocrVal != item.currVal {
                    suggestions[item.key] = item.ocrVal
                }
            } else {
                // Not confirmed: apply newly scanned value if it was empty or uncertain
                if item.currVal.isEmpty || (updated.fieldConfidence?[item.key] ?? "") == "uncertain" {
                    switch item.key {
                    case "series": updated.series = item.ocrVal
                    case "serial": updated.serial = item.ocrVal
                    case "denomination": updated.denomination = item.ocrVal
                    case "issueMonth": updated.issueMonth = item.ocrVal
                    case "issueYear": updated.issueYear = item.ocrVal
                    case "owner": updated.owner = item.ocrVal
                    case "secondName": updated.secondName = item.ocrVal
                    case "address": updated.address = item.ocrVal
                    case "issuingAgent": updated.issuingAgent = item.ocrVal
                    case "datingStamp": updated.datingStamp = item.ocrVal
                    default: break
                    }
                }
            }
        }

        // Merge raw OCR if new content was discovered
        if !ocrRec.rawOCR.isEmpty, !updated.rawOCR.contains(ocrRec.rawOCR.prefix(40)) {
            updated.additionalOCR = (updated.additionalOCR == nil)
                ? ocrRec.rawOCR
                : "\(updated.additionalOCR!)\n---\n\(ocrRec.rawOCR)"
        }

        applyRequiredStatus(&updated)

        // Persist to database
        if let idx = allRecords.firstIndex(where: { $0.id == updated.id }) {
            allRecords[idx] = updated
        }
        try saveRecordLive(updated, allRecords: allRecords)

        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
        delegate?.reviewCoordinator(self, didSelectRecord: updated)
        return (updated, suggestions)
    }

    // MARK: - Image Caching

    func loadImage(relativePath: String) -> NSImage? {
        guard !relativePath.isEmpty else { return nil }
        let key = relativePath as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let fileURL = outputRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path), let img = NSImage(contentsOf: fileURL) else { return nil }

        imageCache.setObject(img, forKey: key)
        return img
    }

    private func preloadAdjacentPhotos() {
        guard let currentId = currentRecordId,
              let idx = queueRecordIds.firstIndex(of: currentId) else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let neighbors = [idx - 1, idx + 1]
            for nIdx in neighbors where nIdx >= 0 && nIdx < self.queueRecordIds.count {
                let id = self.queueRecordIds[nIdx]
                if let rec = self.allRecords.first(where: { $0.id == id }) {
                    let path = rec.photo.isEmpty ? rec.sourcePhoto : rec.photo
                    _ = self.loadImage(relativePath: path)
                }
            }
        }
    }
}
