import Foundation

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
            let isResolved = (record.resolvedReviewReasons ?? []).contains("near_match")
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
            self.detail = "Historical record marked for review. Please inspect photograph and confirm fields."
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
