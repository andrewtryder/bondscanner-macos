import Foundation
import CoreGraphics

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
    // A standard US savings bond serial has a single leading prefix letter.
    // If the first character is a letter, start numeric body at index 1 so any 'O' in the numeric body is converted to '0'.
    let start = chars[0].isLetter ? 1 : 0
    var end = chars.count
    if end > start && chars[end - 1] == "E" {
        end -= 1
        if end > start && chars[end - 1] == "E" { end -= 1 }
    } else if end > start && chars[end - 1] == "I" {
        end -= 1
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

/// Strict 1-glyph OCR confusions used only when comparing two already-read serials.
func serialCharsAreOCRConfusable(_ a: Character, _ b: Character) -> Bool {
    if a == b { return true }
    let pair = String([a, b]).uppercased()
    let allowed: Set<String> = [
        "0O", "O0", "0D", "D0", "08", "80", "06", "60", "09", "90",
        "1I", "I1", "1L", "L1", "17", "71",
        "5S", "S5", "56", "65",
        "8B", "B8", "83", "38", "86", "68", "89", "98",
        "2Z", "Z2", "4A", "A4"
    ]
    return allowed.contains(pair)
}

/// Exact normalized match, or a single confusable-character difference.
/// Empty (unread) serials never match.
func serialsMatchForMerge(_ incomingRaw: String, _ existingRaw: String) -> (exact: Bool, near: Bool) {
    let a = normalizeSerial(incomingRaw)
    let b = normalizeSerial(existingRaw)
    if a.isEmpty || b.isEmpty { return (false, false) }
    if a == b { return (true, false) }
    guard a.count == b.count else { return (false, false) }
    let diffs = zip(Array(a), Array(b)).filter { $0.0 != $0.1 }
    guard diffs.count == 1, serialCharsAreOCRConfusable(diffs[0].0, diffs[0].1) else {
        return (false, false)
    }
    return (false, true)
}

/// Other required fields that both sides actually read must be identical.
func otherRequiredFieldsAgree(_ incoming: BondRecord, _ existing: BondRecord) -> Bool {
    func agree(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return true }
        return a == b
    }
    return agree(incoming.series, existing.series)
        && agree(incoming.denomination, existing.denomination)
        && agree(incoming.issueMonth, existing.issueMonth)
        && agree(incoming.issueYear, existing.issueYear)
}

/// A capture may merge into an existing record only when the capture's OWN
/// serial was read and matches the record's serial exactly, or within a
/// strict 1-character OCR-confusion tolerance with every other read field
/// agreeing. "Retry in progress" or "bond still in view" is never enough.
func canMergeCapture(_ incoming: BondRecord, into existing: BondRecord) -> Bool {
    let match = serialsMatchForMerge(incoming.serial, existing.serial)
    if match.exact { return true }
    if match.near && otherRequiredFieldsAgree(incoming, existing) { return true }
    return false
}

