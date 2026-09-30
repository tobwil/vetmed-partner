package de.tobwil.vetmed.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

/** Kotlin port of `apps/ios/VetMedTests/OnlineReportTests.swift`. Synthetic data only; no network. */
class OnlineReportTests {
    private val key = "synthetic-api-key-for-contract-tests"
    private val configuration = OnlineReportConfiguration("synthetic-model", Instant.now(), ReportExecutionMode.ONLINE)

    private class StubTransport(private val response: HttpResponse) : HttpTransport {
        val requests = mutableListOf<HttpRequest>()
        override suspend fun send(request: HttpRequest): HttpResponse { requests += request; return response }
    }
    private fun completed(text: String = "{}") = HttpResponse(200,
        """{"status":"completed","model":"synthetic-snapshot-1","output":[{"type":"message","content":[{"type":"output_text","text":${Json.encodeToString(String.serializer(), text)}}]}]}""".encodeToByteArray())

    @Test fun requestIsStatelessStrictAndContainsNoAuthenticationInBody() {
        val request = OpenAIReportApi.request("synthetic-model", key, "Kein Fieber.", "Only source facts.", listOf("Befunde"), 4)
        assertEquals("https://api.openai.com/v1/responses", request.url)
        assertEquals("Bearer $key", request.headers["Authorization"])
        val text = request.body!!.decodeToString()
        assertFalse(text.contains(key))
        val body = Json.parseToJsonElement(text).jsonObject
        assertFalse(body.getValue("store").jsonPrimitive.boolean)
        assertFalse(body.getValue("background").jsonPrimitive.boolean)
        assertNull(body["tools"]); assertNull(body["previous_response_id"]); assertNull(body["conversation"])
        val format = body.getValue("text").jsonObject.getValue("format").jsonObject
        assertTrue(format.getValue("strict").jsonPrimitive.boolean)
        assertEquals("json_schema", format.getValue("type").jsonPrimitive.content)
    }

    @Test fun incompleteAndRefusedResponsesNeverBecomeReports() {
        for (body in listOf(
            """{"status":"incomplete","model":"test","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}""",
            """{"status":"completed","model":"test","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}""",
        )) {
            try { OpenAIReportApi.result(HttpResponse(200, body.encodeToByteArray())); fail("Must not become a report") } catch (_: AppFailure) {}
        }
    }

    @Test fun providerFailureMakesOneRequestAndDoesNotRetry() = runTest {
        val transport = StubTransport(HttpResponse(429, ByteArray(0)))
        var recorded: ByteArray? = null
        var completion: String? = null
        val engine = OpenAIReportEngine(configuration, key, listOf("Befunde"), transport,
            record = { payload, _ -> recorded = payload; newId() }, finish = { _, status, _ -> completion = status })
        try { engine.generate("Synthetic", "Test"); fail("429 must fail") } catch (error: AppFailure) { assertTrue(error.message!!.contains("Anbieterlimit")) }
        assertEquals(1, transport.requests.size)
        assertTrue(recorded != null)
        assertTrue(completion!!.contains("kein automatischer Neuversand"))
    }

    @Test fun consentIsRequiredBeforeAnyNetworkCall() = runTest {
        val transport = StubTransport(completed())
        val engine = OpenAIReportEngine(OnlineReportConfiguration("synthetic-model", preferredMode = ReportExecutionMode.ONLINE), key, listOf("Befunde"), transport)
        try { engine.generate("Synthetic", "Test"); fail("No consent") } catch (_: AppFailure) {}
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun requestBudgetAndActualModelProvenance() = runTest {
        val transport = StubTransport(completed())
        val engine = OpenAIReportEngine(configuration, key, listOf("Befunde"), transport)
        repeat(12) { engine.generate("Synthetic", "Test") }
        try { engine.generate("Synthetic", "Test"); fail("Budget exceeded") } catch (error: AppFailure) { assertTrue(error.message!!.contains("zwölf")) }
        assertEquals(12, transport.requests.size)
        assertEquals("synthetic-snapshot-1", engine.engineRevision)
    }

    @Test fun pipelineRetainsCloudProvenanceAndPerformsLocalValidation() = runTest {
        val output = """{"items":[{"section":"Befunde","text":"Kein Fieber.","segmentId":"q1","quote":"Kein Fieber."}]}"""
        val engine = OpenAIReportEngine(configuration, key, ReportTemplate.TREATMENT_REPORT.sections, StubTransport(completed(output)))
        val transcript = TranscriptBuilder.edited("Kein Fieber.", null)
        val report = ReportPipeline(engine).run(transcript, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
        assertEquals("openai/synthetic-model", report.modelID); assertEquals("synthetic-snapshot-1", report.modelRevision)
        assertEquals(transcript.id, report.content.sourceTranscriptVersionId)
        assertNull(report.approvedAt)
    }

    @Test fun invalidKeysAreRejectedBeforeAnyRequest() {
        for (value in listOf("short", "has space in the middle of key", "line\nbreak-synthetic-api-key")) {
            try { validateApiKey(value); fail(value) } catch (_: AppFailure) {}
        }
        validateApiKey(key)
    }

    @Test fun modelListIsSortedAndUsesBearerHeader() = runTest {
        val transport = StubTransport(HttpResponse(200, """{"data":[{"id":"b-model"},{"id":"a-model"}]}""".encodeToByteArray()))
        assertEquals(listOf("a-model", "b-model"), OpenAIReportApi.models(key, transport))
        assertEquals("GET", transport.requests.single().method)
        assertEquals("Bearer $key", transport.requests.single().headers["Authorization"])
    }
}
