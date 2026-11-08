package de.tobwil.vetmed.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.util.Base64

/** Whether a value's numbers were found again in the locally read original (text layer or OCR). */
@Serializable
enum class LabEvidence {
    /** Every number of value and reference appears in the local text. */
    @SerialName("found") FOUND,
    /** At least one number does not appear in the local text: check against the original. */
    @SerialName("notFound") NOT_FOUND,
    /** No local text to compare with (e.g. OCR found nothing). */
    @SerialName("unchecked") UNCHECKED,
    /** Typed or changed by the user. */
    @SerialName("edited") EDITED,
    /** Read on the device only (line parser), never by a model: always to be checked. */
    @SerialName("local") LOCAL,
}

/** The app's own reading of a value against the printed reference. Never taken from a model. */
enum class LabAssessment(val label: String, val symbol: String) {
    LOW("niedrig", "↓"), NORMAL("im Bereich", ""), HIGH("hoch", "↑"), UNKNOWN("nicht bewertbar", "?"),
}

@Serializable
data class LabValue(
    val id: String = newId(),
    val parameter: String,
    val value: String,
    val unit: String = "",
    /** Reference range exactly as printed by the laboratory; empty when none is printed. */
    val reference: String = "",
    /** The laboratory's own printed flag (H, L, +, ↑ …); empty when none is printed. */
    val flag: String = "",
    val page: Int = 1,
    val evidence: LabEvidence = LabEvidence.UNCHECKED,
    /** The reader marked this line as partly illegible. */
    val uncertain: Boolean = false,
) {
    val assessment: LabAssessment get() = LabMath.assess(value, reference)
    /** The laboratory flags high or low, but the app's reading of the printed range says otherwise: a sign of a misread value. */
    val flagConflict: Boolean get() = LabMath.flagConflict(flag, assessment)
    val needsCheck: Boolean get() = uncertain || flagConflict || evidence == LabEvidence.NOT_FOUND || evidence == LabEvidence.LOCAL
}

/** A lab result read into a table. Only a confirmed table is used in the chat. */
@Serializable
data class LabReport(
    val laboratory: String = "",
    val sampleDate: String = "",
    val values: List<LabValue> = emptyList(),
    /** How the table was read, e.g. "Gemini gemini-3.6-flash · Seitenbilder" or "Auf dem Gerät · Zeilenerkennung". */
    val method: String,
    val readAt: AppleDate = now(),
    val pages: Int = 0,
    val confirmedAt: AppleDate? = null,
) {
    val openChecks: Int get() = values.count { it.needsCheck }
}

/** Numbers and reference ranges as printed on German lab reports. Deterministic; the model never assesses. */
object LabMath {
    private val numberPattern = Regex("""\d+(?:[.,]\d+)*""")

    /**
     * "12,5" and "0.8" are decimals. With both separators, the last one is the decimal mark ("1.234,5", "1,234.5").
     * A single separator is always read as a decimal mark, because lab values rarely use thousands separators.
     */
    fun number(text: String): Double? {
        val raw = text.trim().replace(" ", "").replace(" ", "")
        if (raw.isEmpty() || !raw.all { it.isDigit() || it == ',' || it == '.' } || !raw.first().isDigit() || !raw.last().isDigit()) return null
        val lastComma = raw.lastIndexOf(','); val lastDot = raw.lastIndexOf('.')
        val normalized = when {
            lastComma >= 0 && lastDot >= 0 -> {
                val decimal = if (lastComma > lastDot) ',' else '.'
                val thousands = if (decimal == ',') '.' else ','
                raw.replace(thousands.toString(), "").replace(decimal, '.')
            }
            lastComma >= 0 -> if (raw.count { it == ',' } == 1) raw.replace(',', '.') else return null
            lastDot >= 0 -> if (raw.count { it == '.' } == 1) raw else return null
            else -> raw
        }
        return normalized.toDoubleOrNull()
    }

    /** Every number in a text, as values, for the comparison with the original. */
    fun numbers(text: String): List<Double> = numberPattern.findAll(text).mapNotNull { number(it.value) }.toList()

    data class Range(val low: Double?, val high: Double?, val lowInclusive: Boolean = true, val highInclusive: Boolean = true)

    private val between = Regex("""^(?:von\s*)?(\d+(?:[.,]\d+)*)\s*(?:-|–|—|bis|\.\.\.?)\s*(\d+(?:[.,]\d+)*)$""", RegexOption.IGNORE_CASE)
    private val bound = Regex("""^(<=|>=|≤|≥|<|>|bis|unter|über|ab|max\.?|min\.?)\s*(\d+(?:[.,]\d+)*)$""", RegexOption.IGNORE_CASE)

