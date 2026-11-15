import CoreGraphics
import Foundation

func regexMatches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let r = NSRange(text.startIndex ..< text.endIndex, in: text)
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
        if end > start && chars[end - 1] == "E" {
            end -= 1
        }
    } else if end > start && chars[end - 1] == "I" {
        end -= 1
    }
    if start < end {
        for i in start ..< end where chars[i] == "O" {
            chars[i] = "0"
        }
    }
    return String(chars)
}

func recordMatchingSerial(_ raw: String, in records: [BondRecord], excluding id: String? = nil) -> BondRecord? {
    let key = normalizeSerial(raw)
    guard !key.isEmpty else { return nil }
    return records.first { record in
        if let id = id, record.id == id {
            return false
        }
        let other = normalizeSerial(record.serial)
        return !other.isEmpty && other == key
    }
}

/// Strict 1-glyph OCR confusions used only when comparing two already-read serials.
func serialCharsAreOCRConfusable(_ a: Character, _ b: Character) -> Bool {
    if a == b {
        return true
    }
    let pair = String([a, b]).uppercased()
    let allowed: Set = [
        "0O", "O0", "0D", "D0", "08", "80", "06", "60", "09", "90",
        "1I", "I1", "1L", "L1", "17", "71",
        "5S", "S5", "56", "65",
        "8B", "B8", "83", "38", "86", "68", "89", "98",
        "2Z", "Z2", "4A", "A4",
    ]
    return allowed.contains(pair)
}

/// Exact normalized match, or a single confusable-character difference.
/// Empty (unread) serials never match.
func serialsMatchForMerge(_ incomingRaw: String, _ existingRaw: String) -> (exact: Bool, near: Bool) {
    let a = normalizeSerial(incomingRaw)
    let b = normalizeSerial(existingRaw)
    if a.isEmpty || b.isEmpty {
        return (false, false)
    }
    if a == b {
        return (true, false)
    }
    guard a.count == b.count else { return (false, false) }
    let diffs = zip(Array(a), Array(b)).filter { $0.0 != $0.1 }
    guard diffs.count == 1, serialCharsAreOCRConfusable(diffs[0].0, diffs[0].1) else {
        return (false, false)
    }
    return (false, true)
}

/// Other required fields that both sides actually read must be identical.
func otherRequiredFieldsAgree(_ incoming: BondRecord, _ existing: BondRecord) -> Bool {
    return !recordsHaveConflictingFields(incoming, existing)
}

/// Identifies whether an incoming record is an OCR-confusable near-match with an existing record.
/// Used to preserve ambiguous captures as separate records for user review rather than auto-merging.
func findNearMatchRecord(_ incoming: BondRecord, in records: [BondRecord], excluding id: String? = nil) -> BondRecord? {
    let incomingSerial = normalizeSerial(incoming.serial)
    guard !incomingSerial.isEmpty, !validatedSerial(incoming.serial, series: incoming.series).value.isEmpty else { return nil }
    for existing in records {
        if let id = id, existing.id == id {
            continue
        }
        if existing.id == incoming.id {
            continue
        }
        // Skip pairs that have already been resolved to keep separate
        let incomingResolved = incoming.resolvedReviewReasons ?? []
        let existingResolved = existing.resolvedReviewReasons ?? []
        let incomingHasResolvedPair = incomingResolved.contains(where: { key in
            guard key.hasPrefix("keep_separate:") else { return false }
            let cand = key.replacingOccurrences(of: "keep_separate:", with: "").trimmingCharacters(in: .whitespaces)
            return cand == existing.id || existing.id.hasPrefix(cand) || cand.hasPrefix(existing.id)
        })
        let existingHasResolvedPair = existingResolved.contains(where: { key in
            guard key.hasPrefix("keep_separate:") else { return false }
            let cand = key.replacingOccurrences(of: "keep_separate:", with: "").trimmingCharacters(in: .whitespaces)
            return cand == incoming.id || incoming.id.hasPrefix(cand) || cand.hasPrefix(incoming.id)
        })
        if incomingHasResolvedPair || existingHasResolvedPair {
            continue
        }

        let existingSerial = normalizeSerial(existing.serial)
        guard !existingSerial.isEmpty, !validatedSerial(existing.serial, series: existing.series).value.isEmpty else { continue }
        let match = serialsMatchForMerge(incoming.serial, existing.serial)
        if match.near {
            return existing
        }
    }
    return nil
}

