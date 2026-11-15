import XCTest
@testable import BondScanner

private enum AIEvalMode: String { case review, all }
private enum AIEvalRun: String, CaseIterable { case textOnly, multimodal }

private struct AIEvalCounters: Codable {
    var fixtures = 0, missingPhotos = 0, undecodablePhotos = 0, reviewFixtures = 0
    var visionCorrect = 0, visionEvaluated = 0, proposals = 0, correctProposals = 0
    var recoveredErrors = 0, visionErrors = 0, regressions = 0, abstentions = 0, failures = 0
    var serialExact = 0, serialEvaluated = 0, dateExact = 0, dateEvaluated = 0, denominationExact = 0, denominationEvaluated = 0
    var visualUnverifiedSerials = 0, corroboratedSerials = 0
    var latencies: [Double] = []

    mutating func addVision(_ actual: String, expected: String, field: String) {
        guard !expected.isEmpty else { return }
        visionEvaluated += 1
        let correct = AIEvaluation.normalized(actual, field: field) == AIEvaluation.normalized(expected, field: field)
        if correct { visionCorrect += 1 } else { visionErrors += 1 }
        if field == "serial" { serialEvaluated += 1; if correct { serialExact += 1 } }
        if field == "denomination" { denominationEvaluated += 1; if correct { denominationExact += 1 } }
        if field == "issueDate" { dateEvaluated += 1; if correct { dateExact += 1 } }
    }
}

private enum AIEvaluation {
    static let fields = ["series", "serial", "denomination", "issueDate"]
    static func normalized(_ value: String, field: String) -> String {
        switch field {
        case "serial": return normalizeSerial(value)
        case "denomination": return value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        case "issueDate": return value.replacingOccurrences(of: "-", with: "/").uppercased()
        default: return value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }
    static func value(_ record: BondRecord, field: String) -> String {
        switch field { case "series": return record.series; case "serial": return record.serial; case "denomination": return record.denomination; case "issueDate": return "\(record.issueMonth)/\(record.issueYear)"; default: return "" }
    }
    static func expected(_ fixture: FixtureManifestItem, field: String) -> String {
        switch field { case "series": return fixture.series ?? ""; case "serial": return fixture.serial ?? ""; case "denomination": return fixture.denomination ?? ""; case "issueDate": return "\(fixture.issueMonth ?? "")/\(fixture.issueYear ?? "")"; default: return "" }
    }
    static func uniqueSuggestions(_ suggestions: [BondAISuggestion]) -> [String: BondAISuggestion] {
        var values: [String: BondAISuggestion] = [:]
        for suggestion in suggestions where values[suggestion.field]?.abstained != false { values[suggestion.field] = suggestion }
        return values
    }
}

/// Explicitly opt-in and read-only. Reports contain aggregate counters/timings only.
final class PrivateAIIntegrationTests: XCTestCase {
    private var priorLogging = true
    override func setUp() { super.setUp(); priorLogging = ScanLog.shared.isEnabled; ScanLog.shared.isEnabled = false }
    override func tearDown() { ScanLog.shared.isEnabled = priorLogging; super.tearDown() }

    func testPrivateRealPhotosWithAppleMultimodalModel() async throws {
        guard ProcessInfo.processInfo.environment["BONDSCANNER_RUN_LOCAL_AI_EVAL"] == "1" else { throw XCTSkip("Set BONDSCANNER_RUN_LOCAL_AI_EVAL=1.") }
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, *), ReviewCoordinator.localModelAvailable else { throw XCTSkip("Apple local model unavailable.") }
        #else
        throw XCTSkip("FoundationModels unavailable.")
        #endif
        let env = ProcessInfo.processInfo.environment
        let mode = AIEvalMode(rawValue: env["BONDSCANNER_AI_EVAL_MODE"] ?? "review") ?? .review
        let limit = max(1, Int(env["BONDSCANNER_AI_EVAL_LIMIT"] ?? "5") ?? 5)
        let manifestURL = try XCTUnwrap(PrivateFixturesEnvironment.manifestURL(for: .real))
        let fixtures = try JSONDecoder().decode([FixtureManifestItem].self, from: Data(contentsOf: manifestURL)).sorted { $0.id < $1.id }
        guard !fixtures.isEmpty else { throw XCTSkip("Private real manifest empty.") }
        var vision = AIEvalCounters(), text = AIEvalCounters(), image = AIEvalCounters()

