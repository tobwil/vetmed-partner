package de.tobwil.vetmed.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

/** Synthetic data only; no network. Mirrors the OpenAI contract tests for the Gemini provider. */
class GeminiOnlineTests {
    private val key = "synthetic-gemini-key-for-contract-tests"
    private val configuration = OnlineReportConfiguration("gemini-3.6-flash", Instant.now(), ReportExecutionMode.ONLINE, provider = OnlineProvider.GEMINI)

    private class StubTransport(private val response: HttpResponse) : HttpTransport {
        val requests = mutableListOf<HttpRequest>()
        override suspend fun send(request: HttpRequest): HttpResponse { requests += request; return response }
    }
    private class StubStream(private val events: List<String>) : StreamingTransport {
        val requests = mutableListOf<HttpRequest>()
        override suspend fun stream(request: HttpRequest, receive: suspend (ByteArray) -> Boolean) {
            requests += request
            for (event in events) if (receive(event.encodeToByteArray())) return
            throw AppFailure("Die Verbindung endete vor dem Abschluss.")
        }
    }
    private fun quoted(text: String) = Json.encodeToString(String.serializer(), text)
    private fun answer(text: String, reason: String = "STOP") = HttpResponse(200,
        """{"candidates":[{"content":{"role":"model","parts":[{"text":"intern","thought":true},{"text":${quoted(text)}}]},"finishReason":"$reason"}],"modelVersion":"gemini-3.6-flash-001"}""".encodeToByteArray())
    private fun chunk(text: String, reason: String? = null) =
        """{"candidates":[{"content":{"role":"model","parts":[{"text":${quoted(text)}}]}${reason?.let { ",\"finishReason\":\"$it\"" } ?: ""}}],"modelVersion":"gemini-3.6-flash-001"}"""

    @Test fun reportRequestUsesSchemaSystemInstructionAndKeepsKeyOutOfBody() {
        val request = GeminiOnlineApi.reportRequest("gemini-3.6-flash", key, "Kein Fieber.", "Nur Quellenfakten.", listOf("Befunde"), 4)
        assertEquals("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent", request.url)
        assertEquals(key, request.headers["x-goog-api-key"])
        val text = request.body!!.decodeToString()
        assertFalse(text.contains(key))
        val body = Json.parseToJsonElement(text).jsonObject
        assertEquals("Nur Quellenfakten.", body.getValue("systemInstruction").jsonObject.getValue("parts").jsonArray[0].jsonObject.getValue("text").jsonPrimitive.content)
        val config = body.getValue("generationConfig").jsonObject
        assertEquals("application/json", config.getValue("responseMimeType").jsonPrimitive.content)
        val item = config.getValue("responseSchema").jsonObject.getValue("properties").jsonObject.getValue("items").jsonObject.getValue("items").jsonObject
        assertEquals(listOf("Befunde"), item.getValue("properties").jsonObject.getValue("section").jsonObject.getValue("enum").jsonArray.map { it.jsonPrimitive.content })
    }

    @Test fun pipelineProducesGeminiReportWithProvenance() = runTest {
        val output = """{"items":[{"section":"Befunde","text":"Kein Fieber.","segmentId":"q1","quote":"Kein Fieber."}]}"""
        val engine = onlineReportEngine(configuration, key, ReportTemplate.TREATMENT_REPORT.sections, StubTransport(answer(output)))
        val report = ReportPipeline(engine).run(TranscriptBuilder.edited("Kein Fieber.", null), ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
        assertEquals("gemini/gemini-3.6-flash", report.modelID)
        assertEquals("gemini-3.6-flash-001", report.modelRevision)
        assertNull(report.approvedAt)
    }

    @Test fun truncatedOrBlockedReportsAreRefused() {
        for (response in listOf(answer("{}", "MAX_TOKENS"), answer("{}", "SAFETY"), HttpResponse(200, """{"promptFeedback":{"blockReason":"SAFETY"}}""".encodeToByteArray()), HttpResponse(403, ByteArray(0)))) {
            try { GeminiOnlineApi.reportResult(response, "m"); fail() } catch (_: AppFailure) {}
        }
    }

    @Test fun chatSnapshotIsTranslatedToGeminiRolesAndStreamCompletesOnlyOnFinishReason() = runTest {
        val snapshot = SparringRequestBuilder.prepare(null, Encounter(), SparringDraft(question = "Kein Fieber. Welche Angaben fehlen?"), "gemini-3.6-flash", instructions = "test")
        val transport = StubStream(listOf(chunk("Es fehlen "), chunk("Gewicht und Puls.", "STOP")))
        val updates = mutableListOf<AnalysisStreamUpdate>()
        SparringService(transport, OnlineProvider.GEMINI).run(snapshot, key, beforeSending = {}, receive = { updates += it })
        val request = transport.requests.single()
        assertEquals("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse", request.url)
        val body = Json.parseToJsonElement(request.body!!.decodeToString()).jsonObject
        assertEquals("user", body.getValue("contents").jsonArray.last().jsonObject.getValue("role").jsonPrimitive.content)
        assertFalse(request.body!!.decodeToString().contains(key))
        val terminal = updates.last() as AnalysisStreamUpdate.Terminal
        assertEquals(AnalysisStatus.COMPLETED, terminal.status)
        assertEquals("Es fehlen Gewicht und Puls.", terminal.text)
    }

    @Test fun chatStreamWithoutFinishReasonOrWithSafetyStopIsNotComplete() = runTest {
        val snapshot = SparringRequestBuilder.prepare(null, Encounter(), SparringDraft(question = "Frage"), "gemini-3.6-flash", instructions = "test")
        try { SparringService(StubStream(listOf(chunk("Teil"))), OnlineProvider.GEMINI).run(snapshot, key, beforeSending = {}, receive = {}); fail() } catch (_: AppFailure) {}
        val decoder = GeminiAnalysisDecoder()
        decoder.consume(chunk("Teil").encodeToByteArray())
        val terminal = decoder.consume(chunk("", "SAFETY").encodeToByteArray()) as AnalysisStreamUpdate.Terminal
        assertEquals(AnalysisStatus.REFUSED, terminal.status)
        assertTrue(decoder.terminal)
    }

    @Test fun modelListKeepsOnlyGeminiTextModels() = runTest {
        val body = """{"models":[{"name":"models/gemini-3.6-flash","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}]}"""
        assertEquals(listOf("gemini-3.6-flash"), GeminiOnlineApi.models(key, StubTransport(HttpResponse(200, body.encodeToByteArray()))))
    }
}
