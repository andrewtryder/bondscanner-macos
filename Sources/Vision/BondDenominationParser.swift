import CoreGraphics
import Foundation

func normalizeDenominationText(_ raw: String) -> String {
    var t = raw.uppercased()
    let replacements = [
        "DORLARS": "DOLLARS", "D0LLARS": "DOLLARS", "DCLLARS": "DOLLARS",
        "DOLIARS": "DOLLARS", "DOILARS": "DOLLARS", "DOLARS": "DOLLARS",
        "TWENTV": "TWENTY", "TVENTY": "TWENTY",
        "SEVENTV": "SEVENTY", "SEVEMTY": "SEVENTY",
        "I8.75": "18.75", "I8,75": "18.75",
        "\u{2014}": "-", "\u{2013}": "-", "\u{2212}": "-",
    ]
    for (a, b) in replacements {
        t = t.replacingOccurrences(of: a, with: b)
    }
    return t
}

func levenshtein(_ a: String, _ b: String) -> Int {
    let aChars = Array(a), bChars = Array(b)
    if aChars.isEmpty {
        return bChars.count
    }
    if bChars.isEmpty {
        return aChars.count
    }
    var prev = Array(0 ... bChars.count)
    var cur = [Int](repeating: 0, count: bChars.count + 1)
    for i in 1 ... aChars.count {
        cur[0] = i
        for j in 1 ... bChars.count {
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
    if series == "E" {
        return (1941 ... 1980).contains(y)
    }
    if series == "EE" {
        return (1980 ... 2026).contains(y)
    }
    if series == "I" {
        return (1998 ... 2026).contains(y)
    }
    return (1941 ... 2026).contains(y)
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
        "SEF": "SEP", "SFP": "SEP", "5EP": "SEP", "SCP": "SEP", "SETEMBER": "SEP",
    ]
    let token = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).first.map(String.init) ?? s
    if let canon = aliases[token], let i = names.firstIndex(of: canon) {
        return String(format: "%02d", i + 1)
    }
    return nil
}

func monthAbbrev(_ month: String) -> String {
    let names = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    if let i = Int(month), (1 ... 12).contains(i) {
        return names[i - 1]
    }
    return month
}

func isRulerLikeText(_ text: String) -> Bool {
    let t = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if t.contains("INCH") || t.contains("CENTIMETER") || t == "CM" || t == "MM" || t == "IN" {
        return true
    }
    // Isolated tick numbers: "1", "10", "12", "1 2 3 4".
    let compact = t.replacingOccurrences(of: " ", with: "")
    if regexMatches("^[0-9]{1,2}$", in: compact).isEmpty == false {
        if let n = Int(compact), (0 ... 16).contains(n) {
            return true
        }
    }
    let nums = regexMatches("\\b[0-9]{1,2}\\b", in: t)
    if nums.count >= 3, nums.allSatisfy({ Int($0) ?? 99 <= 16 }) {
        return true
    }
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
        ("FIFTYDOLLARS", "50", 2),
    ]
    // Exact (after TVENTY→TWENTY normalization) first.
    let exactPairs: [(String, String)] = [
        ("TEN THOUSAND", "10000"), ("FIVE THOUSAND", "5000"),
        ("ONE THOUSAND", "1000"), ("FIVE HUNDRED", "500"),
        ("TWO HUNDRED", "200"), ("ONE HUNDRED", "100"),
        ("SEVENTY-FIVE", "75"), ("SEVENTY FIVE", "75"), ("SEVENTYFIVE", "75"),
        ("TWENTY-FIVE", "25"), ("TWENTY FIVE", "25"), ("TWENTYFIVE", "25"),
        ("FIFTY DOLLARS", "50"), ("TEN DOLLARS", "10"),
        ("SEVENTY FIVE DOLLARS", "75"), ("TWENTY FIVE DOLLARS", "25"),
    ]
    for (word, amount) in exactPairs where faces.contains(amount) && normalized.contains(word) {
        hits.append((amount, 2, word))
    }
    if regexMatches("TWENTY[\\s-]*F[I1L]?VE", in: normalized).isEmpty == false {
        hits.append(("25", 2, "TWENTY-FIVE"))
    }
    if regexMatches("SEVENTY[\\s-]*F[I1L]?VE", in: normalized).isEmpty == false {
        hits.append(("75", 2, "SEVENTY-FIVE"))
    }

    // Sliding-window Levenshtein against compact letter strings (TVENTYFINE ≈ TWENTYFIVE).
    for (phrase, amount, strength) in phrases where faces.contains(amount) {
        let target = Array(phrase)
        let chars = Array(compact)
        guard chars.count >= target.count - 1 else { continue }
        let maxDist = max(1, min(2, target.count / 5 + 1)) // 10-letter phrase allows 2
        let minLen = max(target.count - 1, 1)
        let maxLen = target.count + 1
        if chars.count >= minLen {
            for len in minLen ... min(maxLen, chars.count) {
                if chars.count < len {
                    break
                }
                for start in 0 ... (chars.count - len) {
                    let window = String(chars[start ..< (start + len)])
                    if levenshtein(window, phrase) <= maxDist {
                        hits.append((amount, strength, "fuzzy:\(phrase)"))
                    }
                }
            }
        }
    }
    // Isolated FIFTY / HUNDRED without DOLLARS is weaker and easy to hallucinate.
    if hits.isEmpty {
        if normalized.contains("FIFTY"), faces.contains("50") {
            hits.append(("50", 1, "FIFTY"))
        }
        if normalized.contains("THOUSAND"), faces.contains("1000"), !normalized.contains("TEN THOUSAND"), !normalized.contains("FIVE THOUSAND") {
            hits.append(("1000", 1, "THOUSAND"))
        }
    }
    // Dedup, keep strongest evidence for each amount.
    var best: [String: (Int, String)] = [:]
    for (v, s, e) in hits {
        if let prev = best[v], prev.0 >= s {
            continue
        }
        best[v] = (s, e)
    }
    // More specific compounds (TWENTYFIVE) ahead of shorter ones (TEN DOLLARS)
    // so `.first` cannot pick a false $10 over a real $25.
    return best.map { ($0.key, $0.value.0, $0.value.1) }.sorted { a, b in
        if a.1 != b.1 {
            return a.1 > b.1
        }
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
        if isDateLikeText(line.text) {
            continue
        }
        if isRulerLikeText(line.text) {
            continue
        }
        let token = cleanAlnum(line.text)
        if isYearToken(token) {
            continue
        }
        // "10 MAY 1966" compacted is 10MAY1966 — skip any face value on a date line (already continued).
        var candidates: [String] = []
        if faces.contains(token) {
            candidates.append(token)
        }
        if token.hasSuffix("00"), token.count == 4 {
            let stem = String(token.dropLast(2))
            if faces.contains(stem) {
                candidates.append(stem)
            }
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
                || regexMatches("\\b" + value + "\\b[^A-Z0-9]{0,12}(?:MATURITY|FACE)", in: blob).isEmpty == false
            {
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
            ("7\\s*[.,]\\s*50", "10"),
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
