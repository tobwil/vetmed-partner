import Foundation

/// Gemini counterpart of the OpenAI report and chat contracts, ported from Android's `GeminiOnline.kt` (ADR 0012):
/// the same strict report items (as `responseSchema`), the same stored chat snapshot (translated to `contents` only
/// when sending) and the same "only the provider's final event completes an answer" rule. The key travels only in the
/// `x-goog-api-key` header, never in a URL or a stored request.
enum GeminiOnlineAPI {
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta/"

    static func checkModel(_ modelID: String) throws {
        guard !modelID.isEmpty, modelID.utf8.count < 256, !modelID.contains(where: { $0.isWhitespace || "/?:#".contains($0) }) else {
            throw AppFailure("Bitte eine gültige Modell-ID auswählen.")
        }
    }

    static func post(_ path: String, key: String, body: [String: Any], accept: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private static func text(_ value: String) -> [String: Any] { ["text": value] }

    // Reports -----------------------------------------------------------------------------------------

    static func reportRequest(modelID: String, key: String, prompt: String, instructions: String, sections: [String], sourceLimit: Int) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        try checkModel(modelID)
        guard (1...64).contains(sourceLimit), !sections.isEmpty else { throw AppFailure("Ungültiger Berichtsvertrag.") }
        let fields = ["section", "text", "segmentId", "quote"]
        let item: [String: Any] = ["type": "OBJECT",
            "properties": ["section": ["type": "STRING", "format": "enum", "enum": sections], "text": ["type": "STRING"],
                           "segmentId": ["type": "STRING", "format": "enum", "enum": (1...sourceLimit).map { "q\($0)" }], "quote": ["type": "STRING"]],
            "required": fields, "propertyOrdering": fields]
        let skip: [String: Any] = ["type": "OBJECT",
            "properties": ["segmentId": ["type": "STRING", "format": "enum", "enum": (1...sourceLimit).map { "q\($0)" }], "reason": ["type": "STRING"]],
            "required": ["segmentId", "reason"]]
        let body: [String: Any] = [
            "systemInstruction": ["parts": [text(instructions)]],
            "contents": [["role": "user", "parts": [text(prompt)]]],
            "generationConfig": ["maxOutputTokens": 32_768, "responseMimeType": "application/json",
                                 "responseSchema": ["type": "OBJECT", "properties": ["items": ["type": "ARRAY", "items": item], "skipped": ["type": "ARRAY", "items": skip]], "required": ["items"]]],
        ]
        return try post("models/\(modelID):generateContent", key: key, body: body)
    }

