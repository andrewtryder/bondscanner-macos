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

struct FieldReading {
    var value: String = ""
    var confidence: String = "" // "high" or "uncertain"
    var source: String = ""
    var isHigh: Bool { confidence == "high" && !value.isEmpty }
    var isUncertain: Bool { confidence == "uncertain" && !value.isEmpty }
}

func setFieldReading(_ key: String, _ reading: FieldReading, on record: inout BondRecord) {
    var conf = record.fieldConfidence ?? [:]
    var src = record.fieldSource ?? [:]
    if reading.value.isEmpty {
        conf[key] = nil
        src[key] = nil
    } else {
        conf[key] = reading.confidence
        src[key] = reading.source
    }
    record.fieldConfidence = conf
    record.fieldSource = src
}

func fieldConfidenceIsHigh(_ record: BondRecord, _ key: String) -> Bool {
    return (record.fieldConfidence?[key] ?? "") == "high"
}

func validSeriesValues() -> [String] { ["E", "EE", "I"] }

func validFaceValues(for series: String) -> [String] {
    // Series E face values. Same list is used when the series is still unknown,
    // so a stray "20" (not a Series E denomination) cannot go green.
    return ["10000", "5000", "1000", "500", "200", "100", "75", "50", "25", "10"]
}

/// Series E: 1 letter + 10 digits + E (12 chars). Series EE: 1 letter + 10 digits + EE.
/// Strips a leading junk character only when the remainder already matches exactly.
/// Never invents a missing prefix letter or any other character.
func validatedSerial(_ raw: String, series: String = "") -> FieldReading {
    let n = normalizeSerial(raw)
    guard !n.isEmpty else { return FieldReading() }

    func isExactE(_ s: String) -> Bool {
        return s.count == 12 && regexMatches("^[A-Z][0-9]{10}E$", in: s).isEmpty == false
    }
    func isExactEE(_ s: String) -> Bool {
        return s.count == 13 && regexMatches("^[A-Z][0-9]{10}EE$", in: s).isEmpty == false
    }
    func isExactI(_ s: String) -> Bool {
        return regexMatches("^[A-Z][0-9]{10}I$", in: s).isEmpty == false
    }
    func isExact(_ s: String) -> Bool {
        if series == "EE" { return isExactEE(s) }
        if series == "I" { return isExactI(s) }
        if series == "E" { return isExactE(s) }
        return isExactEE(s) || isExactE(s) || isExactI(s)
    }

    // Prefer an exact-pattern SUBSTRING so a glued prefix (a name's last letter)
    // is treated as junk only when the remainder itself is an exact serial.
    let eeHits = regexMatches("[A-Z][0-9]{10}EE", in: n)
    let eHits = regexMatches("[A-Z][0-9]{10}E", in: n).filter { hit in
        // Do not accept the E-truncated form of an EE serial.
        guard let range = n.range(of: hit) else { return false }
        let after = range.upperBound
        if after < n.endIndex, n[after] == "E" { return false }
        return isExactE(hit)
    }
    let iHits = regexMatches("[A-Z][0-9]{10}I", in: n).filter { isExactI($0) }

    if series == "EE" || (series.isEmpty && !eeHits.isEmpty) {
        if let hit = eeHits.first, isExactEE(hit) {
            let source = (hit == n) ? "pattern" : "stripped-leading-junk"
            return FieldReading(value: hit, confidence: "high", source: source)
        }
    }
    if let hit = eHits.first, isExactE(hit) {
        let source = (hit == n) ? "pattern" : "stripped-leading-junk"
        return FieldReading(value: hit, confidence: "high", source: source)
    }
    if let hit = iHits.first, isExactI(hit) {
        let source = (hit == n) ? "pattern" : "stripped-leading-junk"
        return FieldReading(value: hit, confidence: "high", source: source)
    }

    // Near-miss (wrong length, extra digit) kept for review only — never green,
    // and never shortened or given a made-up prefix letter.
    let loose = regexMatches("[A-Z][0-9]{7,11}(?:EE|E|I)", in: n)
    if let hit = loose.first {
        return FieldReading(value: hit, confidence: "uncertain", source: "unvalidated")
    }
    return FieldReading()
}

func monthNumber(_ text: String) -> String? {
    let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    let s = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let i = names.firstIndex(where: { s.hasPrefix($0) }) { return String(format: "%02d", i + 1) }
    if let v = Int(s), (1...12).contains(v) { return String(format: "%02d", v) }
    return nil
}

func requiredFieldIsConfident(_ record: BondRecord, key: String, value: String) -> Bool {
    guard !value.isEmpty else { return false }
    if (record.fieldConfidence?[key] ?? "") == "uncertain" { return false }
    if (record.fieldConfidence?[key] ?? "") == "high" { return true }
    // Legacy rows with no confidence: do not treat as green just because a value is present.
    return false
}

func requiredFieldsComplete(_ record: BondRecord) -> Bool {
    return requiredFieldIsConfident(record, key: "serial", value: record.serial)
        && requiredFieldIsConfident(record, key: "series", value: record.series)
        && requiredFieldIsConfident(record, key: "issueDate", value: record.issueMonth)
        && requiredFieldIsConfident(record, key: "issueDate", value: record.issueYear)
        && requiredFieldIsConfident(record, key: "denomination", value: record.denomination)
}

func requiredFieldsMissing(_ record: BondRecord) -> [String] {
    var missing: [String] = []
    if !requiredFieldIsConfident(record, key: "serial", value: record.serial) { missing.append("serial") }
    if !requiredFieldIsConfident(record, key: "series", value: record.series) { missing.append("series") }
    if !requiredFieldIsConfident(record, key: "issueDate", value: record.issueMonth)
        || !requiredFieldIsConfident(record, key: "issueDate", value: record.issueYear) {
        missing.append("issue date")
    }
    if !requiredFieldIsConfident(record, key: "denomination", value: record.denomination) { missing.append("face value") }
    return missing
}

/// Green / verified only when serial, series, issue month+year, and face value
/// all pass validation with high confidence (agreement for face value; exact
/// serial pattern). An uncertain amount or serial is REVIEW, never green.
func applyRequiredStatus(_ record: inout BondRecord) {
    let missing = requiredFieldsMissing(record)
    if missing.isEmpty {
        record.status = "OK"
        // Keep any informational notes that are not a missing-field warning.
        if record.notes.hasPrefix("Missing or uncertain:") { record.notes = "" }
    } else {
        record.status = "REVIEW"
        record.notes = "Missing or uncertain: " + missing.joined(separator: ", ")
    }
}

func mergeBondRecord(from incoming: BondRecord, into existing: inout BondRecord, contributingPhoto: String, contributingSource: String, captureId: String) -> [String] {
    var filled: [String] = []
    func incomingHigh(_ key: String) -> Bool {
        return (incoming.fieldConfidence?[key] ?? "") == "high"
    }
    func existingHigh(_ key: String) -> Bool {
        return (existing.fieldConfidence?[key] ?? "") == "high"
    }
    func take(_ key: String, confidenceKey: String? = nil, current: String, incomingValue: String, set: (String) -> Void) {
        let ckey = confidenceKey ?? key
        let incomingOK = !incomingValue.isEmpty
        let shouldReplaceUncertain = !current.isEmpty && incomingOK && incomingHigh(ckey) && !existingHigh(ckey)
        let shouldFillEmpty = current.isEmpty && incomingOK
        guard shouldFillEmpty || shouldReplaceUncertain else { return }
        if shouldReplaceUncertain {
            var prev = existing.previousExtracted ?? [:]
            if prev[key] == nil { prev[key] = current }
            existing.previousExtracted = prev
        }
        set(incomingValue)
        var photos = existing.fieldPhoto ?? [:]
        var ids = existing.fieldCaptureId ?? [:]
        var conf = existing.fieldConfidence ?? [:]
        var src = existing.fieldSource ?? [:]
        photos[key] = contributingSource.isEmpty ? contributingPhoto : contributingSource
        ids[key] = captureId
        if let c = incoming.fieldConfidence?[ckey] { conf[ckey] = c }
        if let s = incoming.fieldSource?[ckey] { src[ckey] = s }
        existing.fieldPhoto = photos
        existing.fieldCaptureId = ids
        existing.fieldConfidence = conf
        existing.fieldSource = src
        filled.append(key)
    }
    take("series", current: existing.series, incomingValue: incoming.series) { existing.series = $0 }
    take("serial", current: existing.serial, incomingValue: incoming.serial) { existing.serial = $0 }
    take("issueMonth", confidenceKey: "issueDate", current: existing.issueMonth, incomingValue: incoming.issueMonth) { existing.issueMonth = $0 }
    take("issueYear", confidenceKey: "issueDate", current: existing.issueYear, incomingValue: incoming.issueYear) { existing.issueYear = $0 }
    take("denomination", current: existing.denomination, incomingValue: incoming.denomination) { existing.denomination = $0 }
    if !filled.isEmpty {
        if existing.owner.isEmpty && !incoming.owner.isEmpty { existing.owner = incoming.owner }
        if existing.secondName.isEmpty && !incoming.secondName.isEmpty { existing.secondName = incoming.secondName }
        if existing.secondRole.isEmpty && !incoming.secondRole.isEmpty { existing.secondRole = incoming.secondRole }
        if existing.address.isEmpty && !incoming.address.isEmpty { existing.address = incoming.address }
        if existing.issuingAgent.isEmpty && !incoming.issuingAgent.isEmpty { existing.issuingAgent = incoming.issuingAgent }
        if existing.datingStamp.isEmpty && !incoming.datingStamp.isEmpty { existing.datingStamp = incoming.datingStamp }
        if !incoming.rawOCR.isEmpty {
            if let prev = existing.additionalOCR, !prev.isEmpty {
                existing.additionalOCR = prev + "\n---\n" + incoming.rawOCR
            } else {
                existing.additionalOCR = incoming.rawOCR
            }
        }
    }
    applyRequiredStatus(&existing)
    return filled
}

func annotateFieldSources(_ record: inout BondRecord, photo: String, captureId: String, fields: [String]? = nil) {
    var photos = record.fieldPhoto ?? [:]
    var ids = record.fieldCaptureId ?? [:]
    let pairs: [(String, String)] = [
        ("series", record.series), ("serial", record.serial),
        ("issueMonth", record.issueMonth), ("issueYear", record.issueYear),
        ("denomination", record.denomination)
    ]
    for (key, value) in pairs {
        if value.isEmpty { continue }
        if let fields = fields, !fields.contains(key) { continue }
        if photos[key] == nil {
            photos[key] = photo
            ids[key] = captureId
        }
    }
    record.fieldPhoto = photos
    record.fieldCaptureId = ids
}

func normalizeDenominationText(_ raw: String) -> String {
    var t = raw.uppercased()
    let replacements = [
        "DORLARS": "DOLLARS", "D0LLARS": "DOLLARS", "DCLLARS": "DOLLARS",
        "DOLIARS": "DOLLARS", "DOILARS": "DOLLARS", "DOLARS": "DOLLARS",
        "TWENTV": "TWENTY", "TVENTY": "TWENTY",
        "SEVENTV": "SEVENTY", "SEVEMTY": "SEVENTY",
        "I8.75": "18.75", "I8,75": "18.75",
        "\u{2014}": "-", "\u{2013}": "-", "\u{2212}": "-"
    ]
    for (a, b) in replacements { t = t.replacingOccurrences(of: a, with: b) }
    return t
}

func levenshtein(_ a: String, _ b: String) -> Int {
    let aChars = Array(a), bChars = Array(b)
    if aChars.isEmpty { return bChars.count }
    if bChars.isEmpty { return aChars.count }
    var prev = Array(0...bChars.count)
    var cur = [Int](repeating: 0, count: bChars.count + 1)
    for i in 1...aChars.count {
        cur[0] = i
        for j in 1...bChars.count {
            let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &cur)
    }
    return prev[bChars.count]
}

/// Letters only, so "TVENTYFINE DOLLARS" → "TVENTYFINEDOLLARS".
func lettersOnly(_ raw: String) -> String {
    return normalizeDenominationText(raw).filter { $0.isLetter }
}

/// True when the text is a bank dating stamp or other date (day + month name,
/// month + year with a day numeral). Face-value extraction must ignore these.
func isDateLikeText(_ text: String) -> Bool {
    let t = normalizeDenominationText(text)
    let months = "JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?"
    // "10 MAY", "10 MAY 1966", "L0 MAY", "I0 MAY" (OCR 10), "MAY 10"
    if regexMatches("(?:^|\\D)(?:[0-3]?[0-9]|[LI][O0]|[O0][0-9])\\s*(?:\(months))", in: t).isEmpty == false {
        return true
    }
    if regexMatches("(?:\(months))\\s+[0-3]?[0-9]\\b", in: t).isEmpty == false {
        return true
    }
    return false
}

func isYearToken(_ token: String) -> Bool {
    return regexMatches("^(?:19|20)[0-9]{2}$", in: token).isEmpty == false
}

/// Series E was issued 1941–1980, EE from 1980, I from 1998. 1900 and other
/// OCR near-misses are not plausible issue years.
func isPlausibleIssueYear(_ year: String, series: String) -> Bool {
    guard let y = Int(year), year.count == 4 else { return false }
    if series == "E" { return (1941...1980).contains(y) }
    if series == "EE" { return (1980...2026).contains(y) }
    if series == "I" { return (1998...2026).contains(y) }
    return (1941...2026).contains(y)
}

