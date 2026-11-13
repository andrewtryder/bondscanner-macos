import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import ImageIO
import AudioToolbox
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

// A single-file, fully local Mac savings-bond scanner.
// Images, extracted rows and raw OCR are stored ONLY in ~/BondScans.

private let outputRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BondScans", isDirectory: true)
private let photosRoot = outputRoot.appendingPathComponent("photos", isDirectory: true)
private let recordsURL = outputRoot.appendingPathComponent("records.json")
private let csvURL = outputRoot.appendingPathComponent("bonds.csv")
private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
private let debugURL = outputRoot.appendingPathComponent("scan-debug.log")

// Log only operational telemetry. No OCR text, names, tax IDs, or serial numbers.
final class ScanLog {
    static let shared = ScanLog()
    private let lock = NSLock()
    func write(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: debugURL.path) {
            _ = FileManager.default.createFile(atPath: debugURL.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: debugURL.path) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        if let data = "[\(timestamp)] \(event)\n".data(using: .utf8) { handle.write(data) }
    }
}


struct OCRLine {
    let text: String
    let confidence: Float
    let box: CGRect // normalized, origin bottom-left
}

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

func regexMatches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let r = NSRange(text.startIndex..<text.endIndex, in: text)
    return re.matches(in: text, range: r).compactMap { m in
        guard let range = Range(m.range, in: text) else { return nil }
        return String(text[range])
    }
}

func cleanAlnum(_ s: String) -> String {
    return s.uppercased().filter { $0.isLetter || $0.isNumber }
}

/// Uppercase, strip spaces and dashes. Convert O to 0 only in the numeric body
/// of a serial (not a leading prefix letter, and not a trailing E / EE suffix).
func normalizeSerial(_ raw: String) -> String {
    let upper = raw.uppercased().filter { $0.isLetter || $0.isNumber }
    guard !upper.isEmpty else { return "" }
    var chars = Array(upper)
    var start = 0
    while start < chars.count && chars[start].isLetter { start += 1 }
    var end = chars.count
    if end > start && chars[end - 1] == "E" {
        end -= 1
        if end > start && chars[end - 1] == "E" { end -= 1 }
    }
    if start < end {
        for i in start..<end where chars[i] == "O" { chars[i] = "0" }
    }
    return String(chars)
}

func recordMatchingSerial(_ raw: String, in records: [BondRecord], excluding id: String? = nil) -> BondRecord? {
    let key = normalizeSerial(raw)
    guard !key.isEmpty else { return nil }
    return records.first { record in
        if let id = id, record.id == id { return false }
        let other = normalizeSerial(record.serial)
        return !other.isEmpty && other == key
    }
}

func monthNumber(_ text: String) -> String? {
    let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    let s = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let i = names.firstIndex(where: { s.hasPrefix($0) }) { return String(format: "%02d", i + 1) }
    if let v = Int(s), (1...12).contains(v) { return String(format: "%02d", v) }
    return nil
}

func parseDeterministically(_ lines: [OCRLine]) -> BondRecord {
    let full = lines.map(\.text).joined(separator: "\n")
    let upper = full.uppercased()
    let compactLines = lines.map { cleanAlnum($0.text) }
    let now = ISO8601DateFormatter().string(from: Date())
    var record = BondRecord(id: UUID().uuidString, capturedAt: now,
        series: "", serial: "", issueMonth: "", issueYear: "", denomination: "",
        owner: "", secondName: "", secondRole: "", address: "", taxID: "",
        issuingAgent: "", datingStamp: "", status: "REVIEW", notes: "",
        photo: "", sourcePhoto: "", rawOCR: full)

    // Each real savings-bond serial appears in a colored, large print run and
    // generally has 1 letter, several digits, then a suffix E or EE.
    var candidates: [(String, Int)] = []
    for (i, s) in compactLines.enumerated() {
        let matches = regexMatches("[A-Z][0-9]{7,11}(?:EE|E|I)", in: s)
        for m in matches {
            var score = 0
            if m.hasSuffix("EE") { score += 5 }
            else if m.hasSuffix("E") { score += 4 }
            if m.count >= 10 && m.count <= 13 { score += 3 }
            // In landscape, the serial is normally in the lower-right part.
            if lines[i].box.midX > 0.52 && lines[i].box.midY < 0.38 { score += 4 }
            if lines[i].confidence > 0.5 { score += 1 }
            candidates.append((m, score))
        }
    }
    if let best = candidates.max(by: { $0.1 < $1.1 }) { record.serial = best.0 }

    if upper.contains("SERIES EE") || record.serial.hasSuffix("EE") { record.series = "EE" }
    else if upper.contains("SERIES E") || record.serial.hasSuffix("E") { record.series = "E" }
    else if upper.contains("SERIES I") || record.serial.hasSuffix("I") { record.series = "I" }

    // Denomination must come from the printed face value, not nearby account numbers.
    let vals: [(String, String)] = [
        ("TEN THOUSAND", "10000"), ("FIVE THOUSAND", "5000"),
        ("ONE THOUSAND", "1000"), ("FIVE HUNDRED", "500"),
        ("TWO HUNDRED", "200"), ("ONE HUNDRED", "100"),
        ("FIFTY", "50"), ("TWENTY FIVE", "25"), ("TWENTY DOLLARS", "20"), ("TWENTY-FIVE", "25"), ("TEN DOLLARS", "10")]
    for (words, amount) in vals where upper.contains(words) {
        record.denomination = amount
        break
    }
    if record.denomination.isEmpty {
        for value in ["10000", "5000", "1000", "500", "200", "100", "50", "25", "20", "10"] {
            if lines.contains(where: { cleanAlnum($0.text) == value && ($0.box.midX < 0.30 || $0.box.midX > 0.70) }) {
                record.denomination = value
                break
            }
        }
    }

    // Look for an issue MONTH YEAR near the upper-right, not the bank's dated stamp.
    var dateCandidates: [(String, String, Int)] = []
    let months = "JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?"
    let datePattern = "\\b(\(months)|0?[1-9]|1[0-2])\\s*[-./ ]+\\s*((?:19|20)[0-9]{2})\\b"
    if let pattern = try? NSRegularExpression(pattern: datePattern, options: [.caseInsensitive]) {
        for line in lines {
            let text = line.text.uppercased()
            let matches = pattern.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            for match in matches {
                guard let r1 = Range(match.range(at: 1), in: text), let r2 = Range(match.range(at: 2), in: text),
                      let month = monthNumber(String(text[r1])) else { continue }
                let year = String(text[r2])
                var score = 0
                if line.box.midX > 0.62 { score += 4 }
                if line.box.midY > 0.52 { score += 3 }
                if text.contains("ISSUE") { score += 3 }
                if text.contains("DATING") { score -= 5 }
                if text.contains("STAMP") { score -= 5 }
                dateCandidates.append((month, year, score))
            }
        }
    }
    // OCR sometimes splits 04 and 1986 into adjacent observations.
    for a in lines {
        let token = cleanAlnum(a.text)
        guard let month = monthNumber(token) else { continue }
        for b in lines {
            let year = cleanAlnum(b.text)
            if regexMatches("^(?:19|20)[0-9]{2}$", in: year).isEmpty { continue }
            let dx = abs(b.box.midX - a.box.midX), dy = abs(b.box.midY - a.box.midY)
            if (dy < 0.08 && dx < 0.24) || (dx < 0.1 && dy < 0.08) {
                let score = (a.box.midX > 0.62 ? 4 : 0) + (a.box.midY > 0.52 ? 3 : 0)
                dateCandidates.append((month, year, score))
            }
        }
    }
    if let best = dateCandidates.max(by: { $0.2 < $1.2 }) {
        record.issueMonth = best.0; record.issueYear = best.1
    }

    // Best-effort owner and secondary registration. AI can improve these later.
    // Do not mistake all-caps headings or an address for a person's name.
    let namePrefix = "^(?:MR|MRS|MS|MISS|DR)\\.?\\s+[A-Z][A-Z .'-]{3,45}$"
    let names = lines.filter { line in
        let t = line.text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return !regexMatches(namePrefix, in: t).isEmpty && line.box.midX < 0.74
    }.sorted { $0.box.midY > $1.box.midY }
    if let first = names.first { record.owner = first.text.trimmingCharacters(in: .whitespaces) }
    if names.count >= 2 { record.secondName = names[1].text.trimmingCharacters(in: .whitespaces) }
    if upper.contains(" POD ") || upper.contains("POD") { record.secondRole = "POD" }
    else if upper.contains(" OR ") { record.secondRole = "OR" }

    let required = [record.series, record.serial, record.issueMonth, record.issueYear, record.denomination]
    if required.allSatisfy({ !$0.isEmpty }) {
        record.status = "OK"
        if record.owner.isEmpty { record.status = "REVIEW"; record.notes = "Check registered owner" }
    } else {
        var missing: [String] = []
        if record.serial.isEmpty { missing.append("serial") }
        if record.series.isEmpty { missing.append("series") }
        if record.issueMonth.isEmpty || record.issueYear.isEmpty { missing.append("issue date") }
        if record.denomination.isEmpty { missing.append("face value") }
        record.notes = "Missing or uncertain: " + missing.joined(separator: ", ")
    }
    return record
}

