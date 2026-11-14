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
}
