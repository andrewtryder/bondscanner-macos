import CoreGraphics
import Foundation

func stampRegionCrops(_ image: CGImage) -> [CGImage] {
    let w = image.width, h = image.height
    // Dating stamp is typically below the issue-date line, still on the right.
    let regions = [
        CGRect(x: Int(Double(w) * 0.40), y: Int(Double(h) * 0.22), width: max(Int(Double(w) * 0.58), 1), height: max(Int(Double(h) * 0.50), 1)),
        CGRect(x: Int(Double(w) * 0.35), y: Int(Double(h) * 0.30), width: max(Int(Double(w) * 0.62), 1), height: max(Int(Double(h) * 0.50), 1)),
    ]
    var crops: [CGImage] = []
    for r in regions {
        guard r.width > 80, r.height > 50, let crop = image.cropping(to: r) else { continue }
        crops.append(upscaledImage(crop, scale: 2.0) ?? crop)
    }
    return crops
}

/// Dating-stamp crops anchored below the ISSUE DATE label (right side, mid bond).
func stampAnchoredCrops(_ image: CGImage, lines: [OCRLine]) -> [CGImage] {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    var rects: [CGRect] = []
    for line in lines {
        guard isIssueDateAnchorText(line.text) else { continue }
        if line.box.midX < 0.35 {
            continue
        }
        let box = visionBoxToCG(line.box, image: image)
        let x = max(0, box.minX - 0.16 * w)
        let maxX = min(w, box.maxX + 0.16 * w)
        // Start below the typed issue date, cover the agent stamp area.
        let top = min(h - 40, box.minY + max(0.10 * h, box.height * 4))
        let height = min(h - top, 0.38 * h)
        let r = CGRect(x: x, y: top, width: maxX - x, height: height)
        if r.width > 60, r.height > 36 {
            rects.append(r)
        }
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

func monthsBetweenIssue(_ monthA: String, _ yearA: String, _ monthB: String, _ yearB: String) -> Int? {
    guard let a = yearMonthIndex(monthA, yearA), let b = yearMonthIndex(monthB, yearB) else { return nil }
    return b - a
}

func extractDatingStamp(_ lines: [OCRLine], series: String) -> DatingStampReading? {
    let months = "JAN(?:UARY)?|FEB(?:RUARY)?|MAR(?:CH)?|APR(?:IL)?|MAY|JUN(?:E)?|JUL(?:Y)?|AUG(?:UST)?|SEP(?:T(?:EMBER)?)?|OCT(?:OBER)?|NOV(?:EMBER)?|DEC(?:EMBER)?"
    // Pattern 1: Day + month name + year (e.g. 14 APR 1986)
    let patternDayFirst = "(?:^|[^A-Z0-9])([0-3IlLO]?[0-9IlLO])[\\.\\-]?\\s+(\(months))\\.?\\s+((?:19|20)[0-9O]{2})(?:[^0-9]|$)"
    // Pattern 2: Month name + day + year (e.g. APR 14, 1986 or APR 14 1986)
    let patternMonthFirst = "(?:^|[^A-Z0-9])(\(months))\\.?\\s+([0-3IlLO]?[0-9IlLO])[,\\.\\-]?\\s+((?:19|20)[0-9O]{2})(?:[^0-9]|$)"

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
        guard let day = Int(t), (1 ... 31).contains(day) else { return nil }
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
        if isIssueLabel(text) || isSerialLike(text) {
            return
        }
        let u = text.uppercased()
        if let reDayFirst = try? NSRegularExpression(pattern: patternDayFirst, options: [.caseInsensitive]) {
            let ns = NSRange(u.startIndex ..< u.endIndex, in: u)
            for match in reDayFirst.matches(in: u, range: ns) {
                guard let dR = Range(match.range(at: 1), in: u),
                      let mR = Range(match.range(at: 2), in: u),
                      let yR = Range(match.range(at: 3), in: u),
                      let day = stampDay(String(u[dR])),
                      let month = monthFromName(String(u[mR])),
                      let year = stampYear(String(u[yR])) else { continue }
                let conf = assembled ? "uncertain" : ((1941 ... 2026).contains(Int(year) ?? 0) ? "high" : "uncertain")
                hits.append(DatingStampReading(day: day, month: month, year: year, confidence: conf,
                                               raw: "\(day) \(monthAbbrev(month)) \(year)"))
            }
        }
        if let reMonthFirst = try? NSRegularExpression(pattern: patternMonthFirst, options: [.caseInsensitive]) {
            let ns = NSRange(u.startIndex ..< u.endIndex, in: u)
            for match in reMonthFirst.matches(in: u, range: ns) {
                guard let mR = Range(match.range(at: 1), in: u),
                      let dR = Range(match.range(at: 2), in: u),
                      let yR = Range(match.range(at: 3), in: u),
                      let day = stampDay(String(u[dR])),
                      let month = monthFromName(String(u[mR])),
                      let year = stampYear(String(u[yR])) else { continue }
                let conf = assembled ? "uncertain" : ((1941 ... 2026).contains(Int(year) ?? 0) ? "high" : "uncertain")
                hits.append(DatingStampReading(day: day, month: month, year: year, confidence: conf,
                                               raw: "\(day) \(monthAbbrev(month)) \(year)"))
            }
        }
    }

    for line in lines {
        collect(from: line.text, assembled: false)
    }
    // Join only nearby, non-serial lines so a split "12" / "AUG" / "1966" can match
    // without swallowing the serial number or the $25 corner. These are uncertain.
    for (i, a) in lines.enumerated() {
        if isIssueLabel(a.text) || isSerialLike(a.text) {
            continue
        }
        var group = a.text.uppercased()
        for (j, b) in lines.enumerated() where j != i {
            if isIssueLabel(b.text) || isSerialLike(b.text) {
                continue
            }
            let dx = abs(b.box.midX - a.box.midX), dy = abs(b.box.midY - a.box.midY)
            if dy < 0.10, dx < 0.28 {
                group += " " + b.text.uppercased()
            }
        }
        collect(from: group, assembled: true)
    }

    return hits.first(where: { $0.confidence == "high" }) ?? hits.first
}
