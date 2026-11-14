import Foundation
import CoreGraphics

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

func yearMonthIndex(_ month: String, _ year: String) -> Int? {
    guard let y = Int(year), let m = Int(month), (1...12).contains(m), isPlausibleIssueYear(year, series: "") || (1941...2026).contains(y) else { return nil }
    return y * 12 + (m - 1)
}

func monthsBetweenIssue(_ monthA: String, _ yearA: String, _ monthB: String, _ yearB: String) -> Int? {
    guard let a = yearMonthIndex(monthA, yearA), let b = yearMonthIndex(monthB, yearB) else { return nil }
    return b - a
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
    return records
        .filter { $0.capturedAt < capturedAt && !$0.issueMonth.isEmpty && !$0.issueYear.isEmpty }
        .sorted { $0.capturedAt > $1.capturedAt }
        .prefix(window)
        .map { ($0.issueMonth, $0.issueYear) }
}

func sequenceInconsistencyNote(month: String, year: String, recent: [(month: String, year: String)], unambiguous: Bool) -> String? {
    guard !recent.isEmpty else { return nil }
    let indexes = recent.compactMap { yearMonthIndex($0.month, $0.year) }
    guard let earliest = indexes.min(), let latest = indexes.max(),
          let issue = yearMonthIndex(month, year) else { return nil }
    if issue < earliest - 2 {
        return "Issue date is more than 2 months earlier than the previous few scans."
    }
    if issue > latest + 12 {
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

    func isAggressiveSource(_ source: String) -> Bool {
        let s = source.lowercased()
        return s.contains("hi-up") || s.contains("dark-up")
    }
    func yearIsCredible(_ year: String) -> Bool {
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

    var conf = "uncertain"
    var src = chosen.source
    if unanimousYear && !disagreed && chosen.year == agreedYear, let m = agreedMonth {
        conf = "high"
        src = "variants-agree"
        if let stamp = stamp, stamp.confidence == "high" {
            if stampConsistent(month: m, year: chosen.year, stamp: stamp) {
                src = "variants+stamp"
            } else {
                conf = "uncertain"
                src = "stamp-conflict"
            }
        }
    }
    if let stamp = stamp, stamp.confidence == "high",
       stampConsistent(month: chosen.month, year: chosen.year, stamp: stamp),
       candidates.contains(where: { $0.year == chosen.year && $0.month == chosen.month || $0.year == chosen.year }) {
        if !disagreed && unanimousYear {
            conf = "high"
            src = "variants+stamp"
        } else if disagreed {
            conf = "uncertain"
            src = "stamp-preferred-variant"
        }
    }
    if ambiguous && conf == "high" && disagreed {
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
