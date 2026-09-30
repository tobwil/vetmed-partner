package de.tobwil.vetmed.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

/** Kotlin port of `SparringTests.swift` and the Markdown cases of `NavigationAndSharingTests.swift`. */
class SparringTests {
    private val key = "synthetic-streaming-key-for-contract-tests"
    private fun snapshot(caseID: String? = null, encounter: Encounter = Encounter(), question: String = "Kein Fieber. Welche Angaben fehlen?") =
        SparringRequestBuilder.prepare(caseID, encounter, SparringDraft(question = question), "synthetic-model", instructions = "test")
    private fun delta(text: String, sequence: Int = 1) =
        """{"type":"response.output_text.delta","delta":${Json.encodeToString(String.serializer(), text)},"sequence_number":$sequence,"item_id":"msg1","content_index":0}""".encodeToByteArray()
    private fun final(text: String, status: String = "completed", refusal: Boolean = false): ByteArray {
        val content = if (refusal) """{"type":"refusal","refusal":"refused"}""" else """{"type":"output_text","text":"$text"}"""
        return """{"type":"response.$status","sequence_number":99,"response":{"status":"$status","model":"synthetic-model-snapshot","usage":{"input_tokens":50,"output_tokens":20},"output":[{"type":"message","content":[$content]}]}}""".encodeToByteArray()
    }
    private fun report(text: String, date: Instant = now(), approved: Boolean = false, parent: String? = null) = ReportVersion(
        createdAt = date, parentID = parent,
        content = StructuredReport(template = ReportTemplate.TREATMENT_REPORT, length = ReportLength.SHORT, audience = Audience.VETERINARIAN,
            sourceTranscriptVersionId = newId(), sections = emptyList(), missingInformation = emptyList(), conflicts = emptyList()),
        editedText = text, modelID = "test", modelRevision = "test", warnings = listOf("Zahlen prüfen"), approvedAt = if (approved) date else null,
    )
    private inline fun assertFails(block: () -> Unit) { try { block(); fail("Expected failure") } catch (_: AppFailure) {} }
    private fun prepare(caseID: String?, encounter: Encounter, draft: SparringDraft, context: VetCase?) =
        SparringRequestBuilder.prepare(caseID, encounter, draft, "test", context, instructions = "test")

    private class StubStream(private val events: List<ByteArray>, private val disconnect: Boolean = false) : StreamingTransport {
        val requests = mutableListOf<HttpRequest>()
        override suspend fun stream(request: HttpRequest, receive: suspend (ByteArray) -> Boolean) {
            requests += request
            for (event in events) if (receive(event)) return
            if (disconnect) throw AppFailure("Die Verbindung wurde unterbrochen.")
        }
    }

    @Test fun caseReportsIncludeSelectedEditedVersionsAndFreezeContent() {
        val first = report("Kein Fieber. 12,5 kg.", approved = true)
        val second = report("Kontrolle: Temperatur nicht gemessen.")
        val ignored = report("NICHT AUSGEWÄHLT")
        val encounter = Encounter(reports = listOf(first, ignored))
        val item = VetCase(label = "Nur lokal", species = "Hund", encounters = listOf(encounter, Encounter(reports = listOf(second))))
        val snapshot = prepare(item.id, encounter, SparringDraft(question = "Wie weiter?", reportIDs = listOf(first.id, second.id)), item)
        val request = SparringRequestBuilder.request(snapshot, key)
        assertArrayEquals(snapshot.payload, request.body)
        val messages = Json.parseToJsonElement(request.body!!.decodeToString()).jsonObject.getValue("input") as JsonArray
        val text = messages.last().jsonObject.getValue("content").jsonPrimitive.content
        assertTrue(text.contains("Kein Fieber. 12,5 kg.")); assertTrue(text.contains(second.text))
        assertTrue(text.contains("Fachlich geprüft")); assertTrue(text.contains("Entwurf · fachlich ungeprüft"))
        assertTrue(text.contains("Zahlen prüfen")); assertFalse(text.contains(ignored.text)); assertFalse(text.contains(item.label))
        assertEquals(first.text, snapshot.reports?.first()?.text)
        assertEquals(snapshot, VetJson.decodeFromString(SparringSnapshot.serializer(), VetJson.encodeToString(SparringSnapshot.serializer(), snapshot)))
    }

