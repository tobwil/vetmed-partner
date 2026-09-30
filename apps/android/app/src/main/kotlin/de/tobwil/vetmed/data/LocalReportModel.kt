package de.tobwil.vetmed.data

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.DeviceReadiness
import de.tobwil.vetmed.core.ModelStore
import de.tobwil.vetmed.core.OutputRepetition
import de.tobwil.vetmed.core.ReportTextEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** One loaded model. Tests use a synthetic runtime; the app uses [LiteRtRuntime]. */
interface LocalRuntime : AutoCloseable {
    val backendName: String
    /** Streams text chunks to [onText] and returns when the answer is complete. */
    suspend fun generate(prompt: String, instructions: String, onText: (String) -> Unit)
}

fun interface LocalRuntimeFactory { suspend fun open(model: File, cacheDir: File): LocalRuntime }

/**
 * LiteRT-LM with deterministic sampling. GPU is tried first; if the device's GPU delegate cannot start, the same
 * model runs on the CPU. Either way nothing leaves the device, which is what the offline mode promises.
 */
class LiteRtRuntime private constructor(private val engine: Engine, override val backendName: String) : LocalRuntime {
    companion object : LocalRuntimeFactory {
        override suspend fun open(model: File, cacheDir: File): LocalRuntime = withContext(Dispatchers.Default) {
            cacheDir.mkdirs()
            fun start(backend: Backend) = Engine(
                EngineConfig(modelPath = model.absolutePath, backend = backend, maxNumTokens = 8192, cacheDir = cacheDir.absolutePath),
            ).apply { initialize() }
            try { LiteRtRuntime(start(Backend.GPU()), "GPU") }
            catch (gpu: Exception) {
                try { LiteRtRuntime(start(Backend.CPU()), "CPU") }
                catch (cpu: Exception) { throw AppFailure("Das lokale Modell konnte nicht gestartet werden: ${cpu.message ?: gpu.message}") }
            }
        }
    }

    override suspend fun generate(prompt: String, instructions: String, onText: (String) -> Unit) = withContext(Dispatchers.Default) {
        val conversation = engine.createConversation(
            ConversationConfig(
                systemInstruction = Contents.of(instructions),
                samplerConfig = SamplerConfig(topK = 1, topP = 0.95, temperature = 0.0, seed = 0),
                maxOutputToken = 2048,
                thinkingConfig = ThinkingConfig(false),
            ),
        )
        try {
            conversation.sendMessageAsync(prompt)
                .catch { error -> throw if (error is CancellationException || error is AppFailure) error else AppFailure(localFailure(error)) }
                .collect { message -> message.contents.contents.filterIsInstance<Content.Text>().forEach { onText(it.text) } }
        } catch (error: CancellationException) {
            runCatching { conversation.cancelProcess() }
            throw error
        } catch (error: AppFailure) {
            runCatching { conversation.cancelProcess() }
            throw error
        } finally {
            conversation.close()
        }
    }

    private fun localFailure(error: Throwable): String {
        val text = error.message.orEmpty()
        return if (text.contains("token", ignoreCase = true) && (text.contains("max", ignoreCase = true) || text.contains("exceed", ignoreCase = true)))
            "Dieser Abschnitt überschreitet das lokale Kontextlimit. Das Transkript bleibt vollständig erhalten."
        else "Das lokale Modell ist fehlgeschlagen: ${text.ifEmpty { error::class.simpleName }}"
    }

    override fun close() = engine.close()
}

/**
 * Port of the iOS `MLXLocalReportEngine` lifecycle: explicit install, verified load, generation, unload and delete.
 * The model is never downloaded implicitly and never used as a silent fallback for online reports.
 */