func rotateCG(_ cg: CGImage, exif: Int) -> CGImage? {
    let image = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(exif))
    return ciContext.createCGImage(image, from: image.extent)
}

func textOCR(_ image: CGImage, fast: Bool) -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = fast ? .fast : .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.007
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    return (request.results ?? []).compactMap { obs in
        guard let t = obs.topCandidates(1).first else { return nil }
        return OCRLine(text: t.string, confidence: t.confidence, box: obs.boundingBox)
    }
}

func orientationScore(_ lines: [OCRLine]) -> Int {
    let upper = lines.map(\.text).joined(separator: " ").uppercased()
    var score = 0
    if upper.contains("SERIES") { score += 35 }
    if upper.contains("DOLLARS") { score += 20 }
    if upper.contains("SAVINGS") { score += 15 }
    if upper.contains("ISSUE") { score += 10 }
    if upper.contains("UNITED") { score += 10 }
    if upper.contains("AMERICA") { score += 8 }
    if upper.contains("POD") { score += 6 }
    if regexMatches("[A-Z][0-9]{7,11}E{1,2}", in: cleanAlnum(upper)).count > 0 { score += 30 }
    score += min(lines.count, 40)
    return score
}

// Read broad potential outlines (front/back, rotated, different denominations).
// Avoid rejecting the bond solely because the paper border is poorly contrasted.
func rectangleCandidates(_ image: CGImage) -> [VNRectangleObservation] {
    let request = VNDetectRectanglesRequest()
    request.minimumAspectRatio = 0.20
    request.maximumAspectRatio = 1.0
    request.minimumSize = 0.15
    request.minimumConfidence = 0.20
    request.quadratureTolerance = 43
    request.maximumObservations = 12
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
    catch { ScanLog.shared.write("rectangle detection exception; falling back to text"); return [] }
    return (request.results ?? []).filter { r in
        let box = r.boundingBox
        return box.width * box.height > 0.10 && box.width > 0.30 && box.height > 0.15
    }.sorted { a, b in
        // Prefer bigger outlined regions; later OCR selects whether they actually contain a bond.
        a.boundingBox.width * a.boundingBox.height > b.boundingBox.width * b.boundingBox.height
    }
}

func rectify(_ image: CGImage, using rectangle: VNRectangleObservation) -> CGImage? {
    let source = CIImage(cgImage: image)
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let correction = CIFilter.perspectiveCorrection()
    correction.inputImage = source
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
    correction.topLeft = point(rectangle.topLeft)
    correction.topRight = point(rectangle.topRight)
    correction.bottomLeft = point(rectangle.bottomLeft)
    correction.bottomRight = point(rectangle.bottomRight)
    guard let out = correction.outputImage,
          let cg = ciContext.createCGImage(out, from: out.extent),
          cg.width > 450, cg.height > 200 else { return nil }
    return cg
}

func detectBond(_ image: CGImage) -> CGRect? {
    return rectangleCandidates(image).first?.boundingBox
}

func bondTextSignal(_ lines: [OCRLine]) -> Bool {
    let text = lines.map(\.text).joined(separator: " ").uppercased()
    let compact = cleanAlnum(text)
    return (text.contains("SERIES") && (text.contains("DOLLAR") || text.contains("SAVINGS")))
        || (text.contains("UNITED STATES") && text.contains("DOLLAR"))
        || !regexMatches("[A-Z][0-9]{7,11}(?:EE|E)", in: compact).isEmpty
}

// Cheap OCR reconnaissance that runs even if paper edges cannot be detected.
// It tries upside-down and portrait camera views before deciding if a bond is visible.
func probeForBond(_ image: CGImage) -> (score: Int, lines: Int, found: Bool) {
    var best = (score: -1, lines: 0, found: false)
    for orientation in [1, 3, 6, 8] {
        guard let candidate = rotateCG(image, exif: orientation) else { continue }
        let lines = textOCR(candidate, fast: true)
        let signal = bondTextSignal(lines)
        let score = orientationScore(lines) + (signal ? 25 : 0)
        if score > best.score { best = (score, lines.count, signal) }
    }
    return best
}

func adjustedForFaintPrinting(_ image: CGImage) -> CGImage? {
    let original = CIImage(cgImage: image)
    let contrast = CIFilter.colorControls()
    contrast.inputImage = original
    contrast.contrast = 1.38
    contrast.saturation = 0.1
    let sharpen = CIFilter.sharpenLuminance()
    sharpen.inputImage = contrast.outputImage
    sharpen.sharpness = 0.35
    guard let final = sharpen.outputImage else { return nil }
    return ciContext.createCGImage(final, from: final.extent)
}

func scanImage(_ image: CGImage) -> OCRResult {
    var candidates: [(image: CGImage, rectified: Bool, label: String)] = [(image, false, "full")]
    let rectangles = rectangleCandidates(image)
    // Test a couple of different edge candidates rather than blindly trusting the largest.
    for (index, rectangle) in rectangles.prefix(3).enumerated() {
        if let corrected = rectify(image, using: rectangle) {
            candidates.append((corrected, true, "rect\(index + 1)"))
        }
    }
    let center = CGRect(x: Int(Double(image.width) * 0.055),
                        y: Int(Double(image.height) * 0.08),
                        width: Int(Double(image.width) * 0.89),
                        height: Int(Double(image.height) * 0.84))
    if let cropped = image.cropping(to: center) {
        candidates.append((cropped, false, "center"))
    }

    var bestImage = image
    var bestScore = -1
    var bestRectified = false
    var bestLabel = "full"
    for candidate in candidates {
        for orientation in [1, 3, 6, 8] {
            guard let rotated = rotateCG(candidate.image, exif: orientation) else { continue }
            let lines = textOCR(rotated, fast: true)
            let score = orientationScore(lines) + (bondTextSignal(lines) ? 25 : 0)
            if score > bestScore {
                bestScore = score
                bestImage = rotated
                bestRectified = candidate.rectified
                bestLabel = "\(candidate.label)/orientation\(orientation)"
            }
        }
    }

    var selectedImage = bestImage
    var finalLines = textOCR(bestImage, fast: false)
    var finalScore = orientationScore(finalLines)
    if let enhanced = adjustedForFaintPrinting(bestImage) {
        let enhancedLines = textOCR(enhanced, fast: false)
        let enhancedScore = orientationScore(enhancedLines)
        if enhancedScore > finalScore + 3 {
            selectedImage = enhanced
            finalLines = enhancedLines
            finalScore = enhancedScore
            bestLabel += "/enhanced"
        }
    }
    let result = parseDeterministically(finalLines)
    let recognized = bondTextSignal(finalLines) || bondTextSignal(textOCR(bestImage, fast: true))
    ScanLog.shared.write("scan candidates=\(candidates.count) best=\(bestLabel) hunt_score=\(bestScore) final_score=\(finalScore) ocr_lines=\(finalLines.count) rectified=\(bestRectified) bond_text=\(recognized) fields_complete=\(result.status == "OK")")
    return OCRResult(record: result, image: selectedImage, originalImage: image,
                     huntScore: max(bestScore, finalScore), lineCount: finalLines.count,
                     rectified: bestRectified, bondTextFound: recognized)
}

