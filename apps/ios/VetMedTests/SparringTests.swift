import XCTest
import CryptoKit
@testable import VetMed

private actor StubAnalysisStream: AnalysisStreamingTransport {
    let events: [Data]
    let disconnect: Bool
    private(set) var requests: [URLRequest] = []
    init(_ events: [Data] = [], disconnect: Bool = false) { self.events = events; self.disconnect = disconnect }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (Data) async throws -> Bool) async throws {
        requests.append(request)
        for event in events {
            try Task.checkCancellation()
            if try await receive(event) { return }
        }
        if disconnect { throw URLError(.networkConnectionLost) }
    }
}

@MainActor
final class SparringTests: XCTestCase {
    private let key = "synthetic-streaming-key-for-contract-tests"
    private func snapshot(caseID: UUID? = nil, encounter: Encounter = .init(), question: String = "Kein Fieber. Welche Angaben fehlen?") throws -> SparringSnapshot {
        try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: .init(question: question), modelID: "synthetic-model")
    }
    private func delta(_ text: String, sequence: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": text, "sequence_number": sequence, "item_id": "msg1", "content_index": 0])
    }
    private func final(_ text: String, status: String = "completed", refusal: Bool = false) throws -> Data {
        let content: [String: Any] = refusal ? ["type": "refusal", "refusal": "refused"] : ["type": "output_text", "text": text]
        return try JSONSerialization.data(withJSONObject: ["type": "response." + status, "sequence_number": 99,
            "response": ["status": status, "model": "synthetic-model-snapshot", "usage": ["input_tokens": 50, "output_tokens": 20],
                         "output": [["type": "message", "content": [content]]]]])
    }
    private func report(_ text: String, date: Date = Date(), approved: Bool = false) -> ReportVersion {
        let content = StructuredReport(template: .treatment_report, length: .short, audience: .veterinarian,
            sourceTranscriptVersionId: UUID().uuidString, sections: [], missingInformation: [], conflicts: [])
        return ReportVersion(createdAt: date, content: content, editedText: text, modelID: "test", modelRevision: "test",
            warnings: ["Zahlen prüfen"], approvedAt: approved ? date : nil)
    }
    func testCaseReportsIncludeSelectedEditedVersionsFromMultipleEncountersAndFreezeContent() throws {
        let first = report("Kein Fieber. 12,5 kg.", approved: true)
        let second = report("Kontrolle: Temperatur nicht gemessen.")
        let ignored = report("NICHT AUSGEWÄHLT")
        let encounter = Encounter(reports: [first, ignored])
        var item = VetCase(label: "Nur lokal", species: "Hund", encounters: [encounter, Encounter(reports: [second])])
        let draft = SparringDraft(question: "Wie weiter?", reportIDs: [first.id, second.id])
        let snapshot = try SparringRequestBuilder.prepare(caseID: item.id, encounter: encounter, draft: draft, modelID: "test", caseContext: item)
        let request = try SparringRequestBuilder.request(snapshot: snapshot, key: key)
        XCTAssertEqual(request.httpBody, snapshot.payload)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let text = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(text.contains("Kein Fieber. 12,5 kg.")); XCTAssertTrue(text.contains(second.text))
        XCTAssertTrue(text.contains("Fachlich geprüft")); XCTAssertTrue(text.contains("Entwurf · fachlich ungeprüft"))
        XCTAssertTrue(text.contains("Zahlen prüfen")); XCTAssertFalse(text.contains(ignored.text)); XCTAssertFalse(text.contains(item.label))
        item.encounters[0].reports[0].editedText = "Später verändert"
        XCTAssertEqual(snapshot.reports?.first?.text, first.text)
        XCTAssertEqual(try JSONDecoder().decode(SparringSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func testReportSelectionRejectsForeignMissingDuplicateAndStandaloneReferences() throws {
        let own = report("Eigener Bericht"), foreign = report("Fremder Bericht")
        let encounter = Encounter(reports: [own])
        let item = VetCase(label: "A", species: "Hund", encounters: [encounter])
        let other = VetCase(label: "B", species: "Katze", encounters: [Encounter(reports: [foreign])])
        func prepare(_ ids: [UUID], caseID: UUID?, context: VetCase?) throws -> SparringSnapshot {
            try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter,
                draft: .init(question: "Frage", reportIDs: ids), modelID: "test", caseContext: context)
        }
        XCTAssertThrowsError(try prepare([foreign.id], caseID: item.id, context: item))
        XCTAssertThrowsError(try prepare([foreign.id], caseID: item.id, context: other))
        XCTAssertThrowsError(try prepare([own.id], caseID: nil, context: item))
        XCTAssertThrowsError(try prepare([own.id, own.id], caseID: item.id, context: item))
        XCTAssertThrowsError(try prepare([own.id], caseID: item.id, context: nil))
        XCTAssertThrowsError(try SparringRequestBuilder.prepare(caseID: item.id, encounter: Encounter(),
            draft: .init(question: "Frage", reportIDs: [own.id]), modelID: "test", caseContext: item))
    }
    func testDeselectedReportIsNotReintroducedFromHistoryButOriginalSnapshotIsPreserved() throws {
        let source = report("EINMALIGER QUELLTEXT")
        var encounter = Encounter(reports: [source])
        var item = VetCase(label: "A", species: "Hund", encounters: [encounter])
        let first = try SparringRequestBuilder.prepare(caseID: item.id, encounter: encounter,
            draft: .init(question: "Erste Frage", reportIDs: [source.id]), modelID: "test", caseContext: item)
        let run = AnalysisRun(snapshot: first, status: .completed, text: "Frühere Antwort")
        encounter.analysisRuns = [run]; item.encounters = [encounter]
        let next = try SparringRequestBuilder.prepare(caseID: item.id, encounter: encounter,
            draft: .init(question: "Rückfrage", historyIDs: [run.id], reportIDs: []), modelID: "test", caseContext: item)
        let text = String(decoding: next.payload, as: UTF8.self)
        XCTAssertFalse(text.contains(source.text)); XCTAssertTrue(text.contains(run.text)); XCTAssertTrue(text.contains("Erste Frage"))
        XCTAssertTrue(first.userText.contains(source.text)); XCTAssertTrue(next.reports?.isEmpty == true)
        let stillSelected = try SparringRequestBuilder.prepare(caseID: item.id, encounter: encounter,
            draft: .init(question: "Rückfrage", historyIDs: [run.id], reportIDs: [source.id]), modelID: "test", caseContext: item)
        XCTAssertEqual(String(decoding: stillSelected.payload, as: UTF8.self).components(separatedBy: source.text).count, 2)
    }
    func testLatestReportDefaultPrefersCurrentEncounterAndMarksSupersededVersions() throws {
        let old = report("Alt", date: Date(timeIntervalSince1970: 1))
        var revised = report("Korrigiert", date: Date(timeIntervalSince1970: 2)); revised.parentID = old.id
        let later = report("Anderer Vorgang", date: Date(timeIntervalSince1970: 3))
        let encounter = Encounter(reports: [old, revised])
        let empty = Encounter()
        let item = VetCase(label: "A", species: "Hund", encounters: [encounter, Encounter(reports: [later]), empty])
        XCTAssertEqual(ChatReportSelection.defaultIDs(in: item, encounterID: encounter.id), [revised.id])
        XCTAssertEqual(ChatReportSelection.defaultIDs(in: item, encounterID: empty.id), [later.id])
        XCTAssertEqual(ChatReportSelection.available(in: item).filter(\.isOlderVersion).map(\.id), [old.id])
        let legacy = Data("{\"question\":\"Alt\",\"context\":\"\",\"mode\":\"question\",\"historyIDs\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(SparringDraft.self, from: legacy).reportIDs)
        let optedOut = SparringDraft(reportIDs: [])
        XCTAssertEqual(try JSONDecoder().decode(SparringDraft.self, from: JSONEncoder().encode(optedOut)).reportIDs, [])
    }
    func testOversizedReportContextFailsWithoutTruncation() throws {
        let source = report(String(repeating: "x", count: SparringRequestBuilder.maximumPayloadBytes))
        let encounter = Encounter(reports: [source])
        let item = VetCase(label: "A", species: "Hund", encounters: [encounter])
        XCTAssertThrowsError(try SparringRequestBuilder.prepare(caseID: item.id, encounter: encounter,
            draft: .init(question: "Frage", reportIDs: [source.id]), modelID: "test", caseContext: item))
    }
    func testPreviewIsExactStatelessPayloadWithoutCredentialsOrAutomaticCaseFields() throws {
        let caseID = UUID(), encounter = Encounter()
        let prepared = try snapshot(caseID: caseID, encounter: encounter)
        let request = try SparringRequestBuilder.request(snapshot: prepared, key: key)
        XCTAssertEqual(request.httpBody, prepared.payload)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true); XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["previous_response_id"]); XCTAssertNil(body["tools"]); XCTAssertNil(body["conversation"])
        let text = String(decoding: prepared.payload, as: UTF8.self)
        XCTAssertFalse(text.contains(key)); XCTAssertFalse(text.contains(caseID.uuidString)); XCTAssertFalse(text.contains(encounter.id.uuidString))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
    }
    func testOnlyExplicitCompleteHistoryFromSameScopeCanBeSent() throws {
        let caseID = UUID(); var encounter = Encounter()
        var own = AnalysisRun(snapshot: try snapshot(caseID: caseID, encounter: encounter, question: "Eigenes Material"), status: .completed, text: "Eigene Hypothese")
        let foreign = AnalysisRun(snapshot: try snapshot(caseID: UUID(), question: "FREMDES MATERIAL"), status: .completed, text: "FREMDER INHALT")
        encounter.analysisRuns = [own, foreign]
        let blank = try snapshot(caseID: caseID, encounter: encounter)
        XCTAssertFalse(String(decoding: blank.payload, as: UTF8.self).contains("Eigene Hypothese"))
        var draft = SparringDraft(question: "Rückfrage", historyIDs: [own.id])
        let selected = try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: draft, modelID: "test")
        XCTAssertTrue(String(decoding: selected.payload, as: UTF8.self).contains("Eigene Hypothese"))
        XCTAssertFalse(String(decoding: selected.payload, as: UTF8.self).contains("FREMDER INHALT"))
        draft.historyIDs = [foreign.id]
        XCTAssertThrowsError(try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: draft, modelID: "test"))
        own.status = .incomplete; encounter.analysisRuns = [own]; draft.historyIDs = [own.id]
        XCTAssertThrowsError(try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: draft, modelID: "test"))
    }
    func testQuickCheckHasNoCaseAndNeverCreatesClinicalCase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), repository = try CaseRepository(root: root, key: key)
        var check = QuickCheck(draft: .init(question: "Synthetischer Schnellcheck"))
        let request = try SparringRequestBuilder.prepare(caseID: nil, encounter: check.analysisContext, draft: check.draft, modelID: "test")
        XCTAssertNil(request.caseID)
        check.runs = [AnalysisRun(snapshot: request, status: .completed, text: "Ungeprüfte Analyse")]
        let document = VaultDocument(quickChecks: [check])
        try await repository.save(document)
        let reopened = try CaseRepository(root: root, key: key)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded, document); XCTAssertTrue(loaded.cases.isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: root.appendingPathComponent("cases.sqlite")), as: UTF8.self).contains("Synthetischer Schnellcheck"))
    }
    func testDeletingClinicalCasePreservesIndependentQuickCheckAndViceVersa() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let clinical = VetCase(label: "A", species: "Hund", encounters: [.init(sparringDraft: .init(question: "Fallfrage"))])
        let check = QuickCheck(draft: .init(question: "Unabhängig"))
        try await repository.save(.init(cases: [clinical], quickChecks: [check]))
        try await repository.save(.init(quickChecks: [check]))
        var loaded = try await repository.load(); XCTAssertTrue(loaded.cases.isEmpty); XCTAssertEqual(loaded.quickChecks, [check])
        try await repository.save(.init(cases: [clinical]))
        loaded = try await repository.load(); XCTAssertEqual(loaded.cases, [clinical]); XCTAssertNil(loaded.quickChecks)
    }
    func testBrokenSaveRollsBackBothCasesAndQuickChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let check = QuickCheck(draft: .init(question: "Behalten")), clinical = VetCase(label: "Behalten", species: "Katze")
        let document = VaultDocument(cases: [clinical], quickChecks: [check])
        try await repository.save(document)
        do { try await repository.save(.init(quickChecks: [check, check])); XCTFail("Duplicate ID accepted") } catch {}
        let loaded = try await repository.load(); XCTAssertEqual(loaded, document)
        try await repository.verifyIntegrity()
    }
    func testSSEHandlesUTF8CRLFCommentsAndMultilineDataWithoutAccumulatingWholeStream() throws {
        let message = "data: {\"type\":\"example\",\r\ndata: \"text\":\"Größe 🐕\"}\r\n\r\n"
        var decoder = BoundedSSEDecoder(); var events: [Data] = []
        for byte in Data(": ping\r\n\r\nevent: ignored\r\n".utf8) + Data(message.utf8) {
            if let event = try decoder.feed(byte) { events.append(event) }
        }
        XCTAssertEqual(events.count, 1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: events[0]) as? [String: String])
        XCTAssertEqual(value["text"], "Größe 🐕")
    }
    func testSSERejectsOversizedUnterminatedLine() throws {
        var decoder = BoundedSSEDecoder()
        for _ in 0..<524_288 { _ = try decoder.feed(65) }
        XCTAssertThrowsError(try decoder.feed(65))
    }
    func testOnlyMatchingTerminalEventCompletesAnswerAndProvidesActualUsage() throws {
        var decoder = OpenAIAnalysisDecoder()
        _ = try decoder.consume(delta("Kein "))
        _ = try decoder.consume(delta("Fieber.", sequence: 2))
        XCTAssertFalse(decoder.terminal)
        guard case .terminal(let status, let text, let model, let usage, _)? = try decoder.consume(final("Kein Fieber.")) else { return XCTFail("Missing terminal") }
        XCTAssertEqual(status, .completed); XCTAssertEqual(text, "Kein Fieber."); XCTAssertEqual(model, "synthetic-model-snapshot")
        XCTAssertEqual(usage, AnalysisUsage(inputTokens: 50, outputTokens: 20))
        var mismatch = OpenAIAnalysisDecoder(); _ = try mismatch.consume(delta("Kein Fieber."))
        XCTAssertThrowsError(try mismatch.consume(final("Fieber.")))
    }
    func testRefusalAndTokenLimitRemainNonComplete() throws {
        for (status, refused, expected) in [("incomplete", false, AnalysisStatus.incomplete), ("completed", true, .refused)] {
            var decoder = OpenAIAnalysisDecoder(); _ = try decoder.consume(delta("Teilantwort"))
            guard case .terminal(let actual, _, _, _, _)? = try decoder.consume(final("Teilantwort", status: status, refusal: refused)) else { return XCTFail("Missing terminal") }
            XCTAssertEqual(actual, expected)
        }
    }
    func testDuplicateStreamEventIsRejectedInsteadOfDuplicatingText() throws {
        var decoder = OpenAIAnalysisDecoder(), event = try delta("Text")
        _ = try decoder.consume(event)
        XCTAssertThrowsError(try decoder.consume(event))
        event = try JSONSerialization.data(withJSONObject: ["type": "error", "message": "PRIVATE PROVIDER BODY"])
        do { _ = try decoder.consume(event); XCTFail("No error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE PROVIDER BODY")) }
    }
    func testFailedPersistencePreventsAnyNetworkRequest() async throws {
        let transport = StubAnalysisStream([try final("Test")]), service = SparringService(transport: transport)
        do {
            try await service.run(snapshot: snapshot(), key: key, beforeSending: { throw AppFailure("synthetic storage error") }, receive: { _ in XCTFail("Unexpected output") })
            XCTFail("Sent without persistence")
        } catch {}
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testDisconnectKeepsPartialTextAndDoesNotRetryOrComplete() async throws {
        let transport = StubAnalysisStream([try delta("Gesicherter Teil")], disconnect: true), service = SparringService(transport: transport)
        var text = "", completed = false, recorded = false
        do {
            try await service.run(snapshot: snapshot(), key: key, beforeSending: { recorded = true }, receive: { update in
                XCTAssertTrue(recorded)
                if case .text(let value) = update { text = value }
                if case .terminal = update { completed = true }
            })
            XCTFail("Disconnect accepted")
        } catch {}
        XCTAssertEqual(text, "Gesicherter Teil"); XCTAssertFalse(completed)
        let requests = await transport.requests; XCTAssertEqual(requests.count, 1)
    }
    func testCancellationAfterPersistBeforeSendDoesNotSendAnything() async throws {
        let transport = StubAnalysisStream([try final("Test")]), service = SparringService(transport: transport)
        let prepared = try snapshot()
        let task = Task { try await service.run(snapshot: prepared, key: key, beforeSending: { withUnsafeCurrentTask { $0?.cancel() } }, receive: { _ in XCTFail("Unexpected output") }) }
        do { try await task.value; XCTFail("No cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testRecoveryMarksActiveRunsIncompleteAndPreservesDraftAndFinishedAnswer() throws {
        var encounter = Encounter(sparringDraft: .init(question: "Ungesendet"))
        let value = try snapshot(encounter: encounter)
        encounter.analysisRuns = [AnalysisRun(snapshot: value, status: .streaming, text: "Teil"), AnalysisRun(snapshot: value, status: .completed, text: "Fertig")]
        encounter.recoverInterruptedAnalysis()
        XCTAssertEqual(encounter.analysisRuns?.map(\.status), [.incomplete, .completed])
        XCTAssertEqual(encounter.analysisRuns?.map(\.text), ["Teil", "Fertig"])
        XCTAssertEqual(encounter.sparringDraft?.question, "Ungesendet")
    }
}
