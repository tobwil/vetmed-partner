package de.tobwil.vetmed.core

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

/** Guard rails against wrong medication statements in the sparring chat. */
class MedicationSafetyTests {
    private val key = "synthetic-streaming-key-for-contract-tests"
    private fun run(text: String, sources: List<AnswerSource>? = null) =
        AnalysisRun(snapshot = SparringRequestBuilder.prepare(null, Encounter(), SparringDraft(question = "Frage"), "m", instructions = "t"), text = text, sources = sources)

    @Test fun medicationContentIsDetectedAndOrdinaryAnswersAreNot() {
        val medication = listOf(
            "Das Präparat enthält Meloxicam.",
            "Wirkstoffe: Fipronil und S-Methopren.",
            "Übliche Dosierung 0,1 mg/kg einmal täglich.",
            "Gabe von 2 mg pro Tier",
            "Bitte die Fachinformation prüfen.",
            "Eine Kautablette alle drei Monate.",
            "Wartezeit essbare Gewebe: 28 Tage.",
            "5 µg/kg i.v.",
            "Wechselwirkungen mit NSAIDs beachten.",
            "Bravecto: Fluralaner",
            "Gut verträglich ist Meloxicam.",
            "Alternativ Carprofen oder Robenacoxib.",
        )
        medication.forEach { assertTrue(it, MedicationSafety.mentionsMedication(it)) }
        val ordinary = listOf(
            "Die Lahmheit hinten links spricht eher für ein orthopädisches Problem.",
            "Temperatur nicht gemessen; bitte nachholen.",
            "5 ml Blut in ein EDTA-Röhrchen.",
            "Kontrolle in 3 Tagen.",
        )
        ordinary.forEach { assertFalse(it, MedicationSafety.mentionsMedication(it)) }
    }

    @Test fun onlyHttpsLinksOnOfficialDomainsCountAsOfficial() {
        assertTrue(MedicationSafety.isOfficial("https://medicines.health.europa.eu/veterinary/de/600000047183"))
        assertTrue(MedicationSafety.isOfficial("https://www.ema.europa.eu/en/medicines/veterinary/EPAR/x"))
        assertTrue(MedicationSafety.isOfficial("https://portal.dimdi.pharmnet-bund.de/amguifree/"))
        assertTrue(MedicationSafety.isOfficial("https://aspregister.basg.gv.at/aspregister/faces/aspregister.jspx"))
        assertFalse("Kein https", MedicationSafety.isOfficial("http://ema.europa.eu/x"))
        assertFalse("Täuschung über Subdomain", MedicationSafety.isOfficial("https://ema.europa.eu.example.com/x"))
        assertFalse("Täuschung über Präfix", MedicationSafety.isOfficial("https://notema.europa.eu/x"))
        assertFalse(MedicationSafety.isOfficial("https://www.tierarzt-blog.de/meloxicam"))
        assertFalse(MedicationSafety.isOfficial("kein link"))
    }

    @Test fun aMedicationAnswerWithoutOfficialSourceIsWarnedAndExportedWithTheWarning() {
        val unsourced = run("Das Präparat enthält Wirkstoff A.")
        assertTrue(MedicationSafety.needsWarning(unsourced))
        assertTrue(ChatMarkdown.export(unsourced).contains(MedicationSafety.WARNING))
        val blogOnly = run("Das Präparat enthält Wirkstoff A.", listOf(AnswerSource("https://www.tierarzt-blog.de/a")))
        assertTrue("Nicht amtliche Quellen heben die Warnung nicht auf", MedicationSafety.needsWarning(blogOnly))
        val official = run("Das Präparat enthält Wirkstoff A.", listOf(AnswerSource("https://medicines.health.europa.eu/veterinary/de/1", "Fachinformation")))
        assertFalse(MedicationSafety.needsWarning(official))
        assertTrue(ChatMarkdown.export(official).contains("Amtliche Quellen:\n- Fachinformation: https://medicines.health.europa.eu/veterinary/de/1"))
        assertFalse(MedicationSafety.needsWarning(run("Die Lahmheit spricht eher für ein orthopädisches Problem.")))
    }