    @Test fun reportSelectionRejectsForeignMissingDuplicateAndStandaloneReferences() {
        val own = report("Eigener Bericht"); val foreign = report("Fremder Bericht")
        val encounter = Encounter(reports = listOf(own))
        val item = VetCase(label = "A", species = "Hund", encounters = listOf(encounter))
        val other = VetCase(label = "B", species = "Katze", encounters = listOf(Encounter(reports = listOf(foreign))))
        fun draft(ids: List<String>) = SparringDraft(question = "Frage", reportIDs = ids)
        assertFails { prepare(item.id, encounter, draft(listOf(foreign.id)), item) }
        assertFails { prepare(item.id, encounter, draft(listOf(foreign.id)), other) }
        assertFails { prepare(null, encounter, draft(listOf(own.id)), item) }
        assertFails { prepare(item.id, encounter, draft(listOf(own.id, own.id)), item) }
        assertFails { prepare(item.id, encounter, draft(listOf(own.id)), null) }
        assertFails { prepare(item.id, Encounter(), draft(listOf(own.id)), item) }
    }

    @Test fun deselectedReportIsNotReintroducedFromHistory() {
        val source = report("EINMALIGER QUELLTEXT")
        var encounter = Encounter(reports = listOf(source))
        var item = VetCase(label = "A", species = "Hund", encounters = listOf(encounter))
        val first = prepare(item.id, encounter, SparringDraft(question = "Erste Frage", reportIDs = listOf(source.id)), item)
        val run = AnalysisRun(snapshot = first, status = AnalysisStatus.COMPLETED, text = "Frühere Antwort")
        encounter = encounter.copy(analysisRuns = listOf(run)); item = item.copy(encounters = listOf(encounter))
        val next = prepare(item.id, encounter, SparringDraft(question = "Rückfrage", historyIDs = listOf(run.id), reportIDs = emptyList()), item)
        val text = next.payload.decodeToString()
        assertFalse(text.contains(source.text)); assertTrue(text.contains(run.text)); assertTrue(text.contains("Erste Frage"))
        assertTrue(first.userText.contains(source.text)); assertTrue(next.reports!!.isEmpty())
        val stillSelected = prepare(item.id, encounter, SparringDraft(question = "Rückfrage", historyIDs = listOf(run.id), reportIDs = listOf(source.id)), item)
        assertEquals(2, stillSelected.payload.decodeToString().split(source.text).size)
    }

    @Test fun latestReportDefaultPrefersCurrentEncounterAndMarksSupersededVersions() {
        val old = report("Alt", Instant.ofEpochSecond(1))
        val revised = report("Korrigiert", Instant.ofEpochSecond(2), parent = old.id)
        val later = report("Anderer Vorgang", Instant.ofEpochSecond(3))
        val encounter = Encounter(reports = listOf(old, revised)); val empty = Encounter()
        val item = VetCase(label = "A", species = "Hund", encounters = listOf(encounter, Encounter(reports = listOf(later)), empty))
        assertEquals(listOf(revised.id), ChatReportSelection.defaultIDs(item, encounter.id))
        assertEquals(listOf(later.id), ChatReportSelection.defaultIDs(item, empty.id))
        assertEquals(listOf(old.id), ChatReportSelection.available(item).filter { it.isOlderVersion }.map { it.id })
        assertNull(VetJson.decodeFromString(SparringDraft.serializer(), """{"question":"Alt","context":"","mode":"question","historyIDs":[]}""").reportIDs)
        assertEquals(emptyList<String>(), VetJson.decodeFromString(SparringDraft.serializer(), VetJson.encodeToString(SparringDraft.serializer(), SparringDraft(reportIDs = emptyList()))).reportIDs)
    }

    @Test fun oversizedReportContextFailsWithoutTruncation() {
        val source = report("x".repeat(SparringRequestBuilder.MAXIMUM_PAYLOAD_BYTES))
        val encounter = Encounter(reports = listOf(source))
        val item = VetCase(label = "A", species = "Hund", encounters = listOf(encounter))
        assertFails { prepare(item.id, encounter, SparringDraft(question = "Frage", reportIDs = listOf(source.id)), item) }
    }

