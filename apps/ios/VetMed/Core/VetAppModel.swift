import Foundation
import Darwin
import Combine
import AVFoundation

@MainActor
final class VetAppModel: ObservableObject {
    nonisolated static var isDiagnosticLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--qa-local-report") || ProcessInfo.processInfo.arguments.contains("--qa-offline-speech") || ProcessInfo.processInfo.arguments.contains("--qa-offline-pipeline") || ProcessInfo.processInfo.arguments.contains("--qa-full-pipeline")
        #else
        false
        #endif
    }
    @Published private(set) var document = VaultDocument()
    @Published var error: String?
    @Published var busy = false
    @Published private(set) var recordingActionPending = false
    var captureInProgress: Bool { recordingActionPending || recorder.isRecording || recorder.isTransitioning }
    @Published var workStatus = ""
    @Published private(set) var activeAnalysisID: UUID?
    private let attachmentImporter = ChatAttachmentImporter()
    @Published var locked = true
    @Published var loaded = false
    @Published var selectedQuickCheckID: UUID?
    @Published var selectedCaseID: UUID?
    @Published var selectedEncounterID: UUID?
    @Published var speechStatus = "Wird geprüft"
    @Published private(set) var vocabulary: [VocabularyEntry] = []
    @Published private(set) var onlineConfiguration = OnlineReportConfiguration()
    @Published private(set) var hasOnlineKey = false
    @Published var onlineModels: [String] = []
    @Published var onlineSettingsStatus: String?
    @Published private(set) var testedOnlineModel: String?
    private var onlineStore: OnlineReportStore {
        #if DEBUG
        OnlineReportStore(service: ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "de.tobwil.vetmed.uitest" : "de.tobwil.vetmed.secrets")
        #else
        OnlineReportStore()
        #endif
    }
    #if DEBUG
    @Published var diagnosticResult: String?
    func runOfflineDiagnostics() {
        run { [self] in
            workStatus = "Synthetischer Offline-Gerätetest"
            diagnosticResult = await DeviceQARunner.runOfflinePipeline(engine: model)
        }
    }
    #endif
    let model = MLXLocalReportEngine()
    let recorder = AudioRecorder()
    private var opening = false
    private var deletingRecords = false
    private var repository: CaseRepository?
    private var work: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var pressure: MemoryPressureMonitor?
    var currentCase: VetCase? { document.cases.first { $0.id == selectedCaseID } }
    var currentEncounter: Encounter? { currentCase?.encounters.first { $0.id == selectedEncounterID } }
    init() {
        pressure = MemoryPressureMonitor { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.trimIdleMemory()
                let action = MemoryPressurePolicy.action(availableBytes: os_proc_available_memory(), hasModel: self.model.ready,
                    activeWork: self.busy || self.model.isBusy || self.recorder.isRecording)
                switch action {
                case .reclaimedCaches: break
                case .releaseIdleModel: try? self.model.unload()
                case .stopActiveWork:
                    self.model.requestMemoryStop(); self.work?.cancel()
                    if self.recorder.isRecording { await self.recorder.pause(); await self.markInterrupted() }
                    self.error = "Speicherdruck: laufende Arbeit wurde kontrolliert beendet. Gesicherte Inhalte bleiben erhalten."
                }
            }
        }
    }
    func unlock() async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            #if DEBUG
            let isUITest = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            #else
            let isUITest = false
            #endif
            if !loaded {
                let root = isUITest ? AppPaths.root.appendingPathComponent("UITests") : AppPaths.root
                try AppPaths.prepare(root)
                let secure = SecureStore(service: isUITest ? "de.tobwil.vetmed.uitest" : "de.tobwil.vetmed.secrets")
                let key = try secure.vaultKey(existingData: CaseRepository.hasExistingData(at: root))
                let repository = try CaseRepository(root: root, key: key)
                self.repository = repository
                document = try await repository.load()
                vocabulary = try await repository.vocabulary()
                do {
                    onlineConfiguration = try onlineStore.configuration()
                    hasOnlineKey = try onlineStore.key() != nil
                } catch {
                    onlineConfiguration = .init(); hasOnlineKey = false
                    self.error = "Lokale Fälle wurden geöffnet. Online-Einstellungen konnten nicht gelesen werden; bitte den API-Zugang neu einrichten."
                }
                for c in document.cases.indices {
                    for e in document.cases[c].encounters.indices where [.recording, .transcribing, .generating].contains(document.cases[c].encounters[e].state) {
                        document.cases[c].encounters[e].state = .interrupted
                    }
                }
                for c in document.cases.indices {
                    for e in document.cases[c].encounters.indices { document.cases[c].encounters[e].recoverInterruptedAnalysis() }
                }
                for index in (document.quickChecks ?? []).indices {
                    var context = document.quickChecks![index].analysisContext
                    context.recoverInterruptedAnalysis()
                    document.quickChecks?[index].runs = context.analysisRuns ?? []
                    document.quickChecks?[index].chatAttachments = context.chatAttachments
                }
                loaded = true
                do { try await recoverAudio(); try await persist(); try await repository.cleanUnreferencedAttachments(document) }
                catch { self.error = "Vorhandene Fälle wurden geöffnet. Wiederherstellung oder Speichern ist noch nicht vollständig: " + error.localizedDescription }
            }
            try AppPaths.clean(AppPaths.exports)
            locked = false
            speechStatus = await AppleOfflineTranscriber.status()
        } catch { self.error = error.localizedDescription }
    }
    func background() async {
        locked = true; player?.stop(); player = nil
        work?.cancel()
        if recorder.isRecording { await recorder.pause(); await markInterrupted() }
        if !model.isBusy { try? model.unload() }
    }
    func newEncounter(caseID: UUID? = nil) async {
        guard !busy, !captureInProgress else { return }
        var id = caseID
        if id == nil {
            let item = VetCase(label: "Fall \(document.cases.count + 1)", species: "Nicht angegeben")
            document.cases.insert(item, at: 0); id = item.id
        }
        guard let c = document.cases.firstIndex(where: { $0.id == id }) else { return }
        let encounter = Encounter()
        document.cases[c].encounters.insert(encounter, at: 0)
        selectedQuickCheckID = nil; selectedCaseID = id; selectedEncounterID = encounter.id
        await saveOrReport()
    }
    func updateCase(label: String, species: String, animalName: String) async {
        guard !deletingRecords, let c = document.cases.firstIndex(where: { $0.id == selectedCaseID }) else { return }
        document.cases[c].label = label; document.cases[c].species = species; document.cases[c].animalName = animalName
        await saveOrReport()
    }
    func deleteCase(_ id: UUID) async {
        guard !busy, !captureInProgress, let repository else { return }
        deletingRecords = true; busy = true; workStatus = "Fall wird gelöscht"
        defer { deletingRecords = false; busy = false; workStatus = "" }
        do {
            var next = document; next.cases.removeAll { $0.id == id }
            try await repository.save(next); document = next
            try await repository.removeCaseFiles(id)
            if selectedCaseID == id { selectedCaseID = nil; selectedEncounterID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func select(_ c: VetCase, _ e: Encounter) { guard !busy, !captureInProgress else { return }; selectedQuickCheckID = nil; selectedCaseID = c.id; selectedEncounterID = e.id }
    func saveTranscript(_ text: String, caseID: UUID? = nil, encounterID: UUID? = nil) async {
        guard !busy, !captureInProgress, let c = caseID ?? selectedCaseID, let e = encounterID ?? selectedEncounterID,
              let encounter = document.cases.first(where: { $0.id == c })?.encounters.first(where: { $0.id == e }) else { return }
        let previous = encounter.transcripts.last
        guard previous?.editedText != text else { return }
        let version = TranscriptBuilder.edited(text, previous: previous)
        mutate(caseID: c, encounterID: e) { $0.transcripts.append(version); $0.state = .transcriptReady }
        await saveOrReport()
    }
    func record() async {
        guard !busy, !captureInProgress, let c = selectedCaseID, let e = selectedEncounterID else { return }
        recordingActionPending = true
        defer { recordingActionPending = false }
        do {
            // Never begin capturing for a case that has not reached durable storage.
            try await persist()
            try model.unload()
            player?.stop(); player = nil
            recorder.onSegment = { [weak self] data, segment in
                guard let self, let repository = self.repository else { throw AppFailure("Fallspeicher ist nicht geöffnet.") }
                try await repository.storeAudio(data, caseID: c, encounterID: e, segmentID: segment.id)
                self.mutate(caseID: c, encounterID: e) { if !$0.audio.contains(where: { $0.id == segment.id }) { $0.audio.append(segment) } }
                try await self.persist()
            }
            recorder.onInterruption = { [weak self] in await self?.markInterrupted(caseID: c, encounterID: e) }
            try await recorder.start(caseID: c, encounterID: e)
            if recorder.isRecording { mutate(caseID: c, encounterID: e) { $0.state = .recording } }; try await persist()
        } catch {
            if recorder.isRecording { await recorder.pause(); await markInterrupted(caseID: c, encounterID: e) }
            self.error = error.localizedDescription
        }
    }
    func pauseRecording() async {
        guard !recordingActionPending, let c = selectedCaseID, let e = selectedEncounterID else { return }
        recordingActionPending = true
        defer { recordingActionPending = false }
        await recorder.pause()
        mutate(caseID: c, encounterID: e) { $0.state = recorder.error == nil ? .paused : .interrupted; $0.lastError = recorder.error }
        await saveOrReport()
    }
    func markInterrupted(caseID: UUID? = nil, encounterID: UUID? = nil) async {
        mutate(caseID: caseID, encounterID: encounterID) { $0.state = .interrupted; $0.lastError = recorder.error }
        await saveOrReport()
    }
    func transcribe() {
        guard !busy, !captureInProgress, let c = selectedCaseID, let e = currentEncounter, let repository else { return }
        let existingAudio = Set(e.transcripts.flatMap(\.segments).compactMap(\.audioID))
        let pending = e.audio.filter { !existingAudio.contains($0.id) }
        guard !pending.isEmpty else { error = "Keine neuen Audiosegmente vorhanden."; return }
        run(state: .transcribing) { [self] in
            try model.unload()
            var newSegments: [TranscriptSegment] = []
            for (index, segment) in pending.enumerated() {
                try Task.checkCancellation(); workStatus = "Transkription \(index + 1) von \(pending.count) · auf diesem Gerät"
                let data = try await repository.audio(caseID: c, encounterID: e.id, segmentID: segment.id)
                let file = AppPaths.scratch.appendingPathComponent("transcribe-\(segment.id).caf")
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                defer { try? FileManager.default.removeItem(at: file) }
                newSegments += TranscriptBuilder.audioSentences(try await AppleOfflineTranscriber().transcribe(file: file, audioID: segment.id))
            }
            guard !newSegments.isEmpty else { throw AppFailure("Kein verständlicher Text erkannt. Die Aufnahme bleibt erhalten.") }
            let previous = e.transcripts.last
            let segments = (previous?.segments ?? []) + newSegments
            let text = segments.map(\.text).joined(separator: "\n")
            let raw = [previous?.rawText ?? "", newSegments.map(\.text).joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n")
            let version = TranscriptVersion(parentID: previous?.id, rawText: raw, editedText: text, segments: segments, engine: "Apple SpeechAnalyzer · de-DE · offline")
            mutate(caseID: c, encounterID: e.id) { $0.transcripts.append(version); $0.state = .transcriptReady }
            try await persist()
        }
    }
    func generate(template: ReportTemplate, length: ReportLength, audience: Audience, mode: ReportExecutionMode) {
        guard let c = selectedCaseID, let e = selectedEncounterID, let transcript = currentEncounter?.transcripts.last else { error = "Bitte zuerst das Transkript speichern."; return }
        let configuration = onlineConfiguration
        run(state: .generating) { [self] in
            let engine: any ReportTextEngine
            switch mode {
            case .offline:
                try await model.load(); engine = model
            case .online:
                guard configuration.isEnabled, let key = try onlineStore.key() else { throw AppFailure("Bitte Online-Berichte in Einstellungen mit deinem API-Key aktivieren oder ausdrücklich Offline wählen.") }
                try model.unload()
                engine = OpenAIReportEngine(configuration: configuration, key: key, sections: template.sections, record: { [self] payload, modelID in
                    let value = CloudReportRequest(modelID: modelID, transcriptVersionID: transcript.id, payload: payload)
                    mutate(caseID: c, encounterID: e) { $0.cloudReportRequests = ($0.cloudReportRequests ?? []) + [value] }
                    try await persist()
                    return value.id
                }, finish: { [self] id, status, responseModel in
                    mutate(caseID: c, encounterID: e) { encounter in
                        if let index = encounter.cloudReportRequests?.firstIndex(where: { $0.id == id }) {
                            encounter.cloudReportRequests?[index].status = status
                            encounter.cloudReportRequests?[index].responseModelID = responseModel
                        }
                    }
                    try await persist()
                })
            }
            let report = try await ReportPipeline(engine: engine).run(transcript: transcript, template: template, length: length, audience: audience, checkpoint: { [self] value in
                mutate(caseID: c, encounterID: e) { $0.reportCheckpoint = value }
                try await persist()
            }) { workStatus = $0 }
            mutate(caseID: c, encounterID: e) { $0.reports.append(report); $0.reportCheckpoint = nil; $0.state = .reviewRequired }
            try await persist()
        }
    }
    func analysisContext(caseID: UUID?, encounterID: UUID) -> Encounter? {
        if let caseID { return document.cases.first { $0.id == caseID }?.encounters.first { $0.id == encounterID } }
        return document.quickChecks?.first { $0.id == encounterID }?.analysisContext
    }
    private func mutateAnalysis(caseID: UUID?, encounterID: UUID, _ change: (inout Encounter) -> Void) {
        if let caseID { mutate(caseID: caseID, encounterID: encounterID, change); return }
        guard let index = document.quickChecks?.firstIndex(where: { $0.id == encounterID }) else { return }
        var context = document.quickChecks![index].analysisContext
        change(&context)
        document.quickChecks?[index].draft = context.sparringDraft ?? .init()
        document.quickChecks?[index].runs = context.analysisRuns ?? []
        document.quickChecks?[index].chatAttachments = context.chatAttachments
    }
    func newQuickCheck() async {
        guard !busy, !captureInProgress else { return }
        let check = QuickCheck()
        document.quickChecks = [check] + (document.quickChecks ?? [])
        selectedQuickCheckID = check.id; selectedCaseID = nil; selectedEncounterID = nil
        await saveOrReport()
    }
    func selectQuickCheck(_ id: UUID) {
        guard !busy, !captureInProgress, document.quickChecks?.contains(where: { $0.id == id }) == true else { return }
        selectedQuickCheckID = id; selectedCaseID = nil; selectedEncounterID = nil
    }
    func deleteQuickCheck(_ id: UUID) async {
        guard !busy, !captureInProgress, let repository else { return }
        deletingRecords = true; busy = true; workStatus = "Schnellcheck wird gelöscht"
        defer { deletingRecords = false; busy = false; workStatus = "" }
        do {
            var next = document; next.quickChecks?.removeAll { $0.id == id }
            if next.quickChecks?.isEmpty == true { next.quickChecks = nil }
            try await repository.save(next); document = next
            if selectedQuickCheckID == id { selectedQuickCheckID = nil }
            try await repository.removeQuickCheckFiles(id)
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func saveSparringDraft(_ draft: SparringDraft, caseID: UUID?, encounterID: UUID) async -> Bool {
        guard !deletingRecords else { return false }
        do {
            try draft.validate()
            guard analysisContext(caseID: caseID, encounterID: encounterID) != nil else { return false }
            mutateAnalysis(caseID: caseID, encounterID: encounterID) { $0.sparringDraft = draft }
            try await persist(); return true
        } catch { self.error = "Entwurf konnte nicht gespeichert werden: " + error.localizedDescription; return false }
    }
    func importChatAttachment(url: URL, caseID: UUID?, encounterID: UUID, removeAfterImport: Bool = false, completion: @escaping @MainActor (ChatAttachment) -> Void) {
        var importStarted = false
        defer { if removeAfterImport && !importStarted { try? FileManager.default.removeItem(at: url) } }
        guard !busy, !captureInProgress, let repository, let context = analysisContext(caseID: caseID, encounterID: encounterID) else { return }
        guard (context.chatAttachments?.count ?? 0) < 30,
              document.cases.flatMap(\.encounters).reduce(0, { $0 + ($1.chatAttachments?.count ?? 0) }) + (document.quickChecks ?? []).reduce(0, { $0 + ($1.chatAttachments?.count ?? 0) }) < 200 else {
            error = "Das lokale Anhangslimit ist erreicht. Bitte nicht mehr benötigte Chats oder Fälle löschen."; return
        }
        importStarted = true
        run(onFinish: { if removeAfterImport { try? FileManager.default.removeItem(at: url) } }) { [self] in
            try model.unload(); workStatus = "Anhang wird lokal vorbereitet"
            let prepared = try await attachmentImporter.read(url: url)
            try Task.checkCancellation()
            try await repository.storeAttachment(prepared, caseID: caseID, encounterID: encounterID)
            mutateAnalysis(caseID: caseID, encounterID: encounterID) { $0.chatAttachments = ($0.chatAttachments ?? []) + [prepared.attachment] }
            do { try await persist() }
            catch {
                mutateAnalysis(caseID: caseID, encounterID: encounterID) { $0.chatAttachments?.removeAll { $0.id == prepared.attachment.id } }
                try? await repository.removeAttachment(caseID: caseID, encounterID: encounterID, id: prepared.attachment.id)
                throw error
            }
            completion(prepared.attachment)
        }
    }
    func chatAttachmentData(caseID: UUID?, encounterID: UUID, id: UUID, upload: Bool) async throws -> Data {
        guard !captureInProgress, let repository, analysisContext(caseID: caseID, encounterID: encounterID)?.chatAttachments?.contains(where: { $0.id == id }) == true else { throw AppFailure("Dieser Anhang ist nicht verfügbar.") }
        if !model.isBusy { try model.unload() }
        return try await repository.attachmentData(caseID: caseID, encounterID: encounterID, id: id, upload: upload)
    }
    @discardableResult
    func reviewChatDocument(caseID: UUID?, encounterID: UUID, id: UUID, text: String) async -> Bool {
        guard !deletingRecords, text.utf8.count <= 400_000,
              let previous = analysisContext(caseID: caseID, encounterID: encounterID)?.chatAttachments?.first(where: { $0.id == id && $0.kind == .document }) else { return false }
        mutateAnalysis(caseID: caseID, encounterID: encounterID) { encounter in
            guard let index = encounter.chatAttachments?.firstIndex(where: { $0.id == id }) else { return }
            encounter.chatAttachments?[index].reviewedText = text
            encounter.chatAttachments?[index].reviewedAt = Date()
        }
        do { try await persist(); return true }
        catch {
            mutateAnalysis(caseID: caseID, encounterID: encounterID) { encounter in
                if let index = encounter.chatAttachments?.firstIndex(where: { $0.id == id }) { encounter.chatAttachments?[index] = previous }
            }
            self.error = "Der geprüfte Text konnte nicht gespeichert werden: " + error.localizedDescription; return false
        }
    }
    func startAnalysis(_ snapshot: SparringSnapshot) {
        guard !busy, !captureInProgress else { return }
        guard onlineConfiguration.isEnabled, hasOnlineKey, onlineConfiguration.modelID == snapshot.modelID else {
            error = "Bitte zuerst den API-Zugang in den Chat-Details einrichten."; return
        }
        guard (snapshot.caseID == nil ? selectedQuickCheckID == snapshot.encounterID : (currentCase?.id == snapshot.caseID && currentEncounter?.id == snapshot.encounterID)), analysisContext(caseID: snapshot.caseID, encounterID: snapshot.encounterID) != nil else { error = "Der ausgewählte Chat wurde geändert. Bitte die Nachricht dort erneut senden."; return }
        let existing = document.cases.flatMap(\.encounters).flatMap { $0.analysisRuns ?? [] } + (document.quickChecks ?? []).flatMap(\.runs)
        guard existing.count < 250, (analysisContext(caseID: snapshot.caseID, encounterID: snapshot.encounterID)?.analysisRuns?.count ?? 0) < 100 else {
            error = "Das lokale Analysebudget ist erreicht. Bitte nicht mehr benötigte Fälle exportieren und löschen oder einen neuen Vorgang verwenden."; return
        }
        run { [self] in
            workStatus = "Sparring · OpenAI · Antwort wird angefordert"
            try model.unload()
            guard let key = try onlineStore.key() else { throw AppFailure("Der API-Key fehlt.") }
            let analysis = AnalysisRun(snapshot: snapshot)
            activeAnalysisID = analysis.id
            defer { activeAnalysisID = nil }
            #if !targetEnvironment(simulator)
            if !(snapshot.requestImages ?? []).isEmpty, os_proc_available_memory() < 256 * 1_048_576 {
                throw AppFailure("Für die Bilder ist gerade zu wenig Arbeitsspeicher frei. Bitte erneut versuchen, sobald mehr Speicher verfügbar ist.")
            }
            #endif
            var imageData: [UUID: Data] = [:]
            guard let repository else { throw AppFailure("Der lokale Speicher ist nicht geöffnet.") }
            for reference in snapshot.requestImages ?? [] where imageData[reference.attachmentID] == nil {
                imageData[reference.attachmentID] = try await repository.attachmentData(caseID: snapshot.caseID, encounterID: snapshot.encounterID, id: reference.attachmentID, upload: true)
            }
            var checkpoint = Date.distantPast
            var checkpointBytes = 0
            do {
                try await SparringService().run(snapshot: snapshot, key: key, imageData: imageData, beforeSending: { [self] in
                    mutateAnalysis(caseID: snapshot.caseID, encounterID: snapshot.encounterID) {
                        $0.analysisRuns = ($0.analysisRuns ?? []) + [analysis]
                    }
                    try await persist()
                }, receive: { [self] update in
                    var terminal = false
                    mutateAnalysis(caseID: snapshot.caseID, encounterID: snapshot.encounterID) { encounter in
                        guard let index = encounter.analysisRuns?.firstIndex(where: { $0.id == analysis.id }) else { return }
                        switch update {
                        case .text(let text):
                            encounter.analysisRuns?[index].status = .streaming
                            encounter.analysisRuns?[index].text = text
                        case .terminal(let status, let text, let model, let usage, let notice):
                            terminal = true
                            encounter.analysisRuns?[index].status = status
                            encounter.analysisRuns?[index].text = text
                            encounter.analysisRuns?[index].actualModelID = model
                            encounter.analysisRuns?[index].usage = usage
                            encounter.analysisRuns?[index].notice = notice
                        }
                    }
                    workStatus = "Sparring · Antwort läuft"
                    let bytes = analysisContext(caseID: snapshot.caseID, encounterID: snapshot.encounterID)?.analysisRuns?.first(where: { $0.id == analysis.id })?.text.utf8.count ?? 0
                    if terminal || Date().timeIntervalSince(checkpoint) >= 1 || bytes - checkpointBytes >= 8192 {
                        try await persist(); checkpoint = Date(); checkpointBytes = bytes
                    }
                })
            } catch {
                let cancelled = Task.isCancelled
                mutateAnalysis(caseID: snapshot.caseID, encounterID: snapshot.encounterID) { encounter in
                    guard let index = encounter.analysisRuns?.firstIndex(where: { $0.id == analysis.id }) else { return }
                    encounter.analysisRuns?[index].status = cancelled ? .cancelled : .failed
                    encounter.analysisRuns?[index].notice = cancelled ? "Bewusst abgebrochen. Der Anbieter kann den Auftrag bereits berechnet haben. Kein automatischer Neuversand." : error.localizedDescription
                }
                await saveOrReport()
                throw error
            }
        }
    }
    func saveOnlineConfiguration(modelID: String, keyDraft: String) {
        guard !busy else { return }
        error = nil
        do {
            let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw AppFailure("Bitte eine Modell-ID auswählen.") }
            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let storedKey = try onlineStore.key()
            guard !key.isEmpty || storedKey != nil else { throw AppFailure("Bitte deinen API-Key eintragen.") }
            var configuration = onlineConfiguration
            configuration.modelID = id; configuration.consentDate = Date(); configuration.preferredMode = .online
            configuration.verifiedModelID = testedOnlineModel == id ? id : nil
            configuration.verifiedAt = testedOnlineModel == id ? Date() : nil
            try onlineStore.save(configuration, key: key.isEmpty ? nil : key)
            onlineConfiguration = configuration; hasOnlineKey = true
            onlineSettingsStatus = "Der Online-Zugang ist bereit. Inhalte werden erst beim Senden im Chat oder beim Erstellen eines Online-Berichts übertragen."
        } catch { self.error = error.localizedDescription }
    }
    func resetOnlineModelVerification() { testedOnlineModel = nil }
    func removeOnlineKey() {
        guard !busy else { return }
        do {
            try onlineStore.removeKey(); onlineConfiguration = try onlineStore.configuration(); hasOnlineKey = false
            testedOnlineModel = nil; onlineModels = []; onlineSettingsStatus = "API-Key entfernt."
        } catch { self.error = error.localizedDescription }
    }
    func loadOnlineModels(keyDraft: String) {
        run { [self] in
            workStatus = "Anbietermodelle laden · keine Falldaten"
            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = key.isEmpty ? try onlineStore.key() : key else { throw AppFailure("Bitte API-Key eintragen.") }
            onlineModels = try await OpenAIReportAPI.models(key: value)
            onlineSettingsStatus = "Modellliste geladen. Die Liste bestätigt noch nicht die Eignung für strukturierte Berichte. Bitte das ausgewählte Modell testen."
        }
    }
    func testOnlineModel(modelID: String, keyDraft: String) {
        run { [self] in
            workStatus = "Synthetischer Anbietertest · keine Falldaten"
            testedOnlineModel = nil
            let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = key.isEmpty ? try onlineStore.key() : key else { throw AppFailure("Bitte API-Key eintragen.") }
            let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = OnlineReportConfiguration(modelID: id, consentDate: Date(), preferredMode: .online)
            let engine = OpenAIReportEngine(configuration: config, key: value, sections: ReportTemplate.treatment_report.sections)
            let transcript = TranscriptBuilder.edited("Hund 12,5 kg. Kein Fieber. Temperatur nicht gemessen.", previous: nil)
            _ = try await ReportPipeline(engine: engine).run(transcript: transcript, template: .treatment_report, length: .medium, audience: .veterinarian) { workStatus = $0 }
            testedOnlineModel = id; onlineSettingsStatus = "Synthetischer Verbindungstest bestanden: " + engine.engineRevision + ". Keine fachliche Freigabe."
        }
    }
    func saveReportEdit(_ text: String, report: ReportVersion) async {
        guard text != report.text else { return }
        var revision = report; revision.id = UUID(); revision.parentID = report.id; revision.createdAt = Date()
        revision.editedText = text; revision.approvedAt = nil
        revision.warnings = ["Manuell bearbeitet: Zahlen, Einheiten, Negationen und Quellen erneut prüfen."]
        mutate { $0.reports.append(revision); $0.state = .reviewRequired }; await saveOrReport()
    }
    func approve(_ id: UUID) async {
        mutate { encounter in
            if let i = encounter.reports.firstIndex(where: { $0.id == id }) { encounter.reports[i].approvedAt = Date(); encounter.state = .approved }
        }
        await saveOrReport()
    }
    func recordShare(_ id: UUID, format: String) async { mutate { $0.shares.append(ShareEvent(reportID: id, format: format)) }; await saveOrReport() }
    func play(_ segment: TranscriptSegment) async {
        guard !busy, !captureInProgress, let c = selectedCaseID, let e = selectedEncounterID, let id = segment.audioID, let repository else { return }
        do {
            let data = try await repository.audio(caseID: c, encounterID: e, segmentID: id)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data); player?.currentTime = segment.startSeconds ?? 0; player?.play()
        } catch { self.error = error.localizedDescription }
    }
    func installModel() { run { [self] in try await model.install() } }
    func saveVocabulary(_ entries: [VocabularyEntry]) async {
        guard let repository else { return }
        do { try await repository.saveVocabulary(entries); vocabulary = entries }
        catch { self.error = error.localizedDescription }
    }
    func installSpeech() { run { [self] in try await AppleOfflineTranscriber.install(); speechStatus = await AppleOfflineTranscriber.status() } }
    func cancel() { work?.cancel() }
    private func run(state: EncounterState? = nil, onFinish: (() -> Void)? = nil, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !captureInProgress else { return }
        busy = true; error = nil; workStatus = "Wird vorbereitet"
        if let state { mutate { $0.state = state } }
        work = Task {
            defer { busy = false; work = nil; workStatus = ""; onFinish?() }
            do { try await persist(); try await operation() }
            catch {
                if state != nil { mutate { $0.state = Task.isCancelled ? .interrupted : .failed; $0.lastError = Task.isCancelled ? "Abgebrochen" : error.localizedDescription }; await saveOrReport() }
                self.error = Task.isCancelled ? "Abgebrochen. Gesicherte Inhalte bleiben erhalten." : error.localizedDescription
            }
        }
    }
    private func mutate(caseID: UUID? = nil, encounterID: UUID? = nil, _ change: (inout Encounter) -> Void) {
        guard let c = document.cases.firstIndex(where: { $0.id == (caseID ?? selectedCaseID) }),
              let e = document.cases[c].encounters.firstIndex(where: { $0.id == (encounterID ?? selectedEncounterID) }) else { return }
        change(&document.cases[c].encounters[e])
    }
    private func persist() async throws { guard let repository else { throw AppFailure("Fallspeicher ist noch gesperrt.") }; try await repository.save(document) }
    private func saveOrReport() async { do { try await persist() } catch { self.error = "Speichern fehlgeschlagen: " + error.localizedDescription } }
    private func recoverAudio() async throws {
        try AppPaths.prepare(AppPaths.scratch)
        guard let repository else { return }
        for url in try FileManager.default.contentsOfDirectory(at: AppPaths.scratch, includingPropertiesForKeys: nil) {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_").compactMap { UUID(uuidString: String($0)) }
            if parts.count == 3,
               let c = document.cases.firstIndex(where: { $0.id == parts[0] }),
               let e = document.cases[c].encounters.firstIndex(where: { $0.id == parts[1] }) {
                let data = try Data(contentsOf: url)
                let duration = (try? AVAudioPlayer(data: data).duration) ?? 0
                try await repository.storeAudio(data, caseID: parts[0], encounterID: parts[1], segmentID: parts[2])
                if !document.cases[c].encounters[e].audio.contains(where: { $0.id == parts[2] }) {
                    document.cases[c].encounters[e].audio.append(AudioSegment(id: parts[2], duration: duration, recovered: true))
                }
                document.cases[c].encounters[e].state = .interrupted
                if duration == 0 { document.cases[c].encounters[e].lastError = "Unvollständiges Audio wurde verschlüsselt gesichert. Andere Fälle bleiben verfügbar." }
                try await persist()
                try FileManager.default.removeItem(at: url)
            } else if url.lastPathComponent.hasPrefix("transcribe-") || url.lastPathComponent.hasPrefix("photo-import-") { try FileManager.default.removeItem(at: url) }
        }
        // Audio-file write and metadata transaction are separate durable operations. Recover the
        // encrypted orphan if the app was interrupted between them, without storing a cleartext index.
        for c in document.cases.indices {
            for e in document.cases[c].encounters.indices {
                let caseID = document.cases[c].id, encounterID = document.cases[c].encounters[e].id
                let known = Set(document.cases[c].encounters[e].audio.map(\.id))
                for id in try await repository.storedAudioIDs(caseID: caseID, encounterID: encounterID) where !known.contains(id) {
                    let data = try await repository.audio(caseID: caseID, encounterID: encounterID, segmentID: id)
                    let duration = (try? AVAudioPlayer(data: data).duration) ?? 0
                    document.cases[c].encounters[e].audio.append(AudioSegment(id: id, duration: duration, recovered: true))
                    document.cases[c].encounters[e].state = .interrupted
                    try await persist()
                }
            }
        }
    }
}
