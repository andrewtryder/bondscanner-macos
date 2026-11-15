// Sources/Vision/MICRLineDetector.swift
// Bond Scanner — Experimental MICR-Line Recognition for Compatible Series EE Photographs
//
// HISTORICAL & TECHNICAL BACKGROUND:
// In March 1985, the U.S. Department of the Treasury (Bureau of Public Debt / Fiscal Service)
// redesigned Series EE savings bonds to include a machine-readable Magnetic Ink Character
// Recognition (MICR) clear band along the bottom edge, using the standardized E-13B font.
// Under Federal Reserve Bank Operating Circular No. 4 and 31 CFR Part 321:
// 1. The Transit/Routing field encodes the standardized Fiscal Service Routing Transit Number:
//    "000090007" (bracketed by E-13B transit symbols ⑆000090007⑆).
// 2. The Auxiliary On-Us field (left) encodes the 10-digit serial number.
//
// EXPERIMENTAL SCOPE:
// Evaluates compatible Series EE photographs (issue dates >= March 1985).
// Pre-1985 bonds (Series E and early Series EE) were issued without MICR lines.
// Operates as an independent, non-destructive secondary pass to corroborate optical candidates.

import CoreGraphics
import Foundation
import Vision

public struct MICRLineAnalysis: Codable, Equatable {
    public let isCompatibleEra: Bool
    public let micrLineFound: Bool
    public let routingNumberMatched: Bool
    public let routingNumber: String?
    public let extractedSerialDigits: String?
    public let confidence: Float
    public let maskedSummary: String
    public let diagnosticNotes: [String]

    public static let notApplicable = MICRLineAnalysis(
        isCompatibleEra: false,
        micrLineFound: false,
        routingNumberMatched: false,
        routingNumber: nil,
        extractedSerialDigits: nil,
        confidence: 0.0,
        maskedSummary: "Not applicable (Pre-March 1985 era or non-EE series)",
        diagnosticNotes: ["MICR lines were introduced in March 1985 for Series EE."]
    )
}

public enum MICRLineDetector {
    /// Standard Treasury / Bureau of the Fiscal Service savings bond routing transit number.
    public static let treasuryRoutingNumber = "000090007"

    /// Determine if the bond's issue era is historically compatible with MICR line printing (March 1985+).
    public static func isCompatibleEra(series: String, month: String = "", year: String = "") -> Bool {
        let cleanSeries = series.uppercased().trimmingCharacters(in: .whitespaces)
        guard cleanSeries == "EE" || cleanSeries == "I" else { return false }

        guard let y = Int(year), year.count == 4 else {
            // If year is unknown, attempt detection if series is EE
            return cleanSeries == "EE" || cleanSeries == "I"
        }

        if y > 1985 {
            return true
        }
        if y < 1985 {
            return false
        }

        // Year 1985: Introduced in March 1985
        if let m = Int(month), m >= 3 {
            return true
        }
        if month.isEmpty {
            return true
        } // Assume possible compatibility if month unread
        return false
    }

    /// Crop the bottom clear band of a physical bond image (normalized y: 0.0 to 0.14).
    public static func cropBottomBand(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 100, height > 100 else { return nil }

        // Bottom 14% of the image (accounting for CoreGraphics / Vision coordinate orientation)
        let bandHeight = max(24, Int(Double(height) * 0.14))
        let cropY = height - bandHeight
        let cropRect = CGRect(x: 0, y: cropY, width: width, height: bandHeight)
        return image.cropping(to: cropRect)
    }

    /// Analyze a candidate image for experimental MICR-line recognition.
    public static func detectMICR(
        in image: CGImage,
        series: String = "EE",
        month: String = "",
        year: String = ""
    ) -> MICRLineAnalysis {
        guard isCompatibleEra(series: series, month: month, year: year) else {
            return MICRLineAnalysis.notApplicable
        }

        guard let bottomBand = cropBottomBand(image) else {
            return MICRLineAnalysis(
                isCompatibleEra: true,
                micrLineFound: false,
                routingNumberMatched: false,
                routingNumber: nil,
                extractedSerialDigits: nil,
                confidence: 0.0,
                maskedSummary: "Could not isolate bottom band for MICR inspection",
                diagnosticNotes: ["Bottom margin crop failed."]
            )
        }

        // Run OCR on the bottom band
        let lines = textOCR(bottomBand, fast: false, minimumTextHeight: 0.015, alternateCount: 3)
        guard !lines.isEmpty else {
            return MICRLineAnalysis(
                isCompatibleEra: true,
                micrLineFound: false,
                routingNumberMatched: false,
                routingNumber: nil,
                extractedSerialDigits: nil,
                confidence: 0.0,
                maskedSummary: "No text observed in bottom clear band",
                diagnosticNotes: ["Zero OCR observations in bottom band."]
            )
        }

        var notes: [String] = []
        var routingMatched = false
        var detectedRouting: String?
        var extractedDigits: String?
        var maxConf: Float = 0.0

        for line in lines {
            maxConf = max(maxConf, line.confidence)
            let raw = line.text.uppercased()

            // Normalize OCR confusions common in E-13B fonts (O to 0, I to 1, transit symbols)
            let cleaned = raw.replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "o", with: "0")
                .replacingOccurrences(of: "D", with: "0")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "⑆", with: "")

            // Check for Treasury Routing Transit number: "000090007"
            if cleaned.contains("000090007") || cleaned.contains("00090007") || cleaned.contains("00009007") {
                routingMatched = true
                detectedRouting = treasuryRoutingNumber
                notes.append("Fiscal Service Routing Transit Number (000090007) verified in MICR band.")
            }

            // Extract candidate 10-digit serial sequences from the band
            let digitSequences = regexMatches("[0-9]{9,10}", in: cleaned)
            for seq in digitSequences where seq != treasuryRoutingNumber {
                if extractedDigits == nil || seq.count > (extractedDigits?.count ?? 0) {
                    extractedDigits = seq
                }
            }
        }

        let micrFound = routingMatched || extractedDigits != nil
        let summaryText: String
        if routingMatched && extractedDigits != nil {
            summaryText = "MICR line verified: Routing \(treasuryRoutingNumber), Serial \(maskSerial("EE" + extractedDigits! + "EE"))"
        } else if routingMatched {
            summaryText = "MICR routing verified: \(treasuryRoutingNumber)"
        } else if let digits = extractedDigits {
            summaryText = "MICR candidate digits observed: \(maskSerial("EE" + digits + "EE"))"
        } else {
            summaryText = "No valid MICR format detected in bottom band"
        }

        return MICRLineAnalysis(
            isCompatibleEra: true,
            micrLineFound: micrFound,
            routingNumberMatched: routingMatched,
            routingNumber: detectedRouting,
            extractedSerialDigits: extractedDigits,
            confidence: micrFound ? maxConf : 0.0,
            maskedSummary: summaryText,
            diagnosticNotes: notes
        )
    }
}