/// Month from a month NAME only. Bare 1…12 are ruler ticks and must not
/// become an issue month.
func monthFromName(_ text: String) -> String? {
    let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    let s = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    // "FEB", "FEBRUARY", "FEB 1966". Reject bare "10" or "12" (ruler ticks).
    if let i = names.firstIndex(where: { s.hasPrefix($0) }) {
        return String(format: "%02d", i + 1)
    }
    // Common OCR confusions for a faint 3-letter month (especially SEP).
    let aliases: [String: String] = [
        "SEF": "SEP", "SFP": "SEP", "5EP": "SEP", "SCP": "SEP", "SETEMBER": "SEP"
    ]
    let token = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).first.map(String.init) ?? s
    if let canon = aliases[token], let i = names.firstIndex(of: canon) {
        return String(format: "%02d", i + 1)
    }
    return nil
}

func monthAbbrev(_ month: String) -> String {
    let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    if let i = Int(month), (1...12).contains(i) { return names[i - 1] }
    return month
}

func isRulerLikeText(_ text: String) -> Bool {
    let t = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if t.contains("INCH") || t.contains("CENTIMETER") || t == "CM" || t == "MM" || t == "IN" { return true }
    // Isolated tick numbers: "1", "10", "12", "1 2 3 4".
    let compact = t.replacingOccurrences(of: " ", with: "")
    if regexMatches("^[0-9]{1,2}$", in: compact).isEmpty == false {
        if let n = Int(compact), (0...16).contains(n) { return true }
    }
    let nums = regexMatches("\\b[0-9]{1,2}\\b", in: t)
    if nums.count >= 3, nums.allSatisfy({ Int($0) ?? 99 <= 16 }) { return true }
    return false
}

/// Fuzzy word-amount reader. Matches "TWENTY FIVE DOLLARS" and OCR near-misses
/// such as "TVENTYFINE DOLLARS" (V/W and FINE/FIVE). Returns (value, strength)
/// where strength 2 is a strong phrase match and 1 is a weaker isolated word.
func wordAmountReadings(in blob: String, series: String) -> [(value: String, strength: Int, evidence: String)] {
    let faces = validFaceValues(for: series)
    let normalized = normalizeDenominationText(blob)
    let compact = lettersOnly(blob)
    var hits: [(String, Int, String)] = []

    // Fuzzy search is limited to the compounds that OCR actually garbles
    // (TVENTYFINE → TWENTYFIVE). "TENDOLLARS" is NOT fuzzed: distance 2 on
    // that phrase false-matches other bond text and then goes green as $10.
    let phrases: [(String, String, Int)] = [
        ("TENTHOUSAND", "10000", 2), ("FIVETHOUSAND", "5000", 2),
        ("ONETHOUSAND", "1000", 2), ("FIVEHUNDRED", "500", 2),
        ("TWOHUNDRED", "200", 2), ("ONEHUNDRED", "100", 2),
        ("SEVENTYFIVE", "75", 2), ("TWENTYFIVE", "25", 2),
        ("FIFTYDOLLARS", "50", 2)
    ]
    // Exact (after TVENTY→TWENTY normalization) first.
    let exactPairs: [(String, String)] = [
        ("TEN THOUSAND", "10000"), ("FIVE THOUSAND", "5000"),
        ("ONE THOUSAND", "1000"), ("FIVE HUNDRED", "500"),
        ("TWO HUNDRED", "200"), ("ONE HUNDRED", "100"),
        ("SEVENTY-FIVE", "75"), ("SEVENTY FIVE", "75"), ("SEVENTYFIVE", "75"),
        ("TWENTY-FIVE", "25"), ("TWENTY FIVE", "25"), ("TWENTYFIVE", "25"),
        ("FIFTY DOLLARS", "50"), ("TEN DOLLARS", "10"),
        ("SEVENTY FIVE DOLLARS", "75"), ("TWENTY FIVE DOLLARS", "25")
    ]
    for (word, amount) in exactPairs where faces.contains(amount) && normalized.contains(word) {
        hits.append((amount, 2, word))
    }
    if regexMatches("TWENTY[\\s-]*F[I1L]?VE", in: normalized).isEmpty == false { hits.append(("25", 2, "TWENTY-FIVE")) }
    if regexMatches("SEVENTY[\\s-]*F[I1L]?VE", in: normalized).isEmpty == false { hits.append(("75", 2, "SEVENTY-FIVE")) }

    // Sliding-window Levenshtein against compact letter strings (TVENTYFINE ≈ TWENTYFIVE).
    for (phrase, amount, strength) in phrases where faces.contains(amount) {
        let target = Array(phrase)
        let chars = Array(compact)
        guard chars.count >= target.count - 1 else { continue }
        let maxDist = max(1, min(2, target.count / 5 + 1)) // 10-letter phrase allows 2
        let minLen = max(target.count - 1, 1)
        let maxLen = target.count + 1
        if chars.count >= minLen {
            for len in minLen...min(maxLen, chars.count) {
                if chars.count < len { break }
                for start in 0...(chars.count - len) {
                    let window = String(chars[start..<(start + len)])
                    if levenshtein(window, phrase) <= maxDist {
                        hits.append((amount, strength, "fuzzy:\(phrase)"))
                    }
                }
            }
        }
    }
    // Isolated FIFTY / HUNDRED without DOLLARS is weaker and easy to hallucinate.
    if hits.isEmpty {
        if normalized.contains("FIFTY") && faces.contains("50") { hits.append(("50", 1, "FIFTY")) }
        if normalized.contains("THOUSAND") && faces.contains("1000") && !normalized.contains("TEN THOUSAND") && !normalized.contains("FIVE THOUSAND") {
            hits.append(("1000", 1, "THOUSAND"))
        }
    }
    // Dedup, keep strongest evidence for each amount.
    var best: [String: (Int, String)] = [:]
    for (v, s, e) in hits {
        if let prev = best[v], prev.0 >= s { continue }
        best[v] = (s, e)
    }
    // More specific compounds (TWENTYFIVE) ahead of shorter ones (TEN DOLLARS)
    // so `.first` cannot pick a false $10 over a real $25.
    return best.map { ($0.key, $0.value.0, $0.value.1) }.sorted { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        return a.2.count > b.2.count
    }
}

func cornerNumeralReadings(_ lines: [OCRLine], series: String, treatAsCorner: Bool) -> [(value: String, votes: Int)] {
    let faces = validFaceValues(for: series)
    func isCorner(_ box: CGRect) -> Bool {
        let xEdge = box.midX < 0.22 || box.midX > 0.78
        let yEdge = box.midY < 0.28 || box.midY > 0.72
        return xEdge && yEdge
    }
    var votes: [String: Int] = [:]
    for line in lines {
        if isDateLikeText(line.text) { continue }
        if isRulerLikeText(line.text) { continue }
        let token = cleanAlnum(line.text)
        if isYearToken(token) { continue }
        // "10 MAY 1966" compacted is 10MAY1966 — skip any face value on a date line (already continued).
        var candidates: [String] = []
        if faces.contains(token) { candidates.append(token) }
        if token.hasSuffix("00") && token.count == 4 {
            let stem = String(token.dropLast(2))
            if faces.contains(stem) { candidates.append(stem) }
        }
        for value in candidates {
            let onCorner = treatAsCorner || isCorner(line.box)
            let onSide = line.box.midX < 0.22 || line.box.midX > 0.78
            if onCorner || onSide {
                // Side-only (not a true corner) is a weaker vote, and a lonely
                // "10" on the right edge is often the day of a dating stamp.
                votes[value, default: 0] += onCorner ? 2 : 1
            }
        }
    }
    return votes.map { ($0.key, $0.value) }.sorted { $0.votes > $1.votes }
}

/// Supporting (non-word, non-corner) evidence: $25, "25 DOLLARS", MATURITY VALUE,
/// Series E issue-price → face. Never uses a date-like token.
func supportingNumeralReading(_ lines: [OCRLine], series: String) -> FieldReading {
    let faces = validFaceValues(for: series)
    let usable = lines.filter { !isDateLikeText($0.text) && !isRulerLikeText($0.text) }
    let blob = normalizeDenominationText(usable.map(\.text).joined(separator: " "))

    let dollarPattern = "\\$\\s*(10(?:000|00)?|5000|500|200|100|75|50|25|10)(?:\\.00)?"
    if let hit = regexMatches(dollarPattern, in: blob).first {
        let digits = hit.filter { $0.isNumber }
        if faces.contains(digits) {
            return FieldReading(value: digits, confidence: "uncertain", source: "dollar-numeral")
        }
    }
    for value in faces {
        if blob.contains(value + " DOLLARS") || blob.contains(value + " DOLLAR") {
            return FieldReading(value: value, confidence: "high", source: "numeral-dollars")
        }
    }
    if blob.contains("MATURITY") || blob.contains("FACE VALUE") || blob.contains("MATURITY VALUE") {
        for value in faces {
            if regexMatches("(?:MATURITY|FACE)\\s*(?:VALUE)?[^A-Z0-9]{0,12}" + value + "\\b", in: blob).isEmpty == false
                || regexMatches("\\b" + value + "\\b[^A-Z0-9]{0,12}(?:MATURITY|FACE)", in: blob).isEmpty == false {
                return FieldReading(value: value, confidence: "uncertain", source: "maturity-label")
            }
        }
    }
    if series == "E" || series.isEmpty || series == "I" {
        let issueMap: [(String, String)] = [
            ("18\\s*[.,]\\s*75", "25"),
            ("37\\s*[.,]\\s*50", "50"),
            ("56\\s*[.,]\\s*25", "75"),
            ("75\\s*[.,]\\s*00", "100"),
            ("150\\s*[.,]\\s*00", "200"),
            ("375\\s*[.,]\\s*00", "500"),
            ("750\\s*[.,]\\s*00", "1000"),
            ("7\\s*[.,]\\s*50", "10")
        ]
        let priceContext = blob.contains("ISSUE") || blob.contains("PRICE") || blob.contains("PURCHASE")
        if priceContext {
            for (pattern, face) in issueMap where faces.contains(face) {
                if regexMatches(pattern, in: blob).isEmpty == false {
                    return FieldReading(value: face, confidence: "uncertain", source: "issue-price")
                }
            }
        }
    }
    return FieldReading()
}

/// Face / maturity value with confidence. Prefers fuzzy word amounts and large
/// corner numerals. Ignores dating-stamp regions and date-like tokens.
/// Word and corner must agree for a high-confidence amount; a lone weak source
/// (for example a "10" taken from "10 MAY 1966") is uncertain → REVIEW.
func extractDenominationReading(_ lines: [OCRLine], series: String, treatAsCorner: Bool = false) -> FieldReading {
    let blob = lines.map(\.text).joined(separator: " ")
    let words = wordAmountReadings(in: blob, series: series)
    let corners = cornerNumeralReadings(lines, series: series, treatAsCorner: treatAsCorner)
    let supporting = supportingNumeralReading(lines, series: series)

    let strongWord = words.filter { $0.strength >= 2 }
    let uniqueStrongWords = Set(strongWord.map { $0.value })
    // Already sorted most-specific first.
    let wordValue = (strongWord.first ?? words.first)?.value ?? ""
    let wordStrong = strongWord.contains { $0.value == wordValue } && uniqueStrongWords.count == 1
    let wordsDisagree = uniqueStrongWords.count > 1
    let strongCorners = corners.filter { $0.votes >= 2 }
    let cornerValue = (strongCorners.first ?? corners.first)?.value ?? ""
    let cornerStrong = strongCorners.contains { $0.value == cornerValue && $0.votes >= 2 }
    // $10 is a ruler tick and a calendar day. Never high from corners alone.
    func tenNeedsWords(_ value: String, fromWords: Bool) -> Bool {
        return value == "10" && !fromWords
    }

    if wordsDisagree {
        let preferred = strongWord.first!.value
        return FieldReading(value: preferred, confidence: "uncertain", source: "words-disagree")
    }
    if !wordValue.isEmpty && !cornerValue.isEmpty {
        if wordValue == cornerValue && (wordStrong || cornerStrong) {
            return FieldReading(value: wordValue, confidence: "high", source: "words+corners")
        }
        // Disagreement: keep the word amount if it is strong, but never green.
        if wordStrong {
            return FieldReading(value: wordValue, confidence: "uncertain", source: "words-disagree-corners:\(cornerValue)")
        }
        if cornerStrong {
            return FieldReading(value: cornerValue, confidence: "uncertain", source: "corners-disagree-words:\(wordValue)")
        }
        return FieldReading(value: wordValue, confidence: "uncertain", source: "disagree")
    }
    if wordStrong && !wordValue.isEmpty {
        return FieldReading(value: wordValue, confidence: "high", source: "words")
    }
    if cornerStrong && !cornerValue.isEmpty {
        if tenNeedsWords(cornerValue, fromWords: false) {
            return FieldReading(value: cornerValue, confidence: "uncertain", source: "corners-ten")
        }
        return FieldReading(value: cornerValue, confidence: "high", source: "corners")
    }
    // Only a weak source (single side numeral, isolated word, issue-price, $n).
    if !wordValue.isEmpty {
        return FieldReading(value: wordValue, confidence: "uncertain", source: "words-weak")
    }
    if !cornerValue.isEmpty {
        return FieldReading(value: cornerValue, confidence: "uncertain", source: "corners-weak")
    }
    if !supporting.value.isEmpty {
        return supporting
    }
    return FieldReading()
}

