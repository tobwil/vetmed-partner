import Foundation
import NaturalLanguage

enum ReportValidator {
    static func decode(_ text: String) throws -> StructuredReport {
        try decodeJSON(StructuredReport.self, text)
    }
    static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), let firstNewline = value.firstIndex(of: "\n"), value.hasSuffix("```") {
            value = String(value[value.index(after: firstNewline)...].dropLast(3))
        }
        value = normalizeJSONWhitespace(value)
        do { return try JSONDecoder().decode(type, from: Data(value.utf8)) }
        catch DecodingError.keyNotFound(let key, _) { throw AppFailure("JSON-Pflichtfeld fehlt: \(key.stringValue).") }
        catch DecodingError.typeMismatch(_, let context) { throw AppFailure("JSON-Feldtyp ungültig: \(context.codingPath.map(\.stringValue).joined(separator: ".")).") }
        catch { throw AppFailure("Die Modellantwort enthält kein gültiges Berichts-JSON.") }
    }
    /// Some local outputs spell whitespace as literal \n between JSON tokens. Only normalize
    /// outside strings; quotes, content, punctuation and malformed structure remain untouched.
    static func normalizeJSONWhitespace(_ input: String) -> String {
        let characters = Array(input)
        var output = "", insideString = false, escaped = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if insideString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { insideString = false }
            } else if character == "\"" { insideString = true; output.append(character) }
            else if character == "\\", index + 1 < characters.count, ["n", "r", "t"].contains(characters[index + 1]) {
                output.append(" "); index += 1
            } else { output.append(character) }
            index += 1
        }
        return output
    }
    static func validate(_ report: StructuredReport, transcript: TranscriptVersion) throws -> [String] {
        guard Set(transcript.segments.map(\.id)).count == transcript.segments.count else { throw AppFailure("Das Transkript enthält doppelte Quellen-IDs. Bitte eine neue Textversion speichern.") }
        guard report.schemaVersion == 1, report.requiresReview,
              report.sourceTranscriptVersionId == transcript.id.uuidString,
              !report.sections.isEmpty, !report.sections.flatMap(\.items).isEmpty,
              Set(report.sections.map(\.key)).count == report.sections.count,
              report.sections.allSatisfy({ report.template.sections.contains($0.key) }) else { throw AppFailure("Berichtsformat oder Quellenstand ist ungültig.") }
        let segments = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0.text) })
        var warnings: [String] = []
        for section in report.sections {
            for item in section.items {
                guard item.origin == "dictated", !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !item.sourceRefs.isEmpty else { throw AppFailure("Eine Aussage hat keinen Diktatbeleg.") }
                for ref in item.sourceRefs {
                    guard let source = segments[ref.segmentId], !ref.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          source.contains(ref.quote) else { throw AppFailure("Ein Quellenbeleg ist unbekannt oder verändert.") }
                }
                let quotes = item.sourceRefs.map(\.quote).joined(separator: " ")
                guard numbers(item.text).isSubset(of: numbers(quotes)) else { throw AppFailure("Eine Zahl im Bericht ist nicht durch die zugeordnete Originalstelle belegt.") }
                guard units(item.text).isSubset(of: units(quotes)) else { throw AppFailure("Eine Einheit im Bericht wurde gegenüber dem Beleg verändert.") }
                guard comparisons(item.text).isSubset(of: comparisons(quotes)) else { throw AppFailure("Ein Vergleichszeichen wurde gegenüber dem Beleg verändert.") }
                if comparisons(quotes).contains(where: { !numbers($0).isDisjoint(with: numbers(item.text)) && !comparisons(item.text).contains($0) }) {
                    throw AppFailure("Ein Vergleichszeichen am Zahlenwert fehlt.")
                }
                if hasNegation(quotes) != hasNegation(item.text) { warnings.append("Negation abgleichen: \(item.text)") }
            }
        }
        let missingNumbers = numbers(transcript.editedText).subtracting(numbers(report.text))
        if !missingNumbers.isEmpty { warnings.append("Zahlen aus dem Transkript fehlen im Bericht: " + missingNumbers.sorted().joined(separator: ", ")) }
        let covered = Set(report.sections.flatMap(\.items).flatMap(\.sourceRefs).map(\.segmentId))
        if !Set(transcript.segments.filter { TranscriptSourcePolicy.requiresCoverage($0.text) }.map(\.id)).isSubset(of: covered) { warnings.append("Nicht alle Transkriptabschnitte sind im Bericht belegt. Vollständigkeit prüfen.") }
        if !report.conflicts.isEmpty { warnings.append("Widersprüchliche Angaben vor Freigabe klären.") }
        return Array(Set(warnings)).sorted()
    }
    static func numbers(_ text: String) -> Set<String> { matches(#"(?<![\p{L}\d])\d+(?:[.,]\d+)?"#, text).map { $0.replacingOccurrences(of: ",", with: ".") }.reduce(into: Set<String>()) { $0.insert($1) } }
    static func units(_ text: String) -> Set<String> { Set(matches(#"(?i)(?<!\p{L})(?:µg/kg|μg/kg|mg/kg|mg/dl|mmol/l|µmol/l|ml/kg|g/l|mg|µg|μg|kg|ml|mm|cm|°c|bpm)(?!\p{L})"#, text.lowercased())) }
    static func comparisons(_ text: String) -> Set<String> { Set(matches(#"(?:[<>≤≥]=?)\s*\d+(?:[.,]\d+)?"#, text).map { $0.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".") }) }
    static func hasNegation(_ text: String) -> Bool { !matches(#"(?i)\b(?:kein\w*|nicht|ohne|verneint)\b"#, text).isEmpty }
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
enum TranscriptSourcePolicy {
    /// Closed list of dictation housekeeping phrases. Clinical content is never omitted by model discretion.
    static func requiresCoverage(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: .punctuationCharacters)
        if ["diktatbeginn", "diktatende", "ende des diktats", "neuer bericht", "synthetischer testfall"].contains(normalized) { return false }
        // Exact synthetic recording labels carry no findings. Anchors keep any appended clinical
        // clause mandatory; this never delegates omission decisions to the language model.
        let syntheticLabel = #"^abschnitt (?:\d+|(?:erst|zweit|dritt|viert|fünft|sechst|siebt|acht|neunt|zehnt)(?:e|er|en|es))\.? synthetischer testfall$"#
        return normalized.range(of: syntheticLabel, options: .regularExpression) == nil
    }
}
enum TranscriptBuilder {
    /// Sentence-level source coverage, retaining the enclosing ASR time range for audio playback.
    static func audioSentences(_ input: [TranscriptSegment]) -> [TranscriptSegment] {
        var groups: [[TranscriptSegment]] = []
        for source in input {
            if let last = groups.last?.last, last.audioID == source.audioID { groups[groups.count - 1].append(source) }
            else { groups.append([source]) }
        }
        return groups.flatMap { group in
            var joined = "", offsets: [(NSRange, TranscriptSegment)] = []
            for source in group {
                if !joined.isEmpty { joined += " " }
                let start = joined.utf16.count
                joined += source.text
                offsets.append((NSRange(location: start, length: source.text.utf16.count), source))
            }
            var offset = 0
            return edited(joined, previous: nil).segments.enumerated().map { index, piece in
                let range = NSRange(location: offset, length: piece.text.utf16.count)
                offset += range.length
                let enclosing = offsets.filter { NSIntersectionRange($0.0, range).length > 0 }.map(\.1)
                return TranscriptSegment(id: group[0].id + "-sentence-\(index)", text: piece.text, audioID: group[0].audioID,
                    startSeconds: enclosing.first?.startSeconds, endSeconds: enclosing.last?.endSeconds)
            }
        }
    }
    static func edited(_ text: String, previous: TranscriptVersion?) -> TranscriptVersion {
        // Changed text gets fresh source IDs; original audio-aligned segments remain in the parent version.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentenceRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in sentenceRanges.append(range); return true }
        var segments: [TranscriptSegment] = []
        var consumed = text.startIndex
        for sentence in sentenceRanges {
            var remainder = text[consumed..<sentence.upperBound]
            while !remainder.isEmpty {
                var boundary = remainder.index(remainder.startIndex, offsetBy: min(900, remainder.count))
                if boundary < remainder.endIndex, let space = remainder[..<boundary].lastIndex(where: \.isWhitespace), space > remainder.startIndex { boundary = remainder.index(after: space) }
                let piece = String(remainder[..<boundary])
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.init(id: "text-\(segments.count)", text: piece)) }
                remainder = remainder[boundary...]
            }
            consumed = sentence.upperBound
        }
        if consumed < text.endIndex, !segments.isEmpty { segments[segments.count - 1].text += text[consumed...] }
        return TranscriptVersion(parentID: previous?.id, rawText: previous?.rawText ?? text, editedText: text, segments: segments, engine: previous?.engine ?? "Manuelle Eingabe")
    }
}
struct ModelReportDraft: Codable, Sendable {
    struct Item: Codable, Sendable { var section: String; var text: String; var segmentId: String; var quote: String }
    var items: [Item]
    var missingInformation: [String]
    var conflicts: [String]
    mutating func normalizeSectionAliases(for template: ReportTemplate) {
        // Exact heading synonyms only. Statement text and source evidence are never rewritten.
        let aliases: [String: String]
        switch template {
        case .treatment_report: aliases = ["Kontrolle": "Weiteres Vorgehen", "Weitere Ergebnisse": "Weiteres Vorgehen"]
        case .soap: aliases = ["Kontrolle": "Plan", "Weitere Ergebnisse": "Plan"]
        case .follow_up: aliases = ["Kontrolle": "Nächster Schritt", "Weitere Ergebnisse": "Nächster Schritt"]
        case .owner_information: aliases = ["Kontrolle": "Vereinbarte Schritte", "Weitere Ergebnisse": "Einordnung"]
        case .referral: aliases = [:]
        }
        for index in items.indices { if let canonical = aliases[items[index].section] { items[index].section = canonical } }
    }
    func report(transcriptID: UUID, template: ReportTemplate, length: ReportLength, audience: Audience) throws -> StructuredReport {
        guard !items.isEmpty, items.allSatisfy({ template.sections.contains($0.section) }) else { throw AppFailure("Die Modellantwort enthält unbekannte oder leere Berichtsabschnitte.") }
        return StructuredReport(template: template, length: length, audience: audience, sourceTranscriptVersionId: transcriptID.uuidString,
            sections: template.sections.map { section in ReportSection(key: section, items: items.filter { $0.section == section }.map {
                ReportItem(text: $0.text, sourceRefs: [SourceReference(segmentId: $0.segmentId, quote: $0.quote)], origin: "dictated")
            }) }, missingInformation: missingInformation, conflicts: conflicts)
    }
}
extension ModelReportDraft {
    // These are optional model annotations, never a claim that the source is complete or consistent.
    // App-owned StructuredReport always contains the arrays; factual items remain mandatory.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([Item].self, forKey: .items)
        missingInformation = try values.decodeIfPresent([String].self, forKey: .missingInformation) ?? []
        conflicts = try values.decodeIfPresent([String].self, forKey: .conflicts) ?? []
    }
}

@MainActor
struct ReportPipeline {
    let engine: any ReportTextEngine
    static func instructions() throws -> String {
        guard let url = Bundle.main.url(forResource: "report-v1", withExtension: "txt") else { throw AppFailure("Der versionierte Berichtsprompt fehlt.") }
        return try String(contentsOf: url, encoding: .utf8)
    }
    func run(transcript: TranscriptVersion, template: ReportTemplate, length: ReportLength, audience: Audience,
             checkpoint: (ReportCheckpoint) async throws -> Void = { _ in },
             progress: (String) -> Void) async throws -> ReportVersion {
        guard !transcript.segments.isEmpty else { throw AppFailure("Bitte zuerst ein Transkript erfassen.") }
        guard Set(transcript.segments.map(\.id)).count == transcript.segments.count else { throw AppFailure("Das Transkript enthält doppelte Quellen-IDs. Bitte eine neue Textversion speichern.") }
        guard transcript.editedText.utf8.count <= 1_000_000 else { throw AppFailure("Das Transkript ist für einen einzelnen Bericht zu groß. Bitte in mehrere Vorgänge aufteilen; der Originaltext bleibt erhalten.") }
        var chunks: [[TranscriptSegment]] = []; var current: [TranscriptSegment] = []; var size = 0
        for segment in transcript.segments where TranscriptSourcePolicy.requiresCoverage(segment.text) {
            if (size + segment.text.count > engine.characterLimit || current.count >= engine.sourceLimit) && !current.isEmpty { chunks.append(current); current = []; size = 0 }
            current.append(segment); size += segment.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        guard !chunks.isEmpty else { throw AppFailure("Das Transkript enthält noch keine fachlichen Angaben.") }
        var collected: [StructuredReport] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress("Abschnitt \(index + 1) von \(chunks.count) · \(engine.executionLabel)")
            let sectionNames = template.sections.joined(separator: ", ")
            struct WireSource: Encodable { var id: String; var text: String }
            let aliases = Dictionary(uniqueKeysWithValues: chunk.enumerated().map { ($0.element.id, "q\($0.offset + 1)") })
            let originals = Dictionary(uniqueKeysWithValues: aliases.map { ($0.value, $0.key) })
            func prompt(for sources: [TranscriptSegment]) throws -> String { """
            Erstelle einen \(template.title) auf Deutsch. Länge: \(length.title), Zielgruppe: \(audience.title).
            Ordne ALLE Befunde und vereinbarten Schritte aus den Quellen passenden Abschnitten zu.
            Jede Quellen-ID muss in mindestens einem Item erscheinen. Es gibt \(sources.count) Quellen: \(sources.compactMap { aliases[$0.id] }.joined(separator: ", ")).
            Auch negative Angaben, unbekannte Messwerte und vereinbarte Kontrollen müssen erhalten bleiben.
            Erlaubte section-Werte: \(sectionNames).
            Antworte mit genau einem JSON-Objekt. Beginne mit { und ende mit }. Kein Titel, keine Codeblöcke.
            Struktur: {"items":[{"section":"Abschnittsname","text":"Aussage","segmentId":"Quellen-ID","quote":"wörtliches Zitat"}]}
            Das äußere Objekt hat nur das Feld items. Beende die Antwort unmittelbar nach seiner schließenden Klammer.
            Jedes Item hat genau diese vier String-Felder. Nutze echte Quellen-IDs aus id und exakte Zitate aus text.
            Keine Inhalte erfinden. Keine Normalbefunde ergänzen. Zahlen und Negationen unverändert erhalten.
            QUELLEN:
            \(String(decoding: try JSONEncoder().encode(sources.map { WireSource(id: aliases[$0.id]!, text: $0.text) }), as: UTF8.self))
            """ }
            var result: StructuredReport?
            var repairNote = ""
            var pending = chunk
            var accepted: [ModelReportDraft.Item] = []
            var missingInformation: [String] = []
            var conflicts: [String] = []
            for attempt in 0..<2 {
                let output = try await engine.generate(prompt: prompt(for: pending) + repairNote, instructions: Self.instructions())
                do {
                    var draft = try ReportValidator.decodeJSON(ModelReportDraft.self, output)
                    draft.normalizeSectionAliases(for: template)
                    for i in draft.items.indices {
                        guard let original = originals[draft.items[i].segmentId] else { throw AppFailure("Unbekannte Quellen-ID in der Modellantwort.") }
                        draft.items[i].segmentId = original
                    }
                    let invalidSections = Set(draft.items.filter { !template.sections.contains($0.section) }.map(\.section))
                    draft.items.removeAll { !template.sections.contains($0.section) }
                    let sectionRepair = invalidSections.isEmpty ? "" : " Ungültige section-Werte: " + invalidSections.sorted().joined(separator: ", ") + ". Erlaubt sind ausschließlich: " + sectionNames + "."
                    guard !draft.items.isEmpty else { throw AppFailure("Keine gültig zugeordneten Aussagen." + sectionRepair) }
                    let candidate = try draft.report(transcriptID: transcript.id, template: template, length: length, audience: audience)
                    var local = transcript; local.segments = pending; local.editedText = pending.map(\.text).joined(separator: "\n")
                    _ = try ReportValidator.validate(candidate, transcript: local)
                    // Keep only complete, validated source groups. Repair missing groups in isolation,
                    // so a second generation cannot erase facts already covered by the first.
                    let completeIDs = Set(pending.filter { source in
                        let items = draft.items.filter { $0.segmentId == source.id }
                        let text = items.map(\.text).joined(separator: " ")
                        return !items.isEmpty && ReportValidator.numbers(source.text).isSubset(of: ReportValidator.numbers(text))
                            && ReportValidator.hasNegation(source.text) == ReportValidator.hasNegation(text)
                    }.map(\.id))
                    accepted += draft.items.filter { completeIDs.contains($0.segmentId) }
                    missingInformation += draft.missingInformation; conflicts += draft.conflicts
                    pending = pending.filter { TranscriptSourcePolicy.requiresCoverage($0.text) && !completeIDs.contains($0.id) }
                    guard pending.isEmpty else { throw AppFailure("Diese Quellen fehlen oder sind unvollständig: " + pending.compactMap { aliases[$0.id] }.joined(separator: ", ") + "." + sectionRepair) }
                    result = try ModelReportDraft(items: accepted, missingInformation: Array(Set(missingInformation)).sorted(), conflicts: Array(Set(conflicts)).sorted())
                        .report(transcriptID: transcript.id, template: template, length: length, audience: audience)
                    break
                } catch { repairNote = "\nKorrektur für den erneuten Versuch: " + error.localizedDescription + " Gib alle Quellen vollständig wieder."; if attempt == 1 { throw AppFailure("Der lokale Bericht konnte auch nach einem Reparaturversuch nicht geprüft werden: \(error.localizedDescription) Das Transkript bleibt erhalten.") } }
            }
            if let result { collected.append(result) }
            if index + 1 < chunks.count {
                let partial = merge(collected, transcript: transcript, template: template, length: length, audience: audience)
                let version = ReportVersion(content: partial, modelID: engine.engineID, modelRevision: engine.engineRevision,
                    warnings: ["Unvollständig: \(index + 1) von \(chunks.count) Abschnitten gesichert. Keine Freigabe möglich."])
                try await checkpoint(ReportCheckpoint(report: version, completedChunks: index + 1, totalChunks: chunks.count))
            }
        }
        // Merge without another lossy summary; every generated item retains its original source IDs.
        let report = merge(collected, transcript: transcript, template: template, length: length, audience: audience)
        let warnings = try ReportValidator.validate(report, transcript: transcript)
        return ReportVersion(content: report, modelID: engine.engineID, modelRevision: engine.engineRevision, warnings: warnings)
    }
    private func merge(_ collected: [StructuredReport], transcript: TranscriptVersion, template: ReportTemplate, length: ReportLength, audience: Audience) -> StructuredReport {
        StructuredReport(template: template, length: length, audience: audience, sourceTranscriptVersionId: transcript.id.uuidString,
            sections: template.sections.map { name in ReportSection(key: name, items: collected.flatMap(\.sections).filter { $0.key == name }.flatMap(\.items)) },
            missingInformation: Array(Set(collected.flatMap(\.missingInformation))).sorted(), conflicts: Array(Set(collected.flatMap(\.conflicts))).sorted())
    }
}
