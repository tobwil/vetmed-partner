package de.tobwil.vetmed.core

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/** A model backend that turns one prompt into raw text. Online (OpenAI) now, LiteRT-LM later. */
interface ReportTextEngine {
    val engineID: String get() = "synthetic-test-engine"
    val engineRevision: String get() = "synthetic"
    val sourceLimit: Int get() = 4
    val characterLimit: Int get() = 1800
    val executionLabel: String get() = "Test"
    suspend fun generate(prompt: String, instructions: String): String
}

object Prompts {
    fun load(name: String): String =
        Prompts::class.java.classLoader.getResourceAsStream("$name.txt")?.use { it.readBytes().decodeToString() }
            ?: throw AppFailure("Der versionierte Prompt $name fehlt.")
    val report: String by lazy { load("report-v1") }
}

/** Port of the iOS `ReportPipeline`: chunked generation, one repair attempt, local validation, no silent omission. */
class ReportPipeline(private val engine: ReportTextEngine, private val instructions: () -> String = { Prompts.report }) {
    @Serializable private data class WireSource(val id: String, val text: String)

    suspend fun run(
        transcript: TranscriptVersion,
        template: ReportTemplate,
        length: ReportLength,
        audience: Audience,
        checkpoint: suspend (ReportCheckpoint) -> Unit = {},
        progress: (String) -> Unit = {},
    ): ReportVersion {
        if (transcript.segments.isEmpty()) throw AppFailure("Bitte zuerst ein Transkript erfassen.")
        if (transcript.segments.map { it.id }.toSet().size != transcript.segments.size) {
            throw AppFailure("Das Transkript enthält doppelte Quellen-IDs. Bitte eine neue Textversion speichern.")
        }
        if (transcript.editedText.encodeToByteArray().size > 1_000_000) {
            throw AppFailure("Das Transkript ist für einen einzelnen Bericht zu groß. Bitte in mehrere Vorgänge aufteilen; der Originaltext bleibt erhalten.")
        }
        val chunks = mutableListOf<List<TranscriptSegment>>()
        var current = mutableListOf<TranscriptSegment>()
        var size = 0
        for (segment in transcript.segments.filter { TranscriptSourcePolicy.requiresCoverage(it.text) }) {
            if ((size + segment.text.length > engine.characterLimit || current.size >= engine.sourceLimit) && current.isNotEmpty()) {
                chunks += current; current = mutableListOf(); size = 0
            }
            current += segment; size += segment.text.length
        }
        if (current.isNotEmpty()) chunks += current
        if (chunks.isEmpty()) throw AppFailure("Das Transkript enthält noch keine fachlichen Angaben.")

        val collected = mutableListOf<StructuredReport>()
        val sectionNames = template.sections.joinToString(", ")
        for ((index, chunk) in chunks.withIndex()) {
            currentCoroutineContext().ensureActive()
            progress("Abschnitt ${index + 1} von ${chunks.size} · ${engine.executionLabel}")
            val aliases = chunk.mapIndexed { i, segment -> segment.id to "q${i + 1}" }.toMap()
            val originals = aliases.entries.associate { (original, alias) -> alias to original }
            fun prompt(sources: List<TranscriptSegment>): String {
                val wire = VetJson.encodeToString(ListSerializer(WireSource.serializer()), sources.map { WireSource(aliases.getValue(it.id), it.text) })
                return """
                    Erstelle einen ${template.title} auf Deutsch. Länge: ${length.title}, Zielgruppe: ${audience.title}.
                    Ordne ALLE Befunde und vereinbarten Schritte aus den Quellen passenden Abschnitten zu.
                    Jede Quellen-ID muss in mindestens einem Item erscheinen. Es gibt ${sources.size} Quellen: ${sources.mapNotNull { aliases[it.id] }.joinToString(", ")}.
                    Auch negative Angaben, unbekannte Messwerte und vereinbarte Kontrollen müssen erhalten bleiben.
                    Erlaubte section-Werte: $sectionNames.
                    Antworte mit genau einem JSON-Objekt. Beginne mit { und ende mit }. Kein Titel, keine Codeblöcke.
                    Struktur: {"items":[{"section":"Abschnittsname","text":"Aussage","segmentId":"Quellen-ID","quote":"wörtliches Zitat"}]}
                    Das äußere Objekt hat nur das Feld items. Beende die Antwort unmittelbar nach seiner schließenden Klammer.
                    Jedes Item hat genau diese vier String-Felder. Nutze echte Quellen-IDs aus id und exakte Zitate aus text.
                    Keine Inhalte erfinden. Keine Normalbefunde ergänzen. Zahlen und Negationen unverändert erhalten.
                    QUELLEN:
                    """.trimIndent() + "\n" + wire
            }
            var result: StructuredReport? = null
            var repairNote = ""
            var pending = chunk
            val accepted = mutableListOf<ModelReportDraft.Item>()
            val missingInformation = mutableListOf<String>()
            val conflicts = mutableListOf<String>()
            for (attempt in 0 until 2) {
                val output = engine.generate(prompt(pending) + repairNote, instructions())
                try {
                    var draft = ReportValidator.decodeJson(ModelReportDraft.serializer(), output).normalizeSectionAliases(template)
                    draft = draft.copy(items = draft.items.map { item ->
                        item.copy(segmentId = originals[item.segmentId] ?: throw AppFailure("Unbekannte Quellen-ID in der Modellantwort."))
                    })
                    val invalidSections = draft.items.filter { it.section !in template.sections }.map { it.section }.toSortedSet()
                    draft = draft.copy(items = draft.items.filter { it.section in template.sections })
                    val sectionRepair = if (invalidSections.isEmpty()) "" else
                        " Ungültige section-Werte: " + invalidSections.joinToString(", ") + ". Erlaubt sind ausschließlich: " + sectionNames + "."
                    if (draft.items.isEmpty()) throw AppFailure("Keine gültig zugeordneten Aussagen.$sectionRepair")
                    val candidate = draft.report(transcript.id, template, length, audience)
                    val local = transcript.copy(segments = pending, editedText = pending.joinToString("\n") { it.text })
                    ReportValidator.validate(candidate, local)
                    // Keep only complete, validated source groups. Repair missing groups in isolation,
                    // so a second generation cannot erase facts already covered by the first.
                    val completeIDs = pending.filter { source ->
                        val items = draft.items.filter { it.segmentId == source.id }
                        val text = items.joinToString(" ") { it.text }
                        items.isNotEmpty() && ReportValidator.numbers(text).containsAll(ReportValidator.numbers(source.text)) &&
                            ReportValidator.hasNegation(source.text) == ReportValidator.hasNegation(text)
                    }.map { it.id }.toSet()
                    accepted += draft.items.filter { it.segmentId in completeIDs }
                    missingInformation += draft.missingInformation; conflicts += draft.conflicts
                    pending = pending.filter { TranscriptSourcePolicy.requiresCoverage(it.text) && it.id !in completeIDs }
                    if (pending.isNotEmpty()) {
                        throw AppFailure("Diese Quellen fehlen oder sind unvollständig: " + pending.mapNotNull { aliases[it.id] }.joinToString(", ") + "." + sectionRepair)
                    }
                    result = ModelReportDraft(accepted, missingInformation.toSortedSet().toList(), conflicts.toSortedSet().toList())
                        .report(transcript.id, template, length, audience)
                    break
                } catch (error: AppFailure) {
                    repairNote = "\nKorrektur für den erneuten Versuch: " + error.message + " Gib alle Quellen vollständig wieder."
                    if (attempt == 1) throw AppFailure("Der Bericht konnte auch nach einem Reparaturversuch nicht geprüft werden: ${error.message} Das Transkript bleibt erhalten.")
                }
            }
            result?.let { collected += it }
            if (index + 1 < chunks.size) {
                val partial = merge(collected, transcript, template, length, audience)
                val version = ReportVersion(
                    content = partial, modelID = engine.engineID, modelRevision = engine.engineRevision,
                    warnings = listOf("Unvollständig: ${index + 1} von ${chunks.size} Abschnitten gesichert. Keine Freigabe möglich."),
                )
                checkpoint(ReportCheckpoint(version, index + 1, chunks.size))
            }
        }
        // Merge without another lossy summary; every generated item retains its original source IDs.
        val report = merge(collected, transcript, template, length, audience)
        val warnings = ReportValidator.validate(report, transcript)
        return ReportVersion(content = report, modelID = engine.engineID, modelRevision = engine.engineRevision, warnings = warnings)
    }

    private fun merge(collected: List<StructuredReport>, transcript: TranscriptVersion, template: ReportTemplate, length: ReportLength, audience: Audience) =
        StructuredReport(
            template = template, length = length, audience = audience, sourceTranscriptVersionId = transcript.id,
            sections = template.sections.map { name -> ReportSection(name, collected.flatMap { it.sections }.filter { it.key == name }.flatMap { it.items }) },
            missingInformation = collected.flatMap { it.missingInformation }.toSortedSet().toList(),
            conflicts = collected.flatMap { it.conflicts }.toSortedSet().toList(),
        )
}
