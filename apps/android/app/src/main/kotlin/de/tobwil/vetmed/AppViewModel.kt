package de.tobwil.vetmed

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import de.tobwil.vetmed.core.AppFailure
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
class AppViewModel(application: Application, private val repository: VaultRepository) : AndroidViewModel(application) {
    /** Used by the default view model factory: cases and secrets sealed with separate Keystore keys, outside backups. */
    constructor(application: Application) : this(
        application,
        VaultRepository(
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

    init { open() }

    fun open() {
        viewModelScope.launch {
            try {
                _document.value = repository.load()
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
        viewModelScope.launch { commit { CaseOperations.deleteCase(it, caseID) } }
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

    /** Online generation with the user's own key. There is no silent fallback to another provider or mode. */
    fun generate(location: EncounterLocation, template: ReportTemplate, length: ReportLength, mode: ReportExecutionMode) {
        if (_busy.value) return
        val transcript = encounter(location)?.transcripts?.lastOrNull() ?: run { _error.value = "Bitte zuerst das Transkript speichern."; return }
        val configuration = _online.value
        run(location) {
            if (mode == ReportExecutionMode.OFFLINE) {
                throw AppFailure("Das Offline-Modell (LiteRT-LM) ist auf Android noch nicht verfügbar. Bitte Online wählen; es wird nichts automatisch gesendet.")
            }
            val key = repository.apiKey()
            if (!configuration.isEnabled || key == null) {
                throw AppFailure("Bitte Online-Berichte in Einstellungen mit deinem API-Key aktivieren.")
            }
            val engine = OpenAIReportEngine(
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

    private fun run(location: EncounterLocation, operation: suspend () -> Unit) {
        _busy.value = true; _error.value = null; _workStatus.value = "Wird vorbereitet"
        work = viewModelScope.launch {
            try {
                persist { document -> document.mapEncounter(location) { it.copy(state = EncounterState.GENERATING, lastError = null) } }
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
