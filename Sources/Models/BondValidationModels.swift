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

import CoreGraphics
import Foundation

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
        if prefixEnd >= 2 && !s.hasPrefix("EE") {
            break
        }
        if s.hasPrefix("EE") && prefixEnd >= 2 {
            break
        }
    }
    if prefixEnd == 0 {
        prefixEnd = 1
    }

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

    let prefixStr = String(chars[0 ..< prefixEnd])
    let suffixStr = String(chars[suffixStart ..< chars.count])
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
        case let .other(name): return name
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
        case .E: return 1941 ... 1980
        case .EE: return 1980 ... 2011
        case .I: return 1998 ... 2026 // Active issue era through current year
        case .H: return 1952 ... 1979
        case .HH: return 1980 ... 2004
        case .other: return 1935 ... 2026
        }
    }

    /// Offering era specifically for physical paper bonds.
    public var paperOfferingYears: ClosedRange<Int> {
        switch self {
        case .E: return 1941 ... 1980 // Discontinued June 30, 1980
        case .EE: return 1980 ... 2011 // General over-the-counter paper ended Dec 31, 2011
        case .I: return 1998 ... 2024 // OTC paper ended Dec 31, 2011; IRS tax refund paper ended Dec 31, 2024
        case .H: return 1952 ... 1979
        case .HH: return 1980 ... 2004
        case .other: return 1935 ... 2026
        }
    }

    /// Offering era for electronic book-entry bonds (TreasuryDirect).
    public var electronicOfferingYears: ClosedRange<Int>? {
        switch self {
        case .EE: return 2003 ... 2026 // Active today on TreasuryDirect
        case .I: return 2002 ... 2026 // Active today on TreasuryDirect
        default: return nil // Series E, H, HH were never offered as electronic bonds
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
        case .E: return 8 ... 10
        case .EE: return 10 ... 10
        case .I: return 10 ... 10
        case .H, .HH: return 8 ... 10
        case .other: return 7 ... 11
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
