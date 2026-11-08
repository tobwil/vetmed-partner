import Foundation

/// Dose calculator (ADR 0020), same arithmetic and wording as Android's `DoseCalculator`. Pure arithmetic from the
/// user's own numbers; the app never suggests a dose and does not know products.
enum DoseCalculator {
    enum DoseUnit: String, CaseIterable, Identifiable, Sendable {
        case mgPerKg = "mg/kg", ugPerKg = "µg/kg"
        var id: String { rawValue }
        var toMg: Double { self == .mgPerKg ? 1 : 0.001 }
    }
    enum Form: String, CaseIterable, Identifiable, Sendable {
        case liquid = "Lösung", tablet = "Tablette"
        var id: String { rawValue }
        var strengthUnit: String { self == .liquid ? "mg/ml" : "mg je Tablette" }
    }
    struct Result: Equatable, Sendable {
        var totalMg: Double
        var amount: Double
        var amountText: String
        var steps: [String]
        var notes: [String]
    }

    /// "12,5", "12.5" and "1,25" are read; anything else is refused instead of guessed.
    static func number(_ text: String) -> Double? {
        let raw = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard raw.range(of: #"^\d+(?:[.,]\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    static func format(_ value: Double, decimals: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE"); formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp  // like Java's formatter on Android
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func calculate(weight: String, dose: String, unit: DoseUnit, form: Form, strength: String) throws -> Result {
        guard let kg = number(weight) else { throw AppFailure("Bitte das Gewicht in kg als Zahl eingeben, z. B. 12,5.") }
        guard let perKg = number(dose) else { throw AppFailure("Bitte die Dosis pro kg als Zahl eingeben, z. B. 0,1.") }
        guard let per = number(strength) else { throw AppFailure("Bitte die Stärke des Präparats als Zahl eingeben (\(form.strengthUnit)).") }
        guard kg > 0, kg <= 1500 else { throw AppFailure("Das Gewicht muss zwischen 0 und 1.500 kg liegen.") }
        guard perKg > 0 else { throw AppFailure("Die Dosis muss größer als 0 sein.") }
        guard per > 0 else { throw AppFailure("Die Stärke muss größer als 0 sein.") }
        let totalMg = kg * perKg * unit.toMg
        let amount = totalMg / per
        let mgText = totalMg < 0.1 ? "\(format(totalMg * 1000, decimals: 1)) µg" : "\(format(totalMg, decimals: totalMg < 1 ? 3 : 2)) mg"
        var steps = ["\(format(kg)) kg × \(format(perKg, decimals: 3)) \(unit.rawValue) = \(mgText)"]
        var notes: [String] = []
        let amountText: String
        switch form {
        case .liquid:
            amountText = "\(format(amount, decimals: amount < 0.1 ? 3 : 2)) ml"
            steps.append("\(format(totalMg, decimals: 3)) mg ÷ \(format(per, decimals: 3)) mg/ml = \(amountText)")
            if amount < 0.1 { notes.append("Sehr kleine Menge: genau abmessen ist schwierig. Eine passende Spritze oder eine Verdünnung nach Fachinformation erwägen.") }
            if amount > 50 { notes.append("Große Menge. Bitte Konzentration und Einheit noch einmal prüfen.") }
        case .tablet:
            let quarters = Int((amount * 4).rounded())
            amountText = "\(format(amount)) \(amount == 1 ? "Tablette" : "Tabletten")"
            steps.append("\(format(totalMg, decimals: 3)) mg ÷ \(format(per, decimals: 3)) mg je Tablette = \(amountText)")
            if quarters == 0 { notes.append("Weniger als eine Vierteltablette: eine Tablette ist für dieses Gewicht zu stark.") }
            else {
                let rounded = Double(quarters) / 4
                let deviation = Int(((rounded - amount) / amount * 100).rounded())
                if abs(rounded - amount) > 1e-9 {
                    notes.append("Auf Vierteltabletten gerundet: \(tablets(quarters)) (\(deviation >= 0 ? "+" : "")\(deviation) % gegenüber der berechneten Menge). Ob die Tablette teilbar ist, steht in der Fachinformation.")
                }
            }
        }
        if unit == .mgPerKg, perKg > 100 { notes.append("Ungewöhnlich hohe Dosis pro kg. Bitte die Einheit prüfen (mg oder µg).") }
        return Result(totalMg: totalMg, amount: amount, amountText: amountText, steps: steps, notes: notes)
    }

    private static func tablets(_ quarters: Int) -> String {
        let whole = quarters / 4
        let part = ["", "¼", "½", "¾"][quarters % 4]
        let number = whole == 0 ? part : (part.isEmpty ? "\(whole)" : "\(whole) \(part)")
        return "\(number) \(quarters == 4 ? "Tablette" : "Tabletten")"
    }
}

/// Fixed warning rules (ADR 0020), same list and wording as Android's `DrugRules`. A missing warning never means safe.
enum DrugRules {
    enum Severity: Int, Comparable, Sendable {
        case stop, caution, info
        var label: String { switch self { case .stop: "Nicht geben"; case .caution: "Vorsicht"; case .info: "Hinweis" } }
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    enum Mdr1: String, CaseIterable, Identifiable, Sendable {
        case unknown = "Unbekannt", normal = "Kein Defekt", defect = "Defekt nachgewiesen"
        var id: String { rawValue }
    }
    struct Warning: Equatable, Identifiable, Sendable {
        var severity: Severity; var title: String; var text: String
        var id: String { title }
    }
    static let disclaimer = "Feste Regeln der App für bekannte Gefahren. Sie ersetzen keine Fachinformation. Fehlt eine Warnung, heißt das nicht, dass das Mittel unbedenklich ist."

    enum Species { case dog, cat, other }
    static func species(_ text: String) -> Species {
        let value = text.lowercased()
        if ["katze", "kater", "kätzchen", "cat", "feline"].contains(where: { value.contains($0) }) { return .cat }
        if ["hund", "hündin", "welpe", "dog", "canine"].contains(where: { value.contains($0) }) { return .dog }
        return .other
    }

    private static func mentions(_ drug: String, _ names: [String]) -> String? {
        let text = drug.lowercased()
        return names.first { text.range(of: #"(?<!\p{L})"# + NSRegularExpression.escapedPattern(for: $0), options: .regularExpression) != nil }
    }
    private static let paracetamol = ["paracetamol", "acetaminophen"]
    private static let permethrin = ["permethrin"]
    private static let mdr1Drugs = ["ivermectin", "doramectin", "moxidectin", "milbemycin", "selamectin", "eprinomectin", "abamectin", "emodepsid",
                                    "loperamid", "acepromazin", "butorphanol", "vincristin", "vinblastin", "doxorubicin"]
    private static let nsaids = ["meloxicam", "carprofen", "robenacoxib", "firocoxib", "cimicoxib", "mavacoxib", "deracoxib", "ketoprofen", "phenylbutazon",
                                 "flunixin", "tolfenamin", "diclofenac", "ibuprofen", "naproxen", "acetylsalicyl", "aspirin"]
    private static let humanNsaids = ["ibuprofen", "naproxen", "diclofenac"]

    /// Kreatinin and SDMA by name; "Kreatinkinase" (CK) must not count.
    static func isKidneyMarker(_ parameter: String) -> Bool {
        let letters = parameter.lowercased().filter(\.isLetter)
        return ["crea", "krea", "sdma"].contains(letters) || letters.hasPrefix("kreatinin") || letters.hasPrefix("creatinin")
            || letters.hasPrefix("sdma") || letters.hasPrefix("symmetrischesdimethylarginin")
    }
    static func highKidneyValues(_ document: VaultDocument, caseID: UUID?) -> [String] {
        LabTrend.series(document, caseID: caseID, minimumPoints: 1).filter { isKidneyMarker($0.parameter) }.compactMap { series in
            guard let point = series.points.last, point.assessment == .high else { return nil }
            let value = "\(series.parameter) \(point.raw) \(series.unit)".trimmingCharacters(in: .whitespaces)
            return value + (point.reference.isEmpty ? "" : " (Ref. \(point.reference))") + " am \(point.label)"
        }
    }
    static func hasKidneyValues(_ document: VaultDocument, caseID: UUID?) -> Bool {
        LabTrend.series(document, caseID: caseID, minimumPoints: 1).contains { isKidneyMarker($0.parameter) }
    }
    private static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    static func warnings(drug: String, species speciesText: String, mdr1: Mdr1, document: VaultDocument = VaultDocument(), caseID: UUID? = nil) -> [Warning] {
        guard !drug.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let species = species(speciesText)
        var warnings: [Warning] = []
        if species == .cat {
            if mentions(drug, paracetamol) != nil {
                warnings.append(Warning(severity: .stop, title: "Paracetamol ist für Katzen giftig", text: "Schon kleine Mengen können Methämoglobinämie und Leberschäden auslösen."))
            }
            if mentions(drug, permethrin) != nil {
                warnings.append(Warning(severity: .stop, title: "Permethrin ist für Katzen giftig", text: "Es kann Muskelzittern und Krampfanfälle auslösen. Permethrinhaltige Hundepräparate nie bei Katzen anwenden, auch nicht bei engem Kontakt frisch behandelter Hunde."))
            }
        }
        if species == .dog, let name = mentions(drug, mdr1Drugs) {
            switch mdr1 {
            case .defect: warnings.append(Warning(severity: .caution, title: "MDR1-Defekt und \(capitalized(name))",
                text: "Bei einem Defekt im ABCB1-Gen (MDR1) kann der Wirkstoff ins Gehirn gelangen und neurotoxisch wirken. Fachinformation zu MDR1 beachten, Dosis und Alternative prüfen."))
            case .unknown: warnings.append(Warning(severity: .info, title: "MDR1-Status unbekannt",
                text: "\(capitalized(name)) kann bei einem MDR1-Defekt neurotoxisch wirken. Betroffen sind vor allem Collie, Australian Shepherd, Sheltie, Weißer Schäferhund und Mischlinge dieser Rassen."))
            case .normal: break
            }
        }
        if let nsaid = mentions(drug, nsaids) {
            if species != .other, mentions(drug, humanNsaids) != nil {
                warnings.append(Warning(severity: .caution, title: "Humanes NSAID \(species == .cat ? "bei der Katze" : "beim Hund")",
                    text: "\(capitalized(nsaid)) hat bei Hund und Katze eine geringe therapeutische Breite: Magen-Darm-Geschwüre und Nierenschäden sind schon bei üblichen Humandosen beschrieben."))
            }
            let high = highKidneyValues(document, caseID: caseID)
            if !high.isEmpty {
                warnings.append(Warning(severity: .caution, title: "Nierenwert über dem Referenzbereich",
                    text: high.joined(separator: "; ") + ". NSAIDs können die Nierenfunktion weiter verschlechtern. Nutzen und Risiko abwägen, Fachinformation beachten."))
            } else if caseID != nil, !hasKidneyValues(document, caseID: caseID) {
                warnings.append(Warning(severity: .info, title: "Kein bestätigter Nierenwert im Fall", text: "Für NSAIDs ist die Nierenfunktion wichtig. Im Fall liegt kein bestätigter Kreatinin- oder SDMA-Wert vor."))
            }
        }
        return warnings.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }
}

/// Confirmed lab values of one case over time (ADR 0020), like Android's `LabTrend`.
enum LabTrend {
    struct Point: Equatable, Identifiable, Sendable {
        var id: String { attachmentID.uuidString + label + raw }
        var date: Date
        var label: String
        var value: Double
        var raw: String
        var reference: String
        var range: LabMath.Range?
        var assessment: LabAssessment
        var attachmentID: UUID
    }
    struct Series: Identifiable, Sendable {
        var parameter: String; var unit: String; var points: [Point]
        var id: String { LabHistory.key(parameter: parameter, unit: unit) }
        var band: LabMath.Range? { points.last?.range.flatMap { $0.low != nil && $0.high != nil ? $0 : nil } }
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE"); formatter.timeZone = .current; formatter.dateFormat = pattern; formatter.isLenient = false
        return formatter
    }
    /// "01.10.2026", "1.10.26" or "2026-10-01" anywhere in the text.
    static func date(_ text: String) -> Date? {
        guard let range = text.range(of: #"\d{1,4}[.\-]\d{1,2}[.\-]\d{2,4}"#, options: .regularExpression) else { return nil }
        let token = String(text[range])
        if token.contains("-") { return formatter("yyyy-MM-dd").date(from: token) }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        return formatter(parts[2].count == 2 ? "d.M.yy" : "d.M.yyyy").date(from: token)
    }

    static func series(_ document: VaultDocument, caseID: UUID?, minimumPoints: Int = 2) -> [Series] {
        guard let item = document.cases.first(where: { $0.id == caseID }) else { return [] }
        struct Raw { var point: Point; var parameter: String; var unit: String; var confirmed: Date }
        let day = formatter("dd.MM.yyyy")
        var raw: [Raw] = []
        for attachment in item.encounters.flatMap({ $0.chatAttachments ?? [] }) {
            guard let lab = attachment.lab, let confirmed = lab.confirmedAt else { continue }
            let printed = date(lab.sampleDate)
            let label = printed == nil ? day.string(from: confirmed) : lab.sampleDate.trimmingCharacters(in: .whitespaces)
            for value in lab.values {
                guard let number = LabMath.number(value.value) else { continue }
                raw.append(Raw(point: Point(date: printed ?? confirmed, label: label, value: number, raw: value.value, reference: value.reference,
                                            range: LabMath.reference(value.reference), assessment: value.assessment, attachmentID: attachment.id),
                               parameter: value.parameter.trimmingCharacters(in: .whitespaces), unit: value.unit.trimmingCharacters(in: .whitespaces), confirmed: confirmed))
            }
        }
        return Dictionary(grouping: raw) { LabHistory.key(parameter: $0.parameter, unit: $0.unit) }.values
            .map { group -> Series in
                let sorted = group.sorted { ($0.point.date, $0.confirmed) < ($1.point.date, $1.confirmed) }
                return Series(parameter: sorted.last!.parameter, unit: sorted.last!.unit, points: sorted.map(\.point))
            }
            .filter { $0.points.count >= minimumPoints }
            .sorted { $0.parameter.lowercased() < $1.parameter.lowercased() }
    }
}