    @Test fun payloadIsStatelessWithoutCredentialsOrCaseFields() {
        val caseID = newId(); val encounter = Encounter()
        val prepared = snapshot(caseID, encounter)
        val request = SparringRequestBuilder.request(prepared, key)
        assertArrayEquals(prepared.payload, request.body)
        val body = Json.parseToJsonElement(prepared.payload.decodeToString()).jsonObject
        assertTrue(body.getValue("stream").jsonPrimitive.boolean); assertFalse(body.getValue("store").jsonPrimitive.boolean)
        assertNull(body["previous_response_id"]); assertNull(body["tools"]); assertNull(body["conversation"])
        val text = prepared.payload.decodeToString()
        assertFalse(text.contains(key)); assertFalse(text.contains(caseID)); assertFalse(text.contains(encounter.id))
        assertEquals("Bearer $key", request.headers["Authorization"])
        assertEquals("text/event-stream", request.headers["Accept"])
    }

    @Test fun onlyExplicitCompleteHistoryFromSameScopeCanBeSent() {
        val caseID = newId(); var encounter = Encounter()
        var own = AnalysisRun(snapshot = snapshot(caseID, encounter, "Eigenes Material"), status = AnalysisStatus.COMPLETED, text = "Eigene Hypothese")
        val foreign = AnalysisRun(snapshot = snapshot(newId(), question = "FREMDES MATERIAL"), status = AnalysisStatus.COMPLETED, text = "FREMDER INHALT")
        encounter = encounter.copy(analysisRuns = listOf(own, foreign))
        assertFalse(snapshot(caseID, encounter).payload.decodeToString().contains("Eigene Hypothese"))
        val selected = prepare(caseID, encounter, SparringDraft(question = "Rückfrage", historyIDs = listOf(own.id)), null).payload.decodeToString()
        assertTrue(selected.contains("Eigene Hypothese")); assertFalse(selected.contains("FREMDER INHALT"))
        assertFails { prepare(caseID, encounter, SparringDraft(question = "Rückfrage", historyIDs = listOf(foreign.id)), null) }
        own = own.copy(status = AnalysisStatus.INCOMPLETE); encounter = encounter.copy(analysisRuns = listOf(own))
        assertFails { prepare(caseID, encounter, SparringDraft(question = "Rückfrage", historyIDs = listOf(own.id)), null) }
    }

    @Test fun imagesAreReplacedOnlyWithVerifiedBytes() {
        val jpeg = ByteArray(1200) { it.toByte() }
        val attachment = ChatAttachment(
            id = newId(), kind = AttachmentKind.IMAGE, originalName = "IMG_0001.HEIC", originalExtension = "heic", originalByteCount = 5000,
            originalSHA256 = "orig", uploadSHA256 = AttachmentLimits.sha256(jpeg), uploadByteCount = jpeg.size, width = 800, height = 600,
        )
        val encounter = Encounter(chatAttachments = listOf(attachment))
        val prepared = prepare(null, encounter, SparringDraft(question = "Was sieht man?", attachmentIDs = listOf(attachment.id)), null)
        assertFalse("filename must not be sent", prepared.payload.decodeToString().contains("IMG_0001"))
        val body = SparringRequestBuilder.request(prepared, key, mapOf(attachment.id to jpeg)).body!!.decodeToString()
        assertTrue(body.contains("data:image/jpeg;base64,")); assertFalse(body.contains("vetmed-image:"))
        assertFails { SparringRequestBuilder.request(prepared, key, mapOf(attachment.id to jpeg.copyOf(jpeg.size - 1))) }
        assertFails { SparringRequestBuilder.request(prepared, key, emptyMap()) }
        val unreviewed = ChatAttachment(id = newId(), kind = AttachmentKind.DOCUMENT, originalName = "Labor.pdf", originalExtension = "pdf",
            originalByteCount = 10, originalSHA256 = "x", extractedText = "Kein Befund")
        assertFails { prepare(null, Encounter(chatAttachments = listOf(unreviewed)), SparringDraft(question = "?", attachmentIDs = listOf(unreviewed.id)), null) }
        val reviewed = unreviewed.copy(reviewedText = "Kein Befund. 5 mmol/l", reviewedAt = now())
        val withDocument = prepare(null, Encounter(chatAttachments = listOf(reviewed)), SparringDraft(question = "?", attachmentIDs = listOf(reviewed.id)), null)
        assertTrue(withDocument.payload.decodeToString().contains("Kein Befund. 5 mmol/l"))
    }

