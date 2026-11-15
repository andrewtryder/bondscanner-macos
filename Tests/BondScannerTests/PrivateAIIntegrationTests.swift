import XCTest
@testable import BondScanner

/// Opt-in hardware evaluation of the actual Apple on-device multimodal model.
/// It deliberately reads only ignored, manually verified private fixtures and writes
/// aggregate counters only.  It is not part of the mocked unit-test contract.
final class PrivateAIIntegrationTests: XCTestCase {
    func testPrivateRealPhotosWithAppleMultimodalModel() async throws {
        guard ProcessInfo.processInfo.environment["BONDSCANNER_RUN_LOCAL_AI_EVAL"] == "1" else {
            throw XCTSkip("Set BONDSCANNER_RUN_LOCAL_AI_EVAL=1 to run private hardware AI evaluation.")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, *), ReviewCoordinator.localModelAvailable else {
            throw XCTSkip("Apple on-device language model is unavailable on this Mac.")
        }
        #else
        throw XCTSkip("FoundationModels is unavailable in this SDK.")
        #endif

        let manifestURL = try XCTUnwrap(PrivateFixturesEnvironment.manifestURL(for: .real),
            "Private real-fixture manifest is required and is never committed.")
        let fixtures = try JSONDecoder().decode([FixtureManifestItem].self, from: Data(contentsOf: manifestURL))
        guard !fixtures.isEmpty else { throw XCTSkip("Private real-fixture manifest is empty.") }

        var evaluatedFields = 0, exactMatches = 0, falseSuggestions = 0, abstentions = 0
        var totalSeconds = 0.0, completed = 0
        let analyzer = LocalBondAIAnalyzer()
        for fixture in fixtures {
            guard let imageURL = PrivateFixturesEnvironment.imageURL(for: fixture.filename, dataset: .real),
                  let image = cgImageFromFile(imageURL) else { continue }
            var record = scanImage(image).record
            record.id = UUID().uuidString
            record.status = "REVIEW"
            record.revision = 1
            let expected: [String: String] = [
                "series": fixture.series ?? "", "serial": fixture.serial ?? "",
                "denomination": fixture.denomination ?? "", "issueMonth": fixture.issueMonth ?? "",
                "issueYear": fixture.issueYear ?? ""
            ]
            let start = CFAbsoluteTimeGetCurrent()
            let analysis = await analyzer.analyze(record: record, imageURL: imageURL)
            totalSeconds += CFAbsoluteTimeGetCurrent() - start
            completed += 1
            let byField = Dictionary(uniqueKeysWithValues: analysis.suggestions.map { ($0.field, $0) })
            for (field, expectedValue) in expected where !expectedValue.isEmpty {
                evaluatedFields += 1
                guard let suggestion = byField[field], !suggestion.abstained,
                      let proposed = suggestion.proposedValue else {
                    abstentions += 1
                    continue
                }
                if normalized(proposed, field: field) == normalized(expectedValue, field: field) {
                    exactMatches += 1
                } else {
                    falseSuggestions += 1
                }
            }
        }
        guard completed > 0 else { throw XCTSkip("No decodable private real photographs found.") }
        let report: [String: Any] = [
            "fixtures": completed, "evaluatedFields": evaluatedFields,
            "exactMatchFieldAccuracy": evaluatedFields == 0 ? 0 : Double(exactMatches) / Double(evaluatedFields),
            "falseSuggestions": falseSuggestions,
            "abstentionRate": evaluatedFields == 0 ? 0 : Double(abstentions) / Double(evaluatedFields),
            "totalLatencySeconds": totalSeconds,
            "meanLatencySeconds": totalSeconds / Double(completed),
            "throughputFixturesPerMinute": Double(completed) / max(totalSeconds / 60, 0.0001)
        ]
        guard let reports = PrivateFixturesEnvironment.reportsDirectoryURL(for: .real),
              JSONSerialization.isValidJSONObject(report) else { return }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reports.appendingPathComponent("latest-ai-hardware.json"), options: .atomic)
    }

    private func normalized(_ value: String, field: String) -> String {
        field == "serial" ? normalizeSerial(value) : value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