    /** The printed reference as a range, or null when it is not unambiguous (text, several ranges, sex-specific …). */
    fun reference(text: String): Range? {
        val value = text.trim().removeSurrounding("(", ")").trim()
        if (value.isEmpty()) return null
        between.matchEntire(value)?.let { match ->
            val low = number(match.groupValues[1]) ?: return null
            val high = number(match.groupValues[2]) ?: return null
            return if (low <= high) Range(low, high) else null
        }
        bound.matchEntire(value)?.let { match ->
            val limit = number(match.groupValues[2]) ?: return null
            return when (match.groupValues[1].lowercase()) {
                "<", "unter" -> Range(null, limit, highInclusive = false)
                "<=", "≤", "bis", "max", "max." -> Range(null, limit)
                ">", "über" -> Range(limit, null, lowInclusive = false)
                ">=", "≥", "ab", "min", "min." -> Range(limit, null)
                else -> null
            }
        }
        return null
    }

    /** H/↑ and L/↓ are read as high and low; other marks (+, -, *) have laboratory-specific meanings and are not compared. */
    fun flagConflict(flag: String, assessment: LabAssessment): Boolean {
        val mark = flag.trim().uppercase()
        val high = mark in setOf("H", "HH", "↑", "↑↑"); val low = mark in setOf("L", "LL", "↓", "↓↓")
        return (high && assessment in setOf(LabAssessment.NORMAL, LabAssessment.LOW)) || (low && assessment in setOf(LabAssessment.NORMAL, LabAssessment.HIGH))
    }

    /** Low, normal or high only from a plain number and an unambiguous printed range. Anything else is not assessable. */
    fun assess(value: String, reference: String): LabAssessment {
        val number = number(value) ?: return LabAssessment.UNKNOWN
        val range = reference(reference) ?: return LabAssessment.UNKNOWN
        range.low?.let { if (number < it || (!range.lowInclusive && number == it)) return LabAssessment.LOW }
        range.high?.let { if (number > it || (!range.highInclusive && number == it)) return LabAssessment.HIGH }
        return LabAssessment.NORMAL
    }
}

/**
 * Reading a lab result: page images go to the chosen model with a strict schema (transcription only, no assessment),
 * then every number is looked up again in the locally read text, and the user confirms the table at the original.
 */
object LabExtraction {
    const val MAX_PAGES = 6
    const val MAX_PAGE_BYTES = 2 * 1_048_576
    const val MAX_VALUES = 300
    val instructions: String by lazy { Prompts.load("lab-extraction-v1") }
    private val fields = listOf("parameter", "value", "unit", "reference", "flag", "page", "uncertain")

    private fun checkPages(pages: List<ByteArray>) {
        if (pages.isEmpty() || pages.size > MAX_PAGES) throw AppFailure("Bitte einen Befund mit 1 bis $MAX_PAGES Seiten wählen.")
        if (pages.any { it.isEmpty() || it.size > MAX_PAGE_BYTES }) throw AppFailure("Eine Befundseite ist zu groß für den Versand.")
    }

    private fun prompt(pages: Int) = "Übertrage alle Messwerte dieses Laborbefunds ($pages ${if (pages == 1) "Seite" else "Seiten"}) in die Tabelle."

