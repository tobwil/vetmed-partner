package de.tobwil.vetmed.core

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.util.Base64

/**
 * Gemini counterpart of the OpenAI report and chat contracts: the same strict report items (as `responseSchema`),
 * the same stored chat snapshot (translated to `contents` only when sending) and the same "only the provider's
 * final event completes an answer" rule. The key travels only in the `x-goog-api-key` header.
 */
object GeminiOnlineApi {
    private const val BASE_URL = "https://generativelanguage.googleapis.com/v1beta/"

    private fun checkModel(modelID: String) {
        if (modelID.isEmpty() || modelID.encodeToByteArray().size >= 256 || modelID.any { it.isWhitespace() || it == '/' || it == '?' || it == ':' }) {
            throw AppFailure("Bitte eine gültige Modell-ID auswählen.")
        }
    }

    private fun headers(key: String, accept: String? = null) =
        mapOf("x-goog-api-key" to key, "Content-Type" to "application/json") + (accept?.let { mapOf("Accept" to it) } ?: emptyMap())

    private fun text(value: String) = buildJsonObject { put("text", value) }

    // Reports -----------------------------------------------------------------------------------------

    fun reportRequest(modelID: String, key: String, prompt: String, instructions: String, sections: List<String>, sourceLimit: Int): HttpRequest {
        validateApiKey(key)
        checkModel(modelID)
        if (sourceLimit !in 1..64 || sections.isEmpty()) throw AppFailure("Ungültiger Berichtsvertrag.")
        val item = buildJsonObject {
            put("type", "OBJECT")
            putJsonObject("properties") {
                putJsonObject("section") { put("type", "STRING"); put("format", "enum"); put("enum", JsonArray(sections.map(::JsonPrimitive))) }
                putJsonObject("text") { put("type", "STRING") }
                putJsonObject("segmentId") { put("type", "STRING"); put("format", "enum"); put("enum", JsonArray((1..sourceLimit).map { JsonPrimitive("q$it") })) }
                putJsonObject("quote") { put("type", "STRING") }
            }
            val fields = listOf("section", "text", "segmentId", "quote")
            putJsonArray("required") { fields.forEach { add(JsonPrimitive(it)) } }
            putJsonArray("propertyOrdering") { fields.forEach { add(JsonPrimitive(it)) } }
        }
        val body = buildJsonObject {
            putJsonObject("systemInstruction") { putJsonArray("parts") { add(text(instructions)) } }
            putJsonArray("contents") { add(buildJsonObject { put("role", "user"); putJsonArray("parts") { add(text(prompt)) } }) }
            putJsonObject("generationConfig") {
                put("maxOutputTokens", 32_768)
                put("responseMimeType", "application/json")
                putJsonObject("responseSchema") {
                    put("type", "OBJECT")
                    putJsonObject("properties") {
                        putJsonObject("items") { put("type", "ARRAY"); put("items", item) }
                        putJsonObject("skipped") {
                            put("type", "ARRAY")
                            putJsonObject("items") {
                                put("type", "OBJECT")
                                putJsonObject("properties") {
                                    putJsonObject("segmentId") { put("type", "STRING"); put("format", "enum"); put("enum", JsonArray((1..sourceLimit).map { JsonPrimitive("q$it") })) }
                                    putJsonObject("reason") { put("type", "STRING") }
                                }
                                putJsonArray("required") { add(JsonPrimitive("segmentId")); add(JsonPrimitive("reason")) }
                            }
                        }
                    }
                    putJsonArray("required") { add(JsonPrimitive("items")) }
                }
            }
        }
        return HttpRequest(BASE_URL + "models/$modelID:generateContent", "POST", headers(key), body.toString().encodeToByteArray())
    }

    fun checkStatus(status: Int) {
        when (status) {
            in 200..299 -> return
            401, 403 -> throw AppFailure("Gemini hat den API-Key abgewiesen. Bitte Key und freigeschaltete Gemini API prüfen.")
            429 -> throw AppFailure("Gemini-Kontingent erreicht. Bitte Abrechnung und Limits im Google-Konto prüfen und später bewusst erneut starten.")
            400, 404 -> throw AppFailure("Das ausgewählte Gemini-Modell oder das Berichtsformat wird nicht unterstützt. Bitte das Modell in Einstellungen testen.")
            else -> throw AppFailure("Gemini vorübergehend nicht verfügbar (HTTP $status). Kein automatischer Anbieterwechsel oder erneuter Versand.")
        }
    }

