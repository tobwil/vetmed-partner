package de.tobwil.vetmed.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.MissingFieldException
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import java.text.BreakIterator
import java.util.Locale

/** Port of the iOS `ReportValidator`. Both platforms must accept and reject the same reports. */
object ReportValidator {
    fun decode(text: String): StructuredReport = decodeJson(StructuredReport.serializer(), text)

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun <T> decodeJson(serializer: KSerializer<T>, text: String): T {
        var value = text.trim()
        if (value.startsWith("```") && value.endsWith("```") && value.contains('\n')) {
            value = value.substring(value.indexOf('\n') + 1, value.length - 3)
        }
        value = normalizeJsonWhitespace(value)
        try {
            return VetJson.decodeFromString(serializer, value)
        } catch (error: MissingFieldException) {
            throw AppFailure("JSON-Pflichtfeld fehlt: ${error.missingFields.joinToString(", ")}.")
        } catch (error: SerializationException) {
            throw AppFailure("Die Modellantwort enthält kein gültiges Berichts-JSON.")
        } catch (error: IllegalArgumentException) {
            throw AppFailure("Die Modellantwort enthält kein gültiges Berichts-JSON.")
        }
    }

    /**
     * Some local outputs spell whitespace as literal \n between JSON tokens. Only normalize
     * outside strings; quotes, content, punctuation and malformed structure remain untouched.
     */
    fun normalizeJsonWhitespace(input: String): String {
        val output = StringBuilder(input.length)
        var insideString = false
        var escaped = false
        var index = 0
        while (index < input.length) {
            val character = input[index]
            if (insideString) {
                output.append(character)
                if (escaped) escaped = false
                else if (character == '\\') escaped = true
                else if (character == '"') insideString = false
            } else if (character == '"') {
                insideString = true; output.append(character)
            } else if (character == '\\' && index + 1 < input.length && input[index + 1] in "nrt") {
                output.append(' '); index += 1
            } else output.append(character)
            index += 1
        }
        return output.toString()
    }

    fun validate(report: StructuredReport, transcript: TranscriptVersion): List<String> {
        if (transcript.segments.map { it.id }.toSet().size != transcript.segments.size) {
            throw AppFailure("Das Transkript enthält doppelte Quellen-IDs. Bitte eine neue Textversion speichern.")
        }
        val allowed = report.template.sections
        if (report.schemaVersion != 1 || !report.requiresReview ||
            report.sourceTranscriptVersionId != transcript.id ||
            report.sections.isEmpty() || report.sections.all { it.items.isEmpty() } ||
            report.sections.map { it.key }.toSet().size != report.sections.size ||
            !report.sections.all { it.key in allowed }
        ) throw AppFailure("Berichtsformat oder Quellenstand ist ungültig.")
        val segments = transcript.segments.associate { it.id to it.text }
        val warnings = mutableSetOf<String>()
        for (item in report.sections.flatMap { it.items }) {
            if (item.origin != "dictated" || item.text.isBlank() || item.sourceRefs.isEmpty()) {
                throw AppFailure("Eine Aussage hat keinen Diktatbeleg.")
            }
            for (ref in item.sourceRefs) {
                val source = segments[ref.segmentId]
                if (source == null || ref.quote.isBlank() || !source.contains(ref.quote)) {
                    throw AppFailure("Ein Quellenbeleg ist unbekannt oder verändert.")
                }
            }
            val quotes = item.sourceRefs.joinToString(" ") { it.quote }
            if (!quotes.let(::numbers).containsAll(numbers(item.text))) {
                throw AppFailure("Eine Zahl im Bericht ist nicht durch die zugeordnete Originalstelle belegt.")
            }
            if (!units(quotes).containsAll(units(item.text))) throw AppFailure("Eine Einheit im Bericht wurde gegenüber dem Beleg verändert.")
            if (!comparisons(quotes).containsAll(comparisons(item.text))) throw AppFailure("Ein Vergleichszeichen wurde gegenüber dem Beleg verändert.")
            val itemNumbers = numbers(item.text)
            val itemComparisons = comparisons(item.text)
            if (comparisons(quotes).any { sign -> numbers(sign).any { it in itemNumbers } && sign !in itemComparisons }) {
                throw AppFailure("Ein Vergleichszeichen am Zahlenwert fehlt.")
            }
            if (hasNegation(quotes) != hasNegation(item.text)) warnings += "Negation abgleichen: ${item.text}"
        }
        val missingNumbers = numbers(transcript.editedText) - numbers(report.text)
        if (missingNumbers.isNotEmpty()) warnings += "Zahlen aus dem Transkript fehlen im Bericht: " + missingNumbers.sorted().joinToString(", ")
        val covered = report.sections.flatMap { it.items }.flatMap { it.sourceRefs }.map { it.segmentId }.toSet()
        val required = transcript.segments.filter { TranscriptSourcePolicy.requiresCoverage(it.text) }.map { it.id }
        if (!covered.containsAll(required)) warnings += "Nicht alle Transkriptabschnitte sind im Bericht belegt. Vollständigkeit prüfen."
        if (report.conflicts.isNotEmpty()) warnings += "Widersprüchliche Angaben vor Freigabe klären."
        return warnings.sorted()
    }

