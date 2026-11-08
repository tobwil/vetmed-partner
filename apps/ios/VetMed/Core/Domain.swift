import Foundation

struct AppFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum EncounterState: String, Codable, Sendable {
    case draft, recording, paused, transcribing, transcriptReady, generating, reviewRequired, approved, interrupted, failed
    var title: String {
        switch self {
        case .draft: "Entwurf"; case .recording: "Aufnahme läuft"; case .paused: "Pausiert"
        case .transcribing: "Wird lokal transkribiert"; case .transcriptReady: "Transkript bereit"
        case .generating: "Bericht entsteht lokal"; case .reviewRequired: "Prüfung erforderlich"
        case .approved: "Geprüft"; case .interrupted: "Unterbrochen"; case .failed: "Aktion fehlgeschlagen"
        }
    }
}
enum ReportTemplate: String, CaseIterable, Codable, Identifiable, Sendable {
    case treatment_report, soap, follow_up, referral, owner_information
    /// Legacy: written by an earlier Android build. Kept so stored reports and backups stay readable; not offered for new reports.
    case meeting_summary
    var id: String { rawValue }
    var title: String {
        switch self { case .treatment_report: "Behandlungsbericht"; case .soap: "SOAP"; case .follow_up: "Verlauf / Kontrolle"; case .referral: "Überweisung"; case .owner_information: "Information für Tierhalter"; case .meeting_summary: "Besprechungszusammenfassung" }
    }
    var audience: Audience { self == .owner_information ? .owner : .veterinarian }
    /// Whether new reports can be created with this template.
    var isSelectable: Bool { self != .meeting_summary }
    /// Templates offered for new reports, in display order.
    static var selectable: [ReportTemplate] { allCases.filter(\.isSelectable) }
    var sections: [String] {
        switch self {
        case .treatment_report: ["Anamnese", "Befunde", "Beurteilung", "Therapie", "Weiteres Vorgehen"]
        case .soap: ["Subjektiv", "Objektiv", "Beurteilung", "Plan"]
        case .follow_up: ["Anlass", "Veränderung", "Heutige Befunde", "Maßnahmen", "Nächster Schritt"]
        case .referral: ["Fragestellung", "Vorgeschichte", "Befunde", "Bisherige Behandlung"]
        case .owner_information: ["Beobachtungen", "Einordnung", "Vereinbarte Schritte"]
        case .meeting_summary: ["Zusammenfassung", "Besprochene Themen", "Vereinbarungen", "Offene Fragen"]
        }
    }
}
enum ReportLength: String, CaseIterable, Codable, Identifiable, Sendable {
    case short, medium, detailed
    var id: String { rawValue }
    var title: String { switch self { case .short: "Kurz"; case .medium: "Mittel"; case .detailed: "Ausführlich" } }
}
enum Audience: String, CaseIterable, Codable, Identifiable, Sendable {
    case veterinarian, owner
    var id: String { rawValue }
    var title: String { self == .veterinarian ? "Tierärztliche Fachkollegen" : "Tierhalter" }
}
struct VetCase: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var label: String
    var species: String
    var animalName = ""
    var createdAt = Date()
    var archivedAt: Date?
    var encounters: [Encounter] = []
}
struct Encounter: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var reason = "Neues Diktat"
    var state: EncounterState = .draft
    var audio: [AudioSegment] = []
    var transcripts: [TranscriptVersion] = []
    var reports: [ReportVersion] = []
    var reportCheckpoint: ReportCheckpoint?
    var cloudReportRequests: [CloudReportRequest]?
    var sparringDraft: SparringDraft?
    var analysisRuns: [AnalysisRun]?
    var chatAttachments: [ChatAttachment]?
    var shares: [ShareEvent] = []
    var lastError: String?
    var playbackSegments: [TranscriptSegment] {
        var seen = Set<String>()
        return transcripts.flatMap(\.segments).filter { $0.audioID != nil && seen.insert($0.id).inserted }
    }
}
struct ReportCheckpoint: Codable, Equatable, Sendable {
    var report: ReportVersion
    var completedChunks: Int
    var totalChunks: Int
}
struct AudioSegment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var duration: Double
    var createdAt = Date()
    var recovered = false
}
struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var audioID: UUID?
    var startSeconds: Double?
    var endSeconds: Double?
}
struct TranscriptVersion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var parentID: UUID?
    var createdAt = Date()
    var rawText: String
    var editedText: String
    var segments: [TranscriptSegment]
    var engine: String
}
struct SourceReference: Codable, Equatable, Sendable {
    var segmentId: String
    var quote: String
}
struct ReportItem: Codable, Equatable, Sendable {
    var text: String
    var sourceRefs: [SourceReference]
    var origin: String
}
struct ReportSection: Codable, Equatable, Sendable {
    var key: String
    var items: [ReportItem]
}
struct StructuredReport: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var template: ReportTemplate
    var length: ReportLength
    var audience: Audience
    var sourceTranscriptVersionId: String
    var sections: [ReportSection]
    var missingInformation: [String]
    var conflicts: [String]
    var requiresReview = true
    /// Sources left out as not clinical (greetings, small talk), shown for review; never part of `text` (ADR 0018).
    var omitted: [OmittedSource]?
    var text: String {
        // Built in steps: the single long expression is slow for the type checker.
        let body: [String] = sections.map { section in
            let lines: [String] = section.items.map { "• " + $0.text }
            return section.key + "\n" + lines.joined(separator: "\n")
        }
        var result = body.joined(separator: "\n\n")
        if !missingInformation.isEmpty { result += "\n\nOffene Angaben\n" + missingInformation.joined(separator: "\n") }
        if !conflicts.isEmpty { result += "\n\nWidersprüche\n" + conflicts.joined(separator: "\n") }
        return result
    }
}
/// A transcript sentence the model marked as not clinical. Only sentences without numbers and negations qualify.
struct OmittedSource: Codable, Equatable, Sendable {
    var segmentId: String
    var text: String
    var reason: String
}
struct ReportVersion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var parentID: UUID?
    var createdAt = Date()
    var content: StructuredReport
    var editedText: String?
    var modelID: String
    var modelRevision: String
    var promptVersion = "report-v2"
    var warnings: [String]
    var approvedAt: Date?
    var text: String { editedText ?? content.text }
    var exportText: String { (approvedAt == nil ? "ENTWURF – fachliche Prüfung erforderlich" : "Fachlich geprüft am " + approvedAt!.formatted()) + "\n\n" + text }
}
struct ShareEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var reportID: UUID
    var format: String
    var date = Date()
    var status = "An Systemfunktion übergeben; Zustellung unbekannt"
}
struct VaultDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var cases: [VetCase] = []
    var quickChecks: [QuickCheck]?
}
struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var recognized: String
    var preferred: String
    func appears(in text: String) -> Bool { text.range(of: recognized, options: [.caseInsensitive]) != nil }
    func applying(to text: String) -> String { text.replacingOccurrences(of: recognized, with: preferred, options: [.caseInsensitive]) }
}
struct ModelOption: Sendable {
    var id: String
    static let gemma4E2B = Self(id: "mlx-community/gemma-4-e2b-it-4bit")
    static let supported = [gemma4E2B]
    static let revision = "238767527555cb75a05732a84dff5d6ba0dd6809"
}
