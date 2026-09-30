package de.tobwil.vetmed.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.UnknownHostException
import java.security.MessageDigest
import java.util.Base64

object AttachmentLimits {
    const val MAXIMUM_ORIGINAL_BYTES = 20 * 1_048_576
    const val MAXIMUM_IMAGE_BYTES = 2 * 1_048_576
    const val MAXIMUM_IMAGE_EDGE = 4096
    const val MAXIMUM_SOURCE_PIXELS = 64_000_000L
    fun sha256(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
}

/** Port of the iOS `SparringRequestBuilder`: nothing is silently shortened or dropped. */
object SparringRequestBuilder {
    const val MAXIMUM_PAYLOAD_BYTES = 98_304
    const val MAXIMUM_OUTPUT_BYTES = 262_144
    val instructions: String by lazy { Prompts.load("sparring-v1") }

    fun prepare(caseID: String?, encounter: Encounter, draft: SparringDraft, modelID: String, caseContext: VetCase? = null, instructions: String = this.instructions): SparringSnapshot {
        draft.validate()
        if (draft.question.isBlank()) throw AppFailure("Bitte eine Frage eingeben.")
        if (modelID.isEmpty() || modelID.encodeToByteArray().size >= 256 || modelID.any { it.isWhitespace() }) throw AppFailure("Bitte eine gültige Modell-ID in Einstellungen auswählen.")
        val selected = draft.historyIDs.toSet()
        val runs = encounter.analysisRuns.orEmpty().filter { it.id in selected }
        if (selected.size != draft.historyIDs.size || runs.size != selected.size ||
            !runs.all { it.status == AnalysisStatus.COMPLETED && it.snapshot.caseID == caseID && it.snapshot.encounterID == encounter.id }
        ) throw AppFailure("Der ausgewählte Verlauf ist unvollständig oder gehört nicht zu diesem Vorgang. Bitte die Auswahl prüfen.")
        draft.transcriptVersionID?.let { id -> if (encounter.transcripts.none { it.id == id }) throw AppFailure("Der ausgewählte Falltext gehört nicht zu diesem Vorgang.") }
        val reports = ChatReportSelection.resolve(draft.reportIDs.orEmpty(), caseID, encounter.id, caseContext)
        val selection = draft.attachmentIDs.orEmpty()
        if (selection.toSet().size != selection.size) throw AppFailure("Ein Anhang wurde mehrfach ausgewählt.")
        val attachments = encounter.chatAttachments.orEmpty()
        val images = mutableListOf<ChatImageReference>()
        val documents = mutableListOf<ChatDocumentReference>()
        for (id in selection) {
            val attachment = attachments.firstOrNull { it.id == id } ?: throw AppFailure("Ein ausgewählter Anhang fehlt in diesem Chat.")
            if (attachment.kind == AttachmentKind.IMAGE) {
                val hash = attachment.uploadSHA256; val bytes = attachment.uploadByteCount; val width = attachment.width; val height = attachment.height
                if (hash == null || bytes == null || width == null || height == null) throw AppFailure("Das Versandbild ist nicht vollständig vorbereitet.")
                images += ChatImageReference(id, hash, bytes, width, height)
            } else {
                val text = attachment.reviewedText
                if (attachment.reviewedAt == null || text == null) throw AppFailure("Bitte den Text des Dokuments vor dem Senden prüfen.")
                documents += ChatDocumentReference(id, attachment.originalSHA256, text)
            }
        }
        val draftSnapshot = SparringSnapshot(caseID, encounter.id, modelID, draft, ByteArray(0), images, documents, reports = reports)
        fun message(text: String, images: List<ChatImageReference>): JsonObject = buildJsonObject {
            put("role", "user")
            if (images.isEmpty()) put("content", text) else put("content", buildJsonArray {
                add(buildJsonObject { put("type", "input_text"); put("text", text) })
                images.forEach { image -> add(buildJsonObject { put("type", "input_image"); put("image_url", image.placeholder); put("detail", "high") }) }
            })
        }
        val allImages = mutableListOf<ChatImageReference>()
        val messages = buildJsonArray {
            // Only the current report selection is sent; old requests keep their immutable report snapshots.
            for (run in runs) {
                add(message(run.snapshot.conversationText, run.snapshot.images.orEmpty()))
                allImages += run.snapshot.images.orEmpty()
                add(buildJsonObject { put("role", "assistant"); put("content", run.text) })
            }
            add(message(draftSnapshot.userText, images)); allImages += images
        }
        if (allImages.size > 8 || !allImages.all { it.byteCount in 1..AttachmentLimits.MAXIMUM_IMAGE_BYTES && it.width > 0 && it.height > 0 } ||
            allImages.sumOf { it.byteCount.toLong() } > 16L * 1_048_576
        ) throw AppFailure("Dieser Chat enthält mehr Bilder als in eine Anfrage passen. Bitte für weitere Bilder einen neuen Chat starten; es wird nichts unbemerkt weggelassen.")
        val body = buildJsonObject {
            put("background", false)
            put("input", messages)
            put("instructions", instructions)
            put("max_output_tokens", 8192)
            put("model", modelID)
            put("store", false)
            put("stream", true)
        }
        val data = body.toString().encodeToByteArray()
        if (data.size > MAXIMUM_PAYLOAD_BYTES) {
            throw AppFailure("Die Anfrage ist zu groß. Bitte weniger Berichte auswählen oder für einen kürzeren Verlauf einen neuen Chat starten. Es wird nichts unbemerkt weggelassen.")
        }
        return draftSnapshot.copy(payload = data, requestImages = allImages)
    }

