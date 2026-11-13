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
        if d.width == 2592 && d.height == 1944 { tier = 3 }
        else if d.width == 2560 && d.height == 1440 { tier = 2 }
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

final class BondScannerApp: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
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
    private var deliveredFrameLogged = false
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
        ScanLog.shared.write("app launch: version=2 records=\(records.count) no OCR text or identifiers logged")
        updateCount()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { self?.scanNow(); return nil } // Space
            return event
        }
        requestCameraAccess()
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
            // .inputPriority is unavailable on macOS. Setting activeFormat below
            // automatically promotes the session preset to input-priority behavior.
            // Do not set .high — that lets the session override the chosen format
            // and can leave 2592x1944 advertised while video only delivers 1920x1080.
            guard session.canAddInput(input) else { throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"]) }
            session.addInput(input)

            if let best = selectBestCaptureFormat(from: camera.formats) {
                let dims = formatDimensions(best)
                let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(best.formatDescription))
                do {
                    try camera.lockForConfiguration()
                    camera.activeFormat = best
                    if let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                        let target = min(range.maxFrameRate, 30.0)
                        let clamped = max(range.minFrameRate, target)
                        let duration = CMTimeMake(value: 100, timescale: CMTimeScale(max(1, Int32((clamped * 100).rounded()))))
                        if duration >= range.minFrameDuration && duration <= range.maxFrameDuration {
                            camera.activeVideoMinFrameDuration = duration
                            camera.activeVideoMaxFrameDuration = duration
                            ScanLog.shared.write("requested frame rate=\(clamped)")
                        } else {
                            ScanLog.shared.write("frame rate left at device default; range=\(range.minFrameRate)-\(range.maxFrameRate)")
                        }
                    }
                    camera.unlockForConfiguration()
                    chosenFormatWidth = Int(dims.width)
                    chosenFormatHeight = Int(dims.height)
                    chosenFormatSubtype = sub
                    ScanLog.shared.write("chosen_camera_format=\(dims.width)x\(dims.height) subtype=\(sub) mjpeg=\(formatIsMJPEG(best))")
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

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: cameraQueue)
            guard session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Video output unavailable"]) }
            session.addOutput(output)

            photoCaptureSupported = false
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoCaptureSupported = true
                var photoLog = "photo output attached"
                if #available(macOS 13.0, *) {
                    let max = photoOutput.maxPhotoDimensions
                    photoLog += " max_photo=\(max.width)x\(max.height)"
                }
                let codecs = photoOutput.availablePhotoCodecTypes.map { $0.rawValue }.joined(separator: ",")
                photoLog += " codecs=[\(codecs)]"
                ScanLog.shared.write(photoLog)
            } else {
                ScanLog.shared.write("photo output not supported; stills will use the latest video frame")
            }

            session.commitConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(camera.activeFormat.formatDescription))
            ScanLog.shared.write("active_camera_format=\(dims.width)x\(dims.height) subtype=\(sub) session_preset=\(session.sessionPreset.rawValue) photo_output=\(photoCaptureSupported)")
            ScanLog.shared.write("camera=\(camera.localizedName) uid_matches_nexigo=\(camera.localizedName.lowercased().contains("nexigo")) continuous_focus=\(continuous) one_shot_focus=\(autoFocus) focus_point=\(pointSupported)")
            status("Camera: \(camera.localizedName). Finding bond outline or printed text…")
            deliveredFrameLogged = false
            cameraQueue.async { self.session.startRunning() }
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
            ScanLog.shared.write("delivered video frame=\(cg.width)x\(cg.height) chosen_format=\(chosenFormatWidth)x\(chosenFormatHeight) subtype=\(chosenFormatSubtype) photo_output=\(photoCaptureSupported)")
            if cg.width != chosenFormatWidth || cg.height != chosenFormatHeight {
                ScanLog.shared.write("note: delivered video dimensions differ from activeFormat; still photographs use photo output when available")
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
            // OCR also handles re-arming when the table itself creates a rectangle.
            scheduleTextHunt(frame, forRearm: true)
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

    private func scheduleTextHunt(_ frame: CGImage, forRearm: Bool) {
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
                ScanLog.shared.write("ocr hunt: score=\(probe.score) lines=\(probe.lines) bond_signal=\(probe.found) accepted=\(hasBond) rearm_check=\(forRearm)")
                if forRearm {
                    guard self.lockedAfterCapture else { return }
                    if hasBond { self.noBondChecks = 0 }
                    else { self.noBondChecks += 1 }
                    if self.noBondChecks >= 2 {
                        self.lockedAfterCapture = false
                        self.noBondChecks = 0
                        self.huntHits = 0
                        self.priorRect = nil
                        self.status("Ready for next bond. Hunting for edges or text…")
                        ScanLog.shared.write("re-armed after two empty OCR checks")
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
        guard let image = latestImage else { status("No image from camera yet."); return }
        performScan(image, automaticScan: false)
    }

    private func performScan(_ image: CGImage, automaticScan: Bool) {
        guard !isProcessing else { return }
        isProcessing = true
        ScanLog.shared.write("scan started mode=\(automaticScan ? "auto" : "manual") frame=\(image.width)x\(image.height)")
        status("Reading bond with local Apple Vision OCR…")
        analysisQueue.async { [weak self] in
            let result = scanImage(image)
            DispatchQueue.main.async {
                self?.handleOCR(result, auto: automaticScan)
            }
        }
    }

    private func handleOCR(_ result: OCRResult, auto: Bool) {
        var record = result.record
        if !record.serial.isEmpty && records.contains(where: { $0.serial == record.serial }) {
            ScanLog.shared.write("scan duplicate detected (serial omitted from debug log)")
            isProcessing = false
            status("Duplicate serial \(record.serial) — skipped. Remove this bond.")
            preview.captureFlash(color: .systemOrange)
            NSSound.beep()
            if auto { lockedAfterCapture = true }
            return
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
            preview.captureFlash(color: record.status == "OK" ? .systemGreen : .systemYellow)
            NSSound(named: NSSound.Name("Glass"))?.play()
            status(record.status == "OK" ? "Saved! Remove bond, then show the next one." : "Saved for REVIEW. Remove bond, then show the next one.")
            if auto { lockedAfterCapture = true; emptyFrames = 0 }
            // Also lock manually scanned bond to avoid accidental auto duplicate while held.
            if !auto { lockedAfterCapture = true; emptyFrames = 0 }
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
        let reviews = records.filter { $0.status != "OK" }.count
        countLabel.stringValue = "\(records.count) bonds scanned  •  \(reviews) need review"
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
        func next(_ index: Int) {
            guard index < urls.count else { self.status("Photo import finished. Open output folder to review bonds.csv."); return }
            let url = urls[index]
            self.analysisQueue.async { [weak self] in
                guard let self = self else { return }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    DispatchQueue.main.async { next(index + 1) }
                    return
                }
                let result = scanImage(image)
                DispatchQueue.main.async {
                    if self.isProcessing {
                        self.status("Scanner busy; import canceled. Try again.")
                        return
                    }
                    self.isProcessing = true
                    self.handleOCR(result, auto: false)
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
