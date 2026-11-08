package de.tobwil.vetmed.data

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import de.tobwil.vetmed.core.GeminiLive
import de.tobwil.vetmed.core.LiveConnector
import de.tobwil.vetmed.core.LiveSocket
import de.tobwil.vetmed.core.LiveSocketListener
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.math.sqrt

/** OkHttp WebSocket for Gemini Live. No cookies, no cache; text and binary frames are both read as UTF-8 JSON. */
object OkHttpLiveConnector : LiveConnector {
    private val client by lazy {
        OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(20, TimeUnit.SECONDS).followRedirects(false).retryOnConnectionFailure(false).build()
    }

    override fun connect(url: String, listener: LiveSocketListener): LiveSocket {
        val socket = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen()
            override fun onMessage(webSocket: WebSocket, text: String) = listener.onMessage(text)
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = listener.onMessage(bytes.utf8())
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = listener.onClosed(code, reason)
            // The URL carries the one-time token; it never goes into a message or log.
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = listener.onFailure(response?.code?.let { "HTTP $it" } ?: (t::class.simpleName ?: "Fehler"))
        })
        return object : LiveSocket {
            override fun send(text: String) = socket.send(text)
            override fun close() { socket.close(1000, null) }
        }
    }
}

/** Microphone and speaker for one voice conversation. A fake in tests. */
interface VoiceAudio {
    /** 0…1, for the pulsing circle: the microphone while listening, the speaker while the model talks. */
    val level: StateFlow<Float>
    fun start(onChunk: (ByteArray) -> Unit)
    fun play(pcm: ByteArray)
    /** Drops everything queued for playback at once (interruption). */
    fun flush()
    fun setMuted(muted: Boolean)
    fun stop()
}

fun interface VoiceAudioFactory { fun create(): VoiceAudio }

/**
 * Microphone at 16 kHz with the voice-call path (echo cancellation, so the model does not hear itself), playback at
 * 24 kHz. Nothing is written to disk: audio only exists in these buffers while the conversation runs.
 */
class AndroidVoiceAudio : VoiceAudio {
    private val _level = MutableStateFlow(0f)
    override val level: StateFlow<Float> = _level.asStateFlow()
    @Volatile private var running = false
    @Volatile private var muted = false
    private val queue = LinkedBlockingQueue<ByteArray>()
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private val effects = mutableListOf<android.media.audiofx.AudioEffect>()

    @SuppressLint("MissingPermission") // Checked by the screen before the conversation starts.
    override fun start(onChunk: (ByteArray) -> Unit) {
        val inputSize = maxOf(AudioRecord.getMinBufferSize(GeminiLive.INPUT_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), 6400)
        val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, GeminiLive.INPUT_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, inputSize * 2)
        if (recorder.state != AudioRecord.STATE_INITIALIZED) { recorder.release(); throw de.tobwil.vetmed.core.AppFailure("Das Mikrofon konnte nicht geöffnet werden.") }
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(recorder.audioSessionId)?.let { it.enabled = true; effects += it }
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(recorder.audioSessionId)?.let { it.enabled = true; effects += it }
        val output = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(GeminiLive.OUTPUT_RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(GeminiLive.OUTPUT_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), 9600))
            .setTransferMode(AudioTrack.MODE_STREAM).build()
        record = recorder; track = output; running = true
        recorder.startRecording(); output.play()
        thread(name = "vetmed-voice-mic", isDaemon = true) {
            val buffer = ByteArray(3200) // 100 ms
            while (running) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read <= 0) continue
                val chunk = buffer.copyOf(read)
                if (!muted) { if (queue.isEmpty()) _level.value = rms(chunk); onChunk(chunk) }
            }
        }
        thread(name = "vetmed-voice-speaker", isDaemon = true) {
            while (running) {
                val pcm = queue.poll(200, TimeUnit.MILLISECONDS) ?: continue
                _level.value = rms(pcm)
                output.write(pcm, 0, pcm.size)
            }
        }
    }

    override fun play(pcm: ByteArray) { if (running) queue.offer(pcm) }

    override fun flush() {
        queue.clear()
        track?.runCatching { pause(); flush(); play() }
    }

    override fun setMuted(muted: Boolean) { this.muted = muted; if (muted) _level.value = 0f }

    override fun stop() {
        running = false; queue.clear()
        record?.runCatching { stop(); release() }; record = null
        track?.runCatching { pause(); flush(); release() }; track = null
        effects.forEach { runCatching { it.release() } }; effects.clear()
        _level.value = 0f
    }

    private fun rms(pcm: ByteArray): Float {
        var sum = 0.0; var count = 0
        var index = 0
        while (index + 1 < pcm.size) { val sample = (pcm[index].toInt() and 0xFF) or (pcm[index + 1].toInt() shl 8); sum += sample.toDouble() * sample; count++; index += 8 }
        return if (count == 0) 0f else (sqrt(sum / count) / 8000.0).toFloat().coerceIn(0f, 1f)
    }
}
