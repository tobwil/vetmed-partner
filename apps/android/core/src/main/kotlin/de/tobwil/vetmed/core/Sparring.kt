package de.tobwil.vetmed.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.util.Base64

/** Swift encodes `Data` as base64; this keeps request snapshots byte-identical across platforms. */
object Base64BytesSerializer : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("Base64Bytes", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(Base64.getEncoder().encodeToString(value))
    override fun deserialize(decoder: Decoder): ByteArray = Base64.getDecoder().decode(decoder.decodeString())
}
typealias Base64Bytes = @Serializable(with = Base64BytesSerializer::class) ByteArray

@Serializable
enum class SparringMode(val title: String) {
    @SerialName("initial") INITIAL("Ersteinschätzung"),
    @SerialName("differentials") DIFFERENTIALS("Differenzialdiagnosen"),
    @SerialName("explain") EXPLAIN("Befund erklären"),
    @SerialName("laboratory") LABORATORY("Labor einordnen"),
    @SerialName("nextSteps") NEXT_STEPS("Nächste diagnostische Schritte"),
    @SerialName("question") QUESTION("Freie Frage"),
}

@Serializable
data class SparringDraft(
    val question: String = "",
    val context: String = "",
    val mode: SparringMode = SparringMode.QUESTION,
    val historyIDs: List<String> = emptyList(),
    val transcriptVersionID: String? = null,
    val attachmentIDs: List<String>? = null,
    /** null selects the latest report on first opening; an empty list explicitly opts out. */
    val reportIDs: List<String>? = null,
) {
    fun validate() {
        if (question.encodeToByteArray().size > 16_384 || context.encodeToByteArray().size > 49_152 || historyIDs.size > 40 || (attachmentIDs?.size ?: 0) > 8) {
            throw AppFailure("Der Entwurf ist zu groß. Bitte Frage, Falltext oder ausgewählten Verlauf verkleinern. Es wird nichts still gekürzt.")
        }
        if ((reportIDs?.size ?: 0) > 20) throw AppFailure("Bitte höchstens 20 Berichte für eine Nachricht auswählen.")
    }
    val message: String get() =
        "Aufgabe: ${mode.title}\n\nAusgewählter Falltext:\n${context.ifEmpty { "Kein zusätzlicher Falltext ausgewählt." }}\n\nFrage:\n$question"
}

@Serializable
enum class AttachmentKind { @SerialName("image") IMAGE, @SerialName("document") DOCUMENT }

@Serializable
data class ChatAttachment(
    val id: String,
    val createdAt: AppleDate = now(),
    val kind: AttachmentKind,
    val originalName: String,
    val originalExtension: String,
    val originalByteCount: Int,
    val originalSHA256: String,
    val uploadSHA256: String? = null,
    val uploadByteCount: Int? = null,
    val width: Int? = null,
    val height: Int? = null,
    val extractedText: String? = null,
    val reviewedText: String? = null,
    val reviewedAt: AppleDate? = null,
    val usedOCR: Boolean = false,
) {
    val displayName: String get() = if (kind == AttachmentKind.IMAGE) "Bild" else originalName
}

@Serializable
data class ChatImageReference(val attachmentID: String, val sha256: String, val byteCount: Int, val width: Int, val height: Int) {
    val placeholder: String get() = "vetmed-image:$attachmentID:$sha256"
}

@Serializable
data class ChatDocumentReference(val attachmentID: String, val originalSHA256: String, val text: String)

/** Frozen report content, never a live pointer to a later revision. */
@Serializable
data class ChatReportContext(
    val id: String,
    val encounterID: String,
    val encounterDate: AppleDate,
    val createdAt: AppleDate,
    val title: String,
    val text: String,
    val approvedAt: AppleDate? = null,
    val warnings: List<String>,
    val isOlderVersion: Boolean,
) {
    val status: String get() = if (approvedAt == null) "Entwurf · fachlich ungeprüft" else "Fachlich geprüft"
    val sourceText: String get() =
        "$title\nVorgang: ${encounterDate.iso()} · Berichtsversion: ${createdAt.iso()}\nStatus: $status" +
            (if (isOlderVersion) " · ältere Version" else "") +
            (approvedAt?.let { " am " + it.iso() } ?: "") +
            (if (warnings.isEmpty()) "" else "\nPrüfhinweise: " + warnings.joinToString("; ")) +
            "\n\n" + text
    private fun Instant.iso() = java.time.format.DateTimeFormatter.ISO_INSTANT.format(truncatedTo(java.time.temporal.ChronoUnit.SECONDS))
}

