package de.tobwil.vetmed.core

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Dose calculator (ADR 0020). Pure arithmetic from the user's own numbers: weight × dose per kg = amount, divided by
 * the strength of the product. The app never suggests a dose and does not know products; dose and strength come from
 * the product information.
 */
object DoseCalculator {
    enum class DoseUnit(val label: String, val toMg: Double) { MG_PER_KG("mg/kg", 1.0), UG_PER_KG("µg/kg", 0.001) }
    enum class Form(val label: String, val strengthUnit: String) { LIQUID("Lösung", "mg/ml"), TABLET("Tablette", "mg je Tablette") }

    data class Result(
        val totalMg: Double,
        /** Millilitres for a liquid, tablets for a tablet. */
        val amount: Double,
        val amountText: String,
        /** The calculation written out, so it can be checked by eye. */
        val steps: List<String>,
        val notes: List<String>,
    )

    private val german = Locale.GERMANY

    /** "12,5", "12.5" and "1,25" are read; anything else is refused instead of guessed. */
    fun number(text: String): Double? {
        val raw = text.trim().replace(" ", "")
        if (!Regex("""\d+(?:[.,]\d+)?""").matches(raw)) return null
        return raw.replace(',', '.').toDoubleOrNull()
    }

    fun format(value: Double, decimals: Int = 2): String {
        val text = String.format(german, "%,.${decimals}f", value)
        return if (text.contains(',')) text.trimEnd('0').trimEnd(',') else text
    }

    fun calculate(weight: String, dose: String, unit: DoseUnit, form: Form, strength: String): Result {
        val kg = number(weight) ?: throw AppFailure("Bitte das Gewicht in kg als Zahl eingeben, z. B. 12,5.")
        val perKg = number(dose) ?: throw AppFailure("Bitte die Dosis pro kg als Zahl eingeben, z. B. 0,1.")
        val per = number(strength) ?: throw AppFailure("Bitte die Stärke des Präparats als Zahl eingeben (${form.strengthUnit}).")
        if (kg <= 0 || kg > 1500) throw AppFailure("Das Gewicht muss zwischen 0 und 1.500 kg liegen.")
        if (perKg <= 0) throw AppFailure("Die Dosis muss größer als 0 sein.")
        if (per <= 0) throw AppFailure("Die Stärke muss größer als 0 sein.")
        val totalMg = kg * perKg * unit.toMg
        val amount = totalMg / per
        val doseText = "${format(kg)} kg × ${format(perKg, 3)} ${unit.label}"
        val mgText = if (totalMg < 0.1) "${format(totalMg * 1000, 1)} µg" else "${format(totalMg, if (totalMg < 1) 3 else 2)} mg"
        val steps = mutableListOf("$doseText = $mgText")
        val notes = mutableListOf<String>()
        val amountText: String
        when (form) {
            Form.LIQUID -> {
                amountText = "${format(amount, if (amount < 0.1) 3 else 2)} ml"
                steps += "${format(totalMg, 3)} mg ÷ ${format(per, 3)} mg/ml = $amountText"
                if (amount < 0.1) notes += "Sehr kleine Menge: genau abmessen ist schwierig. Eine passende Spritze oder eine Verdünnung nach Fachinformation erwägen."
                if (amount > 50) notes += "Große Menge. Bitte Konzentration und Einheit noch einmal prüfen."
            }
            Form.TABLET -> {
                val quarters = (amount * 4).roundToInt()
                amountText = "${format(amount, 2)} ${if (amount == 1.0) "Tablette" else "Tabletten"}"
                steps += "${format(totalMg, 3)} mg ÷ ${format(per, 3)} mg je Tablette = $amountText"
                if (quarters == 0) notes += "Weniger als eine Vierteltablette: eine Tablette ist für dieses Gewicht zu stark."
                else {
                    val rounded = quarters / 4.0
                    val deviation = ((rounded - amount) / amount * 100).roundToInt()
                    if (abs(rounded - amount) > 1e-9) notes += "Auf Vierteltabletten gerundet: ${tablets(quarters)} (${if (deviation >= 0) "+" else ""}$deviation % gegenüber der berechneten Menge). Ob die Tablette teilbar ist, steht in der Fachinformation."
                }
            }
        }
        if (unit == DoseUnit.MG_PER_KG && perKg > 100) notes += "Ungewöhnlich hohe Dosis pro kg. Bitte die Einheit prüfen (mg oder µg)."
        return Result(totalMg, amount, amountText, steps, notes)
    }

    private fun tablets(quarters: Int): String {
        val whole = quarters / 4
        val part = when (quarters % 4) { 1 -> "¼"; 2 -> "½"; 3 -> "¾"; else -> "" }
        val number = when { whole == 0 -> part; part.isEmpty() -> "$whole"; else -> "$whole $part" }
        return "$number ${if (quarters == 4) "Tablette" else "Tabletten"}"
    }
}