func extractDenomination(_ lines: [OCRLine], series: String, treatAsCorner: Bool = false) -> String {
    return extractDenominationReading(lines, series: series, treatAsCorner: treatAsCorner).value
}

func upscaledImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let source = CIImage(cgImage: image)
    let lanczos = CIFilter.lanczosScaleTransform()
    lanczos.inputImage = source
    lanczos.scale = Float(scale)
    lanczos.aspectRatio = 1
    guard let scaled = lanczos.outputImage else { return nil }
    let contrast = CIFilter.colorControls()
    contrast.inputImage = scaled
    contrast.contrast = 1.45
    contrast.saturation = 0
    contrast.brightness = 0.03
    let sharpen = CIFilter.sharpenLuminance()
    sharpen.inputImage = contrast.outputImage
    sharpen.sharpness = 0.45
    guard let final = sharpen.outputImage else { return ciContext.createCGImage(scaled, from: scaled.extent) }
    return ciContext.createCGImage(final, from: final.extent)
}

func cornerCrops(_ image: CGImage) -> [CGImage] {
    let w = image.width, h = image.height
    let cw = max(80, Int(Double(w) * 0.32))
    let ch = max(80, Int(Double(h) * 0.38))
    let rects = [
        CGRect(x: 0, y: 0, width: cw, height: ch),
        CGRect(x: w - cw, y: 0, width: cw, height: ch),
        CGRect(x: 0, y: h - ch, width: cw, height: ch),
        CGRect(x: w - cw, y: h - ch, width: cw, height: ch)
    ]
    return rects.compactMap { image.cropping(to: $0) }
}

func centerBandCrop(_ image: CGImage) -> CGImage? {
    let w = image.width, h = image.height
    let rect = CGRect(
        x: Int(Double(w) * 0.06),
        y: Int(Double(h) * 0.25),
        width: Int(Double(w) * 0.88),
        height: Int(Double(h) * 0.50)
    )
    return image.cropping(to: rect)
}

func denominationVariantLines(_ image: CGImage) -> [OCRLine] {
    var lines: [OCRLine] = []
    if let up = upscaledImage(image, scale: 2.0) {
        lines += textOCR(up, fast: false)
    }
    if let faint = adjustedForFaintPrinting(image), let up = upscaledImage(faint, scale: 2.0) {
        lines += textOCR(up, fast: false)
    }
    if let band = centerBandCrop(image) {
        let source = upscaledImage(band, scale: 2.2) ?? adjustedForFaintPrinting(band) ?? band
        lines += textOCR(source, fast: false)
    }
    for corner in cornerCrops(image) {
        let source = upscaledImage(corner, scale: 2.5) ?? corner
        lines += textOCR(source, fast: false)
    }
    return lines
}

#if BONDSCANNER_OCR_HARNESS
func ocrHarnessMain() {
    _ = NSApplication.shared
    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
        fputs("usage: ocr-harness <image>...\n", stderr)
        exit(2)
    }
    let debug = ProcessInfo.processInfo.environment["BONDSCANNER_DENOM_DEBUG"] == "1"
    for path in args {
        let url = URL(fileURLWithPath: path)
        guard let image = cgImageFromFile(url) else {
            print("FILE \(url.lastPathComponent) unreadable")
            continue
        }
        let focus = ProcessInfo.processInfo.environment["BONDSCANNER_FOCUS_DATE"] == "1"
        let recent: [(month: String, year: String)] = {
            guard let raw = ProcessInfo.processInfo.environment["BONDSCANNER_RECENT_DATES"], !raw.isEmpty else { return [] }
            return raw.split(separator: ",").compactMap { part -> (month: String, year: String)? in
                let bits = part.split(separator: "/").map(String.init)
                guard bits.count == 2 else { return nil }
                return (bits[0], bits[1])
            }
        }()
        let result = scanImage(image, focusIssueDate: focus, recentIssueDates: recent)
        let r = result.record
        // Operator fields (stdout only). Includes serial; omits owner/address.
        print("FILE \(url.lastPathComponent) dims=\(image.width)x\(image.height) series=\(r.series.isEmpty ? "-" : r.series) denom=\(r.denomination.isEmpty ? "-" : r.denomination) issue=\(r.issueMonth.isEmpty && r.issueYear.isEmpty ? "-/-" : "\(r.issueMonth)/\(r.issueYear)") status=\(r.status) notes=\(r.notes) rectified=\(result.rectified) lines=\(result.lineCount) bond_text=\(result.bondTextFound)")
        let conf = r.fieldConfidence ?? [:]
        let src = r.fieldSource ?? [:]
        print("  fields series=\(r.series.isEmpty ? "-" : r.series) serial=\(r.serial.isEmpty ? "-" : r.serial) denom=\(r.denomination.isEmpty ? "-" : r.denomination) issue=\(r.issueMonth.isEmpty && r.issueYear.isEmpty ? "-/-" : "\(r.issueMonth)/\(r.issueYear)") status=\(r.status)")
        print("  confidence serial=\(conf["serial"] ?? "-"):\(src["serial"] ?? "-") series=\(conf["series"] ?? "-"):\(src["series"] ?? "-") denom=\(conf["denomination"] ?? "-"):\(src["denomination"] ?? "-") issue=\(conf["issueDate"] ?? "-"):\(src["issueDate"] ?? "-")")

        if debug {
            let pattern = "\\$\\s*\\d+[.,]?\\d*|\\b(?:TWENTY|SEVENTY|FIFTY|HUNDRED|THOUSAND|DOLLARS?|MATURITY|FACE|VALUE|EIGHTEEN|18[.,]?75|37[.,]?50|56[.,]?25|25|50|75|100|200|500|FIVE)\\b"
            let money = regexMatches(pattern, in: normalizeDenominationText(r.rawOCR))
            print("  denom_tokens=\(money.joined(separator: ","))")
            let variants = denominationVariantLines(image)
            let vblob = normalizeDenominationText(variants.map(\.text).joined(separator: " "))
            let vmoney = regexMatches(pattern, in: vblob)
            let vdenom = extractDenomination(variants, series: r.series, treatAsCorner: true)
            print("  variant_tokens=\(vmoney.joined(separator: ",")) variant_denom=\(vdenom.isEmpty ? "-" : vdenom)")
            let monthBits = "JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|ISSUE|FIRST|FURST|EIRST|DATE|19[0-9]{2}|20[0-9]{2}"
            for rawLine in r.rawOCR.components(separatedBy: "\n") {
                let u = rawLine.uppercased()
                if regexMatches(monthBits, in: u).isEmpty { continue }
                // Only the date-relevant tokens, never a full line (may contain a name).
                let toks = regexMatches(monthBits + "|[0-3]?[0-9]", in: u)
                print("  date_tokens=\(toks.joined(separator: ","))")
            }
            // datingStamp is a structured day+month+year, never an owner name.
            if !r.datingStamp.isEmpty {
                print("  datingStamp=\(r.datingStamp)")
            }

        }
    }
}
#endif


func extractIssueDateReading(_ lines: [OCRLine], series: String) -> FieldReading {
    let upper = lines.map(\.text).joined(separator: "\n").uppercased()
    var dateCandidates: [(String, String, Int)] = []
    let months = "JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?"
    // Month NAME + year. Numeric 1–12 as a month is rejected here (ruler ticks);
    // slash dates like 03/1960 are handled by a stricter pattern below.
    let namePattern = "\\b(\(months))\\s+((?:19|20)[0-9]{2})\\b"
    let slashPattern = "\\b(0?[1-9]|1[0-2])\\s*[-./]\\s*((?:19|20)[0-9]{2})\\b"
    func collect(_ pattern: String, fromLine line: OCRLine, namedMonth: Bool) {
        let text = line.text.uppercased()
        if isRulerLikeText(text) { return }
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            for match in matches {
                guard let r1 = Range(match.range(at: 1), in: text), let r2 = Range(match.range(at: 2), in: text) else { continue }
                let year = String(text[r2])
                guard isPlausibleIssueYear(year, series: series) else { continue }
                let month: String?
                if namedMonth {
                    month = monthFromName(String(text[r1]))
                } else {
                    month = monthNumber(String(text[r1]))
                }
                guard let month = month else { continue }
                var score = 0
                if line.box.midX > 0.55 { score += 3 }
                if line.box.midY > 0.50 { score += 3 }
                if namedMonth { score += 3 }
                if text.contains("ISSUE") || upper.contains("ISSUE") { score += 6 }
                if upper.contains("FIRST DAY") || upper.contains("FURST DAY") || upper.contains("EIRST DAY") { score += 5 }
                if text.contains("DATING") || text.contains("STAMP") { score -= 5 }
                if isDateLikeText(text) && regexMatches("\\b[0-3]?[0-9]\\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)", in: text).isEmpty == false {
                    score -= 6
                }
                dateCandidates.append((month, year, score))
            }
        }
    }
    for line in lines {
        collect(namePattern, fromLine: line, namedMonth: true)
        collect(slashPattern, fromLine: line, namedMonth: false)
    }
    for a in lines {
        if isRulerLikeText(a.text) { continue }
        guard let month = monthFromName(a.text) else { continue }
        for b in lines {
            if isRulerLikeText(b.text) { continue }
            let year = cleanAlnum(b.text)
            if !isPlausibleIssueYear(year, series: series) { continue }
            let dx = abs(b.box.midX - a.box.midX), dy = abs(b.box.midY - a.box.midY)
            if (dy < 0.18 && dx < 0.40) || (dx < 0.18 && dy < 0.18) {
                var score = (a.box.midX > 0.55 ? 3 : 0) + (a.box.midY > 0.50 ? 3 : 0) + 3
                if upper.contains("ISSUE") { score += 6 }
                if upper.contains("FIRST DAY") || upper.contains("FURST DAY") || upper.contains("EIRST DAY") { score += 5 }
                dateCandidates.append((month, year, score))
            }
        }
    }
    // Full-blob fallback: "FEB 1966" anywhere in this crop's text with issue context.
    if dateCandidates.isEmpty || dateCandidates.allSatisfy({ $0.2 < 5 }) {
        if let re = try? NSRegularExpression(pattern: namePattern, options: [.caseInsensitive]) {
            let matches = re.matches(in: upper, range: NSRange(upper.startIndex..<upper.endIndex, in: upper))
            for match in matches {
                guard let r1 = Range(match.range(at: 1), in: upper), let r2 = Range(match.range(at: 2), in: upper),
                      let month = monthFromName(String(upper[r1])) else { continue }
                let year = String(upper[r2])
                guard isPlausibleIssueYear(year, series: series) else { continue }
                var score = 3
                if upper.contains("ISSUE") { score += 6 }
                if upper.contains("FIRST DAY") || upper.contains("FURST DAY") || upper.contains("EIRST DAY") { score += 5 }
                dateCandidates.append((month, year, score))
            }
        }
    }
    guard let best = dateCandidates.max(by: { $0.2 < $1.2 }) else { return FieldReading() }
    let conf = best.2 >= 5 ? "high" : "uncertain"
    let src = best.2 >= 5 ? "issue-label" : "date-weak"
    return FieldReading(value: "\(best.0)/\(best.1)", confidence: conf, source: src)
}

func issueDateCrops(_ image: CGImage, intensive: Bool = false) -> [CGImage] {
    let w = image.width, h = image.height
    // Issue date sits in the upper-right, ABOVE the issuing-agent / dating stamp.
    // Keep these tight so a stamp "12 AUG 1966" is not mixed into the issue year.
    var regions = [
        CGRect(x: Int(Double(w) * 0.55), y: 0, width: max(Int(Double(w) * 0.45), 1), height: max(Int(Double(h) * 0.40), 1)),
        CGRect(x: Int(Double(w) * 0.50), y: 0, width: max(Int(Double(w) * 0.50), 1), height: max(Int(Double(h) * 0.36), 1)),
        CGRect(x: Int(Double(w) * 0.58), y: Int(Double(h) * 0.04), width: max(Int(Double(w) * 0.40), 1), height: max(Int(Double(h) * 0.38), 1))
    ]
    if intensive {
        regions.append(CGRect(x: Int(Double(w) * 0.48), y: 0, width: max(Int(Double(w) * 0.52), 1), height: max(Int(Double(h) * 0.48), 1)))
        regions.append(CGRect(x: Int(Double(w) * 0.62), y: 0, width: max(Int(Double(w) * 0.36), 1), height: max(Int(Double(h) * 0.44), 1)))
    }
    var crops: [CGImage] = []
    for r in regions {
        guard r.width > 80, r.height > 50, let crop = image.cropping(to: r) else { continue }
        crops.append(crop)
    }
    return crops
}

func stampRegionCrops(_ image: CGImage) -> [CGImage] {
    let w = image.width, h = image.height
    // Dating stamp is typically below the issue-date line, still on the right.
    let regions = [
        CGRect(x: Int(Double(w) * 0.40), y: Int(Double(h) * 0.22), width: max(Int(Double(w) * 0.58), 1), height: max(Int(Double(h) * 0.50), 1)),
        CGRect(x: Int(Double(w) * 0.35), y: Int(Double(h) * 0.30), width: max(Int(Double(w) * 0.62), 1), height: max(Int(Double(h) * 0.50), 1))
    ]
    var crops: [CGImage] = []
    for r in regions {
        guard r.width > 80, r.height > 50, let crop = image.cropping(to: r) else { continue }
        crops.append(upscaledImage(crop, scale: 2.0) ?? crop)
    }
    return crops
}

