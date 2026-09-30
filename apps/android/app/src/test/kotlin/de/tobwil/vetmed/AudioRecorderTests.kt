package de.tobwil.vetmed

import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.AudioSegment
import de.tobwil.vetmed.core.Wav
import de.tobwil.vetmed.data.AudioRecorder
import de.tobwil.vetmed.data.AudioSource
import de.tobwil.vetmed.data.AudioSourceFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Synthetic PCM: a fixed number of bytes, then either silence-free waiting or a system stop. */
class SyntheticMicrophone(private val totalBytes: Long, private val stopWhenDone: Boolean = false) : AudioSourceFactory {
    val closed = AtomicBoolean(false)
    val delivered = AtomicLong(0)
    override fun open(): AudioSource = object : AudioSource {
        override fun read(buffer: ByteArray): Int {
            val remaining = totalBytes - delivered.get()
            if (remaining <= 0) { if (stopWhenDone) return -1; Thread.sleep(2); return 0 }
            val count = minOf(buffer.size.toLong(), remaining).toInt()
            for (i in 0 until count) buffer[i] = ((delivered.get() + i) % 97).toByte()
            delivered.addAndGet(count.toLong())
            return count
        }
        override fun close() { closed.set(true) }
    }
}

class AudioRecorderTests {
    @get:Rule val folder = TemporaryFolder()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @After fun stop() = scope.cancel()

    private suspend fun until(what: String, condition: () -> Boolean) {
        try { withTimeout(10_000) { while (!condition()) delay(5) } } catch (error: Exception) { throw AssertionError(what, error) }
    }

    @Test fun segmentsRollOverAndAreHandedOnAsWavBeforeTheScratchFileIsDeleted() = runBlocking {
        val scratch = folder.newFolder("scratch")
        val microphone = SyntheticMicrophone(Wav.BYTES_PER_SECOND * 5L / 2) // 2.5 s
        val recorder = AudioRecorder(scratch, microphone, segmentSeconds = 1.0)
        val stored = mutableListOf<Pair<ByteArray, AudioSegment>>()
        recorder.onSegment = { wav, segment ->
            // While the callback runs, the plaintext of this segment may still exist in scratch; afterwards it must not.
            stored += wav to segment
        }
        recorder.start("case", "enc", scope)
        until("2 volle Segmente") { stored.size == 2 }
        until("Mikrofon geleert") { microphone.delivered.get() == Wav.BYTES_PER_SECOND * 5L / 2 }
        recorder.pause()
        assertFalse(recorder.recording.value)
        assertTrue(microphone.closed.get())
        assertEquals(listOf(1.0, 1.0, 0.5), stored.map { it.second.duration })
        stored.forEach { (wav, segment) -> assertEquals(segment.duration, Wav.duration(Wav.pcm(wav).size.toLong()), 0.0001) }
        assertEquals(3, stored.map { it.second.id }.toSet().size)
        assertEquals(2.5, recorder.elapsed.value, 0.0001)
        assertTrue("Keine unverschlüsselten Reste", scratch.listFiles().orEmpty().isEmpty())
        assertEquals(null, recorder.error.value)
    }

    @Test fun aSystemStopKeepsTheSavedAudioAndReportsTheInterruption() = runBlocking {
        val scratch = folder.newFolder("scratch")
        val recorder = AudioRecorder(scratch, SyntheticMicrophone(Wav.BYTES_PER_SECOND * 3L / 2, stopWhenDone = true), segmentSeconds = 1.0)
        val stored = mutableListOf<AudioSegment>()
        var interrupted = false
        recorder.onSegment = { _, segment -> stored += segment }
        recorder.onInterruption = { interrupted = true }
        recorder.start("case", "enc", scope)
        until("Unterbrechung gemeldet") { interrupted }
        assertEquals(listOf(1.0, 0.5), stored.map { it.duration })
        assertNotNull(recorder.error.value)
        assertTrue(recorder.error.value!!.contains("Gesicherte Segmente bleiben erhalten"))
        assertFalse(recorder.recording.value)
    }

    @Test fun aFailedSealKeepsThePlaintextSegmentForRecoveryInsteadOfLosingIt() = runBlocking {
        val scratch = folder.newFolder("scratch")
        val recorder = AudioRecorder(scratch, SyntheticMicrophone(Wav.BYTES_PER_SECOND / 2L), segmentSeconds = 20.0)
        recorder.onSegment = { _, _ -> throw AppFailure("Speicher voll") }
        recorder.start("case-1", "enc-1", scope)
        until("Daten gelesen") { recorder.elapsed.value >= 0.5 }
        recorder.pause()
        assertEquals("Speicher voll", recorder.error.value)
        val leftover = AudioRecorder.leftovers(scratch).single()
        assertEquals("case-1", leftover.caseID); assertEquals("enc-1", leftover.encounterID)
        assertEquals(Wav.BYTES_PER_SECOND / 2L, leftover.file.length())
    }

    @Test fun lowStorageRefusesToStartAndARunningRecordingCannotBeStartedTwice() = runBlocking {
        val scratch = folder.newFolder("scratch")
        try {
            AudioRecorder(scratch, SyntheticMicrophone(0), availableBytes = { 1_000 }).start("c", "e", scope)
            fail("Aufnahme trotz vollem Speicher gestartet")
        } catch (error: AppFailure) { assertTrue(error.message!!.contains("Zu wenig freier Speicher")) }
        val recorder = AudioRecorder(scratch, SyntheticMicrophone(0))
        recorder.onSegment = { _, _ -> }
        recorder.start("c", "e", scope)
        try { recorder.start("c", "e", scope); fail("Zweite Aufnahme gestartet") }
        catch (error: AppFailure) { assertTrue(error.message!!.contains("Bitte warten")) }
        recorder.pause()
    }

    @Test fun leftoversIgnoreForeignFiles() {
        val scratch = folder.newFolder("scratch")
        java.io.File(scratch, "a_b_c.pcm").writeBytes(ByteArray(4))
        java.io.File(scratch, "transcribe-x.pcm").writeBytes(ByteArray(4))
        java.io.File(scratch, "a_b_c.wav").writeBytes(ByteArray(4))
        assertEquals(listOf("c"), AudioRecorder.leftovers(scratch).map { it.segmentID })
    }
}
