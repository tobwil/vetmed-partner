import XCTest
@testable import VetMed

/// Guard rails against wrong medication statements in the sparring chat (same cases as Android).
final class MedicationSafetyTests: XCTestCase {
    private let key = "synthetic-streaming-key-for-contract-tests"

    func testMedicationContentIsDetectedAndOrdinaryAnswersAreNot() {
        for text in ["Das Präparat enthält Meloxicam.", "Wirkstoffe: Fipronil und S-Methopren.", "Übliche Dosierung 0,1 mg/kg einmal täglich.",
                     "Gabe von 2 mg pro Tier", "Bitte die Fachinformation prüfen.", "Eine Kautablette alle drei Monate.",
                     "Wartezeit essbare Gewebe: 28 Tage.", "5 µg/kg i.v.", "Wechselwirkungen mit NSAIDs beachten.",
                     "Bravecto: Fluralaner", "Gut verträglich ist Meloxicam.", "Alternativ Carprofen oder Robenacoxib."] {
            XCTAssertTrue(MedicationSafety.mentionsMedication(text), text)
        }
        for text in ["Die Lahmheit hinten links spricht eher für ein orthopädisches Problem.", "Temperatur nicht gemessen; bitte nachholen.",
                     "5 ml Blut in ein EDTA-Röhrchen.", "Kontrolle in 3 Tagen."] {
            XCTAssertFalse(MedicationSafety.mentionsMedication(text), text)
        }
    }

    func testOnlyHttpsLinksOnOfficialDomainsCountAsOfficial() {
        XCTAssertTrue(MedicationSafety.isOfficial("https://medicines.health.europa.eu/veterinary/de/600000047183"))
        XCTAssertTrue(MedicationSafety.isOfficial("https://www.ema.europa.eu/en/medicines/veterinary/EPAR/x"))
        XCTAssertTrue(MedicationSafety.isOfficial("https://portal.dimdi.pharmnet-bund.de/amguifree/"))
        XCTAssertFalse(MedicationSafety.isOfficial("http://ema.europa.eu/x"))
        XCTAssertFalse(MedicationSafety.isOfficial("https://ema.europa.eu.example.com/x"))
        XCTAssertFalse(MedicationSafety.isOfficial("https://notema.europa.eu/x"))
        XCTAssertFalse(MedicationSafety.isOfficial("https://www.tierarzt-blog.de/meloxicam"))
    }

    func testRequestStatesSourceSituationAndOnlyAsksForDomainLimitedSearchWhenEnabled() throws {
        let off = try SparringRequestBuilder.prepare(caseID: nil, encounter: Encounter(), draft: .init(question: "Frage"), modelID: "m")
        let offBody = try XCTUnwrap(JSONSerialization.jsonObject(with: off.payload) as? [String: Any])
        let instructions = try XCTUnwrap(offBody["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Aus deinem Gedächtnis darfst du einem Handelsnamen keinen Wirkstoff zuordnen"))
        XCTAssertTrue(instructions.contains("# Quellenlage für diese Anfrage\nQuellensuche: nicht aktiviert."))
        XCTAssertNil(offBody["tools"]); XCTAssertNil(off.sourceSearch)

        let on = try SparringRequestBuilder.prepare(caseID: nil, encounter: Encounter(), draft: .init(question: "Frage"), modelID: "m", sourceSearch: true)
        XCTAssertEqual(on.sourceSearch, true)
        let request = try SparringRequestBuilder.request(snapshot: on, key: key)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "web_search")
        XCTAssertEqual((tool["filters"] as? [String: Any])?["allowed_domains"] as? [String], MedicationSafety.officialDomains)
        XCTAssertEqual(body["include"] as? [String], ["web_search_call.action.sources"])
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testCitedSourcesAreTakenFromTheFinalResponseAndUnsafeLinksDropped() throws {
        var decoder = OpenAIAnalysisDecoder()
        let text = "Laut Fachinformation enthält das Präparat Wirkstoff A."
        let event = """
        {"type":"response.completed","sequence_number":9,"response":{"status":"completed","model":"m","output":[
        {"type":"web_search_call","id":"ws1","status":"completed"},
        {"type":"message","content":[{"type":"output_text","text":"\(text)","annotations":[
        {"type":"url_citation","url":"https://medicines.health.europa.eu/veterinary/de/1","title":"Präparat – Fachinformation"},
        {"type":"url_citation","url":"https://medicines.health.europa.eu/veterinary/de/1","title":"Doppelt"},
        {"type":"url_citation","url":"javascript:alert(1)","title":"Böse"}]}]}]}}
        """
        guard case .terminal(let status, let final, _, _, _, let sources)? = try decoder.consume(Data(event.utf8)) else { return XCTFail("Missing terminal") }
        XCTAssertEqual(status, .completed); XCTAssertEqual(final, text)
        XCTAssertEqual(sources, [AnswerSource(url: "https://medicines.health.europa.eu/veterinary/de/1", title: "Präparat – Fachinformation")])
    }

    func testAnswersWithoutOfficialSourceAreWarnedAndExportedWithTheWarning() throws {
        let snapshot = try SparringRequestBuilder.prepare(caseID: nil, encounter: Encounter(), draft: .init(question: "Frage"), modelID: "m")
        var run = AnalysisRun(snapshot: snapshot, status: .completed, text: "Das Präparat enthält Wirkstoff A.")
        XCTAssertTrue(MedicationSafety.needsWarning(run))
        XCTAssertTrue(ChatMarkdown.export(run).contains(MedicationSafety.warning))
        run.sources = [AnswerSource(url: "https://www.tierarzt-blog.de/a")]
        XCTAssertTrue(MedicationSafety.needsWarning(run), "Nicht amtliche Quellen heben die Warnung nicht auf")
        run.sources = [AnswerSource(url: "https://medicines.health.europa.eu/veterinary/de/1", title: "Fachinformation")]
        XCTAssertFalse(MedicationSafety.needsWarning(run))
        XCTAssertTrue(ChatMarkdown.export(run).contains("Amtliche Quellen:\n- Fachinformation: https://medicines.health.europa.eu/veterinary/de/1"))
    }
}
