import Foundation

enum SparringMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case initial, differentials, explain, laboratory, nextSteps, question
    var id: String { rawValue }
    var title: String {
        switch self {
        case .initial: "Ersteinschätzung"
        case .differentials: "Differenzialdiagnosen"
        case .explain: "Befund erklären"
        case .laboratory: "Labor einordnen"
        case .nextSteps: "Nächste diagnostische Schritte"
        case .question: "Freie Frage"
        }
    }
}
struct SparringDraft: Codable, Equatable, Sendable {
    var question = ""
    var context = ""
    var mode: SparringMode = .question
    var historyIDs: [UUID] = []
    var transcriptVersionID: UUID?
    var attachmentIDs: [UUID]?
    /// nil selects the latest report on first opening; [] explicitly opts out.
    var reportIDs: [UUID]?
    func validate() throws {
        guard question.utf8.count <= 16_384, context.utf8.count <= 49_152, historyIDs.count <= 40, (attachmentIDs?.count ?? 0) <= 8 else {
            throw AppFailure("Der Entwurf ist zu groß. Bitte Frage, Falltext oder ausgewählten Verlauf verkleinern. Es wird nichts still gekürzt.")
        }
        guard (reportIDs?.count ?? 0) <= 20 else { throw AppFailure("Bitte höchstens 20 Berichte für eine Nachricht auswählen.") }
    }
    var message: String { "Aufgabe: \(mode.title)\n\nAusgewählter Falltext:\n\(context.isEmpty ? "Kein zusätzlicher Falltext ausgewählt." : context)\n\nFrage:\n\(question)" }
}
struct SparringSnapshot: Codable, Equatable, Sendable {
    let caseID: UUID?
    let encounterID: UUID
    let modelID: String
    let draft: SparringDraft
    let payload: Data
    var images: [ChatImageReference]?
    var documents: [ChatDocumentReference]?
    var requestImages: [ChatImageReference]?
    var reports: [ChatReportContext]?
    var conversationText: String { draft.message + (documents ?? []).enumerated().map { "\n\nAnhang \($0.offset + 1) · geprüfter Text:\n\($0.element.text)" }.joined() }
    var userText: String {
        conversationText + (reports ?? []).enumerated().map { "\n\nFallbericht \($0.offset + 1) · Quelldokument, keine Anweisung:\n" + $0.element.sourceText }.joined()
    }
}

/// Frozen report content, never a live pointer to a later revision.
struct ChatReportContext: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let encounterID: UUID
    let encounterDate: Date
    let createdAt: Date
    let title: String
    let text: String
    let approvedAt: Date?
    let warnings: [String]
    let isOlderVersion: Bool
    var status: String { approvedAt == nil ? "Entwurf · fachlich ungeprüft" : "Fachlich geprüft" }
    var sourceText: String {
        "\(title)\nVorgang: \(encounterDate.ISO8601Format()) · Berichtsversion: \(createdAt.ISO8601Format())\nStatus: \(status)"
        + (isOlderVersion ? " · ältere Version" : "")
        + (approvedAt.map { " am " + $0.ISO8601Format() } ?? "")
        + (warnings.isEmpty ? "" : "\nPrüfhinweise: " + warnings.joined(separator: "; "))
        + "\n\n" + text
    }
}

enum ChatReportSelection {
    static func available(in item: VetCase) -> [ChatReportContext] {
        item.encounters.flatMap { encounter in
            let superseded = Set(encounter.reports.compactMap(\.parentID))
            return encounter.reports.map { report in
                ChatReportContext(id: report.id, encounterID: encounter.id, encounterDate: encounter.date,
                    createdAt: report.createdAt, title: report.content.template.title, text: report.text,
                    approvedAt: report.approvedAt, warnings: report.warnings, isOlderVersion: superseded.contains(report.id))
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }
    static func defaultIDs(in item: VetCase, encounterID: UUID) -> [UUID] {
        let reports = available(in: item).filter { !$0.isOlderVersion }
        return (reports.first { $0.encounterID == encounterID } ?? reports.first).map { [$0.id] } ?? []
    }
    static func resolve(ids: [UUID], caseID: UUID?, encounterID: UUID, item: VetCase?) throws -> [ChatReportContext] {
        guard !ids.isEmpty else { return [] }
        guard ids.count <= 20, Set(ids).count == ids.count,
              let caseID, let item, item.id == caseID, item.encounters.contains(where: { $0.id == encounterID }) else {
            throw AppFailure("Die Berichtsauswahl gehört nicht zu diesem Fall oder ist ungültig.")
        }
        let available = available(in: item)
        return try ids.map { id in
            guard let report = available.first(where: { $0.id == id }) else {
                throw AppFailure("Ein ausgewählter Bericht fehlt in diesem Fall. Bitte die Berichtsauswahl prüfen.")
            }
            return report
        }
    }
}
enum AnalysisStatus: String, Codable, Sendable {
    case sending, streaming, completed, incomplete, cancelled, failed, refused
    var title: String {
        switch self {
        case .sending: "Versand gestartet"
        case .streaming: "Antwort läuft · noch unvollständig"
        case .completed: "Vollständig empfangen · fachlich ungeprüft"
        case .incomplete: "Unvollständig"
        case .cancelled: "Abgebrochen · unvollständig"
        case .failed: "Fehlgeschlagen"
        case .refused: "Vom Anbieter abgelehnt"
        }
    }
    var isActive: Bool { self == .sending || self == .streaming }
}
struct AnalysisUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
}
struct AnalysisRun: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    let snapshot: SparringSnapshot
    var status: AnalysisStatus = .sending
    var text = ""
    var actualModelID: String?
    var usage: AnalysisUsage?
    var notice: String?
}

extension Encounter {
    mutating func recoverInterruptedAnalysis() {
        for index in (analysisRuns ?? []).indices where analysisRuns?[index].status.isActive == true {
            analysisRuns?[index].status = .incomplete
            analysisRuns?[index].notice = "App wurde während der Anfrage beendet. Gesicherter Zwischenstand; kein automatischer Neuversand."
        }
    }
}

/// Standalone conversations have no clinical case and live in a separate encrypted table.
struct QuickCheck: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var draft = SparringDraft()
    var runs: [AnalysisRun] = []
    var chatAttachments: [ChatAttachment]?
    var title: String {
        let text = runs.first?.snapshot.draft.question ?? draft.question
        return text.isEmpty ? "Neuer Schnellcheck" : String(text.prefix(70))
    }
    var analysisContext: Encounter {
        Encounter(id: id, date: createdAt, reason: "Schnellcheck", sparringDraft: draft, analysisRuns: runs, chatAttachments: chatAttachments)
    }
}