    @Test fun sseHandlesUtf8CrlfCommentsAndMultilineData() {
        val decoder = BoundedSseDecoder(); val events = mutableListOf<ByteArray>()
        val bytes = ": ping\r\n\r\nevent: ignored\r\n".encodeToByteArray() + "data: {\"type\":\"example\",\r\ndata: \"text\":\"Größe 🐕\"}\r\n\r\n".encodeToByteArray()
        for (byte in bytes) decoder.feed(byte)?.let { events += it }
        assertEquals(1, events.size)
        assertEquals("Größe 🐕", Json.parseToJsonElement(events[0].decodeToString()).jsonObject.getValue("text").jsonPrimitive.content)
    }

    @Test fun sseRejectsOversizedUnterminatedLine() {
        val decoder = BoundedSseDecoder()
        repeat(524_288) { decoder.feed(65) }
        assertFails { decoder.feed(65) }
    }

    @Test fun onlyMatchingTerminalEventCompletesAnswer() {
        val decoder = OpenAIAnalysisDecoder()
        decoder.consume(delta("Kein ")); decoder.consume(delta("Fieber.", 2))
        assertFalse(decoder.terminal)
        val terminal = decoder.consume(final("Kein Fieber.")) as AnalysisStreamUpdate.Terminal
        assertEquals(AnalysisStatus.COMPLETED, terminal.status); assertEquals("Kein Fieber.", terminal.text)
        assertEquals("synthetic-model-snapshot", terminal.model); assertEquals(AnalysisUsage(50, 20), terminal.usage)
        val mismatch = OpenAIAnalysisDecoder(); mismatch.consume(delta("Kein Fieber."))
        assertFails { mismatch.consume(final("Fieber.")) }
    }

    @Test fun refusalAndTokenLimitRemainNonComplete() {
        for ((status, refused, expected) in listOf(Triple("incomplete", false, AnalysisStatus.INCOMPLETE), Triple("completed", true, AnalysisStatus.REFUSED))) {
            val decoder = OpenAIAnalysisDecoder(); decoder.consume(delta("Teilantwort"))
            assertEquals(expected, (decoder.consume(final("Teilantwort", status, refused)) as AnalysisStreamUpdate.Terminal).status)
        }
    }

    @Test fun duplicateStreamEventIsRejectedAndProviderBodyNotShown() {
        val decoder = OpenAIAnalysisDecoder(); val event = delta("Text")
        decoder.consume(event)
        assertFails { decoder.consume(event) }
        try { decoder.consume("""{"type":"error","message":"PRIVATE PROVIDER BODY"}""".encodeToByteArray()); fail() }
        catch (error: AppFailure) { assertFalse(error.message!!.contains("PRIVATE PROVIDER BODY")) }
    }

