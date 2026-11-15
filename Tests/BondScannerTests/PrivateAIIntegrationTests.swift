@testable import BondScanner
import XCTest

private enum AIEvalMode: String { case review, all }
private enum AIEvalRun: String, CaseIterable { case textOnly, multimodal }

private struct AIEvalCounters: Codable {
    var fixtures = 0, missingPhotos = 0, undecodablePhotos = 0, reviewFixtures = 0
    var visionCorrect = 0, visionEvaluated = 0, proposals = 0, correctProposals = 0
    var recoveredErrors = 0, visionErrors = 0, regressions = 0, abstentions = 0, failures = 0, unavailable = 0
    var serialExact = 0, serialEvaluated = 0, dateExact = 0, dateEvaluated = 0, denominationExact = 0, denominationEvaluated = 0
    var visualUnverifiedSerials = 0, corroboratedSerials = 0
    var latencies: [Double] = []

    mutating func addVision(_ actual: String, expected: String, field: String) {
        guard !expected.isEmpty else { return }
        visionEvaluated += 1
        let correct = AIEvaluation.normalized(actual, field: field) == AIEvaluation.normalized(expected, field: field)
        if correct {
            visionCorrect += 1
        } else {
            visionErrors += 1
        }
        if field == "serial" {
            serialEvaluated += 1; if correct {
                serialExact += 1
            }
        }
        if field == "denomination" {
            denominationEvaluated += 1; if correct {
                denominationExact += 1
            }
        }
    }
}

private struct AIEvalCheckpoint: Codable {
    var nextFixtureIndex: Int
    var complete: Bool
    var vision: AIEvalCounters
    var text: AIEvalCounters
    var image: AIEvalCounters
}

