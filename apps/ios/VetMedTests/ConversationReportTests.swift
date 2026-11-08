import XCTest
@testable import VetMed

/// Reports from conversations (ADR 0018): small talk may be left out, visibly; numbers and negations never.
/// Same cases as Android `ConversationReportTests`; synthetic data, no network.
@MainActor
final class ConversationReportTests: XCTestCase {
    private static let clinical: Set<String> = ["Er frisst seit gestern schlecht.", "Hat er erbrochen?", "Nein, kein Erbrechen.",
                                                "Wir geben Meloxicam 0,1 mg/kg einmal täglich.", "Kontrolle in drei Tagen."]
    private let conversation = TranscriptBuilder.edited(
        "Guten Morgen, kommen Sie rein. Na, wie geht es uns heute? Er frisst seit gestern schlecht. Hat er erbrochen? Nein, kein Erbrechen. "
        + "Okay, genau. Wir geben Meloxicam 0,1 mg/kg einmal täglich. Schönes Wetter heute übrigens. Kontrolle in drei Tagen. Tschüss, bis dann!",
        previous: nil)

    /// The sources are the JSON line after "QUELLEN:"; key order is not fixed, so they are decoded, not matched.
    private struct Source: Decodable { var id: String; var text: String }
    private static func sources(_ prompt: String) -> [(id: String, text: String)] {
        guard let start = prompt.range(of: "QUELLEN:\n") else { return [] }
        let line = prompt[start.upperBound...].prefix { $0 != "\n" }
        let decoded = (try? JSONDecoder().decode([Source].self, from: Data(line.utf8))) ?? []
        return decoded.map { ($0.id, $0.text) }
    }
    private static func encode(_ draft: ModelReportDraft) throws -> String { String(decoding: try JSONEncoder().encode(draft), as: UTF8.self) }

    /// Answers like a careful model: clinical sentences into the report, the rest as skipped. Optionally also tries to skip the dose.
    final class ConversationEngine: ReportTextEngine {
        let tryToSkipDose: Bool
        var prompts: [String] = []
        init(tryToSkipDose: Bool) { self.tryToSkipDose = tryToSkipDose }
        var engineID: String { "synthetic-test-engine" }
        var engineRevision: String { "synthetic" }
        var sourceLimit: Int { 60 }
        var characterLimit: Int { 20000 }
        var executionLabel: String { "Test" }
        func generate(prompt: String, instructions: String) async throws -> String {
            prompts.append(prompt)
            let skipDose = tryToSkipDose && prompts.count == 1
            let all = ConversationReportTests.sources(prompt)
            func skips(_ text: String) -> Bool { !ConversationReportTests.clinical.contains(text.trimmingCharacters(in: .whitespaces)) || (skipDose && text.contains("Meloxicam")) }
            let items = all.filter { !skips($0.text) }.map { source in
                let text = source.text.trimmingCharacters(in: .whitespaces)
                return ModelReportDraft.Item(section: text.contains("Kontrolle") ? "Weiteres Vorgehen" : "Befunde", text: text, segmentId: source.id, quote: text)
            }
            let skipped = all.filter { skips($0.text) }.map { ModelReportDraft.Skip(segmentId: $0.id, reason: "Begrüßung oder Smalltalk") }
            return try ConversationReportTests.encode(ModelReportDraft(items: items, missingInformation: [], conflicts: [], skipped: skipped))
        }
    }