/**
 * Fixed warning rules (ADR 0020): a short, closed list of well-known dangers, written out and checked by tests. No
 * language model decides here. A missing warning never means that a drug is safe.
 */
object DrugRules {
    enum class Severity(val label: String) { STOP("Nicht geben"), CAUTION("Vorsicht"), INFO("Hinweis") }
    enum class Mdr1(val label: String) { UNKNOWN("Unbekannt"), NORMAL("Kein Defekt"), DEFECT("Defekt nachgewiesen") }
    data class Warning(val severity: Severity, val title: String, val text: String)

    const val DISCLAIMER = "Feste Regeln der App für bekannte Gefahren. Sie ersetzen keine Fachinformation. Fehlt eine Warnung, heißt das nicht, dass das Mittel unbedenklich ist."

    enum class Species { DOG, CAT, OTHER }
    fun species(text: String): Species {
        val value = text.lowercase()
        return when {
            listOf("katze", "kater", "kätzchen", "cat", "feline").any { value.contains(it) } -> Species.CAT
            listOf("hund", "hündin", "welpe", "dog", "canine").any { value.contains(it) } -> Species.DOG
            else -> Species.OTHER
        }
    }

    private fun mentions(drug: String, names: List<String>): String? {
        val text = drug.lowercase()
        return names.firstOrNull { Regex("""(?<!\p{L})${Regex.escape(it)}""").containsMatchIn(text) }
    }

    private val paracetamol = listOf("paracetamol", "acetaminophen")
    private val permethrin = listOf("permethrin")
    /** Macrocyclic lactones and other substrates of P-glycoprotein with known neurotoxicity in ABCB1 (MDR1) defects. */
    private val mdr1 = listOf(
        "ivermectin", "doramectin", "moxidectin", "milbemycin", "selamectin", "eprinomectin", "abamectin", "emodepsid",
        "loperamid", "acepromazin", "butorphanol", "vincristin", "vinblastin", "doxorubicin",
    )
    private val nsaids = listOf(
        "meloxicam", "carprofen", "robenacoxib", "firocoxib", "cimicoxib", "mavacoxib", "deracoxib", "ketoprofen", "phenylbutazon",
        "flunixin", "tolfenamin", "diclofenac", "ibuprofen", "naproxen", "acetylsalicyl", "aspirin",
    )
    private val humanNsaids = listOf("ibuprofen", "naproxen", "diclofenac")
    /** Kreatinin and SDMA by name; "Kreatinkinase" (CK) must not count, so names are matched exactly or by full stem. */
    fun isKidneyMarker(parameter: String): Boolean {
        val letters = parameter.lowercase().filter { it.isLetter() }
        return letters in setOf("crea", "krea", "sdma") || letters.startsWith("kreatinin") || letters.startsWith("creatinin") ||
            letters.startsWith("sdma") || letters.startsWith("symmetrischesdimethylarginin")
    }

    /** The newest confirmed value of each kidney marker in the case that the app assesses as high, written out. */
    fun highKidneyValues(document: VaultDocument, caseID: String?): List<String> =
        LabTrend.series(document, caseID, minimumPoints = 1).filter { isKidneyMarker(it.parameter) }.mapNotNull { series ->
            val point = series.points.last()
            if (point.assessment != LabAssessment.HIGH) null
            else "${series.parameter} ${point.raw} ${series.unit}".trim() + (if (point.reference.isEmpty()) "" else " (Ref. ${point.reference})") + " am ${point.label}"
        }

    fun hasKidneyValues(document: VaultDocument, caseID: String?): Boolean =
        LabTrend.series(document, caseID, minimumPoints = 1).any { isKidneyMarker(it.parameter) }

