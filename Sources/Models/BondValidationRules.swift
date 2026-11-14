// Sources/Models/BondValidationRules.swift
// Bond Scanner — Evidence-Based Physical U.S. Savings Bond Validation Engine
//
// AUTHORITATIVE STATUTORY & REGULATORY FOUNDATIONS:
// 1. 31 CFR Part 316 — Offering of United States Savings Bonds, Series E (May 1, 1941 – June 30, 1980)
// 2. 31 CFR Part 321 — Payments by Banks and Other Paying Agents of U.S. Savings Bonds
// 3. 31 CFR Part 351 — Offering of United States Savings Bonds, Series EE (Jan 1, 1980 – Dec 31, 2011 on paper; May 2003 – present electronic)
// 4. 31 CFR Part 353 — Regulations Governing United States Savings Bonds, Series EE and HH
// 5. 31 CFR Part 359 — Offering of United States Savings Bonds, Series I (Sept 1, 1998 – Dec 31, 2024 on paper; Oct 2002 – present electronic)
// 6. 31 CFR Part 360 — Regulations Governing United States Savings Bonds, Series I
// 7. Federal Reserve Bank Operating Circular No. 4 & Fiscal Service Manual for Image-Enabled Redemption
// 8. U.S. Department of the Treasury, Bureau of the Fiscal Service / Bureau of the Public Debt
//    Savings Bond Processing Specifications & Table of Redemption Values.
//
// PRIMARY TEST SCOPE: Issue dates 1965–2010.
// PUBLIC APP ARCHITECTURE: Full historically valid dates (Series A-D, E, EE, I, H, HH).

import Foundation
import CoreGraphics

// MARK: - Privacy-Safe Masking (Rule 9)

/// Mask private serial numbers for logs, telemetry, test failures, and diagnostics.
/// Preserves prefix letter and series suffix while masking all numeric digits.
/// Example: "C1234567890EE" -> "C••••••••••EE".
public func maskSerial(_ raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !s.isEmpty else { return "[EMPTY-SERIAL]" }
    guard s.count > 3 else { return String(repeating: "•", count: s.count) }

    var prefixEnd = 0
    let chars = Array(s)
    while prefixEnd < chars.count && chars[prefixEnd].isLetter {
        prefixEnd += 1
        // Prefixes are at most 2 letters (typically 1)
        if prefixEnd >= 2 && !s.hasPrefix("EE") { break }
        if s.hasPrefix("EE") && prefixEnd >= 2 { break }
    }
    if prefixEnd == 0 { prefixEnd = 1 }

    var suffixStart = chars.count
    if s.hasSuffix("EE") || s.hasSuffix("HH") {
        suffixStart = chars.count - 2
    } else if s.hasSuffix("E") || s.hasSuffix("I") || s.hasSuffix("H") {
        suffixStart = chars.count - 1
    }

    if prefixEnd >= suffixStart {
        // Fallback for non-standard formats: mask middle characters
        return String(chars.prefix(1)) + String(repeating: "•", count: max(1, chars.count - 2)) + String(chars.suffix(1))
    }

    let prefixStr = String(chars[0..<prefixEnd])
    let suffixStr = String(chars[suffixStart..<chars.count])
    let maskedDigits = String(repeating: "•", count: suffixStart - prefixEnd)
    return prefixStr + maskedDigits + suffixStr
}

// MARK: - Series Definitions & Historical Eras

public enum BondSeries: Equatable, Hashable {
    case E
    case EE
    case I
    case H
    case HH
    case other(String)

    public init(fromString string: String) {
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch clean {
        case "E": self = .E
        case "EE": self = .EE
        case "I": self = .I
        case "H": self = .H
        case "HH": self = .HH
        default: self = .other(clean)
        }
    }

    public var canonicalName: String {
        switch self {
        case .E: return "E"
        case .EE: return "EE"
        case .I: return "I"
        case .H: return "H"
        case .HH: return "HH"
        case .other(let name): return name
        }
    }