/// Checks whether two records have conflicting non-empty fields.
func recordsHaveConflictingFields(_ a: BondRecord, _ b: BondRecord) -> Bool {
    func conflict(_ v1: String, _ v2: String) -> Bool {
        let t1 = v1.trimmingCharacters(in: .whitespacesAndNewlines)
        let t2 = v2.trimmingCharacters(in: .whitespacesAndNewlines)
        if t1.isEmpty || t2.isEmpty {
            return false
        }
        return t1.caseInsensitiveCompare(t2) != .orderedSame
    }
    if conflict(a.series, b.series) {
        return true
    }
    if conflict(a.denomination, b.denomination) {
        return true
    }
    if conflict(a.issueMonth, b.issueMonth) {
        return true
    }
    if conflict(a.issueYear, b.issueYear) {
        return true
    }
    if conflict(a.owner, b.owner) {
        return true
    }
    if conflict(a.secondName, b.secondName) {
        return true
    }
    if conflict(a.taxID, b.taxID) {
        return true
    }
    return false
}

/// A capture may automatically merge into an existing record ONLY for exact,
/// validated serial matches with no conflicting fields.
/// OCR-confusable near-matches and conflicting fields are NEVER automatically merged.
func canMergeCapture(_ incoming: BondRecord, into existing: BondRecord) -> Bool {
    let match = serialsMatchForMerge(incoming.serial, existing.serial)
    guard match.exact, !recordsHaveConflictingFields(incoming, existing) else { return false }

    let vIncoming = validatedSerial(incoming.serial, series: incoming.series)
    let vExisting = validatedSerial(existing.serial, series: existing.series)
    guard !vIncoming.value.isEmpty && !vExisting.value.isEmpty else { return false }

    return true
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

func validSeriesValues() -> [String] {
    ["E", "EE", "I"]
}

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
        if after < n.endIndex, n[after] == "E" {
            return false
        }
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
    if let i = names.firstIndex(where: { s.hasPrefix($0) }) {
        return String(format: "%02d", i + 1)
    }
    if let v = Int(s), (1 ... 12).contains(v) {
        return String(format: "%02d", v)
    }
    return nil
}

func requiredFieldIsConfident(_ record: BondRecord, key: String, value: String) -> Bool {
    guard !value.isEmpty else { return false }
    if let confirmed = record.userConfirmedFields, confirmed.contains(key) {
        return true
    }
    if (record.fieldConfidence?[key] ?? "") == "uncertain" {
        return false
    }
    if (record.fieldConfidence?[key] ?? "") == "high" {
        return true
    }
    // Legacy rows with no confidence: do not treat as green just because a value is present.
    return false
}

func acceptedFaceValue(_ value: String, isUserConfirmed: Bool = false) -> Bool {
    let clean = value.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
    if isUserConfirmed {
        return ["10", "25", "50", "75", "100", "200", "500", "1000", "5000", "10000"].contains(clean)
    }
    // This batch is $25, $50, and $100 only. Other extracted amounts stay
    // in the record but are not enough for a green status.
    return ["25", "50", "100"].contains(clean)
}

func requiredFieldsComplete(_ record: BondRecord) -> Bool {
    let denomConfirmed = record.userConfirmedFields?.contains("denomination") == true
    return requiredFieldIsConfident(record, key: "serial", value: record.serial)
        && requiredFieldIsConfident(record, key: "denomination", value: record.denomination)
        && acceptedFaceValue(record.denomination, isUserConfirmed: denomConfirmed)
}

func requiredFieldsMissing(_ record: BondRecord) -> [String] {
    var missing: [String] = []
    let denomConfirmed = record.userConfirmedFields?.contains("denomination") == true
    if !requiredFieldIsConfident(record, key: "serial", value: record.serial) {
        missing.append("serial")
    }
    if !requiredFieldIsConfident(record, key: "denomination", value: record.denomination)
        || !acceptedFaceValue(record.denomination, isUserConfirmed: denomConfirmed)
    {
        missing.append("face value")
    }
    return missing
}

/// Date confidence for the CSV. An uncertain or missing date never blocks green.
func dateCheck(for record: BondRecord, among records: [BondRecord]) -> String {
    if record.issueMonth.isEmpty || record.issueYear.isEmpty {
        return "missing"
    }
    let high = fieldConfidenceIsHigh(record, "issueDate")
    let recent = recentScanIssueDates(before: record.capturedAt, among: records.filter { $0.id != record.id })
    let unambiguous = high && (record.fieldSource?["issueDate"] ?? "").contains("agree")
    if sequenceInconsistencyNote(month: record.issueMonth, year: record.issueYear,
                                 recent: recent, unambiguous: unambiguous) != nil
    {
        return "uncertain"
    }
    return high ? "ok" : "uncertain"
}

