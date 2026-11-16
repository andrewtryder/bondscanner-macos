import AppKit
import CoreGraphics
import Foundation

extension ReviewCoordinator {
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
        updated.revision = (updated.revision ?? 1) + 1

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

        // 6. Formulate speculative records array for export
        var proposedRecords = allRecords
        if let idx = proposedRecords.firstIndex(where: { $0.id == updated.id }) {
            proposedRecords[idx] = updated
        } else {
            proposedRecords.append(updated)
        }

        // 7. Persist to SQLite & schedule export BEFORE updating self.allRecords.
        // If persistence throws, self.allRecords is untouched and rolls back reliably.
        try saveRecordLive(updated, allRecords: proposedRecords)

        // 8. Commit to in-memory state only after persistence succeeds
        self.allRecords = proposedRecords
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
        let queueBeforeSave = queueRecordIds
        _ = try saveRecord(
            record: record,
            userEdits: userEdits,
            confirmedFields: confirmedFields,
            resolvedReasons: resolvedReasons,
            acknowledgedWarnings: acknowledgedWarnings
        )

        // Find next unresolved review record starting AFTER current record in the queue
        if let next = nextUnresolvedRecord(excludingCurrent: true, startingAfterCurrent: true, priorQueueIds: queueBeforeSave) {
            selectRecord(id: next.id)
            return next
        } else if let fallbackNext = nextRecord() {
            return fallbackNext
        }
        return nil
    }

    // MARK: - Duplicate Resolution

    func findDuplicateCandidate(for record: BondRecord) -> BondRecord? {
        let resolved = Set(record.resolvedReviewReasons ?? [])

        // 1. Explicit candidate ID if stored
        if let candId = record.duplicateCandidateId,
           !resolved.contains("keep_separate: \(candId)"),
           !resolved.contains("keep_separate:\(candId)"),
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
            let isKeptSeparate = resolved.contains(where: { key in
                guard key.hasPrefix("keep_separate:") else { return false }
                let cand = key.replacingOccurrences(of: "keep_separate:", with: "").trimmingCharacters(in: .whitespaces)
                return cand == cleanId || cleanId.hasPrefix(cand) || cand.hasPrefix(cleanId)
            })
            if !isKeptSeparate, let cand = allRecords.first(where: { $0.id.hasPrefix(cleanId) || cleanId.hasPrefix($0.id) }) {
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

        let recReasonsToResolve = [
            "near_match: \(cand.id)",
            "near_match: \(cand.id.prefix(8))",
            "near_match",
            "keep_separate: \(cand.id)",
            "keep_separate:\(cand.id)",
        ]
        var rSet = Set(rec.resolvedReviewReasons ?? [])
        for r in recReasonsToResolve {
            rSet.insert(r)
        }
        rec.resolvedReviewReasons = Array(rSet).sorted()

        let candReasonsToResolve = [
            "near_match: \(rec.id)",
            "near_match: \(rec.id.prefix(8))",
            "near_match",
            "keep_separate: \(rec.id)",
            "keep_separate:\(rec.id)",
        ]
        var cSet = Set(cand.resolvedReviewReasons ?? [])
        for r in candReasonsToResolve {
            cSet.insert(r)
        }
        cand.resolvedReviewReasons = Array(cSet).sorted()

        rec.revision = (rec.revision ?? 1) + 1
        cand.revision = (cand.revision ?? 1) + 1

        applyRequiredStatus(&rec)
        applyRequiredStatus(&cand)

        // Transactional update in SQLite: either both records persist or both roll back
        try DatabaseManager.shared.atomicUpdateKeepSeparate(recordA: rec, recordB: cand)

        // Only after commit succeeds, update in-memory state:
        if let idx = allRecords.firstIndex(where: { $0.id == rec.id }) {
            allRecords[idx] = rec
        }
        if let idx = allRecords.firstIndex(where: { $0.id == cand.id }) {
            allRecords[idx] = cand
        }
        scheduleAutomaticExports(records: allRecords)

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
        let primConfirmed = Set(primary.userConfirmedFields ?? [])
        let dupConfirmed = Set(duplicate.userConfirmedFields ?? [])

        func getVal(_ rec: BondRecord, field: String) -> String {
            switch field {
            case "series": return rec.series
            case "serial": return rec.serial
            case "denomination": return rec.denomination
            case "issueMonth": return rec.issueMonth
            case "issueYear": return rec.issueYear
            case "owner": return rec.owner
            case "secondName": return rec.secondName
            case "secondRole": return rec.secondRole
            case "address": return rec.address
            case "taxID": return rec.taxID
            case "issuingAgent": return rec.issuingAgent
            case "datingStamp": return rec.datingStamp
            case "notes": return rec.notes
            default: return ""
            }
        }

        let fieldsToCheck = ["series", "serial", "denomination", "issueMonth", "issueYear", "owner", "secondName", "secondRole", "address", "taxID", "issuingAgent", "datingStamp"]

        // Require explicit resolution of conflicting confirmed values
        for f in fieldsToCheck {
            let pVal = getVal(primary, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let dVal = getVal(duplicate, field: f).trimmingCharacters(in: .whitespacesAndNewlines)

            if !pVal.isEmpty && !dVal.isEmpty && pVal != dVal {
                if (primConfirmed.contains(f) && dupConfirmed.contains(f)) || (dupConfirmed.contains(f) && preferredEdits[f] == nil) {
                    if preferredEdits[f] == nil {
                        throw ReviewError.conflictingConfirmedValues(field: f, primaryValue: pVal, candidateValue: dVal)
                    }
                }
            }
        }

        var merged = primary
        merged.revision = (merged.revision ?? 1) + 1

        // 1. Apply any preferred field choices, or inherit confirmed duplicate values when primary is empty
        for f in fieldsToCheck {
            let pVal = getVal(primary, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let dVal = getVal(duplicate, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let chosenValue: String?
            if let explicit = preferredEdits[f] {
                chosenValue = explicit
            } else if pVal.isEmpty && !dVal.isEmpty && dupConfirmed.contains(f) {
                chosenValue = dVal
            } else {
                chosenValue = nil
            }
            guard let value = chosenValue else { continue }
            switch f {
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
        if let notesEdit = preferredEdits["notes"] {
            merged.notes = notesEdit
        }

        // 2. Preserve all associated original photographs durably
        var photos = Set(merged.associatedPhotos ?? [])
        let allPhotos = [primary.photo, primary.sourcePhoto, duplicate.photo, duplicate.sourcePhoto]
        for p in allPhotos where !p.isEmpty {
            if p != merged.photo && p != merged.sourcePhoto {
                photos.insert(p)
            }
        }
        if let primAssoc = primary.associatedPhotos {
            for p in primAssoc where !p.isEmpty && p != merged.photo && p != merged.sourcePhoto {
                photos.insert(p)
            }
        }
        if let dupAssoc = duplicate.associatedPhotos {
            for p in dupAssoc where !p.isEmpty && p != merged.photo && p != merged.sourcePhoto {
                photos.insert(p)
            }
        }
        merged.associatedPhotos = photos.isEmpty ? nil : Array(photos).sorted()

        // 2b. Preserve field-level photograph provenance
        var fieldPhotos = primary.fieldPhoto ?? [:]
        var fieldCaptureIds = primary.fieldCaptureId ?? [:]
        for f in fieldsToCheck {
            let mVal = getVal(merged, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let pVal = getVal(primary, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let dVal = getVal(duplicate, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            if !dVal.isEmpty && (pVal.isEmpty || mVal == dVal) {
                let dPhoto = duplicate.fieldPhoto?[f] ?? (duplicate.sourcePhoto.isEmpty ? duplicate.photo : duplicate.sourcePhoto)
                if !dPhoto.isEmpty {
                    fieldPhotos[f] = dPhoto
                    if dPhoto != merged.photo && dPhoto != merged.sourcePhoto {
                        var curAssoc = Set(merged.associatedPhotos ?? [])
                        curAssoc.insert(dPhoto)
                        merged.associatedPhotos = Array(curAssoc).sorted()
                    }
                }
                let dCap = duplicate.fieldCaptureId?[f] ?? duplicate.id
                if !dCap.isEmpty {
                    fieldCaptureIds[f] = dCap
                }
            }
        }
        merged.fieldPhoto = fieldPhotos.isEmpty ? nil : fieldPhotos
        merged.fieldCaptureId = fieldCaptureIds.isEmpty ? nil : fieldCaptureIds

        // 3. Retain confirmed-field status ONLY for values explicitly selected and retained
        var finalConfirmed = Set<String>()
        for f in fieldsToCheck {
            let mVal = getVal(merged, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let pVal = getVal(primary, field: f).trimmingCharacters(in: .whitespacesAndNewlines)
            let dVal = getVal(duplicate, field: f).trimmingCharacters(in: .whitespacesAndNewlines)

            if preferredEdits[f] != nil {
                // Explicitly selected/edited by user
                finalConfirmed.insert(f)
            } else if primConfirmed.contains(f) && mVal == pVal {
                // Primary had confirmed value and it was retained
                finalConfirmed.insert(f)
            } else if dupConfirmed.contains(f) && pVal.isEmpty && mVal == dVal {
                // Duplicate had confirmed value and primary was empty
                finalConfirmed.insert(f)
            }
        }
        merged.userConfirmedFields = finalConfirmed.isEmpty ? nil : Array(finalConfirmed).sorted()

        // 4. Resolve exact near_match reason keys
        var resolved = Set(merged.resolvedReviewReasons ?? [])
        resolved.insert("near_match: \(duplicate.id)")
        resolved.insert("near_match: \(duplicate.id.prefix(8))")
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
        updated.revision = (updated.revision ?? 0) + 1
        updated.status = "REVIEW"
        var reasons = Set(updated.reviewReasons ?? [])
        reasons.insert("stalled_processing: OCR interrupted")
        updated.reviewReasons = Array(reasons).sorted()
        applyRequiredStatus(&updated)

        var proposed = allRecords
        if let idx = proposed.firstIndex(where: { $0.id == updated.id }) {
            proposed[idx] = updated
        } else {
            throw ReviewError.recordNotFound(updated.id)
        }
        try saveRecordLive(updated, allRecords: proposed)
        allRecords = proposed
        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
        delegate?.reviewCoordinator(self, didSelectRecord: updated)
        return updated
    }

    // MARK: - Reprocessing OCR

    /// Asynchronously re-runs Vision OCR on the record's original photograph.
    /// Never overwrites user-confirmed fields or unsaved edits, applies against latest persisted record,
    /// and presents conflicting OCR results as reviewable suggestions.
    func reprocessPhoto(for record: BondRecord, userActiveEdits: [String: String] = [:]) async throws -> (updated: BondRecord, suggestions: [String: String]) {
        let photoRel = record.sourcePhoto.isEmpty ? record.photo : record.sourcePhoto
        guard !photoRel.isEmpty else {
            throw ReviewError.photoFileNotFound("No saved photo file found for record")
        }
        let root = customOutputRoot ?? outputRoot
        let url = root.appendingPathComponent(photoRel)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReviewError.photoFileNotFound("Photo file does not exist at \(url.path)")
        }

        guard let cgImg = cgImageFromFile(url) else {
            throw ReviewError.ocrFailed("Could not decode photograph image")
        }

        let targetId = record.id

        // Run OCR on background utility thread
        let ocrResult: OCRResult = await Task.detached(priority: .userInitiated) {
            scanImage(cgImg)
        }.value

        return try await MainActor.run {
            // Retrieve latest record from in-memory collection (optimistic concurrency)
            guard var latest = self.allRecords.first(where: { $0.id == targetId }) else {
                throw ReviewError.recordNotFound(targetId)
            }

            var suggestions: [String: String] = [:]
            let confirmed = Set(latest.userConfirmedFields ?? [])
            let ocrRec = ocrResult.record

            let fields: [(key: String, ocrVal: String, currVal: String)] = [
                ("series", ocrRec.series, latest.series),
                ("serial", ocrRec.serial, latest.serial),
                ("denomination", ocrRec.denomination, latest.denomination),
                ("issueMonth", ocrRec.issueMonth, latest.issueMonth),
                ("issueYear", ocrRec.issueYear, latest.issueYear),
                ("owner", ocrRec.owner, latest.owner),
                ("secondName", ocrRec.secondName, latest.secondName),
                ("address", ocrRec.address, latest.address),
                ("issuingAgent", ocrRec.issuingAgent, latest.issuingAgent),
                ("datingStamp", ocrRec.datingStamp, latest.datingStamp),
            ]

            for item in fields {
                guard !item.ocrVal.isEmpty else { continue }
                // If user edited this field in active draft, NEVER overwrite: present as suggestion if different
                if let userEdit = userActiveEdits[item.key] {
                    if item.ocrVal != userEdit {
                        suggestions[item.key] = item.ocrVal
                    }
                    continue
                }

                if confirmed.contains(item.key) {
                    // If user confirmed, do NOT overwrite, but provide as suggestion if different
                    if item.ocrVal != item.currVal {
                        suggestions[item.key] = item.ocrVal
                    }
                } else {
                    // Not confirmed: apply newly scanned value if it was empty or uncertain
                    if item.currVal.isEmpty || (latest.fieldConfidence?[item.key] ?? "") == "uncertain" {
                        switch item.key {
                        case "series": latest.series = item.ocrVal
                        case "serial": latest.serial = item.ocrVal
                        case "denomination": latest.denomination = item.ocrVal
                        case "issueMonth": latest.issueMonth = item.ocrVal
                        case "issueYear": latest.issueYear = item.ocrVal
                        case "owner": latest.owner = item.ocrVal
                        case "secondName": latest.secondName = item.ocrVal
                        case "address": latest.address = item.ocrVal
                        case "issuingAgent": latest.issuingAgent = item.ocrVal
                        case "datingStamp": latest.datingStamp = item.ocrVal
                        default: break
                        }
                    } else if item.ocrVal != item.currVal {
                        // Conflicting with existing value: provide as suggestion
                        suggestions[item.key] = item.ocrVal
                    }
                }
            }

            // Merge raw OCR if new content was discovered
            if !ocrRec.rawOCR.isEmpty, !latest.rawOCR.contains(ocrRec.rawOCR.prefix(40)) {
                latest.additionalOCR = (latest.additionalOCR == nil)
                    ? ocrRec.rawOCR
                    : "\(latest.additionalOCR!)\n---\n\(ocrRec.rawOCR)"
            }

            latest.revision = (latest.revision ?? 1) + 1
            applyRequiredStatus(&latest)

            // Persist the proposed snapshot before publishing it.  A failed write leaves
            // both the displayed record and retry source untouched.
            guard let idx = self.allRecords.firstIndex(where: { $0.id == latest.id }) else {
                throw ReviewError.recordNotFound(latest.id)
            }
            var proposed = self.allRecords
            proposed[idx] = latest
            try saveRecordLive(latest, allRecords: proposed, sortOrder: idx)
            self.allRecords = proposed

            self.recalculateQueue()
            self.delegate?.reviewCoordinator(self, didUpdateRecords: self.allRecords)

            // Selection safety: ONLY update if current selection is STILL on this record, without wiping unsaved edits
            if self.currentRecordId == latest.id {
                self.delegate?.reviewCoordinator(self, didUpdateSelectedRecord: latest)
            }
            return (latest, suggestions)
        }
    }

    // MARK: - Deleting Record

    /// Permanently removes a bond record from the database, trashes associated photos,
    /// and advances the review queue.
    func deleteRecord(record: BondRecord) throws {
        let root = customOutputRoot ?? outputRoot
        guard let idx = allRecords.firstIndex(where: { $0.id == record.id }) else {
            throw ReviewError.recordNotFound(record.id)
        }

        var proposedRecords = allRecords
        proposedRecords.remove(at: idx)

        // 1. Cancel background AI review if queued or active for this record
        cancelAIReview(for: record.id)

        // 2. Persist deletion to SQLite and schedule export BEFORE modifying in-memory allRecords
        try deleteRecordLive(id: record.id, allRecords: proposedRecords)

        // 3. Move photos to macOS Trash safely (verifying no other records reference them)
        _ = try? safelyTrashPhotographs(for: record, existingRecords: proposedRecords, database: DatabaseManager.shared, root: root)

        // 4. Determine next record to select in the queue
        let nextSelectedId: String?
        if let queueIdx = queueRecordIds.firstIndex(of: record.id) {
            if queueIdx + 1 < queueRecordIds.count {
                nextSelectedId = queueRecordIds[queueIdx + 1]
            } else if queueIdx > 0 {
                nextSelectedId = queueRecordIds[queueIdx - 1]
            } else {
                nextSelectedId = nil
            }
        } else {
            nextSelectedId = queueRecordIds.first
        }

        // 5. Commit to in-memory state
        self.allRecords = proposedRecords
        recalculateQueue()
        delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)

        // 6. Select the next record
        if let nextId = nextSelectedId, allRecords.contains(where: { $0.id == nextId }) {
            selectRecord(id: nextId)
        } else if let firstQueueId = queueRecordIds.first {
            selectRecord(id: firstQueueId)
        } else {
            currentRecordId = nil
            delegate?.reviewCoordinator(self, didSelectRecord: nil)
        }
    }
}
