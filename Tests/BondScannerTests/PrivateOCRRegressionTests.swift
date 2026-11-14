import XCTest
import CoreGraphics
@testable import BondScanner

// MARK: - Manifest Models

struct FixtureManifestItem: Decodable {
    let id: String
    let filename: String
    let series: String?
    let denomination: String?
    let serial: String?
    let issueMonth: String?
    let issueYear: String?
    let datingStamp: String?
    let expectedConfidence: [String: String]?
    let expectedStatus: String?
    let scenario: String?
    let notes: String?
}

// MARK: - Quality Metrics Models (Local Privacy-Safe Reporting)

struct FixtureMetric: Codable {
    let id: String
    let scenario: String
    let durationSeconds: Double
    let seriesEvaluated: Bool
    let seriesMatch: Bool
    let denominationEvaluated: Bool
    let denominationMatch: Bool
    let serialEvaluated: Bool
    let serialMatch: Bool
    let issueDateEvaluated: Bool
    let issueDateMatch: Bool
    let statusEvaluated: Bool
    let statusMatch: Bool
    let falseHighConfidenceFields: [String]
    let isIncorrectOKStatus: Bool
    let datingStampConfused: Bool
    let seriesMisclassified: Bool
    let recordedStatus: String
}

struct OCRMetricsSummary: Codable {
    let timestamp: String
    let totalFixtures: Int
    let seriesAccuracy: Double
    let denominationAccuracy: Double
    let serialAccuracy: Double
    let issueDateAccuracy: Double
    let totalFalseHighConfidenceFields: Int
    let totalIncorrectOKStatusCount: Int
    let averageDurationSeconds: Double
    let perFixture: [FixtureMetric]
}

// MARK: - Path Resolver

enum PrivateFixturesEnvironment {
    static func projectRootURL() -> URL? {
        // 1. From #filePath (compile-time path of this test source file)
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile
            .deletingLastPathComponent() // BondScannerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
            return candidate
        }

        // 2. From PROJECT_DIR environment variable if running under Xcode/xcodebuild
        if let env = ProcessInfo.processInfo.environment["PROJECT_DIR"], !env.isEmpty {
            let envURL = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: envURL.appendingPathComponent("project.yml").path) {
                return envURL
            }
        }

        // 3. Current working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("project.yml").path) {
            return cwd
        }

        return nil
    }

    static func manifestURL() -> URL? {
        guard let root = projectRootURL() else { return nil }
        let manifest = root.appendingPathComponent("local-fixtures/manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path) ? manifest : nil
    }

    static func imageURL(for filename: String) -> URL? {
        guard let root = projectRootURL() else { return nil }
        let imagePath = root.appendingPathComponent("local-fixtures/bonds").appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: imagePath.path) ? imagePath : nil
    }

    static func reportsDirectoryURL() -> URL? {
        guard let root = projectRootURL() else { return nil }
        let reports = root.appendingPathComponent("local-fixtures/reports")
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        return reports
    }
}

// MARK: - Test Suite