private enum AIEvaluation {
    static let fields = ["series", "serial", "denomination", "issueMonth", "issueYear"]
    static func normalized(_ value: String, field: String) -> String {
        switch field {
        case "serial": return normalizeSerial(value)
        case "denomination": return value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        case "issueMonth": return monthNumber(value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        case "issueYear": return value.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }

    static func value(_ record: BondRecord, field: String) -> String {
        switch field { case "series": return record.series; case "serial": return record.serial; case "denomination": return record.denomination; case "issueMonth": return record.issueMonth; case "issueYear": return record.issueYear; default: return "" }
    }

    static func expected(_ fixture: FixtureManifestItem, field: String) -> String {
        switch field { case "series": return fixture.series ?? ""; case "serial": return fixture.serial ?? ""; case "denomination": return fixture.denomination ?? ""; case "issueMonth": return fixture.issueMonth ?? ""; case "issueYear": return fixture.issueYear ?? ""; default: return "" }
    }

    static func uniqueSuggestions(_ suggestions: [BondAISuggestion]) -> [String: BondAISuggestion] {
        var values: [String: BondAISuggestion] = [:]
        for suggestion in suggestions where values[suggestion.field]?.abstained != false {
            values[suggestion.field] = suggestion
        }
        return values
    }
}

/// Explicitly opt-in and read-only. Reports contain aggregate counters/timings only.
final class PrivateAIIntegrationTests: XCTestCase {
    private var priorLogging = true
    override func setUp() {
        super.setUp(); priorLogging = ScanLog.shared.isEnabled; ScanLog.shared.isEnabled = false
    }

    override func tearDown() {
        ScanLog.shared.isEnabled = priorLogging; super.tearDown()
    }

    func testEvaluatorCanonicalNormalization() {
        XCTAssertEqual(AIEvaluation.normalized("$1,000", field: "denomination"), "1000")
        XCTAssertEqual(AIEvaluation.normalized("JAN", field: "issueMonth"), "01")
        XCTAssertEqual(AIEvaluation.normalized("C1234567890EE", field: "serial"), normalizeSerial("C1234567890EE"))
    }

    func testEvaluatorSafelyPrefersProposalOverDuplicateAbstention() {
        let abstention = BondAISuggestion(field: "serial", existingValue: "", proposedValue: nil, abstained: true, evidence: "OCR", imageRegion: nil, ambiguity: "", assessment: .insufficientEvidence, requiresOriginalInspection: true)
        let proposal = BondAISuggestion(field: "serial", existingValue: "", proposedValue: "C1234567890EE", abstained: false, evidence: "OCR", imageRegion: nil, ambiguity: "", assessment: .conflictingEvidence, requiresOriginalInspection: true)
        XCTAssertEqual(AIEvaluation.uniqueSuggestions([abstention, proposal])["serial"]?.proposedValue, proposal.proposedValue)
    }

    func testProductionReviewEligibilityKeepsUnresolvedCompleteRecords() {
        var record = emptyBondRecord(id: "eligibility", capturedAt: "2026-01-01T00:00:00Z")
        record.status = "REVIEW"
        record.series = "EE"
        record.serial = "C1234567890EE"
        record.denomination = "50"
        record.fieldConfidence = ["serial": "high", "denomination": "high"]
        record.reviewReasons = ["validation: requires inspection"]
        XCTAssertTrue(ReviewCoordinator.isAutomaticallyReviewEligible(record))
        record.reviewReasons = []
        XCTAssertFalse(ReviewCoordinator.isAutomaticallyReviewEligible(record))
    }

    /// Generates a reviewer-facing draft, never a ground-truth manifest. Values
    /// remain blank when neither Vision nor the local multimodal model can support
    /// them; a human must verify every entry before copying it to manifest.json.
    func testGenerateUnverifiedLocalAIDraftManifest() async throws {
        guard ProcessInfo.processInfo.environment["BONDSCANNER_GENERATE_AI_DRAFT"] == "1" else {
            throw XCTSkip("Use the BondScannerManifestDraft scheme explicitly.")
        }
        guard ReviewCoordinator.localModelAvailability == .available else {
            throw XCTSkip("Local model unavailable: \(ReviewCoordinator.localModelAvailability.rawValue)")
        }
        guard let root = PrivateFixturesEnvironment.projectRootURL() else { throw XCTSkip("Project root unavailable.") }
        let limit = max(1, Int(ProcessInfo.processInfo.environment["BONDSCANNER_AI_DRAFT_LIMIT"] ?? "5") ?? 5)
        let images = try Array(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("local-fixtures/real/images"), includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit))
        guard !images.isEmpty else { throw XCTSkip("No private real photographs available.") }
        struct Draft: Codable {
            let id: String; let filename: String; let series: String?; let denomination: String?; let serial: String?; let issueMonth: String?; let issueYear: String?; let notes: String
        }
        var drafts: [Draft] = []
        let analyzer = LocalBondAIAnalyzer(mode: .multimodal)
        for (index, url) in images.enumerated() {
            guard let image = cgImageFromFile(url) else {
                drafts.append(Draft(id: "draft-\(index + 1)", filename: url.lastPathComponent, series: nil, denomination: nil, serial: nil, issueMonth: nil, issueYear: nil, notes: "UNVERIFIED: image could not be decoded"))
                continue
            }
            let result = scanImage(image)
            var record = result.record
            record.id = UUID().uuidString
            record.revision = 1
            record.status = "REVIEW"
            let analysis = await analyzer.analyze(record: record, imageURL: url)
            let suggestions = AIEvaluation.uniqueSuggestions(analysis.suggestions)
            func value(_ field: String, _ vision: String) -> String? {
                if let proposed = suggestions[field]?.proposedValue, !proposed.isEmpty {
                    return proposed
                }
                return vision.isEmpty ? nil : vision
            }
            drafts.append(Draft(id: "draft-\(index + 1)", filename: url.lastPathComponent, series: value("series", record.series), denomination: value("denomination", record.denomination), serial: value("serial", record.serial), issueMonth: value("issueMonth", record.issueMonth), issueYear: value("issueYear", record.issueYear), notes: "UNVERIFIED AI/Vision draft — manually inspect original photograph before copying any value into manifest.json"))
        }
        let output = root.appendingPathComponent("local-fixtures/real/manifest.ai-draft.json")
        let data = try JSONEncoder().encode(drafts)
        try data.write(to: output, options: .atomic)
    }

    func testPrivateRealPhotosWithAppleMultimodalModel() async throws {
        guard ProcessInfo.processInfo.environment["BONDSCANNER_RUN_LOCAL_AI_EVAL"] == "1" else { throw XCTSkip("Set BONDSCANNER_RUN_LOCAL_AI_EVAL=1.") }
        let availability = ReviewCoordinator.localModelAvailability
        let env = ProcessInfo.processInfo.environment
        let mode = AIEvalMode(rawValue: env["BONDSCANNER_AI_EVAL_MODE"] ?? "review") ?? .review
        let limit = max(1, Int(env["BONDSCANNER_AI_EVAL_LIMIT"] ?? "5") ?? 5)
        let manifestURL = try XCTUnwrap(PrivateFixturesEnvironment.manifestURL(for: .real))
        let fixtures = try JSONDecoder().decode([FixtureManifestItem].self, from: Data(contentsOf: manifestURL)).sorted { $0.id < $1.id }
        guard !fixtures.isEmpty else { throw XCTSkip("Private real manifest empty.") }
        var vision = AIEvalCounters(), text = AIEvalCounters(), image = AIEvalCounters()
        let checkpointURL = try XCTUnwrap(PrivateFixturesEnvironment.reportsDirectoryURL(for: .real)).appendingPathComponent("ai-evaluation-checkpoint.json")
        var startIndex = 0
        if env["BONDSCANNER_AI_EVAL_RESUME"] == "1",
           let data = try? Data(contentsOf: checkpointURL),
           let checkpoint = try? JSONDecoder().decode(AIEvalCheckpoint.self, from: data)
        {
            vision = checkpoint.vision; text = checkpoint.text; image = checkpoint.image
            startIndex = checkpoint.complete ? limit : checkpoint.nextFixtureIndex
        }

        for (fixtureIndex, fixture) in fixtures.prefix(limit).enumerated() where fixtureIndex >= startIndex {
            vision.fixtures += 1
            guard let url = PrivateFixturesEnvironment.imageURL(for: fixture.filename, dataset: .real) else { vision.missingPhotos += 1; continue }
            guard let imageFile = cgImageFromFile(url) else { vision.undecodablePhotos += 1; continue }
            let visionStart = CFAbsoluteTimeGetCurrent()
            var record = scanImage(imageFile).record
            vision.latencies.append(CFAbsoluteTimeGetCurrent() - visionStart)
            record.id = UUID().uuidString; record.revision = 1
            for field in AIEvaluation.fields {
                vision.addVision(AIEvaluation.value(record, field: field), expected: AIEvaluation.expected(fixture, field: field), field: field)
            }
            let expectedMonth = AIEvaluation.expected(fixture, field: "issueMonth"), expectedYear = AIEvaluation.expected(fixture, field: "issueYear")
            if !expectedMonth.isEmpty, !expectedYear.isEmpty {
                vision.dateEvaluated += 1
                if AIEvaluation.normalized(record.issueMonth, field: "issueMonth") == AIEvaluation.normalized(expectedMonth, field: "issueMonth"), record.issueYear == expectedYear {
                    vision.dateExact += 1
                }
            }
            let eligible = ReviewCoordinator.isAutomaticallyReviewEligible(record)
            if eligible {
                vision.reviewFixtures += 1
            }
            guard mode == .all || eligible else { continue }
            text.fixtures += 1; image.fixtures += 1
            if availability == .available {
                await score(analyzer: LocalBondAIAnalyzer(mode: .textOnly), record: record, imageURL: url, fixture: fixture, counters: &text)
                await score(analyzer: LocalBondAIAnalyzer(mode: .multimodal), record: record, imageURL: url, fixture: fixture, counters: &image)
            } else {
                text.unavailable += 1; image.unavailable += 1
            }
            // Safe aggregate-only checkpoint: interrupted hardware runs retain
            // completed measurements without identifiers, OCR, or proposals.
            try writeReport(vision: vision, text: text, image: image, mode: mode, limit: limit, availability: availability, isComplete: false)
            let checkpoint = AIEvalCheckpoint(nextFixtureIndex: fixtureIndex + 1, complete: false, vision: vision, text: text, image: image)
            try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
        }
        try writeReport(vision: vision, text: text, image: image, mode: mode, limit: limit, availability: availability, isComplete: true)
        try JSONEncoder().encode(AIEvalCheckpoint(nextFixtureIndex: limit, complete: true, vision: vision, text: text, image: image)).write(to: checkpointURL, options: .atomic)
    }

    private func score(analyzer: LocalBondAIAnalyzer, record: BondRecord, imageURL: URL, fixture: FixtureManifestItem, counters: inout AIEvalCounters) async {
        let start = CFAbsoluteTimeGetCurrent(); let analysis = await analyzer.analyze(record: record, imageURL: imageURL)
        counters.latencies.append(CFAbsoluteTimeGetCurrent() - start)
        if analysis.status == .unavailable {
            counters.unavailable += 1; return
        }
        guard analysis.status == .ready || analysis.status == .abstained else { counters.failures += 1; return }
        let suggestions = AIEvaluation.uniqueSuggestions(analysis.suggestions)
        for field in AIEvaluation.fields {
            let expected = AIEvaluation.expected(fixture, field: field); guard expected != "/" && !expected.isEmpty else { continue }
            let visionValue = AIEvaluation.value(record, field: field)
            let visionCorrect = AIEvaluation.normalized(visionValue, field: field) == AIEvaluation.normalized(expected, field: field)
            if !visionCorrect {
                counters.visionErrors += 1
            }
            guard let suggestion = suggestions[field], !suggestion.abstained, let proposed = suggestion.proposedValue else { counters.abstentions += 1; continue }
            counters.proposals += 1
            let correct = AIEvaluation.normalized(proposed, field: field) == AIEvaluation.normalized(expected, field: field)
            if correct {
                counters.correctProposals += 1
            }
            if !visionCorrect, correct {
                counters.recoveredErrors += 1
            }
            if visionCorrect, !correct {
                counters.regressions += 1
            }
            if field == "serial" {
                if suggestion.evidence.hasPrefix("visual-unverified:") {
                    counters.visualUnverifiedSerials += 1
                } else {
                    counters.corroboratedSerials += 1
                }
            }
        }
    }

    private func writeReport(vision: AIEvalCounters, text: AIEvalCounters, image: AIEvalCounters, mode: AIEvalMode, limit: Int, availability: LocalModelAvailability, isComplete: Bool) throws {
        func summary(_ c: AIEvalCounters) -> [String: Any] {
            let mean = c.latencies.isEmpty ? 0 : c.latencies.reduce(0, +) / Double(c.latencies.count)
            let ordered = c.latencies.sorted()
            let median = ordered.isEmpty ? 0 : (ordered.count.isMultiple(of: 2)
                ? (ordered[ordered.count / 2 - 1] + ordered[ordered.count / 2]) / 2
                : ordered[ordered.count / 2])
            let measured: Any = c.latencies.isEmpty ? "not measured" : mean
            let medianMeasured: Any = c.latencies.isEmpty ? "not measured" : median
            let precision: Any = c.proposals == 0 ? "not measured" : Double(c.correctProposals) / Double(c.proposals)
            return ["fixtures": c.fixtures, "reviewFixtures": c.reviewFixtures, "missingPhotos": c.missingPhotos, "undecodablePhotos": c.undecodablePhotos, "visionBaselineAccuracy": c.visionEvaluated == 0 ? "not measured" : Double(c.visionCorrect) / Double(c.visionEvaluated), "proposalPrecision": precision, "recoveryRate": c.visionErrors == 0 ? "not measured" : Double(c.recoveredErrors) / Double(c.visionErrors), "regressions": c.regressions, "abstentions": c.abstentions, "failures": c.failures, "unavailable": c.unavailable, "serialExact": c.serialEvaluated == 0 ? "not measured" : Double(c.serialExact) / Double(c.serialEvaluated), "dateExact": c.dateEvaluated == 0 ? "not measured" : Double(c.dateExact) / Double(c.dateEvaluated), "denominationExact": c.denominationEvaluated == 0 ? "not measured" : Double(c.denominationExact) / Double(c.denominationEvaluated), "meanLatencySeconds": measured, "medianLatencySeconds": medianMeasured, "visualUnverifiedSerials": c.visualUnverifiedSerials, "corroboratedSerials": c.corroboratedSerials]
        }
        guard let dir = PrivateFixturesEnvironment.reportsDirectoryURL(for: .real) else { return }
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "complete": isComplete, "os": ProcessInfo.processInfo.operatingSystemVersionString, "modelAvailability": availability.rawValue, "mode": mode.rawValue, "limit": limit, "promptVersion": BondAIAnalysis.currentPromptVersion, "vision": summary(vision), "textOnlyProposalMetrics": summary(text), "multimodalProposalMetrics": summary(image)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("latest-ai-evaluation.json"), options: .atomic)
        let visionSummary = summary(vision)
        let serial = visionSummary["serialExact"] ?? "not measured"
        let date = visionSummary["dateExact"] ?? "not measured"
        let denomination = visionSummary["denominationExact"] ?? "not measured"
        let table = """
        Metric | Vision | Vision + Text AI | Vision + Image AI
        ---|---:|---:|---:
        Exact serial match | \(serial) | proposal metric | proposal metric
        Issue-date accuracy | \(date) | proposal metric | proposal metric
        Denomination accuracy | \(denomination) | proposal metric | proposal metric
        """
        try table.write(to: dir.appendingPathComponent("latest-ai-evaluation.txt"), atomically: true, encoding: .utf8)
    }
}