func rectangleChangedForScene(_ a: CGRect, _ b: CGRect) -> Bool {
    return abs(a.midX - b.midX) > 0.12
        || abs(a.midY - b.midY) > 0.12
        || abs(a.width - b.width) > 0.18
        || abs(a.height - b.height) > 0.18
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

/// Series E serial length varies by denomination and era: 1 letter + 8, 9, or 10
/// digits + E. $25 bonds are typically 10 digits (Q2234677197E); $50 bonds are
/// typically 9 (L710124456E). $100 length is not assumed, so 8–10 are all accepted.
/// Not tied to the $25 10-digit pattern. Series EE / I keep 1 letter + 10 digits
/// + EE/I. Strips a leading junk character only when the remainder already
/// matches exactly. Never invents characters.
func validatedSerial(_ raw: String, series: String = "") -> FieldReading {
    let n = normalizeSerial(raw)
    guard !n.isEmpty else { return FieldReading() }

    func isExactE(_ s: String) -> Bool {
        return regexMatches("^[A-Z][0-9]{8,10}E$", in: s).isEmpty == false
    }
    func isExactEE(_ s: String) -> Bool {
        return s.count == 13 && regexMatches("^[A-Z][0-9]{10}EE$", in: s).isEmpty == false
    }
    func isExactI(_ s: String) -> Bool {
        return regexMatches("^[A-Z][0-9]{10}I$", in: s).isEmpty == false
    }

    // Prefer an exact-pattern SUBSTRING so a glued prefix (a name's last letter)
    // is treated as junk only when the remainder itself is an exact serial.
    let eeHits = regexMatches("[A-Z][0-9]{10}EE", in: n)
    // Greedy 8–10; prefer the longest exact hit so a 10-digit serial is not
    // truncated to a shorter prefix that happens to end before an E.
    let eHits = regexMatches("[A-Z][0-9]{8,10}E", in: n).filter { hit in
        // Do not accept the E-truncated form of an EE serial.
        guard let range = n.range(of: hit) else { return false }
        let after = range.upperBound
        if after < n.endIndex, n[after] == "E" { return false }
        return isExactE(hit)
    }.sorted { $0.count > $1.count }
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

func acceptedFaceValue(_ value: String) -> Bool {
    // This batch is $25, $50, and $100 only. Other extracted amounts stay
    // in the record but are not enough for a green status.
    return ["25", "50", "100"].contains(value)
}

func requiredFieldsComplete(_ record: BondRecord) -> Bool {
    return requiredFieldIsConfident(record, key: "serial", value: record.serial)
        && requiredFieldIsConfident(record, key: "denomination", value: record.denomination)
        && acceptedFaceValue(record.denomination)
}

func requiredFieldsMissing(_ record: BondRecord) -> [String] {
    var missing: [String] = []
    if !requiredFieldIsConfident(record, key: "serial", value: record.serial) { missing.append("serial") }
    if !requiredFieldIsConfident(record, key: "denomination", value: record.denomination)
        || !acceptedFaceValue(record.denomination) {
        missing.append("face value")
    }
    return missing
}

/// Date confidence for the CSV. An uncertain or missing date never blocks green.
func dateCheck(for record: BondRecord, among records: [BondRecord]) -> String {
    if record.issueMonth.isEmpty || record.issueYear.isEmpty { return "missing" }
    let high = fieldConfidenceIsHigh(record, "issueDate")
    let recent = recentScanIssueDates(before: record.capturedAt, among: records.filter { $0.id != record.id })
    let unambiguous = high && (record.fieldSource?["issueDate"] ?? "").contains("agree")
    if sequenceInconsistencyNote(month: record.issueMonth, year: record.issueYear,
                                 recent: recent, unambiguous: unambiguous) != nil {
        return "uncertain"
    }
    return high ? "ok" : "uncertain"
}

func applyRequiredStatus(_ record: inout BondRecord) {
    if record.status == "PROCESSING" || record.status == "DUPLICATE" { return }
    let upper = record.status.uppercased()
    if upper == "FAILED" || upper == "FAIL" || upper == "ERROR" || upper == "FAILURE" { return }
    let missing = requiredFieldsMissing(record)

    // Evidence-based bond validation
    let validation = BondValidationRules.validateBond(record: record)
    record.validationWarnings = validation.warnings.isEmpty ? nil : validation.warnings
    record.validationErrors = validation.hardErrors.isEmpty ? nil : validation.hardErrors

    if !validation.hardErrors.isEmpty {
        record.status = "REVIEW"
        record.notes = "Validation: " + validation.hardErrors.joined(separator: "; ")
        return
    }

    if missing.isEmpty {
        record.status = "OK"
        if !validation.warnings.isEmpty {
            record.notes = "Warning: " + validation.warnings.joined(separator: "; ")
        } else if record.notes.hasPrefix("Missing or uncertain:") || record.notes.hasPrefix("Validation:") {
            record.notes = ""
        }
    } else {
        record.status = "REVIEW"
        record.notes = "Missing or uncertain: " + missing.joined(separator: ", ")
        if !validation.warnings.isEmpty {
            record.notes += " | Warning: " + validation.warnings.joined(separator: "; ")
        }
    }
}

func mergeBondRecord(from incoming: BondRecord, into existing: inout BondRecord, contributingPhoto: String, contributingSource: String, captureId: String) -> [String] {
    var filled: [String] = []
    let confirmedFields = Set(existing.userConfirmedFields ?? [])
    func isUserConfirmed(_ key: String) -> Bool {
        return confirmedFields.contains(key)
    }
    func incomingHigh(_ key: String) -> Bool {
        return (incoming.fieldConfidence?[key] ?? "") == "high"
    }
    func existingHigh(_ key: String) -> Bool {
        return (existing.fieldConfidence?[key] ?? "") == "high"
    }
    func take(_ key: String, confidenceKey: String? = nil, current: String, incomingValue: String, set: (String) -> Void) {
        // Requirement 5: Never silently replace user-confirmed values!
        if isUserConfirmed(key) { return }
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
