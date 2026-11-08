package de.tobwil.vetmed.core

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Reports from conversations (ADR 0018): small talk may be left out, visibly; numbers and negations never. */
class ConversationReportTests {
    private fun encode(draft: ModelReportDraft) = VetJson.encodeToString(ModelReportDraft.serializer(), draft)

    /** A synthetic consultation conversation: greetings and filler around the clinical content. */
    private val conversation = TranscriptBuilder.edited(
        "Guten Morgen, kommen Sie rein. Na, wie geht es uns heute? Er frisst seit gestern schlecht. Hat er erbrochen? Nein, kein Erbrechen. " +
            "Okay, genau. Wir geben Meloxicam 0,1 mg/kg einmal täglich. Schönes Wetter heute übrigens. Kontrolle in drei Tagen. Tschüss, bis dann!",
        null,
    )

    private val clinical = setOf("Er frisst seit gestern schlecht.", "Hat er erbrochen?", "Nein, kein Erbrechen.", "Wir geben Meloxicam 0,1 mg/kg einmal täglich.", "Kontrolle in drei Tagen.")

    /** Answers like a careful model: clinical sentences into the report, the rest as skipped. Optionally also tries to skip the dose. */
    private fun engine(tryToSkipDose: Boolean, prompts: MutableList<String>) = object : ReportTextEngine {
        override val sourceLimit = 60
        override val characterLimit = 20_000
        override suspend fun generate(prompt: String, instructions: String): String {
            prompts += prompt
            val sources = Regex(""""id":"(q\d+)","text":"([^"]*)"""").findAll(prompt).map { it.groupValues[1] to it.groupValues[2] }.toList()
            val skipDose = tryToSkipDose && prompts.size == 1
            val items = sources.filter { (_, text) -> text.trim() in clinical && !(skipDose && text.contains("Meloxicam")) }
                .map { (id, text) -> ModelReportDraft.Item(if (text.contains("Kontrolle")) "Weiteres Vorgehen" else "Befunde", text.trim(), id, text.trim()) }
            val skipped = sources.filter { (_, text) -> text.trim() !in clinical || (skipDose && text.contains("Meloxicam")) }
                .map { (id, _) -> ModelReportDraft.Skip(id, "Begrüßung oder Smalltalk") }
            return encode(ModelReportDraft(items, skipped = skipped))
        }
    }

    @Test fun smallTalkIsLeftOutVisiblyAndTheClinicalContentStays() = runTest {
        val prompts = mutableListOf<String>()
        val report = ReportPipeline(engine(tryToSkipDose = false, prompts)) { Prompts.report }
            .run(conversation, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
        assertEquals(1, prompts.size)
        assertTrue(prompts.single().contains("skipped"))
        clinical.forEach { assertTrue(it, report.text.contains(it)) }
        assertFalse(report.text.contains("Wetter"))
        val omitted = report.content.omitted!!.map { it.text.trim() }
        assertEquals(listOf("Guten Morgen, kommen Sie rein.", "Na, wie geht es uns heute?", "Okay, genau.", "Schönes Wetter heute übrigens.", "Tschüss, bis dann!"), omitted)
        assertTrue(report.warnings.any { it.startsWith("5 Sätze wurden als nicht fachlich ausgelassen") })
        assertFalse(report.warnings.any { it.startsWith("Nicht alle Transkriptabschnitte") })
        // The omitted list is for review only; it never enters the exported report text.
        assertFalse(report.exportText.contains("Tschüss"))
    }

    @Test fun aSentenceWithADoseCanNeverBeSkipped() = runTest {
        val prompts = mutableListOf<String>()
        val report = ReportPipeline(engine(tryToSkipDose = true, prompts)) { Prompts.report }
            .run(conversation, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
        // The first answer skipped the dose; the repair asks for exactly that sentence and says why.
        assertEquals(2, prompts.size)
        assertTrue(prompts[1].contains("dürfen nicht ausgelassen werden"))
        assertTrue(report.text.contains("Meloxicam 0,1 mg/kg"))
        assertFalse(report.content.omitted!!.any { it.text.contains("Meloxicam") })
    }

    @Test fun negationsAndNumbersAreNeverSkippable() {
        assertFalse(ReportSkipPolicy.mayOmit("Nein, kein Erbrechen."))
        assertFalse(ReportSkipPolicy.mayOmit("Das ist nicht schlimm."))
        assertFalse(ReportSkipPolicy.mayOmit("Kommen Sie in 3 Tagen wieder."))
        for (spoken in listOf("Kommen Sie in drei Tagen wieder.", "Er wiegt zwölf Kilo.", "Zweimal täglich bitte.", "Eine halbe Tablette.", "Seit vierzehn Tagen so.", "Etwa zwanzig Minuten."))
            assertFalse(spoken, ReportSkipPolicy.mayOmit(spoken))
        assertTrue(ReportSkipPolicy.mayOmit("Guten Morgen, kommen Sie rein."))
        assertTrue(ReportSkipPolicy.mayOmit("Okay, genau."))
    }

    @Test fun aConversationWithoutClinicalContentFailsInsteadOfAnEmptyReport() = runTest {
        val smallTalk = TranscriptBuilder.edited("Guten Morgen. Schönes Wetter heute. Tschüss!", null)
        val engine = object : ReportTextEngine {
            override suspend fun generate(prompt: String, instructions: String): String {
                val ids = Regex(""""id":"(q\d+)"""").findAll(prompt).map { it.groupValues[1] }.toList()
                return encode(ModelReportDraft(emptyList(), skipped = ids.map { ModelReportDraft.Skip(it, "Smalltalk") }))
            }
        }
        try {
            ReportPipeline(engine) { "test" }.run(smallTalk, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
            fail("no clinical content")
        } catch (error: AppFailure) { assertTrue(error.message!!.contains("keine fachlichen Angaben")) }
    }

    @Test fun providerSchemasAllowSkippedWithKnownIDsOnly() {
        val openAI = OpenAIReportApi.request("m", "synthetic-key-for-contract-tests-000", "p", "i", listOf("Befunde"), 3).body!!.decodeToString()
        assertTrue(openAI.contains("\"skipped\"") && openAI.contains("\"required\":[\"items\",\"skipped\"]"))
        val gemini = GeminiOnlineApi.reportRequest("gemini-3.6-flash", "synthetic-key-for-contract-tests-000", "p", "i", listOf("Befunde"), 3).body!!.decodeToString()
        assertTrue(gemini.contains("\"skipped\""))
        assertEquals(60, OpenAIReportEngine(OnlineReportConfiguration("m"), "synthetic-key-for-contract-tests-000", listOf("Befunde")).sourceLimit)
    }
}