    /// Historically valid offering era for series (calendar years).
    /// Series E: May 1, 1941 to June 30, 1980 (31 CFR § 316.1)
    /// Series EE: January 1, 1980 to December 31, 2011 (paper) (31 CFR § 351.1); May 2003 – present (electronic)
    /// Series I: September 1, 1998 to December 31, 2024 (paper) (31 CFR § 359.1); October 2002 – present (electronic)
    /// Series H: June 1, 1952 to December 31, 1979
    /// Series HH: January 1, 1980 to August 31, 2004
    public var historicalOfferingYears: ClosedRange<Int> {
        switch self {
        case .E: return 1941...1980
        case .EE: return 1980...2011
        case .I: return 1998...2026 // Active issue era through current year
        case .H: return 1952...1979
        case .HH: return 1980...2004
        case .other: return 1935...2026
        }
    }

    /// Offering era specifically for physical paper bonds.
    public var paperOfferingYears: ClosedRange<Int> {
        switch self {
        case .E: return 1941...1980 // Discontinued June 30, 1980
        case .EE: return 1980...2011 // General over-the-counter paper ended Dec 31, 2011
        case .I: return 1998...2024 // OTC paper ended Dec 31, 2011; IRS tax refund paper ended Dec 31, 2024
        case .H: return 1952...1979
        case .HH: return 1980...2004
        case .other: return 1935...2026
        }
    }

    /// Offering era for electronic book-entry bonds (TreasuryDirect).
    public var electronicOfferingYears: ClosedRange<Int>? {
        switch self {
        case .EE: return 2003...2026 // Active today on TreasuryDirect
        case .I: return 2002...2026  // Active today on TreasuryDirect
        default: return nil         // Series E, H, HH were never offered as electronic bonds
        }
    }

    /// Expected trailing serial suffix for the physical bond series.
    public var expectedSerialSuffix: String {
        switch self {
        case .E: return "E"
        case .EE: return "EE"
        case .I: return "I"
        case .H: return "H"
        case .HH: return "HH"
        case .other: return ""
        }
    }

    /// Plausible numeric length between prefix and suffix.
    /// Series E: 8, 9, or 10 digits (early eras 8, mid-era 9, high-volume denominations reaching 10).
    /// Series EE: 10 digits for standard paper certificates.
    /// Series I: 10 digits.
    public var plausibleNumericLengths: ClosedRange<Int> {
        switch self {
        case .E: return 8...10
        case .EE: return 10...10
        case .I: return 10...10
        case .H, .HH: return 8...10
        case .other: return 7...11
        }
    }

    /// Authoritative denominations issued on physical paper for this series.
    public var standardPaperDenominations: [String] {
        switch self {
        case .E:
            // $10 was a special 1944 WWII "Soldier's Bond" issued to military personnel
            return ["10", "25", "50", "75", "100", "200", "500", "1000", "5000", "10000"]
        case .EE:
            // Note: $25 was never issued as a standard paper Series EE bond ($50 was lowest paper EE).
            return ["50", "75", "100", "200", "500", "1000", "5000", "10000"]
        case .I:
            return ["50", "75", "100", "200", "500", "1000", "5000", "10000"]
        case .H, .HH:
            return ["500", "1000", "5000", "10000"]
        case .other:
            return ["10", "25", "50", "75", "100", "200", "500", "1000", "5000", "10000"]
        }
    }
}

// MARK: - Authoritative Series-Specific Denomination-Prefix Tables (Requirement 1)

public enum BondValidationRules {

