package de.tobwil.vetmed.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class WavTests {
    @Test fun roundTripKeepsEverySampleAndDuration() {
        val pcm = ByteArray(Wav.BYTES_PER_SECOND * 3) { (it % 251).toByte() }
        val wav = Wav.wrap(pcm)
        assertEquals(44 + pcm.size, wav.size)
        assertEquals("RIFF", wav.copyOfRange(0, 4).decodeToString())
        assertArrayEquals(pcm, Wav.pcm(wav))
        assertEquals(3.0, Wav.duration(pcm.size.toLong()), 0.0)
    }

    @Test fun truncatedOrForeignAudioIsRejected() {
        val wav = Wav.wrap(ByteArray(1000))
        for (broken in listOf(wav.copyOf(500), ByteArray(10), "OggS".encodeToByteArray() + ByteArray(60))) {
            try { Wav.pcm(broken); fail("accepted broken audio") } catch (_: AppFailure) {}
        }
    }
}
