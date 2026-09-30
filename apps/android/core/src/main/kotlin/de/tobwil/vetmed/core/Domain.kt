package de.tobwil.vetmed.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID

/** User-facing failure. The message is shown as-is. */
class AppFailure(message: String) : Exception(message)

fun newId(): String = UUID.randomUUID().toString().uppercase()

/** Same JSON conventions as the iOS app: Swift's default Date encoding (seconds since 2001-01-01). */
object AppleDateSerializer : KSerializer<Instant> {
    private const val REFERENCE_EPOCH = 978_307_200.0
    override val descriptor = PrimitiveSerialDescriptor("AppleDate", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Instant) {
        encoder.encodeDouble(value.epochSecond + value.nano / 1e9 - REFERENCE_EPOCH)
    }
    // A Double near 8e8 s resolves ~0.1 µs; rounding to µs makes app-created (ms) times round-trip exactly.
    override fun deserialize(decoder: Decoder): Instant =
        Instant.EPOCH.plus(Math.round((decoder.decodeDouble() + REFERENCE_EPOCH) * 1e6), ChronoUnit.MICROS)
}

/** Current time at millisecond precision, the resolution the stored JSON keeps exactly. */
fun now(): Instant = Instant.now().truncatedTo(ChronoUnit.MILLIS)
typealias AppleDate = @Serializable(with = AppleDateSerializer::class) Instant

val VetJson = Json {
    encodeDefaults = true
    ignoreUnknownKeys = true
    explicitNulls = false
}

private val germanDateTime = DateTimeFormatter.ofPattern("dd.MM.yyyy, HH:mm", Locale.GERMANY)
fun Instant.germanDateTime(zone: ZoneId = ZoneId.systemDefault()): String = germanDateTime.format(atZone(zone))

@Serializable
enum class EncounterState(val title: String) {
    @SerialName("draft") DRAFT("Entwurf"),
    @SerialName("recording") RECORDING("Aufnahme läuft"),
    @SerialName("paused") PAUSED("Pausiert"),
    @SerialName("transcribing") TRANSCRIBING("Wird lokal transkribiert"),
    @SerialName("transcriptReady") TRANSCRIPT_READY("Transkript bereit"),
    @SerialName("generating") GENERATING("Bericht entsteht"),
    @SerialName("reviewRequired") REVIEW_REQUIRED("Prüfung erforderlich"),
    @SerialName("approved") APPROVED("Geprüft"),
    @SerialName("interrupted") INTERRUPTED("Unterbrochen"),
    @SerialName("failed") FAILED("Aktion fehlgeschlagen"),
}

@Serializable
enum class Audience(val title: String) {
    @SerialName("veterinarian") VETERINARIAN("Tierärztliche Fachkollegen"),
    @SerialName("owner") OWNER("Tierhalter"),
}

@Serializable
enum class ReportTemplate(val title: String, val sections: List<String>) {
    @SerialName("treatment_report") TREATMENT_REPORT("Behandlungsbericht", listOf("Anamnese", "Befunde", "Beurteilung", "Therapie", "Weiteres Vorgehen")),
    @SerialName("soap") SOAP("SOAP", listOf("Subjektiv", "Objektiv", "Beurteilung", "Plan")),
    @SerialName("follow_up") FOLLOW_UP("Verlauf / Kontrolle", listOf("Anlass", "Veränderung", "Heutige Befunde", "Maßnahmen", "Nächster Schritt")),
    @SerialName("referral") REFERRAL("Überweisung", listOf("Fragestellung", "Vorgeschichte", "Befunde", "Bisherige Behandlung")),
    @SerialName("owner_information") OWNER_INFORMATION("Information für Tierhalter", listOf("Beobachtungen", "Einordnung", "Vereinbarte Schritte"));
    val audience: Audience get() = if (this == OWNER_INFORMATION) Audience.OWNER else Audience.VETERINARIAN
}

@Serializable
enum class ReportLength(val title: String) {
    @SerialName("short") SHORT("Kurz"),
    @SerialName("medium") MEDIUM("Mittel"),
    @SerialName("detailed") DETAILED("Ausführlich"),
}

@Serializable
data class VetCase(
    val id: String = newId(),
    val label: String,
    val species: String,
    val animalName: String = "",
    val createdAt: AppleDate = now(),
    val archivedAt: AppleDate? = null,
    val encounters: List<Encounter> = emptyList(),
) {
    val displayName: String get() = if (animalName.isEmpty()) label else "$animalName · $label"
}

