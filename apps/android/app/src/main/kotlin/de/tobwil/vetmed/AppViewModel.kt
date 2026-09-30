package de.tobwil.vetmed

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import android.net.Uri
import de.tobwil.vetmed.core.AnalysisRun
import de.tobwil.vetmed.core.AnalysisStatus
import de.tobwil.vetmed.core.AnalysisStreamUpdate
import de.tobwil.vetmed.core.AppFailure
import de.tobwil.vetmed.core.ChatAttachment
import de.tobwil.vetmed.core.ChatLocation
import de.tobwil.vetmed.core.ChatOperations
import de.tobwil.vetmed.core.SparringDraft
import de.tobwil.vetmed.core.SparringService
import de.tobwil.vetmed.core.SparringSnapshot
import android.content.ComponentCallbacks2
import de.tobwil.vetmed.core.ModelStore
import de.tobwil.vetmed.core.ReportTextEngine
import de.tobwil.vetmed.data.AttachmentImporter
import de.tobwil.vetmed.data.LocalReportModel
import de.tobwil.vetmed.data.AudioRecorder
import de.tobwil.vetmed.data.AudioSourceFactory
import de.tobwil.vetmed.data.MicrophoneSourceFactory
import de.tobwil.vetmed.data.OnDeviceTranscriber
import de.tobwil.vetmed.data.SpeechStatus
import de.tobwil.vetmed.data.Transcriber
import de.tobwil.vetmed.data.ReportExports
import de.tobwil.vetmed.core.CaseOperations
import de.tobwil.vetmed.core.CaseOperations.mapEncounter
import de.tobwil.vetmed.core.CloudReportRequest
import de.tobwil.vetmed.core.Encounter
import de.tobwil.vetmed.core.EncounterLocation
import de.tobwil.vetmed.core.EncounterState
import de.tobwil.vetmed.core.OnlineModelCheck
import de.tobwil.vetmed.core.OnlineReportConfiguration
import de.tobwil.vetmed.core.OpenAIReportApi
import de.tobwil.vetmed.core.OpenAIReportEngine
import de.tobwil.vetmed.core.ReportExecutionMode
import de.tobwil.vetmed.core.ReportLength
import de.tobwil.vetmed.core.ReportPipeline
import de.tobwil.vetmed.core.ReportTemplate
import de.tobwil.vetmed.core.TranscriptBuilder
import de.tobwil.vetmed.core.VaultDocument
import de.tobwil.vetmed.core.VocabularyEntry
import de.tobwil.vetmed.core.now
import de.tobwil.vetmed.core.validateApiKey
import de.tobwil.vetmed.data.AndroidKeystoreKeySource
import de.tobwil.vetmed.data.VaultRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Base64