    /// Bureau of the Fiscal Service & Bureau of Engraving and Printing denomination prefix mapping.
    /// Roman numerals & single-character abbreviations:
    /// - $10: X (Roman numeral 10, 1944 Soldier's Bond)
    /// - $25: Q (Quarter)
    /// - $50: L (Roman numeral 50)
    /// - $75: K (Introduced May 1964)
    /// - $100: C (Roman numeral 100)
    /// - $200: R (Roosevelt Memorial, introduced 1945)
    /// - $500: D (Roman numeral 500)
    /// - $1,000: M (Roman numeral 1,000)
    /// - $5,000: V (Roman numeral 5,000)
    /// - $10,000: X (Roman numeral 10,000; shared with rare $10, distinguished by denomination)
    public static func expectedPrefixes(forDenomination denom: String, series: BondSeries) -> [Character] {
        let cleanDenom = denom.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        switch series {
        case .E:
            switch cleanDenom {
            case "10": return ["X"]
            case "25": return ["Q"]
            case "50": return ["L"]
            case "75": return ["K"]
            case "100": return ["C"]
            case "200": return ["R"]
            case "500": return ["D"]
            case "1000": return ["M"]
            case "5000": return ["V"]
            case "10000": return ["X"]
            default: return []
            }
        case .EE:
            switch cleanDenom {
            case "50": return ["L"]
            case "75": return ["K"]
            case "100": return ["C"]
            case "200": return ["R"]
            case "500": return ["D"]
            case "1000": return ["M"]
            case "5000": return ["V"]
            case "10000": return ["X"]
            case "25":
                // $25 paper Series EE did not exist in standard issuance; if encountered as experimental or test, Q is plausible
                return ["Q"]
            default: return []
            }
        case .I:
            // Series I paper bonds use denomination-specific prefixes (matching standard Treasury
            // denomination codes: L=$50, K=$75, C=$100, R=$200, D=$500, M=$1000, V=$5000, X=$10000),
            // and can also carry 'I' as a series designator prefix.
            switch cleanDenom {
            case "50": return ["L", "I"]
            case "75": return ["K", "I"]
            case "100": return ["C", "I"]
            case "200": return ["R", "I"]
            case "500": return ["D", "I"]
            case "1000": return ["M", "I"]
            case "5000": return ["V", "I"]
            case "10000": return ["X", "I"]
            default: return ["I"]
            }
        case .H, .HH:
            switch cleanDenom {
            case "500": return ["D"]
            case "1000": return ["M"]
            case "5000": return ["V"]
            case "10000": return ["X"]
            default: return []
            }
        case .other:
            switch cleanDenom {
            case "25": return ["Q"]
            case "50": return ["L"]
            case "75": return ["K"]
            case "100": return ["C"]
            case "200": return ["R"]
            case "500": return ["D"]
            case "1000": return ["M"]
            case "5000": return ["V"]
            case "10000": return ["X"]
            default: return []
            }
        }
    }

    /// Inverse mapping: Expected denominations for a given serial prefix letter.
    public static func expectedDenominations(forPrefix prefix: Character, series: BondSeries) -> [String] {
        let p = Character(prefix.uppercased())
        switch series {
        case .E:
            switch p {
            case "Q": return ["25"]
            case "L": return ["50"]
            case "K": return ["75"]
            case "C": return ["100"]
            case "R": return ["200"]
            case "D": return ["500"]
            case "M": return ["1000"]
            case "V": return ["5000"]
            case "X": return ["10000", "10"]
            default: return []
            }
        case .EE:
            switch p {
            case "L": return ["50"]
            case "K": return ["75"]
            case "C": return ["100"]
            case "R": return ["200"]
            case "D": return ["500"]
            case "M": return ["1000"]
            case "V": return ["5000"]
            case "X": return ["10000"]
            case "Q": return ["25"] // Non-standard paper denomination
            default: return []
            }
        case .I:
            switch p {
            case "L": return ["50"]
            case "K": return ["75"]
            case "C": return ["100"]
            case "R": return ["200"]
            case "D": return ["500"]
            case "M": return ["1000"]
            case "V": return ["5000"]
            case "X": return ["10000"]
            case "I": return ["50", "75", "100", "200", "500", "1000", "5000", "10000"]
            default: return []
            }
        case .H, .HH:
            switch p {
            case "D": return ["500"]
            case "M": return ["1000"]
            case "V": return ["5000"]
            case "X": return ["10000"]
            default: return []
            }
        case .other:
            switch p {
            case "Q": return ["25"]
            case "L": return ["50"]
            case "K": return ["75"]
            case "C": return ["100"]
            case "R": return ["200"]
            case "D": return ["500"]
            case "M": return ["1000"]
            case "V": return ["5000"]
            case "X": return ["10000"]
            default: return []
            }
        }
    }
}