func visionBoxToCG(_ box: CGRect, image: CGImage) -> CGRect {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    return CGRect(x: box.minX * w, y: (1 - box.maxY) * h,
                  width: box.width * w, height: box.height * h)
}

func isIssueDateAnchorText(_ text: String) -> Bool {
    let t = text.uppercased()
    return (t.contains("ISSUE") && t.contains("DATE"))
        || t.contains("FIRST DAY") || t.contains("FURST DAY") || t.contains("EIRST DAY")
        || t.contains("FFIRST")
}

/// Tight crops around the printed "ISSUE DATE" / "FIRST DAY OF" label, extending
/// just far enough down to catch the typed month and year — works on a full
/// unrectified frame where a fixed top-40% crop would miss the date.
func issueDateAnchoredCrops(_ image: CGImage, lines: [OCRLine]) -> [CGImage] {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var rects: [CGRect] = []
    for line in lines {
        guard isIssueDateAnchorText(line.text) else { continue }
        // The printed ISSUE DATE box is on the right half of the bond.
        if line.box.midX < 0.35 { continue }
        let box = visionBoxToCG(line.box, image: image)
        let x = max(0, box.minX - 0.10 * w)
        let maxX = min(w, box.maxX + 0.14 * w)
        let top = max(0, box.minY - 0.03 * h)
        // Typed JUL/SEP 1966 sits immediately below "WHICH IS THE FIRST DAY OF".
        // Stay short of the dating stamp further down (below the issuing agent).
        let height = min(h - top, max(0.18 * h, box.height * 8))
        let r = CGRect(x: x, y: top, width: maxX - x, height: height)
        if r.width > 60, r.height > 36 { rects.append(r) }
    }
    var crops: [CGImage] = []
    var seen: [CGRect] = []
    for r in rects {
        if seen.contains(where: { abs($0.midX - r.midX) < 10 && abs($0.midY - r.midY) < 10 }) { continue }
        seen.append(r)
        let ir = CGRect(x: Int(r.origin.x), y: Int(r.origin.y), width: Int(r.width), height: Int(r.height))
        if let crop = image.cropping(to: ir) { crops.append(crop) }
    }
    return crops
}

/// Dating-stamp crops anchored below the ISSUE DATE label (right side, mid bond).
func stampAnchoredCrops(_ image: CGImage, lines: [OCRLine]) -> [CGImage] {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var rects: [CGRect] = []
    for line in lines {
        guard isIssueDateAnchorText(line.text) else { continue }
        if line.box.midX < 0.35 { continue }
        let box = visionBoxToCG(line.box, image: image)
        let x = max(0, box.minX - 0.16 * w)
        let maxX = min(w, box.maxX + 0.16 * w)
        // Start below the typed issue date, cover the agent stamp area.
        let top = min(h - 40, box.minY + max(0.10 * h, box.height * 4))
        let height = min(h - top, 0.38 * h)
        let r = CGRect(x: x, y: top, width: maxX - x, height: height)
        if r.width > 60, r.height > 36 { rects.append(r) }
    }
    var crops: [CGImage] = []
    for r in rects {
        let ir = CGRect(x: Int(r.origin.x), y: Int(r.origin.y), width: Int(r.width), height: Int(r.height))
        if let crop = image.cropping(to: ir) {
            crops.append(upscaledImage(crop, scale: 2.0) ?? crop)
        }
    }
    return crops
}

func highContrastImage(_ image: CGImage, contrast: Float, brightness: Float = 0) -> CGImage? {
    let controls = CIFilter.colorControls()
    controls.inputImage = CIImage(cgImage: image)
    controls.contrast = contrast
    controls.brightness = brightness
    controls.saturation = 0
    guard let out = controls.outputImage else { return nil }
    return ciContext.createCGImage(out, from: out.extent)
}

func dateBoxVariants(_ crop: CGImage, intensive: Bool) -> [(String, CGImage)] {
    var out: [(String, CGImage)] = [("raw", crop)]
    if let up2 = upscaledImage(crop, scale: 2.2) { out.append(("up2", up2)) }
    if let up3 = upscaledImage(crop, scale: 3.0) { out.append(("up3", up3)) }
    if let faint = adjustedForFaintPrinting(crop) {
        out.append(("faint", faint))
        if let fu = upscaledImage(faint, scale: 2.6) { out.append(("faint-up", fu)) }
    }
    if let hi = highContrastImage(crop, contrast: 1.7, brightness: 0.05) {
        out.append(("hi", hi))
        if let hu = upscaledImage(hi, scale: 2.5) { out.append(("hi-up", hu)) }
    }
    if intensive {
        if let up4 = upscaledImage(crop, scale: 3.6) { out.append(("up4", up4)) }
        if let darker = highContrastImage(crop, contrast: 2.0, brightness: -0.08),
           let du = upscaledImage(darker, scale: 3.0) {
            out.append(("dark-up", du))
        }
    }
    return out
}

func yearMonthIndex(_ month: String, _ year: String) -> Int? {
    guard let y = Int(year), let m = Int(month), (1...12).contains(m), isPlausibleIssueYear(year, series: "") || (1941...2026).contains(y) else { return nil }
    return y * 12 + (m - 1)
}

