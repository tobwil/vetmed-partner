package de.tobwil.vetmed.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Synthetic audio and responses only; no network. */
class GeminiTranscriptionTests {
    private val key = "synthetic-gemini-key-for-contract-tests"
    private val wav = Wav.wrap(ByteArray(3200))

    private class StubTransport(private val responses: MutableList<HttpResponse>) : HttpTransport {
        val requests = mutableListOf<HttpRequest>()
        override suspend fun send(request: HttpRequest): HttpResponse { requests += request; return responses.removeAt(0) }
    }

    private fun answer(vararg parts: String): HttpResponse {
        val json = Json.encodeToString(String.serializer(), """{"parts":${parts.joinToString(",", "[", "]") { Json.encodeToString(String.serializer(), it) }}}""")
        return HttpResponse(200, """{"candidates":[{"content":{"parts":[{"text":"nachgedacht","thought":true},{"text":$json}]},"finishReason":"STOP"}]}""".encodeToByteArray())
    }

    @Test fun requestKeepsKeyInHeaderAndSendsEverySegmentAsInlineWav() {
        val request = GeminiTranscriptionApi.request(key, "gemini-3.6-flash", listOf(wav, wav), listOf("Meloxicam"))
        assertEquals("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent", request.url)
        assertEquals(key, request.headers["x-goog-api-key"])
        val text = request.body!!.decodeToString()
        assertFalse(text.contains(key))
        val parts = Json.parseToJsonElement(text).jsonObject.getValue("contents").jsonArray[0].jsonObject.getValue("parts").jsonArray
        val audio = parts.mapNotNull { it.jsonObject["inlineData"]?.jsonObject }
        assertEquals(2, audio.size)
        assertEquals("audio/wav", audio[0].getValue("mimeType").jsonPrimitive.content)
        assertTrue(parts[0].jsonObject.getValue("text").jsonPrimitive.content.contains("Meloxicam"))
    }

    @Test fun parsesOneTextPerSegmentAndSkipsThoughts() = runTest {
        val transport = StubTransport(mutableListOf(answer("Der Hund frisst schlecht.", "")))
        assertEquals(listOf("Der Hund frisst schlecht.", ""), GeminiTranscriptionApi(transport).transcribe(key, "gemini-3.6-flash", listOf(wav, wav)))
    }

    @Test fun retriesRateLimitsAndServerErrors() = runTest {
        val transport = StubTransport(mutableListOf(HttpResponse(429, ByteArray(0)), HttpResponse(503, ByteArray(0)), answer("Text")))
        assertEquals(listOf("Text"), GeminiTranscriptionApi(transport, retryDelays = listOf(1, 1, 1)).transcribe(key, "m", listOf(wav)))
        assertEquals(3, transport.requests.size)
    }

    @Test fun rejectsWrongSegmentCountAndInvalidKeyWithoutRetry() = runTest {
        try { GeminiTranscriptionApi(StubTransport(mutableListOf(answer("nur einer")))).transcribe(key, "m", listOf(wav, wav)); fail() }
        catch (error: AppFailure) { assertTrue(error.message!!.contains("1 statt 2")) }
        val transport = StubTransport(mutableListOf(HttpResponse(403, ByteArray(0))))
        try { GeminiTranscriptionApi(transport, retryDelays = listOf(1)).transcribe(key, "m", listOf(wav)); fail() }
        catch (error: AppFailure) { assertTrue(error.message!!.contains("API-Key")) }
        assertEquals(1, transport.requests.size)
    }
}