    /** Replaces image placeholders with the verified JPEG bytes. Any mismatch stops the request. */
    fun request(snapshot: SparringSnapshot, key: String, imageData: Map<String, ByteArray> = emptyMap()): HttpRequest {
        validateApiKey(key)
        if (snapshot.payload.size > MAXIMUM_PAYLOAD_BYTES) throw AppFailure("Die Anfrage ist zu groß.")
        val references = snapshot.requestImages.orEmpty()
        val root = runCatching { Json.parseToJsonElement(snapshot.payload.decodeToString()).jsonObject }.getOrNull()
            ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
        val input = root["input"] as? JsonArray ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
        val parts = input.flatMap { (it.jsonObject["content"] as? JsonArray).orEmpty() }.filter { (it as? JsonObject)?.get("type")?.jsonPrimitive?.contentOrNull == "input_image" }
        if (parts.size != references.size) throw AppFailure("Die Bildauswahl stimmt nicht mit der Anfrage überein.")
        var body = snapshot.payload
        if (references.isNotEmpty()) {
            if (references.size > 8 || !references.all { it.byteCount in 1..AttachmentLimits.MAXIMUM_IMAGE_BYTES } || references.sumOf { it.byteCount.toLong() } > 16L * 1_048_576) {
                throw AppFailure("Zu viele Bilddaten für eine Anfrage.")
            }
            val urls = references.associate { reference ->
                val data = imageData[reference.attachmentID]
                if (data == null || data.size != reference.byteCount || AttachmentLimits.sha256(data) != reference.sha256) {
                    throw AppFailure("Ein Bild fehlt oder wurde verändert. Es wird nichts gesendet.")
                }
                reference.placeholder to "data:image/jpeg;base64," + Base64.getEncoder().encodeToString(data)
            }
            var count = 0
            val replaced = JsonArray(input.map { message ->
                val content = message.jsonObject["content"] as? JsonArray ?: return@map message
                JsonObject(message.jsonObject + ("content" to JsonArray(content.map { part ->
                    val obj = part.jsonObject
                    if (obj["type"]?.jsonPrimitive?.contentOrNull != "input_image") part else {
                        val url = urls[obj["image_url"]?.jsonPrimitive?.contentOrNull] ?: throw AppFailure("Ein Bildbezug ist ungültig.")
                        count += 1
                        JsonObject(obj + ("image_url" to JsonPrimitive(url)))
                    }
                })))
            })
            if (count != references.size) throw AppFailure("Die Bildauswahl stimmt nicht mit der Anfrage überein.")
            body = JsonObject(root + ("input" to replaced)).toString().encodeToByteArray()
            if (body.size > 24 * 1_048_576) throw AppFailure("Die Bildanfrage ist zu groß.")
        }
        return HttpRequest(
            OpenAIReportApi.RESPONSES_URL, "POST",
            mapOf("Authorization" to "Bearer $key", "Content-Type" to "application/json", "Accept" to "text/event-stream"), body,
        )
    }
}

/** Incremental SSE framing: limits apply before a newline arrives, including malicious long lines. */
class BoundedSseDecoder {
    private val line = ByteArrayOutputStream()
    private val fields = ByteArrayOutputStream()
    private var total = 0
    fun feed(byte: Byte): ByteArray? {
        total += 1
        if (total > 4_194_304 || line.size() >= 524_288 || fields.size() >= 524_288) throw AppFailure("Der Antwortstream überschreitet das Größenlimit.")
        if (byte != '\n'.code.toByte()) { line.write(byte.toInt()); return null }
        var current = line.toByteArray()
        line.reset()
        if (current.isNotEmpty() && current.last() == '\r'.code.toByte()) current = current.copyOf(current.size - 1)
        if (current.isEmpty()) {
            if (fields.size() == 0) return null
            return fields.toByteArray().also { fields.reset() }
        }
        val prefix = "data:".encodeToByteArray()
        if (current.size >= prefix.size && current.copyOfRange(0, prefix.size).contentEquals(prefix)) {
            var start = prefix.size
            if (start < current.size && current[start] == ' '.code.toByte()) start += 1
            if (fields.size() > 0) fields.write('\n'.code)
            if (fields.size() + current.size - start > 524_288) throw AppFailure("Ein Antwortabschnitt ist zu groß.")
            fields.write(current, start, current.size - start)
        }
        return null
    }
}

sealed interface AnalysisStreamUpdate {
    data class Text(val text: String) : AnalysisStreamUpdate
    data class Terminal(val status: AnalysisStatus, val text: String, val model: String?, val usage: AnalysisUsage?, val notice: String?) : AnalysisStreamUpdate
}

/** Only the provider's terminal event can mark a response complete. End of stream never implies completion. */
class OpenAIAnalysisDecoder {
    var text = ""; private set
    var terminal = false; private set
    private var lastSequence: Int? = null
    private var sawRefusal = false
    private var activePart: String? = null
    private val partIDs = mutableSetOf<String>()