@Serializable
data class Encounter(
    val id: String = newId(),
    val date: AppleDate = now(),
    val reason: String = "Neues Diktat",
    val state: EncounterState = EncounterState.DRAFT,
    val audio: List<AudioSegment> = emptyList(),
    val transcripts: List<TranscriptVersion> = emptyList(),
    val reports: List<ReportVersion> = emptyList(),
    val reportCheckpoint: ReportCheckpoint? = null,
    val cloudReportRequests: List<CloudReportRequest>? = null,
    val shares: List<ShareEvent> = emptyList(),
    val lastError: String? = null,
) {
    val lastActivity: Instant get() = (listOf(date) + transcripts.map { it.createdAt } + reports.map { it.createdAt }).max()
    val suggestedStep: EncounterStep get() = when {
        reports.isNotEmpty() -> EncounterStep.REPORT
        transcripts.isNotEmpty() -> EncounterStep.TRANSCRIPT
        else -> EncounterStep.RECORDING
    }
    val nextAction: String get() {
        val report = reports.lastOrNull()
        return when {
            report != null -> if (report.approvedAt == null) "Bericht prüfen" else "Bericht ansehen"
            transcripts.isNotEmpty() -> "Text prüfen"
            audio.isEmpty() -> "Diktat aufnehmen"
            else -> "Aufnahme fortsetzen"
        }
    }
    val playbackSegments: List<TranscriptSegment> get() {
        val seen = mutableSetOf<String>()
        return transcripts.flatMap { it.segments }.filter { it.audioID != null && seen.add(it.id) }
    }
}

enum class EncounterStep(val title: String) { RECORDING("Aufnehmen"), TRANSCRIPT("Text prüfen"), REPORT("Bericht") }

@Serializable
data class AudioSegment(val id: String, val duration: Double, val createdAt: AppleDate = now(), val recovered: Boolean = false)

@Serializable
data class TranscriptSegment(
    val id: String,
    val text: String,
    val audioID: String? = null,
    val startSeconds: Double? = null,
    val endSeconds: Double? = null,
)

@Serializable
data class TranscriptVersion(
    val id: String = newId(),
    val parentID: String? = null,
    val createdAt: AppleDate = now(),
    val rawText: String,
    val editedText: String,
    val segments: List<TranscriptSegment>,
    val engine: String,
)

@Serializable data class SourceReference(val segmentId: String, val quote: String)
@Serializable data class ReportItem(val text: String, val sourceRefs: List<SourceReference>, val origin: String)
@Serializable data class ReportSection(val key: String, val items: List<ReportItem>)

@Serializable
data class StructuredReport(
    val schemaVersion: Int = 1,
    val template: ReportTemplate,
    val length: ReportLength,
    val audience: Audience,
    val sourceTranscriptVersionId: String,
    val sections: List<ReportSection>,
    val missingInformation: List<String>,
    val conflicts: List<String>,
    val requiresReview: Boolean = true,
) {
    val text: String get() =
        sections.joinToString("\n\n") { section -> section.key + "\n" + section.items.joinToString("\n") { "• " + it.text } } +
            (if (missingInformation.isEmpty()) "" else "\n\nOffene Angaben\n" + missingInformation.joinToString("\n")) +
            (if (conflicts.isEmpty()) "" else "\n\nWidersprüche\n" + conflicts.joinToString("\n"))
}

@Serializable
data class ReportVersion(
    val id: String = newId(),
    val parentID: String? = null,
    val createdAt: AppleDate = now(),
    val content: StructuredReport,
    val editedText: String? = null,
    val modelID: String,
    val modelRevision: String,
    val promptVersion: String = "report-v1",
    val warnings: List<String>,
    val approvedAt: AppleDate? = null,
) {
    val text: String get() = editedText ?: content.text
    val exportText: String get() =
        (approvedAt?.let { "Fachlich geprüft am " + it.germanDateTime() } ?: "ENTWURF – fachliche Prüfung erforderlich") + "\n\n" + text
}

@Serializable
data class ReportCheckpoint(val report: ReportVersion, val completedChunks: Int, val totalChunks: Int)

@Serializable
data class ShareEvent(
    val id: String = newId(),
    val reportID: String,
    val format: String,
    val date: AppleDate = now(),
    val status: String = "An Systemfunktion übergeben; Zustellung unbekannt",
)

@Serializable
data class CloudReportRequest(
    val id: String = newId(),
    val date: AppleDate = now(),
    val provider: String = "OpenAI",
    val modelID: String,
    val transcriptVersionID: String,
    /** Base64 of the exact request body, matching how iOS encodes `Data`. */
    val payload: String,
    val status: String = "Versand begonnen; Ergebnis noch unbekannt",
    val responseModelID: String? = null,
)

@Serializable
data class VaultDocument(val schemaVersion: Int = 1, val cases: List<VetCase> = emptyList())

@Serializable
data class VocabularyEntry(val id: String = newId(), val recognized: String, val preferred: String) {
    fun appears(text: String): Boolean = text.contains(recognized, ignoreCase = true)
    fun applying(text: String): String = text.replace(recognized, preferred, ignoreCase = true)
}