class LocalReportModel(
    val store: ModelStore,
    private val cacheDir: File,
    private val runtimes: LocalRuntimeFactory = LiteRtRuntime,
    private val readiness: () -> String? = { null },
) : ReportTextEngine {
    override val engineID: String get() = store.manifest.id
    override val engineRevision: String get() = store.manifest.revision
    override val executionLabel: String get() = "auf diesem Gerät"

    private val _installed = MutableStateFlow(store.isInstalled())
    val installed: StateFlow<Boolean> = _installed.asStateFlow()
    private val _status = MutableStateFlow(if (_installed.value) "Installiert · offline verfügbar" else "Nicht installiert")
    val status: StateFlow<String> = _status.asStateFlow()
    private val _progress = MutableStateFlow<Double?>(null)
    val progress: StateFlow<Double?> = _progress.asStateFlow()

    private val lock = Mutex()
    private var runtime: LocalRuntime? = null
    val isLoaded: Boolean get() = runtime != null

    fun refresh() {
        _installed.value = store.isInstalled()
        if (runtime == null) _status.value = if (_installed.value) "Installiert · offline verfügbar" else if (store.storedBytes() > 0) "Download unterbrochen · fortsetzbar" else "Nicht installiert"
    }

    suspend fun install() = lock.withLock {
        readiness()?.let { throw AppFailure(it) }
        _status.value = "Modell wird geladen"; _progress.value = 0.0
        try {
            store.install(progress = { _progress.value = it }, verifying = { _status.value = "Integrität wird geprüft"; _progress.value = null })
            _status.value = "Installiert · offline verfügbar"
        } catch (error: CancellationException) {
            _status.value = "Download pausiert · fortsetzbar"; throw error
        } catch (error: Exception) {
            _status.value = "Installation unterbrochen"; throw error
        } finally {
            _progress.value = null; _installed.value = store.isInstalled()
        }
    }

    suspend fun load() = lock.withLock {
        if (runtime != null) return@withLock
        readiness()?.let { throw AppFailure(it) }
        if (!store.isInstalled()) throw AppFailure("Bitte das Offline-Modell zuerst in den Einstellungen laden. Es wird nichts automatisch heruntergeladen.")
        _status.value = "Integrität prüfen und Modell laden"
        try {
            store.verify()
            val opened = runtimes.open(store.modelFile, cacheDir)
            runtime = opened
            _status.value = "Bereit · auf diesem Gerät (${opened.backendName})"
        } catch (error: Exception) {
            runtime = null; _status.value = "Laden fehlgeschlagen"; throw error
        }
    }

    fun unload() {
        runtime?.close(); runtime = null
        refresh()
    }

    suspend fun delete() = lock.withLock {
        runtime?.close(); runtime = null
        withContext(Dispatchers.IO) { store.remove(); cacheDir.deleteRecursively() }
        refresh()
    }

    override suspend fun generate(prompt: String, instructions: String): String {
        val active = runtime ?: throw AppFailure("Das lokale Modell ist nicht bereit.")
        readiness()?.let { throw AppFailure(it) }
        val output = StringBuilder()
        var chunks = 0
        active.generate(prompt, instructions) { text ->
            output.append(text); chunks += 1
            if (chunks % 16 == 0 && OutputRepetition.containsLoop(output.toString())) throw AppFailure(OutputRepetition.MESSAGE)
        }
        if (OutputRepetition.containsLoop(output.toString())) throw AppFailure(OutputRepetition.MESSAGE)
        if (output.isBlank()) throw AppFailure("Das Modell lieferte keinen Bericht.")
        return output.toString()
    }

    companion object {
        fun readiness(context: Context): () -> String? = {
            val memory = ActivityManager.MemoryInfo().also { (context.getSystemService(ActivityManager::class.java)).getMemoryInfo(it) }
            val thermal = context.getSystemService(PowerManager::class.java)?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
            DeviceReadiness.blockingReason(memory.totalMem, thermal >= PowerManager.THERMAL_STATUS_SEVERE, Build.SUPPORTED_ABIS.toList())
        }
    }
}