    data class Text(val text: String, val model: String)

    /** Final answer text of a non-streaming response; anything but a normal stop is refused. */
    fun reportResult(response: HttpResponse, requestedModel: String): Text {
        checkStatus(response.status)
        val root = runCatching { Json.parseToJsonElement(response.body.decodeToString()).jsonObject }.getOrNull()
            ?: throw AppFailure("Die Anbieterantwort konnte nicht gelesen werden. Das Transkript bleibt erhalten.")
        (root["promptFeedback"] as? JsonObject)?.string("blockReason")?.let { throw AppFailure("Gemini hat die Bearbeitung abgelehnt ($it). Es wurde kein Bericht übernommen.") }
        val candidate = (root["candidates"] as? JsonArray)?.firstOrNull() as? JsonObject
            ?: throw AppFailure("Gemini lieferte keinen Berichtstext.")
        when (val reason = candidate.string("finishReason")) {
            "STOP" -> Unit
            "MAX_TOKENS" -> throw AppFailure("Gemini hat die Antwort nicht vollständig abgeschlossen. Der Zwischenstand wird nicht als fertiger Bericht übernommen.")
            else -> throw AppFailure("Gemini hat die Bearbeitung abgelehnt oder abgebrochen (${reason ?: "ohne Grund"}). Es wurde kein Bericht übernommen.")
        }
        val text = answerText(candidate)
        if (text.isEmpty()) throw AppFailure("Gemini lieferte keinen Berichtstext.")
        return Text(text, root.string("modelVersion") ?: requestedModel)
    }

    /** Visible answer parts only; the model's own thoughts are never shown or stored. */
    internal fun answerText(candidate: JsonObject): String =
        (candidate["content"] as? JsonObject)?.get("parts")?.let { it as? JsonArray }.orEmpty()
            .mapNotNull { it as? JsonObject }
            .filter { (it["thought"] as? JsonPrimitive)?.contentOrNull != "true" }
            .mapNotNull { it.string("text") }
            .joinToString("")

    suspend fun models(key: String, transport: HttpTransport = EphemeralHttpTransport): List<String> {
        validateApiKey(key)
        val response = transport.send(HttpRequest(BASE_URL + "models?pageSize=1000", "GET", mapOf("x-goog-api-key" to key), null))
        checkStatus(response.status)
        val models = runCatching { Json.parseToJsonElement(response.body.decodeToString()).jsonObject["models"]?.jsonArray.orEmpty() }.getOrNull()
            ?: throw AppFailure("Die Modellliste von Gemini konnte nicht gelesen werden.")
        return models.mapNotNull { it as? JsonObject }
            .filter { model -> (model["supportedGenerationMethods"] as? JsonArray).orEmpty().any { (it as? JsonPrimitive)?.contentOrNull == "generateContent" } }
            .mapNotNull { it.string("name")?.removePrefix("models/") }
            .filter { it.startsWith("gemini") }
            .sorted()
    }

    // Chat --------------------------------------------------------------------------------------------

