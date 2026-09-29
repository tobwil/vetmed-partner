import Foundation

enum SparringRequestBuilder {
    static let maximumPayloadBytes = 98_304
    static let maximumOutputBytes = 262_144
    static func prepare(caseID: UUID?, encounter: Encounter, draft: SparringDraft, modelID: String) throws -> SparringSnapshot {
        try draft.validate()
        guard !draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("Bitte eine Frage eingeben.") }
        guard !modelID.isEmpty, modelID.utf8.count < 256, !modelID.contains(where: \.isWhitespace) else { throw AppFailure("Bitte eine gültige Modell-ID in Einstellungen auswählen.") }
        guard let url = Bundle.main.url(forResource: "sparring-v1", withExtension: "txt") else { throw AppFailure("Die Sparring-Anweisungen fehlen in diesem Build.") }
        let instructions = try String(contentsOf: url, encoding: .utf8)
        let selected = Set(draft.historyIDs)
        let runs = (encounter.analysisRuns ?? []).filter { selected.contains($0.id) }
        guard selected.count == draft.historyIDs.count, runs.count == selected.count,
              runs.allSatisfy({ $0.status == .completed && $0.snapshot.caseID == caseID && $0.snapshot.encounterID == encounter.id }) else {
            throw AppFailure("Der ausgewählte Verlauf ist unvollständig oder gehört nicht zu diesem Vorgang. Bitte die Auswahl prüfen.")
        }
        if let transcriptID = draft.transcriptVersionID, !encounter.transcripts.contains(where: { $0.id == transcriptID }) {
            throw AppFailure("Der ausgewählte Falltext gehört nicht zu diesem Vorgang.")
        }
        let selection = draft.attachmentIDs ?? []
        guard Set(selection).count == selection.count else { throw AppFailure("Ein Anhang wurde mehrfach ausgewählt.") }
        let attachments = encounter.chatAttachments ?? []
        var images: [ChatImageReference] = [], documents: [ChatDocumentReference] = []
        for id in selection {
            guard let attachment = attachments.first(where: { $0.id == id }) else { throw AppFailure("Ein ausgewählter Anhang fehlt in diesem Chat.") }
            if attachment.kind == .image {
                guard let hash = attachment.uploadSHA256, let bytes = attachment.uploadByteCount, let width = attachment.width, let height = attachment.height else { throw AppFailure("Das Versandbild ist nicht vollständig vorbereitet.") }
                images.append(.init(attachmentID: id, sha256: hash, byteCount: bytes, width: width, height: height))
            } else {
                guard attachment.reviewedAt != nil, let text = attachment.reviewedText else { throw AppFailure("Bitte den Text des Dokuments vor dem Senden prüfen.") }
                documents.append(.init(attachmentID: id, originalSHA256: attachment.originalSHA256, text: text))
            }
        }
        var current = SparringSnapshot(caseID: caseID, encounterID: encounter.id, modelID: modelID, draft: draft, payload: Data(), images: images, documents: documents)
        func message(text: String, images: [ChatImageReference]) -> [String: Any] {
            guard !images.isEmpty else { return ["role": "user", "content": text] }
            var content: [[String: Any]] = [["type": "input_text", "text": text]]
            for image in images { content.append(["type": "input_image", "image_url": image.placeholder, "detail": "high"]) }
            return ["role": "user", "content": content]
        }
        var messages: [[String: Any]] = []
        var allImages: [ChatImageReference] = []
        for run in runs {
            messages.append(message(text: run.snapshot.userText, images: run.snapshot.images ?? []))
            allImages += run.snapshot.images ?? []
            messages.append(["role": "assistant", "content": run.text])
        }
        messages.append(message(text: current.userText, images: images)); allImages += images
        guard allImages.count <= 8, allImages.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= ChatAttachmentImporter.maximumImageBytes && $0.width > 0 && $0.height > 0 }), allImages.reduce(0, { $0 + $1.byteCount }) <= 16 * 1_048_576 else {
            throw AppFailure("Dieser Chat enthält mehr Bilder als in eine Anfrage passen. Bitte für weitere Bilder einen neuen Chat starten; es wird nichts unbemerkt weggelassen.")
        }
        let body: [String: Any] = ["model": modelID, "store": false, "stream": true, "background": false,
                                   "max_output_tokens": 8192, "instructions": instructions, "input": messages]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= maximumPayloadBytes else { throw AppFailure("Der Chat ist für eine weitere Anfrage zu lang. Bitte einen neuen Chat starten. Es wird nichts unbemerkt weggelassen.") }
        current = SparringSnapshot(caseID: caseID, encounterID: encounter.id, modelID: modelID, draft: draft, payload: data, images: images, documents: documents, requestImages: allImages)
        return current
    }
    static func request(snapshot: SparringSnapshot, key: String, imageData: [UUID: Data] = [:]) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        guard snapshot.payload.count <= maximumPayloadBytes else { throw AppFailure("Die Anfrage ist zu groß.") }
        var body = snapshot.payload
        let references = snapshot.requestImages ?? []
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any], var input = object["input"] as? [[String: Any]] else { throw AppFailure("Die vorbereitete Anfrage ist ungültig.") }
        let imageParts = input.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "input_image" }
        guard imageParts.count == references.count else { throw AppFailure("Die Bildauswahl stimmt nicht mit der Anfrage überein.") }
        if !references.isEmpty {
            guard references.count <= 8, references.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= ChatAttachmentImporter.maximumImageBytes }), references.reduce(0, { $0 + $1.byteCount }) <= 16 * 1_048_576 else { throw AppFailure("Zu viele Bilddaten für eine Anfrage.") }
            var urls: [String: String] = [:]
            for ref in references {
                guard let data = imageData[ref.attachmentID], data.count == ref.byteCount, data.count <= ChatAttachmentImporter.maximumImageBytes,
                      ChatAttachmentImporter.digest(data) == ref.sha256 else { throw AppFailure("Ein Bild fehlt oder wurde verändert. Es wird nichts gesendet.") }
                urls[ref.placeholder] = "data:image/jpeg;base64," + data.base64EncodedString()
            }
            var count = 0
            for index in input.indices {
                guard var content = input[index]["content"] as? [[String: Any]] else { continue }
                for part in content.indices where content[part]["type"] as? String == "input_image" {
                    guard let placeholder = content[part]["image_url"] as? String, let url = urls[placeholder] else { throw AppFailure("Ein Bildbezug ist ungültig.") }
                    content[part]["image_url"] = url; count += 1
                }
                input[index]["content"] = content
            }
            guard count == references.count else { throw AppFailure("Die Bildauswahl stimmt nicht mit der Anfrage überein.") }
            object["input"] = input
            body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard body.count <= 24 * 1_048_576 else { throw AppFailure("Die Bildanfrage ist zu groß.") }
        }
        var request = URLRequest(url: OpenAIReportAPI.responseURL)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
}