// MARK: - Validation Separation Model (Requirement 2 & 8)

/// 1. Syntactic Serial Validation Result
public struct SyntacticSerialResult: Codable, Equatable {
    public let isValid: Bool
    public let normalizedSerial: String
    public let prefix: String
    public let digits: String
    public let suffix: String
    public let failureReason: String?

    public init(isValid: Bool, normalizedSerial: String, prefix: String, digits: String, suffix: String, failureReason: String? = nil) {
        self.isValid = isValid
        self.normalizedSerial = normalizedSerial
        self.prefix = prefix
        self.digits = digits
        self.suffix = suffix
        self.failureReason = failureReason
    }
}

/// 2. Prefix / Denomination Consistency Result
public struct PrefixDenominationConsistencyResult: Codable, Equatable {
    public enum Status: String, Codable, Equatable {
        case consistent
        case warning
        case inconsistent
        case indeterminate
    }

    public let status: Status
    public let expectedPrefixes: [String]
    public let expectedDenominations: [String]
    public let message: String?
}

/// 3. Series / Issue Date Consistency Result
public struct SeriesIssueDateConsistencyResult: Codable, Equatable {
    public enum Status: String, Codable, Equatable {
        case consistent
        case warning
        case inconsistent
        case indeterminate
    }

    public let status: Status
    public let validYearRange: String?
    public let message: String?
}

/// 4. OCR Confidence Evaluation
public struct OCRConfidenceEvaluation: Codable, Equatable {
    public enum Level: String, Codable, Equatable {
        case high
        case medium
        case uncertain
        case none
    }

    public let overallLevel: Level
    public let fieldConfidence: [String: String]
    public let score: Double
    public let passAgreementCount: Int
    public let notes: [String]
}

/// 5. User-Confirmed Fields State (Requirement 5)
/// User-confirmed fields must NEVER be silently replaced or overwritten.
public struct UserConfirmationState: Codable, Equatable {
    public var confirmedFields: [String]

    public init(confirmedFields: [String] = []) {
        self.confirmedFields = confirmedFields
    }

    public func isConfirmed(_ field: String) -> Bool {
        return confirmedFields.contains(field)
    }

    public mutating func confirm(_ field: String) {
        if !confirmedFields.contains(field) {
            confirmedFields.append(field)
        }
    }

    public mutating func unconfirm(_ field: String) {
        confirmedFields.removeAll { $0 == field }
    }
}

/// 6. Treasury Verification Status (Requirement 2 & 10)
/// Live Treasury verification is not locally available offline.
public struct TreasuryVerificationStatus: Codable, Equatable {
    public let isLocallyAvailable: Bool
    public let statusDescription: String

    public static let notLocallyAvailable = TreasuryVerificationStatus(
        isLocallyAvailable: false,
        statusDescription: "Treasury online verification not locally available (offline validation only; requires Bureau of the Fiscal Service / TreasuryDirect records)."
    )
}

/// Composite Bond Validation Report separating all validation facets
public struct BondValidationReport: Codable, Equatable {
    public let syntacticSerial: SyntacticSerialResult
    public let prefixDenominationConsistency: PrefixDenominationConsistencyResult
    public let seriesDateConsistency: SeriesIssueDateConsistencyResult
    public let ocrConfidence: OCRConfidenceEvaluation
    public let userConfirmation: UserConfirmationState
    public let treasuryVerification: TreasuryVerificationStatus
    public let hardErrors: [String]
    public let warnings: [String]

