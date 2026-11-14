// Sources/Vision/SerialCandidateRanker.swift
// Bond Scanner — Multi-Pass Serial Candidate Extraction and Evidence-Based Ranking Engine
//
// REQUIREMENTS:
// 3. Multi-candidate extraction with source regions and confidence.
// 4. Candidate ranking based on:
//    - Valid prefix
//    - Valid suffix
//    - Plausible numeric length
//    - Expected serial position (upper-right and lower-right corners on physical bonds)
//    - Agreement between independent OCR passes
// 5. Never invent missing serial digits or silently replace user-confirmed values.
// 9. Privacy-safe handling: never expose raw private serial numbers in summaries.

import Foundation
import CoreGraphics

public struct SerialCandidate: Codable, Equatable {
    public let rawText: String
    public let normalized: String
    public let prefix: String
    public let digits: String
    public let suffix: String
    public let box: CGRect
    public var sourcePasses: [String]
    public var visionConfidence: Float
    public var passAgreementCount: Int
    public var score: Double
    public var rankReasons: [String]

    public var maskedDisplay: String {
        return maskSerial(normalized)
    }

    public init(
        rawText: String,
        normalized: String,
        prefix: String,
        digits: String,
        suffix: String,
        box: CGRect,
        sourcePasses: [String] = [],
        visionConfidence: Float = 0.0,
        passAgreementCount: Int = 1,
        score: Double = 0.0,
        rankReasons: [String] = []
    ) {
        self.rawText = rawText
        self.normalized = normalized
        self.prefix = prefix
        self.digits = digits
        self.suffix = suffix
        self.box = box
        self.sourcePasses = sourcePasses
        self.visionConfidence = visionConfidence
        self.passAgreementCount = passAgreementCount
        self.score = score
        self.rankReasons = rankReasons
    }
}

public enum SerialCandidateRanker {

    /// Extract serial candidates from a set of OCR lines from a specific pass.
    static func extractCandidates(
        from lines: [OCRLine],
        passName: String,
        expectedSeries: String = ""
    ) -> [SerialCandidate] {
        var candidates: [SerialCandidate] = []

        for line in lines {
            let normLine = normalizeSerial(line.text)
            guard !normLine.isEmpty else { continue }

            // Extract exact and near-miss pattern matches
            // E.g., [A-Z][0-9]{8,10}E, [A-Z][0-9]{10}EE, [A-Z][0-9]{10}I, or near-misses
            let patterns = [
                "[A-Z][0-9]{10}EE",
                "[A-Z][0-9]{8,10}E\\b",
                "[A-Z][0-9]{10}I\\b",
                "[A-Z][0-9]{7,11}(?:EE|E|I)"
            ]

            var seenNormsInLine = Set<String>()

            for pattern in patterns {
                let matches = regexMatches(pattern, in: normLine)
                for hit in matches {
                    // Prevent duplicate hits for the same token in a single line
                    if seenNormsInLine.contains(hit) { continue }
                    seenNormsInLine.insert(hit)

                    let chars = Array(hit)
                    var pEnd = 0
                    while pEnd < chars.count && chars[pEnd].isLetter { pEnd += 1 }
                    var sStart = chars.count
                    if hit.hasSuffix("EE") { sStart -= 2 }
                    else if hit.hasSuffix("E") || hit.hasSuffix("I") { sStart -= 1 }

                    let prefix = String(chars[0..<pEnd])
                    let suffix = String(chars[sStart..<chars.count])
                    let digits = String(chars[pEnd..<sStart])

                    let candidate = SerialCandidate(
                        rawText: line.text,
                        normalized: hit,
                        prefix: prefix,
                        digits: digits,
                        suffix: suffix,
                        box: line.box,
                        sourcePasses: [passName],
                        visionConfidence: line.confidence,
                        passAgreementCount: 1
                    )
                    candidates.append(candidate)
                }
            }

            // Also inspect individual tokens if they did not match the strict regexes above
            let tokens = line.text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
            for token in tokens {
                let normToken = normalizeSerial(token)
                guard normToken.count >= 9, !seenNormsInLine.contains(normToken) else { continue }

                let chars = Array(normToken)
                var pEnd = 0
                while pEnd < chars.count && chars[pEnd].isLetter { pEnd += 1 }
                guard pEnd > 0 else { continue }

                var sStart = chars.count
                if normToken.hasSuffix("EE") { sStart -= 2 }
                else if normToken.hasSuffix("E") || normToken.hasSuffix("I") { sStart -= 1 }

                guard sStart > pEnd else { continue }
                let digits = String(chars[pEnd..<sStart])
                guard digits.allSatisfy({ $0.isNumber }), digits.count >= 7 else { continue }

                seenNormsInLine.insert(normToken)
                let candidate = SerialCandidate(
                    rawText: token,
                    normalized: normToken,
                    prefix: String(chars[0..<pEnd]),
                    digits: digits,
                    suffix: String(chars[sStart..<chars.count]),
                    box: line.box,
                    sourcePasses: [passName],
                    visionConfidence: line.confidence,
                    passAgreementCount: 1
                )
                candidates.append(candidate)
            }
        }

        return candidates
    }