    static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw AppFailure("Gemini hat den API-Key abgewiesen. Bitte Key und freigeschaltete Gemini API prüfen.")
        case 429: throw AppFailure("Gemini-Kontingent erreicht. Bitte Abrechnung und Limits im Google-Konto prüfen und später bewusst erneut starten.")
        case 400, 404: throw AppFailure("Das ausgewählte Gemini-Modell oder das Berichtsformat wird nicht unterstützt. Bitte das Modell in Einstellungen testen.")
        default: throw AppFailure("Gemini vorübergehend nicht verfügbar (HTTP \(status)). Kein automatischer Anbieterwechsel oder erneuter Versand.")
        }
    }

    /// Final answer text of a non-streaming response; anything but a normal stop is refused.
    static func reportResult(_ response: ReportHTTPResponse, requestedModel: String) throws -> (text: String, model: String) {
        try checkStatus(response.status)
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw AppFailure("Die Anbieterantwort konnte nicht gelesen werden. Das Transkript bleibt erhalten.")
        }
        if let reason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw AppFailure("Gemini hat die Bearbeitung abgelehnt (\(reason)). Es wurde kein Bericht übernommen.")
        }
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { throw AppFailure("Gemini lieferte keinen Berichtstext.") }
        switch candidate["finishReason"] as? String {
        case "STOP": break
        case "MAX_TOKENS": throw AppFailure("Gemini hat die Antwort nicht vollständig abgeschlossen. Der Zwischenstand wird nicht als fertiger Bericht übernommen.")
        case let reason: throw AppFailure("Gemini hat die Bearbeitung abgelehnt oder abgebrochen (\(reason ?? "ohne Grund")). Es wurde kein Bericht übernommen.")
        }
        let value = answerText(candidate)
        guard !value.isEmpty else { throw AppFailure("Gemini lieferte keinen Berichtstext.") }
        return (value, root["modelVersion"] as? String ?? requestedModel)
    }

    /// Visible answer parts only; the model's own thoughts are never shown or stored.
    static func answerText(_ candidate: [String: Any]) -> String {
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
    }

    static func models(key: String, transport: any ReportHTTPTransport = EphemeralReportHTTP()) async throws -> [String] {
        try OnlineReportStore.validateKey(key)
        var request = URLRequest(url: URL(string: baseURL + "models?pageSize=1000")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let response = try await transport.send(request)
        try checkStatus(response.status)
        guard let models = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any])?["models"] as? [[String: Any]] else {
            throw AppFailure("Die Modellliste von Gemini konnte nicht gelesen werden.")
        }
        return models.filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
            .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
            .filter { $0.hasPrefix("gemini") }.sorted()
    }

    // Chat --------------------------------------------------------------------------------------------

    /// Translates the stored provider-neutral snapshot (OpenAI message shape, image placeholders) into a streaming
    /// Gemini request. Images are checked against their recorded SHA-256 exactly as for OpenAI.
    static func sparringRequest(snapshot: SparringSnapshot, key: String, imageData: [UUID: Data] = [:]) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        try checkModel(snapshot.modelID)
        guard snapshot.payload.count <= SparringRequestBuilder.maximumPayloadBytes else { throw AppFailure("Die Anfrage ist zu groß.") }
        // Source search is OpenAI-only (domain-limited). A request prepared with it is never silently sent without it.
        guard snapshot.sourceSearch != true else { throw AppFailure("Diese Anfrage wurde mit Quellensuche vorbereitet, die es nur mit OpenAI gibt. Bitte erneut senden.") }
        let invalid = AppFailure("Die vorbereitete Anfrage ist ungültig.")
        guard let root = try? JSONSerialization.jsonObject(with: snapshot.payload) as? [String: Any],
              let input = root["input"] as? [[String: Any]], let instructions = root["instructions"] as? String else { throw invalid }
        let references = snapshot.requestImages ?? []
        var images: [String: Data] = [:]
        for reference in references {
            guard let data = imageData[reference.attachmentID], data.count == reference.byteCount, data.count <= ChatAttachmentImporter.maximumImageBytes,
                  ChatAttachmentImporter.digest(data) == reference.sha256 else { throw AppFailure("Ein Bild fehlt oder wurde verändert. Es wird nichts gesendet.") }
            images[reference.placeholder] = data
        }
        var used = 0
        var contents: [[String: Any]] = []
        for message in input {
            let role: String
            switch message["role"] as? String { case "user": role = "user"; case "assistant": role = "model"; default: throw invalid }
            var parts: [[String: Any]] = []
            if let content = message["content"] as? String { parts.append(text(content)) }
            else if let content = message["content"] as? [[String: Any]] {
                for part in content {
                    switch part["type"] as? String {
                    case "input_text": guard let value = part["text"] as? String else { throw invalid }; parts.append(text(value))
                    case "input_image":
                        guard let placeholder = part["image_url"] as? String, let data = images[placeholder] else { throw AppFailure("Ein Bildbezug ist ungültig.") }
                        used += 1
                        parts.append(["inlineData": ["mimeType": "image/jpeg", "data": data.base64EncodedString()]])
                    default: throw invalid
                    }
                }
            } else { throw invalid }
            contents.append(["role": role, "parts": parts])
        }
        guard used == references.count else { throw AppFailure("Die Bildauswahl stimmt nicht mit der Anfrage überein.") }
        let request = try post("models/\(snapshot.modelID):streamGenerateContent?alt=sse", key: key, body: [
            "systemInstruction": ["parts": [text(instructions)]], "contents": contents, "generationConfig": ["maxOutputTokens": 32_768],
        ], accept: "text/event-stream")
        guard (request.httpBody?.count ?? 0) <= 24 * 1_048_576 else { throw AppFailure("Die Bildanfrage ist zu groß.") }
        return request
    }
}