func monthsBetweenIssue(_ monthA: String, _ yearA: String, _ monthB: String, _ yearB: String) -> Int? {
    guard let a = yearMonthIndex(monthA, yearA), let b = yearMonthIndex(monthB, yearB) else { return nil }
    return b - a
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

func extractDatingStamp(_ lines: [OCRLine], series: String) -> DatingStampReading? {
    let months = "JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?"
    // Day + month name + year, allowing punctuation and O/I/l OCR slips in digits.
    let pattern = "(?:^|[^A-Z0-9])([0-3IlLO]?[0-9IlLO])[\\.\\-]?\\s+(\(months))\\.?\\s+((?:19|20)[0-9O]{2})(?:[^0-9]|$)"

    func stampYear(_ raw: String) -> String? {
        let y = raw.uppercased().replacingOccurrences(of: "O", with: "0")
        guard isPlausibleIssueYear(y, series: series) || isPlausibleIssueYear(y, series: "") else { return nil }
        return y
    }
    func stampDay(_ raw: String) -> Int? {
        var t = raw.uppercased()
        t = t.replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
        guard let day = Int(t), (1...31).contains(day) else { return nil }
        return day
    }
    func isIssueLabel(_ text: String) -> Bool {
        let t = text.uppercased()
        return t.contains("ISSUE") || t.contains("FIRST DAY") || t.contains("FURST DAY")
            || t.contains("EIRST DAY") || t.contains("FFIRST")
    }
    func isSerialLike(_ text: String) -> Bool {
        return !regexMatches("[A-Z]?[0-9]{8,}E?", in: cleanAlnum(text)).isEmpty
    }

    var hits: [DatingStampReading] = []
    func collect(from text: String, assembled: Bool) {
        if isIssueLabel(text) || isSerialLike(text) { return }
        let u = text.uppercased()
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let ns = NSRange(u.startIndex..<u.endIndex, in: u)
        for match in re.matches(in: u, range: ns) {
            guard let dR = Range(match.range(at: 1), in: u),
                  let mR = Range(match.range(at: 2), in: u),
                  let yR = Range(match.range(at: 3), in: u),
                  let day = stampDay(String(u[dR])),
                  let month = monthFromName(String(u[mR])),
                  let year = stampYear(String(u[yR])) else { continue }
            // High only for a single-line day+month+year. Assembled "1" + issue
            // month + year from "FIRST DAY OF MAR 1960" is not a dating stamp.
            let conf: String
            if assembled {
                conf = "uncertain"
            } else {
                conf = (1941...2026).contains(Int(year) ?? 0) ? "high" : "uncertain"
            }
            hits.append(DatingStampReading(day: day, month: month, year: year, confidence: conf,
                                           raw: "\(day) \(monthAbbrev(month)) \(year)"))
        }
    }

    for line in lines {
        collect(from: line.text, assembled: false)
    }
    // Join only nearby, non-serial lines so a split "12" / "AUG" / "1966" can match
    // without swallowing the serial number or the $25 corner. These are uncertain.
    for (i, a) in lines.enumerated() {
        if isIssueLabel(a.text) || isSerialLike(a.text) { continue }
        var group = a.text.uppercased()
        for (j, b) in lines.enumerated() where j != i {
            if isIssueLabel(b.text) || isSerialLike(b.text) { continue }
            let dx = abs(b.box.midX - a.box.midX), dy = abs(b.box.midY - a.box.midY)
            if dy < 0.10 && dx < 0.28 {
                group += " " + b.text.uppercased()
            }
        }
        collect(from: group, assembled: true)
    }

    return hits.first(where: { $0.confidence == "high" }) ?? hits.first
}

func allIssueDateCandidates(_ lines: [OCRLine], series: String) -> [(month: String, year: String, score: Int)] {
    // Reuse the deterministic collector by calling extract logic's candidates.
    // Duplicated collection so we can inspect every variant, not just the winner.
    var dateCandidates: [(String, String, Int)] = []
    let upper = lines.map(\.text).joined(separator: "\n").uppercased()
    let months = "JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:TEMBER)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?"
    let namePattern = "\\b(\(months))\\s+((?:19|20)[0-9]{2})\\b"
    let slashPattern = "\\b(0?[1-9]|1[0-2])\\s*[-./]\\s*((?:19|20)[0-9]{2})\\b"
    func collect(_ pattern: String, fromLine line: OCRLine, namedMonth: Bool) {
        let text = line.text.uppercased()
        if isRulerLikeText(text) { return }
        if text.contains("DATING") { return }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in re.matches(in: text, range: ns) {
            guard let r1 = Range(match.range(at: 1), in: text), let r2 = Range(match.range(at: 2), in: text) else { continue }
            let year = String(text[r2])
            guard isPlausibleIssueYear(year, series: series) else { continue }
            let month = namedMonth ? monthFromName(String(text[r1])) : monthNumber(String(text[r1]))
            guard let month = month else { continue }
            var score = namedMonth ? 3 : 1
            if line.box.midX > 0.50 { score += 2 }
            if text.contains("ISSUE") || upper.contains("ISSUE") { score += 6 }
            if upper.contains("FIRST DAY") || upper.contains("FURST DAY") || upper.contains("EIRST DAY") { score += 5 }
            if isDateLikeText(text) && regexMatches("\\b[0-3]?[0-9]\\s+(?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)", in: text).isEmpty == false {
                score -= 6
            }
            dateCandidates.append((month, year, score))
        }
    }
    for line in lines {
        collect(namePattern, fromLine: line, namedMonth: true)
        collect(slashPattern, fromLine: line, namedMonth: false)
    }
    for a in lines {
        if isRulerLikeText(a.text) { continue }
        guard let month = monthFromName(a.text) else { continue }
        for b in lines {
            if isRulerLikeText(b.text) { continue }
            var year = cleanAlnum(b.text)
            // "196O" (letter O) — only fold O to 0 in a 4-digit year token.
            if year.count == 4 { year = year.replacingOccurrences(of: "O", with: "0") }
            if !isPlausibleIssueYear(year, series: series) { continue }
            let dx = abs(b.box.midX - a.box.midX), dy = abs(b.box.midY - a.box.midY)
            if (dy < 0.22 && dx < 0.45) || (dx < 0.22 && dy < 0.22) {
                var score = 3
                if upper.contains("ISSUE") { score += 6 }
                if upper.contains("FIRST DAY") || upper.contains("FURST DAY") || upper.contains("EIRST DAY") { score += 5 }
                dateCandidates.append((month, year, score))
            }
        }
    }
    if let re = try? NSRegularExpression(pattern: namePattern, options: [.caseInsensitive]) {
        let ns = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        for match in re.matches(in: upper, range: ns) {
            guard let r1 = Range(match.range(at: 1), in: upper), let r2 = Range(match.range(at: 2), in: upper),
                  let month = monthFromName(String(upper[r1])) else { continue }
            let year = String(upper[r2])
            guard isPlausibleIssueYear(year, series: series) else { continue }
            var score = 3
            if upper.contains("ISSUE") { score += 6 }
            if upper.contains("FIRST DAY") || upper.contains("FURST DAY") || upper.contains("EIRST DAY") { score += 5 }
            dateCandidates.append((month, year, score))
        }
    }
    return dateCandidates
}

/// Confusable year-ending digits (6 reads as 0, 8 as 0 or 3, 5 as 6, etc.).
let ambiguousYearDigits: Set<Character> = ["0", "3", "5", "6", "8", "9"]

func yearLastDigitAmbiguous(_ year: String) -> Bool {
    guard let last = year.last else { return false }
    return ambiguousYearDigits.contains(last)
}

func stampConsistent(month: String, year: String, stamp: DatingStampReading) -> Bool {
    guard issueOnOrBeforeStamp(month: month, year: year, stamp: stamp) else { return false }
    guard let gap = monthsBetweenIssue(month, year, stamp.month, stamp.year) else { return false }
    return (0...6).contains(gap)
}

func issueOnOrBeforeStamp(month: String, year: String, stamp: DatingStampReading) -> Bool {
    guard let i = yearMonthIndex(month, year), let s = yearMonthIndex(stamp.month, stamp.year) else { return false }
    return i <= s
}

func fitsRecentSequence(month: String, year: String, recent: [(month: String, year: String)]) -> Bool {
    guard !recent.isEmpty else { return true }
    let indexes = recent.compactMap { yearMonthIndex($0.month, $0.year) }
    guard let earliest = indexes.min(), let latest = indexes.max(),
          let issue = yearMonthIndex(month, year) else { return true }
    // Earlier than the previous few by more than 2 months, or more than ~1 year ahead.
    if issue < earliest - 2 { return false }
    if issue > latest + 12 { return false }
    return true
}

func recentScanIssueDates(before capturedAt: String, among records: [BondRecord], window: Int = 3) -> [(month: String, year: String)] {
    // Last few scans in capture-time order only — not the whole ledger and not
    // serial-number neighbours. An earlier out-of-sequence test bond drops out
    // of this window once more recent scans have been taken.
    return records
        .filter { $0.capturedAt < capturedAt && !$0.issueMonth.isEmpty && !$0.issueYear.isEmpty }
        .sorted { $0.capturedAt > $1.capturedAt }
        .prefix(window)
        .map { ($0.issueMonth, $0.issueYear) }
}

/// Sequence flag: REVIEW with a note, never rewrite the date.
/// The first dated scan of a session has no history and is not flagged.
func sequenceInconsistencyNote(month: String, year: String, recent: [(month: String, year: String)], unambiguous: Bool) -> String? {
    guard !recent.isEmpty else { return nil }
    let indexes = recent.compactMap { yearMonthIndex($0.month, $0.year) }
    guard let earliest = indexes.min(), let latest = indexes.max(),
          let issue = yearMonthIndex(month, year) else { return nil }
    if issue < earliest - 2 {
        // Going backward in a chronological session is always suspicious.
        // A confusable last digit (0/6) is never "unambiguous" enough to override this.
        return "Issue date is more than 2 months earlier than the previous few scans."
    }
    if issue > latest + 12 {
        // A clear unanimous reading (e.g. 1966 after a 1960 test bond) is allowed.
        if unambiguous { return nil }
        return "Issue date jumps more than a year ahead of the previous few scans."
    }
    return nil
}

func resolveIssueDate(
    candidates: [(month: String, year: String, source: String)],
    stamp: DatingStampReading?,
    series: String,
    recent: [(month: String, year: String)]
) -> FieldReading {
    guard !candidates.isEmpty else { return FieldReading() }
    let months = Dictionary(grouping: candidates, by: { $0.month })
    let years = Dictionary(grouping: candidates, by: { $0.year })
    // Aggressive contrast/upscale filters can fabricate a 0/6. A dissenting
    // year counts for agreement only if a non-aggressive variant produced it
    // (or several distinct aggressive sources did).
    func isAggressiveSource(_ source: String) -> Bool {
        let s = source.lowercased()
        return s.contains("hi-up") || s.contains("dark-up")
    }
    func yearIsCredible(_ year: String) -> Bool {
        // "paired" is a cross-variant assembly, not an independent reading.
        // Duplicate collector hits from the same source label count as one.
        let hits = candidates.filter { $0.year == year && $0.source != "paired" && !isAggressiveSource($0.source) }
        return Set(hits.map(\.source)).count >= 2
    }
    let allYears = Set(candidates.map(\.year))
    let credibleYears = Set(allYears.filter(yearIsCredible))
    let uniqueYears = credibleYears.isEmpty ? allYears : credibleYears
    let uniqueMonths = Set(candidates.map(\.month))
    let agreedYear = uniqueYears.count == 1 ? uniqueYears.first : nil
    let agreedMonth = uniqueMonths.count == 1 ? uniqueMonths.first : (months.max(by: { $0.value.count < $1.value.count })?.key)
    let yearCounts = years.mapValues(\.count)
    let chosenSourceCount = agreedYear.map { year in Set(candidates.filter { $0.year == year }.map(\.source)).count } ?? 0
    let unanimousYear = agreedYear != nil && chosenSourceCount >= 2 && (yearCounts[agreedYear ?? ""] ?? 0) >= 2
    let disagreed = uniqueYears.count > 1
    let ambiguous = disagreed && uniqueYears.contains(where: { yearLastDigitAmbiguous($0) })

    func pick(_ month: String, _ year: String, conf: String, src: String) -> FieldReading {
        return FieldReading(value: "\(month)/\(year)", confidence: conf, source: src)
    }

    // Prefer a candidate that was actually read, fits the dating stamp (0–6 months,
    // on or before the stamp), and/or fits the recent scan sequence. Never invent a year.
    var preferred: (month: String, year: String, source: String)?
    if let stamp = stamp, stamp.confidence == "high" {
        let consistent = candidates.filter { stampConsistent(month: $0.month, year: $0.year, stamp: stamp) }
        let consistentYears = Set(consistent.map(\.year))
        if consistentYears.count == 1, let c = consistent.first {
            preferred = c
        } else if let stampFit = consistent.max(by: { yearCounts[$0.year, default: 0] < yearCounts[$1.year, default: 0] }),
                  years[stampFit.year] != nil {
            preferred = stampFit
        }
    }
    if preferred == nil, !recent.isEmpty, uniqueYears.count > 1 {
        let fitting = candidates.filter { fitsRecentSequence(month: $0.month, year: $0.year, recent: recent) }
        let fittingYears = Set(fitting.map(\.year))
        // Only one candidate year fits the sequence, and an OCR variant actually read it.
        if fittingYears.count == 1, let c = fitting.first {
            preferred = c
        }
    }
    if preferred == nil {
        if let y = agreedYear, let m = agreedMonth {
            preferred = (m, y, "variants")
        } else if let y = yearCounts.max(by: { $0.value < $1.value })?.key,
                  let m = agreedMonth ?? candidates.first(where: { $0.year == y })?.month {
            preferred = (m, y, "variants-majority")
        } else if let c = candidates.max(by: { a, b in
            if yearCounts[a.year, default: 0] != yearCounts[b.year, default: 0] {
                return yearCounts[a.year, default: 0] < yearCounts[b.year, default: 0]
            }
            return a.source.count < b.source.count
        }) {
            preferred = c
        }
    }
    guard let chosen = preferred, !chosen.month.isEmpty, !chosen.year.isEmpty else {
        return FieldReading()
    }

    // High only when variants agree on the year (several readings, no disagreement).
    var conf = "uncertain"
    var src = chosen.source
    if unanimousYear && !disagreed && chosen.year == agreedYear, let m = agreedMonth {
        conf = "high"
        src = "variants-agree"
        if let stamp = stamp, stamp.confidence == "high" {
            if stampConsistent(month: m, year: chosen.year, stamp: stamp) {
                src = "variants+stamp"
            } else {
                // Agreed year conflicts with a clear stamp and no consistent variant.
                conf = "uncertain"
                src = "stamp-conflict"
            }
        }
    }
    // Stamp or sequence selected a year a variant actually read.
    if let stamp = stamp, stamp.confidence == "high",
       stampConsistent(month: chosen.month, year: chosen.year, stamp: stamp),
       candidates.contains(where: { $0.year == chosen.year && $0.month == chosen.month || $0.year == chosen.year }) {
        if !disagreed && unanimousYear {
            conf = "high"
            src = "variants+stamp"
        } else if disagreed {
            // Stamp selected a year a variant actually read, but years still
            // disagree: prefer that year, never high. Agreement is required for green.
            conf = "uncertain"
            src = "stamp-preferred-variant"
        }
    }
    if ambiguous && conf == "high" && disagreed {
        // Agreement is required for high when 0/6/8-style digits disagree.
        conf = "uncertain"
        src = "year-digit-ambiguous"
    }

        if ProcessInfo.processInfo.environment["BONDSCANNER_DENOM_DEBUG"] == "1" {
        let listed = candidates.map { "\($0.month)/\($0.year)@\($0.source)" }.joined(separator: ",")
        let stampDesc = stamp.map { "\($0.day)/\($0.month)/\($0.year):\($0.confidence)" } ?? "-"
        print("  year_variants=[\(listed)] chosen=\(chosen.month)/\(chosen.year) conf=\(conf) src=\(src) stamp=\(stampDesc)")
    }
    return pick(chosen.month, chosen.year, conf: conf, src: src)
}

func extractIssueDateFromImage(_ image: CGImage, series: String, baseLines: [OCRLine], intensive: Bool, recent: [(month: String, year: String)]) -> (date: FieldReading, stamp: DatingStampReading?) {
    var candidates: [(month: String, year: String, source: String)] = []
    var stampLines: [OCRLine] = baseLines
    for c in allIssueDateCandidates(baseLines, series: series) {
        candidates.append((c.month, c.year, "base"))
    }
    var crops = issueDateCrops(image, intensive: intensive)
    crops += issueDateAnchoredCrops(image, lines: baseLines)
    for (ci, crop) in crops.enumerated() {
        for (label, variant) in dateBoxVariants(crop, intensive: intensive) {
            let lines = textOCR(variant, fast: false, minimumTextHeight: 0.003, alternateCount: 3)
            stampLines += lines
            for c in allIssueDateCandidates(lines, series: series) {
                candidates.append((c.month, c.year, "\(label)-\(ci)"))
            }
        }
    }
    // Dating stamp: default + label-anchored crops, a few enhancements, alternate OCR readings.
    var stampCrops = stampRegionCrops(image)
    stampCrops += stampAnchoredCrops(image, lines: baseLines)
    for crop in stampCrops {
        let variants: [(String, CGImage)] = {
            var v: [(String, CGImage)] = [("raw", crop)]
            if let faint = adjustedForFaintPrinting(crop) { v.append(("faint", faint)) }
            if let hi = highContrastImage(crop, contrast: 1.8, brightness: 0.05) { v.append(("hi", hi)) }
            if intensive, let up = upscaledImage(crop, scale: 2.8) { v.append(("up", up)) }
            return v
        }()
        for (_, variant) in variants {
            stampLines += textOCR(variant, fast: false, minimumTextHeight: 0.003, alternateCount: 3)
        }
    }
    // If a month and a year were each actually read in the date box, pair them.
    // Never invent a digit: both pieces must already appear in OCR. Used so
    // "SEP" in one variant and "1966" in another can form 09/1966 (uncertain).
    var isolatedMonths: [String] = []
    var isolatedYears: [String] = []
    func harvest(_ lines: [OCRLine]) {
        for line in lines {
            if isRulerLikeText(line.text) { continue }
            if let m = monthFromName(line.text) { isolatedMonths.append(m) }
            let u = line.text.uppercased()
            if let re = try? NSRegularExpression(pattern: "\\b((?:19|20)[0-9O]{2})\\b", options: []) {
                let ns = NSRange(u.startIndex..<u.endIndex, in: u)
                for match in re.matches(in: u, range: ns) {
                    guard let r = Range(match.range(at: 1), in: u) else { continue }
                    let y = String(u[r]).replacingOccurrences(of: "O", with: "0")
                    if isPlausibleIssueYear(y, series: series) { isolatedYears.append(y) }
                }
            }
        }
    }
    harvest(baseLines)
    harvest(stampLines)
    let knownMonths = Set(candidates.map(\.month) + isolatedMonths)
    let knownYears = Set(candidates.map(\.year) + isolatedYears)
    for m in knownMonths {
        for y in knownYears {
            if candidates.contains(where: { $0.month == m && $0.year == y }) { continue }
            let monthRead = isolatedMonths.contains(m) || candidates.contains(where: { $0.month == m })
            let yearRead = isolatedYears.contains(y) || candidates.contains(where: { $0.year == y })
            if monthRead && yearRead {
                candidates.append((m, y, "paired"))
            }
        }
    }
    let stamp = extractDatingStamp(stampLines, series: series)
    if ProcessInfo.processInfo.environment["BONDSCANNER_DENOM_DEBUG"] == "1" {
        let monthBits = "JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|ISSUE|FIRST|FURST|EIRST|DATE|19[0-9]{2}|20[0-9]{2}"
        var stampToks: [String] = []
        var seen = Set<String>()
        for line in stampLines {
            let u = line.text.uppercased()
            let toks = regexMatches(monthBits + "|[0-3]?[0-9]", in: u)
            if toks.isEmpty { continue }
            let key = toks.joined(separator: ",")
            if seen.insert(key).inserted { stampToks.append(key) }
        }
        print("  stamp_tokens=[\(stampToks.joined(separator: " | "))]")
    }
    let date = resolveIssueDate(candidates: candidates, stamp: stamp, series: series, recent: recent)
    return (date, stamp)
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

    // Serial: accept only an exact pattern (Series E: 1 letter + 10 digits + E).
    // A letter glued from a neighboring word (e.g. a name ending in S + digits)
    // is leading junk and is kept only when the remainder itself is exact.
    var serialReadings: [(FieldReading, Int)] = []
    for (i, s) in compactLines.enumerated() {
        let reading = validatedSerial(s, series: "")
        guard !reading.value.isEmpty else { continue }
        var score = 0
        if reading.isHigh { score += 8 }
        if reading.value.hasSuffix("EE") { score += 5 }
        else if reading.value.hasSuffix("E") { score += 4 }
        if lines[i].box.midX > 0.52 && lines[i].box.midY < 0.38 { score += 4 }
        if lines[i].confidence > 0.5 { score += 1 }
        serialReadings.append((reading, score))
    }
    // Also try the full compact blob so a serial split across short tokens can match.
    let blobSerial = validatedSerial(compactLines.joined(), series: "")
    if blobSerial.isHigh {
        serialReadings.append((blobSerial, 7))
    }
    if let best = serialReadings.filter({ $0.0.isHigh }).max(by: { $0.1 < $1.1 })
        ?? serialReadings.max(by: { $0.1 < $1.1 }) {
        record.serial = best.0.value
        setFieldReading("serial", best.0, on: &record)
    }

    if upper.contains("SERIES EE") || record.serial.hasSuffix("EE") {
        record.series = "EE"
        setFieldReading("series", FieldReading(value: "EE", confidence: "high",
                                               source: upper.contains("SERIES EE") ? "text" : "serial-suffix"), on: &record)
    } else if upper.contains("SERIES E") || (record.serial.hasSuffix("E") && !record.serial.hasSuffix("EE") && fieldConfidenceIsHigh(record, "serial")) {
        record.series = "E"
        let src = upper.contains("SERIES E") ? "text" : "serial-suffix"
        // "SERIES E" in text is high; suffix alone is high only with a validated serial.
        let conf = (upper.contains("SERIES E") || fieldConfidenceIsHigh(record, "serial")) ? "high" : "uncertain"
        setFieldReading("series", FieldReading(value: "E", confidence: conf, source: src), on: &record)
    } else if upper.contains("SERIES I") || (record.serial.hasSuffix("I") && fieldConfidenceIsHigh(record, "serial")) {
        record.series = "I"
        setFieldReading("series", FieldReading(value: "I", confidence: "high",
                                               source: upper.contains("SERIES I") ? "text" : "serial-suffix"), on: &record)
    }

    let denom = extractDenominationReading(lines, series: record.series)
    record.denomination = denom.value
    setFieldReading("denomination", denom, on: &record)

    let date = extractIssueDateReading(lines, series: record.series)
    if !date.value.isEmpty {
        let parts = date.value.split(separator: "/").map(String.init)
        if parts.count == 2 {
            record.issueMonth = parts[0]
            record.issueYear = parts[1]
            setFieldReading("issueDate", date, on: &record)
        }
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

    applyRequiredStatus(&record)
    return record
}

func rotateCG(_ cg: CGImage, exif: Int) -> CGImage? {
    let image = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(exif))
    return ciContext.createCGImage(image, from: image.extent)
}

func textOCR(_ image: CGImage, fast: Bool, minimumTextHeight: Float = 0.007, alternateCount: Int = 1) -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = fast ? .fast : .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = minimumTextHeight
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    let n = max(1, alternateCount)
    return (request.results ?? []).flatMap { obs -> [OCRLine] in
        return obs.topCandidates(n).map { t in
            OCRLine(text: t.string, confidence: t.confidence, box: obs.boundingBox)
        }
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

/// Pixel-space aspect (longer/shorter) of a Vision rectangle. Normalized
/// bounding boxes are not usable for aspect: they ignore the image's 16:9 shape.
func rectanglePixelGeometry(_ rectangle: VNRectangleObservation, image: CGImage) -> (width: CGFloat, height: CGFloat, aspect: CGFloat, areaFraction: CGFloat) {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    let rw = (dist(pt(rectangle.topLeft), pt(rectangle.topRight)) + dist(pt(rectangle.bottomLeft), pt(rectangle.bottomRight))) / 2
    let rh = (dist(pt(rectangle.topLeft), pt(rectangle.bottomLeft)) + dist(pt(rectangle.topRight), pt(rectangle.bottomRight))) / 2
    let longS = max(rw, rh)
    let shortS = max(min(rw, rh), 1)
    let area = rw * rh
    return (rw, rh, longS / shortS, area / (w * h))
}

/// US Series E/EE paper bonds are about 2.1–2.4:1. A 12-inch ruler is long and
/// thin (often 8:1 or more) and must not win over the bond.
func bondRectangleScore(_ rectangle: VNRectangleObservation, image: CGImage) -> Double {
    let g = rectanglePixelGeometry(rectangle, image: image)
    // Reject ruler-like strips and tiny scraps.
    if g.aspect > 3.6 || g.aspect < 1.45 { return -1 }
    if g.areaFraction < 0.08 || g.areaFraction > 0.92 { return -1 }
    if g.width < 400 || g.height < 160 { return -1 }
    var score = Double(rectangle.confidence) * 4
    let aspectError = abs(g.aspect - 2.25)
    if g.aspect >= 2.05 && g.aspect <= 2.50 { score += 14 - aspectError * 10 }
    else if g.aspect >= 1.80 && g.aspect <= 2.85 { score += 7 - aspectError * 4 }
    else { score += 1 }
    if g.areaFraction >= 0.12 && g.areaFraction <= 0.72 { score += 5 }
    score += min(Double(g.areaFraction), 0.6) * 3
    return score
}

// Read broad potential outlines (front/back, rotated, different denominations).
// Prefer a bond-shaped rectangle (~2.1–2.4:1) over a long thin ruler.
func rectangleCandidates(_ image: CGImage) -> [VNRectangleObservation] {
    let request = VNDetectRectanglesRequest()
    // Detection is slightly broader than the bond window so perspective-skewed
    // bonds still appear; bondRectangleScore then drops rulers.
    request.minimumAspectRatio = 0.22
    request.maximumAspectRatio = 0.90
    request.minimumSize = 0.12
    request.minimumConfidence = 0.18
    request.quadratureTolerance = 43
    request.maximumObservations = 12
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
    catch { ScanLog.shared.write("rectangle detection exception; falling back to text"); return [] }
    let scored = (request.results ?? []).map { ($0, bondRectangleScore($0, image: image)) }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
    if !scored.isEmpty {
        let g = rectanglePixelGeometry(scored[0].0, image: image)
        ScanLog.shared.write("bond rectangle picked aspect=\(String(format: "%.2f", g.aspect)) area=\(String(format: "%.2f", g.areaFraction)) score=\(String(format: "%.1f", scored[0].1)) of \(scored.count)")
    }
    return scored.map { $0.0 }
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

func fallbackBondCrop(_ image: CGImage) -> CGImage? {
    // Inset the frame so a ruler laid along a table edge is usually excluded
    // when rectangle detection finds nothing.
    let center = CGRect(x: Int(Double(image.width) * 0.07),
                        y: Int(Double(image.height) * 0.10),
                        width: Int(Double(image.width) * 0.86),
                        height: Int(Double(image.height) * 0.80))
    return image.cropping(to: center)
}

func scanImage(_ image: CGImage, focusIssueDate: Bool = false, recentIssueDates: [(month: String, year: String)] = []) -> OCRResult {
    // Field extraction uses ONLY text inside a bond-shaped crop (or the
    // inset fallback). The full frame is kept out so ruler tick numbers
    // (1…12) and other table text cannot become a denomination or date.
    var candidates: [(image: CGImage, rectified: Bool, label: String)] = []
    let rectangles = rectangleCandidates(image)
    for (index, rectangle) in rectangles.prefix(3).enumerated() {
        if let corrected = rectify(image, using: rectangle) {
            candidates.append((corrected, true, "rect\(index + 1)"))
        }
    }
    if let cropped = fallbackBondCrop(image) {
        candidates.append((cropped, false, "center"))
    }
    if candidates.isEmpty {
        candidates.append((image, false, "full"))
        ScanLog.shared.write("no bond crop available; using full frame")
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
    var result = parseDeterministically(finalLines)
    func considerDenom(_ reading: FieldReading, label: String) {
        guard !reading.value.isEmpty else { return }
        let currentHigh = fieldConfidenceIsHigh(result, "denomination")
        if currentHigh { return }
        let currentValue = result.denomination
        // Prefer a high-confidence reading over an uncertain one; do not
        // overwrite a value with a weaker disagreeing guess.
        if reading.isHigh || currentValue.isEmpty || (reading.value == currentValue) {
            result.denomination = reading.value
            setFieldReading("denomination", reading, on: &result)
            bestLabel += label
        }
    }
    if !fieldConfidenceIsHigh(result, "denomination") {
        var variantLines = finalLines
        variantLines += denominationVariantLines(selectedImage)
        considerDenom(extractDenominationReading(variantLines, series: result.series), label: "/denom-variant")
        if !fieldConfidenceIsHigh(result, "denomination") {
            var cornerLines: [OCRLine] = []
            for corner in cornerCrops(selectedImage) {
                let source = upscaledImage(corner, scale: 2.5) ?? corner
                cornerLines += textOCR(source, fast: false)
            }
            considerDenom(extractDenominationReading(cornerLines, series: result.series, treatAsCorner: true), label: "/denom-corner")
        }
        if !fieldConfidenceIsHigh(result, "denomination") {
            candidateLoop: for candidate in candidates where candidate.rectified || candidate.label == "center" {
                for orientation in [1, 3, 6, 8] {
                    guard let rotated = rotateCG(candidate.image, exif: orientation) else { continue }
                    var extra = textOCR(rotated, fast: false)
                    extra += denominationVariantLines(rotated)
                    let reading = extractDenominationReading(extra, series: result.series)
                    if reading.isHigh || (result.denomination.isEmpty && !reading.value.isEmpty) {
                        considerDenom(reading, label: "/denom-\(candidate.label)")
                        if reading.isHigh { break candidateLoop }
                    }
                }
            }
        }
    }
    // Issue date: several upscaled/contrast variants of the upper-right date
    // box, plus a dating-stamp cross-check. Agreement is required for high
    // confidence, especially when the year's last digit is a 0/6/8-style shape.
    let extracted = extractIssueDateFromImage(selectedImage, series: result.series,
                                              baseLines: finalLines,
                                              intensive: focusIssueDate,
                                              recent: recentIssueDates)
    if let stamp = extracted.stamp, stamp.confidence == "high" {
        result.datingStamp = stamp.raw
    }
    let date = extracted.date
    if !date.value.isEmpty {
        // Variant-aware resolver is authoritative: a single-pass "high" from
        // parseDeterministically must not stick when years disagree.
        let parts = date.value.split(separator: "/").map(String.init)
        if parts.count == 2 {
            result.issueMonth = parts[0]
            result.issueYear = parts[1]
            setFieldReading("issueDate", date, on: &result)
            bestLabel += "/issue-date"
        }
    }
    applyRequiredStatus(&result)
    if let note = sequenceInconsistencyNote(month: result.issueMonth, year: result.issueYear,
                                            recent: recentIssueDates,
                                            unambiguous: fieldConfidenceIsHigh(result, "issueDate")
                                                && (result.fieldSource?["issueDate"] ?? "").contains("agree")) {
        result.status = "REVIEW"
        if result.notes.isEmpty {
            result.notes = note
        } else if !result.notes.contains(note) {
            result.notes = result.notes + " " + note
        }
    }
    let recognized = bondTextSignal(finalLines) || bondTextSignal(textOCR(bestImage, fast: true))
    ScanLog.shared.write("scan candidates=\(candidates.count) best=\(bestLabel) hunt_score=\(bestScore) final_score=\(finalScore) ocr_lines=\(finalLines.count) rectified=\(bestRectified) bond_text=\(recognized) fields_complete=\(requiredFieldsComplete(result)) denom=\(result.denomination.isEmpty ? "none" : "set")")
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
        // AI-filled required fields stay uncertain (REVIEW) unless the deterministic
        // parser already marked them high.
        if !fieldConfidenceIsHigh(next, "serial") {
            let s = cleanAlnum(grounded("serial"))
            let reading = validatedSerial(s, series: next.series)
            if reading.isHigh && (next.serial.isEmpty || !fieldConfidenceIsHigh(next, "serial")) {
                next.serial = reading.value
                setFieldReading("serial", reading, on: &next)
            }
        }
        if next.series.isEmpty {
            let s = (obj["series"] ?? "").uppercased()
            if validSeriesValues().contains(s), next.rawOCR.uppercased().contains("SERIES") {
                next.series = s
                setFieldReading("series", FieldReading(value: s, confidence: "high", source: "text"), on: &next)
            }
        }
        if !fieldConfidenceIsHigh(next, "denomination") && next.denomination.isEmpty {
            let d = cleanAlnum(grounded("denomination"))
            if validFaceValues(for: next.series).contains(d) {
                next.denomination = d
                setFieldReading("denomination", FieldReading(value: d, confidence: "uncertain", source: "ai"), on: &next)
            }
        }
        if !fieldConfidenceIsHigh(next, "issueDate") && (next.issueMonth.isEmpty || next.issueYear.isEmpty) {
            let mo = (obj["issue_month"] ?? "")
            let yr = (obj["issue_year"] ?? "")
            if let month = monthNumber(mo), regexMatches("^(?:19|20)[0-9]{2}$", in: yr).count == 1,
                raw.contains(cleanAlnum(mo) + yr) {
                next.issueMonth = month; next.issueYear = yr
                setFieldReading("issueDate", FieldReading(value: "\(month)/\(yr)", confidence: "uncertain", source: "ai"), on: &next)
            }
        }
        applyRequiredStatus(&next)
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
    // MJPEG (compressed) can carry 2K over USB 2.0. Uncompressed 420v above
    // 1920x1080 is past this camera's USB 2.0 ceiling (~480 Mbps), so prefer
    // 1080p 420v when MJPEG is not advertised.
    let uncompressedCap = 1920 * 1080
    func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int, Int) {
        let d = formatDimensions(format)
        let pixels = Int(d.width) * Int(d.height)
        let mjpeg = formatIsMJPEG(format) ? 1 : 0
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased()
        let four20 = (sub == "420v" || sub == "420f") ? 1 : 0
        let effective: Int
        if mjpeg == 1 {
            effective = pixels
        } else if pixels > uncompressedCap {
            effective = 0
        } else {
            effective = pixels
        }
        return (mjpeg, effective, four20, pixels)
    }
    return usable.max { a, b in
        let sa = score(a), sb = score(b)
        if sa.0 != sb.0 { return sa.0 < sb.0 }
        if sa.1 != sb.1 { return sa.1 < sb.1 }
        if sa.2 != sb.2 { return sa.2 < sb.2 }
        return sa.3 < sb.3
    }
}

func select1080FallbackFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
    let matches = formats.filter { format in
        let d = formatDimensions(format)
        return d.width == 1920 && d.height == 1080
    }
    return matches.first(where: { format in
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription)).lowercased()
        return sub == "420v" || sub == "420f"
    }) ?? matches.first
}

