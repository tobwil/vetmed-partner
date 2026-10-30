import Foundation

/// A web source the provider cited for an answer. Only shown and checked locally, never sent back.
struct AnswerSource: Codable, Equatable, Sendable {
    let url: String
    var title: String?
}

/// Guard rails for medication statements in the sparring chat (same rules as Android's `MedicationSafety`).
/// Language models confuse trade names and active substances from memory; the prompt forbids that, and the app
/// additionally marks every answer that talks about medication without an official source.
enum MedicationSafety {
    /// Official sources for veterinary medicines in the EU, Germany and Austria. Web search is limited to these.
    static let officialDomains = [
        "medicines.health.europa.eu", // EU Union Product Database, public part
        "ema.europa.eu",
        "pharmnet-bund.de",
        "bvl.bund.de",
        "aspregister.basg.gv.at",
    ]
    static let databaseURL = URL(string: "https://medicines.health.europa.eu/veterinary/de/search-medicines")!
    static let warning = "Arzneimittelangaben ohne amtlichen Beleg. Wirkstoffe, Zusammensetzung und Dosierung vor jeder Anwendung in der Fachinformation prüfen."

    private static let words = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}])(wirkstoff\p{L}*|präparat\p{L}*|praeparat\p{L}*|arzneimittel\p{L}*|tierarzneimittel\p{L}*|medikament\p{L}*|"# +
        #"zusammensetzung|enthält|enthalten|dosier\p{L}*|dosis|dosen|tablette\p{L}*|kautablette\p{L}*|injektion\p{L}*|"# +
        #"spot-on|suspension|salbe|tropfen|fachinformation|beipackzettel|packungsbeilage|wartezeit\p{L}*|"# +
        #"kontraindikation\p{L}*|gegenanzeige\p{L}*|wechselwirkung\p{L}*|nebenwirkung\p{L}*|handelsname\p{L}*)(?![\p{L}\p{N}])"#,
        options: [.caseInsensitive])
    /// Typical endings of active substance names (INN), so "Präparat: Fluralaner" is caught without a keyword.
    private static let substances = try! NSRegularExpression(pattern:
        #"(?<![\p{L}])\p{L}{2,}(?:xicam|profen|coxib|oxacin|mectin|mycin|cyclin|cillin|laner|citinib|tinib|lokivetmab|bedinvetmab|pril|sartan|thrin|quantel|pyrantel|febantel|azol|azole|methason|metason|azepam|zolam|pimobendan|fipronil|imidacloprid|maropitant|gabapentin|tramadol|metamizol|ketamin|medetomidin|butorphanol|furosemid|spironolacton|methopren|selamectin)(?![\p{L}])"#, options: [.caseInsensitive])
    private static let doses = try! NSRegularExpression(pattern:
        #"\d+(?:[.,]\d+)?\s?(?:mg|µg|μg|mcg|ie|i\.\s?e\.)(?:\s?/\s?(?:kg|ml|tablette|tier))?(?![\p{L}])"#, options: [.caseInsensitive])

    /// True when an answer names medication, composition or doses. Errs on the side of warning.
    static func mentionsMedication(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return words.firstMatch(in: text, range: range) != nil || doses.firstMatch(in: text, range: range) != nil
            || substances.firstMatch(in: text, range: range) != nil
    }

    static func isOfficial(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              var host = components.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return officialDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func officialSources(_ run: AnalysisRun) -> [AnswerSource] { (run.sources ?? []).filter { isOfficial($0.url) } }

    /// A warning is shown unless the answer has no medication content or cites at least one official source.
    static func needsWarning(_ run: AnalysisRun) -> Bool { mentionsMedication(run.text) && officialSources(run).isEmpty }

    /// The final block of the system instructions; tells the model what it can and cannot rely on.
    static func instructions(_ base: String, sourceSearch: Bool) -> String {
        let trimmed = base.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let situation = sourceSearch
            ? "Quellensuche: aktiviert, beschränkt auf amtliche Arzneimittelquellen (" + officialDomains.joined(separator: ", ") + "). "
                + "Belege präparatbezogene Angaben ausschließlich mit Treffern dieser Suche und nenne die Quelle direkt bei der Angabe. "
                + "Findest du keinen passenden Treffer, sage das und nenne keine Zusammensetzung."
            : "Quellensuche: nicht aktiviert. Du hast für diese Anfrage keinen Zugriff auf Fachinformationen, Datenbanken oder das Internet. "
                + "Präparatbezogene Angaben sind deshalb nur aus mitgesendeten Angaben oder Anhängen möglich."
        return trimmed + "\n\n# Quellenlage für diese Anfrage\n" + situation
    }

    /// Web search tool for the OpenAI Responses API, limited to official domains.
    static var openAITool: [String: Any] { ["type": "web_search", "filters": ["allowed_domains": officialDomains]] }

    /// Cited https sources from the final `output_text` parts, de-duplicated.
    static func citations(in parts: [[String: Any]]) -> [AnswerSource] {
        var seen = Set<String>(), result: [AnswerSource] = []
        for part in parts where part["type"] as? String == "output_text" {
            for annotation in part["annotations"] as? [[String: Any]] ?? [] where annotation["type"] as? String == "url_citation" {
                guard let url = annotation["url"] as? String, url.hasPrefix("https://"), url.count <= 2048, seen.insert(url).inserted else { continue }
                result.append(AnswerSource(url: url, title: (annotation["title"] as? String).map { String($0.prefix(300)) }))
            }
        }
        return Array(result.prefix(20))
    }
}
