import Foundation

/// Where a step runs. `.ask`: a Gemini key exists, but the user has not yet said whether audio may leave the device.
enum ProcessingRoute: Sendable, Equatable { case online, device, ask }

/// Online speech-to-text with the user's own Gemini key (same rules as Android's `GeminiTranscriptionConfiguration`).
/// It is the default once the key exists and the user agreed once (`decidedAt`); before that the app asks.
struct GeminiTranscriptionConfiguration: Codable, Equatable, Sendable {
    static let defaultModel = "gemini-3.6-flash"
    var enabled = false
    var modelID = GeminiTranscriptionConfiguration.defaultModel
    /// When the user explicitly chose online or device transcription.
    var decidedAt: Date?
    /// One-time consent for the voice mode (conversation audio and the chosen case context go to Gemini Live).
    var voiceConsentAt: Date?
}

/// Online first, never a silent switch (ADR 0014). Same rules as Android's `Processing`.
/// With a configured online access, online is the default because it reads and writes better than the on-device
/// models. "Nur auf dem Gerät" overrides everything. When an online step fails, the app shows the error and offers
/// the device route as a button; it never falls back by itself.
enum Processing {
    static func transcription(online: OnlineReportConfiguration, gemini: GeminiTranscriptionConfiguration, hasGeminiKey: Bool) -> ProcessingRoute {
        if online.deviceOnly == true || !hasGeminiKey { return .device }
        if gemini.enabled { return .online }
        return gemini.decidedAt != nil ? .device : .ask
    }

    /// Preselected mode for a new report. The user can still pick the other one per report.
    static func reportMode(online: OnlineReportConfiguration, hasKey: Bool) -> ReportExecutionMode {
        online.deviceOnly != true && online.isEnabled && hasKey ? .online : .offline
    }

    /// Lab results: page images to the chosen model, unless "Nur auf dem Gerät" or no online access.
    static func labRoute(online: OnlineReportConfiguration, hasKey: Bool) -> ProcessingRoute {
        online.deviceOnly != true && online.isEnabled && hasKey ? .online : .device
    }

    static func summary(online: OnlineReportConfiguration, hasKey: Bool, transcription: ProcessingRoute) -> String {
        if online.deviceOnly == true { return "Nur auf dem Gerät: Transkription und Berichte bleiben auf diesem Gerät. Die Qualität ist geringer." }
        guard online.isEnabled, hasKey else { return "Kein Online-Zugang eingerichtet: Es wird auf dem Gerät verarbeitet. Mit eigenem API-Key wird Online der Standard." }
        let speech: String
        switch transcription {
        case .online: speech = "online mit Gemini."
        case .ask: speech = "Gemini, nach einmaliger Zustimmung bei der ersten Aufnahme."
        case .device: speech = "auf dem Gerät."
        }
        return "Online mit \(online.activeProvider.title) (beste Qualität) für Berichte und Chat. Transkription: " + speech
    }

    /// Shown once before the first online transcription: what leaves the device, and the paid-tier requirement.
    static let transcriptionConsent =
        "Für die beste Erkennung werden die Audioteile dieser und künftiger Aufnahmen an Google (Gemini) gesendet. " +
        "Fälle, Transkripte und Berichte bleiben verschlüsselt auf diesem Gerät. Für Patienten- und Halterdaten nur einen Key " +
        "mit aktivierter Abrechnung verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen. " +
        "Du kannst das jederzeit in den Einstellungen ändern."
}

/// After an online step failed: the device route, offered as a button. Never taken automatically.
struct DeviceOffer: Equatable, Sendable {
    enum Kind: Sendable { case transcription, report }
    let location: EncounterLocation
    let kind: Kind
}
