package de.tobwil.vetmed.data

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.AudioSegment
import de.tobwil.vetmed.core.Wav
import de.tobwil.vetmed.core.newId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

/** 16 kHz mono PCM16 microphone input. Tests supply synthetic sources. */
interface AudioSource {
    /** Fills [buffer]; returns the number of bytes read or a negative value when the system stopped the input. */
    fun read(buffer: ByteArray): Int
    fun close()
}

fun interface AudioSourceFactory { fun open(): AudioSource }

object MicrophoneSourceFactory : AudioSourceFactory {
    @SuppressLint("MissingPermission") // The screen requests RECORD_AUDIO before any recording starts.
    override fun open(): AudioSource {
        val minimum = AudioRecord.getMinBufferSize(Wav.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw AppFailure("Das Mikrofon unterstützt das Aufnahmeformat nicht.")
        val record = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, Wav.SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, Wav.BYTES_PER_SECOND / 2))
        if (record.state != AudioRecord.STATE_INITIALIZED) { record.release(); throw AppFailure("Das Mikrofon ist nicht verfügbar. Bitte andere Aufnahme-Apps schließen.") }
        record.startRecording()
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) { record.release(); throw AppFailure("Aufnahme konnte nicht gestartet werden.") }
        return object : AudioSource {
            override fun read(buffer: ByteArray) = record.read(buffer, 0, buffer.size)
            override fun close() { runCatching { record.stop() }; record.release() }
        }
    }
}

/**
 * Port of the iOS `AudioRecorder`: segments of about 20 seconds are handed to [onSegment] (which encrypts and
 * stores them) as soon as they are complete. Only the segment in progress exists unencrypted in the no-backup
 * scratch folder, named by IDs only so an interrupted segment can be recovered without a cleartext index.
 */
class AudioRecorder(
    private val scratch: File,
    private val sources: AudioSourceFactory = MicrophoneSourceFactory,
    private val segmentSeconds: Double = 20.0,
    private val availableBytes: (File) -> Long = { it.usableSpace },
) {
    private val _recording = MutableStateFlow(false)
    val recording: StateFlow<Boolean> = _recording.asStateFlow()
    private val _elapsed = MutableStateFlow(0.0)
    val elapsed: StateFlow<Double> = _elapsed.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    var onSegment: (suspend (wav: ByteArray, segment: AudioSegment) -> Unit)? = null
    var onInterruption: (suspend () -> Unit)? = null

    private val lock = Mutex()
    private var job: Job? = null
    private var owner: Pair<String, String>? = null
    private var completed = 0.0

    suspend fun start(caseID: String, encounterID: String, scope: CoroutineScope) = lock.withLock {
        if (_recording.value) throw AppFailure("Bitte warten, bis die laufende Aufnahmeaktion abgeschlossen ist.")
        if (owner != caseID to encounterID) { completed = 0.0; _elapsed.value = 0.0 }
        owner = caseID to encounterID
        scratch.mkdirs()
        if (availableBytes(scratch) < 20_000_000) throw AppFailure("Zu wenig freier Speicher für eine sichere Aufnahme. Bitte Speicher freigeben; vorhandene Segmente bleiben erhalten.")
        val source = withContext(Dispatchers.IO) { sources.open() }
        _error.value = null; _recording.value = true
        job = scope.launch(Dispatchers.IO) { loop(source, caseID, encounterID) }
    }

    /** Stops after saving the segment in progress. Never switches case before that save has completed. */
    suspend fun pause() {
        val running = job ?: return
        _recording.value = false
        running.join()
        job = null
    }

    private suspend fun loop(source: AudioSource, caseID: String, encounterID: String) {
        val buffer = ByteArray(Wav.BYTES_PER_SECOND / 10)
        var segmentID = newId()
        var file = File(scratch, "${caseID}_${encounterID}_$segmentID.pcm")
        var output = FileOutputStream(file)
        var bytes = 0L
        val limit = (segmentSeconds * Wav.BYTES_PER_SECOND).toLong()
        var interrupted = false
        try {
            while (_recording.value && currentCoroutineContextActive()) {
                val read = source.read(buffer)
                if (read < 0) {
                    _error.value = "Die Aufnahme wurde vom System beendet. Gesicherte Segmente bleiben erhalten."
                    interrupted = true; break
                }
                if (read == 0) continue
                output.write(buffer, 0, read); bytes += read
                _elapsed.value = completed + Wav.duration(bytes)
                if (bytes >= limit) {
                    output.close()
                    finish(file, segmentID, bytes)
                    segmentID = newId(); bytes = 0
                    file = File(scratch, "${caseID}_${encounterID}_$segmentID.pcm")
                    output = FileOutputStream(file)
                }
            }
        } catch (error: Exception) {
            _error.value = error.message ?: "Die Aufnahme wurde unterbrochen."
            interrupted = true
        } finally {
            source.close()
            runCatching { output.close() }
            try { if (bytes > 0) finish(file, segmentID, bytes) else file.delete() }
            catch (error: Exception) { _error.value = error.message; interrupted = true }
            _recording.value = false
            if (interrupted) onInterruption?.invoke()
        }
    }

    private suspend fun finish(file: File, id: String, bytes: Long) {
        val duration = Wav.duration(bytes)
        if (duration <= 0.05) { file.delete(); return }
        val callback = onSegment ?: throw AppFailure("Aufnahme kann keinem Fallspeicher zugeordnet werden.")
        // Only delete the scratch file once the encrypted segment is durably stored.
        callback(Wav.wrap(file.readBytes()), AudioSegment(id = id, duration = duration))
        completed += duration; _elapsed.value = completed
        file.delete()
    }

    private suspend fun currentCoroutineContextActive() = kotlinx.coroutines.currentCoroutineContext().isActive

    companion object {
        /** Scratch files left by a crash: (caseID, encounterID, segmentID, file). */
        fun leftovers(scratch: File): List<Leftover> = scratch.listFiles().orEmpty().mapNotNull { file ->
            val parts = file.nameWithoutExtension.split('_')
            if (file.extension == "pcm" && parts.size == 3) Leftover(parts[0], parts[1], parts[2], file) else null
        }
    }

    data class Leftover(val caseID: String, val encounterID: String, val segmentID: String, val file: File)
}