/// Incremental SSE framing: limits apply before a newline arrives, including malicious long lines.
struct BoundedSSEDecoder {
    private var line = Data()
    private var fields = Data()
    private var totalBytes = 0
    mutating func feed(_ byte: UInt8) throws -> Data? {
        totalBytes += 1
        guard totalBytes <= 4_194_304, line.count < 524_288, fields.count < 524_288 else { throw AppFailure("Der Antwortstream überschreitet das Größenlimit.") }
        guard byte == 10 else { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !fields.isEmpty else { return nil }
            let data = fields; fields.removeAll(keepingCapacity: true); return data
        }
        let prefix = Data("data:".utf8)
        if line.starts(with: prefix) {
            var value = line.dropFirst(prefix.count)
            if value.first == 32 { value = value.dropFirst() }
            if !fields.isEmpty { fields.append(10) }
            guard fields.count + value.count <= 524_288 else { throw AppFailure("Ein Antwortabschnitt ist zu groß.") }
            fields.append(contentsOf: value)
        }
        return nil
    }
}

enum AnalysisStreamUpdate: Sendable {
    case text(String)
    case terminal(AnalysisStatus, String, String?, AnalysisUsage?, String?)
}

/// Only the provider's terminal event can mark a response complete. EOF never implies completion.
struct OpenAIAnalysisDecoder {
    private(set) var text = ""
    private(set) var terminal = false
    private var lastSequence: Int?
    private var sawRefusal = false
    private var activePart: String?
    private var partIDs = Set<String>()
    mutating func consume(_ data: Data) throws -> AnalysisStreamUpdate? {
        guard !terminal else { throw AppFailure("Unerwartete Daten nach Ende der Antwort.") }
        if data == Data("[DONE]".utf8) { return nil }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else {
            throw AppFailure("Der Anbieter hat ein ungültiges Streaming-Ereignis geliefert.")
        }
        if let sequence = event["sequence_number"] as? Int {
            guard lastSequence == nil || sequence > lastSequence! else { throw AppFailure("Die Reihenfolge der Antwort ist ungültig. Der Zwischenstand bleibt unvollständig.") }
            lastSequence = sequence
        }
        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String, let item = event["item_id"] as? String,
                  let index = event["content_index"] as? Int else { throw AppFailure("Ein Antwortabschnitt ist unvollständig.") }
            let part = item + ":" + String(index)
            if activePart != part {
                guard !partIDs.contains(part) else { throw AppFailure("Verschachtelte Antwortabschnitte können nicht sicher dargestellt werden.") }
                if !text.isEmpty { text += "\n\n" }
                activePart = part; partIDs.insert(part)
            }
            guard text.utf8.count + delta.utf8.count <= SparringRequestBuilder.maximumOutputBytes else { throw AppFailure("Die Antwort ist zu lang. Der Zwischenstand bleibt erhalten.") }
            text += delta
            return .text(text)
        case "response.refusal.delta", "response.refusal.done":
            sawRefusal = true
            return nil
        case "response.completed", "response.incomplete", "response.failed":
            guard let response = event["response"] as? [String: Any], let status = response["status"] as? String else { throw AppFailure("Der Abschlussstatus der Antwort fehlt.") }
            let model = response["model"] as? String
            var usage: AnalysisUsage?
            if let raw = response["usage"] as? [String: Any], let input = raw["input_tokens"] as? Int, let output = raw["output_tokens"] as? Int, input >= 0, output >= 0 {
                usage = AnalysisUsage(inputTokens: input, outputTokens: output)
            }
            let output = response["output"] as? [[String: Any]] ?? []
            let content = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            sawRefusal = sawRefusal || content.contains { $0["type"] as? String == "refusal" }
            let finalText = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            guard finalText.utf8.count <= SparringRequestBuilder.maximumOutputBytes else { throw AppFailure("Die Antwort ist zu lang.") }
            terminal = true
            if sawRefusal { return .terminal(.refused, text, model, usage, "Der Anbieter hat die Anfrage abgelehnt. Eine etwaige Teilantwort ist nicht vollständig.") }
            if type == "response.completed", status == "completed", !finalText.isEmpty {
                // Check the stream against the final object; never silently replace a differing partial answer.
                guard text.isEmpty || text == finalText else { throw AppFailure("Stream und Abschlussantwort stimmen nicht überein. Bitte den unvollständigen Zwischenstand prüfen.") }
                return .terminal(.completed, finalText, model, usage, nil)
            }
            return .terminal(status == "failed" ? .failed : .incomplete, text.isEmpty ? finalText : text, model, usage,
                             "Der Anbieter hat die Analyse nicht vollständig abgeschlossen. Ein neuer Versuch kann erneut Kosten verursachen.")
        case "error":
            throw AppFailure("Der Anbieter hat die Analyse abgebrochen. Der Zwischenstand bleibt unvollständig; kein automatischer Neuversand.")
        default: return nil
        }
    }
}