    @Test fun theRequestStatesTheSourceSituationAndOnlyAsksForDomainLimitedSearchWhenEnabled() {
        val off = Json.parseToJsonElement(SparringRequestBuilder.prepare(null, Encounter(), SparringDraft(question = "Frage"), "m", instructions = "Basis").payload.decodeToString()).jsonObject
        assertTrue(off["instructions"]!!.jsonPrimitive.content.startsWith("Basis\n\n# Quellenlage für diese Anfrage\nQuellensuche: nicht aktiviert."))
        assertNull(off["tools"]); assertNull(off["include"])

        val snapshot = SparringRequestBuilder.prepare(null, Encounter(), SparringDraft(question = "Frage"), "m", instructions = "Basis", sourceSearch = true)
        assertEquals(true, snapshot.sourceSearch)
        val on = Json.parseToJsonElement(snapshot.payload.decodeToString()).jsonObject
        assertTrue(on["instructions"]!!.jsonPrimitive.content.contains("Quellensuche: aktiviert, beschränkt auf amtliche Arzneimittelquellen"))
        val tool = on["tools"]!!.jsonArray.single().jsonObject
        assertEquals("web_search", tool["type"]!!.jsonPrimitive.content)
        assertEquals(MedicationSafety.OFFICIAL_DOMAINS, tool["filters"]!!.jsonObject["allowed_domains"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals("web_search_call.action.sources", on["include"]!!.jsonArray.single().jsonPrimitive.content)
        assertEquals(false, on["store"]!!.jsonPrimitive.content.toBoolean())
        // The request sent to OpenAI keeps the tool exactly as prepared.
        val sent = Json.parseToJsonElement(SparringRequestBuilder.request(snapshot, key).body!!.decodeToString()).jsonObject
        assertEquals(on["tools"], sent["tools"])
    }

    @Test fun geminiNeverSendsARequestPreparedForSourceSearchWithoutIt() {
        val snapshot = SparringRequestBuilder.prepare(null, Encounter(), SparringDraft(question = "Frage"), "gemini-3.6-flash", instructions = "t", sourceSearch = true)
        try { GeminiOnlineApi.sparringRequest(snapshot, key); fail("Gemini darf eine Quellensuche-Anfrage nicht ohne Suche senden") }
        catch (error: AppFailure) { assertTrue(error.message!!.contains("nur mit OpenAI")) }
    }

    @Test fun citedSourcesAreTakenFromTheFinalResponseAndUnsafeLinksDropped() {
        val decoder = OpenAIAnalysisDecoder()
        val text = "Laut Fachinformation enthält das Präparat Wirkstoff A."
        val annotations = """[
            {"type":"url_citation","url":"https://medicines.health.europa.eu/veterinary/de/1","title":"Präparat – Fachinformation","start_index":0,"end_index":10},
            {"type":"url_citation","url":"https://medicines.health.europa.eu/veterinary/de/1","title":"Doppelt","start_index":11,"end_index":12},
            {"type":"url_citation","url":"javascript:alert(1)","title":"Böse"},
            {"type":"file_citation","file_id":"x"}
        ]"""
        val event = """{"type":"response.completed","sequence_number":9,"response":{"status":"completed","model":"m","output":[
            {"type":"web_search_call","id":"ws1","status":"completed","action":{"type":"search","query":"Präparat Wirkstoff"}},
            {"type":"message","content":[{"type":"output_text","text":"$text","annotations":$annotations}]}]}}"""
        val terminal = decoder.consume(event.encodeToByteArray()) as AnalysisStreamUpdate.Terminal
        assertEquals(AnalysisStatus.COMPLETED, terminal.status)
        assertEquals(text, terminal.text)
        assertEquals(listOf(AnswerSource("https://medicines.health.europa.eu/veterinary/de/1", "Präparat – Fachinformation")), terminal.sources)
    }

    @Test fun storedAnswersWithoutSourcesStillDecode() {
        val legacy = """{"id":"A","createdAt":0,"snapshot":{"encounterID":"E","modelID":"m","draft":{},"payload":""},"status":"completed","text":"x"}"""
        val decoded = VetJson.decodeFromString(AnalysisRun.serializer(), legacy)
        assertNull(decoded.sources); assertNull(decoded.snapshot.sourceSearch)
    }

    @Test fun thePromptForbidsTradeNameToSubstanceMappingFromMemory() {
        val prompt = SparringRequestBuilder.instructions
        assertTrue(prompt.contains("# Arzneimittel, Präparate und Wirkstoffe"))
        assertTrue(prompt.contains("Aus deinem Gedächtnis darfst du einem Handelsnamen keinen Wirkstoff zuordnen"))
        assertFalse("Die Quellenlage steht nicht mehr fest im Prompt", prompt.contains("Webrecherche ist für diesen Auftrag nicht aktiviert"))
    }
}