    /**
     * Translates the stored provider-neutral snapshot (OpenAI message shape, image placeholders) into a streaming
     * Gemini request. Images are checked against their recorded SHA-256 exactly as for OpenAI.
     */
    fun sparringRequest(snapshot: SparringSnapshot, key: String, imageData: Map<String, ByteArray> = emptyMap()): HttpRequest {
        validateApiKey(key)
        checkModel(snapshot.modelID)
        if (snapshot.payload.size > SparringRequestBuilder.MAXIMUM_PAYLOAD_BYTES) throw AppFailure("Die Anfrage ist zu groß.")
        // Source search is OpenAI-only (domain-limited). A request prepared with it is never silently sent without it.
        if (snapshot.sourceSearch == true) throw AppFailure("Diese Anfrage wurde mit Quellensuche vorbereitet, die es nur mit OpenAI gibt. Bitte erneut senden.")
        val root = runCatching { Json.parseToJsonElement(snapshot.payload.decodeToString()).jsonObject }.getOrNull()
            ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
        val input = root["input"] as? JsonArray ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
        val instructions = root.string("instructions") ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
        val references = snapshot.requestImages.orEmpty()
        val images = if (references.isEmpty()) emptyMap() else verifiedImages(references, imageData)
        var used = 0
        val contents = buildJsonArray {
            for (element in input) {
                val message = element as? JsonObject ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
                val role = when (message.string("role")) { "user" -> "user"; "assistant" -> "model"; else -> throw AppFailure("Die vorbereitete Anfrage ist ungültig.") }
                val parts = buildJsonArray {
                    when (val content: JsonElement? = message["content"]) {
                        is JsonPrimitive -> add(text(content.content))
                        is JsonArray -> for (part in content) {
                            val obj = part as? JsonObject ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
                            when (obj.string("type")) {
                                "input_text" -> add(text(obj.string("text") ?: throw AppFailure("Die vorbereitete Anfrage ist ungültig.")))
                                "input_image" -> {
                                    val data = images[obj.string("image_url")] ?: throw AppFailure("Ein Bildbezug ist ungültig.")
                                    used += 1
                                    add(buildJsonObject { putJsonObject("inlineData") { put("mimeType", "image/jpeg"); put("data", Base64.getEncoder().encodeToString(data)) } })
                                }
                                else -> throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
                            }
                        }
                        else -> throw AppFailure("Die vorbereitete Anfrage ist ungültig.")
                    }
                }
                add(buildJsonObject { put("role", role); put("parts", parts) })
            }
        }
        if (used != references.size) throw AppFailure("Die Bildauswahl stimmt nicht mit der Anfrage überein.")
        val body = buildJsonObject {
            putJsonObject("systemInstruction") { putJsonArray("parts") { add(text(instructions)) } }
            put("contents", contents)
            putJsonObject("generationConfig") { put("maxOutputTokens", 32_768) }
        }.toString().encodeToByteArray()
        if (body.size > 24 * 1_048_576) throw AppFailure("Die Bildanfrage ist zu groß.")
        return HttpRequest(BASE_URL + "models/${snapshot.modelID}:streamGenerateContent?alt=sse", "POST", headers(key, "text/event-stream"), body)
    }
}

/** Gemini SSE chunks carry text deltas; the chunk with a `finishReason` is the only terminal event. */
class GeminiAnalysisDecoder : AnalysisDecoder {
    var text = ""; private set
    override var terminal = false; private set