func sanitizeCSV(_ value: String) -> String {
    // Prevent spreadsheet formula injection from untrusted OCR strings.
    var v = value
    if let first = v.first, "=+-@".contains(first) { v = "'" + v }
    return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

func writeRecords(_ records: [BondRecord]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(records)
    try jsonData.write(to: recordsURL, options: .atomic)
    let cols = ["id", "captured_at", "series", "serial_number", "issue_month", "issue_year",
                "face_value_usd", "registered_owner", "second_name", "second_role",
                "address", "tax_id", "issuing_agent", "dating_stamp", "status", "notes", "photo", "source_photo", "raw_ocr"]
    let rows: [[String]] = records.map { r in
        [r.id, r.capturedAt, r.series, r.serial, r.issueMonth, r.issueYear,
         r.denomination, r.owner, r.secondName, r.secondRole,
         r.address, r.taxID, r.issuingAgent, r.datingStamp,
         r.status, r.notes, r.photo, r.sourcePhoto, r.rawOCR]
    }
    let csv = ([cols.map(sanitizeCSV).joined(separator: ",")] + rows.map {
        $0.map(sanitizeCSV).joined(separator: ",")
    }).joined(separator: "\r\n") + "\r\n"
    try csv.write(to: csvURL, atomically: true, encoding: .utf8)
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

#if canImport(FoundationModels)
@available(macOS 26.0, *)
func enrichWithAppleIntelligence(_ record: BondRecord) async -> BondRecord {
    guard SystemLanguageModel.default.isAvailable else { return record }
    let instructions = """
    Extract fields from imperfect Apple Vision OCR of a United States PAPER savings bond.
    Return ONLY a single plain JSON object (no markdown or prose) with string keys:
    series, serial, issue_month, issue_year, denomination, owner,
    second_name, second_role, address, tax_id, issuing_agent, dating_stamp.
    Empty string for missing or ambiguous fields. Do NOT invent characters.
    Series E and EE may have different layouts. A bank DATING STAMP is NOT the bond's ISSUE DATE.
    Serial is a colored letter+digits+E/EE at the edge, NOT bank routing/account numbers.
    Keep individual names as printed. Separate the registered owner from the second named
    person, and classify second_role as OR or POD when indicated. Do not calculate values.
    """
    let prompt = "Parse these OCR lines from a single bond. These are the only allowed sources for values:\n" + String(record.rawOCR.prefix(11000))
    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let s = response.content
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") else { return record }
        let json = String(s[open...close])
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: String] else { return record }
        var next = record
        // A field can only be accepted when its text is supported by the actual OCR.
        let raw = cleanAlnum(record.rawOCR)
        func grounded(_ key: String) -> String {
            let proposed = (obj[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = cleanAlnum(proposed)
            guard !normalized.isEmpty, raw.contains(normalized) else { return "" }
            return proposed
        }
        if next.owner.isEmpty { next.owner = grounded("owner") }
        if next.secondName.isEmpty { next.secondName = grounded("second_name") }
        if next.address.isEmpty { next.address = grounded("address") }
        if next.taxID.isEmpty { next.taxID = grounded("tax_id") }
        if next.issuingAgent.isEmpty { next.issuingAgent = grounded("issuing_agent") }
        if next.datingStamp.isEmpty { next.datingStamp = grounded("dating_stamp") }
        if next.secondRole.isEmpty {
            let role = (obj["second_role"] ?? "").uppercased()
            if role == "POD" || role == "OR" { next.secondRole = role }
        }
        // Never override a machine-validated serial, date, or face value with a generated guess.
        if next.serial.isEmpty {
            let s = cleanAlnum(grounded("serial"))
            if !regexMatches("^[A-Z][0-9]{7,11}(?:EE|E|I)$", in: s).isEmpty { next.serial = s }
        }
        if next.series.isEmpty {
            let s = (obj["series"] ?? "").uppercased()
            if ["E", "EE", "I"].contains(s), next.rawOCR.uppercased().contains("SERIES") { next.series = s }
        }
        if next.denomination.isEmpty {
            let d = grounded("denomination")
            if ["10", "25", "50", "100", "200", "500", "1000", "5000", "10000", "20"].contains(d) { next.denomination = d }
        }
        if next.issueMonth.isEmpty || next.issueYear.isEmpty {
            let mo = (obj["issue_month"] ?? "")
            let yr = (obj["issue_year"] ?? "")
            if let month = monthNumber(mo), regexMatches("^(?:19|20)[0-9]{2}$", in: yr).count == 1,
                raw.contains(cleanAlnum(mo) + yr) {
                next.issueMonth = month; next.issueYear = yr
            }
        }
        let basics = [next.series, next.serial, next.issueMonth, next.issueYear, next.denomination, next.owner]
        next.status = basics.allSatisfy({ !$0.isEmpty }) ? "OK" : "REVIEW"
        if next.status == "OK" { next.notes = "" }
        return next
    } catch { return record }
}
#endif


func fourCharCodeString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    if let s = String(bytes: bytes, encoding: .ascii),
       s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value < 127 }) {
        return s
    }
    return String(format: "0x%08X", code)
}

func formatIsMJPEG(_ format: AVCaptureDevice.Format) -> Bool {
    let name = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased()
    return name == "jpeg" || name == "mjpa" || name == "mjpb" || name == "mjpg"
}

func formatDimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
    return CMVideoFormatDescriptionGetDimensions(format.formatDescription)
}

func videoCaptureDevices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
        types.append(.external)
    } else {
        types.append(AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown"))
    }
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    return discovery.devices
}

func selectBestCaptureFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
    let usable = formats.filter { format in
        let d = formatDimensions(format)
        return d.width >= 1280 && d.height >= 720 && d.width <= 4096 && d.height <= 4096
    }
    func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int) {
        let d = formatDimensions(format)
        let pixels = Int(d.width) * Int(d.height)
        var tier = 1
        if d.width == 2592 && d.height == 1944 { tier = 4 }
        else if d.width == 2560 && d.height == 1440 { tier = 3 }
        else if d.width == 2048 && d.height == 1536 { tier = 2 }
        let mjpeg = formatIsMJPEG(format) ? 1 : 0
        return (tier, pixels, mjpeg)
    }
    return usable.max { a, b in
        let sa = score(a), sb = score(b)
        if sa.0 != sb.0 { return sa.0 < sb.0 }
        if sa.1 != sb.1 { return sa.1 < sb.1 }
        return sa.2 < sb.2
    }
}

func logAllCameraFormats(_ camera: AVCaptureDevice) {
    for (index, format) in camera.formats.enumerated() {
        let d = formatDimensions(format)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let fps = format.videoSupportedFrameRateRanges.map { range in
            String(format: "%.2f-%.2f", range.minFrameRate, range.maxFrameRate)
        }.joined(separator: ",")
        ScanLog.shared.write("camera format[\(index)] \(d.width)x\(d.height) subtype=\(sub) fps=[\(fps)]")
    }
}

func logCameraControls(_ camera: AVCaptureDevice) {
    func modeName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoFocus: return "autoFocus"
        case .continuousAutoFocus: return "continuousAutoFocus"
        @unknown default: return "other"
        }
    }
    func expName(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoExpose: return "autoExpose"
        case .continuousAutoExposure: return "continuousAutoExposure"
        case .custom: return "custom"
        @unknown default: return "other"
        }
    }
    func wbName(_ mode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch mode {
        case .locked: return "locked"
        case .autoWhiteBalance: return "autoWhiteBalance"
        case .continuousAutoWhiteBalance: return "continuousAutoWhiteBalance"
        @unknown default: return "other"
        }
    }
    let focusModes: [AVCaptureDevice.FocusMode] = [.continuousAutoFocus, .autoFocus, .locked]
    let expModes: [AVCaptureDevice.ExposureMode] = [.continuousAutoExposure, .autoExpose, .locked, .custom]
    let wbModes: [AVCaptureDevice.WhiteBalanceMode] = [.continuousAutoWhiteBalance, .autoWhiteBalance, .locked]
    let focusSupported = focusModes.filter { camera.isFocusModeSupported($0) }.map(modeName).joined(separator: ",")
    let expSupported = expModes.filter { camera.isExposureModeSupported($0) }.map(expName).joined(separator: ",")
    let wbSupported = wbModes.filter { camera.isWhiteBalanceModeSupported($0) }.map(wbName).joined(separator: ",")
    ScanLog.shared.write("focus supported=[\(focusSupported)] current=\(modeName(camera.focusMode)) point_of_interest=\(camera.isFocusPointOfInterestSupported)")
    ScanLog.shared.write("exposure supported=[\(expSupported)] current=\(expName(camera.exposureMode)) point_of_interest=\(camera.isExposurePointOfInterestSupported)")
    ScanLog.shared.write("white_balance supported=[\(wbSupported)] current=\(wbName(camera.whiteBalanceMode))")
}


func preferredFrameDuration(for format: AVCaptureDevice.Format, desiredFPS: Double) -> (duration: CMTime, fps: Double)? {
    let ranges = format.videoSupportedFrameRateRanges
    guard !ranges.isEmpty else { return nil }
    var bestRange = ranges[0]
    var bestFPS = min(bestRange.maxFrameRate, max(bestRange.minFrameRate, desiredFPS))
    var bestDelta = abs(bestFPS - desiredFPS)
    for range in ranges {
        let fps: Double
        if range.minFrameRate <= desiredFPS && desiredFPS <= range.maxFrameRate {
            fps = desiredFPS
        } else if range.maxFrameRate <= desiredFPS {
            fps = range.maxFrameRate
        } else {
            fps = range.minFrameRate
        }
        let delta = abs(fps - desiredFPS)
        if delta < bestDelta || (delta == bestDelta && fps <= desiredFPS && bestFPS > desiredFPS) {
            bestRange = range
            bestFPS = fps
            bestDelta = delta
        }
    }
    var duration = CMTime(seconds: 1.0 / max(bestFPS, 1), preferredTimescale: 600)
    if CMTimeCompare(duration, bestRange.minFrameDuration) < 0 { duration = bestRange.minFrameDuration }
    if CMTimeCompare(duration, bestRange.maxFrameDuration) > 0 { duration = bestRange.maxFrameDuration }
    let fps = 1.0 / CMTimeGetSeconds(duration)
    return (duration, fps)
}

