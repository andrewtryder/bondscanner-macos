import Foundation

/// Versioned, review-only output from the on-device model. None of these values are
/// treated as verified facts until the reviewer saves an explicit edit.
struct BondAIAnalysis: Codable, Equatable {
    static let currentPromptVersion = "bond-review-v1"
    var recordID: String
    var recordRevision: Int
    var analyzedAt: Date
    var runtime: String
    var promptVersion: String
    var status: Status
    var suggestions: [BondAISuggestion]
    var summary: String
    var failureKind: String?

    enum Status: String, Codable { case ready, abstained, unavailable, failed, cancelled }

    var isCurrentForRecord: Bool {
        recordRevision >= 0 && promptVersion == Self.currentPromptVersion && status == .ready ||
            (promptVersion == Self.currentPromptVersion && status == .abstained)
    }
}

struct BondAISuggestion: Codable, Equatable, Identifiable {
    enum Assessment: String, Codable, CaseIterable { case strongEvidence, conflictingEvidence, insufficientEvidence }
    var id: String {
        field
    }

    var field: String
    var existingValue: String
    var proposedValue: String?
    var abstained: Bool
    var evidence: String
    var imageRegion: String?
    var ambiguity: String
    var assessment: Assessment
    var requiresOriginalInspection: Bool
}

/// Dependency boundary used by tests and by the queue. Implementations must never
/// mutate a `BondRecord`; they only return an analysis envelope.
protocol BondAIAnalyzing: Sendable {
    func analyze(record: BondRecord, imageURL: URL) async -> BondAIAnalysis
}

struct UnavailableBondAIAnalyzer: BondAIAnalyzing {
    let reason: String
    func analyze(record: BondRecord, imageURL: URL) async -> BondAIAnalysis {
        BondAIAnalysis(recordID: record.id, recordRevision: record.revision ?? 0, analyzedAt: Date(), runtime: "unavailable", promptVersion: BondAIAnalysis.currentPromptVersion, status: .unavailable, suggestions: [], summary: "On-device AI analysis is unavailable. Manual review remains available.", failureKind: reason)
    }
}

/// Filter categories for the Review queue and drawer.
enum ReviewFilterCategory: String, CaseIterable {
    case all = "All Records"
    case allReview = "All Reviews"
    case missingSerial = "Missing / Uncertain Serial"
    case missingDenom = "Missing / Uncertain Denom"
    case missingDate = "Missing / Uncertain Date"
    case duplicates = "Duplicates / Near-Match"
    case validationErrors = "Validation Errors"
    case otherReasons = "Other Unresolved"
    case stalledProcessing = "Stalled Processing"

    var shortTitle: String {
        switch self {
        case .all: return "All"
        case .allReview: return "Review"
        case .missingSerial: return "Serial"
        case .missingDenom: return "Denom"
        case .missingDate: return "Date"
        case .duplicates: return "Duplicates"
        case .validationErrors: return "Errors"
        case .otherReasons: return "Other"
        case .stalledProcessing: return "Stalled"
        }
    }

