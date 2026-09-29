import SwiftUI

@main
struct VetMedApp: App {
    @StateObject private var app = VetAppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AccentTheme.storageKey) private var theme: AccentTheme = .klinik
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app)
                .overlay { if scenePhase != .active { PrivacyCover() } }
                .tint(theme.primary)
                .environment(\.accentTheme, theme)
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
    @Environment(\.accentTheme) private var theme
    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 18) {
                Image(systemName: "cross.case.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(theme.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: theme.primary.opacity(0.4), radius: 18, y: 8)
                    .symbolEffect(.breathe, options: .repeat(.continuous))
                Text("VetMed").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Deine Fälle bleiben geschützt.").foregroundStyle(.secondary)
            }
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.accentTheme) private var theme
    @AppStorage(AppearanceMode.storageKey) private var appearance: AppearanceMode = .system
    var body: some View {
        Group {
            if VetAppModel.isDiagnosticLaunch {
                DeviceDiagnosticsView(model: app.model)
            } else if !app.workspaceReady {
                ZStack {
                    PrivacyCover()
                    VStack { Spacer(); Button("Lokale Daten öffnen") { Task { await app.unlock() } }.buttonStyle(.glassProminent).controlSize(.large).padding(.bottom, 90) }
                }
            } else {
                TabView(selection: $app.activeTab) {
                    NavigationStack { StartHome() }.tabItem { Label("Start", systemImage: "house") }.tag(AppTab.start)
                    NavigationStack { CasesView() }.tabItem { Label("Fälle", systemImage: "folder") }.tag(AppTab.cases)
                    NavigationStack(path: $app.chatPath) {
                        SparringHome()
                            .navigationDestination(for: ChatLocation.self) { location in
                                ChatConversationView(caseID: location.caseID, encounterID: location.encounterID).id(location)
                            }
                    }.tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }.tag(AppTab.chat)
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .safeAreaInset(edge: .bottom) {
                    if app.busy && !app.activeAnalysisIsVisible {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(app.workStatus).font(.caption.weight(.medium)).lineLimit(2).contentTransition(.opacity)
                            Spacer()
                            Button("Abbrechen") { app.cancel() }.font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular.tint(theme.primary.opacity(0.12)), in: .capsule)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: app.busy && !app.activeAnalysisIsVisible)
            }
        }
        .onAppear { AppearanceSwitcher.apply(appearance, animated: false) }
        .onChange(of: appearance) { _, mode in AppearanceSwitcher.apply(mode) }
        .alert("Hinweis", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) { Button("OK") { app.error = nil } } message: { Text(app.error ?? "") }
    }
}
struct DeleteCaseButton: View {
    @EnvironmentObject private var app: VetAppModel
    let caseID: UUID
    var didDelete: () -> Void
    @State private var confirming = false
    var body: some View {
        Button("Fall löschen", systemImage: "trash", role: .destructive) { confirming = true }
            .accessibilityIdentifier("delete-case-bottom")
            .disabled(app.busy || app.captureInProgress)
            .alert("Diesen Fall mit allen Vorgängen, Berichten und Aufnahmen löschen?", isPresented: $confirming) {
                Button("Behalten", role: .cancel) {}
                Button("Fall endgültig löschen", role: .destructive) {
                    Task { await app.deleteCase(caseID); if !app.document.cases.contains(where: { $0.id == caseID }) { didDelete() } }
                }
            }
    }
}
struct ReportReview: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    let reportID: UUID
    let location: EncounterLocation
    @State private var edited = ""
    @State private var reviewed = false
    @State private var share: SharePayload?
    @State private var copied = false
    private var report: ReportVersion? { app.encounter(at: location)?.reports.first { $0.id == reportID } }
    var body: some View {
        Form {
            if let report {
                Section {
                    Label(report.approvedAt == nil ? "Entwurf · Prüfung erforderlich" : "Fachlich geprüft", systemImage: report.approvedAt == nil ? "doc.badge.clock" : "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(report.approvedAt == nil ? Color.orange : Color.green)
                        .symbolEffect(.bounce, value: report.approvedAt != nil)
                    Text(report.modelID.hasPrefix("openai/") ? "Online erstellt · OpenAI" : "Lokal auf dem Gerät erstellt").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Modell & Version") { Text(report.modelID + "\n" + report.modelRevision).font(.caption).textSelection(.enabled) }
                    TextEditor(text: $edited).frame(minHeight: 300).accessibilityIdentifier("report-editor")
                    if edited != report.text { Button("Als neue Version speichern") { Task { if await app.saveReportEdit(edited, report: report, at: location) { dismiss() } } } }
                }
                Section("Prüfung am Original") {
                    ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    DisclosureGroup("Quellenbezüge") {
                        ForEach(Array(report.content.sections.flatMap(\.items).enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 5) { Text(item.text).font(.subheadline); ForEach(Array(item.sourceRefs.enumerated()), id: \.offset) { _, ref in Text("„\(ref.quote)“ · \(ref.segmentId)").font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                    Toggle("Zahlen, Einheiten, Negationen und Vollständigkeit am Original geprüft", isOn: $reviewed)
                    Button("Diese Version als geprüft markieren", systemImage: "checkmark.seal") { Task { await app.approve(report.id, at: location) } }.disabled(!reviewed || edited != report.text || report.approvedAt != nil)
                        .sensoryFeedback(.success, trigger: report.approvedAt != nil)
                }
                Section("Exportvorschau") {
                    Text(report.exportText).font(.footnote).textSelection(.enabled)
                }.disabled(edited != report.text)
            }
        }.themedBackground().navigationTitle("Bericht prüfen").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let report {
                HStack(spacing: 16) {
                    Button(copied ? "Text kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        ExportService.copy(report); copied = true
                        Task { await app.recordShare(report.id, format: "Zwischenablage", at: location) }
                    }.accessibilityIdentifier("copy-report")
                    Spacer()
                    Menu {
                        Button("Als Text teilen") { share = SharePayload(content: .text(report.exportText), reportID: report.id, format: "Text") }.accessibilityIdentifier("share-report-text")
                        Button("Als PDF teilen") { do { share = SharePayload(content: .file(try ExportService.pdf(report)), reportID: report.id, format: "PDF") } catch { app.error = error.localizedDescription } }
                    } label: { Label("Teilen", systemImage: "square.and.arrow.up") }.buttonStyle(.glassProminent).accessibilityIdentifier("share-report-menu")
                }.buttonStyle(.glass).contentTransition(.symbolEffect(.replace)).padding(.horizontal, 20).padding(.vertical, 10).disabled(edited != report.text)
            }
        }
        .onAppear { edited = report?.text ?? "" }
        .onChange(of: report == nil) { _, missing in if missing { dismiss() } }
        .sheet(item: $share) { payload in
            ActivitySheet(content: payload.content) { completed, error in
                if error != nil { app.error = "Der Text konnte nicht an die ausgewählte App übergeben werden. Du kannst ihn auch über Kopieren einfügen." }
                if completed, let id = payload.reportID { Task { await app.recordShare(id, format: payload.format, at: location) } }
            }
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject private var app: VetAppModel
    @ObservedObject var model: MLXLocalReportEngine
    var body: some View {
        Form {
            AppearanceSettingsSection()
            Section("Online-Zugang") {
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
                Text("Online-Berichte mit OpenAI und ein optionaler lokaler Berichtspfad. Chat mit Bildern und Befunden ist verbunden. Fachliche Freigabe, vollständige Offline-Prüfung, weitere Anbieter und Android stehen noch aus.").font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section("Synthetischer Gerätetest") {
                Text("Flugmodus aktivieren und WLAN ausschalten. Der Test verarbeitet ausschließlich die vorbereitete synthetische Audiodatei; er verwendet weder Mikrofon noch deine Fälle.").font(.caption)
                Button("Offline-Gerätetest starten") { app.runOfflineDiagnostics() }.disabled(app.busy || app.captureInProgress)
                if let result = app.diagnosticResult { Text(result).font(.footnote).textSelection(.enabled) }
            }
            #endif
        }.themedBackground().navigationTitle("Einstellungen")
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
                Text("Mit Online aktivieren richtest du deinen OpenAI-Zugang ein. Bericht online erstellen sendet das geprüfte Transkript; Senden im Chat überträgt deine Frage, die hinzugefügten Anhänge und den Verlauf desselben Chats. Die Versanddetails findest du im Chat-Menü. Aufnahme und Transkription bleiben lokal.").font(.footnote)
                Text("Der API-Key bleibt im Geräte-Schlüsselbund. Wir deaktivieren die abrufbare Antwortspeicherung; weitere Aufbewahrung beim Anbieter richtet sich nach deinem API-Vertrag.").font(.caption).foregroundStyle(.secondary)
                Link("OpenAI-Datenkontrollen", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                Button("Online aktivieren") {
                    app.saveOnlineConfiguration(modelID: modelID, keyDraft: keyDraft)
                    if app.error == nil { keyDraft = "" }
                }.buttonStyle(.borderedProminent).disabled(app.busy || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!app.hasOnlineKey && keyDraft.isEmpty))
                if app.hasOnlineKey { Button("API-Key entfernen", role: .destructive) { app.removeOnlineKey(); keyDraft = "" }.disabled(app.busy) }
                Text("Bei Verbindungs- oder Anbieterfehlern bleibt der Auftrag lokal. Es gibt keinen automatischen Wechsel zu einem anderen Anbieter und keinen Versand bei späterer Netzrückkehr.").font(.caption).foregroundStyle(.secondary)
            }
        }.themedBackground().navigationTitle("Online-Zugang")
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
        }.themedBackground().navigationTitle("Fachwortliste")
    }
}

struct DeviceDiagnosticsView: View {
    @ObservedObject var model: MLXLocalReportEngine
    var body: some View {
        VStack(spacing: 20) {
            GradientIcon(systemName: "cpu", size: 84).symbolEffect(.pulse, isActive: model.isBusy)
            Text("Technischer Gerätetest").font(.title2.bold())
            Text("Ausschließlich synthetische Testdaten").foregroundStyle(.secondary)
            Text(model.status).multilineTextAlignment(.center)
            if let value = model.progress { ProgressView(value: value) }
            else if model.isBusy { ProgressView() }
            Text("Laufzeit, Speicher und Quellenprüfung werden im Prüfprotokoll festgehalten.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32)
    }
}
