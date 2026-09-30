package de.tobwil.vetmed.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** 16 kHz mono PCM16 WAV, the format recorded on Android and understood by the on-device recognizer. */
object Wav {
    const val SAMPLE_RATE = 16_000
    const val BYTES_PER_SECOND = SAMPLE_RATE * 2
    private const val HEADER = 44

    fun wrap(pcm: ByteArray): ByteArray {
        val header = ByteBuffer.allocate(HEADER).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".encodeToByteArray()); putInt(36 + pcm.size); put("WAVE".encodeToByteArray())
            put("fmt ".encodeToByteArray()); putInt(16); putShort(1); putShort(1); putInt(SAMPLE_RATE); putInt(BYTES_PER_SECOND); putShort(2); putShort(16)
            put("data".encodeToByteArray()); putInt(pcm.size)
        }.array()
        return header + pcm
    }

    /** Returns the PCM payload of a WAV written by [wrap]; anything else is rejected rather than guessed. */
    fun pcm(wav: ByteArray): ByteArray {
        if (wav.size < HEADER || wav.copyOfRange(0, 4).decodeToString() != "RIFF" || wav.copyOfRange(8, 12).decodeToString() != "WAVE") {
            throw AppFailure("Die Aufnahme hat kein gültiges WAV-Format.")
        }
        val buffer = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        if (buffer.getShort(20).toInt() != 1 || buffer.getShort(22).toInt() != 1 || buffer.getInt(24) != SAMPLE_RATE || buffer.getShort(34).toInt() != 16) {
            throw AppFailure("Die Aufnahme hat ein unerwartetes Audioformat.")
        }
        val size = buffer.getInt(40)
        if (size < 0 || HEADER + size > wav.size) throw AppFailure("Die Aufnahme ist unvollständig.")
        return wav.copyOfRange(HEADER, HEADER + size)
    }

    fun duration(pcmBytes: Long): Double = pcmBytes.toDouble() / BYTES_PER_SECOND
}
