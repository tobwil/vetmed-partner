package de.tobwil.vetmed

import de.tobwil.vetmed.data.ReportExports
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Pagination and file lifecycle on the JVM; the rendered PDF itself is checked in androidTest (PdfDocument needs a device). */
class ReportExportTests {
    @get:Rule val folder = TemporaryFolder()

    @Test fun everyLineLandsOnExactlyOnePageInOrder() {
        val exports = ReportExports(folder.root)
        val tops = IntArray(400) { it * 18 }; val bottoms = IntArray(400) { it * 18 + 16 }
        val pages = exports.paginate(tops, bottoms, 742)
        assertTrue(pages.size > 1)
        assertEquals((0 until 400).toList(), pages.flatMap { it.toList() })
        pages.forEach { page -> assertTrue(bottoms[page.last] - tops[page.first] <= 742) }
        // A single line taller than a page is kept whole rather than dropped.
        assertEquals(listOf(0..0, 1..1), exports.paginate(intArrayOf(0, 900), intArrayOf(900, 920), 742))
        assertEquals(emptyList<IntRange>(), exports.paginate(IntArray(0), IntArray(0), 742))
    }

    @Test fun recentExportsSurviveCleanupButExpiredAndDeletedOnesDoNot() {
        val exports = ReportExports(folder.root)
        val file = exports.file("R1").apply { writeText("%PDF") }
        exports.cleanExpired(now = System.currentTimeMillis())
        assertTrue("a receiving app may still read a fresh export", file.exists())
        exports.cleanExpired(now = System.currentTimeMillis() + ReportExports.MAX_AGE_MILLIS + 60_000)
        assertFalse(file.exists())
        exports.file("R2").writeText("%PDF"); exports.remove(listOf("R2"))
        assertFalse(exports.file("R2").exists())
    }
}
