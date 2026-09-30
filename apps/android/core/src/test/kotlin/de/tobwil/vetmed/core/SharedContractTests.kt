package de.tobwil.vetmed.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.time.Instant

/** Checks against `shared/` so Android and iOS keep one fachlicher Vertrag. */
class SharedContractTests {
    private val shared = File(System.getProperty("vetmed.shared") ?: "../../../shared")

    @Serializable
    private data class Fixture(val id: String, val category: String, val transcript: String, val criticalSourcePhrases: List<String>, val synthetic: Boolean)

    private val corpus: List<Fixture> by lazy {
        Json { ignoreUnknownKeys = true }.decodeFromString(ListSerializer(Fixture.serializer()), shared.resolve("fixtures/report-corpus-de.json").readText())
    }

    /** Returns every source verbatim, as a perfect model would. */
    private class VerbatimEngine : ReportTextEngine {
        override val sourceLimit = 24
        override val characterLimit = 12_000
        override suspend fun generate(prompt: String, instructions: String): String {
            val sources = Json.parseToJsonElement(prompt.substringAfter("QUELLEN:\n").substringBefore("\nKorrektur")).jsonArray
            val items = sources.map {
                val source = it.jsonObject
                ModelReportDraft.Item("Befunde", source.getValue("text").jsonPrimitive.content, source.getValue("id").jsonPrimitive.content, source.getValue("text").jsonPrimitive.content)
            }
            return VetJson.encodeToString(ModelReportDraft.serializer(), ModelReportDraft(items))
        }
    }

    @Test fun corpusIsSyntheticOnly() {
        assertEquals(30, corpus.size)
        assertTrue(corpus.all { it.synthetic })
    }

    @Test fun segmentationNeverSplitsCriticalPhrasesOrLosesText() {
        for (fixture in corpus) {
            val version = TranscriptBuilder.edited(fixture.transcript, null)
            assertEquals(fixture.id, fixture.transcript, version.segments.joinToString("") { it.text })
            for (phrase in fixture.criticalSourcePhrases) {
                assertTrue("${fixture.id}: '$phrase' split across sources", version.segments.any { it.text.contains(phrase) })
            }
        }
    }

    @Test fun verbatimReportsKeepEveryCriticalPhraseWithoutWarnings() = runTest {
        for (fixture in corpus) {
            val transcript = TranscriptBuilder.edited(fixture.transcript, null)
            if (transcript.segments.none { TranscriptSourcePolicy.requiresCoverage(it.text) }) {
                try {
                    ReportPipeline(VerbatimEngine()) { "test" }.run(transcript, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
                    fail("${fixture.id}: empty dictation must not become a report")
                } catch (_: AppFailure) {}
                continue
            }
            val report = ReportPipeline(VerbatimEngine()) { "test" }.run(transcript, ReportTemplate.TREATMENT_REPORT, ReportLength.MEDIUM, Audience.VETERINARIAN)
            for (phrase in fixture.criticalSourcePhrases) assertTrue("${fixture.id}: $phrase", report.text.contains(phrase))
            assertEquals(fixture.id, emptyList<String>(), report.warnings)
        }
    }

    @Test fun structuredReportMatchesSharedSchemaFields() {
        val schema = Json.parseToJsonElement(shared.resolve("schemas/report-v1.schema.json").readText()).jsonObject
        val required = schema.getValue("required").jsonArray.map { it.jsonPrimitive.content }.toSet()
        val templates = schema.getValue("properties").jsonObject.getValue("template").jsonObject.getValue("enum").jsonArray.map { it.jsonPrimitive.content }.toSet()
        val report = StructuredReport(
            template = ReportTemplate.SOAP, length = ReportLength.SHORT, audience = Audience.OWNER, sourceTranscriptVersionId = newId(),
            sections = listOf(ReportSection("Plan", listOf(ReportItem("Kontrolle.", listOf(SourceReference("text-0", "Kontrolle.")), "dictated")))),
            missingInformation = emptyList(), conflicts = emptyList(),
        )
        val encoded = Json.parseToJsonElement(VetJson.encodeToString(StructuredReport.serializer(), report)).jsonObject
        assertEquals(required, encoded.keys)
        assertEquals(templates, ReportTemplate.entries.map { VetJson.encodeToString(ReportTemplate.serializer(), it).trim('"') }.toSet())
    }

    @Test fun datesAndIdsUseTheSameJsonAsIos() {
        // Swift's JSONEncoder writes Date as seconds since 2001-01-01 and UUID uppercased.
        val case = VetCase(id = "9A7C3E4B-0000-4000-8000-000000000001", label = "Fall 1", species = "Hund", createdAt = Instant.parse("2026-09-29T12:00:00Z"))
        val json = VetJson.encodeToString(VetCase.serializer(), case)
        assertEquals(812376000.0, Json.parseToJsonElement(json).jsonObject.getValue("createdAt").jsonPrimitive.content.toDouble(), 0.0)
        assertEquals(case, VetJson.decodeFromString(VetCase.serializer(), json))
        val fromIos = """{"id":"9A7C3E4B-0000-4000-8000-000000000001","label":"Fall 1","species":"Hund","animalName":"","createdAt":812376000.5,"encounters":[],"futureField":true}"""
        assertEquals(Instant.parse("2026-09-29T12:00:00.500Z"), VetJson.decodeFromString(VetCase.serializer(), fromIos).createdAt)
    }
}
