import CoreGraphics
import Foundation

struct OCRLine {
    let text: String
    let confidence: Float
    let box: CGRect // normalized, origin bottom-left
}

struct OCRResult {
    let record: BondRecord
    let image: CGImage
    let originalImage: CGImage
    let huntScore: Int
    let lineCount: Int
    let rectified: Bool
    let bondTextFound: Bool
}

struct FieldReading {
    var value: String = ""
    var confidence: String = "" // "high" or "uncertain"
    var source: String = ""
    var isHigh: Bool {
        confidence == "high" && !value.isEmpty
    }

    var isUncertain: Bool {
        confidence == "uncertain" && !value.isEmpty
    }
}

/// Bank dating stamp: day + month name + year (e.g. "12 AUG 1966").
/// Not the printed "FIRST DAY OF JUL 1966" issue date.
struct DatingStampReading {
    var day: Int
    var month: String
    var year: String
    var confidence: String
    var raw: String
}