final class PrivateOCRRegressionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure test runs do not write debug events to ~/BondScans/scan-debug.log
        ScanLog.shared.isEnabled = false
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = true
        super.tearDown()
    }

    private func loadManifest() throws -> [FixtureManifestItem] {
        guard let manifestURL = PrivateFixturesEnvironment.manifestURL() else {
            throw XCTSkip("Private fixtures not found: 'local-fixtures/manifest.json' does not exist. Skipping private regression tests.")
        }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let items = try decoder.decode([FixtureManifestItem].self, from: data)
        if items.isEmpty {
            throw XCTSkip("Private fixtures manifest 'local-fixtures/manifest.json' is empty. Skipping private regression tests.")
        }
        return items
    }

    // MARK: - Task 3, 4, 5: Manifest Regression & Quality Metrics Test

    func testPrivateManifestRegression() throws {
        let items = try loadManifest()

        var fixtureMetrics: [FixtureMetric] = []
        var totalSeriesEval = 0, matchedSeries = 0
        var totalDenomEval = 0, matchedDenom = 0
        var totalSerialEval = 0, matchedSerial = 0
        var totalDateEval = 0, matchedDate = 0
        var totalFalseHighConf = 0
        var totalIncorrectOK = 0
        var totalDuration = 0.0

        for item in items {
            guard let imageURL = PrivateFixturesEnvironment.imageURL(for: item.filename) else {
                throw XCTSkip("Fixture image '\(item.filename)' not found in 'local-fixtures/bonds/'. Skipping regression tests.")
            }
            guard let image = cgImageFromFile(imageURL) else {
                XCTFail("Fixture [\(item.id)]: Failed to decode image file '\(item.filename)'")
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            let ocrResult = scanImage(image)
            let duration = CFAbsoluteTimeGetCurrent() - start
            totalDuration += duration

            let record = ocrResult.record
            var falseHighConfFields: [String] = []

            // 1. Evaluate Series
            var seriesEvaluated = false
            var seriesMatch = false
            var seriesMisclassified = false
            if let expectedSeries = item.series, !expectedSeries.isEmpty {
                seriesEvaluated = true
                totalSeriesEval += 1
                if record.series.caseInsensitiveCompare(expectedSeries) == .orderedSame {
                    seriesMatch = true
                    matchedSeries += 1
                } else {
                    // Check for Series E vs EE confusion
                    if (expectedSeries == "E" && record.series == "EE") ||
                       (expectedSeries == "EE" && record.series == "E") {
                        seriesMisclassified = true
                        XCTFail("Fixture [\(item.id)]: Series classification mismatch: E vs EE confusion")
                    } else {
                        XCTFail("Fixture [\(item.id)]: Series mismatch")
                    }

                    if fieldConfidenceIsHigh(record, "series") {
                        falseHighConfFields.append("series")
                        XCTFail("Fixture [\(item.id)]: False high-confidence reading for series")
                    }
                }
            }

            // 2. Evaluate Denomination
            var denomEvaluated = false
            var denomMatch = false
            if let expectedDenom = item.denomination, !expectedDenom.isEmpty {
                denomEvaluated = true
                totalDenomEval += 1
                let normExpected = expectedDenom.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
                let normActual = record.denomination.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
                if normActual == normExpected {
                    denomMatch = true
                    matchedDenom += 1
                } else {
                    XCTFail("Fixture [\(item.id)]: Denomination mismatch")
                    if fieldConfidenceIsHigh(record, "denomination") {
                        falseHighConfFields.append("denomination")
                        XCTFail("Fixture [\(item.id)]: False high-confidence reading for denomination")
                    }
                }
            }

            // 3. Evaluate Serial
            var serialEvaluated = false
            var serialMatch = false
            if let expectedSerial = item.serial, !expectedSerial.isEmpty {
                serialEvaluated = true
                totalSerialEval += 1
                let normExpected = normalizeSerial(expectedSerial)
                let normActual = normalizeSerial(record.serial)
                if normActual == normExpected {
                    serialMatch = true
                    matchedSerial += 1
                } else {
                    // Check if selected serial looks like routing/account number (e.g. numeric without valid bond suffix)
                    if !normActual.isEmpty && (normActual.rangeOfCharacter(from: CharacterSet.letters) == nil || !normActual.hasSuffix("E")) {
                        XCTFail("Fixture [\(item.id)]: Serial mismatch (possible routing/account number confusion)")
                    } else {
                        XCTFail("Fixture [\(item.id)]: Serial mismatch")
                    }

                    if fieldConfidenceIsHigh(record, "serial") {
                        falseHighConfFields.append("serial")
                        XCTFail("Fixture [\(item.id)]: False high-confidence reading for serial")
                    }
                }
            }

            // 4. Evaluate Issue Date
            var issueDateEvaluated = false
            var issueDateMatch = false
            var datingStampConfused = false
            if (item.issueMonth != nil && !item.issueMonth!.isEmpty) || (item.issueYear != nil && !item.issueYear!.isEmpty) {
                issueDateEvaluated = true
                totalDateEval += 1
                let expMonth = item.issueMonth ?? ""
                let expYear = item.issueYear ?? ""
                let actMonth = record.issueMonth
                let actYear = record.issueYear

                let monthMatches = expMonth.isEmpty || (actMonth == expMonth || monthNumber(actMonth) == monthNumber(expMonth))
                let yearMatches = expYear.isEmpty || (actYear == expYear)

                if monthMatches && yearMatches {
                    issueDateMatch = true
                    matchedDate += 1
                } else {
                    // Check for confusion with bank dating stamp
                    if let stamp = item.datingStamp, !stamp.isEmpty {
                        let normStamp = stamp.uppercased()
                        if (!actMonth.isEmpty && normStamp.contains(actMonth)) || (!actYear.isEmpty && normStamp.contains(actYear)) {
                            datingStampConfused = true
                            XCTFail("Fixture [\(item.id)]: Issue date confused with bank dating stamp")
                        } else {
                            XCTFail("Fixture [\(item.id)]: Issue date mismatch")
                        }
                    } else {
                        XCTFail("Fixture [\(item.id)]: Issue date mismatch")
                    }

                    if fieldConfidenceIsHigh(record, "issueDate") {
                        falseHighConfFields.append("issueDate")
                        XCTFail("Fixture [\(item.id)]: False high-confidence reading for issueDate")
                    }
                }
            }

            // 5. Evaluate Expected Confidence
            if let expectedConf = item.expectedConfidence {
                for (fieldKey, expectedLevel) in expectedConf {
                    let actualLevel = record.fieldConfidence?[fieldKey] ?? "none"
                    if actualLevel.caseInsensitiveCompare(expectedLevel) != .orderedSame {
                        XCTFail("Fixture [\(item.id)]: Confidence mismatch for '\(fieldKey)'")
                    }
                }
            }

            // 6. Evaluate Status & Incorrect OK Detection
            var statusEvaluated = false
            var statusMatch = false
            var isIncorrectOK = false
            let hasAnyMismatch = (seriesEvaluated && !seriesMatch) ||
                                 (denomEvaluated && !denomMatch) ||
                                 (serialEvaluated && !serialMatch) ||
                                 (issueDateEvaluated && !issueDateMatch)

            if record.status.uppercased() == "OK" && hasAnyMismatch {
                isIncorrectOK = true
                totalIncorrectOK += 1
                XCTFail("Fixture [\(item.id)]: Incorrect OK status assigned despite field mismatches")
            }

            if let expStatus = item.expectedStatus, !expStatus.isEmpty {
                statusEvaluated = true
                if record.status.caseInsensitiveCompare(expStatus) == .orderedSame {
                    statusMatch = true
                } else {
                    XCTFail("Fixture [\(item.id)]: Status mismatch")
                }
            }

            totalFalseHighConf += falseHighConfFields.count

            fixtureMetrics.append(FixtureMetric(
                id: item.id,
                scenario: item.scenario ?? "Scenario \(item.id)",
                durationSeconds: duration,
                seriesEvaluated: seriesEvaluated,
                seriesMatch: seriesMatch,
                denominationEvaluated: denomEvaluated,
                denominationMatch: denomMatch,
                serialEvaluated: serialEvaluated,
                serialMatch: serialMatch,
                issueDateEvaluated: issueDateEvaluated,
                issueDateMatch: issueDateMatch,
                statusEvaluated: statusEvaluated,
                statusMatch: statusMatch,
                falseHighConfidenceFields: falseHighConfFields,
                isIncorrectOKStatus: isIncorrectOK,
                datingStampConfused: datingStampConfused,
                seriesMisclassified: seriesMisclassified,
                recordedStatus: record.status
            ))
        }

        // Aggregate Metrics
        let seriesAcc = totalSeriesEval > 0 ? Double(matchedSeries) / Double(totalSeriesEval) : 1.0
        let denomAcc = totalDenomEval > 0 ? Double(matchedDenom) / Double(totalDenomEval) : 1.0
        let serialAcc = totalSerialEval > 0 ? Double(matchedSerial) / Double(totalSerialEval) : 1.0
        let dateAcc = totalDateEval > 0 ? Double(matchedDate) / Double(totalDateEval) : 1.0
        let avgDuration = items.isEmpty ? 0.0 : totalDuration / Double(items.count)

        let summary = OCRMetricsSummary(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            totalFixtures: items.count,
            seriesAccuracy: seriesAcc,
            denominationAccuracy: denomAcc,
            serialAccuracy: serialAcc,
            issueDateAccuracy: dateAcc,
            totalFalseHighConfidenceFields: totalFalseHighConf,
            totalIncorrectOKStatusCount: totalIncorrectOK,
            averageDurationSeconds: avgDuration,
            perFixture: fixtureMetrics
        )

        // Write reports to local-fixtures/reports/
        try persistReports(summary)
    }

    // MARK: - Task 3 & 5: In-Memory Orientation Invariance Tests

    func testOrientationInvariance() throws {
        let items = try loadManifest()

        // Test orientations: 1 (0°), 6 (90° CW), 3 (180°), 8 (270° CW)
        let orientationExifs: [(exif: Int, desc: String)] = [
            (1, "0°"),
            (6, "90° CW"),
            (3, "180°"),
            (8, "270° CW")
        ]

        var testedImagesCount = 0

        for item in items {
            guard let imageURL = PrivateFixturesEnvironment.imageURL(for: item.filename) else {
                continue
            }
            guard let baseImage = cgImageFromFile(imageURL) else { continue }
            testedImagesCount += 1

            for (exif, desc) in orientationExifs {
                guard let rotated = rotateCG(baseImage, exif: exif) else {
                    XCTFail("Fixture [\(item.id)]: Failed in-memory rotation to \(desc)")
                    continue
                }

                let result = scanImage(rotated)
                if !result.bondTextFound && result.huntScore < 20 {
                    XCTFail("Fixture [\(item.id)]: Bond signal lost at orientation \(desc)")
                }

                // If serial is expected, check that rotation handling still captured serial
                if let expSerial = item.serial, !expSerial.isEmpty {
                    let normExpected = normalizeSerial(expSerial)
                    let normActual = normalizeSerial(result.record.serial)
                    if normActual != normExpected && fieldConfidenceIsHigh(result.record, "serial") {
                        XCTFail("Fixture [\(item.id)]: False high-confidence serial at orientation \(desc)")
                    }
                }
            }
        }

        if testedImagesCount == 0 {
            throw XCTSkip("No fixture images found in 'local-fixtures/bonds/'. Skipping orientation invariance tests.")
        }
    }

    // MARK: - Report Persistence

    private func persistReports(_ summary: OCRMetricsSummary) throws {
        guard let reportsDir = PrivateFixturesEnvironment.reportsDirectoryURL() else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(summary)

        let safeDate = summary.timestamp.replacingOccurrences(of: ":", with: "-")
        let datedJsonURL = reportsDir.appendingPathComponent("report-\(safeDate).json")
        let latestJsonURL = reportsDir.appendingPathComponent("latest.json")

        try jsonData.write(to: datedJsonURL, options: .atomic)
        try jsonData.write(to: latestJsonURL, options: .atomic)

        // Generate human-readable text report
        var text = """
        ================================================================================
        BOND SCANNER OCR QUALITY METRICS REPORT
        Timestamp: \(summary.timestamp)
        Fixtures Evaluated: \(summary.totalFixtures)
        Average Duration: \(String(format: "%.3f", summary.averageDurationSeconds))s
        ================================================================================
        AGGREGATE ACCURACY:
          Series Classification:   \(String(format: "%5.1f%%", summary.seriesAccuracy * 100))
          Denomination Accuracy:   \(String(format: "%5.1f%%", summary.denominationAccuracy * 100))
          Serial Exact Match:      \(String(format: "%5.1f%%", summary.serialAccuracy * 100))
          Issue Month/Year Match:  \(String(format: "%5.1f%%", summary.issueDateAccuracy * 100))

        CRITICAL ERROR COUNTS:
          False High-Confidence Fields: \(summary.totalFalseHighConfidenceFields)
          Incorrect OK Status Count:    \(summary.totalIncorrectOKStatusCount)
        ================================================================================
        PER-FIXTURE BREAKDOWN:

        """

        for f in summary.perFixture {
            let sMatch = f.seriesEvaluated ? (f.seriesMatch ? "PASS" : "FAIL") : "N/E"
            let dMatch = f.denominationEvaluated ? (f.denominationMatch ? "PASS" : "FAIL") : "N/E"
            let serMatch = f.serialEvaluated ? (f.serialMatch ? "PASS" : "FAIL") : "N/E"
            let dateMatch = f.issueDateEvaluated ? (f.issueDateMatch ? "PASS" : "FAIL") : "N/E"
            let statusStr = f.isIncorrectOKStatus ? "BAD_OK" : f.recordedStatus

            text += String(format: "  [%@] %-38@ | Series: %@ | Denom: %@ | Serial: %@ | Date: %@ | Status: %@ (%.2fs)\n",
                           f.id,
                           String(f.scenario.prefix(38)),
                           sMatch, dMatch, serMatch, dateMatch, statusStr, f.durationSeconds)

            if !f.falseHighConfidenceFields.isEmpty {
                text += "      * WARNING: False high-confidence in: \(f.falseHighConfidenceFields.joined(separator: ", "))\n"
            }
            if f.datingStampConfused {
                text += "      * WARNING: Issue date confused with bank dating stamp\n"
            }
            if f.seriesMisclassified {
                text += "      * WARNING: Series E / EE misclassification\n"
            }
        }

        text += "================================================================================\n"

        let datedTxtURL = reportsDir.appendingPathComponent("report-\(safeDate).txt")
        let latestTxtURL = reportsDir.appendingPathComponent("latest.txt")

        if let textData = text.data(using: .utf8) {
            try textData.write(to: datedTxtURL, options: .atomic)
            try textData.write(to: latestTxtURL, options: .atomic)
        }
    }
}
