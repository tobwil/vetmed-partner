package de.tobwil.vetmed.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Live check of lab reading with real (anonymized) results from a local folder, never from the repository.
 * Runs only with `VETMED_EVAL_LAB_DIR`, `VETMED_EVAL_KEY`, `VETMED_EVAL_MODEL` and `VETMED_EVAL_PROVIDER` (openai|gemini);
 * see `scripts/eval-labs.sh`. Per result: `name-1.jpg`, `name-2.jpg` … (pages), optional `name.txt` (the locally
 * readable text for the cross-check) and optional `name.expected.json` ([{"parameter","value"}, …], typed by hand).
 * Writes `build/lab-eval.json`: how many expected values were read exactly, how many were wrong, and how many of the
 * wrong ones the app marked (red or orange) so the user would have caught them.
 */
class LabLiveEval {
    private val dir = System.getenv("VETMED_EVAL_LAB_DIR")
    private val key = System.getenv("VETMED_EVAL_KEY")
    private val model = System.getenv("VETMED_EVAL_MODEL")
    private val provider = System.getenv("VETMED_EVAL_PROVIDER") ?: "openai"

    @Test fun labResultsAreReadAndMisreadingsAreMarked() {
        assumeTrue("Live-Prüfung nur mit VETMED_EVAL_LAB_DIR, VETMED_EVAL_KEY und VETMED_EVAL_MODEL", listOf(dir, key, model).none { it.isNullOrBlank() })
        val folder = File(dir!!)
        val names = folder.listFiles().orEmpty().mapNotNull { Regex("""^(.+)-(\d+)\.(jpe?g)$""").matchEntire(it.name)?.groupValues?.get(1) }.distinct().sorted()
        var expectedTotal = 0; var exact = 0; var wrong = 0; var wrongMarked = 0; var missing = 0
        val results = buildJsonArray {
            for (name in names) {
                val pages = folder.listFiles().orEmpty().filter { Regex("""^${Regex.escape(name)}-(\d+)\.jpe?g$""").matches(it.name) }
                    .sortedBy { Regex("""-(\d+)\.""").find(it.name)!!.groupValues[1].toInt() }.map { it.readBytes() }
                val local = File(folder, "$name.txt").takeIf { it.exists() }?.readText().orEmpty()
                val outcome = runCatching {
                    runBlocking {
                        val request = if (provider == "gemini") LabExtraction.geminiRequest(model!!, key!!, pages) else LabExtraction.openAIRequest(model!!, key!!, pages)
                        val response = EphemeralHttpTransport.send(request)
                        val text = if (provider == "gemini") GeminiOnlineApi.reportResult(response, model).text else OpenAIReportApi.result(response).text
                        LabExtraction.verify(LabExtraction.parse(text, "$provider $model", pages.size), local)
                    }
                }
                val report = outcome.getOrNull()
                val expected = File(folder, "$name.expected.json").takeIf { it.exists() }
                    ?.let { Json.parseToJsonElement(it.readText()).jsonArray.map { row -> row.jsonObject } }.orEmpty()
                val rows = buildJsonArray {
                    for (row in expected) {
                        val parameter = row["parameter"]!!.jsonPrimitive.content; val value = row["value"]!!.jsonPrimitive.content
                        expectedTotal++
                        val found = report?.values?.firstOrNull { LabHistory.key(it.parameter, "") == LabHistory.key(parameter, "") }
                        val status = when {
                            found == null -> { missing++; "fehlt" }
                            found.value.replace(" ", "") == value.replace(" ", "") -> { exact++; "richtig" }
                            else -> { wrong++; if (found.needsCheck) { wrongMarked++; "falsch, markiert" } else "falsch, NICHT markiert" }
                        }
                        add(buildJsonObject { put("parameter", parameter); put("erwartet", value); put("gelesen", found?.value); put("status", status) })
                    }
                }
                add(buildJsonObject {
                    put("befund", name); put("seiten", pages.size); put("fehler", outcome.exceptionOrNull()?.message)
                    put("werte", report?.values?.size ?: 0); put("markiert", report?.openChecks ?: 0); put("vergleich", rows)
                    put("tabelle", report?.let { JsonPrimitive(LabExtraction.render(it)) } ?: JsonPrimitive(null as String?))
                })
            }
        }
        val summary = buildJsonObject {
            put("anbieter", provider); put("modell", model); put("befunde", names.size); put("erwartet", expectedTotal)
            put("richtig", exact); put("falsch", wrong); put("falsch_aber_markiert", wrongMarked); put("fehlt", missing); put("ergebnisse", results)
        }
        File("build/lab-eval.json").apply { parentFile.mkdirs() }.writeText(summary.toString())
        println("Laborbefunde: ${names.size}, erwartet $expectedTotal, richtig $exact, falsch $wrong (davon markiert $wrongMarked), fehlt $missing")
    }
}
