package de.tobwil.vetmed

import android.app.Application
import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.core.app.ApplicationProvider
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import de.tobwil.vetmed.core.CaseOperations
import de.tobwil.vetmed.core.TranscriptSegment
import de.tobwil.vetmed.core.Wav
import de.tobwil.vetmed.data.AudioSourceFactory
import de.tobwil.vetmed.data.SpeechStatus
import de.tobwil.vetmed.data.Transcriber
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.ui.AccentTheme
import de.tobwil.vetmed.ui.AppearanceMode
import de.tobwil.vetmed.ui.AppearanceStore
import de.tobwil.vetmed.ui.VetMedApp
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Compose UI tests of the real app on Robolectric with synthetic data. With `-PrecordScreenshots`
 * the run also writes the screenshots to docs/evidence/android. This is no substitute for a Pixel 9 test.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w411dp-h923dp-normal-long-notround-port-xxhdpi-keyshidden-nonav")
class WalkthroughTests {
    @get:Rule val compose = createComposeRule()
    @get:Rule val folder = TemporaryFolder()
    private val application: Application = ApplicationProvider.getApplicationContext()
    private val keys = MemoryKeys() to MemoryKeys()

    private fun repository() = testRepository(application, folder.root, keys.first, keys.second)

    private fun launch(
        document: VaultDocument?, mode: AppearanceMode = AppearanceMode.LIGHT, theme: AccentTheme = AccentTheme.KLINIK,
        microphone: AudioSourceFactory = SyntheticMicrophone(0), transcriber: Transcriber = SyntheticTranscriber(),
    ): AppViewModel {
        AppearanceStore(application).apply { this.mode = mode; this.theme = theme }
        if (document != null) runBlocking { repository().save(document) }
        val model = AppViewModel(application, repository(), microphone, transcriber)
        compose.setContent { VetMedApp(model) }
        waitFor("App geöffnet", model) { model.ready.value }
        compose.waitForIdle()
        return model
    }

    private fun waitFor(what: String, model: AppViewModel, condition: () -> Boolean) {
        // View model work resumes from Dispatchers.IO onto Robolectric's paused main looper; drain it while waiting.
        try { compose.waitUntil(20_000) { shadowOf(Looper.getMainLooper()).idle(); condition() } }
        catch (error: Throwable) { throw AssertionError("$what: error=${model.error.value} ready=${model.ready.value} busy=${model.busy.value}", error) }
    }

    private fun shot(name: String) = compose.onRoot().captureRoboImage(
        "../../../docs/evidence/android/$name.png",
        RoborazziOptions(recordOptions = RoborazziOptions.RecordOptions(resizeScale = 0.5)),
    )

    @Test fun startDayShowsDashboardAndRecentWork() {
        launch(SyntheticCases.seed().document)
        compose.onNodeWithText("Diktat aufnehmen").assertIsDisplayed()
        compose.onNodeWithText("Bello · K-2026-014").assertIsDisplayed()
        compose.onAllNodesWithText("Bericht prüfen").onFirst().assertIsDisplayed()
        shot("01-start-tag-klinik")
    }

    @Test fun startNightWithLavenderTheme() {
        launch(SyntheticCases.seed().document, AppearanceMode.DARK, AccentTheme.LAVENDEL)
        compose.onNodeWithContentDescription("Tagmodus").assertIsDisplayed()
        shot("02-start-nacht-lavendel")
    }

    @Test fun casesListAndCaseDetail() {
        val seeded = SyntheticCases.seed()
        launch(seeded.document, theme = AccentTheme.OZEAN)
        compose.onNodeWithTag("tab-cases").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Mia · K-2026-013").assertIsDisplayed()
        shot("03-faelle-ozean")
        compose.onNodeWithTag("case-row-" + seeded.withReport.caseID).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Neues Diktat zu diesem Fall").assertIsDisplayed()
        shot("04-fall-ozean")
    }