    public var isValid: Bool {
        return hardErrors.isEmpty && syntacticSerial.isValid && seriesDateConsistency.status != .inconsistent
    }
}

// MARK: - Validation Engine Implementation

extension BondValidationRules {

    /// Validate serial syntax strictly without inventing missing digits.
    public static func validateSyntacticSerial(_ rawSerial: String, expectedSeries: String = "") -> SyntacticSerialResult {
        let norm = normalizeSerial(rawSerial)
        guard !norm.isEmpty else {
            return SyntacticSerialResult(isValid: false, normalizedSerial: "", prefix: "", digits: "", suffix: "", failureReason: "Empty serial number")
        }

        let chars = Array(norm)
        var start = 0
        while start < chars.count && chars[start].isLetter { start += 1 }
        guard start > 0 else {
            return SyntacticSerialResult(isValid: false, normalizedSerial: norm, prefix: "", digits: "", suffix: "", failureReason: "Missing letter prefix in serial '\(maskSerial(norm))'")
        }

        var end = chars.count
        if end > start && chars[end - 1] == "E" {
            end -= 1
            if end > start && chars[end - 1] == "E" { end -= 1 }
        } else if end > start && (chars[end - 1] == "I" || chars[end - 1] == "H") {
            end -= 1
            if end > start && chars[end - 1] == "H" { end -= 1 }
        }

        let prefix = String(chars[0..<start])
        let suffix = String(chars[end..<chars.count])
        let digits = String(chars[start..<end])

        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else {
            return SyntacticSerialResult(isValid: false, normalizedSerial: norm, prefix: prefix, digits: digits, suffix: suffix, failureReason: "Non-numeric characters in serial body '\(maskSerial(norm))'")
        }

        let series = BondSeries(fromString: expectedSeries)
        let allowedLengths: ClosedRange<Int>
        switch series {
        case .E: allowedLengths = 8...10
        case .EE, .I: allowedLengths = 10...10
        default: allowedLengths = 8...10
        }

        // Validate suffix matches expected series if series is provided
        if !expectedSeries.isEmpty {
            let expectedSuffix = series.expectedSerialSuffix
            if !expectedSuffix.isEmpty && suffix != expectedSuffix {
                let reason = "Serial suffix '\(suffix)' contradicts specified Series \(series.canonicalName) (expected suffix '\(expectedSuffix)') in serial '\(maskSerial(norm))'"
                return SyntacticSerialResult(isValid: false, normalizedSerial: norm, prefix: prefix, digits: digits, suffix: suffix, failureReason: reason)
            }
        }

        if !allowedLengths.contains(digits.count) {
            let reason = "Invalid numeric length (\(digits.count) digits; expected \(allowedLengths.lowerBound)–\(allowedLengths.upperBound)) in serial '\(maskSerial(norm))'. Missing digits are never invented."
            return SyntacticSerialResult(isValid: false, normalizedSerial: norm, prefix: prefix, digits: digits, suffix: suffix, failureReason: reason)
        }

        return SyntacticSerialResult(isValid: true, normalizedSerial: norm, prefix: prefix, digits: digits, suffix: suffix)
    }

