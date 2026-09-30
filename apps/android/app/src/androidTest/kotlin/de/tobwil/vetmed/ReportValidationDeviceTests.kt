package de.tobwil.vetmed

import androidx.test.ext.junit.runners.AndroidJUnit4
import de.tobwil.vetmed.core.ReportValidator
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Exercise Android ICU itself: JVM/Robolectric accept flags that crash this screen on Android. */
@RunWith(AndroidJUnit4::class)
class ReportValidationDeviceTests {
    @Test fun transcriptNumbersInitializeOnAndroidAndKeepUnicodeDigits() {
        assertEquals(emptySet<String>(), ReportValidator.numbers(""))
        assertEquals(setOf("12.5", "٣.٥"), ReportValidator.numbers("Hund 12,5 kg; ٣,٥; x7"))
    }
    @Test fun unitsKeepUnicodeBoundariesAndCase() {
        assertEquals(setOf("kg", "µg/kg", "μg/kg", "°c"), ReportValidator.units("12 KG; 3 µg/kg; 4 μg/kg; 38 °C; äkg"))
    }
    @Test fun comparisonsKeepSignsAndUnicodeWhitespace() {
        assertEquals(setOf("≤12.5", ">\u00a0٣"), ReportValidator.comparisons("≤ 12,5; >\u00a0٣"))
    }
    @Test fun negationKeepsUnicodeWordBoundaries() {
        listOf("KEIN Fieber", "keinerlei", "ohne", "verneint", "nicht", "kein\u0308").forEach { assertTrue(it, ReportValidator.hasNegation(it)) }
        listOf("irgendkeine", "äkein", "nichtä", "ohne\u0308", "\u0308kein").forEach { assertFalse(it, ReportValidator.hasNegation(it)) }
    }
}
