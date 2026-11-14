import XCTest
@testable import BondScanner

final class BondScannerTests: XCTestCase {

    func testNormalizeSerial() {
        XCTAssertEqual(normalizeSerial("c1234567890ee"), "C1234567890EE")
        XCTAssertEqual(normalizeSerial("C 1234567890 EE"), "C1234567890EE")
        XCTAssertEqual(normalizeSerial("C123456789OEE"), "C1234567890EE") // O to 0 in numeric body
        XCTAssertEqual(normalizeSerial("q2234677197e"), "Q2234677197E")
        XCTAssertEqual(normalizeSerial(""), "")
    }

    func testValidatedSerialSeriesE() {
        // 9-digit Series E (e.g. $50 bond)
        let s9 = validatedSerial("L710124456E", series: "E")
        XCTAssertTrue(s9.isHigh)
        XCTAssertEqual(s9.value, "L710124456E")

        // 10-digit Series E (e.g. $25 bond)
        let s10 = validatedSerial("Q2234677197E", series: "E")
        XCTAssertTrue(s10.isHigh)
        XCTAssertEqual(s10.value, "Q2234677197E")

        // 8-digit Series E
        let s8 = validatedSerial("C12345678E", series: "E")
        XCTAssertTrue(s8.isHigh)
        XCTAssertEqual(s8.value, "C12345678E")

        // Leading junk character stripped
        let junk = validatedSerial("NAMEQ2234677197E", series: "E")
        XCTAssertTrue(junk.isHigh)
        XCTAssertEqual(junk.value, "Q2234677197E")
    }

    func testValidatedSerialSeriesEE() {
        let ee = validatedSerial("C1234567890EE", series: "EE")
        XCTAssertTrue(ee.isHigh)
        XCTAssertEqual(ee.value, "C1234567890EE")
    }

    func testValidatedSerialSeriesI() {
        let i = validatedSerial("I1234567890I", series: "I")
        XCTAssertTrue(i.isHigh)
        XCTAssertEqual(i.value, "I1234567890I")
    }

    func testInvalidSerialRejected() {
        let invalid = validatedSerial("12345678", series: "E")
        XCTAssertFalse(invalid.isHigh)
    }

    func testDenominationFuzzyMatching() {
        // Exact
        let exactHits = wordAmountReadings(in: "TWENTY FIVE DOLLARS", series: "E")
        XCTAssertEqual(exactHits.first?.value, "25")

        // OCR typo: TVENTYFINE DOLLARS
        let typoHits = wordAmountReadings(in: "TVENTYFINE DOLLARS", series: "E")
        XCTAssertEqual(typoHits.first?.value, "25")

        // Fifty dollars
        let fiftyHits = wordAmountReadings(in: "FIFTY DOLLARS", series: "E")
        XCTAssertEqual(fiftyHits.first?.value, "50")

        // One hundred dollars
        let hundredHits = wordAmountReadings(in: "ONE HUNDRED DOLLARS", series: "E")
        XCTAssertEqual(hundredHits.first?.value, "100")
    }

    func testMonthParsing() {
        XCTAssertEqual(monthFromName("JAN"), "01")
        XCTAssertEqual(monthFromName("FEBRUARY"), "02")
        XCTAssertEqual(monthFromName("MAR 1966"), "03")
        XCTAssertEqual(monthFromName("SETEMBER"), "09") // OCR alias
        XCTAssertEqual(monthFromName("DEC"), "12")
        XCTAssertNil(monthFromName("RULER 10"))
    }

    func testPlausibleIssueYear() {
        // Series E (1941 - 1980)
        XCTAssertTrue(isPlausibleIssueYear("1945", series: "E"))
        XCTAssertTrue(isPlausibleIssueYear("1966", series: "E"))
        XCTAssertTrue(isPlausibleIssueYear("1980", series: "E"))
        XCTAssertFalse(isPlausibleIssueYear("1930", series: "E"))
        XCTAssertFalse(isPlausibleIssueYear("1985", series: "E"))
        XCTAssertFalse(isPlausibleIssueYear("1900", series: "E"))

        // Series EE (1980 - 2026)
        XCTAssertTrue(isPlausibleIssueYear("1985", series: "EE"))
        XCTAssertTrue(isPlausibleIssueYear("2005", series: "EE"))
        XCTAssertFalse(isPlausibleIssueYear("1975", series: "EE"))
    }
}
