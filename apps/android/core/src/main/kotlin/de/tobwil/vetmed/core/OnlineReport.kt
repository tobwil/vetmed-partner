package de.tobwil.vetmed.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.UnknownHostException
import java.time.Instant

@Serializable
enum class ReportExecutionMode(val title: String) {
    @kotlinx.serialization.SerialName("online") ONLINE("Online"),
    @kotlinx.serialization.SerialName("offline") OFFLINE("Offline · optional"),
}

@Serializable
data class OnlineReportConfiguration(
    val modelID: String = "",
    val consentDate: AppleDate? = null,
    val preferredMode: ReportExecutionMode = ReportExecutionMode.OFFLINE,
    val verifiedModelID: String? = null,
    val verifiedAt: AppleDate? = null,
) {
    val isEnabled: Boolean get() = consentDate != null && modelID.isNotEmpty()
}

fun validateApiKey(key: String) {
    if (key.encodeToByteArray().size !in 20..1024 || !key.all { it.code in 33..126 }) {
        throw AppFailure("Bitte einen gültigen API-Key ohne Leerzeichen oder Zeilenumbrüche eingeben.")
    }
}

data class HttpRequest(val url: String, val method: String, val headers: Map<String, String>, val body: ByteArray?)
data class HttpResponse(val status: Int, val body: ByteArray)

fun interface HttpTransport { suspend fun send(request: HttpRequest): HttpResponse }

/** No cookies, no cache, no redirects, bounded response size. Mirrors the iOS ephemeral session. */
object EphemeralHttpTransport : HttpTransport {
    private const val MAX_BYTES = 4_194_304

    override suspend fun send(request: HttpRequest): HttpResponse = withContext(Dispatchers.IO) {
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = 30_000
            connection.readTimeout = 120_000
            connection.requestMethod = request.method
            request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            request.body?.let { body ->
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            if (status !in 200..299) return@withContext HttpResponse(status, ByteArray(0))
            val output = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(16_384)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (output.size() + read > MAX_BYTES) throw AppFailure("Die Anbieterantwort überschreitet das sichere Größenlimit.")
                    output.write(buffer, 0, read)
                }
            }
            HttpResponse(status, output.toByteArray())
        } catch (error: UnknownHostException) {
            throw AppFailure("Keine Internetverbindung. Das Transkript bleibt lokal. Es wird später nichts automatisch gesendet.")
        } catch (error: IOException) {
            throw AppFailure("Die Verbindung zum Anbieter wurde unterbrochen. Der Auftrag kann bereits berechnet worden sein. Ein erneuter Versuch startet einen neuen Auftrag.")
        } finally {
            connection.disconnect()
        }
    }
}

object OpenAIReportApi {
    const val RESPONSES_URL = "https://api.openai.com/v1/responses"
    const val MODELS_URL = "https://api.openai.com/v1/models"