    fun openAIRequest(modelID: String, key: String, pages: List<ByteArray>): HttpRequest {
        validateApiKey(key)
        checkPages(pages)
        if (modelID.isEmpty() || modelID.any { it.isWhitespace() }) throw AppFailure("Bitte eine gültige Modell-ID auswählen.")
        val value = buildJsonObject {
            put("type", "object"); put("additionalProperties", false)
            putJsonObject("properties") {
                listOf("parameter", "value", "unit", "reference", "flag").forEach { putJsonObject(it) { put("type", "string") } }
                putJsonObject("page") { put("type", "integer") }
                putJsonObject("uncertain") { put("type", "boolean") }
            }
            putJsonArray("required") { fields.forEach { add(JsonPrimitive(it)) } }
        }
        val body = buildJsonObject {
            put("model", modelID); put("store", false); put("stream", false); put("background", false); put("max_output_tokens", 16_384)
            put("instructions", instructions)
            putJsonArray("input") {
                add(buildJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        add(buildJsonObject { put("type", "input_text"); put("text", prompt(pages.size)) })
                        pages.forEach { page ->
                            add(buildJsonObject { put("type", "input_image"); put("image_url", "data:image/jpeg;base64," + Base64.getEncoder().encodeToString(page)); put("detail", "high") })
                        }
                    }
                })
            }
            putJsonObject("text") {
                putJsonObject("format") {
                    put("type", "json_schema"); put("name", "veterinary_lab_table_v1"); put("strict", true)
                    putJsonObject("schema") {
                        put("type", "object"); put("additionalProperties", false)
                        putJsonObject("properties") {
                            putJsonObject("laboratory") { put("type", "string") }
                            putJsonObject("sampleDate") { put("type", "string") }
                            putJsonObject("values") { put("type", "array"); put("items", value) }
                        }
                        putJsonArray("required") { listOf("laboratory", "sampleDate", "values").forEach { add(JsonPrimitive(it)) } }
                    }
                }
            }
        }
        return HttpRequest(OpenAIReportApi.RESPONSES_URL, "POST", mapOf("Authorization" to "Bearer $key", "Content-Type" to "application/json"), body.toString().encodeToByteArray())
    }

    fun geminiRequest(modelID: String, key: String, pages: List<ByteArray>): HttpRequest {
        validateApiKey(key)
        checkPages(pages)
        if (modelID.isEmpty() || modelID.any { it.isWhitespace() || it == '/' || it == '?' || it == ':' }) throw AppFailure("Bitte eine gültige Modell-ID auswählen.")
        val value = buildJsonObject {
            put("type", "OBJECT")
            putJsonObject("properties") {
                listOf("parameter", "value", "unit", "reference", "flag").forEach { putJsonObject(it) { put("type", "STRING") } }
                putJsonObject("page") { put("type", "INTEGER") }
                putJsonObject("uncertain") { put("type", "BOOLEAN") }
            }
            putJsonArray("required") { fields.forEach { add(JsonPrimitive(it)) } }
            putJsonArray("propertyOrdering") { fields.forEach { add(JsonPrimitive(it)) } }
        }
        val body = buildJsonObject {
            putJsonObject("systemInstruction") { putJsonArray("parts") { add(buildJsonObject { put("text", instructions) }) } }
            putJsonArray("contents") {
                add(buildJsonObject {
                    put("role", "user")
                    putJsonArray("parts") {
                        add(buildJsonObject { put("text", prompt(pages.size)) })
                        pages.forEach { page -> add(buildJsonObject { putJsonObject("inlineData") { put("mimeType", "image/jpeg"); put("data", Base64.getEncoder().encodeToString(page)) } }) }
                    }
                })
            }
            putJsonObject("generationConfig") {
                put("maxOutputTokens", 32_768); put("responseMimeType", "application/json")
                putJsonObject("responseSchema") {
                    put("type", "OBJECT")
                    putJsonObject("properties") {
                        putJsonObject("laboratory") { put("type", "STRING") }
                        putJsonObject("sampleDate") { put("type", "STRING") }
                        putJsonObject("values") { put("type", "ARRAY"); put("items", value) }
                    }
                    putJsonArray("required") { listOf("laboratory", "sampleDate", "values").forEach { add(JsonPrimitive(it)) } }
                }
            }
        }
        return HttpRequest(
            "https://generativelanguage.googleapis.com/v1beta/models/$modelID:generateContent", "POST",
            mapOf("x-goog-api-key" to key, "Content-Type" to "application/json"), body.toString().encodeToByteArray(),
        )
    }

    /** The model's table. Rejects anything that is not the schema; empty tables are an error, not a result. */
    fun parse(text: String, method: String, pages: Int): LabReport {
        val root = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: throw AppFailure("Die Tabelle des Anbieters konnte nicht gelesen werden.")
        val rows = (root["values"] as? JsonArray) ?: throw AppFailure("Die Tabelle des Anbieters ist unvollständig.")
        if (rows.size > MAX_VALUES) throw AppFailure("Der Befund enthält mehr als $MAX_VALUES Werte. Bitte in Teilen hinzufügen.")
        fun JsonObject.text(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty().take(200)
        val values = rows.map { element ->
            val row = element as? JsonObject ?: throw AppFailure("Die Tabelle des Anbieters ist unvollständig.")
            LabValue(
                parameter = row.text("parameter"), value = row.text("value"), unit = row.text("unit"), reference = row.text("reference"), flag = row.text("flag"),
                page = ((row["page"] as? JsonPrimitive)?.intOrNull ?: 1).coerceIn(1, pages.coerceAtLeast(1)),
                uncertain = (row["uncertain"] as? JsonPrimitive)?.booleanOrNull ?: false,
            )
        }.filter { it.parameter.isNotEmpty() || it.value.isNotEmpty() }
        if (values.isEmpty()) throw AppFailure("Im Befund wurden keine Messwerte erkannt. Du kannst den Text stattdessen als Dokument prüfen.")
        return LabReport(laboratory = root.text("laboratory"), sampleDate = root.text("sampleDate"), values = values, method = method, pages = pages)
    }

    /**
     * Every number of a value and its reference must appear in the locally read original. A model that misreads
     * "5,8" as "5,3" is caught here unless the local reading makes the same mistake; the user confirms either way.
     */
    fun verify(report: LabReport, localText: String): LabReport {
        val local = LabMath.numbers(localText).toSet()
        return report.copy(values = report.values.map { value ->
            if (value.evidence == LabEvidence.EDITED || value.evidence == LabEvidence.LOCAL) return@map value
            val numbers = LabMath.numbers(value.value) + LabMath.numbers(value.reference)
            val evidence = when {
                local.isEmpty() -> LabEvidence.UNCHECKED
                numbers.all { it in local } -> LabEvidence.FOUND
                else -> LabEvidence.NOT_FOUND
            }
            value.copy(evidence = evidence)
        })
    }

    private val localLine = Regex(
        """^\s*([A-Za-zÄÖÜäöüß][A-Za-zÄÖÜäöüß0-9 .,()/%+\-]*?)\s+([<>≤≥]?\s?\d+(?:[.,]\d+)?)\s*([A-Za-zµμ%/][^\s]*(?:\s?/\s?[^\s]+)?)?\s*""" +
            """(\(?(?:\d+(?:[.,]\d+)?\s*(?:-|–|bis)\s*\d+(?:[.,]\d+)?|[<>≤≥]\s*\d+(?:[.,]\d+)?)\)?)?\s*([HLhl+\-↑↓*]{1,2})?\s*$""",
    )

    /** Device-only fallback: one value per text line that looks like "Name Wert Einheit Referenz". Always to be checked. */
    fun parseLocal(text: String, pages: Int): LabReport {
        var page = 1
        val values = text.lineSequence().mapNotNull { line ->
            Regex("""^Seite (\d+)$""").matchEntire(line.trim())?.let { page = it.groupValues[1].toInt(); return@mapNotNull null }
            val match = localLine.matchEntire(line) ?: return@mapNotNull null
            val (name, value, unit, reference, flag) = match.destructured
            if (name.trim().length < 2) return@mapNotNull null
            LabValue(parameter = name.trim(), value = value.trim(), unit = unit.trim(), reference = reference.trim().removeSurrounding("(", ")"), flag = flag.trim(), page = page, evidence = LabEvidence.LOCAL)
        }.take(MAX_VALUES).toList()
        if (values.isEmpty()) throw AppFailure("Auf dem Gerät wurden keine Wertezeilen erkannt. Bitte online lesen oder den Text als Dokument prüfen.")
        return LabReport(values = values, method = "Auf dem Gerät · Zeilenerkennung", pages = pages)
    }

    private fun cell(text: String) = text.replace("|", "/").replace("\n", " ").ifEmpty { "–" }

    /** The confirmed table as the chat receives it: laboratory values verbatim, the app's own assessment separate. */
    fun render(report: LabReport): String = buildString {
        append("Laborbefund")
        if (report.laboratory.isNotEmpty()) append(" · ").append(report.laboratory)
        if (report.sampleDate.isNotEmpty()) append(" · Probe vom ").append(report.sampleDate)
        append("\nTabelle am Original geprüft und bestätigt. Referenz und Kennzeichnung stammen vom Labor; die Bewertung berechnet die App ausschließlich aus dem gedruckten Referenzbereich.\n\n")
        append("| Parameter | Wert | Einheit | Referenz (Labor) | Kennz. (Labor) | Bewertung (App) |\n|---|---|---|---|---|---|\n")
        report.values.forEach { value ->
            val assessment = value.assessment
            append("| ${cell(value.parameter)} | ${cell(value.value)} | ${cell(value.unit)} | ${cell(value.reference)} | ${cell(value.flag)} | ")
            append(if (assessment == LabAssessment.NORMAL) assessment.label else (assessment.symbol + " " + assessment.label).trim()).append(" |\n")
        }
    }
}

/** Earlier confirmed values of the same parameter in the same case, newest first: the course over several results. */
object LabHistory {
    data class Entry(val date: String, val value: LabValue, val attachmentID: String)

    /** Names match case- and space-insensitively ("ALT (GPT)" = "alt(gpt)"); units must match to be comparable. */
    fun key(parameter: String, unit: String): String =
        parameter.lowercase().filter { it.isLetterOrDigit() } + "|" + unit.lowercase().replace(" ", "").replace("μ", "µ")

    fun previous(document: VaultDocument, caseID: String?, excludeAttachmentID: String): Map<String, List<Entry>> {
        val chats = if (caseID == null) emptyList() else document.cases.firstOrNull { it.id == caseID }?.encounters.orEmpty()
        return chats.flatMap { it.chatAttachments.orEmpty() }
            .filter { it.id != excludeAttachmentID && it.lab?.confirmedAt != null }
            .sortedByDescending { it.lab!!.confirmedAt }
            .flatMap { attachment -> attachment.lab!!.values.map { Entry(attachment.lab.sampleDate.ifEmpty { attachment.createdAt.germanDateTime().substringBefore(",") }, it, attachment.id) } }
            .groupBy { key(it.value.parameter, it.value.unit) }
    }
}
