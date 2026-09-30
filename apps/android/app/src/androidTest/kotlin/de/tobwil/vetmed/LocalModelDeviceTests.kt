package de.tobwil.vetmed

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import de.tobwil.vetmed.core.ModelStore
import de.tobwil.vetmed.core.ReportLength
import de.tobwil.vetmed.core.ReportPipeline
import de.tobwil.vetmed.core.ReportTemplate
import de.tobwil.vetmed.core.ReportValidator
import de.tobwil.vetmed.core.TranscriptBuilder
import de.tobwil.vetmed.data.LocalReportModel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Device acceptance for the real Gemma 4 E2B on LiteRT-LM. Install the model in the app's settings first; without it
 * the test is skipped, never downloaded. Synthetic transcript only.
 */
@RunWith(AndroidJUnit4::class)
class LocalModelDeviceTests {
    @Test fun gemmaWritesAVerifiableReportOnThisDevice() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.app.Application>()
        val model = LocalReportModel(ModelStore(File(context.noBackupFilesDir, "models")), File(context.cacheDir, "litertlm"), readiness = LocalReportModel.readiness(context))
        assumeTrue("Offline-Modell nicht installiert", model.installed.value)
        val transcript = TranscriptBuilder.edited("Hund 12,5 kg. Kein Fieber. Lahmheit hinten links. Kontrolle in 3 Tagen.", previous = null)
        val started = System.nanoTime()
        model.load()
        val report = ReportPipeline(model).run(transcript, ReportTemplate.TREATMENT_REPORT, ReportLength.SHORT, ReportTemplate.TREATMENT_REPORT.audience)
        val seconds = (System.nanoTime() - started) / 1e9
        model.unload()
        android.util.Log.i("VetMedDeviceQA", "Gemma-Bericht in %.1f s: %s".format(seconds, report.content.text))
        assertEquals(model.engineID, report.modelID)
        assertTrue(ReportValidator.numbers(report.content.text).containsAll(setOf("12.5", "3")))
        assertTrue(ReportValidator.hasNegation(report.content.text))
    }
}