    // Android's ICU rejects Java's embedded (?U) flag. Explicit Unicode classes also
    // keep the JVM tests Unicode-aware without making the Android class initializer crash.
    private const val WORD = """[\p{L}\p{M}\p{Nd}\p{Nl}\p{Pc}\u200C\u200D]"""
    private val numberPattern = Regex("""(?<![\p{L}\p{Nd}])\p{Nd}+(?:[.,]\p{Nd}+)?""")
    private val unitPattern = Regex("""(?i)(?<!\p{L})(?:µg/kg|μg/kg|mg/kg|mg/dl|mmol/l|µmol/l|ml/kg|g/l|mg|µg|μg|kg|ml|mm|cm|°c|bpm)(?!\p{L})""")
    private val comparisonPattern = Regex("""(?:[<>≤≥]=?)[\p{Z}\u0009-\u000D\u0085]*\p{Nd}+(?:[.,]\p{Nd}+)?""")
    private val negationPattern = Regex("""(?i)(?<!$WORD)(?:kein$WORD*|nicht|ohne|verneint)(?!$WORD)""")

    fun numbers(text: String): Set<String> = numberPattern.findAll(text).map { it.value.replace(',', '.') }.toSet()
    fun units(text: String): Set<String> = unitPattern.findAll(text.lowercase()).map { it.value }.toSet()
    fun comparisons(text: String): Set<String> = comparisonPattern.findAll(text).map { it.value.replace(" ", "").replace(',', '.') }.toSet()
    fun hasNegation(text: String): Boolean = negationPattern.containsMatchIn(text)
}

object TranscriptSourcePolicy {
    private val housekeeping = setOf("diktatbeginn", "diktatende", "ende des diktats", "neuer bericht", "synthetischer testfall")
    private val syntheticLabel = Regex("""^abschnitt (?:\d+|(?:erst|zweit|dritt|viert|fünft|sechst|siebt|acht|neunt|zehnt)(?:e|er|en|es))\.? synthetischer testfall$""")

    /** Closed list of dictation housekeeping phrases. Clinical content is never omitted by model discretion. */
    fun requiresCoverage(text: String): Boolean {
        val normalized = text.trim().lowercase().trim { it.isPunctuation() }
        if (normalized in housekeeping) return false
        return !syntheticLabel.matches(normalized)
    }

    private fun Char.isPunctuation(): Boolean = when (Character.getType(this).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
        Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION, Character.OTHER_PUNCTUATION -> true
        else -> false
    }
}

object TranscriptBuilder {
    private const val MAX_SEGMENT = 900

    /** Changed text gets fresh source IDs; original audio-aligned segments remain in the parent version. */
    fun edited(text: String, previous: TranscriptVersion?): TranscriptVersion {
        val segments = mutableListOf<TranscriptSegment>()
        var consumed = 0
        for (end in sentenceEnds(text)) {
            var remainder = text.substring(consumed, end)
            while (remainder.isNotEmpty()) {
                var boundary = minOf(MAX_SEGMENT, remainder.length)
                if (boundary < remainder.length) {
                    val space = remainder.substring(0, boundary).indexOfLast { it.isWhitespace() }
                    if (space > 0) boundary = space + 1
                }
                val piece = remainder.substring(0, boundary)
                if (piece.isNotBlank()) segments += TranscriptSegment(id = "text-${segments.size}", text = piece)
                remainder = remainder.substring(boundary)
            }
            consumed = end
        }
        if (consumed < text.length && segments.isNotEmpty()) {
            val last = segments.removeAt(segments.lastIndex)
            segments += last.copy(text = last.text + text.substring(consumed))
        }
        return TranscriptVersion(
            parentID = previous?.id,
            rawText = previous?.rawText ?: text,
            editedText = text,
            segments = segments,
            engine = previous?.engine ?: "Manuelle Eingabe",
        )
    }

