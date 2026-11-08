package de.tobwil.vetmed.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** A WebSocket as the session needs it; OkHttp in the app, a fake in tests. */
interface LiveSocket {
    fun send(text: String): Boolean
    fun close()
}

interface LiveSocketListener {
    fun onOpen()
    fun onMessage(text: String)
    fun onClosed(code: Int, reason: String)
    fun onFailure(message: String)
}

fun interface LiveConnector { fun connect(url: String, listener: LiveSocketListener): LiveSocket }

sealed interface LiveState {
    data object Idle : LiveState
    data object Connecting : LiveState
    data object Live : LiveState
    /** The server announced the end of this connection; a new one resumes the same conversation. */
    data object Resuming : LiveState
    data class Ended(val message: String?) : LiveState
}

/**
 * One voice conversation (ADR 0016). Connects with a one-time token, keeps the transcript, plays nothing itself
 * ([onAudio] hands 24 kHz PCM to the app) and resumes after the server's go-away with the last resumption handle.
 * A lost network ends the session visibly; nothing reconnects or resends on its own.
 */
class LiveSession(
    private val key: String,
    private val instructions: String,
    private val vocabulary: List<String>,
    private val connector: LiveConnector,
    private val scope: CoroutineScope,
    private val transport: HttpTransport = EphemeralHttpTransport,
) {
    private val _state = MutableStateFlow<LiveState>(LiveState.Idle)
    val state: StateFlow<LiveState> = _state.asStateFlow()
    private val _turns = MutableStateFlow<List<LiveTurn>>(emptyList())
    val turns: StateFlow<List<LiveTurn>> = _turns.asStateFlow()
    private val _seconds = MutableStateFlow(0.0 to 0.0)
    /** Seconds of audio sent and received, for the cost display. */
    val audioSeconds: StateFlow<Pair<Double, Double>> = _seconds.asStateFlow()

    /** 24 kHz 16-bit PCM from the model, in order. */
    var onAudio: (ByteArray) -> Unit = {}
    /** The user spoke over the model, or tapped "Unterbrechen": queued audio must stop at once. */
    var onInterrupted: () -> Unit = {}

    private val lock = Any()
    private var socket: LiveSocket? = null
    private var handle: String? = null
    private var generation = 0
    private var stopped = false
    private var muteUntilTurnEnds = false

    fun start() {
        synchronized(lock) { if (_state.value != LiveState.Idle) return; _state.value = LiveState.Connecting }
        connect(resume = false)
    }

    private fun connect(resume: Boolean) {
        val attempt = synchronized(lock) { ++generation }
        scope.launch {
            val token = try { GeminiLive.token(transport.send(GeminiLive.tokenRequest(key))) }
            catch (error: Exception) { end(attempt, (error as? AppFailure)?.message ?: "Der Sprachmodus konnte nicht angemeldet werden. Keine Internetverbindung?"); return@launch }
            val setup = GeminiLive.setup(instructions, vocabulary, if (resume) synchronized(lock) { handle } else null)
            // onOpen can fire before connect() returns; the setup must go to this connection, never to the previous one.
            val ready = CompletableDeferred<LiveSocket>()
            val opened = connector.connect(GeminiLive.socketUrl(token), object : LiveSocketListener {
                override fun onOpen() { scope.launch { val own = ready.await(); synchronized(lock) { if (attempt == generation && !stopped) own.send(setup) } } }
                override fun onMessage(text: String) = receive(attempt, text)
                override fun onClosed(code: Int, reason: String) = closed(attempt, if (code == 1000) null else "Verbindung beendet ($code${if (reason.isNotBlank()) ": $reason" else ""}).")
                override fun onFailure(message: String) = closed(attempt, "Die Verbindung zum Sprachdienst wurde unterbrochen. Die Mitschrift bleibt erhalten; es wird nichts automatisch neu gestartet.")
            })
            ready.complete(opened)
            val previous = synchronized(lock) {
                if (attempt != generation || stopped) null.also { opened.close() } else socket.also { socket = opened }
            }
            previous?.close()
        }
    }

    private fun receive(attempt: Int, text: String) {
        val events = GeminiLive.parse(text)
        synchronized(lock) {
            if (attempt != generation || stopped) return
            for (event in events) {
                when (event) {
                    GeminiLive.Event.SetupComplete -> _state.value = LiveState.Live
                    is GeminiLive.Event.Audio -> if (!muteUntilTurnEnds) {
                        _seconds.value = _seconds.value.first to _seconds.value.second + event.pcm.size / (GeminiLive.OUTPUT_RATE * 2.0)
                        onAudio(event.pcm)
                    }
                    GeminiLive.Event.Interrupted -> { muteUntilTurnEnds = false; onInterrupted() }
                    GeminiLive.Event.TurnComplete -> muteUntilTurnEnds = false
                    is GeminiLive.Event.Resumption -> if (event.resumable && event.handle != null) handle = event.handle
                    is GeminiLive.Event.GoAway -> if (handle != null) {
                        _state.value = LiveState.Resuming
                        scope.launch { connect(resume = true) }
                    }
                    is GeminiLive.Event.Failure -> { endLocked(event.message); return }
                    else -> Unit
                }
                _turns.value = LiveTranscript.apply(_turns.value, event)
            }
        }
    }

    private fun closed(attempt: Int, message: String?) {
        synchronized(lock) {
            // The old connection closing after a resume is expected; only the current one matters.
            if (attempt != generation || stopped) return
            if (_state.value == LiveState.Resuming) return
            endLocked(message ?: "Der Sprachdienst hat das Gespräch beendet.")
        }
    }

    private fun end(attempt: Int, message: String) = synchronized(lock) { if (attempt == generation && !stopped) endLocked(message) }

    private fun endLocked(message: String?) {
        stopped = true
        socket?.close(); socket = null
        _turns.value = _turns.value.map { if (it.open) it.copy(open = false) else it }
        _state.value = LiveState.Ended(message)
    }

    /** Microphone audio, 16 kHz 16-bit PCM. Dropped while not connected; never buffered for later sending. */
    fun sendAudio(pcm: ByteArray) {
        synchronized(lock) {
            if (_state.value != LiveState.Live || stopped) return
            if (socket?.send(GeminiLive.audio(pcm)) == true) _seconds.value = _seconds.value.first + pcm.size / (GeminiLive.INPUT_RATE * 2.0) to _seconds.value.second
        }
    }

    fun sendImage(jpeg: ByteArray): Boolean = synchronized(lock) { _state.value == LiveState.Live && socket?.send(GeminiLive.image(jpeg)) == true }

    /** Microphone muted: tells the server the user's audio has ended for now. */
    fun pauseInput() { synchronized(lock) { if (_state.value == LiveState.Live) socket?.send(GeminiLive.audioStreamEnd()) } }

    /** "Unterbrechen": stop playing the current answer here; the rest of this turn is discarded. */
    fun interrupt() {
        synchronized(lock) {
            muteUntilTurnEnds = true
            _turns.value = LiveTranscript.apply(_turns.value, GeminiLive.Event.Interrupted)
        }
        onInterrupted()
    }

    fun stop() { synchronized(lock) { if (!stopped) endLocked(null) } }
}
