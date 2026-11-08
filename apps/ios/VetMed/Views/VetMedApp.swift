import SwiftUI
import UniformTypeIdentifiers

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
                    Text(report.modelID.hasPrefix("openai/") ? "Online erstellt · OpenAI" : report.modelID.hasPrefix("gemini/") ? "Online erstellt · Gemini" : "Lokal auf dem Gerät erstellt").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Modell & Version") { Text(report.modelID + "\n" + report.modelRevision).font(.caption).textSelection(.enabled) }
                    TextEditor(text: $edited).frame(minHeight: 300).accessibilityIdentifier("report-editor")
                    if edited != report.text { Button("Als neue Version speichern") { Task { if await app.saveReportEdit(edited, report: report, at: location) { dismiss() } } } }
                }
                Section("Prüfung am Original") {
                    ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    // Sentences the model left out as not clinical are shown, never dropped silently (ADR 0018).
                    if let omitted = report.content.omitted, !omitted.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nicht übernommen · bitte prüfen").font(.subheadline.weight(.semibold))
                            ForEach(Array(omitted.enumerated()), id: \.offset) { _, source in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("„\(source.text.trimmingCharacters(in: .whitespacesAndNewlines))“").font(.subheadline)
                                    Text(source.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("Gehört ein Satz doch in den Bericht, ergänze ihn oben im Text.").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("report-omitted")
                    }
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
            Section("Verarbeitung") {
                Text(app.reportMode == .online ? "Online · beste Qualität" : "Auf dem Gerät").font(.headline)
                Text(Processing.summary(online: app.onlineConfiguration, hasKey: app.hasOnlineKey, transcription: app.transcriptionRoute))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("processing-summary")
                Toggle(isOn: Binding(get: { app.onlineConfiguration.deviceOnly == true }, set: { app.setDeviceOnly($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nur auf dem Gerät verarbeiten")
                        Text("Transkription und Berichte ohne Internet. Der Chat braucht weiterhin den Online-Zugang.").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("device-only")
                NavigationLink("API-Key & Modell") { OnlineReportSettingsView() }
                Text(app.hasOnlineKey ? app.onlineConfiguration.activeProvider.title + " · " + app.onlineConfiguration.modelID : "Noch kein API-Key hinterlegt").font(.caption).foregroundStyle(.secondary)
                Text("Fällt Online aus, zeigt die App den Fehler und bietet die Verarbeitung auf dem Gerät als Knopf an. Sie wechselt nie von selbst und sendet später nichts automatisch nach.").font(.caption).foregroundStyle(.secondary)
            }
            AppearanceSettingsSection()
            Section("Optionales Offline-Modell") {
                Label("Gemma 4 E2B · 4 Bit", systemImage: "cpu")
                Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                if let progress = model.progress { ProgressView(value: progress) }
                Text("Einmaliger Download: ca. 3,6 GB. Danach arbeitet die Berichtserstellung ohne Internet.").font(.caption).foregroundStyle(.secondary)
                Button(model.installed ? "Installation prüfen" : "Modell herunterladen") { app.installModel() }.disabled(app.busy)
                if model.installed { Button("Modell entladen") { do { try model.unload() } catch { app.error = error.localizedDescription } }.disabled(app.busy); Button("Modell löschen", role: .destructive) { do { try model.delete() } catch { app.error = error.localizedDescription } }.disabled(app.busy) }
                if let seconds = model.lastSeconds { LabeledContent("Letzte Modellantwort", value: String(format: "%.1f s", seconds)) }
            }
            Section("Spracherkennung") {
                switch app.transcriptionRoute {
                case .online: Text("Aktiv: Online-Transkription mit Gemini (\(app.geminiConfiguration.modelID)). Die Audioteile werden dafür an Google gesendet.").font(.caption)
                case .ask: Text("Gemini ist eingerichtet. Vor der ersten Transkription fragt die App einmal, ob Audio an Google gehen darf.").font(.caption)
                case .device: Text(app.hasGeminiKey && app.onlineConfiguration.deviceOnly != true ? "Transkribiert wird auf dem Gerät, wie von dir gewählt. Gemini erkennt Fachsprache meist deutlich besser." : "Transkribiert wird auf dem Gerät. Mit einem Gemini-Key wird die genauere Online-Transkription der Standard.").font(.caption)
                }
                NavigationLink("Online-Transkription (Gemini)") { GeminiSettingsView() }
                LabeledContent("Auf dem Gerät", value: app.speechStatus)
                Button("Deutsche Sprachressourcen installieren") { app.installSpeech() }.disabled(app.busy)
                NavigationLink("Eigene Fachwortkorrekturen") { VocabularyView() }
            }
            Section("Lokale Daten") {
                Label("Verschlüsselt auf diesem iPhone", systemImage: "lock.shield")
                Text("Keine automatische Cloud-Synchronisation. Lokale Daten und Modelle sind von iPhone-Backups ausgeschlossen. Ohne eigene Sicherung gehen Fälle bei Geräteverlust oder Deinstallation verloren.").font(.caption)
                NavigationLink("Sicherung erstellen oder wiederherstellen") { BackupView() }
            }
            Section("Entwicklungsstand") {
                Text("iPhone-Pilot · 0.1").font(.headline)
                NavigationLink("Drittanbieter-Lizenzen") {
                    ScrollView { Text(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Lizenztexte fehlen.").font(.footnote).textSelection(.enabled).padding() }.navigationTitle("Lizenzen")
                }
                Text("Online-Berichte und Chat mit OpenAI oder Gemini, Online-Transkription mit Gemini, optionaler lokaler Berichtspfad. Fachliche Freigabe und vollständige Offline-Prüfung stehen noch aus.").font(.caption).foregroundStyle(.secondary)
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
    @State private var provider: OnlineProvider = .openai
    @State private var keyDraft = ""
    @State private var modelID = ""
    private var hasKey: Bool { provider == .gemini ? app.hasGeminiKey : app.hasOpenAIKey }
    var body: some View {
        Form {
            Section("Anbieter") {
                Picker("Anbieter", selection: $provider) { ForEach(OnlineProvider.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("provider")
                Text(provider == .gemini ? "Der Gemini-Key gilt auch für die Online-Transkription." : "OpenAI wird nur für Berichte und Chat verwendet.").font(.caption).foregroundStyle(.secondary)
            }.disabled(app.busy)
            Section(provider.title) {
                SecureField(hasKey ? "API-Key ersetzen (optional)" : "Eigenen API-Key eingeben", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Modell-ID", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Verfügbare Modelle laden") { app.loadOnlineModels(provider: provider, keyDraft: keyDraft) }
                if !app.onlineModels.isEmpty {
                    Menu("Modell aus dem Konto auswählen") {
                        ForEach(app.onlineModels, id: \.self) { id in Button(id) { modelID = id } }
                    }
                }
                Button("Modell mit synthetischem Text testen") { app.testOnlineModel(provider: provider, modelID: modelID, keyDraft: keyDraft) }.disabled(modelID.isEmpty)
                Text("Modelltest und Berichte verwenden deinen API-Zugang und können Kosten verursachen. Der Modelltest überträgt ausschließlich einen festen synthetischen Text.").font(.caption).foregroundStyle(.secondary)
                if let status = app.onlineSettingsStatus { Text(status).font(.footnote) }
            }.disabled(app.busy)
            Section("Online als Standard aktivieren") {
                Text("Mit Online aktivieren richtest du deinen \(provider.title)-Zugang ein. Bericht online erstellen sendet das geprüfte Transkript; Senden im Chat überträgt deine Frage, die hinzugefügten Anhänge und den Verlauf desselben Chats. Die Versanddetails findest du im Chat-Menü.").font(.footnote)
                if provider == .gemini {
                    Text("Der API-Key bleibt im Geräte-Schlüsselbund. Für Patientendaten nur einen Key mit aktivierter Abrechnung verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen.").font(.caption).foregroundStyle(.secondary)
                    Link("Gemini-API-Nutzungsbedingungen", destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                } else {
                    Text("Der API-Key bleibt im Geräte-Schlüsselbund. Wir deaktivieren die abrufbare Antwortspeicherung; weitere Aufbewahrung beim Anbieter richtet sich nach deinem API-Vertrag.").font(.caption).foregroundStyle(.secondary)
                    Link("OpenAI-Datenkontrollen", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                }
                Button(app.onlineConfiguration.isEnabled && app.onlineConfiguration.activeProvider == provider ? "Konfiguration speichern" : "Online mit \(provider.title) aktivieren") {
                    app.saveOnlineConfiguration(provider: provider, modelID: modelID, keyDraft: keyDraft)
                    if app.error == nil { keyDraft = "" }
                }.buttonStyle(.borderedProminent).disabled(app.busy || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!hasKey && keyDraft.isEmpty))
                    .accessibilityIdentifier("save-online")
                if hasKey { Button("\(provider.title)-API-Key entfernen", role: .destructive) { app.removeOnlineKey(provider); keyDraft = "" }.disabled(app.busy) }
                Text("Bei Verbindungs- oder Anbieterfehlern bleibt der Auftrag lokal. Es gibt keinen automatischen Wechsel zu einem anderen Anbieter und keinen Versand bei späterer Netzrückkehr.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Arzneimittelangaben im Chat") {
                Toggle("Mit amtlichen Quellen belegen", isOn: Binding(get: { app.onlineConfiguration.sourceSearch == true }, set: { app.setSourceSearch($0) }))
                    .disabled(app.busy || provider != .openai).accessibilityIdentifier("source-search")
                Text(provider == .openai ? "OpenAI sucht nur in EU-Tierarzneimitteldatenbank, EMA, PharmNet.Bund, BVL und BASG. Jede Suche kostet extra."
                     : "Nur mit OpenAI verfügbar. Gemini bietet keine Begrenzung auf amtliche Seiten.").font(.caption).foregroundStyle(.secondary)
                Text("Unabhängig davon nennt der Chat Wirkstoffe eines Präparats nicht aus dem Gedächtnis. Antworten mit Arzneimittelangaben ohne amtliche Quelle werden deutlich als ungeprüft markiert.").font(.caption).foregroundStyle(.secondary)
            }
        }.themedBackground().navigationTitle("Online-Zugang")
            .onAppear { provider = app.onlineConfiguration.activeProvider; modelID = app.onlineConfiguration.modelID }
            .onChange(of: provider) { _, value in
                keyDraft = ""; app.onlineModels = []
                modelID = app.onlineConfiguration.activeProvider == value ? app.onlineConfiguration.modelID : value.defaultModel
            }
            .onChange(of: modelID) { _, _ in app.resetOnlineModelVerification() }
            .onChange(of: keyDraft) { _, _ in app.resetOnlineModelVerification() }
            .onDisappear { keyDraft = "" }
    }
}

/// Gemini for speech-to-text. The key is shared with reports and chat when Gemini is chosen there.
struct GeminiSettingsView: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var keyDraft = ""
    @State private var modelID = GeminiTranscriptionConfiguration.defaultModel
    @State private var enabled = true
    var body: some View {
        Form {
            Section("Gemini") {
                SecureField(app.hasGeminiKey ? "Gemini-API-Key ersetzen (optional)" : "Gemini-API-Key eingeben", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("gemini-key")
                TextField("Modell-ID", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Für Transkription verwenden", isOn: $enabled).accessibilityIdentifier("gemini-enabled")
                Text("Den Key erstellst du in Google AI Studio. Er bleibt im Geräte-Schlüsselbund und gilt auch für Berichte und Chat, wenn dort Gemini gewählt ist.").font(.caption).foregroundStyle(.secondary)
                Link("Google AI Studio öffnen", destination: URL(string: "https://aistudio.google.com/apikey")!)
            }.disabled(app.busy)
            Section("Datenschutz") {
                Text("Bei aktivierter Online-Transkription werden die Audioteile der Aufnahme an Google gesendet. Fälle, Transkripte und Berichte bleiben verschlüsselt auf diesem Gerät.").font(.footnote)
                Text("Für Patienten- und Halterdaten nur einen Key mit aktivierter Abrechnung verwenden: Im kostenlosen Kontingent darf Google Eingaben zur Produktverbesserung nutzen und von Menschen prüfen lassen.").font(.caption).foregroundStyle(.secondary)
                Link("Gemini-API-Nutzungsbedingungen", destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                Button("Speichern") {
                    app.saveGeminiConfiguration(enabled: enabled, modelID: modelID, keyDraft: keyDraft)
                    if app.error == nil { keyDraft = "" }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("save-gemini")
                    .disabled(app.busy || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (enabled && !app.hasGeminiKey && keyDraft.isEmpty))
                if app.hasGeminiKey { Button("Gemini-API-Key entfernen", role: .destructive) { app.removeOnlineKey(.gemini); keyDraft = "" }.disabled(app.busy) }
                if let status = app.onlineSettingsStatus { Text(status).font(.footnote) }
            }
        }.themedBackground().navigationTitle("Online-Transkription")
            .onAppear {
                modelID = app.geminiConfiguration.modelID
                // Undecided means recommended: online. Saving here counts as the explicit choice.
                enabled = app.geminiConfiguration.enabled || app.geminiConfiguration.decidedAt == nil
            }
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

/// Password-protected backup of all cases to a place of the user's choice, and restoring from one (ADR 0019).
struct BackupView: View {
    @EnvironmentObject private var app: VetAppModel
    // Passwords live only in memory for this screen.
    @State private var password = ""
    @State private var repeated = ""
    @State private var includeAudio = true
    @State private var problem: String?
    @State private var created: URL?
    @State private var moving = false
    @State private var picking = false
    @State private var source: URL?
    @State private var restorePassword = ""

    var body: some View {
        Form {
            Section {
                Text("Alle Fälle, Berichte, Chats, Anhänge und die Fachwortliste in eine Datei").font(.headline)
                Text("Die Datei ist mit deinem Passwort verschlüsselt (AES-256). Ohne das Passwort lässt sie sich nicht öffnen, auch nicht von uns. API-Keys sind nicht enthalten. Speichere die Datei außerhalb des iPhones, etwa auf dem Computer.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $includeAudio) {
                    VStack(alignment: .leading) {
                        Text("Aufnahmen mitsichern")
                        Text("Ungefähr " + Self.megabytes(BackupContent.estimatedBytes(app.document, includeAudio: includeAudio)) + " insgesamt").font(.caption).foregroundStyle(.secondary)
                    }
                }
                SecureField("Passwort (mindestens \(BackupFormat.minimumPassword) Zeichen)", text: $password).textContentType(.newPassword).accessibilityIdentifier("backup-password")
                SecureField("Passwort wiederholen", text: $repeated).textContentType(.newPassword).accessibilityIdentifier("backup-password-repeat")
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                Text("Das Passwort kann nicht wiederhergestellt werden. Bitte sicher notieren.").font(.caption).foregroundStyle(.secondary)
                Button("Sicherung erstellen …") {
                    do {
                        try BackupFormat.checkNewPassword(password, repeated: repeated)
                        let secret = password; password = ""; repeated = ""; problem = nil
                        Task { if let url = await app.createBackup(password: secret, includeAudio: includeAudio) { created = url; moving = true } }
                    } catch { problem = error.localizedDescription }
                }.disabled(app.busy || (app.document.cases.isEmpty && (app.document.quickChecks ?? []).isEmpty)).accessibilityIdentifier("backup-create")
            } header: { Text("Sicherung erstellen") }
            Section {
                Text("Fälle, die schon auf dem iPhone sind, bleiben unverändert. Nur fehlende Fälle und Schnellchecks kommen hinzu. Eine Sicherung von Android lässt sich hier ebenfalls öffnen.")
                    .font(.caption).foregroundStyle(.secondary)
                if source == nil {
                    Button("Sicherung auswählen …") { picking = true }.disabled(app.busy).accessibilityIdentifier("backup-pick")
                } else {
                    SecureField("Passwort der Sicherung", text: $restorePassword).accessibilityIdentifier("restore-password")
                    HStack {
                        Button("Wiederherstellen") {
                            guard let url = source else { return }
                            let secret = restorePassword; source = nil; restorePassword = ""
                            Task { await app.restoreBackup(from: url, password: secret) }
                        }.disabled(app.busy || restorePassword.isEmpty).accessibilityIdentifier("restore-start")
                        Spacer()
                        Button("Abbrechen", role: .cancel) { source = nil; restorePassword = "" }
                    }.buttonStyle(.borderless)
                }
            } header: { Text("Wiederherstellen") }
            if app.busy, !app.workStatus.isEmpty { Section { Text(app.workStatus).font(.footnote) } }
            if let result = app.backupResult { Section { Label(result, systemImage: "checkmark.circle").accessibilityIdentifier("backup-result") } }
        }
        .themedBackground().navigationTitle("Sicherung").navigationBarTitleDisplayMode(.inline)
        .fileMover(isPresented: $moving, file: created) { result in
            if case .failure = result, let created { try? FileManager.default.removeItem(at: created) }
            if case .failure = result { app.backupResult = nil }
            created = nil
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { source = url; restorePassword = "" }
        }
        .onDisappear { password = ""; repeated = ""; restorePassword = "" }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        bytes < 1_000_000 ? "unter 1 MB" : "\((bytes / 1_000_000).formatted(.number.locale(Locale(identifier: "de_DE")))) MB"
    }
}
