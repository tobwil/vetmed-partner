package de.tobwil.vetmed.core

import kotlinx.serialization.Serializable
import java.net.URI

/** A web source the provider cited for an answer. Only shown and checked locally, never sent back. */
@Serializable
data class AnswerSource(val url: String, val title: String? = null)

/**
 * Guard rails for medication statements in the sparring chat. Language models confuse trade names and active
 * substances from memory; the prompt forbids that, and the app additionally marks every answer that talks about
 * medication without an official source, so a wrong statement cannot look verified.
 */
object MedicationSafety {
    /** Official sources for veterinary medicines in the EU, Germany and Austria. Web search is limited to these. */
    val OFFICIAL_DOMAINS = listOf(
        "medicines.health.europa.eu", // EU Union Product Database, public part
        "ema.europa.eu",
        "pharmnet-bund.de",
        "bvl.bund.de",
        "aspregister.basg.gv.at",
    )
    const val DATABASE_URL = "https://medicines.health.europa.eu/veterinary/de/search-medicines"
    const val WARNING = "Arzneimittelangaben ohne amtlichen Beleg. Wirkstoffe, Zusammensetzung und Dosierung vor jeder Anwendung in der Fachinformation prüfen."

    private val words = Regex(
        """(?iu)(?<![\p{L}\p{N}])(wirkstoff\p{L}*|präparat\p{L}*|praeparat\p{L}*|arzneimittel\p{L}*|tierarzneimittel\p{L}*|medikament\p{L}*|""" +
            """zusammensetzung|enthält|enthalten|dosier\p{L}*|dosis|dosen|tablette\p{L}*|kautablette\p{L}*|injektion\p{L}*|""" +
            """spot-on|suspension|salbe|tropfen|fachinformation|beipackzettel|packungsbeilage|wartezeit\p{L}*|""" +
            """kontraindikation\p{L}*|gegenanzeige\p{L}*|wechselwirkung\p{L}*|nebenwirkung\p{L}*|handelsname\p{L}*)(?![\p{L}\p{N}])""",
    )
    /** Typical endings of active substance names (INN), so "Präparat: Fluralaner" is caught without a keyword. */
    private val substances = Regex("""(?iu)(?<![\p{L}])\p{L}{2,}(?:xicam|profen|coxib|oxacin|mectin|mycin|cyclin|cillin|laner|citinib|tinib|lokivetmab|bedinvetmab|pril|sartan|thrin|quantel|pyrantel|febantel|azol|azole|methason|metason|azepam|zolam|pimobendan|fipronil|imidacloprid|maropitant|gabapentin|tramadol|metamizol|ketamin|medetomidin|butorphanol|furosemid|spironolacton|methopren|selamectin)(?![\p{L}])""")
    private val doses = Regex("""(?iu)\d+(?:[.,]\d+)?\s?(?:mg|µg|μg|mcg|ie|i\.\s?e\.)(?:\s?/\s?(?:kg|ml|tablette|tier))?(?![\p{L}])""")

    /** True when an answer names medication, composition or doses. Errs on the side of warning. */
    fun mentionsMedication(text: String): Boolean = words.containsMatchIn(text) || doses.containsMatchIn(text) || substances.containsMatchIn(text)

    fun isOfficial(url: String): Boolean {
        val host = runCatching { URI(url).host }.getOrNull()?.lowercase()?.removePrefix("www.") ?: return false
        if (runCatching { URI(url).scheme }.getOrNull()?.lowercase() != "https") return false
        return OFFICIAL_DOMAINS.any { host == it || host.endsWith(".$it") }
    }

    fun officialSources(run: AnalysisRun): List<AnswerSource> = run.sources.orEmpty().filter { isOfficial(it.url) }

    /** A warning is shown unless the answer has no medication content or cites at least one official source. */
    fun needsWarning(run: AnalysisRun): Boolean = mentionsMedication(run.text) && officialSources(run).isEmpty()

    /** The final block of the system instructions; tells the model what it can and cannot rely on. */
    fun instructions(base: String, sourceSearch: Boolean): String = base.trimEnd() + "\n\n# Quellenlage für diese Anfrage\n" + if (sourceSearch) {
        "Quellensuche: aktiviert, beschränkt auf amtliche Arzneimittelquellen (" + OFFICIAL_DOMAINS.joinToString(", ") + "). " +
            "Belege präparatbezogene Angaben ausschließlich mit Treffern dieser Suche und nenne die Quelle direkt bei der Angabe. " +
            "Findest du keinen passenden Treffer, sage das und nenne keine Zusammensetzung."
    } else {
        "Quellensuche: nicht aktiviert. Du hast für diese Anfrage keinen Zugriff auf Fachinformationen, Datenbanken oder das Internet. " +
            "Präparatbezogene Angaben sind deshalb nur aus mitgesendeten Angaben oder Anhängen möglich."
    }

    /** Web search tool for the OpenAI Responses API, limited to official domains. */
    fun openAITool() = kotlinx.serialization.json.buildJsonObject {
        put("type", kotlinx.serialization.json.JsonPrimitive("web_search"))
        put("filters", kotlinx.serialization.json.buildJsonObject {
            put("allowed_domains", kotlinx.serialization.json.JsonArray(OFFICIAL_DOMAINS.map { kotlinx.serialization.json.JsonPrimitive(it) }))
        })
    }
}
