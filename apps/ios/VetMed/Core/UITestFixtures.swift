#if DEBUG
import Foundation

/// Opt-in synthetic data in the isolated UI-test vault; never used by a normal device launch.
enum UITestFixtures {
    static let caseID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let encounterID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let answerID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    static let markdown = "## Synthetischer Test\n\n**Fett dargestellt** und *kursiv*.\n\n- Hund 12,5 kg\n- Kein Fieber\n\nENDE-DER-TESTANTWORT"
    static func sharing() throws -> VetCase {
        let text = "Synthetischer Exporttest. Hund 12,5 kg. Kein Fieber. ENDE-DES-TESTBERICHTS"
        let transcript = TranscriptBuilder.edited(text, previous: nil)
        let content = StructuredReport(template: .treatment_report, length: .short, audience: .veterinarian,
            sourceTranscriptVersionId: transcript.id.uuidString, sections: [.init(key: "Testinhalt", items: [.init(text: text, sourceRefs: [], origin: "dictated")])], missingInformation: [], conflicts: [])
        let report = ReportVersion(content: content, modelID: "synthetic-ui-fixture", modelRevision: "test-only", warnings: [])
        var encounter = Encounter(id: encounterID, state: .reviewRequired, transcripts: [transcript], reports: [report])
        let snapshot = try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: .init(question: "Synthetischer Formatierungs- und Exporttest"), modelID: "synthetic-ui-fixture")
        encounter.analysisRuns = [AnalysisRun(id: answerID, snapshot: snapshot, status: .completed, text: markdown)]
        return VetCase(id: caseID, label: "UI-Prüffall", species: "Synthetisch", encounters: [encounter])
    }
}
#endif