    override fun consume(data: ByteArray): AnalysisStreamUpdate? {
        if (terminal) throw AppFailure("Unerwartete Daten nach Ende der Antwort.")
        val event = runCatching { Json.parseToJsonElement(data.decodeToString()).jsonObject }.getOrNull()
            ?: throw AppFailure("Der Anbieter hat ein ungültiges Streaming-Ereignis geliefert.")
        if (event["error"] != null) throw AppFailure("Der Anbieter hat die Analyse abgebrochen. Der Zwischenstand bleibt unvollständig; kein automatischer Neuversand.")
        val model = event.string("modelVersion")
        val usage = (event["usageMetadata"] as? JsonObject)?.let { raw ->
            val input = (raw["promptTokenCount"] as? JsonPrimitive)?.intOrNull; val output = (raw["candidatesTokenCount"] as? JsonPrimitive)?.intOrNull
            if (input != null && output != null && input >= 0 && output >= 0) AnalysisUsage(input, output) else null
        }
        (event["promptFeedback"] as? JsonObject)?.string("blockReason")?.let {
            terminal = true
            return AnalysisStreamUpdate.Terminal(AnalysisStatus.REFUSED, text, model, usage, "Der Anbieter hat die Anfrage abgelehnt ($it).")
        }
        val candidate = (event["candidates"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return null
        val delta = GeminiOnlineApi.answerText(candidate)
        if (text.encodeToByteArray().size + delta.encodeToByteArray().size > SparringRequestBuilder.MAXIMUM_OUTPUT_BYTES) throw AppFailure("Die Antwort ist zu lang. Der Zwischenstand bleibt erhalten.")
        text += delta
        val reason = candidate.string("finishReason") ?: return if (delta.isEmpty()) null else AnalysisStreamUpdate.Text(text)
        terminal = true
        return when {
            reason == "STOP" && text.isNotEmpty() -> AnalysisStreamUpdate.Terminal(AnalysisStatus.COMPLETED, text, model, usage, null)
            reason in setOf("SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "LANGUAGE") ->
                AnalysisStreamUpdate.Terminal(AnalysisStatus.REFUSED, text, model, usage, "Der Anbieter hat die Anfrage abgelehnt ($reason). Eine etwaige Teilantwort ist nicht vollständig.")
            reason == "MAX_TOKENS" || reason == "STOP" -> AnalysisStreamUpdate.Terminal(AnalysisStatus.INCOMPLETE, text, model, usage,
                "Der Anbieter hat die Analyse nicht vollständig abgeschlossen. Ein neuer Versuch kann erneut Kosten verursachen.")
            else -> AnalysisStreamUpdate.Terminal(AnalysisStatus.FAILED, text, model, usage,
                "Der Anbieter hat die Analyse abgebrochen ($reason). Ein neuer Versuch kann erneut Kosten verursachen.")
        }
    }
}

/** Gemini report engine with the same request budget and provenance callbacks as [OpenAIReportEngine]. */
class GeminiReportEngine(
    private val configuration: OnlineReportConfiguration,
    private val key: String,
    private val sections: List<String>,
    private val transport: HttpTransport = EphemeralHttpTransport,
    private val record: suspend (payload: ByteArray, modelID: String) -> String = { _, _ -> newId() },
    private val finish: suspend (id: String, status: String, responseModel: String?) -> Unit = { _, _, _ -> },
) : ReportTextEngine {
    private var calls = 0
    private val actualModels = sortedSetOf<String>()
    override val engineID get() = "gemini/" + configuration.modelID
    override val engineRevision get() = if (actualModels.isEmpty()) configuration.modelID else actualModels.joinToString(", ")
    override val sourceLimit get() = 60
    override val characterLimit get() = 20_000
    override val executionLabel get() = "Gemini · online"

    override suspend fun generate(prompt: String, instructions: String): String {
        currentCoroutineContext().ensureActive()
        if (!configuration.isEnabled) throw AppFailure("Online-Berichte sind noch nicht aktiviert.")
        if (calls >= MAX_CALLS) throw AppFailure("Das Limit von $MAX_CALLS Anbieteranfragen für diesen Bericht ist erreicht. Gesicherte Abschnitte bleiben erhalten.")
        val request = GeminiOnlineApi.reportRequest(configuration.modelID, key, prompt, instructions, sections, sourceLimit)
        // The stored request record never contains the key: it is only in the header.
        val id = record(request.body ?: ByteArray(0), configuration.modelID)
        calls += 1
        try {
            currentCoroutineContext().ensureActive()
            val response = transport.send(request)
            currentCoroutineContext().ensureActive()
            val value = GeminiOnlineApi.reportResult(response, configuration.modelID)
            actualModels += value.model
            finish(id, "Antwort vollständig empfangen; fachliche Prüfung erforderlich", value.model)
            return value.text
        } catch (error: kotlinx.coroutines.CancellationException) {
            runCatching { kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { finish(id, "Abgebrochen; Verarbeitung beim Anbieter möglicherweise begonnen", null) } }
            throw error
        } catch (error: Exception) {
            runCatching { finish(id, "Fehlgeschlagen; kein automatischer Neuversand", null) }
            throw error
        }
    }
}

/** The engine for the configured provider; never a silent switch to another one. */
fun onlineReportEngine(
    configuration: OnlineReportConfiguration,
    key: String,
    sections: List<String>,
    transport: HttpTransport = EphemeralHttpTransport,
    record: suspend (payload: ByteArray, modelID: String) -> String = { _, _ -> newId() },
    finish: suspend (id: String, status: String, responseModel: String?) -> Unit = { _, _, _ -> },
): ReportTextEngine = when (configuration.provider) {
    OnlineProvider.GEMINI -> GeminiReportEngine(configuration, key, sections, transport, record, finish)
    OnlineProvider.OPENAI -> OpenAIReportEngine(configuration, key, sections, transport, record, finish)
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
