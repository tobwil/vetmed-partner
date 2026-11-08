package de.tobwil.vetmed.core

import de.tobwil.vetmed.core.DoseCalculator.DoseUnit
import de.tobwil.vetmed.core.DoseCalculator.Form
import de.tobwil.vetmed.core.DrugRules.Mdr1
import de.tobwil.vetmed.core.DrugRules.Severity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

/** Dose calculator, fixed warning rules and lab course (ADR 0020). Synthetic numbers only, no dosing advice. */
class DosingTests {
    private fun failsWith(text: String, block: () -> Unit) {
        try { block(); fail("must fail: $text") } catch (error: AppFailure) { assertTrue(error.message, error.message!!.contains(text)) }
    }

    @Test fun liquidDoseIsCalculatedAndWrittenOut() {
        val result = DoseCalculator.calculate("12,5", "0,1", DoseUnit.MG_PER_KG, Form.LIQUID, "1,5")
        assertEquals(1.25, result.totalMg, 1e-9)
        assertEquals(0.8333, result.amount, 1e-4)
        assertEquals("0,83 ml", result.amountText)
        assertEquals(listOf("12,5 kg × 0,1 mg/kg = 1,25 mg", "1,25 mg ÷ 1,5 mg/ml = 0,83 ml"), result.steps)
        assertTrue(result.notes.isEmpty())
    }

    @Test fun microgramsAndVerySmallVolumesAreSaid() {
        val result = DoseCalculator.calculate("4", "10", DoseUnit.UG_PER_KG, Form.LIQUID, "0,5")
        assertEquals(0.04, result.totalMg, 1e-9)
        assertEquals("4 kg × 10 µg/kg = 40 µg", result.steps.first())
        assertEquals("0,08 ml", result.amountText)
        assertTrue(result.notes.single().startsWith("Sehr kleine Menge"))
    }

    @Test fun tabletsAreRoundedToQuartersOnlyAsAHint() {
        val result = DoseCalculator.calculate("30", "4", DoseUnit.MG_PER_KG, Form.TABLET, "50")
        assertEquals("2,4 Tabletten", result.amountText)
        assertEquals("Auf Vierteltabletten gerundet: 2 ½ Tabletten (+4 % gegenüber der berechneten Menge). Ob die Tablette teilbar ist, steht in der Fachinformation.", result.notes.single())
        assertEquals("1 Tablette", DoseCalculator.calculate("10", "5", DoseUnit.MG_PER_KG, Form.TABLET, "50").amountText)
        assertTrue(DoseCalculator.calculate("10", "5", DoseUnit.MG_PER_KG, Form.TABLET, "50").notes.isEmpty())
        assertTrue(DoseCalculator.calculate("2", "1", DoseUnit.MG_PER_KG, Form.TABLET, "20").notes.single().contains("zu stark"))
    }

    @Test fun nonsenseIsRefusedAndUnitMixUpsAreFlagged() {
        failsWith("Gewicht") { DoseCalculator.calculate("zwölf", "0,1", DoseUnit.MG_PER_KG, Form.LIQUID, "1,5") }
        failsWith("Gewicht") { DoseCalculator.calculate("-3", "0,1", DoseUnit.MG_PER_KG, Form.LIQUID, "1,5") }
        failsWith("1.500 kg") { DoseCalculator.calculate("2000", "0,1", DoseUnit.MG_PER_KG, Form.LIQUID, "1,5") }
        failsWith("größer als 0") { DoseCalculator.calculate("10", "0", DoseUnit.MG_PER_KG, Form.LIQUID, "1,5") }
        failsWith("Stärke") { DoseCalculator.calculate("10", "1", DoseUnit.MG_PER_KG, Form.LIQUID, "") }
        assertTrue(DoseCalculator.calculate("10", "200", DoseUnit.MG_PER_KG, Form.LIQUID, "100").notes.any { it.contains("Einheit prüfen") })
    }

    @Test fun catsGetStopWarningsForParacetamolAndPermethrin() {
        val paracetamol = DrugRules.warnings("Paracetamol 500 mg", "Katze", Mdr1.UNKNOWN).single()
        assertEquals(Severity.STOP, paracetamol.severity); assertTrue(paracetamol.title.contains("Katzen giftig"))
        assertEquals(Severity.STOP, DrugRules.warnings("Permethrin Spot-on", "Kater, EKH", Mdr1.UNKNOWN).single().severity)
        // Same drugs for a dog: no rule here (that is no statement that they are safe).
        assertTrue(DrugRules.warnings("Paracetamol", "Hund", Mdr1.UNKNOWN).isEmpty())
        assertTrue(DrugRules.warnings("Permethrin", "Hund", Mdr1.UNKNOWN).isEmpty())
    }

    @Test fun macrocyclicLactonesDependOnTheMdr1Status() {
        assertEquals(Severity.CAUTION, DrugRules.warnings("Ivermectin", "Hund", Mdr1.DEFECT).single().severity)
        assertEquals(Severity.INFO, DrugRules.warnings("Milbemycinoxim + Praziquantel", "Hund (Collie)", Mdr1.UNKNOWN).single().severity)
        assertTrue(DrugRules.warnings("Ivermectin", "Hund", Mdr1.NORMAL).isEmpty())
        assertTrue(DrugRules.warnings("Ivermectin", "Katze", Mdr1.DEFECT).isEmpty())
        assertTrue(DrugRules.warnings("Loperamid", "Hündin", Mdr1.DEFECT).single().title.contains("Loperamid"))
    }