func desiredFPSForFormatDimensions(_ width: Int32, _ height: Int32) -> Double {
    // Uncompressed 2592x1944 420v at 30 fps is ~2.3 Gbps, far beyond USB 2.0 (~480 Mbps).
    // Request a rate the bus can actually carry so the device does not silently downscale.
    let pixels = Int(width) * Int(height)
    if pixels >= 2592 * 1944 { return 10 }
    if pixels >= 2048 * 1536 { return 15 }
    return 30
}

func estimatedMegabitsPerSecond(width: Int, height: Int, fps: Double, bytesPerPixel: Double = 1.5) -> Double {
    return Double(width) * Double(height) * bytesPerPixel * fps * 8.0 / 1_000_000.0
}

func largestSupportedPhotoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
    if #available(macOS 13.0, *) {
        let supported = format.supportedMaxPhotoDimensions
        return supported.max { a, b in
            Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }
    }
    return nil
}


final class PreviewView: NSView {
    let videoLayer = AVCaptureVideoPreviewLayer()
    let guide = CAShapeLayer()
    let detected = CAShapeLayer()
    let flash = CALayer()
    var sourceSize = CGSize(width: 16, height: 9)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
        guide.fillColor = NSColor.clear.cgColor
        guide.strokeColor = NSColor.systemYellow.cgColor
        guide.lineWidth = 3
        guide.lineDashPattern = [14, 8]
        layer?.addSublayer(guide)
        detected.fillColor = NSColor.clear.cgColor
        detected.strokeColor = NSColor.systemGreen.cgColor
        detected.lineWidth = 5
        layer?.addSublayer(detected)
        flash.backgroundColor = NSColor.systemGreen.cgColor
        flash.opacity = 0
        layer?.addSublayer(flash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        flash.frame = bounds
        let frame = bounds.insetBy(dx: bounds.width * 0.065, dy: bounds.height * 0.17)
        guide.path = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
        detected.frame = bounds
        CATransaction.commit()
    }

    func showDetected(_ observation: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let b = observation {
            // The preview uses aspect-fit, so account for letterboxing.
            let imageFrame = AVMakeRect(aspectRatio: sourceSize, insideRect: bounds)
            let box = CGRect(x: imageFrame.minX + b.minX * imageFrame.width,
                             y: imageFrame.minY + b.minY * imageFrame.height,
                             width: b.width * imageFrame.width,
                             height: b.height * imageFrame.height)
            detected.path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)
        } else { detected.path = nil }
        CATransaction.commit()
    }

    func captureFlash(color: NSColor = .systemGreen) {
        flash.removeAllAnimations()
        flash.backgroundColor = color.cgColor
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.6
        animation.toValue = 0
        animation.duration = 0.55
        flash.add(animation, forKey: "capture")
    }
}

