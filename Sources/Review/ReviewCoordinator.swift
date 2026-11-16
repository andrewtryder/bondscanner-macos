import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Vision
#if canImport(FoundationModels)
    import FoundationModels
#endif

enum ReviewError: Error, LocalizedError, Equatable {
    case conflictingConfirmedValues(field: String, primaryValue: String, candidateValue: String)
    case recordNotFound(String)
    case photoFileNotFound(String)
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case let .conflictingConfirmedValues(field, prim, cand):
            return "Conflicting confirmed values for '\(field)': primary has '\(prim)', candidate has '\(cand)'. Please explicitly select which value to retain."
        case let .recordNotFound(id):
            return "Record with ID '\(id)' was not found."
        case let .photoFileNotFound(path):
            return "Photograph file was not found at '\(path)'."
        case let .ocrFailed(msg):
            return "OCR processing failed: \(msg)"
        }
    }
}

protocol ReviewCoordinatorDelegate: AnyObject {
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateRecords records: [BondRecord])
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didSelectRecord record: BondRecord?)
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didChangeProgress progress: ReviewProgress)
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateSelectedRecord record: BondRecord)
}

extension ReviewCoordinatorDelegate {
    func reviewCoordinator(_ coordinator: ReviewCoordinator, didUpdateSelectedRecord record: BondRecord) {
        reviewCoordinator(coordinator, didSelectRecord: record)
    }
}

/// Central coordinator for the Bond Review and Correction workflow.
/// Manages review filtering, durable SQLite persistence, atomic duplicate resolution,
/// photo caching, and selection stability across background OCR operations.
final class ReviewCoordinator {
    weak var delegate: ReviewCoordinatorDelegate?

    var allRecords: [BondRecord] = []
    var currentRecordId: String?
    var activeFilter: ReviewFilterCategory = .allReview {
        didSet {
            recalculateQueue()
        }
    }

    var queueRecordIds: [String] = []
    private var initialSessionQueueCount: Int = 0
    var reviewedInSessionCount: Int = 0

    /// High performance image cache for smooth queue navigation
    private let imageCache = NSCache<NSString, NSImage>()
    let customOutputRoot: URL?
    private let aiAnalyzer: any BondAIAnalyzing
    private var aiQueuedIDs: [String] = []
    private var aiActiveID: String?
    /// Identifies the task which owns `aiActiveID`.  Cancellation is cooperative,
    /// so an old task must never clear the state of a newer task.
    private var aiActiveToken: UUID?
    private var aiTask: Task<Void, Never>?
    private(set) var aiPaused = false
    private var aiDeferredForForegroundWork = false
    private(set) var aiCompleted = 0
    private(set) var aiAbstained = 0
    private(set) var aiFailed = 0

    private static let automaticAIKey = "automaticOnDeviceBondAIReview"

    init(records: [BondRecord] = [], outputRoot: URL? = nil, aiAnalyzer: any BondAIAnalyzing = LocalBondAIAnalyzer()) {
        imageCache.countLimit = 15
        self.allRecords = records
        self.customOutputRoot = outputRoot
        self.aiAnalyzer = aiAnalyzer
        recalculateQueue(resetSessionMetrics: true)
        aiQueuedIDs = (UserDefaults.standard.stringArray(forKey: "bondAIReviewQueue") ?? []).filter { id in
            records.contains { $0.id == id && $0.status == "REVIEW" }
        }
        aiPaused = UserDefaults.standard.bool(forKey: "bondAIReviewPaused")
        startNextAIJobIfPossible()
    }

    deinit {
        aiTask?.cancel()
    }

    static var automaticAIEnabled: Bool {
        get { UserDefaults.standard.object(forKey: automaticAIKey) as? Bool ?? localModelAvailable }
        set { UserDefaults.standard.set(newValue, forKey: automaticAIKey) }
    }

    static var localModelAvailable: Bool {
        localModelAvailability == .available
    }