    @Test fun transcriptAndReportReview() {
        launch(SyntheticCases.seed().document, AppearanceMode.DARK, AccentTheme.KLINIK)
        compose.onNodeWithText("Bello · K-2026-014").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("workflow-step-1").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("transcript-save-status", useUnmergedTree = true).also {
            runCatching { it.assertIsDisplayed() }.onFailure { error -> throw AssertionError(compose.onRoot(useUnmergedTree = true).printToString(), error) }
        }
        shot("05-diktat-text-nacht")
        compose.onNodeWithTag("workflow-step-2").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Bericht prüfen").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Entwurf · Prüfung erforderlich").assertIsDisplayed()
        shot("06-bericht-pruefen-nacht")
    }

    @Test fun settingsShowAppearanceAndThemes() {
        launch(SyntheticCases.seed().document, theme = AccentTheme.KORALLE)
        compose.onNodeWithContentDescription("Einstellungen").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Farbthema Koralle").assertIsDisplayed()
        shot("07-einstellungen-koralle")
    }

    @Test fun typedTextAutosavesAndSurvivesRelaunch() {
        val model = launch(null)
        compose.onNodeWithText("Diktat aufnehmen").performClick()
        waitFor("Diktat angelegt", model) { model.document.value.cases.isNotEmpty() }
        compose.onNodeWithTag("enter-transcript").performClick()
        compose.waitForIdle()
        val text = "Synthetischer Autosave. Temperatur nicht gemessen."
        compose.onNodeWithTag("transcript-editor").performTextInput(text)
        compose.mainClock.advanceTimeBy(1_500)
        waitFor("Text gespeichert", model) { model.document.value.cases.first().encounters.first().transcripts.isNotEmpty() }
        compose.onNodeWithText("Text gespeichert").assertIsDisplayed()
        // A fresh repository on the same files and keys, like an app restart.
        val reopened = runBlocking { repository().load() }
        assertEquals(text, reopened.cases.single().encounters.single().transcripts.last().editedText)
    }

    @Test fun deletingFromCaseDetailRemovesOnlyThatCase() {
        val seeded = SyntheticCases.seed()
        val model = launch(seeded.document)
        compose.onNodeWithTag("tab-cases").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("case-row-" + seeded.withReport.caseID).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("delete-case-bottom").performClick()
        compose.onNodeWithText("Fall endgültig löschen").performClick()
        waitFor("Fall gelöscht", model) { model.document.value.cases.size == 2 }
        assertTrue(model.document.value.cases.none { it.id == seeded.withReport.caseID })
        assertEquals(2, runBlocking { repository().load() }.cases.size)
    }

    @Test fun chatListSeparatesQuickChecksAndCaseChats() {
        launch(SyntheticCases.seed().document, theme = AccentTheme.LAVENDEL)
        compose.onNodeWithTag("tab-chat").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("OHNE FALL").assertIsDisplayed()
        compose.onNodeWithText("ZU EINEM FALL").assertIsDisplayed()
        compose.onNodeWithText("Allgemeine Frage zur Impfung").assertIsDisplayed()
        shot("08-chats-lavendel")
    }

    @Test fun caseChatRendersFormattedAnswerWithReports() {
        val seeded = SyntheticCases.seed()
        val model = launch(seeded.document, AppearanceMode.DARK, AccentTheme.OZEAN)
        compose.onNodeWithTag("tab-chat").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("chat-row-" + seeded.withReport.encounterID).performClick()
        waitFor("Chat geöffnet", model) { runCatching { compose.onNodeWithText("Mögliche Ursachen").assertIsDisplayed() }.isSuccess }
        compose.onNodeWithTag("chat-scope", useUnmergedTree = true).assertIsDisplayed()
        assertEquals(2, compose.onAllNodesWithText("1 Bericht als Wissen").fetchSemanticsNodes().size)
        compose.onNodeWithTag("copy-answer-" + model.chatContext(de.tobwil.vetmed.core.ChatLocation(seeded.withReport.caseID, seeded.withReport.encounterID))!!.analysisRuns!!.single().id).assertIsDisplayed()
        shot("09-chat-antwort-nacht")
    }

    @Test fun newQuickCheckSavesDraftWithoutCreatingACase() {
        val model = launch(SyntheticCases.seed().document)
        val cases = model.document.value.cases.size
        compose.onNodeWithTag("start-chat").performClick()
        waitFor("Chat angelegt", model) { model.document.value.quickChecks.orEmpty().size == 2 }
        waitFor("Chat geöffnet", model) { runCatching { compose.onNodeWithTag("chat-scope", useUnmergedTree = true).assertIsDisplayed() }.isSuccess }
        compose.onNodeWithText("Was möchtest du besprechen?").assertIsDisplayed()
        compose.onNodeWithTag("sparring-question").performTextInput("Schnellcheck QA synthetisch")
        compose.mainClock.advanceTimeBy(1_000)
        waitFor("Entwurf gespeichert", model) { model.document.value.quickChecks!!.any { it.draft.question == "Schnellcheck QA synthetisch" } }
        compose.onNodeWithText("Lokal gespeichert · KI-Antworten fachlich prüfen").assertIsDisplayed()
        assertEquals(cases, model.document.value.cases.size)
        compose.onNodeWithTag("chat-add-attachment").performClick()
        compose.onNodeWithText("Foto auswählen").assertIsDisplayed()
        compose.onNodeWithText("Datei hinzufügen").assertIsDisplayed()
        shot("10-neuer-chat-anhang")
    }

    @Test fun dictationRecordsSealsAndTranscribesOnDevice() {
        shadowOf(application).grantPermissions(android.Manifest.permission.RECORD_AUDIO)
        val microphone = SyntheticMicrophone(Wav.BYTES_PER_SECOND * 25L)
        val transcriber = SyntheticTranscriber()
        val model = launch(null, theme = AccentTheme.KORALLE, microphone = microphone, transcriber = transcriber)
        compose.onNodeWithText("Diktat aufnehmen").performClick()
        waitFor("Diktat angelegt", model) { model.document.value.cases.isNotEmpty() }
        compose.onNodeWithText("Bereit für dein Diktat").assertIsDisplayed()
        compose.onNodeWithTag("record-audio").performClick()
        // The first 20-second segment is sealed while the microphone keeps running.
        waitFor("Erstes Segment gesichert", model) { model.document.value.cases.single().encounters.single().audio.size == 1 }
        waitFor("Mikrofon geleert", model) { microphone.delivered.get() == Wav.BYTES_PER_SECOND * 25L }
        compose.waitForIdle()
        compose.onNodeWithText("Aufnahme läuft").assertIsDisplayed()
        compose.onNodeWithText("0:25").assertIsDisplayed()
        shot("11-aufnahme-laeuft-koralle")
        compose.onNodeWithTag("finish-dictation").performClick()
        waitFor("Transkript erstellt", model) { model.document.value.cases.single().encounters.single().transcripts.isNotEmpty() }
        val encounter = model.document.value.cases.single().encounters.single()
        assertEquals(listOf(20.0, 5.0), encounter.audio.map { it.duration })
        assertEquals(transcriber.engineName, encounter.transcripts.single().engine)
        assertTrue(microphone.closed.get())
        // Every segment is stored sealed; no plaintext stays in the scratch folder.
        encounter.audio.forEach { segment ->
            val wav = runBlocking { repository().audio(encounter.let { model.document.value.cases.single().id }, encounter.id, segment.id) }
            assertEquals(segment.duration, Wav.duration(Wav.pcm(wav).size.toLong()), 0.001)
        }
        assertTrue(java.io.File(application.noBackupFilesDir, "scratch").listFiles().orEmpty().none { it.extension == "pcm" })
        waitFor("Text im Editor", model) { runCatching { compose.onNodeWithText("Hund 12,5 kg.", substring = true).assertIsDisplayed() }.isSuccess }
        compose.onNodeWithTag("original-recording").performClick()
        compose.waitForIdle()
        shot("12-transkript-mit-aufnahme")
    }

    @Test fun missingGermanSpeechResourcesAreOfferedButNeverDownloadedSilently() {
        val transcriber = SyntheticTranscriber(SpeechStatus.DOWNLOADABLE)
        val model = launch(null, transcriber = transcriber)
        compose.onNodeWithContentDescription("Einstellungen").performClick()
        waitFor("Status geladen", model) { model.speechStatus.value == SpeechStatus.DOWNLOADABLE }
        compose.onNodeWithTag("speech-status", useUnmergedTree = true).performScrollTo()
        compose.onNodeWithText(SpeechStatus.DOWNLOADABLE.title).assertIsDisplayed()
        assertEquals(0, transcriber.installs)
        compose.onNodeWithTag("install-speech").performClick()
        waitFor("Installiert", model) { model.speechStatus.value == SpeechStatus.READY }
        assertEquals(1, transcriber.installs)
    }
}

/** Offline speech recognition stand-in: fixed synthetic sentences per audio segment. */
class SyntheticTranscriber(var current: SpeechStatus = SpeechStatus.READY) : Transcriber {
    var installs = 0
    override val engineName = "Synthetischer Test-Erkenner · offline"
    override suspend fun status() = current
    override suspend fun install(progress: (Int) -> Unit) { installs += 1; progress(100); current = SpeechStatus.READY }
    private var calls = 0
    override suspend fun transcribe(wav: ByteArray, audioID: String): List<TranscriptSegment> {
        Wav.pcm(wav) // Rejects anything that is not the recorder's format.
        calls += 1
        val text = if (calls == 1) "Hund 12,5 kg. Kein Fieber." else "Kontrolle in 3 Tagen."
        return listOf(TranscriptSegment(id = "$audioID-0", text = text, audioID = audioID, startSeconds = 0.0))
    }
}