func applyRequiredStatus(_ record: inout BondRecord) {
    if record.status == "PROCESSING" || record.status == "DUPLICATE" {
        return
    }
    let upper = record.status.uppercased()
    if upper == "FAILED" || upper == "FAIL" || upper == "ERROR" || upper == "FAILURE" {
        return
    }
    let missing = requiredFieldsMissing(record)

    // Evidence-based bond validation
    let validation = BondValidationRules.validateBond(record: record)
    record.validationWarnings = validation.warnings.isEmpty ? nil : validation.warnings
    record.validationErrors = validation.hardErrors.isEmpty ? nil : validation.hardErrors

    // Track structured review reasons separately from confidence and notes
    var reasons = Set(record.reviewReasons ?? [])
    let resolved = Set(record.resolvedReviewReasons ?? [])

    // Filter out previous dynamic validation and missing-field reasons before re-evaluating
    reasons = reasons.filter { !$0.hasPrefix("validation:") && !$0.hasPrefix("missing_required:") }

    // If notes historically indicated a near-match, ensure it is recorded in structured reasons
    let hasResolvedNearMatchOrKeepSeparate = resolved.contains("near_match") || resolved.contains(where: { $0.hasPrefix("keep_separate:") || $0.hasPrefix("near_match:") })
    if record.notes.contains("Near-match") || record.notes.contains("near-match"), !hasResolvedNearMatchOrKeepSeparate, !reasons.contains(where: { $0.hasPrefix("near_match") }) {
        reasons.insert("near_match")
    }

    // Add current validation hard errors
    for err in validation.hardErrors {
        let reasonKey = "validation: \(err)"
        if !resolved.contains(reasonKey) {
            reasons.insert(reasonKey)
        }
    }

    // Add current missing required fields
    if !missing.isEmpty {
        reasons.insert("missing_required: \(missing.joined(separator: ", "))")
    }

    // Preserve legacy review intent:
    // If a record historically had REVIEW status, but has no structured reasons and the user has not
    // explicitly confirmed it or resolved the legacy review, retain a legacy review reason.
    if upper == "REVIEW" && reasons.isEmpty && (record.userConfirmedFields ?? []).isEmpty && !resolved.contains("legacy_review") {
        reasons.insert("legacy_review: manual verification required")
    }

    // Remove any explicitly resolved reasons
    for r in resolved {
        reasons.remove(r)
        if r.hasPrefix("keep_separate:") || r.hasPrefix("near_match:") {
            let candId = r.replacingOccurrences(of: "keep_separate:", with: "")
                .replacingOccurrences(of: "near_match:", with: "")
                .trimmingCharacters(in: .whitespaces)
            reasons = reasons.filter { reason in
                if reason.hasPrefix("near_match: \(candId)") || reason == "near_match: \(candId)" || reason.hasPrefix("near_match:\(candId)") {
                    return false
                }
                return true
            }
        }
    }
    if resolved.contains("near_match") || !reasons.contains(where: { $0.hasPrefix("near_match:") }), resolved.contains(where: { $0.hasPrefix("keep_separate:") || $0.hasPrefix("near_match") }) {
        reasons.remove("near_match")
    }

    record.reviewReasons = reasons.isEmpty ? nil : Array(reasons).sorted()

    // If ANY review reason exists (e.g. near-match, validation error, missing field),
    // status MUST be REVIEW and cannot be reclassified as OK simply because OCR confidence is high.
    if let activeReasons = record.reviewReasons, !activeReasons.isEmpty {
        record.status = "REVIEW"
        if !validation.hardErrors.isEmpty {
            let valNote = "Validation: " + validation.hardErrors.joined(separator: "; ")
            if !record.notes.contains("Validation:") {
                record.notes = record.notes.isEmpty ? valNote : "\(record.notes); \(valNote)"
            }
        } else if !missing.isEmpty {
            let missNote = "Missing or uncertain: " + missing.joined(separator: ", ")
            if !record.notes.contains("Missing or uncertain:") {
                record.notes = record.notes.isEmpty ? missNote : "\(record.notes); \(missNote)"
            }
        }
        if !validation.warnings.isEmpty, !record.notes.contains("Warning:") {
            record.notes += " | Warning: " + validation.warnings.joined(separator: "; ")
        }
        return
    }

    // No review reasons and no missing fields -> OK
    record.status = "OK"
    if !validation.warnings.isEmpty {
        record.notes = "Warning: " + validation.warnings.joined(separator: "; ")
    } else if record.notes.hasPrefix("Missing or uncertain:") || record.notes.hasPrefix("Validation:") {
        record.notes = ""
    }
}

