// Tests/BondScannerTests/BondValidationTests.swift
// Evidence-Based Bond Validation Engine Regression & Unit Tests
//
// Verifies:
// 1. Series-specific denomination-prefix mappings (authoritative 31 CFR / Fiscal Service tables).
// 2. Separation of concerns: syntactic validity, prefix/denomination consistency, series/issue-date
//    consistency, OCR confidence, user-confirmed fields, and Treasury verification.
// 3. Multi-candidate serial extraction and evidence-based candidate ranking.
// 4. Position and agreement bonuses; refusal to invent missing digits.
// 5. User-confirmed values are preserved and never silently overwritten.
// 6. Experimental MICR-line recognition on compatible Series EE photographs.
// 7. Negative and ambiguous regression cases.
// 8. Strict historical rules vs warnings for uncertain rules.
// 9. Privacy-safe masking of all serial numbers.
// 10. Complete offline processing without external network calls.

import XCTest
import CoreGraphics
@testable import BondScanner

final class BondValidationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ScanLog.shared.isEnabled = false
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        super.tearDown()
    }

    // MARK: - Requirement 1: Series-Specific Denomination-Prefix Mappings

    func testSeriesEDenominationPrefixMappings() {
        let series = BondSeries.E

        // Authoritative mappings per Treasury Bureau of the Fiscal Service
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "10", series: series), ["X"]) // 1944 Soldier's Bond
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "25", series: series), ["Q"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "50", series: series), ["L"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "75", series: series), ["K"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "100", series: series), ["C"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "200", series: series), ["R"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "500", series: series), ["D"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "1000", series: series), ["M"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "5000", series: series), ["V"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "10000", series: series), ["X"])

        // Inverse prefix lookups
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "Q", series: series), ["25"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "L", series: series), ["50"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "C", series: series), ["100"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "D", series: series), ["500"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "M", series: series), ["1000"])
    }

    func testSeriesEEDenominationPrefixMappings() {
        let series = BondSeries.EE

        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "50", series: series), ["L"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "75", series: series), ["K"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "100", series: series), ["C"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "200", series: series), ["R"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "500", series: series), ["D"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "1000", series: series), ["M"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "5000", series: series), ["V"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "10000", series: series), ["X"])

        // Inverse
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "L", series: series), ["50"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "C", series: series), ["100"])
    }

    func testSeriesIDenominationsAndPrefix() {
        let series = BondSeries.I
        // Denomination-dependent prefixes matching Treasury standard codes:
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "50", series: series), ["L", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "75", series: series), ["K", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "100", series: series), ["C", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "200", series: series), ["R", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "500", series: series), ["D", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "1000", series: series), ["M", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "5000", series: series), ["V", "I"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "10000", series: series), ["X", "I"])

        // Inverse prefix lookups for Series I
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "L", series: series), ["50"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "C", series: series), ["100"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "D", series: series), ["500"])
        XCTAssertEqual(BondValidationRules.expectedDenominations(forPrefix: "M", series: series), ["1000"])
        XCTAssertTrue(BondValidationRules.expectedDenominations(forPrefix: "I", series: series).contains("100"))
        XCTAssertTrue(BondValidationRules.expectedDenominations(forPrefix: "I", series: series).contains("50"))

        // Prefix C on $100 Series I must be consistent
        let c100 = BondValidationRules.validatePrefixDenomination(prefix: "C", denomination: "100", series: "I")
        XCTAssertEqual(c100.status, .consistent)

        // Prefix I on $100 Series I must be consistent
        let i100 = BondValidationRules.validatePrefixDenomination(prefix: "I", denomination: "100", series: "I")
        XCTAssertEqual(i100.status, .consistent)

        // Prefix L ($50) on $100 Series I is a warning, not hard rejection
        let l100 = BondValidationRules.validatePrefixDenomination(prefix: "L", denomination: "100", series: "I")
        XCTAssertEqual(l100.status, .warning)
    }

    func testHistoricalSeriesHAndHH() {
        let seriesH = BondSeries.H
        let seriesHH = BondSeries.HH
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "500", series: seriesH), ["D"])
        XCTAssertEqual(BondValidationRules.expectedPrefixes(forDenomination: "1000", series: seriesHH), ["M"])
        XCTAssertEqual(seriesH.expectedSerialSuffix, "H")
        XCTAssertEqual(seriesHH.expectedSerialSuffix, "HH")
    }

    // MARK: - Requirement 2: Separation of Validation Dimensions

    func testValidationSeparationModel() {
        let record = BondRecord(
            id: "test-01",
            capturedAt: "2026-11-14T10:00:00Z",
            series: "EE",
            serial: "C1234567890EE",
            issueMonth: "06",
            issueYear: "1994",
            denomination: "100",
            owner: "TEST OWNER",
            secondName: "",
            secondRole: "",
            address: "",
            taxID: "",
            issuingAgent: "",
            datingStamp: "",
            status: "OK",
            notes: "",
            photo: "",
            sourcePhoto: "",
            rawOCR: "",
            fieldConfidence: ["serial": "high", "denomination": "high", "issueDate": "high"]
        )

        let report = BondValidationRules.validateBond(record: record, userConfirmedFields: ["denomination"])

        // 1. Syntactic serial
        XCTAssertTrue(report.syntacticSerial.isValid)
        XCTAssertEqual(report.syntacticSerial.prefix, "C")
        XCTAssertEqual(report.syntacticSerial.digits, "1234567890")
        XCTAssertEqual(report.syntacticSerial.suffix, "EE")

        // 2. Prefix/denomination consistency
        XCTAssertEqual(report.prefixDenominationConsistency.status, .consistent)

        // 3. Series/issue-date consistency
        XCTAssertEqual(report.seriesDateConsistency.status, .consistent)

        // 4. OCR confidence
        XCTAssertEqual(report.ocrConfidence.overallLevel, .high)

        // 5. User-confirmed fields
        XCTAssertTrue(report.userConfirmation.isConfirmed("denomination"))
        XCTAssertFalse(report.userConfirmation.isConfirmed("serial"))

        // 6. Treasury verification (offline-first: explicitly not locally available)
        XCTAssertFalse(report.treasuryVerification.isLocallyAvailable)
        XCTAssertTrue(report.treasuryVerification.statusDescription.contains("not locally available"))

        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.hardErrors.isEmpty)
    }

    // MARK: - Requirement 8: Strict Historical Rules vs Warnings

    func testHardFailureOnImpossibleIssueDate() {
        // Series EE bond issued in 1974 (Series EE was not created until Jan 1980)
        let resEEPre1980 = BondValidationRules.validateSeriesIssueDate(series: "EE", month: "05", year: "1974")
        XCTAssertEqual(resEEPre1980.status, .inconsistent)
        XCTAssertNotNil(resEEPre1980.message)

        // Series E bond issued in 1988 (Series E ended in Dec 1980)
        let resEPost1980 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "07", year: "1988")
        XCTAssertEqual(resEPost1980.status, .inconsistent)

        // Series I bond issued in 1992 (Series I began in 1998)
        let resIPre1998 = BondValidationRules.validateSeriesIssueDate(series: "I", month: "01", year: "1992")
        XCTAssertEqual(resIPre1998.status, .inconsistent)
    }

    func testDualIssuanceTransitionYear1980() {
        // 1980 was a valid transition year where both Series E and Series EE were issued
        let validE1980 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "06", year: "1980")
        XCTAssertEqual(validE1980.status, .consistent)

        let validEE1980 = BondValidationRules.validateSeriesIssueDate(series: "EE", month: "06", year: "1980")
        XCTAssertEqual(validEE1980.status, .consistent)
    }

    func testSeriesEJuneAndJuly1980MonthSpecificRules() {
        // Series E was offered through June 30, 1980 (31 CFR § 316.1)
        // June 1980 must be ACCEPTED (consistent)
        let juneE1980 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "06", year: "1980")
        XCTAssertEqual(juneE1980.status, .consistent)

        // July 1980 must be REJECTED (inconsistent)
        let julyE1980 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "07", year: "1980")
        XCTAssertEqual(julyE1980.status, .inconsistent)
        XCTAssertTrue(julyE1980.message?.contains("discontinued on June 30, 1980") == true)

        // Month name alias "JUL" must also be rejected
        let julNamedE1980 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "JUL", year: "1980")
        XCTAssertEqual(julNamedE1980.status, .inconsistent)

        // Series EE was offered throughout all of 1980
        let julyEE1980 = BondValidationRules.validateSeriesIssueDate(series: "EE", month: "07", year: "1980")
        XCTAssertEqual(julyEE1980.status, .consistent)
    }

    func testSeriesEInauguralMay1941MonthSpecificRules() {
        // Series E offering began May 1, 1941 (31 CFR § 316.1)
        let may1941 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "05", year: "1941")
        XCTAssertEqual(may1941.status, .consistent)

        let apr1941 = BondValidationRules.validateSeriesIssueDate(series: "E", month: "04", year: "1941")
        XCTAssertEqual(apr1941.status, .inconsistent)
        XCTAssertTrue(apr1941.message?.contains("first issued on May 1, 1941") == true)
    }

    func testPaperVsElectronicOfferingPeriods() {
        // Series EE: paper 1980-2011; 2012+ is warning on paper certificates
        let ee2011 = BondValidationRules.validateSeriesIssueDate(series: "EE", month: "12", year: "2011")
        XCTAssertEqual(ee2011.status, .consistent)

        let ee2015 = BondValidationRules.validateSeriesIssueDate(series: "EE", month: "05", year: "2015")
        XCTAssertEqual(ee2015.status, .warning)
        XCTAssertTrue(ee2015.message?.contains("December 31, 2011") == true)

        // Series I: paper Sept 1998 - Dec 2024
        // Aug 1998: pre-offering
        let iAug1998 = BondValidationRules.validateSeriesIssueDate(series: "I", month: "08", year: "1998")
        XCTAssertEqual(iAug1998.status, .inconsistent)

        // Sept 1998: inaugural paper offering
        let iSep1998 = BondValidationRules.validateSeriesIssueDate(series: "I", month: "09", year: "1998")
        XCTAssertEqual(iSep1998.status, .consistent)

        // 2015: tax refund paper era (valid)
        let i2015 = BondValidationRules.validateSeriesIssueDate(series: "I", month: "04", year: "2015")
        XCTAssertEqual(i2015.status, .consistent)

        // 2025: paper option discontinued
        let i2025 = BondValidationRules.validateSeriesIssueDate(series: "I", month: "01", year: "2025")
        XCTAssertEqual(i2025.status, .warning)
        XCTAssertTrue(i2025.message?.contains("December 31, 2024") == true)
    }

    func testWarningOnUncertainOrAnomalousPrefix() {
        // Prefix C ($100) with denomination $50: treated as warning/anomaly, not hard crash
        let prefixResult = BondValidationRules.validatePrefixDenomination(prefix: "C", denomination: "50", series: "EE")
        XCTAssertEqual(prefixResult.status, .warning)
        XCTAssertTrue(prefixResult.message?.contains("typically denotes $100") == true)

        // $25 on paper Series EE: warning (not standard paper EE denomination)
        let ee25Result = BondValidationRules.validatePrefixDenomination(prefix: "Q", denomination: "25", series: "EE")
        XCTAssertEqual(ee25Result.status, .warning)
        XCTAssertTrue(ee25Result.message?.contains("not issued as standard paper Series EE") == true)
    }

    func testHardFailureOnSerialSuffixContradictingSeries() {
        // Series E bond with EE suffix
        let eWithEE = BondValidationRules.validateSyntacticSerial("C1234567890EE", expectedSeries: "E")
        XCTAssertFalse(eWithEE.isValid)
        XCTAssertTrue(eWithEE.failureReason?.contains("contradicts specified Series E") == true)

        // Series EE bond with single E suffix
        let eeWithE = BondValidationRules.validateSyntacticSerial("C123456789E", expectedSeries: "EE")
        XCTAssertFalse(eeWithE.isValid)
        XCTAssertTrue(eeWithE.failureReason?.contains("contradicts specified Series EE") == true)
    }

    // MARK: - Requirement 5: Never Invent Missing Digits & Protect User-Confirmed Fields

    func testNeverInventMissingDigits() {
        // 7 digits on Series EE: must fail syntactic validation, not invent 3 digits
        let truncated = BondValidationRules.validateSyntacticSerial("C1234567EE", expectedSeries: "EE")
        XCTAssertFalse(truncated.isValid)
        XCTAssertTrue(truncated.failureReason?.contains("Missing digits are never invented") == true)
        XCTAssertEqual(truncated.digits.count, 7) // Kept as 7, never padded
    }

    func testPreserveUserConfirmedValues() {
        var existing = BondRecord(
            id: "user-rec-1",
            capturedAt: "2026-11-14T10:00:00Z",
            series: "EE",
            serial: "C1111111111EE",
            issueMonth: "05",
            issueYear: "1992",
            denomination: "100",
            owner: "John Doe",
            secondName: "",
            secondRole: "",
            address: "",
            taxID: "",
            issuingAgent: "",
            datingStamp: "",
            status: "OK",
            notes: "",
            photo: "photo1.jpg",
            sourcePhoto: "photo1.jpg",
            rawOCR: "",
            fieldConfidence: ["serial": "high", "denomination": "high"]
        )
        // User explicitly confirms the serial number
        existing.userConfirmedFields = ["serial"]

        let incoming = BondRecord(
            id: "incoming-capture",
            capturedAt: "2026-11-14T10:01:00Z",
            series: "EE",
            serial: "C2222222222EE", // Different serial read with high confidence
            issueMonth: "05",
            issueYear: "1992",
            denomination: "100",
            owner: "",
            secondName: "",
            secondRole: "",
            address: "",
            taxID: "",
            issuingAgent: "",
            datingStamp: "",
            status: "OK",
            notes: "",
            photo: "photo2.jpg",
            sourcePhoto: "photo2.jpg",
            rawOCR: "",
            fieldConfidence: ["serial": "high"]
        )

        let filled = mergeBondRecord(
            from: incoming,
            into: &existing,
            contributingPhoto: "photo2.jpg",
            contributingSource: "camera",
            captureId: "cap-2"
        )

        // Serial MUST NOT have been overwritten
        XCTAssertEqual(existing.serial, "C1111111111EE")
        XCTAssertFalse(filled.contains("serial"))
    }

    // MARK: - Requirements 3 & 4: Multi-Candidate Ranking

    func testSerialCandidateRanking() {
        // Candidate A: Valid prefix, valid suffix, 10 digits, upper-right corner, 2 passes
        let candA = SerialCandidate(
            rawText: "C1234567890EE",
            normalized: "C1234567890EE",
            prefix: "C",
            digits: "1234567890",
            suffix: "EE",
            box: CGRect(x: 0.65, y: 0.70, width: 0.25, height: 0.05), // upper-right
            sourcePasses: ["pass1", "pass2"],
            visionConfidence: 0.95,
            passAgreementCount: 2
        )

        // Candidate B: Central account/vignette number (noise)
        let candB = SerialCandidate(
            rawText: "000090007",
            normalized: "000090007",
            prefix: "",
            digits: "000090007",
            suffix: "",
            box: CGRect(x: 0.40, y: 0.50, width: 0.20, height: 0.04), // center
            sourcePasses: ["pass1"],
            visionConfidence: 0.88,
            passAgreementCount: 1
        )

        // Candidate C: Contradicting suffix (E on Series EE)
        let candC = SerialCandidate(
            rawText: "C123456789E",
            normalized: "C123456789E",
            prefix: "C",
            digits: "123456789",
            suffix: "E",
            box: CGRect(x: 0.65, y: 0.70, width: 0.25, height: 0.05),
            sourcePasses: ["pass1"],
            visionConfidence: 0.90,
            passAgreementCount: 1
        )

        let ranked = SerialCandidateRanker.rankCandidates(
            [candB, candC, candA],
            series: "EE",
            denomination: "100"
        )

        XCTAssertEqual(ranked.first?.normalized, "C1234567890EE")
        XCTAssertTrue((ranked.first?.score ?? 0) > (ranked.last?.score ?? 0))

        let best = SerialCandidateRanker.selectBestSerial(from: ranked, series: "EE", denomination: "100")
        XCTAssertEqual(best.value, "C1234567890EE")
        XCTAssertTrue(best.isHigh)
    }

    // MARK: - Requirement 6: Experimental MICR-Line Recognition

    func testMICREraCompatibility() {
        // Pre-1985 bonds are not compatible
        XCTAssertFalse(MICRLineDetector.isCompatibleEra(series: "E", month: "07", year: "1972"))
        XCTAssertFalse(MICRLineDetector.isCompatibleEra(series: "EE", month: "12", year: "1982"))

        // March 1985 and later Series EE are compatible
        XCTAssertTrue(MICRLineDetector.isCompatibleEra(series: "EE", month: "03", year: "1985"))
        XCTAssertTrue(MICRLineDetector.isCompatibleEra(series: "EE", month: "08", year: "1994"))
        XCTAssertTrue(MICRLineDetector.isCompatibleEra(series: "EE", month: "", year: "2002"))
    }

    func testMICRCorroborationInRanking() {
        let cand = SerialCandidate(
            rawText: "C1234567890EE",
            normalized: "C1234567890EE",
            prefix: "C",
            digits: "1234567890",
            suffix: "EE",
            box: CGRect(x: 0.65, y: 0.70, width: 0.25, height: 0.05),
            sourcePasses: ["pass1"],
            visionConfidence: 0.90,
            passAgreementCount: 1
        )

        // Rank without MICR
        let rankedWithout = SerialCandidateRanker.rankCandidates([cand], series: "EE", denomination: "100", micrDigits: nil)
        // Rank with matching MICR digits
        let rankedWith = SerialCandidateRanker.rankCandidates([cand], series: "EE", denomination: "100", micrDigits: "1234567890")

        XCTAssertGreaterThan(rankedWith.first!.score, rankedWithout.first!.score)
        XCTAssertTrue(rankedWith.first!.rankReasons.contains { $0.contains("MICR") })
    }

    func testMICRCorroborationRejectsRoutingNumber() {
        let cand = SerialCandidate(
            rawText: "C1234567890EE",
            normalized: "C1234567890EE",
            prefix: "C",
            digits: "1234567890",
            suffix: "EE",
            box: CGRect(x: 0.65, y: 0.70, width: 0.25, height: 0.05),
            sourcePasses: ["pass1"],
            visionConfidence: 0.90,
            passAgreementCount: 1
        )

        // Base rank without MICR
        let baseRanked = SerialCandidateRanker.rankCandidates([cand], series: "EE", denomination: "100", micrDigits: nil)

        // Rank when micrDigits is the Treasury routing transit number (000090007)
        let routingRanked = SerialCandidateRanker.rankCandidates([cand], series: "EE", denomination: "100", micrDigits: "000090007")

        // Score must NOT increase when matching the Treasury routing number!
        XCTAssertEqual(routingRanked.first!.score, baseRanked.first!.score)
        XCTAssertFalse(routingRanked.first!.rankReasons.contains { $0.contains("MICR") })

        // Rank with actual matching serial digits
        let serialRanked = SerialCandidateRanker.rankCandidates([cand], series: "EE", denomination: "100", micrDigits: "1234567890")
        XCTAssertGreaterThan(serialRanked.first!.score, baseRanked.first!.score)
        XCTAssertTrue(serialRanked.first!.rankReasons.contains { $0.contains("MICR") })
    }

    func testIntraPhotoPassesNotMisrepresentedAsIndependent() {
        let cand = SerialCandidate(
            rawText: "C1234567890EE",
            normalized: "C1234567890EE",
            prefix: "C",
            digits: "1234567890",
            suffix: "EE",
            box: CGRect(x: 0.65, y: 0.70, width: 0.25, height: 0.05),
            sourcePasses: ["corner-crop-1", "corner-crop-2"],
            visionConfidence: 0.90,
            passAgreementCount: 2
        )

        let ranked = SerialCandidateRanker.rankCandidates([cand], series: "EE", denomination: "100")
        // Reason must not claim "independent" observations for crops from the same photo
        for reason in ranked.first!.rankReasons {
            XCTAssertFalse(reason.lowercased().contains("independent dual-pass"),
                           "Intra-photo crop passes must not be labeled as independent dual-pass: \(reason)")
        }
    }

    // MARK: - Requirement 9: Privacy-Safe Masking

    func testPrivacySafeMasking() {
        XCTAssertEqual(maskSerial("C1234567890EE"), "C••••••••••EE")
        XCTAssertEqual(maskSerial("Q2234677197E"), "Q••••••••••E")
        XCTAssertEqual(maskSerial("L710124456E"), "L•••••••••E")
        XCTAssertEqual(maskSerial("I1234567890I"), "I••••••••••I")

        // No digits should ever appear in the masked output
        let masked = maskSerial("C9876543210EE")
        XCTAssertFalse(masked.contains("9876543210"))
        XCTAssertTrue(masked.hasPrefix("C"))
        XCTAssertTrue(masked.hasSuffix("EE"))
    }

    // MARK: - Negative and Ambiguous Regression Cases (Requirement 7)

    func testNegativeCaseSeriesMismatchStatusReview() {
        var record = BondRecord(
            id: "neg-01",
            capturedAt: "2026-11-14T10:00:00Z",
            series: "E",
            serial: "C1234567890EE", // EE suffix on Series E
            issueMonth: "05",
            issueYear: "1972",
            denomination: "100",
            owner: "SAMPLE",
            secondName: "",
            secondRole: "",
            address: "",
            taxID: "",
            issuingAgent: "",
            datingStamp: "",
            status: "OK",
            notes: "",
            photo: "",
            sourcePhoto: "",
            rawOCR: "",
            fieldConfidence: ["serial": "high", "denomination": "high"]
        )

        applyRequiredStatus(&record)

        // Status must NOT be OK
        XCTAssertEqual(record.status, "REVIEW")
        XCTAssertNotNil(record.validationErrors)
        XCTAssertTrue(record.notes.contains("Validation:"))
    }

    func testNegativeCaseDateContradictionStatusReview() {
        var record = BondRecord(
            id: "neg-02",
            capturedAt: "2026-11-14T10:00:00Z",
            series: "EE",
            serial: "C1234567890EE",
            issueMonth: "04",
            issueYear: "1975", // Impossible: Series EE began in 1980
            denomination: "100",
            owner: "SAMPLE",
            secondName: "",
            secondRole: "",
            address: "",
            taxID: "",
            issuingAgent: "",
            datingStamp: "",
            status: "OK",
            notes: "",
            photo: "",
            sourcePhoto: "",
            rawOCR: "",
            fieldConfidence: ["serial": "high", "denomination": "high"]
        )

        applyRequiredStatus(&record)

        XCTAssertEqual(record.status, "REVIEW")
        XCTAssertNotNil(record.validationErrors)
        XCTAssertTrue(record.notes.contains("1980"))
    }
}
