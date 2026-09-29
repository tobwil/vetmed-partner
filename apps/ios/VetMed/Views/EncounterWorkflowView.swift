import SwiftUI

struct EncounterEditor: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let location: EncounterLocation
    @ObservedObject var recorder: AudioRecorder
    @State private var step: EncounterStep = .recording
    @State private var transcript = ""
    @State private var lastSavedTranscript = ""
    @State private var loaded = false
    @FocusState private var transcriptFocused: Bool
    @State private var editingCase = false
    @State private var options = false
    @State private var reportID: UUID?
    @AppStorage("report-template") private var template: ReportTemplate = .treatment_report
    @AppStorage("report-length") private var length: ReportLength = .medium
    @AppStorage("report-audience") private var audience: Audience = .veterinarian
    @State private var mode: ReportExecutionMode = .offline
    private var item: VetCase? { app.document.cases.first { $0.id == location.caseID } }
    private var encounter: Encounter? { app.encounter(at: location) }
    private var recording: Bool { app.recordingLocation == location && recorder.isRecording }
    private var blocked: Bool { app.busy || (app.captureInProgress && app.recordingLocation != location) }
    private var duration: Double { app.recordingLocation == location ? recorder.elapsed : (encounter?.audio.reduce(0) { $0 + $1.duration } ?? 0) }
    var body: some View {
        Form {
            Section {
                HStack {
                    Label(item?.species ?? "Fall", systemImage: "cross.case").font(.subheadline)
                    Spacer()
                    Button("Falldaten", systemImage: "pencil") { editingCase = true }.font(.subheadline)
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(EncounterStep.allCases) { value in
                        Button { step = value } label: {
                            VStack(spacing: 6) {
                                Text("\(value.rawValue + 1)").font(.caption.bold()).frame(width: 26, height: 26)
                                    .background(step == value ? Color.teal : Color.secondary.opacity(0.15), in: Circle())
                                    .foregroundStyle(step == value ? .white : .primary)
                                Text(value.title).font(.caption).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.plain).accessibilityIdentifier("workflow-step-\(value.rawValue)")
                            .accessibilityAddTraits(step == value ? .isSelected : [])
                            .disabled(app.busy || app.captureInProgress || (value == .report && (encounter?.reports.isEmpty ?? true)))
                    }
                }.padding(.vertical, 8)
            }
            switch step {
            case .recording: recordingContent
            case .transcript: transcriptContent
            case .report: reportContent
            }
            Section { DeleteCaseButton(caseID: location.caseID) { dismiss() } }
        }.navigationTitle(item?.label ?? "Diktat").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Zum Fall chatten", systemImage: "bubble.left.and.bubble.right") { app.openChat(location.chat) }
                        .accessibilityIdentifier("chat-from-dictation").disabled(app.busy || app.captureInProgress)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fertig") { transcriptFocused = false } }
            }
            .safeAreaInset(edge: .bottom) { primaryAction }
            .sheet(isPresented: $editingCase) { CaseEditor(caseID: location.caseID) }
            .sheet(isPresented: $options) { reportOptions }
            .navigationDestination(isPresented: Binding(get: { reportID != nil }, set: { if !$0 { reportID = nil } })) {
                if let reportID { ReportReview(reportID: reportID, location: location) }
            }
            .onAppear {
                guard !loaded else { return }
                transcript = encounter?.transcripts.last?.editedText ?? ""; lastSavedTranscript = transcript
                step = encounter?.suggestedStep ?? .recording; mode = app.onlineConfiguration.preferredMode; loaded = true
            }
            .onChange(of: encounter == nil) { _, missing in if missing { dismiss() } }
            .onChange(of: encounter?.transcripts.last?.id) { _, _ in
                let saved = encounter?.transcripts.last?.editedText ?? ""
                if transcript == lastSavedTranscript { transcript = saved }
                lastSavedTranscript = saved
            }
            .onChange(of: encounter?.reports.last?.id) { old, new in
                if loaded, let new, new != old { step = .report; reportID = new }
            }
            .task(id: transcript) {
                guard loaded, transcript != lastSavedTranscript else { return }
                let value = transcript
                do {
                    try await Task.sleep(for: .seconds(1)); try Task.checkCancellation()
                    if await app.saveTranscript(value, at: location) { lastSavedTranscript = value }
                } catch {}
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { savePendingText() } }
            .onDisappear {
                savePendingText()
                if recording { Task { await app.pauseRecording() } }
            }
    }
    private var recordingContent: some View {
        Section {
            VStack(spacing: 16) {
                Text(recording ? "Aufnahme läuft" : ((encounter?.audio.isEmpty ?? true) ? "Bereit für dein Diktat" : "Aufnahme pausiert")).font(.title3.bold())
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))).font(.system(size: 40, weight: .medium, design: .rounded)).monospacedDigit()
                Button {
                    Task {
                        if recording { await app.pauseRecording() }
                        else { await app.record(at: location) }
                    }
                } label: {
                    Label(recording ? "Pause" : ((encounter?.audio.isEmpty ?? true) ? "Aufnahme starten" : "Fortsetzen"), systemImage: recording ? "pause.fill" : "mic.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(recording ? .red : .teal)
                    .disabled(blocked || app.recordingActionPending || recorder.isTransitioning).accessibilityIdentifier("record-audio")
                Text("Lass die App während der Aufnahme geöffnet.").font(.footnote).foregroundStyle(.secondary)
                if app.recordingLocation == location, let error = recorder.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let error = encounter?.lastError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if !recording {
                    Button("Text stattdessen eingeben") { step = .transcript }.accessibilityIdentifier("enter-transcript").disabled(blocked)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
        }
    }
    private var transcriptContent: some View {
        Group {
            Section {
                TextEditor(text: $transcript).focused($transcriptFocused).frame(minHeight: 250).accessibilityIdentifier("transcript-editor")
                    .disabled(app.busy || app.captureInProgress).autocorrectionDisabled()
                Text(transcript == lastSavedTranscript ? "Text gespeichert" : "Text wird gespeichert …").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("transcript-save-status")
                Text("Zahlen, Einheiten und Verneinungen bitte am Original prüfen.").font(.footnote).foregroundStyle(.secondary)
                let numbers = ReportValidator.numbers(transcript).sorted()
                if !numbers.isEmpty { Text("Zahlen im Text: " + numbers.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                ForEach(app.vocabulary.filter { $0.appears(in: transcript) }) { entry in
                    Button("\(entry.recognized) → \(entry.preferred)") { transcript = entry.applying(to: transcript) }.font(.footnote).disabled(blocked)
                }
                Button("Text speichern") { Task { if await app.saveTranscript(transcript, at: location) { lastSavedTranscript = transcript } } }.accessibilityIdentifier("save-transcript").disabled(blocked || app.captureInProgress)
            } header: { Text("Text prüfen und ergänzen") }
            if let version = encounter?.transcripts.last {
                Section {
                    DisclosureGroup("Original und Aufnahme") {
                        Text(version.rawText).font(.footnote).textSelection(.enabled)
                        ForEach(encounter?.playbackSegments ?? []) { segment in
                            Button { Task { await app.play(segment, at: location) } } label: { Label(segment.text, systemImage: "play.circle") }.font(.footnote).disabled(blocked || app.captureInProgress)
                        }
                    }
                }
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.title).font(.subheadline)
                        Text("\(length.title) · \(audience.title) · \(mode == .online ? "Online" : "Offline")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Button("Anpassen") { options = true }.accessibilityIdentifier("report-options")
                }
            }
        }
    }
    private var reportContent: some View {
        Group {
            if let reports = encounter?.reports, !reports.isEmpty {
                Section("Berichte") {
                    ForEach(reports.reversed()) { report in
                        Button { reportID = report.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.content.template.title).font(.headline)
                                Label(report.approvedAt == nil ? "Bitte prüfen" : "Geprüft", systemImage: report.approvedAt == nil ? "doc.text" : "checkmark.seal").font(.subheadline)
                                Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                    Button("Text bearbeiten oder weiteren Bericht erstellen") { step = .transcript }
                }
            }
            if let checkpoint = encounter?.reportCheckpoint {
                Section("Unvollständiger Zwischenstand") {
                    Text("\(checkpoint.completedChunks) von \(checkpoint.totalChunks) Abschnitten gespeichert").font(.subheadline)
                    DisclosureGroup("Bisherigen Text ansehen") { Text(checkpoint.report.text).font(.footnote).textSelection(.enabled) }
                }
            }
        }
    }
    @ViewBuilder private var primaryAction: some View {
        if !app.busy {
            Group {
                switch step {
                case .recording:
                    if recording || !(encounter?.audio.isEmpty ?? true) {
                        Button("Fertig · Text prüfen") {
                            Task {
                                if recording { await app.pauseRecording() }
                                guard !app.captureInProgress else { return }
                                step = .transcript
                                if encounter?.hasPendingAudio == true { app.transcribe(at: location) }
                            }
                        }.accessibilityIdentifier("finish-dictation").disabled(blocked || recorder.isTransitioning || app.recordingActionPending)
                    }
                case .transcript:
                    Button("Bericht erstellen", systemImage: "sparkles") {
                        Task {
                            let value = transcript
                            guard await app.saveTranscript(value, at: location) else { return }
                            lastSavedTranscript = value
                            app.generate(at: location, template: template, length: length, audience: audience, mode: mode)
                        }
                    }.accessibilityIdentifier("generate-report").disabled(blocked || app.captureInProgress || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .report:
                    if let report = encounter?.reports.last { Button(report.approvedAt == nil ? "Bericht prüfen" : "Bericht ansehen und teilen") { reportID = report.id }.disabled(blocked) }
                }
            }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
        }
    }
    private var reportOptions: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Vorlage", selection: $template) { ForEach(ReportTemplate.allCases) { Text($0.title).tag($0) } }
                    Picker("Länge", selection: $length) { ForEach(ReportLength.allCases) { Text($0.title).tag($0) } }
                    Picker("Für wen?", selection: $audience) { ForEach(Audience.allCases) { Text($0.title).tag($0) } }
                }
                Section("Verarbeitung") {
                    Picker("Modus", selection: $mode) { ForEach(ReportExecutionMode.allCases) { Text($0.title).tag($0) } }
                    if mode == .online {
                        if !app.hasOnlineKey || !app.onlineConfiguration.isEnabled { NavigationLink("Online-Zugang einrichten") { OnlineReportSettingsView() } }
                        Text("Online wird nur der geprüfte Text mit deinen Berichtseinstellungen gesendet.").font(.footnote)
                        DisclosureGroup("Text vor dem Senden ansehen") { Text(transcript).font(.footnote).textSelection(.enabled) }
                    } else { Text("Für Offline-Berichte muss das lokale Modell in den Einstellungen installiert sein.").font(.footnote) }
                }
            }.navigationTitle("Bericht anpassen").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { options = false } } }
        }
    }
    private func savePendingText() {
        guard loaded, transcript != lastSavedTranscript else { return }
        let value = transcript
        Task { if await app.saveTranscript(value, at: location) { lastSavedTranscript = value } }
    }
}