    func testSmallTalkIsLeftOutVisiblyAndTheClinicalContentStays() async throws {
        let engine = ConversationEngine(tryToSkipDose: false)
        let report = try await ReportPipeline(engine: engine).run(transcript: conversation, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertTrue(engine.prompts[0].contains("skipped"))
        for sentence in Self.clinical { XCTAssertTrue(report.text.contains(sentence), sentence) }
        XCTAssertFalse(report.text.contains("Wetter"))
        XCTAssertEqual(report.content.omitted?.map { $0.text.trimmingCharacters(in: .whitespaces) },
                       ["Guten Morgen, kommen Sie rein.", "Na, wie geht es uns heute?", "Okay, genau.", "Schönes Wetter heute übrigens.", "Tschüss, bis dann!"])
        XCTAssertTrue(report.warnings.contains { $0.hasPrefix("5 Sätze wurden als nicht fachlich ausgelassen") })
        XCTAssertFalse(report.warnings.contains { $0.hasPrefix("Nicht alle Transkriptabschnitte") })
        // The omitted list is for review only; it never enters the exported report text.
        XCTAssertFalse(report.exportText.contains("Tschüss"))
    }

    func testASentenceWithADoseCanNeverBeSkipped() async throws {
        let engine = ConversationEngine(tryToSkipDose: true)
        let report = try await ReportPipeline(engine: engine).run(transcript: conversation, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
        // The first answer skipped the dose; the repair asks for exactly that sentence and says why.
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertTrue(engine.prompts[1].contains("dürfen nicht ausgelassen werden"))
        XCTAssertTrue(report.text.contains("Meloxicam 0,1 mg/kg"))
        XCTAssertFalse(report.content.omitted?.contains { $0.text.contains("Meloxicam") } ?? true)
    }

    func testNegationsAndNumbersAreNeverSkippable() async throws {
        XCTAssertFalse(ReportSkipPolicy.mayOmit("Nein, kein Erbrechen."))
        XCTAssertFalse(ReportSkipPolicy.mayOmit("Das ist nicht schlimm."))
        XCTAssertFalse(ReportSkipPolicy.mayOmit("Kommen Sie in 3 Tagen wieder."))
        for spoken in ["Kommen Sie in drei Tagen wieder.", "Er wiegt zwölf Kilo.", "Zweimal täglich bitte.", "Eine halbe Tablette.", "Seit vierzehn Tagen so.", "Etwa zwanzig Minuten."] {
            XCTAssertFalse(ReportSkipPolicy.mayOmit(spoken), spoken)
        }
        XCTAssertTrue(ReportSkipPolicy.mayOmit("Guten Morgen, kommen Sie rein."))
        XCTAssertTrue(ReportSkipPolicy.mayOmit("Okay, genau."))
    }

    func testAConversationWithoutClinicalContentFailsInsteadOfAnEmptyReport() async throws {
        final class SmallTalkEngine: ReportTextEngine {
            var engineID: String { "synthetic-test-engine" }
            var engineRevision: String { "synthetic" }
            var sourceLimit: Int { 60 }
            var characterLimit: Int { 20000 }
            var executionLabel: String { "Test" }
            func generate(prompt: String, instructions: String) async throws -> String {
                let skipped = ConversationReportTests.sources(prompt).map { ModelReportDraft.Skip(segmentId: $0.id, reason: "Smalltalk") }
                return try ConversationReportTests.encode(ModelReportDraft(items: [], missingInformation: [], conflicts: [], skipped: skipped))
            }
        }
        let smallTalk = TranscriptBuilder.edited("Guten Morgen. Schönes Wetter heute. Tschüss!", previous: nil)
        do {
            _ = try await ReportPipeline(engine: SmallTalkEngine()).run(transcript: smallTalk, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
            XCTFail("no clinical content")
        } catch { XCTAssertTrue(error.localizedDescription.contains("keine fachlichen Angaben"), error.localizedDescription) }
    }

    func testProviderSchemasAllowSkippedWithKnownIDsOnly() async throws {
        let key = "synthetic-key-for-contract-tests-000"
        let openAI = String(decoding: try OpenAIReportAPI.request(modelID: "m", key: key, prompt: "p", instructions: "i", sections: ["Befunde"], sourceLimit: 3).httpBody!, as: UTF8.self)
        XCTAssertTrue(openAI.contains("\"skipped\"") && openAI.contains("\"required\":[\"items\",\"skipped\"]"))
        let gemini = String(decoding: try GeminiOnlineAPI.reportRequest(modelID: "gemini-3.6-flash", key: key, prompt: "p", instructions: "i", sections: ["Befunde"], sourceLimit: 3).httpBody!, as: UTF8.self)
        XCTAssertTrue(gemini.contains("\"skipped\""))
        XCTAssertEqual(OpenAIReportEngine(configuration: .init(modelID: "m"), key: key, sections: ["Befunde"]).sourceLimit, 60)
        XCTAssertEqual(reportMaxCalls, 40)
    }
}
