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
    func validate() throws {
        guard question.utf8.count <= 16_384, context.utf8.count <= 49_152, historyIDs.count <= 40 else {
            throw AppFailure("Der Entwurf ist zu groß. Bitte Frage, Falltext oder ausgewählten Verlauf verkleinern. Es wird nichts still gekürzt.")
        }
    }
    var message: String { "Aufgabe: \(mode.title)\n\nAusgewählter Falltext:\n\(context.isEmpty ? "Kein zusätzlicher Falltext ausgewählt." : context)\n\nFrage:\n\(question)" }
}
struct SparringSnapshot: Codable, Equatable, Sendable {
    let caseID: UUID?
    let encounterID: UUID
    let modelID: String
    let draft: SparringDraft
    let payload: Data
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
    var title: String {
        let text = runs.first?.snapshot.draft.question ?? draft.question
        return text.isEmpty ? "Neuer Schnellcheck" : String(text.prefix(70))
    }
    var analysisContext: Encounter {
        Encounter(id: id, date: createdAt, reason: "Schnellcheck", sparringDraft: draft, analysisRuns: runs)
    }
}
