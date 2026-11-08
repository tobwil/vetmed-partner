package de.tobwil.vetmed.core

/** Where a step runs. ASK means: a Gemini key exists, but the user has not yet said whether audio may leave the device. */
enum class ProcessingRoute { ONLINE, DEVICE, ASK }

/**
 * Online first, never a silent switch (ADR 0014). With a configured online access, online is the default because it
 * reads and writes better than the on-device models. "Nur auf dem Gerät" overrides everything. When an online step
 * fails, the app shows the error and offers the device route as a button; it never falls back by itself.
 */
object Processing {
    /** Speech-to-text: Gemini once its key exists and the user agreed once; the device recognizer otherwise. */
    fun transcription(online: OnlineReportConfiguration, gemini: GeminiTranscriptionConfiguration, hasGeminiKey: Boolean): ProcessingRoute = when {
        online.deviceOnly == true || !hasGeminiKey -> ProcessingRoute.DEVICE
        gemini.enabled -> ProcessingRoute.ONLINE
        gemini.decidedAt != null -> ProcessingRoute.DEVICE
        else -> ProcessingRoute.ASK
    }

    /** Preselected mode for a new report. The user can still pick the other one per report. */
    fun reportMode(online: OnlineReportConfiguration, hasKey: Boolean): ReportExecutionMode =
        if (online.deviceOnly != true && online.isEnabled && hasKey) ReportExecutionMode.ONLINE else ReportExecutionMode.OFFLINE

    /** Lab results: page images to the chosen model, unless "Nur auf dem Gerät" or no online access. */
    fun labRoute(online: OnlineReportConfiguration, hasKey: Boolean): ProcessingRoute =
        if (online.deviceOnly != true && online.isEnabled && hasKey) ProcessingRoute.ONLINE else ProcessingRoute.DEVICE

    /** One sentence for settings: what runs where right now. */
    fun summary(online: OnlineReportConfiguration, hasKey: Boolean, transcription: ProcessingRoute): String = when {
        online.deviceOnly == true -> "Nur auf dem Gerät: Transkription und Berichte bleiben auf diesem Gerät. Die Qualität ist geringer."
        !online.isEnabled || !hasKey -> "Kein Online-Zugang eingerichtet: Es wird auf dem Gerät verarbeitet. Mit eigenem API-Key wird Online der Standard."
        else -> "Online mit ${online.provider.title} (beste Qualität) für Berichte und Chat. Transkription: " + when (transcription) {
            ProcessingRoute.ONLINE -> "online mit Gemini."
            ProcessingRoute.ASK -> "Gemini, nach einmaliger Zustimmung bei der ersten Aufnahme."
            ProcessingRoute.DEVICE -> "auf dem Gerät."
        }
    }

    /** Shown once before the first online transcription: what leaves the device, and the paid-tier requirement. */
    const val TRANSCRIPTION_CONSENT =
        "Für die beste Erkennung werden die Audioteile dieser und künftiger Aufnahmen an Google (Gemini) gesendet. " +
            "Fälle, Transkripte und Berichte bleiben verschlüsselt auf diesem Gerät. Für Patienten- und Halterdaten nur einen Key " +
            "mit aktivierter Abrechnung verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen. " +
            "Du kannst das jederzeit in den Einstellungen ändern."
}