    /// Merge candidates across multiple independent OCR passes, accumulating agreement counts.
    public static func mergePassCandidates(
        into existing: inout [String: SerialCandidate],
        newCandidates: [SerialCandidate]
    ) {
        for cand in newCandidates {
            let key = cand.normalized
            if var prev = existing[key] {
                // Combine source passes and track distinct occurrences / locations
                var isDistinctPass = false
                for p in cand.sourcePasses where !prev.sourcePasses.contains(p) {
                    prev.sourcePasses.append(p)
                    isDistinctPass = true
                }
                let isDistinctLocation = abs(cand.box.midY - prev.box.midY) > 0.15 || abs(cand.box.midX - prev.box.midX) > 0.15
                if isDistinctPass || isDistinctLocation {
                    prev.passAgreementCount += 1
                }
                prev.visionConfidence = max(prev.visionConfidence, cand.visionConfidence)
                // Keep the bounding box with stronger corner positioning
                if isPreferredSerialPosition(cand.box) && !isPreferredSerialPosition(prev.box) {
                    prev = SerialCandidate(
                        rawText: cand.rawText,
                        normalized: prev.normalized,
                        prefix: prev.prefix,
                        digits: prev.digits,
                        suffix: prev.suffix,
                        box: cand.box,
                        sourcePasses: prev.sourcePasses,
                        visionConfidence: prev.visionConfidence,
                        passAgreementCount: prev.passAgreementCount
                    )
                }
                existing[key] = prev
            } else {
                existing[key] = cand
            }
        }
    }

    /// Test if a normalized bounding box is in the expected physical serial regions.
    /// On US physical savings bonds, serial numbers are printed in:
    /// - Upper right corner: midX > 0.50, midY > 0.55
    /// - Lower right corner: midX > 0.50, midY < 0.45
    public static func isPreferredSerialPosition(_ box: CGRect) -> Bool {
        let isRight = box.midX >= 0.48
        let isUpper = box.midY >= 0.52
        let isLower = box.midY <= 0.45
        return isRight && (isUpper || isLower)
    }

