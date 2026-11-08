package de.tobwil.vetmed.core

import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.util.Base64

/**
 * Online speech-to-text with the user's own Gemini key. It is the default once the key exists and the user agreed
 * once ([decidedAt]); before that the app asks instead of sending audio (see [Processing.transcription]).
 */
@Serializable
data class GeminiTranscriptionConfiguration(
    val enabled: Boolean = false,
    val modelID: String = DEFAULT_MODEL,
    /** When the user explicitly chose online or device transcription. Older stores have none and are asked once. */
    val decidedAt: AppleDate? = null,
    /** One-time consent for the voice mode (conversation audio and the chosen case context go to Gemini Live). */
    val voiceConsentAt: AppleDate? = null,
) {
    companion object { const val DEFAULT_MODEL = "gemini-3.6-flash" }
}

/**
 * Sends several recorded segments in one `generateContent` request and receives one transcript per segment as
 * strict JSON, so every text stays tied to its audio segment. Neighbouring segments in one request give the model
 * context across the 20-second cuts. Rate limits and server errors are retried; everything else fails visibly.
 */
class GeminiTranscriptionApi(
    private val transport: HttpTransport = EphemeralHttpTransport,
    private val retryDelays: List<Long> = listOf(2_000, 6_000, 18_000),
) {
    companion object {
        /** Six 20-second segments ≈ 2 minutes ≈ 5 MB request, well below the 20 MB inline limit. */
        const val BATCH_SIZE = 6
        private const val BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models/"

        fun prompt(count: Int, vocabulary: List<String>): String = buildString {
            append("Du erhältst $count aufeinanderfolgende Audioteile einer deutschsprachigen Diktat- oder Gesprächsaufnahme aus einer Tierarztpraxis. ")
            append("Transkribiere jeden Teil wortgetreu in normaler deutscher Rechtschreibung mit Satzzeichen. ")
            append("Ein Teil kann mitten im Wort beginnen oder enden; schreibe angeschnittene Wörter dem Teil zu, in dem sie überwiegend zu hören sind. ")
            append("Keine Zusammenfassung, keine Sprecherbezeichnungen, keine Zeitstempel, keine Kommentare. Erfinde nichts. ")
            append("Ist in einem Teil nichts Verständliches gesprochen, gib für ihn einen leeren String aus. ")
            append("Antworte nur mit JSON: {\"parts\": [...]} mit genau $count Strings in der Reihenfolge der Audioteile.")
            if (vocabulary.isNotEmpty()) append(" Fachbegriffe, die vorkommen können: ").append(vocabulary.joinToString(", ")).append('.')
        }

        fun request(key: String, modelID: String, wavs: List<ByteArray>, vocabulary: List<String>): HttpRequest {
            val body = buildJsonObject {
                putJsonArray("contents") {
                    add(buildJsonObject {
                        put("role", "user")
                        putJsonArray("parts") {
                            add(buildJsonObject { put("text", prompt(wavs.size, vocabulary)) })
                            wavs.forEachIndexed { index, wav ->
                                add(buildJsonObject { put("text", "Audioteil ${index + 1}:") })
                                add(buildJsonObject {
                                    putJsonObject("inlineData") { put("mimeType", "audio/wav"); put("data", Base64.getEncoder().encodeToString(wav)) }
                                })
                            }
                        }
                    })
                }
                putJsonObject("generationConfig") {
                    put("responseMimeType", "application/json")
                    putJsonObject("responseSchema") {
                        put("type", "OBJECT")
                        putJsonObject("properties") { putJsonObject("parts") { put("type", "ARRAY"); putJsonObject("items") { put("type", "STRING") } } }
                        put("required", buildJsonArray { add(kotlinx.serialization.json.JsonPrimitive("parts")) })
                    }
                    putJsonObject("thinkingConfig") { put("thinkingLevel", "low") }
                }
            }
            return HttpRequest(
                url = BASE_URL + modelID.trim() + ":generateContent",
                method = "POST",
                headers = mapOf("x-goog-api-key" to key, "Content-Type" to "application/json"),
                body = body.toString().encodeToByteArray(),
            )
        }

        /** Extracts the per-segment texts; refuses answers that do not match the number of segments sent. */
        fun parse(body: ByteArray, expected: Int): List<String> {
            val root = runCatching { Json.parseToJsonElement(body.decodeToString()).jsonObject }.getOrNull()
                ?: throw AppFailure("Gemini hat keine lesbare Antwort geliefert.")
            val candidate = (root["candidates"] as? JsonArray)?.firstOrNull()?.jsonObject
                ?: throw AppFailure("Gemini hat die Audioteile nicht transkribiert (keine Antwort, ggf. Sicherheitsfilter).")
            val text = (candidate["content"] as? JsonObject)?.get("parts")?.jsonArray.orEmpty()
                .map { it.jsonObject }
                .filter { (it["thought"]?.jsonPrimitive?.boolean) != true }
                .mapNotNull { it["text"]?.jsonPrimitive?.contentOrNull }
                .joinToString("")
            val parts = runCatching { Json.parseToJsonElement(text).jsonObject.getValue("parts").jsonArray.map { it.jsonPrimitive.content.trim() } }.getOrNull()
                ?: throw AppFailure("Gemini hat das Transkript nicht im erwarteten Format geliefert (${candidate["finishReason"]?.jsonPrimitive?.contentOrNull ?: "unbekannt"}).")
            if (parts.size != expected) throw AppFailure("Gemini hat ${parts.size} statt $expected Audioteile zurückgegeben. Bitte erneut transkribieren.")
            return parts
        }
    }

    suspend fun transcribe(key: String, modelID: String, wavs: List<ByteArray>, vocabulary: List<String> = emptyList()): List<String> {
        validateApiKey(key)
        if (modelID.isBlank()) throw AppFailure("Bitte eine Gemini-Modell-ID eingeben.")
        val request = request(key, modelID, wavs, vocabulary)
        var attempt = 0
        while (true) {
            val response = transport.send(request)
            if (response.status in 200..299) return parse(response.body, wavs.size)
            val retryable = response.status == 429 || response.status >= 500
            if (retryable && attempt < retryDelays.size) { delay(retryDelays[attempt]); attempt++; continue }
            throw AppFailure(when (response.status) {
                400 -> "Gemini hat die Anfrage abgelehnt (400). Bitte API-Key und Modell-ID prüfen."
                401, 403 -> "Gemini hat den API-Key abgelehnt (${response.status}). Bitte Key und freigeschaltete Gemini API prüfen."
                404 -> "Das Gemini-Modell „$modelID“ wurde nicht gefunden."
                429 -> "Gemini-Kontingent erschöpft (429). Bitte später erneut transkribieren; Fortschritt bleibt gespeichert."
                else -> "Gemini ist gerade nicht erreichbar (${response.status}). Bitte später erneut transkribieren; Fortschritt bleibt gespeichert."
            })
        }
    }
}
