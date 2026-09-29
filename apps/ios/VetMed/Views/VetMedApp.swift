import SwiftUI

@main
struct VetMedApp: App {
    @StateObject private var app = VetAppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app).tint(Color(red: 0.10, green: 0.40, blue: 0.36))
                .overlay { if scenePhase != .active { PrivacyCover() } }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--qa-full-pipeline") {
                        _ = await DeviceQARunner.runOfflinePipeline(engine: app.model, requireOffline: false)
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--qa-offline-pipeline") {
                        _ = await DeviceQARunner.runOfflinePipeline(engine: app.model)
                        return
                    }
                    if ProcessInfo.processInfo.arguments.contains("--qa-local-report") {
                        await DeviceQARunner.run(engine: app.model, repeatCount: ProcessInfo.processInfo.arguments.contains("--qa-memory") ? 10 : 1, testCancellation: ProcessInfo.processInfo.arguments.contains("--qa-memory"))
                        return
                    }
                    #endif
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--qa-offline-speech") {
                        await DeviceQARunner.runSpeech()
                        return
                    }
                    #endif
                    await app.unlock()
                }
                .onChange(of: scenePhase) { _, phase in if phase == .background { Task { await app.background() } } else if phase == .active && app.locked && !VetAppModel.isDiagnosticLaunch { Task { await app.unlock() } } }
        }
    }
}
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) { Image(systemName: "cross.case.fill").font(.system(size: 48)).foregroundStyle(.teal); Text("VetMed").font(.largeTitle.bold()); Text("Deine Fälle bleiben geschützt.").foregroundStyle(.secondary) }
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var tab = 0
    var body: some View {
        Group {
            if VetAppModel.isDiagnosticLaunch {
                DeviceDiagnosticsView(model: app.model)
            } else if app.locked {
                ZStack {
                    PrivacyCover()
                    VStack { Spacer(); Button("Lokale Daten öffnen") { Task { await app.unlock() } }.buttonStyle(.borderedProminent).padding(.bottom, 90) }
                }
            } else {
                TabView(selection: $tab) {
                    NavigationStack { ReportsHome() }.tabItem { Label("Berichte", systemImage: "doc.text") }.tag(0)
                    NavigationStack { SparringIntro() }.tabItem { Label("Sparring", systemImage: "bubble.left.and.bubble.right") }.tag(1)
                    NavigationStack { CasesView() }.tabItem { Label("Fälle", systemImage: "folder") }.tag(2)
                    NavigationStack { SettingsView(model: app.model) }.tabItem { Label("Einstellungen", systemImage: "slider.horizontal.3") }.tag(3)
                }
                .safeAreaInset(edge: .bottom) {
                    if app.busy {
                        HStack { ProgressView(); Text(app.workStatus).font(.caption); Spacer(); Button("Abbrechen") { app.cancel() } }.padding().background(.regularMaterial)
                    }
                }
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) { Button("OK") { app.error = nil } } message: { Text(app.error ?? "") }
    }
}
struct ReportsHome: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var editor = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("AUFNAHME & TRANSKRIPTION LOKAL", systemImage: "iphone.gen3").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.teal)
                    Text("Mehr Zeit\nfür deine Patienten.").font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("Diktieren. Prüfen. Fertig dokumentiert.").foregroundStyle(.secondary)
                    Button { Task { await app.newEncounter(); editor = app.currentEncounter != nil } } label: {
                        Label("Neues Diktat", systemImage: "mic.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("new-dictation").disabled(app.busy || app.captureInProgress)
                    Text("Berichte online mit deinem API-Key oder optional mit lokalem Modell. Jeder KI-Bericht bleibt bis zu deiner Prüfung ein Entwurf.").font(.footnote).foregroundStyle(.secondary)
                }.padding(22).background(Color.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 26))
                HStack { Text("Zuletzt bearbeitet").font(.title3.bold()); Spacer(); Text("\(app.document.cases.reduce(0) { $0 + $1.encounters.count }) Vorgänge").font(.caption).foregroundStyle(.secondary) }
                if app.document.cases.allSatisfy({ $0.encounters.isEmpty }) {
                    ContentUnavailableView("Raum für deinen ersten Bericht", systemImage: "waveform", description: Text("Starte ein Diktat oder gib ein Transkript ein. Der Fall wird automatisch angelegt."))
                }
                ForEach(app.document.cases.filter { $0.archivedAt == nil }) { c in
                    ForEach(c.encounters.prefix(3)) { e in
                        Button { app.select(c, e); editor = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: e.state == .approved ? "checkmark.seal" : "doc.text").font(.title2).frame(width: 42, height: 48).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) { Text(c.label).font(.headline); Text("\(c.species) · \(e.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary); Text(e.state.title).font(.caption).foregroundStyle(e.state == .approved ? .teal : .secondary) }
                                Spacer(); Image(systemName: "chevron.right").font(.caption)
                            }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).disabled(app.busy || app.captureInProgress)
                    }
                }
            }.padding(20)
        }.background(Color(.systemGroupedBackground)).navigationTitle("Berichte")
        .navigationDestination(isPresented: $editor) { EncounterEditor(recorder: app.recorder) }
    }
}
struct EncounterEditor: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var recorder: AudioRecorder
    @State private var transcript = ""
    @State private var lastSavedTranscript = ""
    @State private var template: ReportTemplate = .treatment_report
    @State private var length: ReportLength = .medium
    @State private var audience: Audience = .veterinarian
    @State private var mode: ReportExecutionMode = .offline
    @State private var editingCase = false
    var body: some View {
        Form {
            Section {
                Button { editingCase = true } label: { HStack { Label(app.currentCase?.label ?? "Fall", systemImage: "folder"); Spacer(); Text(app.currentCase?.species ?? "").foregroundStyle(.secondary); Image(systemName: "pencil") } }
                Label(app.currentEncounter?.state.title ?? "Entwurf", systemImage: "circle.inset.filled").font(.caption).foregroundStyle(.secondary)
            }
            Section("1 · Diktat") {
                HStack {
                    Image(systemName: recorder.isRecording ? "waveform" : "mic").foregroundStyle(recorder.isRecording ? .red : .teal).font(.title)
                    VStack(alignment: .leading) { Text(recorder.isRecording ? "Aufnahme läuft" : "Auf diesem Gerät").font(.headline); Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer()
                    Button(recorder.isRecording ? "Pause / Stopp" : ((app.currentEncounter?.audio.isEmpty ?? true) ? "Aufnehmen" : "Fortsetzen")) {
                        Task { if recorder.isRecording { await app.pauseRecording() } else { if !transcript.isEmpty { await app.saveTranscript(transcript) }; await app.record() } }
                    }.buttonStyle(.borderedProminent).disabled(app.busy || app.recordingActionPending || recorder.isTransitioning).accessibilityIdentifier("record-audio")
                }
                if let error = recorder.error { Text(error).foregroundStyle(.red) }
                let count = app.currentEncounter?.audio.count ?? 0
                if count > 0 {
                    Text("\(count) gesicherte Audiosegmente").font(.caption).foregroundStyle(.secondary)
                    Button("Lokal transkribieren", systemImage: "text.bubble") { Task { if !transcript.isEmpty { await app.saveTranscript(transcript) }; app.transcribe() } }.disabled(app.busy || app.captureInProgress)
                }
                Text("Aufnahme im Vordergrund. Bei Unterbrechung pausiert das Diktat; gesicherte Segmente bleiben erhalten.").font(.caption).foregroundStyle(.secondary)
            }
            Section("2 · Transkript prüfen") {
                TextEditor(text: $transcript).frame(minHeight: 190).accessibilityIdentifier("transcript-editor").disabled(app.busy || app.captureInProgress)
                if !transcript.isEmpty {
                    Text("Erkennungssicherheit: unbekannt. Zahlen, Negationen und Fachwörter am Original prüfen.").font(.caption).foregroundStyle(.secondary)
                    let numbers = ReportValidator.numbers(transcript).sorted()
                    if !numbers.isEmpty { Text("Zahlen abgleichen: " + numbers.joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
                    ForEach(app.vocabulary.filter { $0.appears(in: transcript) }) { entry in
                        Button("Vorschlag übernehmen: \(entry.recognized) → \(entry.preferred)") { transcript = entry.applying(to: transcript) }
                            .font(.footnote).disabled(app.busy || app.captureInProgress)
                    }
                }
                Button("Transkript speichern") { Task { await app.saveTranscript(transcript) } }.accessibilityIdentifier("save-transcript").disabled(app.busy || app.captureInProgress || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let version = app.currentEncounter?.transcripts.last {
                    DisclosureGroup("Original & Audio · \(app.currentEncounter?.transcripts.count ?? 0) Versionen") {
                        Text(version.rawText).font(.footnote).textSelection(.enabled)
                        ForEach(app.currentEncounter?.playbackSegments ?? []) { segment in
                            Button { Task { await app.play(segment) } } label: { Label(segment.text, systemImage: "play.circle") }.font(.footnote)
                        }
                    }
                }
            }
            Section("3 · Bericht erstellen") {
                Picker("Verarbeitung", selection: $mode) {
                    ForEach(ReportExecutionMode.allCases) { Text($0.title).tag($0) }
                }.disabled(app.busy)
                Picker("Vorlage", selection: $template) { ForEach(ReportTemplate.allCases) { Text($0.title).tag($0) } }
                Picker("Länge", selection: $length) { ForEach(ReportLength.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker("Zielgruppe", selection: $audience) { ForEach(Audience.allCases) { Text($0.title).tag($0) } }
                Button { Task { await app.saveTranscript(transcript); app.generate(template: template, length: length, audience: audience, mode: mode) } } label: {
                    Label(mode == .online ? "Bericht online erstellen" : "Bericht lokal erstellen", systemImage: "sparkles")
                }.disabled(app.busy || app.captureInProgress || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if mode == .online {
                    Text("OpenAI · \(app.onlineConfiguration.modelID.isEmpty ? "Modell noch nicht eingerichtet" : app.onlineConfiguration.modelID)").font(.caption)
                    DisclosureGroup("Übertragenen Text vorab ansehen") {
                        Text(transcript).font(.footnote).textSelection(.enabled)
                        Text("Nur dieses Transkript mit Vorlage, Länge, Zielgruppe und Berichtsanweisungen. Keine automatische Übernahme von Fallkennung, Tiername, Audio oder Anhängen. Personenangaben im Transkript bitte vorher entfernen.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Zahlen, Einheiten, Negationen und Maßnahmen mit dem Original abgleichen. Die automatische Prüfung ersetzt deine fachliche Kontrolle nicht.").font(.caption).foregroundStyle(.secondary)
            }
            if let checkpoint = app.currentEncounter?.reportCheckpoint {
                Section("Gesicherter Zwischenstand") {
                    Label("\(checkpoint.completedChunks) von \(checkpoint.totalChunks) Abschnitten", systemImage: "doc.badge.clock")
                    Text("Der Bericht ist unvollständig. Beim erneuten Erstellen werden alle Quellen nochmals verarbeitet.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Bisherigen Text ansehen") { Text(checkpoint.report.text).font(.footnote).textSelection(.enabled) }
                }
            }
            if let reports = app.currentEncounter?.reports, !reports.isEmpty {
                Section("4 · Prüfen & teilen") {
                    ForEach(reports.reversed()) { report in
                        NavigationLink { ReportReview(reportID: report.id) } label: {
                            VStack(alignment: .leading) { Text(report.content.template.title); Text("\(report.approvedAt == nil ? "Entwurf" : "Geprüft") · \(report.createdAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if let requests = app.currentEncounter?.cloudReportRequests, !requests.isEmpty {
                Section {
                    DisclosureGroup("Online-Aufträge · \(requests.count)") {
                        ForEach(requests.reversed()) { request in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(request.provider) · \(request.date.formatted(date: .abbreviated, time: .shortened))").font(.subheadline)
                                Text(request.status).font(.caption).foregroundStyle(.secondary)
                                Text(request.responseModelID ?? request.modelID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.navigationTitle(app.currentCase?.label ?? "Diktat").navigationBarTitleDisplayMode(.inline)
        .onAppear { transcript = app.currentEncounter?.transcripts.last?.editedText ?? ""; lastSavedTranscript = transcript; mode = app.onlineConfiguration.preferredMode }
        .onChange(of: app.currentEncounter?.transcripts.last?.id) { _, _ in
            let saved = app.currentEncounter?.transcripts.last?.editedText ?? ""
            // An async save notification must not overwrite a more recent keystroke.
            if transcript == lastSavedTranscript { transcript = saved }
            lastSavedTranscript = saved
        }
        .task(id: transcript) {
            let text = transcript, c = app.selectedCaseID, e = app.selectedEncounterID
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation(); await app.saveTranscript(text, caseID: c, encounterID: e) }
            catch { /* Debounced edits are superseded by the next input. */ }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePendingText() } }
        .onDisappear { savePendingText(); if recorder.isRecording { Task { await app.pauseRecording() } } }
        .sheet(isPresented: $editingCase) { CaseEditor() }
    }
    private func savePendingText() {
        let text = transcript, c = app.selectedCaseID, e = app.selectedEncounterID
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await app.saveTranscript(text, caseID: c, encounterID: e) }
    }
}
struct CaseEditor: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var species = ""
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form { TextField("Lokale Kennung", text: $label); TextField("Tierart", text: $species); TextField("Tiername (optional)", text: $name); Text("Die lokale Kennung und der Tiername werden nicht automatisch in externe Anfragen übernommen.").font(.caption).foregroundStyle(.secondary) }
                .navigationTitle("Fall bearbeiten").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await app.updateCase(label: label, species: species, animalName: name); dismiss() } }.disabled(label.isEmpty) } }
        }.onAppear { label = app.currentCase?.label ?? ""; species = app.currentCase?.species ?? ""; name = app.currentCase?.animalName ?? "" }
    }
}
struct CasesView: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var editor = false
    @State private var toDelete: UUID?
    var body: some View {
        List {
            if app.document.cases.isEmpty { ContentUnavailableView("Noch keine Fälle", systemImage: "folder", description: Text("Mit dem ersten Diktat entsteht ein Fall.")) }
            ForEach(app.document.cases) { c in
                Section(c.label + " · " + c.species) {
                    ForEach(c.encounters) { e in
                        Button { app.select(c, e); editor = true } label: { VStack(alignment: .leading) { Text(e.date.formatted(date: .abbreviated, time: .shortened)); Text(e.state.title).font(.caption).foregroundStyle(.secondary) } }
                    }
                    Button("Neuen Vorgang anlegen") { Task { await app.newEncounter(caseID: c.id); editor = true } }
                    Button("Fall löschen", role: .destructive) { toDelete = c.id }
                }
            }
        }.navigationTitle("Fälle").disabled(app.busy || app.captureInProgress)
        .navigationDestination(isPresented: $editor) { EncounterEditor(recorder: app.recorder) }
        .confirmationDialog("Fall mit allen Berichten und Aufnahmen löschen?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Endgültig lokal löschen", role: .destructive) { if let id = toDelete { Task { await app.deleteCase(id); toDelete = nil } } }
        }
    }
}
struct ReportReview: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    let reportID: UUID
    @State private var edited = ""
    @State private var reviewed = false
    @State private var share: SharePayload?
    private var report: ReportVersion? { app.currentEncounter?.reports.first { $0.id == reportID } }
    var body: some View {
        Form {
            if let report {
                Section {
                    Label(report.approvedAt == nil ? "Entwurf · Prüfung erforderlich" : "Fachlich geprüft", systemImage: report.approvedAt == nil ? "doc.badge.clock" : "checkmark.seal").foregroundStyle(.teal)
                    Text(report.modelID.hasPrefix("openai/") ? "Online erstellt · OpenAI" : "Lokal auf dem Gerät erstellt").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Modell & Version") { Text(report.modelID + "\n" + report.modelRevision).font(.caption).textSelection(.enabled) }
                    TextEditor(text: $edited).frame(minHeight: 300).accessibilityIdentifier("report-editor")
                    if edited != report.text { Button("Als neue Version speichern") { Task { await app.saveReportEdit(edited, report: report); dismiss() } } }
                }
                Section("Prüfung am Original") {
                    ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    DisclosureGroup("Quellenbezüge") {
                        ForEach(Array(report.content.sections.flatMap(\.items).enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 5) { Text(item.text).font(.subheadline); ForEach(Array(item.sourceRefs.enumerated()), id: \.offset) { _, ref in Text("„\(ref.quote)“ · \(ref.segmentId)").font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                    Toggle("Zahlen, Einheiten, Negationen und Vollständigkeit am Original geprüft", isOn: $reviewed)
                    Button("Diese Version als geprüft markieren") { Task { await app.approve(report.id) } }.disabled(!reviewed || edited != report.text || report.approvedAt != nil)
                }
                Section("Exportvorschau") {
                    Text(report.exportText).font(.footnote).textSelection(.enabled)
                    Button("Kopieren", systemImage: "doc.on.doc") { ExportService.copy(report); Task { await app.recordShare(report.id, format: "Zwischenablage") } }
                    Button("Text teilen", systemImage: "square.and.arrow.up") { share = SharePayload(items: [report.exportText], reportID: report.id, format: "Text") }
                    Button("PDF teilen", systemImage: "doc.richtext") { do { share = SharePayload(items: [try ExportService.pdf(report)], reportID: report.id, format: "PDF") } catch { app.error = error.localizedDescription } }
                }.disabled(edited != report.text)
            }
        }.navigationTitle("Bericht prüfen").navigationBarTitleDisplayMode(.inline)
        .onAppear { edited = report?.text ?? "" }
        .sheet(item: $share) { payload in ActivitySheet(items: payload.items) { completed in if completed { Task { await app.recordShare(payload.reportID, format: payload.format) } } } }
    }
}
struct SharePayload: Identifiable { let id = UUID(); let items: [Any]; let reportID: UUID; let format: String }
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct SettingsView: View {
    @EnvironmentObject private var app: VetAppModel
    @ObservedObject var model: MLXLocalReportEngine
    var body: some View {
        Form {
            Section("Online-Berichte") {
                NavigationLink("API-Key & Modell") { OnlineReportSettingsView() }
                Text(app.hasOnlineKey ? "OpenAI · " + app.onlineConfiguration.modelID : "Noch kein API-Key hinterlegt").font(.caption).foregroundStyle(.secondary)
                Text("Mit aktivierter Konfiguration ist Online der Standard. Offline kannst du pro Bericht ausdrücklich auswählen.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Optionales Offline-Modell") {
                Label("Gemma 4 E2B · 4 Bit", systemImage: "cpu")
                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                if let progress = model.progress { ProgressView(value: progress) }
                Text("Einmaliger Download: ca. 3,6 GB. Danach arbeitet die Berichtserstellung ohne Internet.").font(.caption).foregroundStyle(.secondary)
                Button(model.installed ? "Installation prüfen" : "Modell herunterladen") { app.installModel() }.disabled(app.busy)
                if model.installed { Button("Modell entladen") { do { try model.unload() } catch { app.error = error.localizedDescription } }.disabled(app.busy); Button("Modell löschen", role: .destructive) { do { try model.delete() } catch { app.error = error.localizedDescription } }.disabled(app.busy) }
                if let seconds = model.lastSeconds { LabeledContent("Letzte Modellantwort", value: String(format: "%.1f s", seconds)) }
            }
            Section("Lokale Spracherkennung") {
                Text(app.speechStatus)
                Button("Deutsche Sprachressourcen installieren") { app.installSpeech() }.disabled(app.busy)
                NavigationLink("Eigene Fachwortkorrekturen") { VocabularyView() }
            }
            Section("Lokale Daten") {
                Label("Verschlüsselt auf diesem iPhone", systemImage: "lock.shield")
                Text("Keine automatische Cloud-Synchronisation. Lokale Daten und Modelle sind von App-Backups ausgeschlossen. Geräteverlust oder Deinstallation kann zum Datenverlust führen.").font(.caption)
            }
            Section("Entwicklungsstand") {
                Text("iPhone-Pilot · 0.1").font(.headline)
                NavigationLink("Drittanbieter-Lizenzen") {
                    ScrollView { Text(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Lizenztexte fehlen.").font(.footnote).textSelection(.enabled).padding() }.navigationTitle("Lizenzen")
                }
                Text("Online-Berichte mit OpenAI und ein optionaler lokaler Berichtspfad. Fachliche Freigabe, vollständige Offline-Prüfung, Cloud-Sparring und Android stehen noch aus.").font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section("Synthetischer Gerätetest") {
                Text("Flugmodus aktivieren und WLAN ausschalten. Der Test verarbeitet ausschließlich die vorbereitete synthetische Audiodatei; er verwendet weder Mikrofon noch deine Fälle.").font(.caption)
                Button("Offline-Gerätetest starten") { app.runOfflineDiagnostics() }.disabled(app.busy || app.captureInProgress)
                if let result = app.diagnosticResult { Text(result).font(.footnote).textSelection(.enabled) }
            }
            #endif
        }.navigationTitle("Einstellungen")
    }
}
struct SparringIntro: View {
    var body: some View {
        ContentUnavailableView("Fachliches Sparring", systemImage: "bubble.left.and.bubble.right", description: Text("Dieser Entwicklungsstand enthält den lokalen Diktatablauf. Cloudanbieter, Anhänge und Brave-Recherche sind noch nicht angeschlossen."))
            .navigationTitle("Sparring")
    }
}

struct OnlineReportSettingsView: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var keyDraft = ""
    @State private var modelID = ""
    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField(app.hasOnlineKey ? "API-Key ersetzen (optional)" : "Eigenen API-Key eingeben", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Modell-ID", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Verfügbare Modelle laden") { app.loadOnlineModels(keyDraft: keyDraft) }
                if !app.onlineModels.isEmpty {
                    Menu("Modell aus dem Konto auswählen") {
                        ForEach(app.onlineModels, id: \.self) { id in Button(id) { modelID = id } }
                    }
                }
                Button("Modell mit synthetischem Text testen") { app.testOnlineModel(modelID: modelID, keyDraft: keyDraft) }.disabled(modelID.isEmpty)
                Text("Modelltest und Berichte verwenden deinen API-Zugang und können Kosten verursachen. Der Modelltest überträgt ausschließlich einen festen synthetischen Text.").font(.caption).foregroundStyle(.secondary)
                if let status = app.onlineSettingsStatus { Text(status).font(.footnote) }
            }.disabled(app.busy)
            Section("Online als Standard aktivieren") {
                Text("Mit Online aktivieren erlaubst du die Übertragung des geprüften Transkripts, sobald du Bericht online erstellen wählst. Den zu übertragenden Text siehst du im Editor. Aufnahme und Transkription bleiben lokal.").font(.footnote)
                Text("Der API-Key bleibt im Geräte-Schlüsselbund. Wir deaktivieren die abrufbare Antwortspeicherung; weitere Aufbewahrung beim Anbieter richtet sich nach deinem API-Vertrag.").font(.caption).foregroundStyle(.secondary)
                Link("OpenAI-Datenkontrollen", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                Button("Online aktivieren") {
                    app.saveOnlineConfiguration(modelID: modelID, keyDraft: keyDraft)
                    if app.error == nil { keyDraft = "" }
                }.buttonStyle(.borderedProminent).disabled(app.busy || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!app.hasOnlineKey && keyDraft.isEmpty))
                if app.hasOnlineKey { Button("API-Key entfernen", role: .destructive) { app.removeOnlineKey(); keyDraft = "" }.disabled(app.busy) }
                Text("Bei Verbindungs- oder Anbieterfehlern bleibt der Auftrag lokal. Es gibt keinen automatischen Wechsel zu einem anderen Anbieter und keinen Versand bei späterer Netzrückkehr.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Online-Berichte")
            .onAppear { modelID = app.onlineConfiguration.modelID }
            .onChange(of: modelID) { _, _ in app.resetOnlineModelVerification() }
            .onChange(of: keyDraft) { _, _ in app.resetOnlineModelVerification() }
            .onDisappear { keyDraft = "" }
    }
}

struct VocabularyView: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var recognized = ""
    @State private var preferred = ""
    var body: some View {
        Form {
            Section("Korrektur vorschlagen") {
                TextField("Erkannter Ausdruck", text: $recognized)
                TextField("Gewünschter Fachbegriff", text: $preferred)
                Button("Zur Fachwortliste hinzufügen") {
                    let entry = VocabularyEntry(recognized: recognized.trimmingCharacters(in: .whitespacesAndNewlines), preferred: preferred.trimmingCharacters(in: .whitespacesAndNewlines))
                    Task { await app.saveVocabulary(app.vocabulary + [entry]); if app.vocabulary.contains(entry) { recognized = ""; preferred = "" } }
                }.disabled(recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recognized == preferred)
                Text("Die Liste macht Vorschläge im Transkripteditor. Du übernimmst eine Korrektur ausdrücklich; das Original bleibt erhalten. Die Spracherkennung wird dadurch nicht trainiert.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Eigene Einträge") {
                ForEach(app.vocabulary) { entry in
                    VStack(alignment: .leading) { Text(entry.preferred); Text(entry.recognized).font(.caption).foregroundStyle(.secondary) }
                }.onDelete { offsets in
                    var entries = app.vocabulary; entries.remove(atOffsets: offsets)
                    Task { await app.saveVocabulary(entries) }
                }
            }
        }.navigationTitle("Fachwortliste")
    }
}

struct DeviceDiagnosticsView: View {
    @ObservedObject var model: MLXLocalReportEngine
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu").font(.system(size: 50)).foregroundStyle(.teal)
            Text("Technischer Gerätetest").font(.title2.bold())
            Text("Ausschließlich synthetische Testdaten").foregroundStyle(.secondary)
            Text(model.status).multilineTextAlignment(.center)
            if let value = model.progress { ProgressView(value: value) }
            else if model.isBusy { ProgressView() }
            Text("Laufzeit, Speicher und Quellenprüfung werden im Prüfprotokoll festgehalten.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32)
    }
}