    fun consume(data: ByteArray): AnalysisStreamUpdate? {
        if (terminal) throw AppFailure("Unerwartete Daten nach Ende der Antwort.")
        val raw = data.decodeToString()
        if (raw == "[DONE]") return null
        val event = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull()
        val type = event?.get("type")?.jsonPrimitive?.contentOrNull ?: throw AppFailure("Der Anbieter hat ein ungültiges Streaming-Ereignis geliefert.")
        (event["sequence_number"] as? JsonPrimitive)?.intOrNull?.let { sequence ->
            val last = lastSequence
            if (last != null && sequence <= last) throw AppFailure("Die Reihenfolge der Antwort ist ungültig. Der Zwischenstand bleibt unvollständig.")
            lastSequence = sequence
        }
        when (type) {
            "response.output_text.delta" -> {
                val delta = event.string("delta"); val item = event.string("item_id"); val index = (event["content_index"] as? JsonPrimitive)?.intOrNull
                if (delta == null || item == null || index == null) throw AppFailure("Ein Antwortabschnitt ist unvollständig.")
                val part = "$item:$index"
                if (activePart != part) {
                    if (part in partIDs) throw AppFailure("Verschachtelte Antwortabschnitte können nicht sicher dargestellt werden.")
                    if (text.isNotEmpty()) text += "\n\n"
                    activePart = part; partIDs += part
                }
                if (text.encodeToByteArray().size + delta.encodeToByteArray().size > SparringRequestBuilder.MAXIMUM_OUTPUT_BYTES) throw AppFailure("Die Antwort ist zu lang. Der Zwischenstand bleibt erhalten.")
                text += delta
                return AnalysisStreamUpdate.Text(text)
            }
            "response.refusal.delta", "response.refusal.done" -> { sawRefusal = true; return null }
            "response.completed", "response.incomplete", "response.failed" -> {
                val response = event["response"] as? JsonObject
                val status = response?.string("status") ?: throw AppFailure("Der Abschlussstatus der Antwort fehlt.")
                val model = response.string("model")
                val usage = (response["usage"] as? JsonObject)?.let { raw ->
                    val input = (raw["input_tokens"] as? JsonPrimitive)?.intOrNull; val output = (raw["output_tokens"] as? JsonPrimitive)?.intOrNull
                    if (input != null && output != null && input >= 0 && output >= 0) AnalysisUsage(input, output) else null
                }
                val content = (response["output"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                    .filter { it.string("type") == "message" }.flatMap { (it["content"] as? JsonArray).orEmpty().mapNotNull { part -> part as? JsonObject } }
                sawRefusal = sawRefusal || content.any { it.string("type") == "refusal" }
                val finalText = content.filter { it.string("type") == "output_text" }.mapNotNull { it.string("text") }.joinToString("\n\n")
                if (finalText.encodeToByteArray().size > SparringRequestBuilder.MAXIMUM_OUTPUT_BYTES) throw AppFailure("Die Antwort ist zu lang.")
                terminal = true
                if (sawRefusal) return AnalysisStreamUpdate.Terminal(AnalysisStatus.REFUSED, text, model, usage, "Der Anbieter hat die Anfrage abgelehnt. Eine etwaige Teilantwort ist nicht vollständig.")
                if (type == "response.completed" && status == "completed" && finalText.isNotEmpty()) {
                    // Check the stream against the final object; never silently replace a differing partial answer.
                    if (text.isNotEmpty() && text != finalText) throw AppFailure("Stream und Abschlussantwort stimmen nicht überein. Bitte den unvollständigen Zwischenstand prüfen.")
                    return AnalysisStreamUpdate.Terminal(AnalysisStatus.COMPLETED, finalText, model, usage, null)
                }
                return AnalysisStreamUpdate.Terminal(
                    if (status == "failed") AnalysisStatus.FAILED else AnalysisStatus.INCOMPLETE, text.ifEmpty { finalText }, model, usage,
                    "Der Anbieter hat die Analyse nicht vollständig abgeschlossen. Ein neuer Versuch kann erneut Kosten verursachen.",
                )
            }
            "error" -> throw AppFailure("Der Anbieter hat die Analyse abgebrochen. Der Zwischenstand bleibt unvollständig; kein automatischer Neuversand.")
            else -> return null
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
}

fun interface StreamingTransport {
    /** Delivers complete SSE events until [receive] returns true; must throw if the stream ends first. */
    suspend fun stream(request: HttpRequest, receive: suspend (ByteArray) -> Boolean)
}

object OpenAIStreamingTransport : StreamingTransport {
    override suspend fun stream(request: HttpRequest, receive: suspend (ByteArray) -> Boolean) = withContext(Dispatchers.IO) {
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = 30_000
            connection.readTimeout = 120_000
            connection.requestMethod = request.method
            request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            request.body?.let { body -> connection.doOutput = true; connection.setFixedLengthStreamingMode(body.size); connection.outputStream.use { it.write(body) } }
            OpenAIReportApi.checkStatus(connection.responseCode)
            if (connection.contentType?.substringBefore(';')?.trim() != "text/event-stream") {
                throw AppFailure("Das Modell liefert keinen unterstützten Antwortstream. Bitte ein anderes Textmodell auswählen.")
            }
            val decoder = BoundedSseDecoder()
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer)
                    if (read < 0) break
                    for (i in 0 until read) {
                        val event = decoder.feed(buffer[i]) ?: continue
                        currentCoroutineContext().ensureActive()
                        if (receive(event)) return@withContext
                    }
                }
            }
            throw AppFailure("Die Verbindung endete vor dem Abschluss. Der Zwischenstand bleibt unvollständig. Ein neuer Versuch kann erneut Kosten verursachen.")
        } catch (error: UnknownHostException) {
            throw AppFailure("Offline: Der Entwurf bleibt lokal. Bei Netzrückkehr wird nichts automatisch gesendet.")
        } catch (error: IOException) {
            throw AppFailure("Die Verbindung wurde unterbrochen. Eine Verarbeitung beim Anbieter kann bereits begonnen haben. Kein automatischer Neuversand.")
        } finally {
            connection.disconnect()
        }
    }
}

class SparringService(private val transport: StreamingTransport = OpenAIStreamingTransport) {
    private val decoder = OpenAIAnalysisDecoder()

    suspend fun run(
        snapshot: SparringSnapshot,
        key: String,
        imageData: Map<String, ByteArray> = emptyMap(),
        beforeSending: suspend () -> Unit,
        receive: suspend (AnalysisStreamUpdate) -> Unit,
    ) {
        currentCoroutineContext().ensureActive()
        val request = SparringRequestBuilder.request(snapshot, key, imageData)
        beforeSending()
        currentCoroutineContext().ensureActive()
        transport.stream(request) { event ->
            decoder.consume(event)?.let { receive(it) }
            decoder.terminal
        }
        if (!decoder.terminal) throw AppFailure("Die Antwort wurde nicht vollständig abgeschlossen.")
    }
}