    /** Sentence-level source coverage, retaining the enclosing ASR time range for audio playback. */
    fun audioSentences(input: List<TranscriptSegment>): List<TranscriptSegment> {
        val groups = mutableListOf<MutableList<TranscriptSegment>>()
        for (source in input) {
            val last = groups.lastOrNull()?.lastOrNull()
            if (last != null && last.audioID == source.audioID) groups.last() += source else groups += mutableListOf(source)
        }
        return groups.flatMap { group ->
            val joined = StringBuilder()
            val offsets = mutableListOf<Pair<IntRange, TranscriptSegment>>()
            for (source in group) {
                if (joined.isNotEmpty()) joined.append(' ')
                val start = joined.length
                joined.append(source.text)
                offsets += (start until joined.length) to source
            }
            var offset = 0
            edited(joined.toString(), previous = null).segments.mapIndexed { index, piece ->
                val range = offset until offset + piece.text.length
                offset += piece.text.length
                val enclosing = offsets.filter { (sourceRange, _) -> !sourceRange.isEmpty() && sourceRange.first <= range.last && range.first <= sourceRange.last }.map { it.second }
                TranscriptSegment(
                    id = group[0].id + "-sentence-$index",
                    text = piece.text,
                    audioID = group[0].audioID,
                    startSeconds = enclosing.firstOrNull()?.startSeconds,
                    endSeconds = enclosing.lastOrNull()?.endSeconds,
                )
            }
        }
    }

    private fun sentenceEnds(text: String): List<Int> {
        val iterator = BreakIterator.getSentenceInstance(Locale.GERMAN)
        iterator.setText(text)
        val ends = mutableListOf<Int>()
        var end = iterator.next()
        while (end != BreakIterator.DONE) { ends += end; end = iterator.next() }
        return ends
    }
}

@Serializable
data class ModelReportDraft(
    val items: List<Item>,
    // Optional model annotations, never a claim that the source is complete or consistent.
    val missingInformation: List<String> = emptyList(),
    val conflicts: List<String> = emptyList(),
) {
    @Serializable
    data class Item(val section: String, val text: String, val segmentId: String, val quote: String)

    /** Exact heading synonyms only. Statement text and source evidence are never rewritten. */
    fun normalizeSectionAliases(template: ReportTemplate): ModelReportDraft {
        val aliases = when (template) {
            ReportTemplate.TREATMENT_REPORT -> mapOf("Kontrolle" to "Weiteres Vorgehen", "Weitere Ergebnisse" to "Weiteres Vorgehen")
            ReportTemplate.SOAP -> mapOf("Kontrolle" to "Plan", "Weitere Ergebnisse" to "Plan")
            ReportTemplate.FOLLOW_UP -> mapOf("Kontrolle" to "Nächster Schritt", "Weitere Ergebnisse" to "Nächster Schritt")
            ReportTemplate.OWNER_INFORMATION -> mapOf("Kontrolle" to "Vereinbarte Schritte", "Weitere Ergebnisse" to "Einordnung")
            ReportTemplate.REFERRAL -> emptyMap()
        }
        return copy(items = items.map { item -> aliases[item.section]?.let { item.copy(section = it) } ?: item })
    }

    fun report(transcriptID: String, template: ReportTemplate, length: ReportLength, audience: Audience): StructuredReport {
        if (items.isEmpty() || !items.all { it.section in template.sections }) {
            throw AppFailure("Die Modellantwort enthält unbekannte oder leere Berichtsabschnitte.")
        }
        return StructuredReport(
            template = template, length = length, audience = audience, sourceTranscriptVersionId = transcriptID,
            sections = template.sections.map { name ->
                ReportSection(name, items.filter { it.section == name }.map {
                    ReportItem(it.text, listOf(SourceReference(it.segmentId, it.quote)), "dictated")
                })
            },
            missingInformation = missingInformation, conflicts = conflicts,
        )
    }
}