    @Test fun failedPersistencePreventsAnyNetworkRequest() = runTest {
        val transport = StubStream(listOf(final("Test")))
        try {
            SparringService(transport).run(snapshot(), key, beforeSending = { throw AppFailure("synthetic storage error") }, receive = { fail("Unexpected output") })
            fail("Sent without persistence")
        } catch (_: AppFailure) {}
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun disconnectKeepsPartialTextAndDoesNotRetryOrComplete() = runTest {
        val transport = StubStream(listOf(delta("Gesicherter Teil")), disconnect = true)
        var text = ""; var completed = false; var recorded = false
        try {
            SparringService(transport).run(snapshot(), key, beforeSending = { recorded = true }) { update ->
                assertTrue(recorded)
                if (update is AnalysisStreamUpdate.Text) text = update.text
                if (update is AnalysisStreamUpdate.Terminal) completed = true
            }
            fail("Disconnect accepted")
        } catch (_: AppFailure) {}
        assertEquals("Gesicherter Teil", text); assertFalse(completed); assertEquals(1, transport.requests.size)
    }

    @Test fun cancellationAfterPersistBeforeSendDoesNotSendAnything() = runTest {
        val transport = StubStream(listOf(final("Test")))
        try {
            SparringService(transport).run(snapshot(), key, beforeSending = { throw CancellationException("cancelled") }, receive = { fail() })
            fail("No cancellation")
        } catch (_: CancellationException) {}
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun recoveryMarksActiveRunsIncompleteAndPreservesDraftAndFinishedAnswer() {
        var encounter = Encounter(sparringDraft = SparringDraft(question = "Ungesendet"))
        val value = snapshot(encounter = encounter)
        encounter = encounter.copy(analysisRuns = listOf(
            AnalysisRun(snapshot = value, status = AnalysisStatus.STREAMING, text = "Teil"),
            AnalysisRun(snapshot = value, status = AnalysisStatus.COMPLETED, text = "Fertig"),
        )).recoverInterruptedAnalysis()
        assertEquals(listOf(AnalysisStatus.INCOMPLETE, AnalysisStatus.COMPLETED), encounter.analysisRuns!!.map { it.status })
        assertEquals(listOf("Teil", "Fertig"), encounter.analysisRuns!!.map { it.text })
        assertEquals("Ungesendet", encounter.sparringDraft?.question)
    }

    @Test fun quickCheckUsesChatPathWithoutCase() {
        val check = QuickCheck()
        assertEquals("Neuer Schnellcheck", check.title)
        val snapshot = SparringRequestBuilder.prepare(null, check.analysisContext, SparringDraft(question = "Allgemeine Frage"), "m", instructions = "test")
        assertNull(snapshot.caseID); assertEquals(check.id, snapshot.encounterID)
    }

    // Markdown ---------------------------------------------------------------------------------------

    private val markdown = "## Synthetischer Test\n\n**Fett dargestellt** und *kursiv*.\n\n- Hund 12,5 kg\n- Kein Fieber\n\nENDE-DER-TESTANTWORT"

    @Test fun boldItalicHeadingsListsAndCodeHaveNativeRepresentation() {
        val blocks = ChatMarkdown.blocks("$markdown\n\n```\n**wörtlich**\n```")
        assertEquals(2, (blocks[0] as MarkdownBlock.Heading).level)
        val paragraph = (blocks[1] as MarkdownBlock.Paragraph).spans
        assertTrue(paragraph.any { it.bold && it.text == "Fett dargestellt" }); assertTrue(paragraph.any { it.italic && it.text == "kursiv" })
        val item = blocks[2] as MarkdownBlock.ListItem
        assertEquals("•", item.marker); assertEquals(0, item.indent); assertEquals("Hund 12,5 kg", item.spans.joinToString("") { it.text })
        assertEquals("**wörtlich**", (blocks.last() as MarkdownBlock.Code).text)
    }

    @Test fun plainTextPreservesNumbersNegationsUrlsAndLiteralAsterisks() {
        val value = ChatMarkdown.plainText("**Kein** Fieber. 12,5 kg.\n\n[Quelle](https://example.org/paper)\n\n\\*wörtlich\\*\n\n1. Wert < 7,0 mmol/l")
        assertTrue(value.contains("Kein Fieber. 12,5 kg.")); assertFalse(value.contains("**Kein**"))
        assertTrue(value.contains("Quelle (https://example.org/paper)"))
        assertTrue(value.contains("*wörtlich*")); assertTrue(value.contains("1. Wert < 7,0 mmol/l"))
        assertTrue(ChatMarkdown.inline("[Nicht öffnen](file:///private/test)").none { it.link != null })
        assertEquals("Tier_name_mit_Unterstrich", ChatMarkdown.inline("Tier_name_mit_Unterstrich").joinToString("") { it.text })
    }

    @Test fun partialAnswerKeepsWarningWhenCopiedWithoutMarkdown() {
        val run = AnalysisRun(snapshot = snapshot(), status = AnalysisStatus.CANCELLED, text = markdown)
        val text = ChatMarkdown.export(run)
        assertTrue(text.contains("UNVOLLSTÄNDIGE")); assertTrue(text.contains("fachlich ungeprüft"))
        assertFalse(text.contains("**Fett")); assertTrue(text.endsWith("ENDE-DER-TESTANTWORT"))
    }
}