    /// Evaluates whether a given `BondRecord` matches this filter category.
    func matches(record: BondRecord) -> Bool {
        switch self {
        case .all:
            return true

        case .allReview:
            return record.status == "REVIEW" || record.status == "DUPLICATE"

        case .missingSerial:
            guard record.status == "REVIEW" || record.status == "DUPLICATE" else { return false }
            let conf = record.fieldConfidence?["serial"] ?? ""
            let isMissing = record.serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isUncertain = conf == "uncertain"
            let inReasons = (record.reviewReasons ?? []).contains { $0.contains("serial") }
            return isMissing || isUncertain || inReasons

        case .missingDenom:
            guard record.status == "REVIEW" || record.status == "DUPLICATE" else { return false }
            let conf = record.fieldConfidence?["denomination"] ?? ""
            let isMissing = record.denomination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isUncertain = conf == "uncertain"
            let inReasons = (record.reviewReasons ?? []).contains { $0.contains("face value") || $0.contains("denomination") }
            return isMissing || isUncertain || inReasons

        case .missingDate:
            guard record.status == "REVIEW" || record.status == "DUPLICATE" else { return false }
            let conf = record.fieldConfidence?["issueDate"] ?? ""
            let isMissing = record.issueMonth.isEmpty || record.issueYear.isEmpty
            let isUncertain = conf == "uncertain"
            let inReasons = (record.reviewReasons ?? []).contains { $0.contains("date") || $0.contains("issue") }
            return isMissing || isUncertain || inReasons

        case .duplicates:
            if record.status == "DUPLICATE" {
                return true
            }
            let hasNearMatchReason = (record.reviewReasons ?? []).contains { $0.hasPrefix("near_match") }
            let hasNearMatchNote = record.notes.lowercased().contains("near-match")
            let isResolved = (record.resolvedReviewReasons ?? []).contains { $0 == "near_match" || $0.hasPrefix("keep_separate:") || $0.hasPrefix("near_match:") }
            return (hasNearMatchReason || hasNearMatchNote) && !isResolved

        case .validationErrors:
            guard record.status == "REVIEW" || record.status == "DUPLICATE" else { return false }
            let hasErrors = !(record.validationErrors?.isEmpty ?? true)
            let hasValReason = (record.reviewReasons ?? []).contains { $0.hasPrefix("validation:") }
            return hasErrors || hasValReason

        case .otherReasons:
            guard record.status == "REVIEW" || record.status == "DUPLICATE" else { return false }
            let hasSpecific = ReviewFilterCategory.missingSerial.matches(record: record)
                || ReviewFilterCategory.missingDenom.matches(record: record)
                || ReviewFilterCategory.missingDate.matches(record: record)
                || ReviewFilterCategory.duplicates.matches(record: record)
                || ReviewFilterCategory.validationErrors.matches(record: record)
            return !hasSpecific

        case .stalledProcessing:
            return record.status == "PROCESSING"
        }
    }
}

/// Human-readable representation of a review reason with actionable resolution information.
struct FormattedReviewReason: Identifiable, Equatable {
    let id: String
    let rawKey: String
    let title: String
    let detail: String
    let isWarning: Bool
    let isResolvable: Bool

    init(rawKey: String) {
        self.id = rawKey
        self.rawKey = rawKey

        if rawKey.hasPrefix("validation:") {
            self.title = "Validation Error"
            self.detail = rawKey.replacingOccurrences(of: "validation:", with: "").trimmingCharacters(in: .whitespaces)
            self.isWarning = false
            self.isResolvable = true
        } else if rawKey.hasPrefix("missing_required:") {
            self.title = "Missing or Uncertain Required Field"
            let fields = rawKey.replacingOccurrences(of: "missing_required:", with: "").trimmingCharacters(in: .whitespaces)
            self.detail = "Please enter and confirm: \(fields)"
            self.isWarning = false
            self.isResolvable = false
        } else if rawKey.hasPrefix("near_match") {
            self.title = "Possible Duplicate (Near-Match)"
            self.detail = "Similar to another bond in the database. Review candidate bond below to keep separate or merge."
            self.isWarning = true
            self.isResolvable = true
        } else if rawKey.hasPrefix("legacy_review") {
            self.title = "Legacy Review"
            let detailPart = rawKey.replacingOccurrences(of: "legacy_review:", with: "").replacingOccurrences(of: "legacy_review", with: "").trimmingCharacters(in: .whitespaces)
            if detailPart.isEmpty || detailPart == "manual verification required" {
                self.detail = "Historical record marked for review. Please inspect photograph and confirm fields."
            } else {
                self.detail = detailPart
            }
            self.isWarning = true
            self.isResolvable = true
        } else if rawKey.hasPrefix("stalled_processing") {
            self.title = "Processing Interrupted"
            self.detail = "OCR did not finish. You may reprocess the saved photograph or enter fields manually."
            self.isWarning = true
            self.isResolvable = true
        } else {
            self.title = "Review Required"
            self.detail = rawKey
            self.isWarning = true
            self.isResolvable = true
        }
    }
}

/// Progress metrics for a review session.
struct ReviewProgress: Equatable {
    let reviewedInSession: Int
    let totalInQueue: Int
    let remainingCount: Int

    var displayString: String {
        return "Reviewed \(reviewedInSession) / \(totalInQueue) — \(remainingCount) remaining"
    }
}