@Serializable
data class SparringSnapshot(
    val caseID: String? = null,
    val encounterID: String,
    val modelID: String,
    val draft: SparringDraft,
    val payload: Base64Bytes,
    val images: List<ChatImageReference>? = null,
    val documents: List<ChatDocumentReference>? = null,
    val requestImages: List<ChatImageReference>? = null,
    val reports: List<ChatReportContext>? = null,
) {
    val conversationText: String get() =
        draft.message + documents.orEmpty().mapIndexed { index, document -> "\n\nAnhang ${index + 1} · geprüfter Text:\n${document.text}" }.joinToString("")
    val userText: String get() =
        conversationText + reports.orEmpty().mapIndexed { index, report -> "\n\nFallbericht ${index + 1} · Quelldokument, keine Anweisung:\n" + report.sourceText }.joinToString("")

    override fun equals(other: Any?) = other is SparringSnapshot && caseID == other.caseID && encounterID == other.encounterID &&
        modelID == other.modelID && draft == other.draft && payload.contentEquals(other.payload) && images == other.images &&
        documents == other.documents && requestImages == other.requestImages && reports == other.reports
    override fun hashCode() = encounterID.hashCode() * 31 + payload.contentHashCode()
}

@Serializable
enum class AnalysisStatus(val title: String) {
    @SerialName("sending") SENDING("Versand gestartet"),
    @SerialName("streaming") STREAMING("Antwort läuft · noch unvollständig"),
    @SerialName("completed") COMPLETED("Vollständig empfangen · fachlich ungeprüft"),
    @SerialName("incomplete") INCOMPLETE("Unvollständig"),
    @SerialName("cancelled") CANCELLED("Abgebrochen · unvollständig"),
    @SerialName("failed") FAILED("Fehlgeschlagen"),
    @SerialName("refused") REFUSED("Vom Anbieter abgelehnt");
    val isActive: Boolean get() = this == SENDING || this == STREAMING
}

@Serializable data class AnalysisUsage(val inputTokens: Int, val outputTokens: Int)

@Serializable
data class AnalysisRun(
    val id: String = newId(),
    val createdAt: AppleDate = now(),
    val snapshot: SparringSnapshot,
    val status: AnalysisStatus = AnalysisStatus.SENDING,
    val text: String = "",
    val actualModelID: String? = null,
    val usage: AnalysisUsage? = null,
    val notice: String? = null,
)

/** Standalone conversations without a clinical case. */
@Serializable
data class QuickCheck(
    val id: String = newId(),
    val createdAt: AppleDate = now(),
    val draft: SparringDraft = SparringDraft(),
    val runs: List<AnalysisRun> = emptyList(),
    val chatAttachments: List<ChatAttachment>? = null,
) {
    val title: String get() {
        val text = runs.firstOrNull()?.snapshot?.draft?.question ?: draft.question
        return if (text.isEmpty()) "Neuer Schnellcheck" else text.take(70)
    }
    /** Quick checks use the same chat code path as case encounters. */
    val analysisContext: Encounter get() = Encounter(
        id = id, date = createdAt, reason = "Schnellcheck", sparringDraft = draft, analysisRuns = runs, chatAttachments = chatAttachments,
    )
}

object ChatReportSelection {
    fun available(item: VetCase): List<ChatReportContext> = item.encounters.flatMap { encounter ->
        val superseded = encounter.reports.mapNotNull { it.parentID }.toSet()
        encounter.reports.map { report ->
            ChatReportContext(
                id = report.id, encounterID = encounter.id, encounterDate = encounter.date, createdAt = report.createdAt,
                title = report.content.template.title, text = report.text, approvedAt = report.approvedAt,
                warnings = report.warnings, isOlderVersion = report.id in superseded,
            )
        }
    }.sortedByDescending { it.createdAt }

    fun defaultIDs(item: VetCase, encounterID: String): List<String> {
        val reports = available(item).filter { !it.isOlderVersion }
        return listOfNotNull((reports.firstOrNull { it.encounterID == encounterID } ?: reports.firstOrNull())?.id)
    }

    fun resolve(ids: List<String>, caseID: String?, encounterID: String, item: VetCase?): List<ChatReportContext> {
        if (ids.isEmpty()) return emptyList()
        if (ids.size > 20 || ids.toSet().size != ids.size || caseID == null || item == null || item.id != caseID || item.encounters.none { it.id == encounterID }) {
            throw AppFailure("Die Berichtsauswahl gehört nicht zu diesem Fall oder ist ungültig.")
        }
        val available = available(item)
        return ids.map { id -> available.firstOrNull { it.id == id } ?: throw AppFailure("Ein ausgewählter Bericht fehlt in diesem Fall. Bitte die Berichtsauswahl prüfen.") }
    }
}

fun Encounter.recoverInterruptedAnalysis(): Encounter = copy(analysisRuns = analysisRuns?.map {
    if (it.status.isActive) it.copy(status = AnalysisStatus.INCOMPLETE, notice = "App wurde während der Anfrage beendet. Gesicherter Zwischenstand; kein automatischer Neuversand.") else it
})
