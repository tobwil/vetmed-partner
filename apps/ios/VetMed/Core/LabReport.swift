import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lab results as a checked table (ADR 0015). Same rules and texts as Android's `LabReport.kt`.
enum LabEvidence: String, Codable, Sendable {
    /// Every number of value and reference appears in the locally read original.
    case found
    /// At least one number does not appear in the local text: check against the original.
    case notFound
    /// No local text to compare with.
    case unchecked
    /// Typed or changed by the user.
    case edited
    /// Read on the device only (line parser): always to be checked.
    case local
}

/// The app's own reading of a value against the printed reference. Never taken from a model.
enum LabAssessment: Sendable {
    case low, normal, high, unknown
    var label: String { switch self { case .low: "niedrig"; case .normal: "im Bereich"; case .high: "hoch"; case .unknown: "nicht bewertbar" } }
    var symbol: String { switch self { case .low: "↓"; case .normal: ""; case .high: "↑"; case .unknown: "?" } }
    var text: String { (symbol + " " + label).trimmingCharacters(in: .whitespaces) }
}

struct LabValue: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var parameter: String
    var value: String
    var unit = ""
    /// Reference range exactly as printed by the laboratory; empty when none is printed.
    var reference = ""
    /// The laboratory's own printed flag (H, L, +, ↑ …); empty when none is printed.
    var flag = ""
    var page = 1
    var evidence: LabEvidence = .unchecked
    var uncertain = false
    var assessment: LabAssessment { LabMath.assess(value, reference: reference) }
    var flagConflict: Bool { LabMath.flagConflict(flag, assessment) }
    var needsCheck: Bool { uncertain || flagConflict || evidence == .notFound || evidence == .local }
}

struct LabReport: Codable, Equatable, Sendable {
    var laboratory = ""
    var sampleDate = ""
    var values: [LabValue] = []
    /// How the table was read, e.g. "Gemini gemini-3.6-flash · Seitenbilder".
    var method: String
    var readAt = Date()
    var pages = 0
    var confirmedAt: Date?
    var openChecks: Int { values.filter(\.needsCheck).count }
}

/// Numbers and reference ranges as printed on German lab reports. Deterministic; the model never assesses.
enum LabMath {
    private static let numberPattern = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#)