    /// Validate prefix / denomination consistency.
    /// Distinguishes between hard authoritative mismatches and uncertain warnings (Requirement 8).
    public static func validatePrefixDenomination(prefix: String, denomination: String, series: String) -> PrefixDenominationConsistencyResult {
        let cleanDenom = denomination.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        let p = prefix.trimmingCharacters(in: .whitespaces).uppercased()
        let bSeries = BondSeries(fromString: series)

        guard !p.isEmpty, let prefixChar = p.first else {
            return PrefixDenominationConsistencyResult(status: .indeterminate, expectedPrefixes: [], expectedDenominations: [], message: "Missing serial prefix")
        }
        guard !cleanDenom.isEmpty else {
            let expectedDenoms = expectedDenominations(forPrefix: prefixChar, series: bSeries)
            return PrefixDenominationConsistencyResult(status: .indeterminate, expectedPrefixes: [String(prefixChar)], expectedDenominations: expectedDenoms, message: "Missing denomination for prefix comparison")
        }

        // Check if denomination itself is supported for series
        if bSeries == .EE && cleanDenom == "25" {
            return PrefixDenominationConsistencyResult(
                status: .warning,
                expectedPrefixes: ["L", "C", "D"],
                expectedDenominations: bSeries.standardPaperDenominations,
                message: "$25 was not issued as standard paper Series EE (standard paper EE denominations are $50–$10,000)"
            )
        }

        let expectedPrefixList = expectedPrefixes(forDenomination: cleanDenom, series: bSeries).map(String.init)
        let expectedDenomList = expectedDenominations(forPrefix: prefixChar, series: bSeries)

        if expectedPrefixList.contains(String(prefixChar)) {
            return PrefixDenominationConsistencyResult(
                status: .consistent,
                expectedPrefixes: expectedPrefixList,
                expectedDenominations: expectedDenomList,
                message: "Prefix '\(prefixChar)' matches $\(cleanDenom) denomination for Series \(bSeries.canonicalName)"
            )
        }

        // If prefix is documented for a different denomination in the same series, treat as warning/inconsistency
        if !expectedDenomList.isEmpty {
            let message = "Serial prefix '\(prefixChar)' typically denotes $\(expectedDenomList.joined(separator: " or $")), but denomination was read as $\(cleanDenom)"
            return PrefixDenominationConsistencyResult(
                status: .warning,
                expectedPrefixes: expectedPrefixList,
                expectedDenominations: expectedDenomList,
                message: message
            )
        }

        // Unknown prefix letter for this series: warning (reissues / obscure batches exist in Treasury history)
        return PrefixDenominationConsistencyResult(
            status: .warning,
            expectedPrefixes: expectedPrefixList,
            expectedDenominations: [],
            message: "Uncommon or undocumented serial prefix '\(prefixChar)' for Series \(bSeries.canonicalName)"
        )
    }

