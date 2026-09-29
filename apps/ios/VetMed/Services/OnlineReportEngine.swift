import Foundation

enum ReportExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case online, offline
    var id: String { rawValue }
    var title: String { self == .online ? "Online" : "Offline · optional" }
}

struct OnlineReportConfiguration: Codable, Equatable, Sendable {
    var modelID = ""
    var consentDate: Date?
    var preferredMode: ReportExecutionMode = .offline
    var verifiedModelID: String?
    var verifiedAt: Date?
    var isEnabled: Bool { consentDate != nil && !modelID.isEmpty }
}

struct CloudReportRequest: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var provider = "OpenAI"
    var modelID: String
    var transcriptVersionID: UUID
    var payload: Data
    var status = "Versand begonnen; Ergebnis noch unbekannt"
    var responseModelID: String?
}

struct OnlineReportStore: Sendable {
    let secure: SecureStore
    init(service: String = "de.tobwil.vetmed.secrets") { secure = SecureStore(service: service) }
    func configuration() throws -> OnlineReportConfiguration {
        guard let data = try secure.read("online-report-configuration-v1") else { return .init() }
        return try JSONDecoder().decode(OnlineReportConfiguration.self, from: data)
    }
    func key() throws -> String? { try secure.read("provider.openai.api-key").flatMap { String(data: $0, encoding: .utf8) } }
    func save(_ configuration: OnlineReportConfiguration, key: String? = nil) throws {
        if let key { try Self.validateKey(key); try secure.write(Data(key.utf8), account: "provider.openai.api-key") }
        try secure.write(try JSONEncoder().encode(configuration), account: "online-report-configuration-v1")
    }
    func removeKey() throws {
        var configuration = try configuration(); configuration.preferredMode = .offline; configuration.consentDate = nil
        try save(configuration); try secure.delete("provider.openai.api-key")
    }
    static func validateKey(_ key: String) throws {
        guard (20...1024).contains(key.utf8.count), key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw AppFailure("Bitte einen gültigen API-Key ohne Leerzeichen oder Zeilenumbrüche eingeben.")
        }
    }
}

struct ReportHTTPResponse: Sendable { var status: Int; var data: Data }
protocol ReportHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> ReportHTTPResponse }

final class DenyReportRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
struct EphemeralReportHTTP: ReportHTTPTransport {
    func send(_ request: URLRequest) async throws -> ReportHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.waitsForConnectivity = false; config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: DenyReportRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppFailure("Keine gültige Anbieterantwort.") }
            guard (200..<300).contains(http.statusCode) else { return .init(status: http.statusCode, data: Data()) }
            var data = Data()
            for try await byte in bytes {
                if data.count.isMultiple(of: 1024) { try Task.checkCancellation() }
                guard data.count < 4_194_304 else { throw AppFailure("Die Anbieterantwort überschreitet das sichere Größenlimit.") }
                data.append(byte)
            }
            return .init(status: http.statusCode, data: data)
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if error.code == .notConnectedToInternet { throw AppFailure("Keine Internetverbindung. Das Transkript bleibt lokal. Es wird später nichts automatisch gesendet.") }
            throw AppFailure("Die Verbindung zum Anbieter wurde unterbrochen. Der Auftrag kann bereits berechnet worden sein. Ein erneuter Versuch startet einen neuen Auftrag.")
        }
    }
}