    fun warnings(drug: String, speciesText: String, mdr1Status: Mdr1, document: VaultDocument = VaultDocument(), caseID: String? = null): List<Warning> {
        if (drug.isBlank()) return emptyList()
        val species = species(speciesText)
        val warnings = mutableListOf<Warning>()
        if (species == Species.CAT) {
            mentions(drug, paracetamol)?.let {
                warnings += Warning(Severity.STOP, "Paracetamol ist für Katzen giftig", "Schon kleine Mengen können Methämoglobinämie und Leberschäden auslösen.")
            }
            mentions(drug, permethrin)?.let {
                warnings += Warning(Severity.STOP, "Permethrin ist für Katzen giftig", "Es kann Muskelzittern und Krampfanfälle auslösen. Permethrinhaltige Hundepräparate nie bei Katzen anwenden, auch nicht bei engem Kontakt frisch behandelter Hunde.")
            }
        }
        if (species == Species.DOG) mentions(drug, mdr1)?.let { name ->
            when (mdr1Status) {
                Mdr1.DEFECT -> warnings += Warning(Severity.CAUTION, "MDR1-Defekt und ${name.replaceFirstChar { it.uppercase() }}",
                    "Bei einem Defekt im ABCB1-Gen (MDR1) kann der Wirkstoff ins Gehirn gelangen und neurotoxisch wirken. Fachinformation zu MDR1 beachten, Dosis und Alternative prüfen.")
                Mdr1.UNKNOWN -> warnings += Warning(Severity.INFO, "MDR1-Status unbekannt",
                    "${name.replaceFirstChar { it.uppercase() }} kann bei einem MDR1-Defekt neurotoxisch wirken. Betroffen sind vor allem Collie, Australian Shepherd, Sheltie, Weißer Schäferhund und Mischlinge dieser Rassen.")
                Mdr1.NORMAL -> {}
            }
        }
        val nsaid = mentions(drug, nsaids)
        if (nsaid != null) {
            if (species != Species.OTHER && mentions(drug, humanNsaids) != null) {
                warnings += Warning(Severity.CAUTION, "Humanes NSAID ${if (species == Species.CAT) "bei der Katze" else "beim Hund"}",
                    "${nsaid.replaceFirstChar { it.uppercase() }} hat bei Hund und Katze eine geringe therapeutische Breite: Magen-Darm-Geschwüre und Nierenschäden sind schon bei üblichen Humandosen beschrieben.")
            }
            val high = highKidneyValues(document, caseID)
            if (high.isNotEmpty()) {
                warnings += Warning(Severity.CAUTION, "Nierenwert über dem Referenzbereich",
                    high.joinToString("; ") + ". NSAIDs können die Nierenfunktion weiter verschlechtern. Nutzen und Risiko abwägen, Fachinformation beachten.")
            } else if (caseID != null && !hasKidneyValues(document, caseID)) {
                warnings += Warning(Severity.INFO, "Kein bestätigter Nierenwert im Fall", "Für NSAIDs ist die Nierenfunktion wichtig. Im Fall liegt kein bestätigter Kreatinin- oder SDMA-Wert vor.")
            }
        }
        return warnings.sortedBy { it.severity.ordinal }
    }
}

/** Confirmed lab values of one case over time (ADR 0020), for the course chart and the kidney rule. */
object LabTrend {
    data class Point(
        val date: LocalDate?,
        /** Sample date as printed, or the confirmation day when none is printed. */
        val label: String,
        val value: Double,
        val raw: String,
        val reference: String,
        val range: LabMath.Range?,
        val assessment: LabAssessment,
        val attachmentID: String,
    )
    data class Series(val parameter: String, val unit: String, val points: List<Point>) {
        /** The printed range of the newest value, if it has both bounds; used for the shaded band. */
        val band: LabMath.Range? get() = points.last().range?.takeIf { it.low != null && it.high != null }
    }

    private val formats = listOf("d.M.yyyy", "d.M.yy", "yyyy-MM-dd").map { DateTimeFormatter.ofPattern(it) }
    fun date(text: String): LocalDate? {
        val token = Regex("""\d{1,4}[.\-]\d{1,2}[.\-]\d{2,4}""").find(text)?.value ?: return null
        return formats.firstNotNullOfOrNull { runCatching { LocalDate.parse(token, it) }.getOrNull() }
    }

    /**
     * Numeric, confirmed values of the case grouped by parameter and unit (like [LabHistory]), oldest first. Values
     * such as "< 0,1" or "positiv" are left out because they cannot be drawn.
     */
    fun series(document: VaultDocument, caseID: String?, minimumPoints: Int = 2): List<Series> {
        val item = document.cases.firstOrNull { it.id == caseID } ?: return emptyList()
        data class Raw(val point: Point, val parameter: String, val unit: String, val confirmed: java.time.Instant)
        val raw = item.encounters.flatMap { it.chatAttachments.orEmpty() }.filter { it.lab?.confirmedAt != null }.flatMap { attachment ->
            val lab = attachment.lab!!
            val date = date(lab.sampleDate)
            val label = if (date != null) lab.sampleDate.trim() else lab.confirmedAt!!.germanDateTime().substringBefore(",")
            lab.values.mapNotNull { value ->
                val number = LabMath.number(value.value) ?: return@mapNotNull null
                Raw(Point(date ?: lab.confirmedAt!!.atZone(java.time.ZoneId.systemDefault()).toLocalDate(), label, number, value.value, value.reference,
                    LabMath.reference(value.reference), value.assessment, attachment.id), value.parameter.trim(), value.unit.trim(), lab.confirmedAt!!)
            }
        }
        return raw.groupBy { LabHistory.key(it.parameter, it.unit) }.values
            .map { group ->
                val sorted = group.sortedWith(compareBy<Raw>({ it.point.date }, { it.confirmed }))
                Series(sorted.last().parameter, sorted.last().unit, sorted.map { it.point })
            }
            .filter { it.points.size >= minimumPoints }
            .sortedBy { it.parameter.lowercase() }
    }
}
