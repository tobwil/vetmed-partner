import XCTest
@testable import VetMed

/// Voice mode protocol (ADR 0016) against a fake connection; same cases as Android's `GeminiLiveTests`.
@MainActor
final class GeminiLiveTests: XCTestCase {
    private let key = "synthetic-gemini-key-for-contract-tests"
    private func json(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
    private func setupOf(_ text: String) -> [String: Any] { json(text)["setup"] as? [String: Any] ?? [:] }

    func testTheOneTimeTokenIsCreatedWithTheKeyInTheHeaderAndLockedToTheModel() async throws {
        let request = try GeminiLive.tokenRequest(key: key, now: Date(timeIntervalSince1970: 1794132000)) // 2026-11-08T10:00:00Z
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/auth_tokens")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertFalse(body.contains(key))
        let root = json(body)
        XCTAssertEqual(root["uses"] as? Int, 1)
        XCTAssertEqual(root["expireTime"] as? String, "2026-11-08T10:30:00Z")
        XCTAssertEqual(root["newSessionExpireTime"] as? String, "2026-11-08T10:01:00Z")
        XCTAssertEqual((root["bidiGenerateContentSetup"] as? [String: Any])?["model"] as? String, "models/gemini-3.8-live")
        XCTAssertEqual(try GeminiLive.token(.init(status: 200, data: Data(#"{"name":"auth_tokens/abc"}"#.utf8))), "auth_tokens/abc")
        for response in [ReportHTTPResponse(status: 401, data: Data()), .init(status: 200, data: Data("{}".utf8)), .init(status: 200, data: Data(#"{"name":"a b"}"#.utf8))] {
            XCTAssertThrowsError(try GeminiLive.token(response))
        }
        XCTAssertTrue(GeminiLive.socketURL(token: "auth_tokens/a+b").absoluteString.hasSuffix("BidiGenerateContentConstrained?access_token=auth_tokens%2Fa%2Bb"))
    }

    func testSetupCarriesTheSparringRulesTranscriptionAndNoSearch() async throws {
        let instructions = try GeminiLive.instructions(base: "# Rolle\nSparring.", context: "Laborbefund · Kreatinin 1,9")
        XCTAssertTrue(instructions.contains("Quellensuche: nicht aktiviert"))
        XCTAssertTrue(instructions.contains("# Sprachmodus"))
        // Found on a Pixel 9a: unclear audio made Gemini answer in French and Hindi.
        XCTAssertTrue(instructions.contains("SPRICH AUSSCHLIESSLICH DEUTSCH"))
        XCTAssertTrue(instructions.contains("Wechsle nie die Sprache"))
        XCTAssertTrue(instructions.hasSuffix("Laborbefund · Kreatinin 1,9"))
        XCTAssertFalse(try GeminiLive.instructions(base: "Basis", context: " ").contains("Fallkontext"))
        let setup = setupOf(GeminiLive.setup(instructions: instructions, vocabulary: ["Meloxicam", "Meloxicam", " ", "Robenacoxib"] + (1...200).map { "Begriff \($0)" }))
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.8-live")
        XCTAssertEqual((setup["generationConfig"] as? [String: Any])?["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertEqual((((setup["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first)?["text"] as? String, instructions)
        let vocabulary = (setup["inputAudioTranscription"] as? [String: Any])?["customVocabulary"] as? [String] ?? []
        XCTAssertEqual(vocabulary.count, 100)
        XCTAssertEqual(Array(vocabulary.prefix(2)), ["Meloxicam", "Robenacoxib"])
        XCTAssertNotNil(setup["outputAudioTranscription"])
        XCTAssertNotNil((setup["contextWindowCompression"] as? [String: Any])?["slidingWindow"])
        XCTAssertNil(setup["tools"])
        XCTAssertEqual((setup["sessionResumption"] as? [String: Any])?.count, 0)
        XCTAssertEqual((setupOf(GeminiLive.setup(instructions: "x", vocabulary: [], handle: "h1"))["sessionResumption"] as? [String: Any])?["handle"] as? String, "h1")
    }

    func testMessagesInBothDirections() async {
        let audio = (json(GeminiLive.audio(Data([1, 2, 3])))["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        XCTAssertEqual(audio?["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio?["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual((json(GeminiLive.audioStreamEnd())["realtimeInput"] as? [String: Any])?["audioStreamEnd"] as? Bool, true)
        XCTAssertEqual(GeminiLive.parse(#"{"setupComplete":{}}"#), [.setupComplete])
        let events = GeminiLive.parse(#"{"serverContent":{"inputTranscription":{"text":"Hund"},"outputTranscription":{"text":"Ja"},"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQI="}},{"text":"x"}]},"interrupted":true,"turnComplete":true}}"#)
        XCTAssertEqual(events, [.inputText("Hund"), .audio(Data([1, 2])), .outputText("Ja"), .interrupted, .turnComplete])
        XCTAssertEqual(GeminiLive.parse(#"{"goAway":{"timeLeft":"30s"}}"#), [.goAway(30)])
        XCTAssertEqual(GeminiLive.parse(#"{"sessionResumptionUpdate":{"newHandle":"h2","resumable":true}}"#), [.resumption("h2", true)])
        XCTAssertEqual(GeminiLive.parse(#"{"sessionResumptionUpdate":{"newHandle":"","resumable":false}}"#), [.resumption(nil, false)])
        XCTAssertEqual(GeminiLive.parse(#"{"voiceActivity":{"type":"ACTIVITY_START"}}"#), [])
        if case .failure = GeminiLive.parse("kein json").first {} else { XCTFail("failure expected") }
    }

    func testTheTranscriptJoinsChunksAndMarksInterruptions() async {
        var turns: [LiveTurn] = []
        for event: GeminiLive.Event in [.inputText("Hund mit"), .inputText(" Lahmheit"), .inputText("."), .outputText("Seit wann"), .outputText("?"), .turnComplete,
                                        .inputText("Seit gestern"), .outputText("Dann zuerst"), .interrupted] { turns = LiveTranscript.apply(turns, event) }
        XCTAssertEqual(turns.map(\.text), ["Hund mit Lahmheit.", "Seit wann?", "Seit gestern", "Dann zuerst"])
        XCTAssertTrue(turns.last!.interrupted && !turns.contains { $0.open })
        XCTAssertEqual(LiveTranscript.markdown(turns), "**Du:** Hund mit Lahmheit.\n\n**VetMed:** Seit wann?\n\n**Du:** Seit gestern\n\n**VetMed:** Dann zuerst _(unterbrochen)_")
        XCTAssertEqual(GeminiLive.costUSD(inputSeconds: 60, outputSeconds: 60), 0.023, accuracy: 1e-9)
    }

    func testASessionConnectsStreamsAndResumesAfterGoAway() async throws {
        let server = FakeLiveServer()
        let tokens = TokenTransport()
        let session = LiveSession(key: key, instructions: "Anweisungen", vocabulary: ["Meloxicam"], connector: server, transport: tokens)
        var played: [Data] = []; var interruptions = 0
        session.onAudio = { played.append($0) }; session.onInterrupted = { interruptions += 1 }
        await session.start()
        let first = try XCTUnwrap(server.sockets.first)
        XCTAssertTrue(server.urls.first!.absoluteString.hasSuffix("access_token=auth_tokens%2Ft1"))
        XCTAssertEqual(first.sent.count, 1)
        session.sendAudio(Data(count: 3200))
        XCTAssertEqual(first.sent.count, 1, "Audio vor setupComplete wird verworfen")
        first.message(#"{"setupComplete":{}}"#)
        XCTAssertEqual(session.state, .live)
        session.sendAudio(Data(count: 32_000))
        XCTAssertEqual(session.inputSeconds, 1, accuracy: 1e-9)
        first.message(#"{"serverContent":{"inputTranscription":{"text":"Hund lahmt"}}}"#)
        first.message(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQIDBA=="}}]}}}"#)
        first.message(#"{"serverContent":{"outputTranscription":{"text":"Seit wann?"},"turnComplete":true}}"#)
        XCTAssertEqual(played.count, 1)
        first.message(#"{"serverContent":{"interrupted":true}}"#)
        XCTAssertEqual(interruptions, 1)
        first.message(#"{"sessionResumptionUpdate":{"newHandle":"h1","resumable":true}}"#)
        first.message(#"{"goAway":{"timeLeft":"10s"}}"#)
        XCTAssertEqual(session.state, .resuming)
        for _ in 0..<20 where server.sockets.count < 2 { await Task.yield() }
        let second = try XCTUnwrap(server.sockets.dropFirst().first)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertTrue(first.closed)
        first.close(failure: nil)
        XCTAssertEqual((setupOf(second.sent.first!)["sessionResumption"] as? [String: Any])?["handle"] as? String, "h1")
        second.message(#"{"setupComplete":{}}"#)
        second.message(#"{"serverContent":{"outputTranscription":{"text":"Weiter."},"turnComplete":true}}"#)
        XCTAssertEqual(session.turns.map(\.text), ["Hund lahmt", "Seit wann?", "Weiter."])
        first.message(#"{"serverContent":{"outputTranscription":{"text":"alt"}}}"#)
        XCTAssertEqual(session.turns.count, 3)
        session.stop()
        XCTAssertEqual(session.state, .ended(nil))
        XCTAssertTrue(second.closed)
    }

    func testALostConnectionEndsVisiblyAndARefusedTokenIsReported() async throws {
        let server = FakeLiveServer()
        let tokens = TokenTransport()
        let session = LiveSession(key: key, instructions: "x", vocabulary: [], connector: server, transport: tokens)
        await session.start()
        server.sockets[0].message(#"{"setupComplete":{}}"#)
        server.sockets[0].message(#"{"serverContent":{"outputTranscription":{"text":"Ich hö"}}}"#)
        server.sockets[0].close(failure: "reset")
        guard case .ended(let message?) = session.state else { return XCTFail("ended expected") }
        XCTAssertTrue(message.contains("unterbrochen"))
        XCTAssertEqual(tokens.count, 1)
        XCTAssertFalse(session.turns.first!.open)

        let refused = LiveSession(key: key, instructions: "x", vocabulary: [], connector: FakeLiveServer(), transport: TokenTransport(status: 403))
        await refused.start()
        guard case .ended(let reason?) = refused.state else { return XCTFail("ended expected") }
        XCTAssertTrue(reason.contains("abgewiesen"))
    }

    func testInterruptingLocallyDropsTheRestOfTheAnswer() async throws {
        let server = FakeLiveServer()
        let session = LiveSession(key: key, instructions: "x", vocabulary: [], connector: server, transport: TokenTransport())
        var played = 0, stops = 0
        session.onAudio = { _ in played += 1 }; session.onInterrupted = { stops += 1 }
        await session.start()
        let socket = server.sockets[0]
        socket.message(#"{"setupComplete":{}}"#)
        socket.message(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"AQI="}}]},"outputTranscription":{"text":"Lange Antwort"}}}"#)
        session.interrupt()
        socket.message(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"AwQ="}}]}}}"#)
        XCTAssertEqual(played, 1); XCTAssertEqual(stops, 1)
        XCTAssertTrue(session.turns.last!.interrupted)
        socket.message(#"{"serverContent":{"turnComplete":true}}"#)
        socket.message(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"BQY="}}]}}}"#)
        XCTAssertEqual(played, 2)
        session.pauseInput()
        XCTAssertNotNil((json(socket.sent.last!)["realtimeInput"] as? [String: Any])?["audioStreamEnd"])
    }
}

@MainActor
private final class FakeLiveServer: LiveConnector {
    final class Socket: LiveSocket {
        var sent: [String] = []
        var closed = false
        var onMessage: (String) -> Void = { _ in }
        var onClose: (String?) -> Void = { _ in }
        func send(_ text: String) { if !closed { sent.append(text) } }
        func close() { closed = true }
        func message(_ text: String) { onMessage(text) }
        func close(failure: String?) { onClose(failure) }
    }
    var urls: [URL] = []
    var sockets: [Socket] = []
    func connect(url: URL, onOpen: @escaping @MainActor () -> Void, onMessage: @escaping @MainActor (String) -> Void,
                 onClose: @escaping @MainActor (String?) -> Void) -> any LiveSocket {
        let socket = Socket()
        socket.onMessage = onMessage; socket.onClose = onClose
        urls.append(url); sockets.append(socket)
        onOpen() // opens before connect() returns, like a fast handshake
        return socket
    }
}

private final class TokenTransport: ReportHTTPTransport, @unchecked Sendable {
    let status: Int
    var count = 0
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> ReportHTTPResponse {
        count += 1
        return .init(status: status, data: Data(#"{"name":"auth_tokens/t\#(count)"}"#.utf8))
    }
}