enum OpenAIReportAPI {
    static let responseURL = URL(string: "https://api.openai.com/v1/responses")!
    static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    static func request(modelID: String, key: String, prompt: String, instructions: String, sections: [String], sourceLimit: Int) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        guard (1...64).contains(sourceLimit), !sections.isEmpty else { throw AppFailure("Ungültiger Berichtsvertrag.") }
        guard !modelID.isEmpty, modelID.utf8.count < 256, !modelID.contains(where: \.isWhitespace) else { throw AppFailure("Bitte eine gültige Modell-ID auswählen.") }
        let item: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["section": ["type": "string", "enum": sections], "text": ["type": "string"],
                           "segmentId": ["type": "string", "enum": (1...sourceLimit).map { "q\($0)" }], "quote": ["type": "string"]],
            "required": ["section", "text", "segmentId", "quote"]]
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "properties": ["items": ["type": "array", "items": item]], "required": ["items"]]
        let body: [String: Any] = ["model": modelID, "store": false, "stream": false, "background": false,
            "max_output_tokens": 8192, "instructions": instructions,
            "input": [["role": "user", "content": [["type": "input_text", "text": prompt]]]],
            "text": ["format": ["type": "json_schema", "name": "veterinary_report_items_v1", "strict": true, "schema": schema]]]
        var request = URLRequest(url: responseURL); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
    static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw AppFailure("API-Key oder Berechtigung abgewiesen. Bitte die Anbietereinstellungen prüfen.")
        case 429: throw AppFailure("Anbieterlimit erreicht. Bitte Guthaben und Kontolimits prüfen und später bewusst erneut starten.")
        case 400, 404, 422: throw AppFailure("Das ausgewählte Modell oder das Berichtsformat wird vom Anbieter nicht unterstützt. Bitte das Modell in Einstellungen testen.")
        default: throw AppFailure("Anbieter vorübergehend nicht verfügbar (HTTP \(status)). Kein automatischer Anbieterwechsel oder erneuter Versand.")
        }
    }
    struct Result: Decodable {
        struct Item: Decodable {
            struct Content: Decodable { var type: String; var text: String?; var refusal: String? }
            var type: String
            var content: [Content]?
        }
        var status: String
        var model: String
        var output: [Item]
    }
    static func result(_ response: ReportHTTPResponse) throws -> (text: String, model: String) {
        try checkStatus(response.status)
        let value: Result
        do { value = try JSONDecoder().decode(Result.self, from: response.data) }
        catch { throw AppFailure("Die Anbieterantwort konnte nicht gelesen werden. Das Transkript bleibt erhalten.") }
        guard value.status == "completed" else { throw AppFailure("Der Anbieter hat die Antwort nicht vollständig abgeschlossen. Der Zwischenstand wird nicht als fertiger Bericht übernommen.") }
        let content = value.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        guard !content.contains(where: { $0.type == "refusal" }) else { throw AppFailure("Der Anbieter hat die Bearbeitung abgelehnt. Es wurde kein Bericht übernommen.") }
        let text = content.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AppFailure("Der Anbieter lieferte keinen Berichtstext.") }
        return (text, value.model)
    }
    static func models(key: String, transport: any ReportHTTPTransport = EphemeralReportHTTP()) async throws -> [String] {
        try OnlineReportStore.validateKey(key)
        var request = URLRequest(url: modelsURL); request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request); try checkStatus(response.status)
        struct List: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
        return try JSONDecoder().decode(List.self, from: response.data).data.map(\.id).sorted()
    }
}

@MainActor
final class OpenAIReportEngine: ReportTextEngine {
    let configuration: OnlineReportConfiguration
    private let key: String
    private let sections: [String]
    private let transport: any ReportHTTPTransport
    private let record: (Data, String) async throws -> UUID
    private let finish: (UUID, String, String?) async throws -> Void
    private var calls = 0
    private var actualModels = Set<String>()
    var engineID: String { "openai/" + configuration.modelID }
    var engineRevision: String { actualModels.isEmpty ? configuration.modelID : actualModels.sorted().joined(separator: ", ") }
    var sourceLimit: Int { 24 }
    var characterLimit: Int { 12000 }
    var executionLabel: String { "OpenAI · online" }
    init(configuration: OnlineReportConfiguration, key: String, sections: [String], transport: any ReportHTTPTransport = EphemeralReportHTTP(),
         record: @escaping (Data, String) async throws -> UUID = { _, _ in UUID() },
         finish: @escaping (UUID, String, String?) async throws -> Void = { _, _, _ in }) {
        self.configuration = configuration; self.key = key; self.sections = sections; self.transport = transport; self.record = record; self.finish = finish
    }
    func generate(prompt: String, instructions: String) async throws -> String {
        try Task.checkCancellation()
        guard configuration.isEnabled else { throw AppFailure("Online-Berichte sind noch nicht aktiviert.") }
        guard calls < 12 else { throw AppFailure("Das Limit von zwölf Anbieteranfragen für diesen Bericht ist erreicht. Gesicherte Abschnitte bleiben erhalten.") }
        let request = try OpenAIReportAPI.request(modelID: configuration.modelID, key: key, prompt: prompt, instructions: instructions, sections: sections, sourceLimit: sourceLimit)
        let id = try await record(request.httpBody ?? Data(), configuration.modelID)
        calls += 1
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            let value = try OpenAIReportAPI.result(response); actualModels.insert(value.model)
            try await finish(id, "Antwort vollständig empfangen; fachliche Prüfung erforderlich", value.model)
            return value.text
        } catch {
            try? await finish(id, Task.isCancelled ? "Abgebrochen; Verarbeitung beim Anbieter möglicherweise begonnen" : "Fehlgeschlagen; kein automatischer Neuversand", nil)
            throw error
        }
    }
}