    /// Rank candidates according to Requirement 4:
    /// - Valid prefix
    /// - Valid suffix
    /// - Plausible numeric length
    /// - Expected serial position
    /// - Agreement between independent OCR passes
    public static func rankCandidates(
        _ candidates: [SerialCandidate],
        series: String = "",
        denomination: String = "",
        micrDigits: String? = nil
    ) -> [SerialCandidate] {
        let bSeries = BondSeries(fromString: series)

        let ranked = candidates.map { cand -> SerialCandidate in
            var score: Double = 0.0
            var reasons: [String] = []

            // 1. Vision Base Confidence (0-15 pts)
            let confPts = Double(cand.visionConfidence) * 15.0
            score += confPts
            reasons.append("OCR confidence: +\(String(format: "%.1f", confPts))")

            // 2. Suffix Scoring
            let expectedSuffix = bSeries.expectedSerialSuffix
            if !expectedSuffix.isEmpty {
                if cand.suffix == expectedSuffix {
                    score += 35.0
                    reasons.append("Valid series suffix '\(cand.suffix)': +35")
                } else if ["E", "EE", "I"].contains(cand.suffix) {
                    // Suffix contradicts detected series (e.g. E vs EE)
                    score -= 40.0
                    reasons.append("Suffix '\(cand.suffix)' contradicts Series \(bSeries.canonicalName): -40")
                } else {
                    score -= 25.0
                    reasons.append("Invalid bond suffix '\(cand.suffix)': -25")
                }
            } else if ["E", "EE", "I"].contains(cand.suffix) {
                score += 20.0
                reasons.append("Valid bond suffix '\(cand.suffix)': +20")
            }

            // 3. Prefix Scoring
            let pChar = cand.prefix.first ?? " "
            let expectedDenoms = BondValidationRules.expectedDenominations(forPrefix: pChar, series: bSeries)
            if !expectedDenoms.isEmpty {
                score += 25.0
                reasons.append("Recognized series prefix '\(cand.prefix)': +25")

                // Bonus if prefix matches known denomination
                let cleanDenom = denomination.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
                if !cleanDenom.isEmpty && expectedDenoms.contains(cleanDenom) {
                    score += 20.0
                    reasons.append("Prefix matches $\(cleanDenom) face value: +20")
                }
            } else {
                score -= 10.0
                reasons.append("Uncommon or non-standard prefix '\(cand.prefix)': -10")
            }

            // 4. Plausible Numeric Length Scoring (Requirement 5: Never invent missing digits)
            let digitCount = cand.digits.count
            let validLengths = bSeries.plausibleNumericLengths
            if validLengths.contains(digitCount) {
                score += 25.0
                reasons.append("Valid numeric length (\(digitCount) digits): +25")
            } else {
                // Severe penalty for missing/extra digits; strictly never invented
                score -= 40.0
                reasons.append("Non-standard length (\(digitCount) digits, expected \(validLengths.lowerBound)–\(validLengths.upperBound)): -40")
            }

            // 5. Expected Serial Position Scoring
            if isPreferredSerialPosition(cand.box) {
                if cand.box.midY >= 0.52 {
                    score += 20.0
                    reasons.append("Upper-right corner location: +20")
                } else {
                    score += 18.0
                    reasons.append("Lower-right corner location: +18")
                }
            } else if cand.box.midX >= 0.20 && cand.box.midX <= 0.75 && cand.box.midY >= 0.35 && cand.box.midY <= 0.65 {
                // Central vignette / payee area: serials do not live here
                score -= 15.0
                reasons.append("Central vignette / payee area: -15")
            }

            // 6. Agreement Between OCR Passes / Crops (Audit Item 6)
            // Passes originating from crops of the same source photograph are intra-frame observations,
            // not independent captures. They are scored appropriately without misrepresenting independence.
            if cand.passAgreementCount >= 3 {
                score += 60.0
                reasons.append("Multi-crop agreement (same source photo, \(cand.passAgreementCount) crops): +60")
            } else if cand.passAgreementCount == 2 {
                score += 35.0
                reasons.append("Dual-crop agreement (same source photo): +35")
            }

            // Truncation penalty: if a candidate with >= agreement contains this candidate as a prefix
            if candidates.contains(where: { $0.passAgreementCount >= cand.passAgreementCount && $0.normalized.hasPrefix(cand.normalized) && $0.normalized != cand.normalized }) {
                score -= 60.0
                reasons.append("Truncated variant of full serial: -60")
            }

            // 7. MICR Line Corroboration (Audit Item 5)
            // Award corroboration ONLY for actual serial agreement, NEVER for the shared Treasury routing number (000090007).
            if let micr = micrDigits, !micr.isEmpty {
                let routingNumber = "000090007"
                let isRoutingNumber = (micr == routingNumber ||
                    micr.contains("00090007") || micr.contains("00009007") ||
                    (micr.hasPrefix("0000") && micr.contains("9000")))

                if !isRoutingNumber && cand.digits.count >= 8 && micr.count >= 8 {
                    // Must be actual serial agreement (exact match or full serial containment of >= 9 digits)
                    if cand.digits == micr || (cand.digits.count == 10 && micr.count >= 9 && cand.digits.contains(micr)) {
                        score += 30.0
                        reasons.append("Corroborated by independent MICR serial reading: +30")
                    }
                }
            }

            var updated = cand
            updated.score = score
            updated.rankReasons = reasons
            return updated
        }

        return ranked.sorted { $0.score > $1.score }
    }

    /// Select the best validated serial reading from ranked candidates.
    static func selectBestSerial(
        from rankedCandidates: [SerialCandidate],
        series: String = "",
        denomination: String = ""
    ) -> FieldReading {
        guard let best = rankedCandidates.first else {
            return FieldReading()
        }

        let bSeries = BondSeries(fromString: series)
        let expectedSuffix = bSeries.expectedSerialSuffix
        let validLengths = bSeries.plausibleNumericLengths

        let suffixValid = !expectedSuffix.isEmpty && best.suffix == expectedSuffix
        let lengthValid = validLengths.contains(best.digits.count)
        let prefixValid = !BondValidationRules.expectedDenominations(forPrefix: best.prefix.first ?? " ", series: bSeries).isEmpty
        let agreementValid = best.passAgreementCount >= 2 || best.visionConfidence >= 0.85

        let isHigh = best.score >= 60.0 && suffixValid && lengthValid && prefixValid && agreementValid
        let confidence = isHigh ? "high" : "uncertain"
        let source = best.passAgreementCount > 1 ? "ranked-multi-pass(\(best.passAgreementCount))" : "ranked-single-pass"

        return FieldReading(
            value: best.normalized,
            confidence: confidence,
            source: source
        )
    }
}