    static var localModelAvailability: LocalModelAvailability {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return .available
                case .unavailable(.deviceNotEligible): return .deviceIneligible
                case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceDisabled
                case .unavailable(.modelNotReady): return .modelNotReady
                @unknown default: return .unavailableUnknown
                }
            }
        #endif
        return .unsupportedOS
    }

    /// Enqueue a finished OCR record without blocking capture, camera re-arm, or OCR.
    func automaticallyReviewIfEligible(_ record: BondRecord) {
        guard Self.automaticAIEnabled, Self.isAutomaticallyReviewEligible(record) else { return }
        enqueueAIReview(recordID: record.id)
    }

    /// Shared production policy used by the queue and private benchmark. A complete
    /// record can still need review because of unresolved validation/duplicate reasons.
    static func isAutomaticallyReviewEligible(_ record: BondRecord) -> Bool {
        record.status == "REVIEW" && !(requiredFieldsComplete(record) && (record.reviewReasons ?? []).isEmpty)
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func analyzeRecordWithAI(record: BondRecord) async throws -> BondAIAnalysis {
        let photo = record.sourcePhoto.isEmpty ? record.photo : record.sourcePhoto
        let root = customOutputRoot ?? outputRoot
        let imageURL = root.appendingPathComponent(photo)
        let analysis = await aiAnalyzer.analyze(record: record, imageURL: imageURL)
        await MainActor.run {
            if let idx = allRecords.firstIndex(where: { $0.id == record.id }) {
                var updated = allRecords[idx]
                updated.aiAnalysis = analysis
                var proposed = allRecords
                proposed[idx] = updated
                try? saveRecordLive(updated, allRecords: proposed, sortOrder: idx)
                allRecords = proposed
                switch analysis.status {
                case .ready: aiCompleted += 1
                case .abstained, .unavailable: aiAbstained += 1
                default: aiFailed += 1
                }
                recalculateQueue()
                delegate?.reviewCoordinator(self, didUpdateRecords: allRecords)
                if currentRecordId == record.id {
                    delegate?.reviewCoordinator(self, didUpdateSelectedRecord: updated)
                }
            }
        }
        return analysis
    }

    func enqueueAIReview(recordID: String, force: Bool = false) {
        runOnMain { [weak self] in
            guard let self, let record = self.allRecords.first(where: { $0.id == recordID }), record.status == "REVIEW", force || !self.hasCurrentAIAnalysis(record) else { return }
            let photo = record.sourcePhoto.isEmpty ? record.photo : record.sourcePhoto
            let root = self.customOutputRoot ?? outputRoot
            guard !photo.isEmpty, FileManager.default.fileExists(atPath: root.appendingPathComponent(photo).path), !self.aiQueuedIDs.contains(recordID) else { return }
            self.aiQueuedIDs.append(recordID)
            self.persistAIQueue()
            self.startNextAIJobIfPossible()
        }
    }

    func analyzeExistingReviews() {
        runOnMain { [weak self] in
            guard let self else { return }
            for record in self.allRecords where record.status == "REVIEW" && !self.hasCurrentAIAnalysis(record) {
                self.enqueueAIReview(recordID: record.id)
            }
        }
    }

    func pauseAIReview() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.aiPaused = true
            self.persistAIQueue()
        }
    }

    func resumeAIReview() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.aiPaused = false
            self.persistAIQueue()
            self.startNextAIJobIfPossible()
        }
    }

    /// OCR/capture owns responsiveness.  This is intentionally non-persistent: a
    /// foreground workload should defer new inference, never leave the queue paused.
    func setAIBackgroundWorkDeferred(_ deferred: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            self.aiDeferredForForegroundWork = deferred
            if !deferred {
                self.startNextAIJobIfPossible()
            }
        }
    }

    func cancelAIReview() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.aiTask?.cancel()
            self.aiTask = nil
            self.aiActiveID = nil
            self.aiActiveToken = nil
            self.aiQueuedIDs.removeAll()
            self.aiPaused = false
            self.persistAIQueue()
        }
    }

    func cancelAIReview(for recordID: String) {
        runOnMain { [weak self] in
            guard let self else { return }
            if self.aiActiveID == recordID {
                self.aiTask?.cancel()
                self.aiTask = nil
                self.aiActiveID = nil
                self.aiActiveToken = nil
                self.startNextAIJobIfPossible()
            }
            self.aiQueuedIDs.removeAll(where: { $0 == recordID })
            self.persistAIQueue()
        }
    }

    var aiProgressText: String {
        let total = aiQueuedIDs.count + (aiTask == nil ? 0 : 1) + aiCompleted + aiAbstained + aiFailed
        guard total > 0 else { return "" }
        let current = max(0, total - aiQueuedIDs.count)
        return "AI reviewing: \(current) of \(total) — \(aiCompleted) suggestions ready, \(aiAbstained + aiFailed) unresolved"
    }

    private func hasCurrentAIAnalysis(_ record: BondRecord) -> Bool {
        guard let analysis = record.aiAnalysis else { return false }
        return analysis.recordRevision == (record.revision ?? 0)
            && analysis.promptVersion == BondAIAnalysis.currentPromptVersion
            && (analysis.status == .ready || analysis.status == .abstained)
    }

    private func startNextAIJobIfPossible() {
        guard !aiPaused, !aiDeferredForForegroundWork, aiTask == nil, !aiQueuedIDs.isEmpty else { return }
        let id = aiQueuedIDs.removeFirst()
        aiActiveID = id
        let token = UUID()
        aiActiveToken = token
        persistAIQueue()
        guard let record = allRecords.first(where: { $0.id == id }) else {
            finishAIJob(token: token, id: id)
            return
        }
        let photo = record.sourcePhoto.isEmpty ? record.photo : record.sourcePhoto
        let root = customOutputRoot ?? outputRoot
        let imageURL = root.appendingPathComponent(photo)
        let revision = record.revision ?? 0
        aiTask = Task { [weak self, aiAnalyzer] in
            guard let self else { return }
            let analysis = await aiAnalyzer.analyze(record: record, imageURL: imageURL)
            await MainActor.run {
                guard self.aiActiveToken == token else { return }
                defer { self.finishAIJob(token: token, id: id) }
                guard !Task.isCancelled,
                      let index = self.allRecords.firstIndex(where: { $0.id == id }) else { return }
                // A human/OCR change, status transition, or malformed envelope during
                // inference makes output stale; never publish it.
                guard self.allRecords[index].status == "REVIEW",
                      (self.allRecords[index].revision ?? 0) == revision,
                      analysis.recordID == id,
                      analysis.recordRevision == revision else { return }
                var latest = self.allRecords[index]
                latest.aiAnalysis = analysis
                var proposed = self.allRecords
                proposed[index] = latest
                // Database is authoritative: do not expose an AI result until it is durable.
                do { try saveRecordLive(latest, allRecords: proposed, sortOrder: index) }
                catch { self.aiFailed += 1; return }
                self.allRecords = proposed
                switch analysis.status { case .ready: self.aiCompleted += 1; case .abstained, .unavailable: self.aiAbstained += 1; default: self.aiFailed += 1 }
                self.delegate?.reviewCoordinator(self, didUpdateRecords: self.allRecords)
                if self.currentRecordId == id {
                    self.delegate?.reviewCoordinator(self, didUpdateSelectedRecord: latest)
                }
            }
        }
    }

    private func finishAIJob(token: UUID, id: String) {
        guard aiActiveToken == token else { return }
        aiTask = nil
        aiActiveID = nil
        aiActiveToken = nil
        persistAIQueue()
        startNextAIJobIfPossible()
    }

    private func persistAIQueue() {
        // IDs and pause state only: no photos, OCR, prompts, or model output enter defaults/logs.
        // Include the active ID so a quit/crash requeues it safely on launch.
        UserDefaults.standard.set((aiActiveID.map { [$0] } ?? []) + aiQueuedIDs, forKey: "bondAIReviewQueue")
        UserDefaults.standard.set(aiPaused, forKey: "bondAIReviewPaused")
    }

    // MARK: - Queue & Selection Management

    func setAllRecords(_ records: [BondRecord]) {
        self.allRecords = records
        recalculateQueue(resetSessionMetrics: false)

        // Selection stability: ensure currentRecordId is still valid or fallback gracefully
        if let currentId = currentRecordId {
            if let updated = allRecords.first(where: { $0.id == currentId }) {
                delegate?.reviewCoordinator(self, didUpdateSelectedRecord: updated)
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
        guard let currentId = currentRecordId else { return nil }
        if let idx = queueRecordIds.firstIndex(of: currentId) {
            guard idx + 1 < queueRecordIds.count else { return nil }
            selectRecord(id: queueRecordIds[idx + 1])
            return currentRecord
        } else if let allIdx = allRecords.firstIndex(where: { $0.id == currentId }) {
            let queueSet = Set(queueRecordIds)
            for candidate in allRecords.suffix(from: allIdx + 1) where queueSet.contains(candidate.id) {
                selectRecord(id: candidate.id)
                return currentRecord
            }
        }
        return nil
    }

    func previousRecord() -> BondRecord? {
        guard let currentId = currentRecordId else { return nil }
        if let idx = queueRecordIds.firstIndex(of: currentId) {
            if idx > 0 {
                selectRecord(id: queueRecordIds[idx - 1])
                return currentRecord
            } else if let allIdx = allRecords.firstIndex(where: { $0.id == currentId }), allIdx > 0 {
                // Allow stepping back to the immediately preceding record in allRecords (e.g. a record just resolved in this session)
                selectRecord(id: allRecords[allIdx - 1].id)
                return currentRecord
            }
            return nil
        } else if let allIdx = allRecords.firstIndex(where: { $0.id == currentId }) {
            let queueSet = Set(queueRecordIds)
            for candidate in allRecords.prefix(upTo: allIdx).reversed() where queueSet.contains(candidate.id) {
                selectRecord(id: candidate.id)
                return currentRecord
            }
        }
        return nil
    }

    func nextUnresolvedRecord(excludingCurrent: Bool = true, startingAfterCurrent: Bool = true, priorQueueIds: [String]? = nil) -> BondRecord? {
        let effectiveQueue = priorQueueIds ?? queueRecordIds
        let searchIds: [String]
        if startingAfterCurrent, let currentId = currentRecordId, let idx = effectiveQueue.firstIndex(of: currentId) {
            searchIds = Array(effectiveQueue.suffix(from: idx + 1)) + Array(effectiveQueue.prefix(upTo: idx))
        } else {
            searchIds = effectiveQueue
        }

        for id in searchIds {
            if excludingCurrent, id == currentRecordId {
                continue
            }
            if let record = allRecords.first(where: { $0.id == id }), record.status == "REVIEW" || record.status == "DUPLICATE" {
                return record
            }
        }
        return nil
    }

    // MARK: - Image Caching

    func loadImage(relativePath: String) -> NSImage? {
        guard !relativePath.isEmpty else { return nil }
        let key = relativePath as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let root = customOutputRoot ?? outputRoot
        let fileURL = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path), let img = NSImage(contentsOf: fileURL) else { return nil }

        imageCache.setObject(img, forKey: key)
        return img
    }

    private func preloadAdjacentPhotos() {
        guard let currentId = currentRecordId,
              let idx = queueRecordIds.firstIndex(of: currentId) else { return }

        let pathsToLoad: [String] = [idx - 1, idx + 1].compactMap { nIdx in
            guard nIdx >= 0, nIdx < queueRecordIds.count else { return nil }
            let id = queueRecordIds[nIdx]
            guard let rec = allRecords.first(where: { $0.id == id }) else { return nil }
            let path = rec.photo.isEmpty ? rec.sourcePhoto : rec.photo
            return path.isEmpty ? nil : path
        }
        guard !pathsToLoad.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            for path in pathsToLoad {
                _ = self.loadImage(relativePath: path)
            }
        }
    }
}