    private fun lab(id: String, sampleDate: String, confirmedAt: Long?, vararg values: LabValue) = ChatAttachment(
        id = id, kind = AttachmentKind.DOCUMENT, originalName = "$id.pdf", originalExtension = "pdf", originalByteCount = 1, originalSHA256 = id,
        lab = LabReport(sampleDate = sampleDate, values = values.toList(), method = "Synthetisch", confirmedAt = confirmedAt?.let { Instant.ofEpochSecond(it) }),
    )
    private fun case(vararg attachments: ChatAttachment) =
        VaultDocument(cases = listOf(VetCase(id = "C", label = "Synthetisch", species = "Hund", encounters = listOf(Encounter(chatAttachments = attachments.toList())))))

    @Test fun nsaidsAreCheckedAgainstConfirmedKidneyValuesOfTheCase() {
        val high = case(lab("a", "01.10.2026", 1_790_000_000, LabValue(parameter = "Kreatinin", value = "180", unit = "µmol/l", reference = "40 - 130")))
        val warning = DrugRules.warnings("Meloxicam 1,5 mg/ml", "Hund", Mdr1.UNKNOWN, high, "C").single()
        assertEquals(Severity.CAUTION, warning.severity)
        assertTrue(warning.text, warning.text.startsWith("Kreatinin 180 µmol/l (Ref. 40 - 130) am 01.10.2026."))
        // Normal value: no warning. Creatine kinase is no kidney value. An unconfirmed report does not count.
        val normal = case(lab("a", "01.10.2026", 1_790_000_000, LabValue(parameter = "Kreatinin", value = "90", unit = "µmol/l", reference = "40 - 130")))
        assertTrue(DrugRules.warnings("Carprofen", "Hund", Mdr1.UNKNOWN, normal, "C").isEmpty())
        val ck = case(lab("a", "01.10.2026", 1_790_000_000, LabValue(parameter = "Kreatinkinase", value = "900", unit = "U/l", reference = "10 - 200")))
        assertEquals(Severity.INFO, DrugRules.warnings("Carprofen", "Hund", Mdr1.UNKNOWN, ck, "C").single().severity)
        val unconfirmed = case(lab("a", "01.10.2026", null, LabValue(parameter = "Kreatinin", value = "180", unit = "µmol/l", reference = "40 - 130")))
        assertTrue(DrugRules.warnings("Carprofen", "Hund", Mdr1.UNKNOWN, unconfirmed, "C").single().title.startsWith("Kein bestätigter Nierenwert"))
        // Without a case there is nothing to check against.
        assertTrue(DrugRules.warnings("Carprofen", "Hund", Mdr1.UNKNOWN).isEmpty())
        // Human NSAIDs are flagged for dogs and cats.
        assertEquals("Humanes NSAID beim Hund", DrugRules.warnings("Ibuprofen 400", "Hund", Mdr1.UNKNOWN).single().title)
        // Newest value decides: high then normal again → no warning.
        val recovered = case(
            lab("a", "01.10.2026", 1_790_000_000, LabValue(parameter = "Kreatinin", value = "180", unit = "µmol/l", reference = "40 - 130")),
            lab("b", "15.10.2026", 1_790_100_000, LabValue(parameter = "Kreatinin", value = "110", unit = "µmol/l", reference = "40 - 130")),
        )
        assertTrue(DrugRules.warnings("Meloxicam", "Hund", Mdr1.UNKNOWN, recovered, "C").isEmpty())
    }

    @Test fun labCourseIsOrderedBySampleDateAndKeepsOnlyDrawableValues() {
        val document = case(
            // Confirmed later, but the sample is older: the sample date decides the order.
            lab("b", "15.10.2026", 1_790_000_000, LabValue(parameter = "Kreatinin", value = "150", unit = "µmol/l", reference = "40 - 130"),
                LabValue(parameter = "CRP", value = "< 0,1", unit = "mg/dl")),
            lab("a", "01.10.2026", 1_790_100_000, LabValue(parameter = "kreatinin", value = "120", unit = "µmol/l", reference = "40 - 130"),
                LabValue(parameter = "Kreatinin", value = "1,4", unit = "mg/dl", reference = "0,5 - 1,5")),
            lab("c", "20.10.2026", null, LabValue(parameter = "Kreatinin", value = "999", unit = "µmol/l")),
        )
        val series = LabTrend.series(document, "C")
        assertEquals(1, series.size)
        val creatinine = series.single()
        assertEquals("Kreatinin", creatinine.parameter); assertEquals("µmol/l", creatinine.unit)
        assertEquals(listOf(120.0, 150.0), creatinine.points.map { it.value })
        assertEquals(listOf(LocalDate.of(2026, 10, 1), LocalDate.of(2026, 10, 15)), creatinine.points.map { it.date })
        assertEquals(listOf(LabAssessment.NORMAL, LabAssessment.HIGH), creatinine.points.map { it.assessment })
        assertEquals(40.0, creatinine.band!!.low!!, 0.0); assertEquals(130.0, creatinine.band!!.high!!, 0.0)
        // Single values count for the kidney rule; "< 0,1" cannot be drawn and is left out.
        assertEquals(2, LabTrend.series(document, "C", minimumPoints = 1).size)
        assertEquals(LocalDate.of(2026, 1, 5), LabTrend.date("Probe vom 5.1.26"))
    }
}
