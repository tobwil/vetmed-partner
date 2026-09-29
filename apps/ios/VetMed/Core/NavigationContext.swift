import Foundation

enum AppTab: Hashable { case start, cases, chat }

/// A view owns its scope for its entire lifetime, including delayed saves and share callbacks.
struct EncounterLocation: Hashable, Identifiable, Sendable {
    let caseID: UUID
    let encounterID: UUID
    var id: UUID { encounterID }
    var chat: ChatLocation { ChatLocation(caseID: caseID, encounterID: encounterID) }
}
struct ChatLocation: Hashable, Identifiable, Sendable {
    let caseID: UUID?
    let encounterID: UUID
    var id: UUID { encounterID }
}

enum EncounterStep: Int, CaseIterable, Identifiable {
    case recording, transcript, report
    var id: Int { rawValue }
    var title: String {
        switch self { case .recording: "Aufnehmen"; case .transcript: "Text prüfen"; case .report: "Bericht" }
    }
}
extension Encounter {
    var lastActivity: Date {
        ([date] + transcripts.map(\.createdAt) + reports.map(\.createdAt) + (analysisRuns ?? []).map(\.createdAt)).max() ?? date
    }
    var suggestedStep: EncounterStep {
        if !reports.isEmpty { return .report }
        if !transcripts.isEmpty { return .transcript }
        return .recording
    }
    var nextAction: String {
        if let report = reports.last { return report.approvedAt == nil ? "Bericht prüfen" : "Bericht ansehen" }
        if !transcripts.isEmpty { return "Text prüfen" }
        return audio.isEmpty ? "Diktat aufnehmen" : "Aufnahme fortsetzen"
    }
    var hasPendingAudio: Bool {
        let done = Set(transcripts.flatMap(\.segments).compactMap(\.audioID))
        return audio.contains { !done.contains($0.id) }
    }
}