    fun request(modelID: String, key: String, prompt: String, instructions: String, sections: List<String>, sourceLimit: Int): HttpRequest {
        validateApiKey(key)
        if (sourceLimit !in 1..64 || sections.isEmpty()) throw AppFailure("Ungültiger Berichtsvertrag.")
        if (modelID.isEmpty() || modelID.encodeToByteArray().size >= 256 || modelID.any { it.isWhitespace() }) {
            throw AppFailure("Bitte eine gültige Modell-ID auswählen.")
        }
        val item = buildJsonObject {
            put("type", "object")
            put("additionalProperties", false)
            putJsonObject("properties") {
                putJsonObject("section") { put("type", "string"); put("enum", JsonArray(sections.map(::JsonPrimitive))) }
                putJsonObject("text") { put("type", "string") }
                putJsonObject("segmentId") { put("type", "string"); put("enum", JsonArray((1..sourceLimit).map { JsonPrimitive("q$it") })) }
                putJsonObject("quote") { put("type", "string") }
            }
            putJsonArray("required") { listOf("section", "text", "segmentId", "quote").forEach { add(JsonPrimitive(it)) } }
        }
        val body = buildJsonObject {
            put("model", modelID)
            put("store", false)
            put("stream", false)
            put("background", false)
            put("max_output_tokens", 8192)
            put("instructions", instructions)
            put("input", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    put("content", buildJsonArray { add(buildJsonObject { put("type", "input_text"); put("text", prompt) }) })
                })
            })
            putJsonObject("text") {
                putJsonObject("format") {
                    put("type", "json_schema")
                    put("name", "veterinary_report_items_v1")
                    put("strict", true)
                    putJsonObject("schema") {
                        put("type", "object")
                        put("additionalProperties", false)
                        putJsonObject("properties") { putJsonObject("items") { put("type", "array"); put("items", item) } }
                        putJsonArray("required") { add(JsonPrimitive("items")) }
                    }
                }
            }
        }
        return HttpRequest(
            url = RESPONSES_URL, method = "POST",
            headers = mapOf("Authorization" to "Bearer $key", "Content-Type" to "application/json"),
            body = body.toString().encodeToByteArray(),
        )
    }

    fun checkStatus(status: Int) {
        when (status) {
            in 200..299 -> return
            401, 403 -> throw AppFailure("API-Key oder Berechtigung abgewiesen. Bitte die Anbietereinstellungen prüfen.")
            429 -> throw AppFailure("Anbieterlimit erreicht. Bitte Guthaben und Kontolimits prüfen und später bewusst erneut starten.")
            400, 404, 422 -> throw AppFailure("Das ausgewählte Modell oder das Berichtsformat wird vom Anbieter nicht unterstützt. Bitte das Modell in Einstellungen testen.")
            else -> throw AppFailure("Anbieter vorübergehend nicht verfügbar (HTTP $status). Kein automatischer Anbieterwechsel oder erneuter Versand.")
        }
    }

    @Serializable private data class Content(val type: String, val text: String? = null, val refusal: String? = null)
    @Serializable private data class OutputItem(val type: String, val content: List<Content>? = null)
    @Serializable private data class Result(val status: String, val model: String, val output: List<OutputItem>)
    @Serializable private data class ModelList(val data: List<Model>) { @Serializable data class Model(val id: String) }

    data class Text(val text: String, val model: String)

    fun result(response: HttpResponse): Text {
        checkStatus(response.status)
        val value = try {
            VetJson.decodeFromString(Result.serializer(), response.body.decodeToString())
        } catch (error: Exception) {
            throw AppFailure("Die Anbieterantwort konnte nicht gelesen werden. Das Transkript bleibt erhalten.")
        }
        if (value.status != "completed") {
            throw AppFailure("Der Anbieter hat die Antwort nicht vollständig abgeschlossen. Der Zwischenstand wird nicht als fertiger Bericht übernommen.")
        }
        val content = value.output.filter { it.type == "message" }.flatMap { it.content.orEmpty() }
        if (content.any { it.type == "refusal" }) throw AppFailure("Der Anbieter hat die Bearbeitung abgelehnt. Es wurde kein Bericht übernommen.")
        val text = content.filter { it.type == "output_text" }.mapNotNull { it.text }.joinToString("")
        if (text.isEmpty()) throw AppFailure("Der Anbieter lieferte keinen Berichtstext.")
        return Text(text, value.model)
    }

    suspend fun models(key: String, transport: HttpTransport = EphemeralHttpTransport): List<String> {
        validateApiKey(key)
        val response = transport.send(HttpRequest(MODELS_URL, "GET", mapOf("Authorization" to "Bearer $key"), null))
        checkStatus(response.status)
        return VetJson.decodeFromString(ModelList.serializer(), response.body.decodeToString()).data.map { it.id }.sorted()
    }
}

/** Online engine with request budget, consent gate and provenance callbacks, like iOS `OpenAIReportEngine`. */
class OpenAIReportEngine(
    private val configuration: OnlineReportConfiguration,
    private val key: String,
    private val sections: List<String>,
    private val transport: HttpTransport = EphemeralHttpTransport,
    private val record: suspend (payload: ByteArray, modelID: String) -> String = { _, _ -> newId() },
    private val finish: suspend (id: String, status: String, responseModel: String?) -> Unit = { _, _, _ -> },
) : ReportTextEngine {
    private var calls = 0
    private val actualModels = sortedSetOf<String>()
    override val engineID get() = "openai/" + configuration.modelID
    override val engineRevision get() = if (actualModels.isEmpty()) configuration.modelID else actualModels.joinToString(", ")
    override val sourceLimit get() = 24
    override val characterLimit get() = 12_000
    override val executionLabel get() = "OpenAI · online"

    override suspend fun generate(prompt: String, instructions: String): String {
        currentCoroutineContext().ensureActive()
        if (!configuration.isEnabled) throw AppFailure("Online-Berichte sind noch nicht aktiviert.")
        if (calls >= 12) throw AppFailure("Das Limit von zwölf Anbieteranfragen für diesen Bericht ist erreicht. Gesicherte Abschnitte bleiben erhalten.")
        val request = OpenAIReportApi.request(configuration.modelID, key, prompt, instructions, sections, sourceLimit)
        val id = record(request.body ?: ByteArray(0), configuration.modelID)
        calls += 1
        try {
            currentCoroutineContext().ensureActive()
            val response = transport.send(request)
            currentCoroutineContext().ensureActive()
            val value = OpenAIReportApi.result(response)
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

/** Synthetic single-sentence check used before online mode can be enabled. Sends no case data. */
object OnlineModelCheck {
    const val SYNTHETIC_TEXT = "Synthetischer Testfall. Hund 12,5 kg. Kein Fieber."
    fun verified(configuration: OnlineReportConfiguration, modelID: String, now: Instant = Instant.now()) =
        configuration.copy(verifiedModelID = modelID, verifiedAt = now)
}