        for fixture in fixtures.prefix(limit) {
            vision.fixtures += 1
            guard let url = PrivateFixturesEnvironment.imageURL(for: fixture.filename, dataset: .real) else { vision.missingPhotos += 1; continue }
            guard let imageFile = cgImageFromFile(url) else { vision.undecodablePhotos += 1; continue }
            let visionStart = CFAbsoluteTimeGetCurrent()
            var record = scanImage(imageFile).record
            vision.latencies.append(CFAbsoluteTimeGetCurrent() - visionStart)
            record.id = UUID().uuidString; record.revision = 1
            for field in AIEvaluation.fields { vision.addVision(AIEvaluation.value(record, field: field), expected: AIEvaluation.expected(fixture, field: field), field: field) }
            let eligible = record.status == "REVIEW" && !requiredFieldsComplete(record)
            if eligible { vision.reviewFixtures += 1 }
            guard mode == .all || eligible else { continue }
            text.fixtures += 1; image.fixtures += 1
            await score(analyzer: LocalBondAIAnalyzer(mode: .textOnly), record: record, imageURL: url, fixture: fixture, counters: &text)
            await score(analyzer: LocalBondAIAnalyzer(mode: .multimodal), record: record, imageURL: url, fixture: fixture, counters: &image)
        }
        try writeReport(vision: vision, text: text, image: image, mode: mode, limit: limit)
    }

    private func score(analyzer: LocalBondAIAnalyzer, record: BondRecord, imageURL: URL, fixture: FixtureManifestItem, counters: inout AIEvalCounters) async {
        let start = CFAbsoluteTimeGetCurrent(); let analysis = await analyzer.analyze(record: record, imageURL: imageURL)
        counters.latencies.append(CFAbsoluteTimeGetCurrent() - start)
        guard analysis.status == .ready || analysis.status == .abstained else { counters.failures += 1; return }
        let suggestions = AIEvaluation.uniqueSuggestions(analysis.suggestions)
        for field in AIEvaluation.fields {
            let expected = AIEvaluation.expected(fixture, field: field); guard expected != "/" && !expected.isEmpty else { continue }
            let visionValue = AIEvaluation.value(record, field: field)
            let visionCorrect = AIEvaluation.normalized(visionValue, field: field) == AIEvaluation.normalized(expected, field: field)
            guard let suggestion = suggestions[field], !suggestion.abstained, let proposed = suggestion.proposedValue else { counters.abstentions += 1; continue }
            counters.proposals += 1
            let correct = AIEvaluation.normalized(proposed, field: field) == AIEvaluation.normalized(expected, field: field)
            if correct { counters.correctProposals += 1 }
            if !visionCorrect && correct { counters.recoveredErrors += 1 }
            if visionCorrect && !correct { counters.regressions += 1 }
            if field == "serial" { if suggestion.evidence.hasPrefix("visual-unverified:") { counters.visualUnverifiedSerials += 1 } else { counters.corroboratedSerials += 1 } }
        }
    }

    private func writeReport(vision: AIEvalCounters, text: AIEvalCounters, image: AIEvalCounters, mode: AIEvalMode, limit: Int) throws {
        func summary(_ c: AIEvalCounters) -> [String: Any] {
            let mean = c.latencies.isEmpty ? 0 : c.latencies.reduce(0, +) / Double(c.latencies.count)
            return ["fixtures": c.fixtures, "reviewFixtures": c.reviewFixtures, "missingPhotos": c.missingPhotos, "undecodablePhotos": c.undecodablePhotos, "visionBaselineAccuracy": c.visionEvaluated == 0 ? 0 : Double(c.visionCorrect) / Double(c.visionEvaluated), "proposalPrecision": c.proposals == 0 ? 0 : Double(c.correctProposals) / Double(c.proposals), "recoveryRate": c.visionErrors == 0 ? 0 : Double(c.recoveredErrors) / Double(c.visionErrors), "regressions": c.regressions, "abstentions": c.abstentions, "failures": c.failures, "serialExact": c.serialEvaluated == 0 ? 0 : Double(c.serialExact) / Double(c.serialEvaluated), "dateExact": c.dateEvaluated == 0 ? 0 : Double(c.dateExact) / Double(c.dateEvaluated), "denominationExact": c.denominationEvaluated == 0 ? 0 : Double(c.denominationExact) / Double(c.denominationEvaluated), "meanLatencySeconds": mean, "visualUnverifiedSerials": c.visualUnverifiedSerials, "corroboratedSerials": c.corroboratedSerials]
        }
        guard let dir = PrivateFixturesEnvironment.reportsDirectoryURL(for: .real) else { return }
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString, "mode": mode.rawValue, "limit": limit, "promptVersion": BondAIAnalysis.currentPromptVersion, "vision": summary(vision), "textOnlyProposalMetrics": summary(text), "multimodalProposalMetrics": summary(image)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("latest-ai-evaluation.json"), options: .atomic)
        let table = "Metric | Vision | Vision + Text AI | Vision + Image AI\n---|---:|---:|---:\nExact serial match | \(summary(vision)[\"serialExact\"]!) | proposal metric | proposal metric\nIssue-date accuracy | \(summary(vision)[\"dateExact\"]!) | proposal metric | proposal metric\nDenomination accuracy | \(summary(vision)[\"denominationExact\"]!) | proposal metric | proposal metric\n"
        try table.write(to: dir.appendingPathComponent("latest-ai-evaluation.txt"), atomically: true, encoding: .utf8)
    }
}