final class BondScannerApp: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    private var window: NSWindow!
    private var preview: PreviewView!
    private var statusLabel: NSTextField!
    private var countLabel: NSTextField!
    private var lastLabel: NSTextField!
    private var autoButton: NSButton!
    private var aiLabel: NSTextField!
    private var focusLabel: NSTextField!
    private var focusInfo = "Focus: awaiting camera"
    private var captureDevice: AVCaptureDevice?
    private var nextAutoAllowedAt: TimeInterval = 0
    private var lastHuntAt: TimeInterval = 0
    private var huntRunning = false
    private var huntHits = 0
    private var noBondChecks = 0
    private var lastDiagnosticAt: TimeInterval = 0
    private var lastVideoLogAt: TimeInterval = 0
    private var session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var photoCaptureSupported = false
    private var chosenFormatWidth = 0
    private var chosenFormatHeight = 0
    private var chosenFormatSubtype = ""
    private var chosenDeviceFormat: AVCaptureDevice.Format?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var deliveredFrameLogged = false
    private var resolutionPass = 0
    private var latestImage: CGImage?
    private var records: [BondRecord] = []
    private var isProcessing = false
    private var automatic = true
    private var lockedAfterCapture = false
    private var emptyFrames = 0
    private var priorRect: CGRect?
    private var stableFrames = 0
    private var lastAnalyzeAt: TimeInterval = 0
    private var keyMonitor: Any?
    private var aiPending: [UUID] = []
    private var aiBusy = false
    private let cameraQueue = DispatchQueue(label: "bondscanner.camera", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "bondscanner.analysis", qos: .userInitiated)
    private let saveQueue = DispatchQueue(label: "bondscanner.save", qos: .userInitiated)
    private var photoRequests: [Int64: Bool] = [:]
    private var ocrPending: [(id: String, url: URL, automatic: Bool)] = []
    private var ocrBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: recordsURL.path) {
                records = try JSONDecoder().decode([BondRecord].self, from: Data(contentsOf: recordsURL))
            }
            try writeRecords(records)
        } catch {
            showStartupError("Could not open ~/BondScans: \(error.localizedDescription)")
            return
        }
        setupMenu()
        makeWindow()
        ScanLog.shared.write("app launch: version=2.1 records=\(records.count) no OCR text or identifiers logged")
        updateCount()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { self?.scanNow(); return nil } // Space
            return event
        }
        requestCameraAccess()
        for record in records where record.status == "PROCESSING" {
            let url = outputRoot.appendingPathComponent(record.sourcePhoto)
            if FileManager.default.fileExists(atPath: url.path) {
                ScanLog.shared.write("resuming OCR for a photograph saved before the last quit")
                enqueueOCR(id: record.id, originalURL: url, automatic: false)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        ScanLog.shared.write("app quit")
        session.stopRunning()
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Bond Scanner")
        let quit = NSMenuItem(title: "Quit Bond Scanner", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let debugItem = NSMenuItem()
        let debugMenu = NSMenu(title: "Debug")
        let open = NSMenuItem(title: "Open Debug Log", action: #selector(openDebugLog), keyEquivalent: "")
        open.target = self
        debugMenu.addItem(open)
        debugItem.submenu = debugMenu
        bar.addItem(debugItem)
        let cameraItem = NSMenuItem()
        let cameraMenu = NSMenu(title: "Camera")
        let refocus = NSMenuItem(title: "Request Refocus", action: #selector(refocusCamera), keyEquivalent: "r")
        refocus.target = self
        cameraMenu.addItem(refocus)
        cameraItem.submenu = cameraMenu
        bar.addItem(cameraItem)
        NSApp.mainMenu = bar
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func refocusCamera() {
        guard let camera = captureDevice else { status("No webcam available to refocus."); return }
        let supportsSingle = camera.isFocusModeSupported(.autoFocus)
        let supportsContinuous = camera.isFocusModeSupported(.continuousAutoFocus)
        guard supportsSingle || supportsContinuous else {
            ScanLog.shared.write("refocus requested but webcam exposes no software-controlled focus")
            status("Webcam provides no macOS focus control. Adjust distance or use vendor controls.")
            return
        }
        do {
            try camera.lockForConfiguration()
            if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if supportsSingle {
                if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
                camera.focusMode = .autoFocus
            } else { camera.focusMode = .continuousAutoFocus }
            camera.unlockForConfiguration()
            ScanLog.shared.write("manual refocus request sent to webcam")
            status("Requested camera refocus at center. Hold the bond still.")
        } catch {
            ScanLog.shared.write("refocus camera configuration failed")
            status("Could not request focus from the webcam.")
        }
    }
    @objc private func openDebugLog() {
        ScanLog.shared.write("user opened debug log")
        NSWorkspace.shared.open(debugURL)
    }

    private func label(_ text: String, size: CGFloat = 15, bold: Bool = false) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        view.textColor = NSColor.labelColor
        view.lineBreakMode = .byTruncatingTail
        return view
    }

    private func makeButton(_ text: String, action: Selector) -> NSButton {
        let b = NSButton(title: text, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 14)
        return b
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Bond Scanner — 100% Local"
        window.center()
        window.minSize = NSSize(width: 1050, height: 660)
        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        preview = PreviewView(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.videoLayer.session = session
        root.addSubview(preview)

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        let scanButton = makeButton("Scan now (Space)", action: #selector(scanNow))
        autoButton = makeButton("Auto: ON", action: #selector(toggleAuto))
        let importButton = makeButton("Import photos…", action: #selector(importPhotos))
        let folderButton = makeButton("Open output folder", action: #selector(openFolder))
        let undoButton = makeButton("Undo last", action: #selector(undoLast))
        let resetButton = makeButton("Re-arm", action: #selector(rearm))
        let logButton = makeButton("Debug log", action: #selector(openDebugLog))
        let quitButton = makeButton("Quit", action: #selector(quitApp))
        for b in [scanButton, autoButton!, resetButton, importButton, folderButton, undoButton, logButton, quitButton] { toolbar.addArrangedSubview(b) }
        root.addSubview(toolbar)

        countLabel = label("0 scanned", size: 21, bold: true)
        statusLabel = label("Starting webcam…", size: 17)
        lastLabel = label("Hold a bond steady inside the yellow guide.", size: 14)
        aiLabel = label("OCR: Apple Vision (offline)", size: 12)
        focusLabel = label("Focus: checking camera…  |  Debug: ~/BondScans/scan-debug.log", size: 12)
        for v in [countLabel!, statusLabel!, lastLabel!, aiLabel!, focusLabel!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            preview.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 15),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -15),
            preview.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -14),
            countLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            countLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: lastLabel.topAnchor, constant: -5),
            lastLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            lastLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            lastLabel.bottomAnchor.constraint(equalTo: aiLabel.topAnchor, constant: -5),
            aiLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            aiLabel.bottomAnchor.constraint(equalTo: focusLabel.topAnchor, constant: -4),
            focusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            focusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            aiLabel.stringValue = SystemLanguageModel.default.isAvailable
                ? "OCR: Apple Vision + Apple Intelligence (all on-device)"
                : "OCR: Apple Vision (Apple Intelligence model unavailable; still offline)"
        }
        #endif
    }

    private func showStartupError(_ error: String) {
        let alert = NSAlert()
        alert.messageText = "Bond Scanner could not start"
        alert.informativeText = error
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func status(_ text: String) {
        if Thread.isMainThread { statusLabel?.stringValue = text }
        else { DispatchQueue.main.async { [weak self] in self?.statusLabel?.stringValue = text } }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    if allowed { self?.startCamera() }
                    else { self?.status("Camera permission denied. Use Import photos or enable access in System Settings.") }
                }
            }
        default:
            status("Camera permission denied. Enable Bond Scanner in System Settings → Privacy & Security → Camera.")
        }
    }

    private func applyDeviceFormat(_ format: AVCaptureDevice.Format, on camera: AVCaptureDevice, reason: String) throws {
        let dims = formatDimensions(format)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let desired = desiredFPSForFormatDimensions(dims.width, dims.height)
        try camera.lockForConfiguration()
        camera.activeFormat = format
        if let frame = preferredFrameDuration(for: format, desiredFPS: desired) {
            camera.activeVideoMinFrameDuration = frame.duration
            camera.activeVideoMaxFrameDuration = frame.duration
            ScanLog.shared.write("\(reason) format=\(dims.width)x\(dims.height) subtype=\(sub) fps=\(String(format: "%.2f", frame.fps)) raw_mbps=\(String(format: "%.0f", estimatedMegabitsPerSecond(width: Int(dims.width), height: Int(dims.height), fps: frame.fps)))")
        } else {
            ScanLog.shared.write("\(reason) format=\(dims.width)x\(dims.height) subtype=\(sub) fps=device-default")
        }
        camera.unlockForConfiguration()
        chosenDeviceFormat = format
        chosenFormatWidth = Int(dims.width)
        chosenFormatHeight = Int(dims.height)
        chosenFormatSubtype = sub
        applyVideoOutputSettings(width: Int(dims.width), height: Int(dims.height), subtype: sub)
        applyPhotoOutputDimensions(from: format)
    }

    private func applyVideoOutputSettings(width: Int, height: Int, subtype: String) {
        guard let output = videoDataOutput else { return }
        let pixelFormat: OSType
        let lower = subtype.lowercased()
        if lower == "420v" {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } else if lower == "420f" {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        } else if lower == "yuvs" {
            pixelFormat = kCVPixelFormatType_422YpCbCr8_yuvs
        } else {
            pixelFormat = kCVPixelFormatType_32BGRA
        }
        // Request the native format size explicitly so the session cannot silently
        // emit a 1920x1080 buffer from a 2592x1944 activeFormat.
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        output.videoSettings = settings
        ScanLog.shared.write("video output settings \(width)x\(height) pixel_format=\(subtype)")
    }

    private func applyPhotoOutputDimensions(from format: AVCaptureDevice.Format) {
        guard photoCaptureSupported else { return }
        if #available(macOS 13.0, *) {
            let supported = format.supportedMaxPhotoDimensions
            let listed = supported.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
            if let best = largestSupportedPhotoDimensions(for: format) {
                photoOutput.maxPhotoDimensions = best
                ScanLog.shared.write("photo output max_photo=\(best.width)x\(best.height) from supported=[\(listed)]")
            } else {
                ScanLog.shared.write("photo output supportedMaxPhotoDimensions is empty; stills may match the video frame")
            }
        }
    }

    private func logActiveFormatState(_ camera: AVCaptureDevice, at moment: String) {
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(camera.activeFormat.formatDescription))
        ScanLog.shared.write("\(moment) active_format=\(dims.width)x\(dims.height) subtype=\(sub) session_preset=\(session.sessionPreset.rawValue) photo_output=\(photoCaptureSupported)")
    }

    private func reassertChosenFormatIfNeeded(afterStart: Bool) {
        guard let camera = captureDevice, let format = chosenDeviceFormat else { return }
        let dims = formatDimensions(camera.activeFormat)
        let preset = session.sessionPreset.rawValue
        let formatChanged = Int(dims.width) != chosenFormatWidth || Int(dims.height) != chosenFormatHeight
        let presetLooksCapped = preset.lowercased().contains("high") || preset.lowercased().contains("1280") || preset.lowercased().contains("1920")
        if !formatChanged && !presetLooksCapped { return }
        ScanLog.shared.write("re-asserting format after \(afterStart ? "startRunning" : "setup"); was \(dims.width)x\(dims.height) preset=\(preset)")
        session.beginConfiguration()
        do {
            try applyDeviceFormat(format, on: camera, reason: "re-assert")
        } catch {
            ScanLog.shared.write("re-assert of camera format failed")
        }
        session.commitConfiguration()
        logActiveFormatState(camera, at: afterStart ? "after_reassert" : "after_setup_reassert")
    }

    private func handleDeliveredResolutionMismatch(deliveredWidth: Int, deliveredHeight: Int) {
        guard let camera = captureDevice else { return }
        let raw = estimatedMegabitsPerSecond(width: chosenFormatWidth, height: chosenFormatHeight, fps: desiredFPSForFormatDimensions(Int32(chosenFormatWidth), Int32(chosenFormatHeight)))
        if resolutionPass == 0 {
            resolutionPass = 1
            ScanLog.shared.write("delivered \(deliveredWidth)x\(deliveredHeight) is smaller than chosen \(chosenFormatWidth)x\(chosenFormatHeight); re-asserting format at a USB-2-safe frame rate (est raw \(String(format: "%.0f", raw)) Mbps at the chosen size)")
            session.beginConfiguration()
            if let format = chosenDeviceFormat {
                try? applyDeviceFormat(format, on: camera, reason: "mismatch-reassert")
            }
            session.commitConfiguration()
            deliveredFrameLogged = false
            return
        }
        if resolutionPass == 1 {
            resolutionPass = 2
            // Prefer 2560 then 2048, 420v over yuvs, and skip the already-chosen size.
            func altScore(_ format: AVCaptureDevice.Format) -> (Int, Int) {
                let d = formatDimensions(format)
                let tier = (d.width == 2560) ? 2 : 1
                return (tier, formatIsMJPEG(format) ? 1 : (fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased() == "420v" ? 1 : 0))
            }
            let usable = camera.formats.filter { format in
                let d = formatDimensions(format)
                return (Int(d.width) != chosenFormatWidth || Int(d.height) != chosenFormatHeight)
                    && ((d.width == 2560 && d.height == 1440) || (d.width == 2048 && d.height == 1536))
            }
            if let alt = usable.max(by: { a, b in
                let sa = altScore(a), sb = altScore(b)
                if sa.0 != sb.0 { return sa.0 < sb.0 }
                return sa.1 < sb.1
            }) {
                let d = formatDimensions(alt)
                ScanLog.shared.write("trying fallback format \(d.width)x\(d.height)")
                session.beginConfiguration()
                try? applyDeviceFormat(alt, on: camera, reason: "fallback")
                session.commitConfiguration()
                deliveredFrameLogged = false
                return
            }
        }
        ScanLog.shared.write("hardware/USB could not deliver a 2K video frame (got \(deliveredWidth)x\(deliveredHeight); chosen was \(chosenFormatWidth)x\(chosenFormatHeight) subtype=\(chosenFormatSubtype)). Uncompressed 2592x1944 420v exceeds USB 2.0 bandwidth (~480 Mbps). Keeping \(deliveredWidth)x\(deliveredHeight) so preview and capture stay working.")
    }

    private func startCamera() {
        let devices = videoCaptureDevices()
        ScanLog.shared.write("video devices found=\(devices.count)")
        guard let camera = devices.first(where: { $0.uniqueID.lowercased().contains("1bcf0b26") || $0.localizedName.lowercased().contains("nexigo") }) ?? devices.first else {
            status("No webcam found. Plug in the NexiGo, then relaunch; you can still import photos.")
            return
        }
        do {
            captureDevice = camera
            logAllCameraFormats(camera)
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            // .inputPriority is unavailable on macOS. Do not set .high: that lets
            // the session override a later activeFormat and deliver 1920x1080.
            // Set activeFormat AFTER inputs and outputs are attached, then lock it.
            guard session.canAddInput(input) else { throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"]) }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: cameraQueue)
            guard session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Video output unavailable"]) }
            session.addOutput(output)
            videoDataOutput = output

            photoCaptureSupported = false
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoCaptureSupported = true
                let codecs = photoOutput.availablePhotoCodecTypes.map { $0.rawValue }.joined(separator: ",")
                ScanLog.shared.write("photo output attached codecs=[\(codecs)]")
            } else {
                ScanLog.shared.write("photo output not supported; stills will use the latest video frame")
            }

            if let best = selectBestCaptureFormat(from: camera.formats) {
                do {
                    try applyDeviceFormat(best, on: camera, reason: "chosen")
                } catch {
                    ScanLog.shared.write("requested camera format unavailable; using the device default")
                }
            }

            let continuous = camera.isFocusModeSupported(.continuousAutoFocus)
            let autoFocus = camera.isFocusModeSupported(.autoFocus)
            let pointSupported = camera.isFocusPointOfInterestSupported
            let continuousExp = camera.isExposureModeSupported(.continuousAutoExposure)
            let continuousWB = camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
            do {
                try camera.lockForConfiguration()
                if pointSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if continuous { camera.focusMode = .continuousAutoFocus }
                else if autoFocus { camera.focusMode = .autoFocus }
                if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if continuousExp { camera.exposureMode = .continuousAutoExposure }
                if continuousWB { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
                camera.unlockForConfiguration()
            } catch { ScanLog.shared.write("could not configure autofocus or exposure (camera may manage them internally)") }
            logCameraControls(camera)
            focusInfo = continuous ? "Focus: continuous autofocus requested" :
                        (autoFocus ? "Focus: one-shot autofocus requested" : "Focus: webcam controls unavailable / hardware-managed")
            focusLabel.stringValue = focusInfo + "  |  Debug: ~/BondScans/scan-debug.log"

            session.commitConfiguration()
            logActiveFormatState(camera, at: "after_commit")
            ScanLog.shared.write("camera=\(camera.localizedName) uid_matches_nexigo=\(camera.localizedName.lowercased().contains("nexigo")) continuous_focus=\(continuous) one_shot_focus=\(autoFocus) focus_point=\(pointSupported)")
            status("Camera: \(camera.localizedName). Finding bond outline or printed text…")
            deliveredFrameLogged = false
            resolutionPass = 0
            cameraQueue.async {
                self.session.startRunning()
                self.reassertChosenFormatIfNeeded(afterStart: true)
            }
        } catch { status("Camera error: \(error.localizedDescription)") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastAnalyzeAt > 0.80 else { return }
        lastAnalyzeAt = now
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        if !deliveredFrameLogged {
            deliveredFrameLogged = true
            if let camera = captureDevice {
                logActiveFormatState(camera, at: "first_frame")
            }
            ScanLog.shared.write("delivered video frame=\(cg.width)x\(cg.height) chosen_format=\(chosenFormatWidth)x\(chosenFormatHeight) subtype=\(chosenFormatSubtype) photo_output=\(photoCaptureSupported)")
            if cg.width != chosenFormatWidth || cg.height != chosenFormatHeight {
                let width = cg.width, height = cg.height
                cameraQueue.async { [weak self] in
                    self?.handleDeliveredResolutionMismatch(deliveredWidth: width, deliveredHeight: height)
                }
            }
        }
        if now - lastVideoLogAt > 15.0 {
            ScanLog.shared.write("receiving video frames=\(cg.width)x\(cg.height) auto=\(automatic)")
            lastVideoLogAt = now
        }
        DispatchQueue.main.async { [weak self] in self?.latestImage = cg }
        guard automatic else { return }
        let rect = detectBond(cg)
        DispatchQueue.main.async { [weak self] in self?.handleRectangle(rect, frame: cg) }
    }

    private func handleRectangle(_ rect: CGRect?, frame: CGImage) {
        preview.sourceSize = CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
        preview.showDetected(rect)
        let now = Date().timeIntervalSince1970
        if lockedAfterCapture {
            // The bond is still in view if a paper outline is visible — do not re-arm.
            if rect != nil { noBondChecks = 0 }
            scheduleTextHunt(frame, forRearm: true, rectangleVisible: rect != nil)
            return
        }
        guard automatic && !isProcessing && now >= nextAutoAllowedAt else { return }
        if let rect = rect {
            if let prior = priorRect,
               abs(rect.midX - prior.midX) < 0.05,
               abs(rect.midY - prior.midY) < 0.05,
               abs(rect.width - prior.width) < 0.075,
               abs(rect.height - prior.height) < 0.075 {
                stableFrames += 1
            } else { stableFrames = 1 }
            priorRect = rect
            if stableFrames >= 2 {
                stableFrames = 0
                huntHits = 0
                ScanLog.shared.write("auto capture: stable outline; OCR starts")
                performScan(frame, automaticScan: true)
                return
            }
        } else {
            stableFrames = 0
            priorRect = nil
        }
        if now - lastDiagnosticAt > 4 {
            ScanLog.shared.write("hunting: rectangle=\(rect != nil) stable_frames=\(stableFrames) locked=\(lockedAfterCapture)")
            lastDiagnosticAt = now
        }
        scheduleTextHunt(frame, forRearm: false)
    }

    private func scheduleTextHunt(_ frame: CGImage, forRearm: Bool, rectangleVisible: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard !huntRunning && !isProcessing && now - lastHuntAt > 1.8 else { return }
        lastHuntAt = now
        huntRunning = true
        if !forRearm { status("Hunting for the bond: checking text and all four rotations…") }
        analysisQueue.async { [weak self] in
            let probe = probeForBond(frame)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.huntRunning = false
                let hasBond = probe.found && probe.score >= 52 && probe.lines >= 4
                // For re-arm, treat any bond signal, moderate score, or visible outline as "still present".
                // The stricter hasBond threshold previously re-armed while a Series E was still in view.
                let stillPresent = probe.found || probe.score >= 20 || rectangleVisible
                ScanLog.shared.write("ocr hunt: score=\(probe.score) lines=\(probe.lines) bond_signal=\(probe.found) accepted=\(hasBond) still_present=\(stillPresent) rearm_check=\(forRearm)")
                if forRearm {
                    guard self.lockedAfterCapture else { return }
                    if stillPresent { self.noBondChecks = 0 }
                    else { self.noBondChecks += 1 }
                    if self.noBondChecks >= 2 {
                        self.lockedAfterCapture = false
                        self.noBondChecks = 0
                        self.huntHits = 0
                        self.priorRect = nil
                        self.status("Ready for next bond. Hunting for edges or text…")
                        ScanLog.shared.write("re-armed after two empty OCR checks")
                    } else if stillPresent {
                        ScanLog.shared.write("re-arm deferred: bond still in view")
                    }
                    return
                }
                guard !self.lockedAfterCapture && !self.isProcessing && self.automatic else { return }
                if hasBond {
                    self.huntHits += 1
                    self.status("Bond text found (\(self.huntHits)/2). Hold steady…")
                    if self.huntHits >= 2 {
                        self.huntHits = 0
                        ScanLog.shared.write("auto capture: fallback OCR detected bond without stable outline")
                        self.performScan(frame, automaticScan: true)
                    }
                } else {
                    self.huntHits = 0
                    self.status("No readable bond yet — adjust distance/light or press Space to capture for review.")
                }
            }
        }
    }

    @objc private func scanNow() {
        // Manual capture never waits on rectangle detection or an in-flight OCR job.
        requestPhotograph(automatic: false)
    }

    private func performScan(_ image: CGImage, automaticScan: Bool) {
        if automaticScan {
            guard !isProcessing else { return }
            requestPhotograph(automatic: true, fallback: image)
            return
        }
        requestPhotograph(automatic: false, fallback: image)
    }

    private func requestPhotograph(automatic: Bool, fallback: CGImage? = nil) {
        if photoCaptureSupported, session.isRunning {
            let settings = AVCapturePhotoSettings()
            if #available(macOS 13.0, *) {
                let max = photoOutput.maxPhotoDimensions
                if max.width > 0 && max.height > 0 {
                    settings.maxPhotoDimensions = max
                }
            }
            photoRequests[settings.uniqueID] = automatic
            if automatic { isProcessing = true }
            else { lockedAfterCapture = true }
            ScanLog.shared.write("photograph requested mode=\(automatic ? "auto" : "manual") via=photoOutput ocr_queue=\(ocrPending.count)")
            photoOutput.capturePhoto(with: settings, delegate: self)
            if !automatic {
                let waiting = ocrPending.count + (ocrBusy ? 1 : 0)
                status(waiting > 0
                    ? "Capturing photograph… (\(waiting) still being read)."
                    : "Capturing full-resolution photograph…")
            }
            return
        }
        let image = fallback ?? latestImage
        guard let image = image else {
            if automatic { isProcessing = false }
            else { status("No image from camera yet.") }
            return
        }
        if automatic { isProcessing = true }
        else { lockedAfterCapture = true }
        ScanLog.shared.write("photograph requested mode=\(automatic ? "auto" : "manual") via=videoFrame frame=\(image.width)x\(image.height)")
        finishCapture(image: image, jpegBytes: nil, automatic: automatic)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let uniqueID = photo.resolvedSettings.uniqueID
        let dims = photo.resolvedSettings.photoDimensions
        let failure = error
        let jpeg = (failure == nil) ? photo.fileDataRepresentation() : nil
        let cg = (failure == nil) ? photo.cgImageRepresentation() : nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let automatic = self.photoRequests.removeValue(forKey: uniqueID) ?? false
            if failure != nil {
                ScanLog.shared.write("photo output failed; falling back to video frame")
                if let frame = self.latestImage {
                    self.finishCapture(image: frame, jpegBytes: nil, automatic: automatic)
                } else {
                    if automatic { self.isProcessing = false }
                    else {
                        self.status("Photograph capture failed and no video frame is available.")
                        self.preview.captureFlash(color: .systemRed)
                        NSSound.beep()
                    }
                }
                return
            }
            ScanLog.shared.write("photo output captured \(dims.width)x\(dims.height)")
            let image = cg ?? jpeg.flatMap { cgImageFromData($0) }
            guard let image = image else {
                if let frame = self.latestImage {
                    self.finishCapture(image: frame, jpegBytes: nil, automatic: automatic)
                } else {
                    if automatic { self.isProcessing = false }
                    else {
                        self.status("Photograph could not be decoded.")
                        self.preview.captureFlash(color: .systemRed)
                    }
                }
                return
            }
            self.finishCapture(image: image, jpegBytes: jpeg, automatic: automatic)
        }
    }

    private func finishCapture(image: CGImage, jpegBytes: Data?, automatic: Bool) {
        if automatic {
            ScanLog.shared.write("scan started mode=auto frame=\(image.width)x\(image.height)")
            status("Reading bond with local Apple Vision OCR…")
            analysisQueue.async { [weak self] in
                let result = scanImage(image)
                DispatchQueue.main.async { self?.handleOCR(result, auto: true) }
            }
            return
        }
        commitOriginalAndEnqueue(image: image, jpegBytes: jpegBytes)
    }

    private func commitOriginalAndEnqueue(image: CGImage, jpegBytes: Data?) {
        let id = UUID().uuidString
        let capturedAt = ISO8601DateFormatter().string(from: Date())
        let filename = "\(capturedAt.replacingOccurrences(of: ":", with: "-"))_\(id.prefix(8)).jpg"
        let originalRel = "photos/original_" + filename
        let processedRel = "photos/" + filename
        let originalURL = outputRoot.appendingPathComponent(originalRel)
        let width = image.width
        let height = image.height
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = jpegBytes ?? jpegData(image) else {
                DispatchQueue.main.async {
                    self.status("SAVE FAILED: could not encode the photograph.")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph encode failed")
                }
                return
            }
            do {
                try FileManager.default.createDirectory(at: photosRoot, withIntermediateDirectories: true)
                try data.write(to: originalURL, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.status("SAVE FAILED: \(error.localizedDescription)")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph save failed")
                }
                return
            }
            DispatchQueue.main.async {
                var record = emptyBondRecord(id: id, capturedAt: capturedAt)
                record.photo = processedRel
                record.sourcePhoto = originalRel
                let previous = self.records
                self.records.append(record)
                do { try writeRecords(self.records) }
                catch {
                    self.records = previous
                    self.status("SAVE FAILED: \(error.localizedDescription)")
                    self.preview.captureFlash(color: .systemRed)
                    NSSound.beep()
                    ScanLog.shared.write("original photograph record write failed")
                    return
                }
                self.updateCount()
                self.preview.captureFlash(color: .systemBlue)
                NSSound(named: NSSound.Name("Glass"))?.play()
                self.lockedAfterCapture = true
                self.emptyFrames = 0
                let waiting = self.ocrPending.count + (self.ocrBusy ? 1 : 0)
                if waiting == 0 {
                    self.status("Photograph saved (\(width)×\(height)). Reading it in the background…")
                } else {
                    self.status("Photograph saved (\(width)×\(height)). \(waiting) already in the OCR queue; this one will run next.")
                }
                self.lastLabel.stringValue = "Last: photograph saved, OCR pending…"
                ScanLog.shared.write("original saved status=PROCESSING frame=\(width)x\(height) bytes=\(data.count) total=\(self.records.count) ocr_queue=\(waiting + 1)")
                self.enqueueOCR(id: id, originalURL: originalURL, automatic: false)
            }
        }
    }

    private func enqueueOCR(id: String, originalURL: URL, automatic: Bool) {
        ocrPending.append((id: id, url: originalURL, automatic: automatic))
        pumpOCR()
    }

    private func pumpOCR() {
        guard !ocrBusy, let job = ocrPending.first else { return }
        ocrPending.removeFirst()
        ocrBusy = true
        let remaining = ocrPending.count
        status("Reading the saved photograph with Apple Vision OCR…" + (remaining > 0 ? " (\(remaining) waiting)." : ""))
        analysisQueue.async { [weak self] in
            guard let self = self else { return }
            guard let image = cgImageFromFile(job.url) else {
                DispatchQueue.main.async {
                    self.markOCRFailed(id: job.id, message: "Could not read the saved photograph for OCR. The original file is still in the output folder.")
                    self.ocrBusy = false
                    self.pumpOCR()
                }
                return
            }
            ScanLog.shared.write("ocr of saved photograph started frame=\(image.width)x\(image.height)")
            let result = scanImage(image)
            DispatchQueue.main.async {
                self.applyOCR(result, to: job.id)
                self.ocrBusy = false
                self.pumpOCR()
            }
        }
    }

    private func markOCRFailed(id: String, message: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = "REVIEW"
        records[index].notes = message
        let dest = outputRoot.appendingPathComponent(records[index].photo)
        let src = outputRoot.appendingPathComponent(records[index].sourcePhoto)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: src, to: dest)
        }
        try? writeRecords(records)
        updateCount()
        preview.captureFlash(color: .systemRed)
        status(message)
        ScanLog.shared.write("ocr failed; original photograph preserved")
    }

    private func applyOCR(_ result: OCRResult, to id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            ScanLog.shared.write("ocr result ignored; record no longer present")
            return
        }
        let existing = records[index]
        var record = result.record
        record.id = existing.id
        record.capturedAt = existing.capturedAt
        record.sourcePhoto = existing.sourcePhoto
        record.photo = existing.photo

        if let prior = recordMatchingSerial(record.serial, in: records, excluding: record.id) {
            record.status = "DUPLICATE"
            let note = "DUPLICATE of record \(prior.id). Flagged for review."
            record.notes = record.notes.isEmpty ? note : record.notes + " " + note
            ScanLog.shared.write("scan duplicate detected; photograph kept and record flagged (serial omitted from debug log, prior id=\(prior.id))")
        }

        let processedURL = outputRoot.appendingPathComponent(record.photo)
        let originalURL = outputRoot.appendingPathComponent(record.sourcePhoto)
        do {
            if let data = jpegData(result.image) {
                try data.write(to: processedURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: originalURL.path) {
                if FileManager.default.fileExists(atPath: processedURL.path) { try FileManager.default.removeItem(at: processedURL) }
                try FileManager.default.copyItem(at: originalURL, to: processedURL)
            }
        } catch {
            ScanLog.shared.write("processed photograph write issue; original is preserved")
            if !FileManager.default.fileExists(atPath: processedURL.path), FileManager.default.fileExists(atPath: originalURL.path) {
                try? FileManager.default.copyItem(at: originalURL, to: processedURL)
            }
        }

        let previous = records
        records[index] = record
        do { try writeRecords(records) }
        catch {
            records = previous
            status("OCR results could not be saved: \(error.localizedDescription)")
            preview.captureFlash(color: .systemRed)
            NSSound.beep()
            ScanLog.shared.write("ocr record write failed; original photograph preserved")
            return
        }
        updateCount()
        ScanLog.shared.write("scan updated status=\(record.status) fields_nonempty=\([record.series, record.serial, record.issueMonth, record.issueYear, record.denomination, record.owner].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
        let serialDisplay = record.serial.isEmpty ? "unreadable serial" : record.serial
        lastLabel.stringValue = "Last: \(record.series) \(serialDisplay) | \(record.issueMonth)/\(record.issueYear) | $\(record.denomination) | \(record.status)"
        if record.status == "OK" {
            preview.captureFlash(color: .systemGreen)
            status("OCR complete — verified. Remove the bond, then show the next one.")
        } else if record.status == "DUPLICATE" {
            preview.captureFlash(color: .systemOrange)
            status("Duplicate of an earlier record — photograph kept for review. Remove the bond.")
        } else {
            preview.captureFlash(color: .systemYellow)
            status("OCR complete — review needed. Remove the bond, then show the next one.")
        }
        lockedAfterCapture = true
        emptyFrames = 0
        enrichRecordInBackground(record)
    }


    private func handleOCR(_ result: OCRResult, auto: Bool) {
        var record = result.record
        var isDuplicate = false
        if let prior = recordMatchingSerial(record.serial, in: records, excluding: record.id) {
            isDuplicate = true
            record.status = "DUPLICATE"
            let note = "DUPLICATE of record \(prior.id). Flagged for review."
            record.notes = record.notes.isEmpty ? note : record.notes + " " + note
            ScanLog.shared.write("scan duplicate detected; photograph will be kept and the record flagged (serial omitted from debug log, prior id=\(prior.id))")
        }
        // Save partial readings for later review instead of silently dropping a real bond.
        // Do not save random backgrounds, even if a false-positive rectangle was found.
        if auto && (!result.bondTextFound || result.huntScore < 45) {
            nextAutoAllowedAt = Date().timeIntervalSince1970 + 3.0
            ScanLog.shared.write("auto scan rejected: low OCR evidence score=\(result.huntScore) count=\(result.lineCount)")
            isProcessing = false
            status("Not readable — improve lighting/focus, reposition, or press Space to save for review.")
            return
        }
        // A capture is written immediately. Apple Intelligence enrichment updates the row later.
        let filename = "\(record.capturedAt.replacingOccurrences(of: ":", with: "-"))_\(record.id.prefix(8)).jpg"
        let imageURL = photosRoot.appendingPathComponent(filename)
        record.photo = "photos/" + filename
        record.sourcePhoto = "photos/original_" + filename
        do {
            guard let original = jpegData(result.originalImage) else { throw NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original JPEG encoding failed"]) }
            try original.write(to: outputRoot.appendingPathComponent(record.sourcePhoto), options: .atomic)
            guard let data = jpegData(result.image) else { throw NSError(domain: "Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"]) }
            try data.write(to: imageURL, options: .atomic)
            let previous = records
            records.append(record)
            do { try writeRecords(records) }
            catch { records = previous; throw error }
            updateCount()
            ScanLog.shared.write("scan saved status=\(record.status) fields_nonempty=\([record.series, record.serial, record.issueMonth, record.issueYear, record.denomination, record.owner].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
            let serialDisplay = record.serial.isEmpty ? "unreadable serial" : record.serial
            lastLabel.stringValue = "Last: \(record.series) \(serialDisplay) | \(record.issueMonth)/\(record.issueYear) | $\(record.denomination) | \(record.status)"
            if record.status == "OK" {
                preview.captureFlash(color: .systemGreen)
                status("Saved! Remove bond, then show the next one.")
            } else if isDuplicate || record.status == "DUPLICATE" {
                preview.captureFlash(color: .systemOrange)
                status("Duplicate of an earlier record — photograph kept for review. Remove the bond.")
            } else {
                preview.captureFlash(color: .systemYellow)
                status("Saved for REVIEW. Remove bond, then show the next one.")
            }
            NSSound(named: NSSound.Name("Glass"))?.play()
            // Stay locked until the bond actually leaves the frame (re-arm). Manual Space still captures.
            lockedAfterCapture = true
            emptyFrames = 0
            enrichRecordInBackground(record)
        } catch {
            ScanLog.shared.write("scan save failed")
            status("SAVE FAILED: \(error.localizedDescription)")
            NSSound.beep()
        }
        isProcessing = false
    }

    private func enrichRecordInBackground(_ record: BondRecord) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable,
           let id = UUID(uuidString: record.id) {
            aiPending.append(id)
            processNextAIRecord()
        }
        #endif
    }

    private func processNextAIRecord() {
        #if canImport(FoundationModels)
        guard !aiBusy, !aiPending.isEmpty else { return }
        guard #available(macOS 26.0, *) else { return }
        let id = aiPending.removeFirst().uuidString
        guard let record = records.first(where: { $0.id == id }) else {
            processNextAIRecord()
            return
        }
        aiBusy = true
        Task {
            let updated = await enrichWithAppleIntelligence(record)
            await MainActor.run {
                if let index = self.records.firstIndex(where: { $0.id == updated.id }) {
                    self.records[index] = updated
                    do { try writeRecords(self.records); self.updateCount() }
                    catch { self.status("AI update could not be saved: \(error.localizedDescription)") }
                }
                self.aiBusy = false
                self.processNextAIRecord()
            }
        }
        #endif
    }

    private func updateCount() {
        let processing = records.filter { $0.status == "PROCESSING" }.count
        let duplicates = records.filter { $0.status == "DUPLICATE" }.count
        let reviews = records.filter { $0.status != "OK" && $0.status != "PROCESSING" && $0.status != "DUPLICATE" }.count
        let verified = records.filter { $0.status == "OK" }.count
        var text = "\(records.count) captured  •  \(verified) verified  •  \(reviews) need review"
        if duplicates > 0 { text += "  •  \(duplicates) duplicate" }
        if processing > 0 { text += "  •  \(processing) reading" }
        countLabel.stringValue = text
    }

    @objc private func toggleAuto() {
        automatic.toggle()
        autoButton.title = automatic ? "Auto: ON" : "Auto: OFF"
        ScanLog.shared.write("automatic mode toggled to \(automatic)")
        status(automatic ? "Automatic scanning on. Remove each bond after the confirmation flash." : "Manual mode. Press Space to scan each bond.")
    }

    @objc private func openFolder() { NSWorkspace.shared.open(outputRoot) }

    @objc private func rearm() {
        lockedAfterCapture = false
        stableFrames = 0
        priorRect = nil
        emptyFrames = 0
        huntHits = 0
        noBondChecks = 0
        ScanLog.shared.write("manual re-arm")
        status("Ready for next bond. Hold steady inside the guide.")
    }

    @objc private func undoLast() {
        guard let last = records.last else { return }
        let alert = NSAlert()
        alert.messageText = "Undo the last bond?"
        alert.informativeText = "Removes the last spreadsheet row and moves its photograph to the Trash."
        alert.addButton(withTitle: "Undo")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        records.removeLast()
        do {
            try writeRecords(records)
            let image = outputRoot.appendingPathComponent(last.photo)
            if FileManager.default.fileExists(atPath: image.path) { try? FileManager.default.trashItem(at: image, resultingItemURL: nil) }
            let original = outputRoot.appendingPathComponent(last.sourcePhoto)
            if FileManager.default.fileExists(atPath: original.path) { try? FileManager.default.trashItem(at: original, resultingItemURL: nil) }
            updateCount()
            lockedAfterCapture = false
            status("Undid last scan. Ready.")
        } catch {
            records.append(last)
            status("Cannot undo: \(error.localizedDescription)")
        }
    }

    @objc private func importPhotos() {
        let picker = NSOpenPanel()
        picker.title = "Import test bond photos"
        picker.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importFiles(picker.urls)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        status("Importing \(urls.count) photos…")
        // Save each original immediately, then let the shared OCR queue process them.
        func next(_ index: Int) {
            guard index < urls.count else {
                self.status("Import finished. Photographs are saved; OCR continues in the background.")
                return
            }
            let url = urls[index]
            self.saveQueue.async { [weak self] in
                guard let self = self else { return }
                guard let image = cgImageFromFile(url) else {
                    DispatchQueue.main.async { next(index + 1) }
                    return
                }
                DispatchQueue.main.async {
                    self.commitOriginalAndEnqueue(image: image, jpegBytes: nil)
                    next(index + 1)
                }
            }
        }
        next(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = BondScannerApp()
app.delegate = delegate
app.run()
