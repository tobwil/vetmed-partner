package de.tobwil.vetmed.data

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.TranscriptSegment
import de.tobwil.vetmed.core.Wav
import de.tobwil.vetmed.core.newId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Speech-to-text used by the view model; tests replace it with a synthetic implementation. */
interface Transcriber {
    val engineName: String
    suspend fun status(): SpeechStatus
    suspend fun install(progress: (Int) -> Unit)
    suspend fun transcribe(wav: ByteArray, audioID: String): List<TranscriptSegment>
}

enum class SpeechStatus(val title: String) {
    READY("Deutsch · offline bereit"),
    DOWNLOADABLE("Deutsche Sprachressourcen fehlen"),
    DOWNLOADING("Sprachressourcen werden installiert"),
    UNSUPPORTED("Auf diesem Gerät nicht verfügbar"),
}

/**
 * Android's explicit on-device recognizer (`createOnDeviceSpeechRecognizer`) fed from the recorded file. It never
 * falls back to a network recognizer: without installed German resources it fails and the recording stays.
 */
class OnDeviceTranscriber(private val context: Context, private val scratch: File) : Transcriber {
    override val engineName = "Android On-Device-Spracherkennung · de-DE · offline"
    private val language = "de-DE"

    private fun intent() = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }

    override suspend fun status(): SpeechStatus = withContext(Dispatchers.Main) {
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) return@withContext SpeechStatus.UNSUPPORTED
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        try {
            withTimeout(10_000) {
                suspendCancellableCoroutine { continuation ->
                    recognizer.checkRecognitionSupport(intent(), context.mainExecutor, object : RecognitionSupportCallback {
                        override fun onSupportResult(support: RecognitionSupport) {
                            fun has(list: List<String>) = list.any { it.equals(language, true) || it.equals("de", true) || it.startsWith("de-", true) }
                            continuation.resume(when {
                                has(support.installedOnDeviceLanguages) -> SpeechStatus.READY
                                has(support.pendingOnDeviceLanguages) -> SpeechStatus.DOWNLOADING
                                has(support.supportedOnDeviceLanguages) -> SpeechStatus.DOWNLOADABLE
                                else -> SpeechStatus.UNSUPPORTED
                            })
                        }
                        override fun onError(error: Int) { continuation.resume(SpeechStatus.UNSUPPORTED) }
                    })
                }
            }
        } finally {
            recognizer.destroy()
        }
    }

    override suspend fun install(progress: (Int) -> Unit) = withContext(Dispatchers.Main) {
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) throw AppFailure("Deutsche Offline-Spracherkennung ist auf diesem Gerät nicht verfügbar. Aufnahme und Texteingabe bleiben möglich.")
        val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        try {
            suspendCancellableCoroutine { continuation ->
                recognizer.triggerModelDownload(intent(), context.mainExecutor, object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) = progress(completedPercent)
                    override fun onSuccess() = continuation.resume(Unit)
                    override fun onScheduled() = continuation.resumeWithException(AppFailure("Der Download der deutschen Sprachressourcen wurde vom System geplant. Bitte später erneut prüfen."))
                    override fun onError(error: Int) = continuation.resumeWithException(AppFailure("Die deutschen Sprachressourcen konnten nicht installiert werden (Fehler $error)."))
                })
            }
        } finally {
            recognizer.destroy()
        }
    }

    override suspend fun transcribe(wav: ByteArray, audioID: String): List<TranscriptSegment> {
        val pcm = Wav.pcm(wav)
        val duration = Wav.duration(pcm.size.toLong())
        scratch.mkdirs()
        val file = File(scratch, "transcribe-" + newId() + ".pcm")
        withContext(Dispatchers.IO) { file.writeBytes(pcm) }
        val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            return withContext(Dispatchers.Main) {
                if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
                    throw AppFailure("Deutsche Offline-Spracherkennung ist auf diesem Gerät nicht verfügbar. Aufnahme und Texteingabe bleiben möglich.")
                }
                val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                try {
                    withTimeout((duration * 3 * 1000).toLong() + 60_000) { recognize(recognizer, descriptor, audioID) }
                } finally {
                    recognizer.destroy()
                }
            }
        } finally {
            descriptor.close(); file.delete()
        }
    }

    private suspend fun recognize(recognizer: SpeechRecognizer, descriptor: ParcelFileDescriptor, audioID: String): List<TranscriptSegment> =
        suspendCancellableCoroutine { continuation ->
            val segments = mutableListOf<TranscriptSegment>()
            fun add(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim().orEmpty()
                if (text.isNotEmpty()) segments += TranscriptSegment(id = "$audioID-${segments.size}", text = text, audioID = audioID)
            }
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onSegmentResults(segmentResults: Bundle) = add(segmentResults)
                override fun onEndOfSegmentedSession() { if (continuation.isActive) continuation.resume(segments.toList()) }
                override fun onResults(results: Bundle?) { add(results); if (continuation.isActive) continuation.resume(segments.toList()) }
                override fun onError(error: Int) {
                    if (!continuation.isActive) return
                    if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) { continuation.resume(segments.toList()); return }
                    continuation.resumeWithException(AppFailure(when (error) {
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
                            "Deutsche Sprachressourcen fehlen. Bitte in Einstellungen ausdrücklich installieren. Kein Cloud-Fallback."
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Die Spracherkennung hat keine Berechtigung."
                        SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "Die Spracherkennung ist gerade belegt. Bitte erneut versuchen."
                        else -> "Die lokale Spracherkennung ist fehlgeschlagen (Fehler $error). Die Aufnahme bleibt erhalten."
                    }))
                }
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            recognizer.startListening(intent().apply {
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, descriptor)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, Wav.SAMPLE_RATE)
                // Segmented session: the whole file is processed, including pauses, not just the first utterance.
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            })
            continuation.invokeOnCancellation { recognizer.cancel() }
        }
}
