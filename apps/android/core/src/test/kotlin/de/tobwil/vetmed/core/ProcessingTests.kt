package de.tobwil.vetmed.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Online first, never a silent switch (ADR 0014). */
class ProcessingTests {
    private val configured = OnlineReportConfiguration("gemini-3.6-flash", Instant.now(), ReportExecutionMode.ONLINE, provider = OnlineProvider.GEMINI)

    @Test fun transcriptionIsOnlineOnlyWithKeyAndAnExplicitYes() {
        val undecided = GeminiTranscriptionConfiguration()
        assertEquals(ProcessingRoute.DEVICE, Processing.transcription(configured, undecided, hasGeminiKey = false))
        assertEquals(ProcessingRoute.ASK, Processing.transcription(configured, undecided, hasGeminiKey = true))
        assertEquals(ProcessingRoute.ASK, Processing.transcription(OnlineReportConfiguration(), undecided, hasGeminiKey = true))
        assertEquals(ProcessingRoute.ONLINE, Processing.transcription(configured, undecided.copy(enabled = true, decidedAt = Instant.now()), true))
        assertEquals(ProcessingRoute.DEVICE, Processing.transcription(configured, undecided.copy(enabled = false, decidedAt = Instant.now()), true))
    }

    @Test fun deviceOnlyOverridesEveryOnlineDefault() {
        val deviceOnly = configured.copy(deviceOnly = true)
        assertEquals(ProcessingRoute.DEVICE, Processing.transcription(deviceOnly, GeminiTranscriptionConfiguration(enabled = true, decidedAt = Instant.now()), true))
        assertEquals(ProcessingRoute.DEVICE, Processing.transcription(deviceOnly, GeminiTranscriptionConfiguration(), true))
        assertEquals(ReportExecutionMode.OFFLINE, Processing.reportMode(deviceOnly, hasKey = true))
        assertTrue(Processing.summary(deviceOnly, true, ProcessingRoute.DEVICE).startsWith("Nur auf dem Gerät"))
    }

    @Test fun reportsDefaultToOnlineOnceAnAccessIsConfigured() {
        assertEquals(ReportExecutionMode.ONLINE, Processing.reportMode(configured, hasKey = true))
        assertEquals(ReportExecutionMode.OFFLINE, Processing.reportMode(configured, hasKey = false))
        assertEquals(ReportExecutionMode.OFFLINE, Processing.reportMode(OnlineReportConfiguration(), hasKey = true))
        assertTrue(Processing.summary(configured, true, ProcessingRoute.ASK).contains("einmaliger Zustimmung"))
        assertTrue(Processing.summary(OnlineReportConfiguration(), false, ProcessingRoute.DEVICE).startsWith("Kein Online-Zugang"))
    }

    @Test fun storesFromEarlierVersionsAreAskedOnceInsteadOfSwitchedSilently() {
        // Written before ADR 0014: no decidedAt, no deviceOnly.
        val gemini = VetJson.decodeFromString(GeminiTranscriptionConfiguration.serializer(), """{"enabled":false,"modelID":"gemini-3.6-flash"}""")
        val online = VetJson.decodeFromString(OnlineReportConfiguration.serializer(), """{"modelID":"m","preferredMode":"online","provider":"gemini"}""")
        assertNull(gemini.decidedAt)
        assertNull(online.deviceOnly)
        assertEquals(ProcessingRoute.ASK, Processing.transcription(online, gemini, true))
        // An earlier explicit opt-in stays online.
        val optedIn = VetJson.decodeFromString(GeminiTranscriptionConfiguration.serializer(), """{"enabled":true,"modelID":"gemini-3.6-flash"}""")
        assertEquals(ProcessingRoute.ONLINE, Processing.transcription(online, optedIn, true))
        val roundTrip = VetJson.decodeFromString(GeminiTranscriptionConfiguration.serializer(), VetJson.encodeToString(GeminiTranscriptionConfiguration.serializer(), optedIn.copy(decidedAt = Instant.parse("2026-11-08T10:00:00Z"))))
        assertEquals(Instant.parse("2026-11-08T10:00:00Z"), roundTrip.decidedAt)
    }
}
