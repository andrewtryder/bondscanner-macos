import Foundation

struct BondRecord: Codable {
    var id: String
    var capturedAt: String
    var series: String
    var serial: String
    var issueMonth: String
    var issueYear: String
    var denomination: String
    var owner: String
    var secondName: String
    var secondRole: String
    var address: String
    var taxID: String
    var issuingAgent: String
    var datingStamp: String
    var status: String
    var notes: String
    var photo: String
    var sourcePhoto: String
    var rawOCR: String
    /// Field name → photograph that first supplied a non-empty value. Optional so existing records still decode.
    var fieldPhoto: [String: String]?
    var fieldCaptureId: [String: String]?
    /// OCR text from later captures that contributed fields. The first capture's rawOCR is never overwritten.
    var additionalOCR: String?
    /// Per-field confidence: "high" or "uncertain". Optional so existing records still decode.
    var fieldConfidence: [String: String]?
    /// Per-field source (e.g. "words+corners", "pattern", "issue-label"). Optional.
    var fieldSource: [String: String]?
    /// Previous extracted values kept when a later confident read corrects a field.
    var previousExtracted: [String: String]?
    /// Fields explicitly confirmed by user. Never overwritten by automatic OCR passes.
    var userConfirmedFields: [String]?
    /// Evidence-based validation warnings (non-fatal historical anomalies or uncertainties).
    var validationWarnings: [String]?
    /// Evidence-based validation hard errors (strict statutory / format violations).
    var validationErrors: [String]?
    /// Experimental MICR recognition result if available on compatible photographs.
    var micrData: String?
    /// Structured review reasons persisted separately from confidence and notes.
    var reviewReasons: [String]?
    /// Additional original photo paths associated with this bond (e.g. from merged duplicate scans).
    var associatedPhotos: [String]?
    /// Audit trail of validation warnings explicitly acknowledged by the user.
    var acknowledgedWarnings: [String]?
    /// Audit trail of structured review reasons explicitly resolved by the user.
    var resolvedReviewReasons: [String]?
    /// ID of potential duplicate / near-match candidate record if known.
    var duplicateCandidateId: String?
}