/// Gemini SSE chunks carry text deltas; the chunk with a `finishReason` is the only terminal event.
struct GeminiAnalysisDecoder: AnalysisEventDecoder {
    private(set) var text = ""
    private(set) var terminal = false
    mutating func consume(_ data: Data) throws -> AnalysisStreamUpdate? {
        guard !terminal else { throw AppFailure("Unerwartete Daten nach Ende der Antwort.") }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure("Der Anbieter hat ein ungültiges Streaming-Ereignis geliefert.")
        }
        if event["error"] != nil { throw AppFailure("Der Anbieter hat die Analyse abgebrochen. Der Zwischenstand bleibt unvollständig; kein automatischer Neuversand.") }
        let model = event["modelVersion"] as? String
        var usage: AnalysisUsage?
        if let raw = event["usageMetadata"] as? [String: Any], let input = raw["promptTokenCount"] as? Int, let output = raw["candidatesTokenCount"] as? Int, input >= 0, output >= 0 {
            usage = AnalysisUsage(inputTokens: input, outputTokens: output)
        }
        if let reason = (event["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            terminal = true
            return .terminal(.refused, text, model, usage, "Der Anbieter hat die Anfrage abgelehnt (\(reason)).", [])
        }
        guard let candidate = (event["candidates"] as? [[String: Any]])?.first else { return nil }
        let delta = GeminiOnlineAPI.answerText(candidate)
        guard text.utf8.count + delta.utf8.count <= SparringRequestBuilder.maximumOutputBytes else { throw AppFailure("Die Antwort ist zu lang. Der Zwischenstand bleibt erhalten.") }
        text += delta
        guard let reason = candidate["finishReason"] as? String else { return delta.isEmpty ? nil : .text(text) }
        terminal = true
        if reason == "STOP", !text.isEmpty { return .terminal(.completed, text, model, usage, nil, []) }
        if ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "LANGUAGE"].contains(reason) {
            return .terminal(.refused, text, model, usage, "Der Anbieter hat die Anfrage abgelehnt (\(reason)). Eine etwaige Teilantwort ist nicht vollständig.", [])
        }
        if reason == "MAX_TOKENS" || reason == "STOP" {
            return .terminal(.incomplete, text, model, usage, "Der Anbieter hat die Analyse nicht vollständig abgeschlossen. Ein neuer Versuch kann erneut Kosten verursachen.", [])
        }
        return .terminal(.failed, text, model, usage, "Der Anbieter hat die Analyse abgebrochen (\(reason)). Ein neuer Versuch kann erneut Kosten verursachen.", [])
    }
}

/// Gemini report engine with the same request budget and provenance callbacks as `OpenAIReportEngine`.
@MainActor
final class GeminiReportEngine: ReportTextEngine {
    let configuration: OnlineReportConfiguration
    private let key: String
    private let sections: [String]
    private let transport: any ReportHTTPTransport
    private let record: (Data, String) async throws -> UUID
    private let finish: (UUID, String, String?) async throws -> Void
    private var calls = 0
    private var actualModels = Set<String>()
    var engineID: String { "gemini/" + configuration.modelID }
    var engineRevision: String { actualModels.isEmpty ? configuration.modelID : actualModels.sorted().joined(separator: ", ") }
    // Larger chunks keep long conversations within the request budget (ADR 0018).
    var sourceLimit: Int { 60 }
    var characterLimit: Int { 20000 }
    var executionLabel: String { "Gemini · online" }
    init(configuration: OnlineReportConfiguration, key: String, sections: [String], transport: any ReportHTTPTransport = EphemeralReportHTTP(),
         record: @escaping (Data, String) async throws -> UUID = { _, _ in UUID() },
         finish: @escaping (UUID, String, String?) async throws -> Void = { _, _, _ in }) {
        self.configuration = configuration; self.key = key; self.sections = sections; self.transport = transport; self.record = record; self.finish = finish
    }
    func generate(prompt: String, instructions: String) async throws -> String {
        try Task.checkCancellation()
        guard configuration.isEnabled else { throw AppFailure("Online-Berichte sind noch nicht aktiviert.") }
        guard calls < reportMaxCalls else { throw AppFailure("Das Limit von \(reportMaxCalls) Anbieteranfragen für diesen Bericht ist erreicht. Gesicherte Abschnitte bleiben erhalten.") }
        let request = try GeminiOnlineAPI.reportRequest(modelID: configuration.modelID, key: key, prompt: prompt, instructions: instructions, sections: sections, sourceLimit: sourceLimit)
        // The stored request record never contains the key: it is only in the header.
        let id = try await record(request.httpBody ?? Data(), configuration.modelID)
        calls += 1
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            let value = try GeminiOnlineAPI.reportResult(response, requestedModel: configuration.modelID); actualModels.insert(value.model)
            try await finish(id, "Antwort vollständig empfangen; fachliche Prüfung erforderlich", value.model)
            return value.text
        } catch {
            try? await finish(id, Task.isCancelled ? "Abgebrochen; Verarbeitung beim Anbieter möglicherweise begonnen" : "Fehlgeschlagen; kein automatischer Neuversand", nil)
            throw error
        }
    }
}