    /// Validate Series / Issue Date consistency.
    /// Strict enforcement for authoritatively closed offering eras; warnings for boundaries (Requirement 8).
    public static func validateSeriesIssueDate(series: String, month: String, year: String) -> SeriesIssueDateConsistencyResult {
        let bSeries = BondSeries(fromString: series)
        guard let y = Int(year), year.count == 4 else {
            return SeriesIssueDateConsistencyResult(status: .indeterminate, validYearRange: nil, message: "Missing or invalid 4-digit issue year")
        }

        let validRange = bSeries.historicalOfferingYears
        let rangeStr = "\(validRange.lowerBound)–\(validRange.upperBound)"

        // Primary test scope: 1965–2010. Public app architecture: full historical dates.
        switch bSeries {
        case .E:
            if y < 1941 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Series E bonds were not issued prior to May 1, 1941 (issue year: \(year))"
                )
            }
            if y == 1941 {
                if let mStr = monthNumber(month), let m = Int(mStr), m < 5 {
                    return SeriesIssueDateConsistencyResult(
                        status: .inconsistent,
                        validYearRange: rangeStr,
                        message: "Series E bonds were first issued on May 1, 1941; cannot be issued in \(month)/\(year)"
                    )
                }
                return SeriesIssueDateConsistencyResult(
                    status: .consistent,
                    validYearRange: rangeStr,
                    message: "Valid Series E inaugural issue year (May–Dec 1941)"
                )
            }
            if y > 1980 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Series E bonds were discontinued on June 30, 1980; cannot be issued in \(year)"
                )
            }
            if y == 1980 {
                if let mStr = monthNumber(month), let m = Int(mStr) {
                    if m > 6 {
                        return SeriesIssueDateConsistencyResult(
                            status: .inconsistent,
                            validYearRange: rangeStr,
                            message: "Series E bonds were discontinued on June 30, 1980; cannot be issued in \(month)/\(year)"
                        )
                    }
                    return SeriesIssueDateConsistencyResult(
                        status: .consistent,
                        validYearRange: rangeStr,
                        message: "Series E issue in 1980 (month \(mStr); final offering ended June 30, 1980)"
                    )
                }
                return SeriesIssueDateConsistencyResult(
                    status: .warning,
                    validYearRange: rangeStr,
                    message: "Series E issue in 1980; month unread. Final offering ended June 30, 1980"
                )
            }
            return SeriesIssueDateConsistencyResult(status: .consistent, validYearRange: rangeStr, message: "Issue year \(year) is valid for Series E (\(rangeStr))")

        case .EE:
            if y < 1980 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Series EE bonds were first introduced on January 1, 1980; cannot be issued in \(year)"
                )
            }
            if y > 2011 {
                return SeriesIssueDateConsistencyResult(
                    status: .warning,
                    validYearRange: rangeStr,
                    message: "Physical paper Series EE issuance ended on December 31, 2011 (issue year: \(year); electronic EE bonds continue on TreasuryDirect)"
                )
            }
            return SeriesIssueDateConsistencyResult(status: .consistent, validYearRange: rangeStr, message: "Issue year \(year) is valid for paper Series EE (\(rangeStr))")

        case .I:
            if y < 1998 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Series I bonds were first introduced on September 1, 1998; cannot be issued in \(year)"
                )
            }
            if y == 1998 {
                if let mStr = monthNumber(month), let m = Int(mStr), m < 9 {
                    return SeriesIssueDateConsistencyResult(
                        status: .inconsistent,
                        validYearRange: rangeStr,
                        message: "Series I bonds were first introduced on September 1, 1998; cannot be issued in \(month)/\(year)"
                    )
                }
                return SeriesIssueDateConsistencyResult(
                    status: .consistent,
                    validYearRange: rangeStr,
                    message: "Valid inaugural issue year for Series I (September–December 1998)"
                )
            }
            if y > 2026 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Issue year \(year) is in the future"
                )
            }
            if y > 2024 {
                return SeriesIssueDateConsistencyResult(
                    status: .warning,
                    validYearRange: rangeStr,
                    message: "Physical paper Series I bond sales ended completely on December 31, 2024 (issue year: \(year); electronic I bonds continue on TreasuryDirect)"
                )
            }
            if y > 2011 {
                // 2012-2024: Over-the-counter paper ended Dec 31, 2011; available on paper exclusively via IRS tax refund (Form 8888)
                return SeriesIssueDateConsistencyResult(
                    status: .consistent,
                    validYearRange: rangeStr,
                    message: "Paper Series I issue year \(year) (issued via IRS tax refund purchase, 2010–2024; general OTC paper sales ended Dec 31, 2011)"
                )
            }
            return SeriesIssueDateConsistencyResult(status: .consistent, validYearRange: rangeStr, message: "Issue year \(year) is valid for paper Series I (\(rangeStr))")

        case .H:
            if y < 1952 || y > 1979 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Series H bonds were only offered between June 1, 1952 and December 31, 1979 (issue year: \(year))"
                )
            }
            if y == 1952 {
                if let mStr = monthNumber(month), let m = Int(mStr), m < 6 {
                    return SeriesIssueDateConsistencyResult(
                        status: .inconsistent,
                        validYearRange: rangeStr,
                        message: "Series H bonds were first introduced on June 1, 1952; cannot be issued in \(month)/\(year)"
                    )
                }
            }
            return SeriesIssueDateConsistencyResult(status: .consistent, validYearRange: rangeStr, message: "Valid Series H issue year")

        case .HH:
            if y < 1980 || y > 2004 {
                return SeriesIssueDateConsistencyResult(
                    status: .inconsistent,
                    validYearRange: rangeStr,
                    message: "Series HH bonds were only offered between January 1, 1980 and August 31, 2004 (issue year: \(year))"
                )
            }
            if y == 2004 {
                if let mStr = monthNumber(month), let m = Int(mStr), m > 8 {
                    return SeriesIssueDateConsistencyResult(
                        status: .inconsistent,
                        validYearRange: rangeStr,
                        message: "Series HH bond offerings ended on August 31, 2004; cannot be issued in \(month)/\(year)"
                    )
                }
            }
            return SeriesIssueDateConsistencyResult(status: .consistent, validYearRange: rangeStr, message: "Valid Series HH issue year")

        case .other:
            return SeriesIssueDateConsistencyResult(status: .warning, validYearRange: rangeStr, message: "Unrecognized bond series; issue date cannot be verified")
        }
    }

    /// Full evidence-based validation evaluating all separate dimensions.
    static func validateBond(record: BondRecord, userConfirmedFields: Set<String> = []) -> BondValidationReport {
        var hardErrors: [String] = []
        var warnings: [String] = []

        // 1. Syntactic Serial Validation
        let serialResult = validateSyntacticSerial(record.serial, expectedSeries: record.series)
        if !serialResult.isValid {
            if let reason = serialResult.failureReason {
                hardErrors.append(reason)
            } else {
                hardErrors.append("Syntactically invalid serial '\(maskSerial(record.serial))'")
            }
        }

        // 2. Prefix / Denomination Consistency
        let prefixResult = validatePrefixDenomination(prefix: serialResult.prefix, denomination: record.denomination, series: record.series)
        if prefixResult.status == .inconsistent {
            if let msg = prefixResult.message { hardErrors.append(msg) }
        } else if prefixResult.status == .warning {
            if let msg = prefixResult.message { warnings.append(msg) }
        }

        // 3. Series / Issue Date Consistency
        let dateResult = validateSeriesIssueDate(series: record.series, month: record.issueMonth, year: record.issueYear)
        if dateResult.status == .inconsistent {
            if let msg = dateResult.message { hardErrors.append(msg) }
        } else if dateResult.status == .warning {
            if let msg = dateResult.message { warnings.append(msg) }
        }

        // 4. OCR Confidence Evaluation
        let confMap = record.fieldConfidence ?? [:]
        let isHighSerial = confMap["serial"] == "high"
        let isHighDenom = confMap["denomination"] == "high"
        let isHighDate = confMap["issueDate"] == "high"

        let highCount = [isHighSerial, isHighDenom, isHighDate].filter { $0 }.count
        let overallLevel: OCRConfidenceEvaluation.Level
        if highCount >= 3 {
            overallLevel = .high
        } else if highCount >= 2 {
            overallLevel = .medium
        } else if highCount >= 1 {
            overallLevel = .uncertain
        } else {
            overallLevel = .none
        }

        let ocrEvaluation = OCRConfidenceEvaluation(
            overallLevel: overallLevel,
            fieldConfidence: confMap,
            score: Double(highCount) / 3.0,
            passAgreementCount: 1,
            notes: []
        )

        // 5. User-Confirmed Fields
        var existingConfirmed = UserConfirmationState(confirmedFields: record.userConfirmedFields ?? [])
        for field in userConfirmedFields {
            existingConfirmed.confirm(field)
        }

        // 6. Treasury Verification Status
        let treasuryStatus = TreasuryVerificationStatus.notLocallyAvailable

        return BondValidationReport(
            syntacticSerial: serialResult,
            prefixDenominationConsistency: prefixResult,
            seriesDateConsistency: dateResult,
            ocrConfidence: ocrEvaluation,
            userConfirmation: existingConfirmed,
            treasuryVerification: treasuryStatus,
            hardErrors: hardErrors,
            warnings: warnings
        )
    }
}