    /// "12,5" and "0.8" are decimals. With both separators the last one is the decimal mark. A single separator is
    /// always a decimal mark, because lab values rarely use thousands separators.
    static func number(_ text: String) -> Double? {
        let raw = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == ".") }), raw.first!.isNumber, raw.last!.isNumber else { return nil }
        let commas = raw.filter { $0 == "," }.count, dots = raw.filter { $0 == "." }.count
        let normalized: String
        if commas > 0, dots > 0 {
            let decimalIsComma = raw.lastIndex(of: ",")! > raw.lastIndex(of: ".")!
            normalized = raw.replacingOccurrences(of: decimalIsComma ? "." : ",", with: "").replacingOccurrences(of: ",", with: ".")
        } else if commas > 0 {
            guard commas == 1 else { return nil }; normalized = raw.replacingOccurrences(of: ",", with: ".")
        } else {
            guard dots <= 1 else { return nil }; normalized = raw
        }
        return Double(normalized)
    }

    static func numbers(_ text: String) -> [Double] {
        numberPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Swift.Range($0.range, in: text).flatMap { number(String(text[$0])) } }
    }

    struct Range: Equatable { var low: Double?; var high: Double?; var lowInclusive = true; var highInclusive = true }

    private static let between = try! NSRegularExpression(pattern: #"^(?:von\s*)?(\d+(?:[.,]\d+)*)\s*(?:-|–|—|bis|\.\.\.?)\s*(\d+(?:[.,]\d+)*)$"#, options: [.caseInsensitive])
    private static let bound = try! NSRegularExpression(pattern: #"^(<=|>=|≤|≥|<|>|bis|unter|über|ab|max\.?|min\.?)\s*(\d+(?:[.,]\d+)*)$"#, options: [.caseInsensitive])

    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Swift.Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    /// The printed reference as a range, or nil when it is not unambiguous (text, several ranges, sex-specific …).
    static func reference(_ text: String) -> Range? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("("), value.hasSuffix(")") { value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty else { return nil }
        if let parts = groups(between, value) {
            guard let low = number(parts[0]), let high = number(parts[1]), low <= high else { return nil }
            return Range(low: low, high: high)
        }
        if let parts = groups(bound, value), let limit = number(parts[1]) {
            switch parts[0].lowercased() {
            case "<", "unter": return Range(low: nil, high: limit, highInclusive: false)
            case "<=", "≤", "bis", "max", "max.": return Range(low: nil, high: limit)
            case ">", "über": return Range(low: limit, high: nil, lowInclusive: false)
            case ">=", "≥", "ab", "min", "min.": return Range(low: limit, high: nil)
            default: return nil
            }
        }
        return nil
    }

    static func assess(_ value: String, reference text: String) -> LabAssessment {
        guard let number = number(value), let range = reference(text) else { return .unknown }
        if let low = range.low, number < low || (!range.lowInclusive && number == low) { return .low }
        if let high = range.high, number > high || (!range.highInclusive && number == high) { return .high }
        return .normal
    }

    /// H/↑ and L/↓ are read as high and low; other marks (+, -, *) have laboratory-specific meanings.
    static func flagConflict(_ flag: String, _ assessment: LabAssessment) -> Bool {
        let mark = flag.trimmingCharacters(in: .whitespaces).uppercased()
        let high = ["H", "HH", "↑", "↑↑"].contains(mark), low = ["L", "LL", "↓", "↓↓"].contains(mark)
        return (high && (assessment == .normal || assessment == .low)) || (low && (assessment == .normal || assessment == .high))
    }
}

/// Reading a lab result: page images to the chosen model with a strict schema (transcription only), every number
/// looked up again in the locally read text, and the user confirms the table at the original.
enum LabExtraction {
    static let maxPages = 6
    static let maxPageBytes = 2 * 1_048_576
    static let maxValues = 300
    private static let fields = ["parameter", "value", "unit", "reference", "flag", "page", "uncertain"]

    static func instructions() throws -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "lab-extraction-v1", withExtension: "txt") else { throw AppFailure("Die Anweisungen zum Lesen von Laborbefunden fehlen in diesem Build.") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func check(_ pages: [Data]) throws {
        guard (1...maxPages).contains(pages.count) else { throw AppFailure("Bitte einen Befund mit 1 bis \(maxPages) Seiten wählen.") }
        guard pages.allSatisfy({ !$0.isEmpty && $0.count <= maxPageBytes }) else { throw AppFailure("Eine Befundseite ist zu groß für den Versand.") }
    }
    private static func prompt(_ pages: Int) -> String { "Übertrage alle Messwerte dieses Laborbefunds (\(pages) \(pages == 1 ? "Seite" : "Seiten")) in die Tabelle." }

    static func openAIRequest(modelID: String, key: String, pages: [Data]) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        try check(pages)
        guard !modelID.isEmpty, !modelID.contains(where: \.isWhitespace) else { throw AppFailure("Bitte eine gültige Modell-ID auswählen.") }
        var properties: [String: Any] = ["page": ["type": "integer"], "uncertain": ["type": "boolean"]]
        for name in ["parameter", "value", "unit", "reference", "flag"] { properties[name] = ["type": "string"] }
        let row: [String: Any] = ["type": "object", "additionalProperties": false, "properties": properties, "required": fields]
        var content: [[String: Any]] = [["type": "input_text", "text": prompt(pages.count)]]
        for page in pages { content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + page.base64EncodedString(), "detail": "high"]) }
        let body: [String: Any] = ["model": modelID, "store": false, "stream": false, "background": false, "max_output_tokens": 16_384,
            "instructions": try instructions(), "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "veterinary_lab_table_v1", "strict": true, "schema": [
                "type": "object", "additionalProperties": false, "required": ["laboratory", "sampleDate", "values"],
                "properties": ["laboratory": ["type": "string"], "sampleDate": ["type": "string"], "values": ["type": "array", "items": row]]]]]]
        var request = URLRequest(url: OpenAIReportAPI.responseURL)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func geminiRequest(modelID: String, key: String, pages: [Data]) throws -> URLRequest {
        try OnlineReportStore.validateKey(key)
        try check(pages)
        try GeminiOnlineAPI.checkModel(modelID)
        var properties: [String: Any] = ["page": ["type": "INTEGER"], "uncertain": ["type": "BOOLEAN"]]
        for name in ["parameter", "value", "unit", "reference", "flag"] { properties[name] = ["type": "STRING"] }
        let row: [String: Any] = ["type": "OBJECT", "properties": properties, "required": fields, "propertyOrdering": fields]
        var parts: [[String: Any]] = [["text": prompt(pages.count)]]
        for page in pages { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": page.base64EncodedString()]]) }
        var request = try GeminiOnlineAPI.post("models/\(modelID):generateContent", key: key, body: [
            "systemInstruction": ["parts": [["text": try instructions()]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": 32_768, "responseMimeType": "application/json", "responseSchema": [
                "type": "OBJECT", "required": ["laboratory", "sampleDate", "values"],
                "properties": ["laboratory": ["type": "STRING"], "sampleDate": ["type": "STRING"], "values": ["type": "ARRAY", "items": row]]]],
        ])
        request.timeoutInterval = 180
        return request
    }

    /// The model's table. Rejects anything that is not the schema; an empty table is an error, not a result.
    static func parse(_ text: String, method: String, pages: Int) throws -> LabReport {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw AppFailure("Die Tabelle des Anbieters konnte nicht gelesen werden.") }
        guard let rows = root["values"] as? [Any] else { throw AppFailure("Die Tabelle des Anbieters ist unvollständig.") }
        guard rows.count <= maxValues else { throw AppFailure("Der Befund enthält mehr als \(maxValues) Werte. Bitte in Teilen hinzufügen.") }
        func string(_ row: [String: Any], _ key: String) -> String { String(((row[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        var values: [LabValue] = []
        for element in rows {
            guard let row = element as? [String: Any] else { throw AppFailure("Die Tabelle des Anbieters ist unvollständig.") }
            let value = LabValue(parameter: string(row, "parameter"), value: string(row, "value"), unit: string(row, "unit"), reference: string(row, "reference"),
                                 flag: string(row, "flag"), page: min(max((row["page"] as? Int) ?? 1, 1), max(pages, 1)), uncertain: (row["uncertain"] as? Bool) ?? false)
            if !value.parameter.isEmpty || !value.value.isEmpty { values.append(value) }
        }
        guard !values.isEmpty else { throw AppFailure("Im Befund wurden keine Messwerte erkannt. Du kannst den Text stattdessen als Dokument prüfen.") }
        return LabReport(laboratory: string(root, "laboratory"), sampleDate: string(root, "sampleDate"), values: values, method: method, pages: pages)
    }

    /// Every number of a value and its reference must appear in the locally read original.
    static func verify(_ report: LabReport, localText: String) -> LabReport {
        let local = Set(LabMath.numbers(localText))
        var result = report
        result.values = report.values.map { value in
            guard value.evidence != .edited, value.evidence != .local else { return value }
            var checked = value
            let numbers = LabMath.numbers(value.value) + LabMath.numbers(value.reference)
            checked.evidence = local.isEmpty ? .unchecked : (numbers.allSatisfy { local.contains($0) } ? .found : .notFound)
            return checked
        }
        return result
    }

    private static let localLine = try! NSRegularExpression(pattern:
        #"^\s*([A-Za-zÄÖÜäöüß][A-Za-zÄÖÜäöüß0-9 .,()/%+\-]*?)\s+([<>≤≥]?\s?\d+(?:[.,]\d+)?)\s*([A-Za-zµμ%/][^\s]*(?:\s?/\s?[^\s]+)?)?\s*"# +
        #"(\(?(?:\d+(?:[.,]\d+)?\s*(?:-|–|bis)\s*\d+(?:[.,]\d+)?|[<>≤≥]\s*\d+(?:[.,]\d+)?)\)?)?\s*([HLhl+\-↑↓*]{1,2})?\s*$"#)

    /// Device-only fallback: one value per text line that looks like "Name Wert Einheit Referenz". Always to be checked.
    static func parseLocal(_ text: String, pages: Int) throws -> LabReport {
        var page = 1
        var values: [LabValue] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Seite "), let number = Int(trimmed.dropFirst(6)) { page = number; continue }
            guard let parts = groups(localLine, line), parts[0].trimmingCharacters(in: .whitespaces).count >= 2 else { continue }
            var reference = parts[3].trimmingCharacters(in: .whitespaces)
            if reference.hasPrefix("("), reference.hasSuffix(")") { reference = String(reference.dropFirst().dropLast()) }
            values.append(LabValue(parameter: parts[0].trimmingCharacters(in: .whitespaces), value: parts[1].trimmingCharacters(in: .whitespaces),
                                   unit: parts[2].trimmingCharacters(in: .whitespaces), reference: reference, flag: parts[4].trimmingCharacters(in: .whitespaces),
                                   page: page, evidence: .local))
            if values.count == maxValues { break }
        }
        guard !values.isEmpty else { throw AppFailure("Auf dem Gerät wurden keine Wertezeilen erkannt. Bitte online lesen oder den Text als Dokument prüfen.") }
        return LabReport(values: values, method: "Auf dem Gerät · Zeilenerkennung", pages: pages)
    }

    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Swift.Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    private static func cell(_ text: String) -> String {
        let value = text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
        return value.isEmpty ? "–" : value
    }

    /// The confirmed table as the chat receives it: laboratory values verbatim, the app's own assessment separate.
    static func render(_ report: LabReport) -> String {
        var text = "Laborbefund"
        if !report.laboratory.isEmpty { text += " · " + report.laboratory }
        if !report.sampleDate.isEmpty { text += " · Probe vom " + report.sampleDate }
        text += "\nTabelle am Original geprüft und bestätigt. Referenz und Kennzeichnung stammen vom Labor; die Bewertung berechnet die App ausschließlich aus dem gedruckten Referenzbereich.\n\n"
        text += "| Parameter | Wert | Einheit | Referenz (Labor) | Kennz. (Labor) | Bewertung (App) |\n|---|---|---|---|---|---|\n"
        for value in report.values {
            text += "| \(cell(value.parameter)) | \(cell(value.value)) | \(cell(value.unit)) | \(cell(value.reference)) | \(cell(value.flag)) | \(value.assessment.text) |\n"
        }
        return text
    }
}

/// Earlier confirmed values of the same parameter in the same case, newest first.
enum LabHistory {
    struct Entry: Equatable { let date: String; let value: LabValue; let attachmentID: UUID }
    static func key(parameter: String, unit: String) -> String {
        parameter.lowercased().filter { $0.isLetter || $0.isNumber } + "|" + unit.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "μ", with: "µ")
    }
    static func previous(cases: [VetCase], caseID: UUID?, excluding attachmentID: UUID) -> [String: [Entry]] {
        guard let caseID, let item = cases.first(where: { $0.id == caseID }) else { return [:] }
        let labs = item.encounters.flatMap { $0.chatAttachments ?? [] }
            .filter { $0.id != attachmentID && $0.lab?.confirmedAt != nil }
            .sorted { $0.lab!.confirmedAt! > $1.lab!.confirmedAt! }
        var result: [String: [Entry]] = [:]
        for attachment in labs {
            let date = attachment.lab!.sampleDate.isEmpty ? attachment.createdAt.formatted(date: .numeric, time: .omitted) : attachment.lab!.sampleDate
            for value in attachment.lab!.values { result[key(parameter: value.parameter, unit: value.unit), default: []].append(Entry(date: date, value: value, attachmentID: attachment.id)) }
        }
        return result
    }
}

/// Storing and confirming a table on a chat's attachments (same rules as Android's `ChatOperations.saveLab/confirmLab`).
enum LabOperations {
    /// A read or changed table is unconfirmed and must be checked anew.
    static func save(_ report: LabReport, id: UUID, in attachments: [ChatAttachment]) throws -> [ChatAttachment] {
        guard let index = attachments.firstIndex(where: { $0.id == id && $0.isLab == true }) else { throw AppFailure("Dieser Laborbefund ist nicht mehr vorhanden.") }
        guard report.values.count <= LabExtraction.maxValues else { throw AppFailure("Der Befund enthält zu viele Werte.") }
        var result = attachments
        var unconfirmed = report; unconfirmed.confirmedAt = nil
        result[index].lab = unconfirmed; result[index].reviewedText = nil; result[index].reviewedAt = nil
        return result
    }
    /// The user checked the table at the original: from now on the chat receives exactly this rendered table.
    static func confirm(_ report: LabReport, id: UUID, in attachments: [ChatAttachment], now: Date = Date()) throws -> [ChatAttachment] {
        guard !report.values.isEmpty else { throw AppFailure("Die Tabelle enthält keine Werte.") }
        guard report.values.allSatisfy({ !$0.parameter.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw AppFailure("Bitte in jeder Zeile Parameter und Wert ausfüllen oder die Zeile löschen.")
        }
        var result = try save(report, id: id, in: attachments)
        let index = result.firstIndex { $0.id == id }!
        var confirmed = report; confirmed.confirmedAt = now
        result[index].lab = confirmed; result[index].reviewedText = LabExtraction.render(confirmed); result[index].reviewedAt = now
        return result
    }
}