/// The engine for the configured provider; never a silent switch to another one.
@MainActor
func onlineReportEngine(configuration: OnlineReportConfiguration, key: String, sections: [String], transport: any ReportHTTPTransport = EphemeralReportHTTP(),
                        record: @escaping (Data, String) async throws -> UUID = { _, _ in UUID() },
                        finish: @escaping (UUID, String, String?) async throws -> Void = { _, _, _ in }) -> any ReportTextEngine {
    switch configuration.activeProvider {
    case .gemini: GeminiReportEngine(configuration: configuration, key: key, sections: sections, transport: transport, record: record, finish: finish)
    case .openai: OpenAIReportEngine(configuration: configuration, key: key, sections: sections, transport: transport, record: record, finish: finish)
    }
}

/// Several recorded segments in one `generateContent` request, one transcript per segment as strict JSON, so every
/// text stays tied to its audio segment (same contract as Android's `GeminiTranscriptionApi`).
enum GeminiTranscriptionAPI {
    /// Six 20-second segments ≈ 2 minutes ≈ 4 MB request, well below the 20 MB inline limit.
    static let batchSize = 6

    static func prompt(count: Int, vocabulary: [String]) -> String {
        var value = "Du erhältst \(count) aufeinanderfolgende Audioteile einer deutschsprachigen Diktat- oder Gesprächsaufnahme aus einer Tierarztpraxis. "
        value += "Transkribiere jeden Teil wortgetreu in normaler deutscher Rechtschreibung mit Satzzeichen. "
        value += "Ein Teil kann mitten im Wort beginnen oder enden; schreibe angeschnittene Wörter dem Teil zu, in dem sie überwiegend zu hören sind. "
        value += "Keine Zusammenfassung, keine Sprecherbezeichnungen, keine Zeitstempel, keine Kommentare. Erfinde nichts. "
        value += "Ist in einem Teil nichts Verständliches gesprochen, gib für ihn einen leeren String aus. "
        value += "Antworte nur mit JSON: {\"parts\": [...]} mit genau \(count) Strings in der Reihenfolge der Audioteile."
        if !vocabulary.isEmpty { value += " Fachbegriffe, die vorkommen können: " + vocabulary.joined(separator: ", ") + "." }
        return value
    }