func photoDimension(_ dims: CMVideoDimensions, isIn supported: [CMVideoDimensions]) -> Bool {
    return supported.contains { $0.width == dims.width && $0.height == dims.height }
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
    private var resolutionSettled = false
    private var didReassertFormat = false
    private var didTryHigherFormat = false
    private var latestImage: CGImage?
    private var records: [BondRecord] = []
    private var isProcessing = false
    private var automatic = true
    private var lockedAfterCapture = false
    private var autoFillRecordId: String?
    private var autoFillAttempts = 0
    private let autoFillMaxAttempts = 4
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

    @discardableResult
    private func bondScanTry(_ description: String, _ work: @escaping () -> Void) -> Bool {
        var error: NSError?
        let ok = BondScanTry(work, &error)
        if !ok {
            let detail = error?.localizedDescription ?? "Objective-C exception"
            ScanLog.shared.write("\(description) failed: \(detail); will fall back rather than abort")
        }
        return ok
    }

    /// Apply a device format inside the caller's beginConfiguration/commitConfiguration.
    /// Reads back the actual activeFormat afterward. Never sets photo dimensions
    /// that are not in the CURRENT activeFormat.supportedMaxPhotoDimensions.
    /// Objective-C exceptions are caught so the process cannot abort.
    @discardableResult
    private func applyDeviceFormat(_ format: AVCaptureDevice.Format, on camera: AVCaptureDevice, reason: String) -> Bool {
        let dims = formatDimensions(format)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let desired = desiredFPSForFormatDimensions(dims.width, dims.height)
        var applyFailed = false
        let ok = bondScanTry("\(reason) set activeFormat \(dims.width)x\(dims.height)") {
            do {
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
            } catch {
                applyFailed = true
                camera.unlockForConfiguration()
                ScanLog.shared.write("\(reason) lockForConfiguration failed")
            }
        }
        if !ok || applyFailed {
            return false
        }
        // Trust the format the device actually kept, not the one we requested.
        let actual = camera.activeFormat
        let actualDims = formatDimensions(actual)
        let actualSub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(actual.formatDescription))
        chosenDeviceFormat = actual
        chosenFormatWidth = Int(actualDims.width)
        chosenFormatHeight = Int(actualDims.height)
        chosenFormatSubtype = actualSub
        if Int(actualDims.width) != Int(dims.width) || Int(actualDims.height) != Int(dims.height) {
            ScanLog.shared.write("\(reason) requested \(dims.width)x\(dims.height) but activeFormat is \(actualDims.width)x\(actualDims.height) subtype=\(actualSub)")
        }
        bondScanTry("\(reason) video output settings") {
            self.applyVideoOutputSettings(width: Int(actualDims.width), height: Int(actualDims.height), subtype: actualSub)
        }
        applyPhotoOutputDimensions()
        return true
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
        } else if lower == "jpeg" || lower == "mjpa" || lower == "mjpb" || lower == "mjpg" {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        } else {
            pixelFormat = kCVPixelFormatType_32BGRA
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        output.videoSettings = settings
        ScanLog.shared.write("video output settings \(width)x\(height) pixel_format=\(subtype)")
    }

    /// Set maxPhotoDimensions only to a value listed on the CURRENT
    /// activeFormat.supportedMaxPhotoDimensions. Must be called inside
    /// beginConfiguration/commitConfiguration on the session queue when
    /// the session is already running.
    private func applyPhotoOutputDimensions() {
        guard photoCaptureSupported else { return }
        if #available(macOS 13.0, *) {
            guard let camera = captureDevice else { return }
            let format = camera.activeFormat
            let supported = format.supportedMaxPhotoDimensions
            let listed = supported.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
            let current = photoOutput.maxPhotoDimensions
            guard let best = largestSupportedPhotoDimensions(for: format),
                  photoDimension(best, isIn: supported),
                  best.width > 0, best.height > 0 else {
                ScanLog.shared.write("photo output supportedMaxPhotoDimensions is empty or unusable for activeFormat \(formatDimensions(format).width)x\(formatDimensions(format).height); stills may match the video frame (current max_photo=\(current.width)x\(current.height))")
                return
            }
            if current.width == best.width && current.height == best.height {
                ScanLog.shared.write("photo output max_photo already \(best.width)x\(best.height) from supported=[\(listed)]")
                return
            }
            // If a leftover value from a previous format is not in the new
            // list, do not leave it set — but only replace it with a value
            // that IS in the current list, and only inside an ObjC try/catch.
            let applied = bondScanTry("set maxPhotoDimensions \(best.width)x\(best.height)") {
                self.photoOutput.maxPhotoDimensions = best
            }
            if applied {
                let now = self.photoOutput.maxPhotoDimensions
                ScanLog.shared.write("photo output max_photo=\(now.width)x\(now.height) from supported=[\(listed)]")
            } else {
                ScanLog.shared.write("left maxPhotoDimensions unchanged after rejection; current=\(current.width)x\(current.height) supported=[\(listed)]")
            }
        }
    }

    private func logActiveFormatState(_ camera: AVCaptureDevice, at moment: String) {
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(camera.activeFormat.formatDescription))
        ScanLog.shared.write("\(moment) active_format=\(dims.width)x\(dims.height) subtype=\(sub) session_preset=\(session.sessionPreset.rawValue) photo_output=\(photoCaptureSupported)")
    }

    /// One-shot re-assert after startRunning, only if the active format
    /// dimensions actually drifted from what we chose. Do not treat a High
    /// preset name as a reason to fight the device again.
    private func reassertChosenFormatIfNeeded(afterStart: Bool) {
        guard !resolutionSettled else { return }
        guard let camera = captureDevice, let format = chosenDeviceFormat else { return }
        guard !didReassertFormat else { return }
        let dims = formatDimensions(camera.activeFormat)
        if Int(dims.width) == chosenFormatWidth && Int(dims.height) == chosenFormatHeight {
            return
        }
        didReassertFormat = true
        didTryHigherFormat = true
        ScanLog.shared.write("re-asserting format after \(afterStart ? "startRunning" : "setup"); was \(dims.width)x\(dims.height) preset=\(session.sessionPreset.rawValue)")
        session.beginConfiguration()
        let ok = applyDeviceFormat(format, on: camera, reason: "re-assert")
        if !ok {
            apply1080Fallback(on: camera, reason: "re-assert-fallback")
        }
        session.commitConfiguration()
        logActiveFormatState(camera, at: afterStart ? "after_reassert" : "after_setup_reassert")
    }

    @discardableResult
    private func apply1080Fallback(on camera: AVCaptureDevice, reason: String) -> Bool {
        guard let format = select1080FallbackFormat(from: camera.formats) else {
            ScanLog.shared.write("\(reason): no 1920x1080 format is available")
            return false
        }
        return applyDeviceFormat(format, on: camera, reason: reason)
    }

    /// After at most one attempt at a higher format, accept the size the
    /// device is actually delivering (typically 1920x1080 for uncompressed 420v).
    private func handleDeliveredResolutionMismatch(deliveredWidth: Int, deliveredHeight: Int) {
        if resolutionSettled {
            return
        }
        guard let camera = captureDevice else {
            resolutionSettled = true
            return
        }
        let raw = estimatedMegabitsPerSecond(width: chosenFormatWidth, height: chosenFormatHeight, fps: desiredFPSForFormatDimensions(Int32(chosenFormatWidth), Int32(chosenFormatHeight)))
        // A single optional retry was already used at startRunning if the
        // format drifted. Do not try 2560/2048 uncompressed — they need even
        // more bandwidth and previously crashed when photo dimensions were
        // set from a format the session did not keep.
        if !didTryHigherFormat, let hoped = chosenDeviceFormat,
           (chosenFormatWidth != deliveredWidth || chosenFormatHeight != deliveredHeight),
           formatIsMJPEG(hoped) {
            didTryHigherFormat = true
            ScanLog.shared.write("delivered \(deliveredWidth)x\(deliveredHeight) is smaller than chosen \(chosenFormatWidth)x\(chosenFormatHeight); re-asserting MJPEG format once (est raw \(String(format: "%.0f", raw)) Mbps)")
            session.beginConfiguration()
            let ok = applyDeviceFormat(hoped, on: camera, reason: "mismatch-reassert")
            if !ok {
                apply1080Fallback(on: camera, reason: "mismatch-fallback")
                resolutionSettled = true
            }
            session.commitConfiguration()
            deliveredFrameLogged = false
            return
        }
        acceptDeliveredResolution(deliveredWidth: deliveredWidth, deliveredHeight: deliveredHeight)
    }

    private func acceptDeliveredResolution(deliveredWidth: Int, deliveredHeight: Int) {
        resolutionSettled = true
        didTryHigherFormat = true
        guard let camera = captureDevice else { return }
        let actual = camera.activeFormat
        let d = formatDimensions(actual)
        let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(actual.formatDescription))
        chosenDeviceFormat = actual
        chosenFormatWidth = Int(d.width)
        chosenFormatHeight = Int(d.height)
        chosenFormatSubtype = sub
        session.beginConfiguration()
        bondScanTry("accepted-resolution video settings") {
            self.applyVideoOutputSettings(width: Int(d.width), height: Int(d.height), subtype: sub)
        }
        applyPhotoOutputDimensions()
        session.commitConfiguration()
        logActiveFormatState(camera, at: "accepted_delivered")
        let hoped = "\(deliveredWidth)x\(deliveredHeight)"
        ScanLog.shared.write("hardware/USB could not deliver a 2K uncompressed video frame (got \(hoped); activeFormat is \(d.width)x\(d.height) subtype=\(sub)). Uncompressed 420v above 1080p exceeds this camera's USB 2.0 ceiling (~480 Mbps). Accepting \(d.width)x\(d.height). Preview and stills will use this size; OCR relies on crop, upscale, and multi-frame reads.")
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
                let d = formatDimensions(best)
                let sub = fourCharCodeString(CMFormatDescriptionGetMediaSubType(best.formatDescription))
                ScanLog.shared.write("selecting format \(d.width)x\(d.height) subtype=\(sub) mjpeg=\(formatIsMJPEG(best))")
                if !applyDeviceFormat(best, on: camera, reason: "chosen") {
                    ScanLog.shared.write("requested camera format unavailable; falling back to 1920x1080")
                    if !apply1080Fallback(on: camera, reason: "chosen-fallback") {
                        ScanLog.shared.write("1080p fallback also failed; leaving the device default")
                    }
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
            resolutionSettled = false
            didReassertFormat = false
            didTryHigherFormat = false
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
            if !resolutionSettled && (cg.width != chosenFormatWidth || cg.height != chosenFormatHeight) {
                let width = cg.width, height = cg.height
                cameraQueue.async { [weak self] in
                    self?.handleDeliveredResolutionMismatch(deliveredWidth: width, deliveredHeight: height)
                }
            } else if !resolutionSettled {
                resolutionSettled = true
                ScanLog.shared.write("delivered video frame matches chosen \(cg.width)x\(cg.height); resolution settled")
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
                        self.autoFillRecordId = nil
                        self.autoFillAttempts = 0
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
                let supported = captureDevice?.activeFormat.supportedMaxPhotoDimensions ?? []
                if max.width > 0 && max.height > 0 && photoDimension(max, isIn: supported) {
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

    private func shouldFocusIssueDate() -> Bool {
        // When the bond still in view is only missing a confident issue date,
        // auto-retry zooms the date box (more crops, higher upscale, more variants).
        if let aid = autoFillRecordId, let existing = records.first(where: { $0.id == aid }) {
            return requiredFieldsMissing(existing).contains("issue date")
        }
        return false
    }

    private func applySequenceFlag(_ record: inout BondRecord) {
        let recent = recentScanIssueDates(before: record.capturedAt, among: records.filter { $0.id != record.id })
        let unambiguous = fieldConfidenceIsHigh(record, "issueDate")
            && (record.fieldSource?["issueDate"] ?? "").contains("agree")
        if let note = sequenceInconsistencyNote(month: record.issueMonth, year: record.issueYear,
                                                recent: recent, unambiguous: unambiguous) {
            record.status = "REVIEW"
            if record.notes.isEmpty {
                record.notes = note
            } else if !record.notes.contains("previous few scans") && !record.notes.contains("jumps more than a year") {
                record.notes = record.notes + " " + note
            }
        }
    }

    private func finishCapture(image: CGImage, jpegBytes: Data?, automatic: Bool) {

        if automatic {
            ScanLog.shared.write("scan started mode=auto frame=\(image.width)x\(image.height)")
            status("Reading bond with local Apple Vision OCR…")
            let focus = self.shouldFocusIssueDate()
            let recent = recentScanIssueDates(before: ISO8601DateFormatter().string(from: Date()), among: self.records)
            analysisQueue.async { [weak self] in
                let result = scanImage(image, focusIssueDate: focus, recentIssueDates: recent)
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
            let focus = self.shouldFocusIssueDate()
            let recent = recentScanIssueDates(before: ISO8601DateFormatter().string(from: Date()), among: self.records)
            let result = scanImage(image, focusIssueDate: focus, recentIssueDates: recent)
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

    private func writeProcessedImage(_ image: CGImage, to relative: String, fallbackSource: String) {
        let dest = outputRoot.appendingPathComponent(relative)
        let original = outputRoot.appendingPathComponent(fallbackSource)
        do {
            if let data = jpegData(image) {
                try data.write(to: dest, options: .atomic)
            } else if FileManager.default.fileExists(atPath: original.path) {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: original, to: dest)
            }
        } catch {
            ScanLog.shared.write("processed photograph write issue; original is preserved")
            if !FileManager.default.fileExists(atPath: dest.path), FileManager.default.fileExists(atPath: original.path) {
                try? FileManager.default.copyItem(at: original, to: dest)
            }
        }
    }

    private func trashCapturePhotos(_ record: BondRecord) {
        for rel in [record.photo, record.sourcePhoto] where !rel.isEmpty {
            let usedElsewhere = records.contains { other in
                other.id != record.id && (
                    other.photo == rel || other.sourcePhoto == rel
                    || (other.fieldPhoto ?? [:]).values.contains(rel)
                )
            }
            if usedElsewhere { continue }
            let url = outputRoot.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    private func priorRecord(for incoming: BondRecord) -> BondRecord? {
        if let match = recordMatchingSerial(incoming.serial, in: records, excluding: incoming.id) {
            return match
        }
        if let aid = autoFillRecordId, aid != incoming.id, let existing = records.first(where: { $0.id == aid }) {
            return existing
        }
        return nil
    }

    private func presentRecord(_ record: BondRecord, flash: NSColor, message: String, automatic: Bool, contributed: Bool, isNew: Bool) {
        var record = record
        let priorStatus = record.status
        let priorNotes = record.notes
        applySequenceFlag(&record)
        if record.status != priorStatus || record.notes != priorNotes,
           let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
            try? writeRecords(records)
        }
        updateCount()
        let serialDisplay = record.serial.isEmpty ? "unreadable serial" : record.serial
        lastLabel.stringValue = "Last: \(record.series) \(serialDisplay) | \(record.issueMonth)/\(record.issueYear) | $\(record.denomination) | \(record.status)"
        preview.captureFlash(color: flash)
        status(message)
        emptyFrames = 0
        if contributed { enrichRecordInBackground(record) }
        if automatic {
            if isNew { autoFillRecordId = record.id; autoFillAttempts = 1 }
            else { autoFillAttempts += 1 }
            autoFillRecordId = record.id
            if requiredFieldsComplete(record) {
                lockedAfterCapture = true
                autoFillAttempts = autoFillMaxAttempts
                ScanLog.shared.write("auto fill complete required_fields=all attempts=\(autoFillAttempts)")
            } else if autoFillAttempts >= autoFillMaxAttempts {
                lockedAfterCapture = true
                ScanLog.shared.write("auto fill exhausted attempts=\(autoFillAttempts) missing=\(requiredFieldsMissing(record).joined(separator: ","))")
            } else {
                lockedAfterCapture = false
                nextAutoAllowedAt = Date().timeIntervalSince1970 + 1.2
                ScanLog.shared.write("auto fill retry attempts=\(autoFillAttempts)/\(autoFillMaxAttempts) missing=\(requiredFieldsMissing(record).joined(separator: ","))")
            }
        } else {
            lockedAfterCapture = true
        }
    }

    private func applyOCR(_ result: OCRResult, to id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            ScanLog.shared.write("ocr result ignored; record no longer present")
            return
        }
        let row = records[index]
        var incoming = result.record
        incoming.id = row.id
        incoming.capturedAt = row.capturedAt
        incoming.sourcePhoto = row.sourcePhoto
        incoming.photo = row.photo
        applyRequiredStatus(&incoming)

        if let prior = priorRecord(for: incoming), let priorIndex = records.firstIndex(where: { $0.id == prior.id }) {
            var merged = records[priorIndex]
            let filled = mergeBondRecord(from: incoming, into: &merged,
                                         contributingPhoto: incoming.photo,
                                         contributingSource: incoming.sourcePhoto,
                                         captureId: incoming.id)
            if filled.isEmpty {
                records.removeAll { $0.id == incoming.id }
                trashCapturePhotos(incoming)
                try? writeRecords(records)
                ScanLog.shared.write("extra photograph dropped; no new required fields (prior id=\(prior.id))")
                presentRecord(merged, flash: .systemOrange,
                              message: "Same bond — no new required fields. Extra photograph not kept.",
                              automatic: false, contributed: false, isNew: false)
                return
            }
            writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
            records.removeAll { $0.id == incoming.id }
            if let idx = records.firstIndex(where: { $0.id == prior.id }) {
                records[idx] = merged
            } else {
                records.append(merged)
            }
            do { try writeRecords(records) }
            catch { status("OCR results could not be saved: \(error.localizedDescription)"); preview.captureFlash(color: .systemRed); return }
            let fieldList = filled.joined(separator: ", ")
            ScanLog.shared.write("merged fields=\(fieldList) into existing record; photograph kept (prior id=\(prior.id)) status=\(merged.status)")
            let flash: NSColor = requiredFieldsComplete(merged) ? .systemGreen : .systemYellow
            let message = requiredFieldsComplete(merged)
                ? "Updated the existing record with \(fieldList). All required fields verified. Remove the bond."
                : "Updated the existing record with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", "))."
            presentRecord(merged, flash: flash, message: message, automatic: false, contributed: true, isNew: false)
            return
        }

        writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
        annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
        applyRequiredStatus(&incoming)
        let previous = records
        records[index] = incoming
        do { try writeRecords(records) }
        catch {
            records = previous
            status("OCR results could not be saved: \(error.localizedDescription)")
            preview.captureFlash(color: .systemRed)
            NSSound.beep()
            ScanLog.shared.write("ocr record write failed; original photograph preserved")
            return
        }
        ScanLog.shared.write("scan updated status=\(incoming.status) fields_nonempty=\([incoming.series, incoming.serial, incoming.issueMonth, incoming.issueYear, incoming.denomination].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
        let flash: NSColor = incoming.status == "OK" ? .systemGreen : .systemYellow
        let message = incoming.status == "OK"
            ? "OCR complete — verified. Remove the bond, then show the next one."
            : "OCR complete — review needed (\(requiredFieldsMissing(incoming).joined(separator: ", "))). Remove the bond, then show the next one."
        presentRecord(incoming, flash: flash, message: message, automatic: false, contributed: true, isNew: true)
    }

    private func handleOCR(_ result: OCRResult, auto: Bool) {
        var incoming = result.record
        applyRequiredStatus(&incoming)

        if auto && autoFillRecordId == nil && (!result.bondTextFound || result.huntScore < 45) {
            nextAutoAllowedAt = Date().timeIntervalSince1970 + 3.0
            ScanLog.shared.write("auto scan rejected: low OCR evidence score=\(result.huntScore) count=\(result.lineCount)")
            isProcessing = false
            status("Not readable — improve lighting/focus, reposition, or press Space to save for review.")
            return
        }

        if let prior = priorRecord(for: incoming), let priorIndex = records.firstIndex(where: { $0.id == prior.id }) {
            var merged = records[priorIndex]
            let filled = mergeBondRecord(from: incoming, into: &merged, contributingPhoto: "", contributingSource: "", captureId: incoming.id)
            if filled.isEmpty {
                ScanLog.shared.write("auto/manual retry added no required fields; extra photograph not saved (prior id=\(prior.id))")
                isProcessing = false
                if auto {
                    presentRecord(merged, flash: .systemOrange,
                                  message: requiredFieldsComplete(merged)
                                    ? "Same bond already verified. Remove it before the next one."
                                    : "Same bond — no new required fields. Trying again…",
                                  automatic: auto, contributed: false, isNew: false)
                } else {
                    presentRecord(merged, flash: .systemOrange,
                                  message: "Same bond — no new required fields. Extra photograph not kept.",
                                  automatic: false, contributed: false, isNew: false)
                }
                return
            }
            // Contributing retry: save this photograph and point new fields at it.
            let filename = "\(incoming.capturedAt.replacingOccurrences(of: ":", with: "-"))_\(incoming.id.prefix(8)).jpg"
            incoming.photo = "photos/" + filename
            incoming.sourcePhoto = "photos/original_" + filename
            do {
                guard let original = jpegData(result.originalImage) else { throw NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original JPEG encoding failed"]) }
                try original.write(to: outputRoot.appendingPathComponent(incoming.sourcePhoto), options: .atomic)
                writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
                // Re-merge so fieldPhoto paths are the ones we just wrote.
                merged = records[priorIndex]
                let filled2 = mergeBondRecord(from: incoming, into: &merged,
                                              contributingPhoto: incoming.photo,
                                              contributingSource: incoming.sourcePhoto,
                                              captureId: incoming.id)
                records[priorIndex] = merged
                try writeRecords(records)
                let fieldList = (filled2.isEmpty ? filled : filled2).joined(separator: ", ")
                ScanLog.shared.write("merged fields=\(fieldList) into existing record; photograph kept (prior id=\(prior.id)) status=\(merged.status)")
                isProcessing = false
                let flash: NSColor = requiredFieldsComplete(merged) ? .systemGreen : .systemYellow
                let message: String
                if requiredFieldsComplete(merged) {
                    message = "Updated the existing record with \(fieldList). All required fields verified. Remove the bond."
                } else if auto && autoFillAttempts + 1 < autoFillMaxAttempts {
                    message = "Updated with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", ")). Trying another photograph…"
                } else {
                    message = "Updated with \(fieldList). Still missing \(requiredFieldsMissing(merged).joined(separator: ", "))."
                }
                NSSound(named: NSSound.Name("Glass"))?.play()
                presentRecord(merged, flash: flash, message: message, automatic: auto, contributed: true, isNew: false)
            } catch {
                ScanLog.shared.write("scan save failed")
                status("SAVE FAILED: \(error.localizedDescription)")
                NSSound.beep()
                isProcessing = false
            }
            return
        }

        let filename = "\(incoming.capturedAt.replacingOccurrences(of: ":", with: "-"))_\(incoming.id.prefix(8)).jpg"
        incoming.photo = "photos/" + filename
        incoming.sourcePhoto = "photos/original_" + filename
        annotateFieldSources(&incoming, photo: incoming.sourcePhoto, captureId: incoming.id)
        applyRequiredStatus(&incoming)
        do {
            guard let original = jpegData(result.originalImage) else { throw NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Original JPEG encoding failed"]) }
            try original.write(to: outputRoot.appendingPathComponent(incoming.sourcePhoto), options: .atomic)
            writeProcessedImage(result.image, to: incoming.photo, fallbackSource: incoming.sourcePhoto)
            let previous = records
            records.append(incoming)
            do { try writeRecords(records) }
            catch { records = previous; throw error }
            ScanLog.shared.write("scan saved status=\(incoming.status) fields_nonempty=\([incoming.series, incoming.serial, incoming.issueMonth, incoming.issueYear, incoming.denomination].filter { !$0.isEmpty }.count) rectified=\(result.rectified) total=\(records.count)")
            NSSound(named: NSSound.Name("Glass"))?.play()
            let flash: NSColor = incoming.status == "OK" ? .systemGreen : .systemYellow
            let message: String
            if incoming.status == "OK" {
                message = "Saved! All required fields verified. Remove the bond, then show the next one."
            } else if auto {
                message = "Saved. Still missing \(requiredFieldsMissing(incoming).joined(separator: ", ")). Trying another photograph…"
            } else {
                message = "Saved for REVIEW (\(requiredFieldsMissing(incoming).joined(separator: ", "))). Remove bond, then show the next one."
            }
            isProcessing = false
            presentRecord(incoming, flash: flash, message: message, automatic: auto, contributed: true, isNew: true)
        } catch {
            ScanLog.shared.write("scan save failed")
            status("SAVE FAILED: \(error.localizedDescription)")
            NSSound.beep()
            isProcessing = false
        }
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
        autoFillRecordId = nil
        autoFillAttempts = 0
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

#if BONDSCANNER_OCR_HARNESS
ocrHarnessMain()
#else
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = BondScannerApp()
app.delegate = delegate
app.run()
#endif
