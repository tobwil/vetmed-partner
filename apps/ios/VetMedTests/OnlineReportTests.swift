import XCTest
import CryptoKit
@testable import VetMed

private actor StubReportTransport: ReportHTTPTransport {
    let response: ReportHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ response: ReportHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> ReportHTTPResponse { requests.append(request); return response }
}

@MainActor
final class OnlineReportTests: XCTestCase {
    private let key = "synthetic-api-key-for-contract-tests"
    private var configuration: OnlineReportConfiguration { .init(modelID: "synthetic-model", consentDate: Date(), preferredMode: .online) }
    private func completed(_ text: String = "{}") throws -> ReportHTTPResponse {
        .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["status": "completed", "model": "synthetic-snapshot-1",
            "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]))
    }
    func testRequestIsStatelessStrictAndContainsNoAuthenticationInBody() throws {
        let request = try OpenAIReportAPI.request(modelID: "synthetic-model", key: key, prompt: "Kein Fieber.", instructions: "Only source facts.", sections: ["Befunde"], sourceLimit: 4)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(key))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["background"] as? Bool, false)
        XCTAssertNil(body["tools"]); XCTAssertNil(body["previous_response_id"]); XCTAssertNil(body["conversation"])
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(format["type"] as? String, "json_schema")
    }
    func testIncompleteAndRefusedResponsesNeverBecomeReports() throws {
        for body in [
            #"{"status":"incomplete","model":"test","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#,
            #"{"status":"completed","model":"test","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#
        ] { XCTAssertThrowsError(try OpenAIReportAPI.result(.init(status: 200, data: Data(body.utf8)))) }
    }
    func testProviderFailureMakesOneRequestAndDoesNotRetry() async throws {
        let transport = StubReportTransport(.init(status: 429, data: Data()))
        var recorded: Data?
        var completion: String?
        let engine = OpenAIReportEngine(configuration: configuration, key: key, sections: ["Befunde"], transport: transport, record: { payload, _ in
            recorded = payload; return UUID()
        }, finish: { _, status, _ in completion = status })
        do { _ = try await engine.generate(prompt: "Synthetic", instructions: "Test"); XCTFail("429 must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Anbieterlimit")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1); XCTAssertNotNil(recorded)
        XCTAssertTrue(completion?.contains("kein automatischer Neuversand") == true)
    }
    func testConsentIsRequiredBeforeAnyNetworkCall() async throws {
        let transport = StubReportTransport(try completed())
        let config = OnlineReportConfiguration(modelID: "synthetic-model", preferredMode: .online)
        let engine = OpenAIReportEngine(configuration: config, key: key, sections: ["Befunde"], transport: transport)
        do { _ = try await engine.generate(prompt: "Synthetic", instructions: "Test"); XCTFail("No consent") } catch {}
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testRequestBudgetAndActualModelProvenance() async throws {
        let transport = StubReportTransport(try completed())
        let engine = OpenAIReportEngine(configuration: configuration, key: key, sections: ["Befunde"], transport: transport)
        for _ in 0..<12 { _ = try await engine.generate(prompt: "Synthetic", instructions: "Test") }
        do { _ = try await engine.generate(prompt: "Synthetic", instructions: "Test"); XCTFail("Budget exceeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("zwölf")) }
        let requests = await transport.requests; XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(engine.engineRevision, "synthetic-snapshot-1")
    }
    func testPipelineRetainsCloudProvenanceAndPerformsLocalValidation() async throws {
        let output = #"{"items":[{"section":"Befunde","text":"Kein Fieber.","segmentId":"q1","quote":"Kein Fieber."}]}"#
        let transport = StubReportTransport(try completed(output))
        let engine = OpenAIReportEngine(configuration: configuration, key: key, sections: ReportTemplate.treatment_report.sections, transport: transport)
        let transcript = TranscriptBuilder.edited("Kein Fieber.", previous: nil)
        let report = try await ReportPipeline(engine: engine).run(transcript: transcript, template: .treatment_report, length: .medium, audience: .veterinarian) { _ in }
        XCTAssertEqual(report.modelID, "openai/synthetic-model"); XCTAssertEqual(report.modelRevision, "synthetic-snapshot-1")
        XCTAssertEqual(report.content.sourceTranscriptVersionId, transcript.id.uuidString)
        XCTAssertNil(report.approvedAt)
    }
    func testKeychainStoresKeySeparatelyAndRemovingItDisablesOnline() throws {
        let store = OnlineReportStore(service: "de.tobwil.vetmed.synthetic-keys." + UUID().uuidString)
        defer { try? store.secure.delete("provider.openai.api-key"); try? store.secure.delete("online-report-configuration-v1") }
        try store.save(configuration, key: key)
        XCTAssertEqual(try store.key(), key)
        let profile = try store.configuration(); XCTAssertTrue(profile.isEnabled)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains(key))
        try store.removeKey()
        XCTAssertNil(try store.key()); XCTAssertFalse(try store.configuration().isEnabled)
        XCTAssertEqual(try store.configuration().preferredMode, .offline)
    }
    func testRequestSnapshotsRemainEncryptedAndAttachedToTheirOwnCase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let marker = "synthetic-cloud-payload-case-a"
        var encounter = Encounter()
        encounter.cloudReportRequests = [.init(modelID: "synthetic-model", transcriptVersionID: UUID(), payload: Data(marker.utf8))]
        var a = VetCase(label: "A", species: "Hund"); a.encounters = [encounter]
        var b = VetCase(label: "B", species: "Katze"); b.encounters = [Encounter()]
        let document = VaultDocument(cases: [a, b]); try await repo.save(document)
        let loaded = try await repo.load(); XCTAssertEqual(loaded, document)
        XCTAssertNil(loaded.cases[1].encounters[0].cloudReportRequests)
        let bytes = try Data(contentsOf: root.appendingPathComponent("cases.sqlite"))
        XCTAssertNil(bytes.range(of: Data(marker.utf8)))
    }
}