protocol AnalysisStreamingTransport: Sendable {
    func stream(_ request: URLRequest, receive: @escaping @Sendable (Data) async throws -> Bool) async throws
}
struct OpenAIAnalysisHTTP: AnalysisStreamingTransport {
    func stream(_ request: URLRequest, receive: @escaping @Sendable (Data) async throws -> Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false; configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 240
        let session = URLSession(configuration: configuration, delegate: DenyReportRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppFailure("Keine gültige Anbieterantwort.") }
            try OpenAIReportAPI.checkStatus(http.statusCode)
            guard http.mimeType == "text/event-stream" else { throw AppFailure("Das Modell liefert keinen unterstützten Antwortstream. Bitte ein anderes Textmodell auswählen.") }
            var decoder = BoundedSSEDecoder()
            var read = 0
            for try await byte in bytes {
                read += 1
                if read.isMultiple(of: 1024) { try Task.checkCancellation() }
                if let event = try decoder.feed(byte) {
                    try Task.checkCancellation()
                    if try await receive(event) { return }
                }
            }
            throw AppFailure("Die Verbindung endete vor dem Abschluss. Der Zwischenstand bleibt unvollständig. Ein neuer Versuch kann erneut Kosten verursachen.")
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if error.code == .notConnectedToInternet { throw AppFailure("Offline: Der Entwurf bleibt lokal. Bei Netzrückkehr wird nichts automatisch gesendet.") }
            throw AppFailure("Die Verbindung wurde unterbrochen. Eine Verarbeitung beim Anbieter kann bereits begonnen haben. Kein automatischer Neuversand.")
        }
    }
}

@MainActor
final class SparringService {
    private var decoder = OpenAIAnalysisDecoder()
    private let transport: any AnalysisStreamingTransport
    init(transport: any AnalysisStreamingTransport = OpenAIAnalysisHTTP()) { self.transport = transport }
    func run(snapshot: SparringSnapshot, key: String, imageData: [UUID: Data] = [:], beforeSending: @escaping @MainActor () async throws -> Void, receive: @escaping @MainActor (AnalysisStreamUpdate) async throws -> Void) async throws {
        try Task.checkCancellation()
        let request = try SparringRequestBuilder.request(snapshot: snapshot, key: key, imageData: imageData)
        try await beforeSending()
        try Task.checkCancellation()
        try await transport.stream(request) { [self] event in
            try await consume(event, receive: receive)
        }
        guard decoder.terminal else { throw AppFailure("Die Antwort wurde nicht vollständig abgeschlossen.") }
    }
    private func consume(_ event: Data, receive: @escaping @MainActor (AnalysisStreamUpdate) async throws -> Void) async throws -> Bool {
        try Task.checkCancellation()
        if let update = try decoder.consume(event) { try await receive(update) }
        return decoder.terminal
    }
}