    static func request(key: String, modelID: String, wavs: [Data], vocabulary: [String]) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        let model = modelID.trimmingCharacters(in: .whitespaces)
        try GeminiOnlineAPI.checkModel(model)
        var parts: [[String: Any]] = [["text": prompt(count: wavs.count, vocabulary: vocabulary)]]
        for (index, wav) in wavs.enumerated() {
            parts.append(["text": "Audioteil \(index + 1):"])
            parts.append(["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]])
        }
        return try GeminiOnlineAPI.post("models/\(model):generateContent", key: key, body: [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["responseMimeType": "application/json",
                                 "responseSchema": ["type": "OBJECT", "properties": ["parts": ["type": "ARRAY", "items": ["type": "STRING"]]], "required": ["parts"]],
                                 "thinkingConfig": ["thinkingLevel": "low"]],
        ])
    }

    /// Extracts the per-segment texts; refuses answers that do not match the number of segments sent.
    static func parse(_ data: Data, expected: Int) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure("Gemini hat keine lesbare Antwort geliefert.") }
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else {
            throw AppFailure("Gemini hat die Audioteile nicht transkribiert (keine Antwort, ggf. Sicherheitsfilter).")
        }
        let text = GeminiOnlineAPI.answerText(candidate)
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let parts = object["parts"] as? [String] else {
            throw AppFailure("Gemini hat das Transkript nicht im erwarteten Format geliefert (\(candidate["finishReason"] as? String ?? "unbekannt")).")
        }
        guard parts.count == expected else { throw AppFailure("Gemini hat \(parts.count) statt \(expected) Audioteile zurückgegeben. Bitte erneut transkribieren.") }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Rate limits and server errors are retried; everything else fails visibly.
    static func transcribe(key: String, modelID: String, wavs: [Data], vocabulary: [String] = [], transport: any ReportHTTPTransport = EphemeralReportHTTP(),
                           retryDelays: [Duration] = [.seconds(2), .seconds(6), .seconds(18)]) async throws -> [String] {
        let request = try request(key: key, modelID: modelID, wavs: wavs, vocabulary: vocabulary)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            if (200..<300).contains(response.status) { return try parse(response.data, expected: wavs.count) }
            if response.status == 429 || response.status >= 500, attempt < retryDelays.count {
                try await Task.sleep(for: retryDelays[attempt]); attempt += 1; continue
            }
            switch response.status {
            case 400: throw AppFailure("Gemini hat die Anfrage abgelehnt (400). Bitte API-Key und Modell-ID prüfen.")
            case 401, 403: throw AppFailure("Gemini hat den API-Key abgelehnt (\(response.status)). Bitte Key und freigeschaltete Gemini API prüfen.")
            case 404: throw AppFailure("Das Gemini-Modell „\(modelID)“ wurde nicht gefunden.")
            case 429: throw AppFailure("Gemini-Kontingent erschöpft (429). Bitte später erneut transkribieren; Fortschritt bleibt gespeichert.")
            default: throw AppFailure("Gemini ist gerade nicht erreichbar (\(response.status)). Bitte später erneut transkribieren; Fortschritt bleibt gespeichert.")
            }
        }
    }
}

/// The recorder writes 16-bit PCM in a CAF container; Gemini accepts WAV. Pure byte conversion, no audio APIs.
enum CAFAudio {
    static func wav(fromCAF data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let invalid = AppFailure("Ein Audioteil hat ein unerwartetes Format und kann nicht gesendet werden.")
        func be<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size { value = value << 8 | T(bytes[offset + index]) }
            return value
        }
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("caff".utf8) else { throw invalid }
        var offset = 8
        var sampleRate = 0.0, channels: UInt32 = 0, bits: UInt32 = 0, littleEndian = false
        var pcm: ArraySlice<UInt8>?
        while offset + 12 <= bytes.count {
            let type = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = be(offset + 4, Int64.self)
            let start = offset + 12
            // A data chunk of size -1 runs to the end of the file (recording ended without finalizing).
            let end = size < 0 ? bytes.count : min(bytes.count, start + Int(size))
            guard end >= start else { throw invalid }
            if type == "desc", end - start >= 32 {
                sampleRate = Double(bitPattern: be(start, UInt64.self))
                guard String(decoding: bytes[start + 8..<start + 12], as: UTF8.self) == "lpcm" else { throw invalid }
                littleEndian = be(start + 12, UInt32.self) & 2 != 0
                channels = be(start + 24, UInt32.self); bits = be(start + 28, UInt32.self)
            } else if type == "data", end - start >= 4 {
                pcm = bytes[(start + 4)..<end] // after the 4-byte edit count
            }
            if size < 0 { break }
            offset = end
        }
        guard var samples = pcm, bits == 16, channels >= 1, sampleRate >= 8000 else { throw invalid }
        if samples.count % 2 == 1 { samples = samples.dropLast() }
        var body = [UInt8](samples)
        if !littleEndian { for index in stride(from: 0, to: body.count - 1, by: 2) { body.swapAt(index, index + 1) } }
        func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        func le16(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        let rate = UInt32(sampleRate), blockAlign = UInt16(channels) * 2
        var header: [UInt8] = Array("RIFF".utf8) + le32(UInt32(36 + body.count)) + Array("WAVE".utf8)
        header += Array("fmt ".utf8) + le32(16) + le16(1) + le16(UInt16(channels)) + le32(rate) + le32(rate * UInt32(blockAlign)) + le16(blockAlign) + le16(16)
        header += Array("data".utf8) + le32(UInt32(body.count))
        return Data(header + body)
    }
}
