import XCTest
@testable import VetMed

/// Online first and the Gemini provider (ADR 0012, 0014). Same cases as Android; synthetic data, no network.
@MainActor
final class OnlineFirstTests: XCTestCase {
    func testProcessingIsOnlineFirstWithoutSilentSwitch() async throws {
        // Processing: same matrix as Android ProcessingTests.
        var configured = OnlineReportConfiguration(modelID: "gemini-3.6-flash", consentDate: Date(), preferredMode: .online, provider: .gemini)
        let undecided = GeminiTranscriptionConfiguration()
        XCTAssertTrue(Processing.transcription(online: configured, gemini: undecided, hasGeminiKey: false) == .device, "no key → device")
        XCTAssertTrue(Processing.transcription(online: configured, gemini: undecided, hasGeminiKey: true) == .ask, "undecided → ask")
        XCTAssertTrue(Processing.transcription(online: configured, gemini: .init(enabled: true, decidedAt: Date()), hasGeminiKey: true) == .online, "yes → online")
        XCTAssertTrue(Processing.transcription(online: configured, gemini: .init(enabled: false, decidedAt: Date()), hasGeminiKey: true) == .device, "no → device")
        XCTAssertTrue(Processing.reportMode(online: configured, hasKey: true) == .online, "report online")
        XCTAssertTrue(Processing.reportMode(online: configured, hasKey: false) == .offline, "report without key")
        configured.deviceOnly = true
        XCTAssertTrue(Processing.transcription(online: configured, gemini: .init(enabled: true, decidedAt: Date()), hasGeminiKey: true) == .device, "device only wins")
        XCTAssertTrue(Processing.reportMode(online: configured, hasKey: true) == .offline, "device only report")
        XCTAssertTrue(Processing.summary(online: configured, hasKey: true, transcription: .device).hasPrefix("Nur auf dem Gerät"), "summary")

        // Stores written before Gemini existed on iOS decode as OpenAI, never device-only.
        let legacy = try JSONDecoder().decode(OnlineReportConfiguration.self, from: Data(#"{"modelID":"m","preferredMode":"online","consentDate":0}"#.utf8))
        XCTAssertTrue(legacy.activeProvider == .openai && legacy.deviceOnly == nil && legacy.isEnabled, "legacy config")
        XCTAssertTrue(!OnlineReportConfiguration(sourceSearch: true, provider: .gemini).usesSourceSearch && OnlineReportConfiguration(sourceSearch: true).usesSourceSearch, "source search only openai")
    }

    func testOneGeminiKeyAndProviderSpecificRemoval() async throws {
        let key = "synthetic-gemini-key-for-contract-tests"
        // Store: one Gemini key for everything; removing it ends Gemini online only if Gemini was active.
        let store = OnlineReportStore(service: "de.tobwil.vetmed.unittest.online")
        defer { try? store.removeGeminiKey(); try? store.removeKey() }
        try store.save(OnlineReportConfiguration(modelID: "m", consentDate: Date(), preferredMode: .online, provider: .openai), key: "synthetic-openai-key-for-contract-tests")
        try store.saveGemini(.init(enabled: true, decidedAt: Date()), key: key)
        XCTAssertTrue(try store.key(for: .gemini) == key && store.key(for: .openai) == "synthetic-openai-key-for-contract-tests", "keys per provider")
        try store.removeGeminiKey()
        XCTAssertTrue(try store.geminiKey() == nil && store.geminiConfiguration() == .init() && store.configuration().isEnabled, "gemini removal keeps openai")
    }

    func testReportRequestKeepsKeyInHeaderAndRefusesIncompleteAnswers() async throws {
        let key = "synthetic-gemini-key-for-contract-tests"
        // Report request: key only in the header, strict schema.
        let report = try GeminiOnlineAPI.reportRequest(modelID: "gemini-3.6-flash", key: key, prompt: "P", instructions: "I", sections: ["Befunde"], sourceLimit: 3)
        XCTAssertTrue(report.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent", "report url")
        XCTAssertTrue(report.value(forHTTPHeaderField: "x-goog-api-key") == key && !String(decoding: report.httpBody!, as: UTF8.self).contains(key), "key header only")
        let schema = (json(report.httpBody)["generationConfig"] as? [String: Any])?["responseSchema"] as? [String: Any]
        XCTAssertTrue(schema?["required"] as? [String] == ["items"], "schema")
        await expectFailure("model with slash") { _ = try GeminiOnlineAPI.reportRequest(modelID: "../x", key: key, prompt: "P", instructions: "I", sections: ["B"], sourceLimit: 1) }
        let parsed = try GeminiOnlineAPI.reportResult(gemini(#"{"items":[]}"#), requestedModel: "m")
        XCTAssertTrue(parsed.text == #"{"items":[]}"# && parsed.model == "gemini-x-001", "thoughts dropped")
        await expectFailure("max tokens") { _ = try GeminiOnlineAPI.reportResult(gemini("x", reason: "MAX_TOKENS"), requestedModel: "m") }
        await expectFailure("blocked") { _ = try GeminiOnlineAPI.reportResult(.init(status: 200, data: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)), requestedModel: "m") }
        await expectFailure("401") { _ = try GeminiOnlineAPI.reportResult(.init(status: 401, data: Data()), requestedModel: "m") }
    }

    func testEngineFollowsConfiguredProvider() async throws {
        let key = "synthetic-gemini-key-for-contract-tests"
        // Engine selection follows the configured provider and records the request without the key.
        let fake = GeminiFakeHTTP([gemini("Antwort")])
        var recorded = Data()
        let engine = onlineReportEngine(configuration: OnlineReportConfiguration(modelID: "gemini-3.6-flash", consentDate: Date(), preferredMode: .online, provider: .gemini),
                                        key: key, sections: ["Befunde"], transport: fake, record: { payload, _ in recorded = payload; return UUID() })
        XCTAssertTrue(engine.engineID == "gemini/gemini-3.6-flash", "engine id")
        let answer = try await engine.generate(prompt: "P", instructions: "I")
        XCTAssertEqual(answer, "Antwort")
        XCTAssertTrue(!recorded.isEmpty && !String(decoding: recorded, as: UTF8.self).contains(key), "recorded without key")
    }

    func testChatSnapshotBecomesGeminiStreamRequest() async throws {
        let key = "synthetic-gemini-key-for-contract-tests"
        // Chat: the stored provider-neutral snapshot becomes a Gemini stream request.
        let snapshot = try SparringRequestBuilder.prepare(caseID: nil, encounter: Encounter(), draft: .init(question: "Frage"), modelID: "gemini-3.6-flash")
        let chat = try GeminiOnlineAPI.sparringRequest(snapshot: snapshot, key: key)
        XCTAssertTrue(chat.url?.absoluteString.hasSuffix("models/gemini-3.6-flash:streamGenerateContent?alt=sse") == true, "chat url")
        let body = json(chat.httpBody)
        XCTAssertTrue(((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String == json(snapshot.payload)["instructions"] as? String, "system instruction")
        XCTAssertTrue((body["contents"] as? [[String: Any]])?.last?["role"] as? String == "user", "user role")
        let searching = try SparringRequestBuilder.prepare(caseID: nil, encounter: Encounter(), draft: .init(question: "Frage"), modelID: "gemini-3.6-flash", sourceSearch: true)
        await expectFailure("source search never silently dropped") { _ = try GeminiOnlineAPI.sparringRequest(snapshot: searching, key: key) }

        // Streaming: deltas, then the chunk with finishReason is the only terminal event.
        let stream = GeminiFakeStream([#"{"candidates":[{"content":{"parts":[{"text":"Hal"}]}}]}"#,
                                 #"{"candidates":[{"content":{"parts":[{"text":"lo"}]},"finishReason":"STOP"}],"modelVersion":"g-1","usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}"#])
        var updates: [AnalysisStreamUpdate] = []
        try await SparringService(provider: .gemini, transport: stream).run(snapshot: snapshot, key: key, beforeSending: {}, receive: { updates.append($0) })
        XCTAssertTrue(stream.request?.value(forHTTPHeaderField: "x-goog-api-key") == key, "stream uses gemini request")
        guard case .terminal(.completed, "Hallo", "g-1", let usage, nil, _)? = updates.last else { XCTFail("completed \(updates)"); return }
        XCTAssertTrue(usage?.outputTokens == 2, "usage")
        var decoder = GeminiAnalysisDecoder()
        guard case .terminal(.refused, _, _, _, _, _)? = try decoder.consume(Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8)) else { XCTFail("refused"); return }
        await expectFailure("data after end") { _ = try decoder.consume(Data("{}".utf8)) }
    }

    func testTranscriptionSendsInlineWavRetriesAndChecksCount() async throws {
        let key = "synthetic-gemini-key-for-contract-tests"
        // Transcription: segments as inline WAV, retry on 503, strict count.
        let wav = try CAFAudio.wav(fromCAF: caf(samples: [1, 0, 2, 0]))
        let transcription = GeminiFakeHTTP([.init(status: 503, data: Data()), gemini(#"{"parts":[" Hund 12,5 kg. ",""]}"#)])
        let parts = try await GeminiTranscriptionAPI.transcribe(key: key, modelID: "gemini-3.6-flash", wavs: [wav, wav], vocabulary: ["Meloxicam"], transport: transcription, retryDelays: [.milliseconds(1)])
        XCTAssertTrue(parts == ["Hund 12,5 kg.", ""], "parts \(parts)")
        XCTAssertTrue(transcription.requests.count == 2, "retried once")
        let sentParts = ((json(transcription.requests[0].httpBody)["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
        XCTAssertTrue(sentParts.compactMap { ($0["inlineData"] as? [String: Any])?["mimeType"] as? String } == ["audio/wav", "audio/wav"], "inline wav")
        XCTAssertTrue((sentParts.first?["text"] as? String)?.contains("Meloxicam") == true, "vocabulary")
        await expectFailure("count mismatch") { _ = try GeminiTranscriptionAPI.parse(gemini(#"{"parts":["a"]}"#).data, expected: 2) }
        await expectFailure("404 not retried") {
            _ = try await GeminiTranscriptionAPI.transcribe(key: key, modelID: "m", wavs: [wav], transport: GeminiFakeHTTP([.init(status: 404, data: Data())]), retryDelays: [.milliseconds(1)])
        }

        // CAF → WAV: header, body, byte order, open-ended data chunk, unsupported formats.
        let bytes = [UInt8](wav)
        XCTAssertTrue(bytes.count == 48 && Array(bytes[0..<4]) == Array("RIFF".utf8) && Array(bytes[8..<12]) == Array("WAVE".utf8), "wav header")
        XCTAssertTrue(Array(bytes[24..<28]) == [0x80, 0x3E, 0, 0] && Array(bytes[44...]) == [1, 0, 2, 0], "rate and samples")
        XCTAssertTrue(Array(try CAFAudio.wav(fromCAF: caf(samples: [0, 1, 0, 2], littleEndian: false))[44...]) == [1, 0, 2, 0], "big endian swapped")
        XCTAssertTrue(Array(try CAFAudio.wav(fromCAF: caf(samples: [5, 0, 6, 0], dataSize: -1))[44...]) == [5, 0, 6, 0], "unfinished recording")
        await expectFailure("not lpcm") { _ = try CAFAudio.wav(fromCAF: caf(samples: [1, 0], format: "aac ")) }
        await expectFailure("not caf") { _ = try CAFAudio.wav(fromCAF: Data("RIFF....".utf8)) }
    }
}

private final class GeminiFakeHTTP: ReportHTTPTransport, @unchecked Sendable {
    var responses: [ReportHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [ReportHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> ReportHTTPResponse { requests.append(request); return responses.removeFirst() }
}
private final class GeminiFakeStream: AnalysisStreamingTransport, @unchecked Sendable {
    let events: [String]
    var request: URLRequest?
    init(_ events: [String]) { self.events = events }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (Data) async throws -> Bool) async throws {
        self.request = request
        for event in events { if try await receive(Data(event.utf8)) { return } }
        throw AppFailure("EOF")
    }
}
private func json(_ data: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:] }
private func gemini(_ text: String, reason: String = "STOP") -> ReportHTTPResponse {
    let body: [String: Any] = ["candidates": [["content": ["parts": [["text": "nachgedacht", "thought": true], ["text": text]]], "finishReason": reason]], "modelVersion": "gemini-x-001"]
    return .init(status: 200, data: try! JSONSerialization.data(withJSONObject: body))
}
@MainActor private func expectFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ block: () async throws -> Void) async {
    do { try await block(); XCTFail("expected failure: \(message)", file: file, line: line) } catch {}
}

/// CAF with 16-bit PCM as AVAudioRecorder writes it (big-endian header fields).
private func caf(samples: [UInt8], littleEndian: Bool = true, dataSize: Int64? = nil, format: String = "lpcm") -> Data {
    func be64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    var out: [UInt8] = Array("caff".utf8) + [0, 1, 0, 0]
    out += Array("desc".utf8) + be64(32) + be64(Double(16000).bitPattern) + Array(format.utf8) + be32(littleEndian ? 2 : 0) + be32(2) + be32(1) + be32(1) + be32(16)
    out += Array("free".utf8) + be64(4) + [0, 0, 0, 0]
    out += Array("data".utf8) + be64(UInt64(bitPattern: dataSize ?? Int64(samples.count + 4))) + [0, 0, 0, 0] + samples
    return Data(out)
}

