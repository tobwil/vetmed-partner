package de.tobwil.vetmed

import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import de.tobwil.vetmed.core.Audience
import de.tobwil.vetmed.core.ReportLength
import de.tobwil.vetmed.core.ReportTemplate
import de.tobwil.vetmed.core.ReportVersion
import de.tobwil.vetmed.core.StructuredReport
import de.tobwil.vetmed.data.ReportExports
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Device-only: PdfDocument and PdfRenderer need the real graphics stack. */
@RunWith(AndroidJUnit4::class)
class ReportPdfDeviceTests {
    @Test fun longReportKeepsDraftMarkingAndLastLine() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val text = (1..400).joinToString("\n") { "Zeile $it: Kein Fieber. 12,5 kg." } + "\nENDE-DES-TESTBERICHTS"
        val report = ReportVersion(
            content = StructuredReport(template = ReportTemplate.TREATMENT_REPORT, length = ReportLength.SHORT, audience = Audience.VETERINARIAN,
                sourceTranscriptVersionId = "x", sections = emptyList(), missingInformation = emptyList(), conflicts = emptyList()),
            editedText = text, modelID = "synthetic", modelRevision = "synthetic", warnings = emptyList(),
        )
        val exports = ReportExports(File(context.cacheDir, "exports-test"))
        val pdf = exports.pdf(report)
        assertEquals("%PDF", pdf.readBytes().copyOfRange(0, 4).decodeToString())
        PdfRenderer(ParcelFileDescriptor.open(pdf, ParcelFileDescriptor.MODE_READ_ONLY)).use { renderer ->
            assertTrue(renderer.pageCount > 1)
            if (android.os.Build.VERSION.SDK_INT >= 35) {
                val first = renderer.openPage(0).use { page -> page.textContents.joinToString { it.text } }
                val last = renderer.openPage(renderer.pageCount - 1).use { page -> page.textContents.joinToString { it.text } }
                assertTrue(first.contains("ENTWURF")); assertTrue(last.contains("ENDE-DES-TESTBERICHTS"))
            }
        }
        exports.remove(listOf(report.id))
    }
}