/** Android counterpart of the iOS `VetAppModel`. Every change is persisted before it is shown as saved. */
class AppViewModel(
    application: Application,
    private val repository: VaultRepository,
    audioSources: AudioSourceFactory = MicrophoneSourceFactory,
    transcriber: Transcriber? = null,
    localModel: LocalReportModel? = null,
) : AndroidViewModel(application) {
    /** Used by the default view model factory: SQLCipher case database and sealed secrets under separate Keystore keys, outside backups. */
    constructor(application: Application) : this(
        application,
        VaultRepository(
            context = application,
            root = File(application.noBackupFilesDir, "vault"),
            dataKeys = AndroidKeystoreKeySource("de.tobwil.vetmed.vault.v1"),
            secretKeys = AndroidKeystoreKeySource("de.tobwil.vetmed.secrets.v1"),
        ),
    )
    private val writes = Mutex()
    private var work: Job? = null

    private val _document = MutableStateFlow(VaultDocument())
    val document: StateFlow<VaultDocument> = _document.asStateFlow()
    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready.asStateFlow()
    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    private val _workStatus = MutableStateFlow("")
    val workStatus: StateFlow<String> = _workStatus.asStateFlow()
    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()
    private val _online = MutableStateFlow(OnlineReportConfiguration())
    val online: StateFlow<OnlineReportConfiguration> = _online.asStateFlow()
    private val _hasKey = MutableStateFlow(false)
    val hasKey: StateFlow<Boolean> = _hasKey.asStateFlow()
    private val _onlineModels = MutableStateFlow<List<String>>(emptyList())
    val onlineModels: StateFlow<List<String>> = _onlineModels.asStateFlow()
    private val _onlineStatus = MutableStateFlow<String?>(null)
    val onlineStatus: StateFlow<String?> = _onlineStatus.asStateFlow()
    private val _vocabulary = MutableStateFlow<List<VocabularyEntry>>(emptyList())
    val vocabulary: StateFlow<List<VocabularyEntry>> = _vocabulary.asStateFlow()
    private val _activeAnalysisID = MutableStateFlow<String?>(null)
    val activeAnalysisID: StateFlow<String?> = _activeAnalysisID.asStateFlow()
    val exports by lazy { ReportExports(File(application.cacheDir, "exports")) }
    private val scratch = File(application.noBackupFilesDir, "scratch")
    val recorder = AudioRecorder(scratch, audioSources)
    private val transcriber: Transcriber = transcriber ?: OnDeviceTranscriber(application, scratch)
    private val _recordingLocation = MutableStateFlow<EncounterLocation?>(null)
    val recordingLocation: StateFlow<EncounterLocation?> = _recordingLocation.asStateFlow()
    private val _speechStatus = MutableStateFlow<SpeechStatus?>(null)
    val speechStatus: StateFlow<SpeechStatus?> = _speechStatus.asStateFlow()
    private var player: android.media.MediaPlayer? = null
    /** Optional Gemma 4 E2B through LiteRT-LM. Weights live outside backups; nothing downloads without a tap. */
    val localModel: LocalReportModel = localModel ?: LocalReportModel(
        ModelStore(File(application.noBackupFilesDir, "models")), File(application.cacheDir, "litertlm"),
        readiness = LocalReportModel.readiness(application),
    )
    private val memory = object : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) {
            // Like iOS MemoryPressurePolicy: release an idle model first, never interrupt saved work silently.
            if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND && !_busy.value) this@AppViewModel.localModel.unload()
        }
        override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {}
        @Deprecated("Deprecated in Java") override fun onLowMemory() { if (!_busy.value) this@AppViewModel.localModel.unload() }
    }
    init { application.registerComponentCallbacks(memory) }
    private val importer by lazy { AttachmentImporter(application, File(application.noBackupFilesDir, "scratch")) }

    init { open() }

    fun open() {
        viewModelScope.launch {
            try {
                val loaded = repository.load()
                val recovered = ChatOperations.recoverInterrupted(loaded)
                if (recovered != loaded) repository.save(recovered)
                _document.value = recovered
                recoverAudio()
                _vocabulary.value = repository.vocabulary()
                _online.value = repository.onlineConfiguration()
                _hasKey.value = repository.apiKey() != null
                _ready.value = true
            } catch (error: AppFailure) {
                _error.value = "Lokale Daten konnten nicht geöffnet werden: " + error.message
            }
        }
    }

    fun dismissError() { _error.value = null }
    fun reportError(message: String) { _error.value = message }
    fun encounter(location: EncounterLocation): Encounter? = CaseOperations.encounter(_document.value, location)

    /** Applies and persists a change. The visible document only changes after a successful save. */
    private suspend fun commit(failurePrefix: String = "", change: (VaultDocument) -> VaultDocument): Boolean = writes.withLock {
        try {
            val next = change(_document.value)
            if (next !== _document.value) repository.save(next)
            _document.value = next
            true
        } catch (error: AppFailure) {
            _error.value = failurePrefix + error.message
            false
        }
    }

    /** Creates the dictation and reports the new location on the main thread, so the UI can navigate. */
    fun newEncounter(caseID: String? = null, then: (EncounterLocation) -> Unit) {
        if (_busy.value) return
        viewModelScope.launch {
            var location: EncounterLocation? = null
            val saved = commit("Das Diktat konnte nicht angelegt werden: ") { document ->
                val (next, created) = CaseOperations.newEncounter(document, caseID) ?: throw AppFailure("Dieser Fall ist nicht mehr vorhanden.")
                location = created
                next
            }
            if (saved) location?.let(then)
        }
    }

    fun updateCase(caseID: String, label: String, species: String, animalName: String, then: () -> Unit) {
        viewModelScope.launch { if (commit { CaseOperations.updateCase(it, caseID, label, species, animalName) }) then() }
    }

    fun deleteCase(caseID: String) {
        if (_busy.value) return
        val reportIDs = _document.value.cases.firstOrNull { it.id == caseID }?.encounters?.flatMap { it.reports }?.map { it.id }.orEmpty()
        viewModelScope.launch {
            if (commit { CaseOperations.deleteCase(it, caseID) }) {
                runCatching { repository.removeCaseFiles(caseID) }
                exports.remove(reportIDs)
            }
        }
    }

    suspend fun saveTranscript(text: String, location: EncounterLocation): Boolean {
        if (_busy.value) return false
        return commit("Text konnte nicht gespeichert werden: ") { CaseOperations.saveTranscript(it, location, text) }
    }

    /** Saves text left in an editor that is closing; runs in the view model so it outlives the screen. */
    fun flushTranscript(text: String, location: EncounterLocation) { viewModelScope.launch { saveTranscript(text, location) } }

    fun saveReportEdit(text: String, reportID: String, location: EncounterLocation, then: () -> Unit) {
        viewModelScope.launch { if (commit { CaseOperations.saveReportEdit(it, location, reportID, text) }) then() }
    }

    fun approve(reportID: String, location: EncounterLocation) {
        viewModelScope.launch { commit("Speichern fehlgeschlagen: ") { CaseOperations.approve(it, location, reportID) } }
    }

    fun recordShare(reportID: String, format: String, location: EncounterLocation) {
        viewModelScope.launch { commit("Speichern fehlgeschlagen: ") { CaseOperations.recordShare(it, location, reportID, format) } }
    }

    fun saveVocabulary(entries: List<VocabularyEntry>) {
        viewModelScope.launch {
            writes.withLock {
                try { repository.saveVocabulary(entries); _vocabulary.value = entries } catch (error: AppFailure) { _error.value = error.message }
            }
        }
    }

    fun cancel() { work?.cancel() }

    // Recording and transcription --------------------------------------------------------------------

    val captureInProgress: Boolean get() = recorder.recording.value

    /** Starts only after the case is durably stored; every finished segment is sealed before it counts. */
    fun record(location: EncounterLocation) {
        if (_busy.value || recorder.recording.value || encounter(location) == null) return
        viewModelScope.launch {
            try {
                stopPlayback(); localModel.unload()
                recorder.onSegment = { wav, segment ->
                    repository.storeAudio(location.caseID, location.encounterID, segment.id, wav)
                    persist { document -> document.mapEncounter(location) { if (it.audio.any { a -> a.id == segment.id }) it else it.copy(audio = it.audio + segment) } }
                }
                recorder.onInterruption = { markInterrupted(location) }
                _recordingLocation.value = location
                recorder.start(location.caseID, location.encounterID, viewModelScope)
                persist { document -> document.mapEncounter(location) { it.copy(state = EncounterState.RECORDING, lastError = null) } }
            } catch (error: Exception) {
                if (recorder.recording.value) { recorder.pause(); markInterrupted(location) }
                _error.value = (error as? AppFailure)?.message ?: "Die Aufnahme konnte nicht gestartet werden: ${error.message}"
            }
        }
    }

    fun pauseRecording(then: () -> Unit = {}) {
        val location = _recordingLocation.value
        if (location == null || !recorder.recording.value) return then()
        viewModelScope.launch {
            recorder.pause()
            val problem = recorder.error.value
            runCatching { persist { document -> document.mapEncounter(location) { it.copy(state = if (problem == null) EncounterState.PAUSED else EncounterState.INTERRUPTED, lastError = problem) } } }
                .onFailure { _error.value = "Speichern fehlgeschlagen: " + it.message }
            then()
        }
    }

    private suspend fun markInterrupted(location: EncounterLocation) {
        runCatching { persist { document -> document.mapEncounter(location) { it.copy(state = EncounterState.INTERRUPTED, lastError = recorder.error.value) } } }
    }

    /** Local speech recognition of all audio that has no transcript yet. Nothing leaves the device. */
    fun transcribe(location: EncounterLocation) {
        val current = encounter(location) ?: return
        if (_busy.value || recorder.recording.value) return
        val done = current.transcripts.flatMap { it.segments }.mapNotNull { it.audioID }.toSet()
        val pending = current.audio.filter { it.id !in done }
        if (pending.isEmpty()) { _error.value = "Keine neuen Audiosegmente vorhanden."; return }
        run(location, EncounterState.TRANSCRIBING) {
            val recognized = mutableListOf<de.tobwil.vetmed.core.TranscriptSegment>()
            for ((index, segment) in pending.withIndex()) {
                _workStatus.value = "Transkription ${index + 1} von ${pending.size} · auf diesem Gerät"
                val wav = repository.audio(location.caseID, location.encounterID, segment.id)
                recognized += TranscriptBuilder.audioSentences(transcriber.transcribe(wav, segment.id))
            }
            if (recognized.isEmpty()) throw AppFailure("Kein verständlicher Text erkannt. Die Aufnahme bleibt erhalten.")
            persist { document ->
                document.mapEncounter(location) { encounter ->
                    val previous = encounter.transcripts.lastOrNull()
                    val segments = previous?.segments.orEmpty() + recognized
                    val raw = listOf(previous?.rawText.orEmpty(), recognized.joinToString("\n") { it.text }).filter { it.isNotEmpty() }.joinToString("\n")
                    val version = de.tobwil.vetmed.core.TranscriptVersion(
                        parentID = previous?.id, rawText = raw, editedText = segments.joinToString("\n") { it.text }, segments = segments, engine = transcriber.engineName,
                    )
                    encounter.copy(transcripts = encounter.transcripts + version, state = EncounterState.TRANSCRIPT_READY)
                }
            }
        }
    }

    fun play(segment: de.tobwil.vetmed.core.TranscriptSegment, location: EncounterLocation) {
        val id = segment.audioID ?: return
        if (_busy.value || recorder.recording.value || encounter(location)?.audio?.none { it.id == id } != false) return
        viewModelScope.launch {
            try {
                stopPlayback()
                val file = File(scratch, "playback-${de.tobwil.vetmed.core.newId()}.wav").apply { parentFile?.mkdirs() }
                withContext(kotlinx.coroutines.Dispatchers.IO) { file.writeBytes(repository.audio(location.caseID, location.encounterID, id)) }
                player = android.media.MediaPlayer().apply {
                    setDataSource(file.absolutePath); prepare(); file.delete()
                    seekTo(((segment.startSeconds ?: 0.0) * 1000).toInt()); start()
                    setOnCompletionListener { stopPlayback() }
                }
            } catch (error: AppFailure) { _error.value = error.message }
            catch (error: Exception) { _error.value = "Die Aufnahme konnte nicht abgespielt werden." }
        }
    }

    private fun stopPlayback() { player?.runCatching { stop(); release() }; player = null }

    fun refreshSpeechStatus() { viewModelScope.launch { _speechStatus.value = runCatching { transcriber.status() }.getOrDefault(SpeechStatus.UNSUPPORTED) } }

    fun installSpeech() {
        if (_busy.value) return
        _busy.value = true; _workStatus.value = "Deutsche Sprachressourcen werden installiert"
        work = viewModelScope.launch {
            try {
                transcriber.install { percent -> _workStatus.value = "Sprachressourcen: $percent %" }
                _speechStatus.value = transcriber.status()
            } catch (error: CancellationException) { _error.value = "Installation abgebrochen." }
            catch (error: Exception) { _error.value = error.message }
            finally { _busy.value = false; _workStatus.value = ""; work = null }
        }
    }

    /** Recording segments left unencrypted by a crash are sealed into their case; foreign leftovers are removed. */
    private suspend fun recoverAudio() {
        for (leftover in AudioRecorder.leftovers(scratch)) {
            val location = EncounterLocation(leftover.caseID, leftover.encounterID)
            if (encounter(location) == null) { leftover.file.delete(); continue }
            val pcm = withContext(kotlinx.coroutines.Dispatchers.IO) { leftover.file.readBytes() }
            val segment = de.tobwil.vetmed.core.AudioSegment(id = leftover.segmentID, duration = de.tobwil.vetmed.core.Wav.duration(pcm.size.toLong()), recovered = true)
            repository.storeAudio(leftover.caseID, leftover.encounterID, leftover.segmentID, de.tobwil.vetmed.core.Wav.wrap(pcm))
            persist { document ->
                document.mapEncounter(location) {
                    it.copy(audio = if (it.audio.any { a -> a.id == segment.id }) it.audio else it.audio + segment, state = EncounterState.INTERRUPTED,
                        lastError = "Eine unterbrochene Aufnahme wurde verschlüsselt gesichert.")
                }
            }
            leftover.file.delete()
        }
        scratch.listFiles().orEmpty().filter { it.name.startsWith("transcribe-") || it.name.startsWith("playback-") || it.name.startsWith("pdf-import-") }.forEach { it.delete() }
    }

    fun background() {
        stopPlayback()
        if (recorder.recording.value) pauseRecording()
        if (!_busy.value) localModel.unload()
    }

    override fun onCleared() {
        stopPlayback(); localModel.unload()
        getApplication<Application>().unregisterComponentCallbacks(memory)
        super.onCleared()
    }

    // Offline model ------------------------------------------------------------------------------------

    /** Explicit download of the pinned model, resumable and verified. Cancel keeps the partial file. */
    fun installModel() {
        if (_busy.value || recorder.recording.value) return
        _busy.value = true; _error.value = null; _workStatus.value = "Offline-Modell wird geladen"
        work = viewModelScope.launch {
            val progress = launch { localModel.progress.collect { value -> value?.let { _workStatus.value = "Offline-Modell: ${(it * 100).toInt()} %" } } }
            try { localModel.install() }
            catch (error: CancellationException) { _error.value = "Download pausiert. Er wird beim nächsten Mal an derselben Stelle fortgesetzt." }
            catch (error: Exception) { _error.value = error.message }
            finally { progress.cancel(); localModel.refresh(); _busy.value = false; _workStatus.value = ""; work = null }
        }
    }

    fun unloadModel() { if (!_busy.value) localModel.unload() }

    fun deleteModel() {
        if (_busy.value) return
        viewModelScope.launch {
            try { localModel.delete() } catch (error: Exception) { _error.value = error.message }
        }
    }

    // Chat ---------------------------------------------------------------------------------------------

    fun chatContext(location: ChatLocation): Encounter? = ChatOperations.context(_document.value, location)

    fun newQuickCheck(then: (ChatLocation) -> Unit) {
        if (_busy.value) return
        viewModelScope.launch {
            var location: ChatLocation? = null
            if (commit("Der Chat konnte nicht angelegt werden: ") { document -> ChatOperations.newQuickCheck(document).also { location = it.second }.first }) location?.let(then)
        }
    }

    fun deleteQuickCheck(id: String, then: () -> Unit) {
        if (_busy.value) return
        viewModelScope.launch {
            if (commit { ChatOperations.deleteQuickCheck(it, id) }) { runCatching { repository.removeQuickCheckFiles(id) }; then() }
        }
    }

    suspend fun saveSparringDraft(draft: SparringDraft, location: ChatLocation): Boolean =
        commit("Entwurf konnte nicht gespeichert werden: ") { ChatOperations.saveDraft(it, location, draft) }

    /** Saves a draft left in a closing chat; runs in the view model so it outlives the screen. */
    fun flushDraft(draft: SparringDraft, location: ChatLocation) { viewModelScope.launch { saveSparringDraft(draft, location) } }

    fun importAttachment(uri: Uri, location: ChatLocation, then: (ChatAttachment) -> Unit) {
        if (_busy.value) return
        _busy.value = true; _error.value = null; _workStatus.value = "Anhang wird lokal vorbereitet"
        work = viewModelScope.launch {
            try {
                if (chatContext(location) == null) throw AppFailure("Dieser Chat ist nicht mehr vorhanden.")
                val prepared = importer.read(uri)
                repository.storeAttachment(location.caseID, location.encounterID, prepared.attachment.id, prepared.original, prepared.upload)
                if (commit { ChatOperations.addAttachment(it, location, prepared.attachment) }) then(prepared.attachment)
                else repository.removeAttachment(location.caseID, location.encounterID, prepared.attachment.id)
            } catch (error: CancellationException) {
                _error.value = "Import abgebrochen."
            } catch (error: AppFailure) {
                _error.value = error.message
            } finally {
                _busy.value = false; _workStatus.value = ""; work = null
            }
        }
    }

    suspend fun attachmentData(location: ChatLocation, id: String, upload: Boolean): ByteArray {
        if (chatContext(location)?.chatAttachments?.any { it.id == id } != true) throw AppFailure("Dieser Anhang ist nicht verfügbar.")
        return repository.attachmentData(location.caseID, location.encounterID, id, upload)
    }

    fun reviewDocument(location: ChatLocation, id: String, text: String, then: () -> Unit) {
        viewModelScope.launch { if (commit("Der geprüfte Text konnte nicht gespeichert werden: ") { ChatOperations.reviewDocument(it, location, id, text) }) then() }
    }

    /** Streams one answer. The run is persisted before anything is sent; partial text is checkpointed. */
    fun startAnalysis(snapshot: SparringSnapshot) {
        if (_busy.value) return
        val location = ChatLocation(snapshot.caseID, snapshot.encounterID)
        val configuration = _online.value
        if (!configuration.isEnabled || !_hasKey.value || configuration.modelID != snapshot.modelID) {
            _error.value = "Bitte zuerst den API-Zugang in den Chat-Details einrichten."; return
        }
        try { ChatOperations.checkAnalysisBudget(_document.value, location) } catch (error: AppFailure) { _error.value = error.message; return }
        val analysis = AnalysisRun(snapshot = snapshot)
        _busy.value = true; _error.value = null; _workStatus.value = "Chat · OpenAI · Antwort wird angefordert"
        work = viewModelScope.launch {
            _activeAnalysisID.value = analysis.id
            var checkpoint = 0L; var checkpointBytes = 0
            try {
                val key = repository.apiKey() ?: throw AppFailure("Der API-Key fehlt.")
                val images = snapshot.requestImages.orEmpty().associate { reference ->
                    reference.attachmentID to repository.attachmentData(location.caseID, location.encounterID, reference.attachmentID, true)
                }
                SparringService().run(
                    snapshot, key, images,
                    beforeSending = { persist { ChatOperations.mapChat(it, location) { chat -> chat.copy(analysisRuns = chat.analysisRuns.orEmpty() + analysis) } } },
                    receive = { update ->
                        val change: (AnalysisRun) -> AnalysisRun = when (update) {
                            is AnalysisStreamUpdate.Text -> { run -> run.copy(status = AnalysisStatus.STREAMING, text = update.text) }
                            is AnalysisStreamUpdate.Terminal -> { run ->
                                run.copy(status = update.status, text = update.text, actualModelID = update.model, usage = update.usage, notice = update.notice)
                            }
                        }
                        val next = ChatOperations.updateRun(_document.value, location, analysis.id, change)
                        _workStatus.value = "Chat · Antwort läuft"
                        val bytes = (update as? AnalysisStreamUpdate.Text)?.text?.length ?: Int.MAX_VALUE
                        val time = System.currentTimeMillis()
                        if (update is AnalysisStreamUpdate.Terminal || time - checkpoint >= 1000 || bytes - checkpointBytes >= 8192) {
                            persist { next }; checkpoint = time; checkpointBytes = bytes
                        } else _document.value = next
                    },
                )
            } catch (error: CancellationException) {
                withContext(NonCancellable) {
                    runCatching { persist { ChatOperations.updateRun(it, location, analysis.id) { run -> run.copy(status = AnalysisStatus.CANCELLED, notice = "Bewusst abgebrochen. Der Anbieter kann den Auftrag bereits berechnet haben. Kein automatischer Neuversand.") } } }
                }
            } catch (error: Exception) {
                val message = error.message ?: "Unbekannter Fehler"
                runCatching { persist { ChatOperations.updateRun(it, location, analysis.id) { run -> run.copy(status = AnalysisStatus.FAILED, notice = message) } } }
                _error.value = message
            } finally {
                _activeAnalysisID.value = null; _busy.value = false; _workStatus.value = ""; work = null
            }
        }
    }

    /** Online with the user's own key or offline with the local model, as chosen. Never a silent switch between them. */
    fun generate(location: EncounterLocation, template: ReportTemplate, length: ReportLength, mode: ReportExecutionMode) {
        if (_busy.value) return
        val transcript = encounter(location)?.transcripts?.lastOrNull() ?: run { _error.value = "Bitte zuerst das Transkript speichern."; return }
        val configuration = _online.value
        run(location) {
            val engine: ReportTextEngine = if (mode == ReportExecutionMode.OFFLINE) {
                _workStatus.value = "Offline-Modell wird geprüft und geladen"
                localModel.load()
                localModel
            } else {
            val key = repository.apiKey()
            if (!configuration.isEnabled || key == null) {
                throw AppFailure("Bitte Online-Berichte in Einstellungen mit deinem API-Key aktivieren oder ausdrücklich Offline wählen.")
            }
            localModel.unload()
            OpenAIReportEngine(
                configuration, key, template.sections,
                record = { payload, modelID ->
                    val request = CloudReportRequest(modelID = modelID, transcriptVersionID = transcript.id, payload = Base64.getEncoder().encodeToString(payload))
                    persist { document -> document.mapEncounter(location) { it.copy(cloudReportRequests = it.cloudReportRequests.orEmpty() + request) } }
                    request.id
                },
                finish = { id, status, responseModel ->
                    persist { document ->
                        document.mapEncounter(location) { encounter ->
                            encounter.copy(cloudReportRequests = encounter.cloudReportRequests?.map {
                                if (it.id == id) it.copy(status = status, responseModelID = responseModel) else it
                            })
                        }
                    }
                },
            )
            }
            val report = ReportPipeline(engine).run(
                transcript, template, length, template.audience,
                checkpoint = { value -> persist { document -> document.mapEncounter(location) { it.copy(reportCheckpoint = value) } } },
                progress = { _workStatus.value = it },
            )
            persist { document ->
                document.mapEncounter(location) { it.copy(reports = it.reports + report, reportCheckpoint = null, state = EncounterState.REVIEW_REQUIRED) }
            }
        }
    }

    private suspend fun persist(change: (VaultDocument) -> VaultDocument) = writes.withLock {
        val next = change(_document.value)
        repository.save(next)
        _document.value = next
    }

    private fun run(location: EncounterLocation, state: EncounterState = EncounterState.GENERATING, operation: suspend () -> Unit) {
        _busy.value = true; _error.value = null; _workStatus.value = "Wird vorbereitet"
        work = viewModelScope.launch {
            try {
                persist { document -> document.mapEncounter(location) { it.copy(state = state, lastError = null) } }
                operation()
            } catch (error: CancellationException) {
                withContext(NonCancellable) {
                    runCatching { persist { d -> d.mapEncounter(location) { it.copy(state = EncounterState.INTERRUPTED, lastError = "Abgebrochen") } } }
                }
                _error.value = "Abgebrochen. Gesicherte Inhalte bleiben erhalten."
            } catch (error: Exception) {
                val message = error.message ?: "Unbekannter Fehler"
                runCatching { persist { d -> d.mapEncounter(location) { it.copy(state = EncounterState.FAILED, lastError = message) } } }
                _error.value = message
            } finally {
                _busy.value = false; _workStatus.value = ""; work = null
            }
        }
    }

    // Online access ------------------------------------------------------------------------------

    fun loadOnlineModels(keyDraft: String) {
        launchOnline("Modelle werden geladen") {
            val key = keyDraft.ifEmpty { repository.apiKey() ?: throw AppFailure("Bitte zuerst einen API-Key eingeben.") }
            _onlineModels.value = OpenAIReportApi.models(key)
            _onlineStatus.value = "${_onlineModels.value.size} Modelle verfügbar."
        }
    }

    /** Sends only a fixed synthetic sentence, never case data. */
    fun testOnlineModel(modelID: String, keyDraft: String) {
        launchOnline("Modell wird getestet") {
            val key = keyDraft.ifEmpty { repository.apiKey() ?: throw AppFailure("Bitte zuerst einen API-Key eingeben.") }
            val trial = OnlineReportConfiguration(modelID = modelID.trim(), consentDate = now(), preferredMode = ReportExecutionMode.ONLINE)
            val engine = OpenAIReportEngine(trial, key, ReportTemplate.TREATMENT_REPORT.sections)
            ReportPipeline(engine).run(TranscriptBuilder.edited(OnlineModelCheck.SYNTHETIC_TEXT, null), ReportTemplate.TREATMENT_REPORT, ReportLength.SHORT, ReportTemplate.TREATMENT_REPORT.audience)
            _online.value = OnlineModelCheck.verified(_online.value, modelID.trim())
            repository.saveOnline(_online.value)
            _onlineStatus.value = "Modelltest erfolgreich: ${modelID.trim()} liefert einen prüfbaren Bericht."
        }
    }

    fun saveOnlineConfiguration(modelID: String, keyDraft: String): Boolean {
        val model = modelID.trim()
        return try {
            if (model.isEmpty()) throw AppFailure("Bitte eine Modell-ID auswählen.")
            if (keyDraft.isNotEmpty()) validateApiKey(keyDraft)
            if (keyDraft.isEmpty() && !_hasKey.value) throw AppFailure("Bitte einen API-Key eingeben.")
            val next = _online.value.copy(modelID = model, consentDate = now(), preferredMode = ReportExecutionMode.ONLINE)
            viewModelScope.launch {
                try {
                    repository.saveOnline(next, keyDraft.ifEmpty { null })
                    _online.value = next; _hasKey.value = true
                    _onlineStatus.value = "Online ist aktiviert und Standard für neue Berichte."
                } catch (error: AppFailure) { _error.value = error.message }
            }
            true
        } catch (error: AppFailure) { _error.value = error.message; false }
    }

    fun removeOnlineKey() {
        viewModelScope.launch {
            try {
                val next = _online.value.copy(consentDate = null, preferredMode = ReportExecutionMode.OFFLINE)
                repository.removeApiKey(next)
                _online.value = next; _hasKey.value = false; _onlineModels.value = emptyList()
                _onlineStatus.value = "API-Key entfernt. Online ist deaktiviert."
            } catch (error: AppFailure) { _error.value = error.message }
        }
    }

    private fun launchOnline(status: String, block: suspend () -> Unit) {
        if (_busy.value) return
        _busy.value = true; _workStatus.value = status; _onlineStatus.value = null
        work = viewModelScope.launch {
            try { block() }
            catch (error: CancellationException) { _onlineStatus.value = "Abgebrochen." }
            catch (error: Exception) { _onlineStatus.value = error.message }
            finally { _busy.value = false; _workStatus.value = ""; work = null }
        }
    }
}
