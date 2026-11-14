import Foundation
import CoreGraphics
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

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

func bondTextSignal(_ lines: [OCRLine]) -> Bool {
    let text = lines.map(\.text).joined(separator: " ").uppercased()
    let compact = cleanAlnum(text)
    return (text.contains("SERIES") && (text.contains("DOLLAR") || text.contains("SAVINGS")))
        || (text.contains("UNITED STATES") && text.contains("DOLLAR"))
        || !regexMatches("[A-Z][0-9]{7,11}(?:EE|E)", in: compact).isEmpty
}

// Cheap OCR reconnaissance that runs even if paper edges cannot be detected.
// It tries upside-down and portrait camera views before deciding if a bond is visible.
func highConfidenceSerial(from lines: [OCRLine]) -> String {
    let joined = lines.map { $0.text }.joined(separator: " ")
    let compact = lines.map { cleanAlnum($0.text) }.joined()
    let reading = validatedSerial(joined)
    if reading.isHigh { return reading.value }
    let compactReading = validatedSerial(compact)
    if compactReading.isHigh { return compactReading.value }
    return ""
}

func probeForBond(_ image: CGImage) -> (score: Int, lines: Int, found: Bool, serial: String) {
    var best = (score: -1, lines: 0, found: false, serial: "")
    for orientation in [1, 3, 6, 8] {
        guard let candidate = rotateCG(image, exif: orientation) else { continue }
        let lines = textOCR(candidate, fast: true)
        let signal = bondTextSignal(lines)
        let score = orientationScore(lines) + (signal ? 25 : 0)
        let serial = highConfidenceSerial(from: lines)
        if score > best.score {
            best = (score, lines.count, signal, serial)
        } else if best.serial.isEmpty && !serial.isEmpty {
            best.serial = serial
        }
    }
    return best
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

    // Serial: accept an exact Series E/EE/I pattern (E allows 8–10 digits).
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

func scanImage(_ image: CGImage, focusIssueDate: Bool = false, recentIssueDates: [(month: String, year: String)] = []) -> OCRResult {
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
    let extracted = extractIssueDateFromImage(selectedImage, series: result.series,
                                              baseLines: finalLines,
                                              intensive: focusIssueDate,
                                              recent: recentIssueDates)
    if let stamp = extracted.stamp, stamp.confidence == "high" {
        result.datingStamp = stamp.raw
    }
    let date = extracted.date
    if !date.value.isEmpty {
        let parts = date.value.split(separator: "/").map(String.init)
        if parts.count == 2 {
            result.issueMonth = parts[0]
            result.issueYear = parts[1]
            setFieldReading("issueDate", date, on: &result)
            bestLabel += "/issue-date"
        }
    }
    applyRequiredStatus(&result)
    let recognized = bondTextSignal(finalLines) || bondTextSignal(textOCR(bestImage, fast: true))
    ScanLog.shared.write("scan candidates=\(candidates.count) best=\(bestLabel) hunt_score=\(bestScore) final_score=\(finalScore) ocr_lines=\(finalLines.count) rectified=\(bestRectified) bond_text=\(recognized) fields_complete=\(requiredFieldsComplete(result)) denom=\(result.denomination.isEmpty ? "none" : "set")")
    return OCRResult(record: result, image: selectedImage, originalImage: image,
                     huntScore: max(bestScore, finalScore), lineCount: finalLines.count,
                     rectified: bestRectified, bondTextFound: recognized)
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
            if let month = monthNumber(mo), isPlausibleIssueYear(yr, series: next.series),
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

#if BONDSCANNER_OCR_HARNESS
func ocrHarnessMain() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        print("Usage: ocr-harness <image-path>")
        return
    }
    let url = URL(fileURLWithPath: args[1])
    guard let image = cgImageFromFile(url) else {
        print("Failed to load image at \(url.path)")
        return
    }
    let result = scanImage(image)
    print("Record: \(result.record)")
}
#endif