func mergeBondRecord(from incoming: BondRecord, into existing: inout BondRecord, contributingPhoto: String, contributingSource: String, captureId: String) -> [String] {
    let before = existing
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
        if isUserConfirmed(key) {
            return
        }
        let ckey = confidenceKey ?? key
        let incomingOK = !incomingValue.isEmpty
        let shouldReplaceUncertain = !current.isEmpty && incomingOK && incomingHigh(ckey) && !existingHigh(ckey)
        let shouldFillEmpty = current.isEmpty && incomingOK
        guard shouldFillEmpty || shouldReplaceUncertain else { return }
        if shouldReplaceUncertain {
            var prev = existing.previousExtracted ?? [:]
            if prev[key] == nil {
                prev[key] = current
            }
            existing.previousExtracted = prev
        }
        set(incomingValue)
        var photos = existing.fieldPhoto ?? [:]
        var ids = existing.fieldCaptureId ?? [:]
        var conf = existing.fieldConfidence ?? [:]
        var src = existing.fieldSource ?? [:]
        photos[key] = contributingSource.isEmpty ? contributingPhoto : contributingSource
        ids[key] = captureId
        if let c = incoming.fieldConfidence?[ckey] {
            conf[ckey] = c
        }
        if let s = incoming.fieldSource?[ckey] {
            src[ckey] = s
        }
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
        if existing.owner.isEmpty, !incoming.owner.isEmpty {
            existing.owner = incoming.owner
        }
        if existing.secondName.isEmpty, !incoming.secondName.isEmpty {
            existing.secondName = incoming.secondName
        }
        if existing.secondRole.isEmpty, !incoming.secondRole.isEmpty {
            existing.secondRole = incoming.secondRole
        }
        if existing.address.isEmpty, !incoming.address.isEmpty {
            existing.address = incoming.address
        }
        if existing.issuingAgent.isEmpty, !incoming.issuingAgent.isEmpty {
            existing.issuingAgent = incoming.issuingAgent
        }
        if existing.datingStamp.isEmpty, !incoming.datingStamp.isEmpty {
            existing.datingStamp = incoming.datingStamp
        }
        if !incoming.rawOCR.isEmpty {
            if let prev = existing.additionalOCR, !prev.isEmpty {
                existing.additionalOCR = prev + "\n---\n" + incoming.rawOCR
            } else {
                existing.additionalOCR = incoming.rawOCR
            }
        }
    }
    if let inReasons = incoming.reviewReasons, !inReasons.isEmpty {
        var mergedReasons = Set(existing.reviewReasons ?? [])
        for r in inReasons {
            mergedReasons.insert(r)
        }
        existing.reviewReasons = Array(mergedReasons).sorted()
    }
    addAssociatedPhotos(to: &existing, newPhotos: [contributingSource, contributingPhoto] + (incoming.associatedPhotos ?? []))
    applyRequiredStatus(&existing)
    // OCR consolidation is a meaningful mutation too.  This makes an in-flight
    // review analysis stale before any of its suggestions can be persisted.
    if existing != before {
        existing.revision = (before.revision ?? 0) + 1
    }
    return filled
}

func annotateFieldSources(_ record: inout BondRecord, photo: String, captureId: String, fields: [String]? = nil) {
    var photos = record.fieldPhoto ?? [:]
    var ids = record.fieldCaptureId ?? [:]
    let pairs: [(String, String)] = [
        ("series", record.series), ("serial", record.serial),
        ("issueMonth", record.issueMonth), ("issueYear", record.issueYear),
        ("denomination", record.denomination),
    ]
    for (key, value) in pairs {
        if value.isEmpty {
            continue
        }
        if let fields = fields, !fields.contains(key) {
            continue
        }
        if photos[key] == nil {
            photos[key] = photo
            ids[key] = captureId
        }
    }
    record.fieldPhoto = photos
    record.fieldCaptureId = ids
}
