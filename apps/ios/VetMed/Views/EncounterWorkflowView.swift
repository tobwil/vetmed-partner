import SwiftUI

struct EncounterEditor: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accentTheme) private var theme
    @Namespace private var stepNamespace
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
                HStack(spacing: 4) {
                    ForEach(EncounterStep.allCases) { value in
                        let selected = step == value
                        let done = value.rawValue < (encounter?.suggestedStep.rawValue ?? 0)
                        Button { withAnimation(.snappy(duration: 0.35)) { step = value } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: done && !selected ? "checkmark.circle.fill" : "\(value.rawValue + 1).circle.fill")
                                    .font(.subheadline).contentTransition(.symbolEffect(.replace)).accessibilityHidden(true)
                                Text(value.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                            }
                            .foregroundStyle(selected ? Color.white : (done ? theme.primary : Color.primary))
                            .padding(.vertical, 10).padding(.horizontal, 4).frame(maxWidth: .infinity)
                            .background {
                                if selected {
                                    Capsule().fill(theme.gradient)
                                        .shadow(color: theme.primary.opacity(0.35), radius: 6, y: 3)
                                        .matchedGeometryEffect(id: "active-step", in: stepNamespace)
                                }
                            }
                            .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("workflow-step-\(value.rawValue)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .disabled(app.busy || app.captureInProgress || (value == .report && (encounter?.reports.isEmpty ?? true)))
                    }
                }
                .padding(4).background(Color.primary.opacity(0.06), in: Capsule())
                .sensoryFeedback(.selection, trigger: step)
                .padding(.vertical, 4)
            }
            switch step {
            case .recording: recordingContent
            case .transcript: transcriptContent
            case .report: reportContent
            }
            Section { DeleteCaseButton(caseID: location.caseID) { dismiss() } }
        }.themedBackground().navigationTitle(item?.label ?? "Diktat").navigationBarTitleDisplayMode(.inline)
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
                HStack(spacing: 8) {
                    Image(systemName: recording ? "record.circle.fill" : "record.circle").font(.headline)
                        .foregroundStyle(recording ? Color.red : Color.secondary)
                        .symbolEffect(.pulse, isActive: recording)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    Text(recording ? "Aufnahme läuft" : ((encounter?.audio.isEmpty ?? true) ? "Bereit für dein Diktat" : "Aufnahme pausiert")).font(.title3.bold())
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("recording-status")
                }
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .accessibilityIdentifier("recording-elapsed")
                    .font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: duration))
                    .animation(.snappy, value: Int(duration))
                    .foregroundStyle(recording ? Color.red : Color.primary)
                let recordTitle = recording ? "Pause" : ((encounter?.audio.isEmpty ?? true) ? "Aufnahme starten" : "Fortsetzen")
                ZStack {
                    PulseRings(active: recording, color: .red).frame(width: 116, height: 116)
                    Button {
                        Task {
                            if recording { await app.pauseRecording() }
                            else { await app.record(at: location) }
                        }
                    } label: {
                        Image(systemName: recording ? "pause.fill" : "mic.fill")
                            .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 116, height: 116)
                            .background { Circle().fill(recording ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(theme.gradient)) }
                            .shadow(color: (recording ? Color.red : theme.primary).opacity(0.45), radius: 18, y: 8)
                    }.buttonStyle(PressableButtonStyle())
                        .accessibilityLabel(recordTitle)
                        .disabled(blocked || app.recordingActionPending || recorder.isTransitioning).accessibilityIdentifier("record-audio")
                        .sensoryFeedback(recording ? .start : .stop, trigger: recording)
                }.frame(height: 190).animation(.spring(response: 0.4, dampingFraction: 0.7), value: recording)
                Text(recordTitle).font(.headline).foregroundStyle(.secondary).contentTransition(.opacity).accessibilityHidden(true)
                Text("Lass die App während der Aufnahme geöffnet.").font(.footnote).foregroundStyle(.secondary)
                if app.recordingLocation == location, let error = recorder.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let error = encounter?.lastError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if !recording {
                    Button("Text stattdessen eingeben", systemImage: "keyboard") { withAnimation(.snappy(duration: 0.35)) { step = .transcript } }
                        .buttonStyle(.borderless).accessibilityIdentifier("enter-transcript").disabled(blocked)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
        }
    }
    private var transcriptContent: some View {
        Group {
            Section {
                TextEditor(text: $transcript).focused($transcriptFocused).frame(minHeight: 250).accessibilityIdentifier("transcript-editor")
                    .disabled(app.busy || app.captureInProgress).autocorrectionDisabled()
                HStack(spacing: 6) {
                    Image(systemName: transcript == lastSavedTranscript ? "checkmark.icloud.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(transcript == lastSavedTranscript ? Color.green : Color.secondary)
                        .symbolEffect(.rotate, isActive: transcript != lastSavedTranscript)
                        .contentTransition(.symbolEffect(.replace)).accessibilityHidden(true)
                    Text(transcript == lastSavedTranscript ? "Text gespeichert" : "Text wird gespeichert …").foregroundStyle(.secondary).accessibilityIdentifier("transcript-save-status")
                }.font(.caption)
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
                        Text("\(length.title) · \(mode == .online ? "Online" : "Offline")").font(.caption).foregroundStyle(.secondary)
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
                            HStack(spacing: 14) {
                                Image(systemName: report.approvedAt == nil ? "doc.text.fill" : "checkmark.seal.fill").font(.title3)
                                    .foregroundStyle(report.approvedAt == nil ? Color.orange : Color.green)
                                    .frame(width: 44, height: 44)
                                    .background((report.approvedAt == nil ? Color.orange : Color.green).opacity(0.14), in: Circle())
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.content.template.title).font(.headline).foregroundStyle(.primary)
                                    Text(report.approvedAt == nil ? "Bitte prüfen" : "Geprüft").font(.subheadline).foregroundStyle(.tint)
                                    Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    Button("Text bearbeiten oder weiteren Bericht erstellen") { withAnimation(.snappy(duration: 0.35)) { step = .transcript } }
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
                                withAnimation(.snappy(duration: 0.35)) { step = .transcript }
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
                            app.generate(at: location, template: template, length: length, mode: mode)
                        }
                    }.accessibilityIdentifier("generate-report").disabled(blocked || app.captureInProgress || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .report:
                    if let report = encounter?.reports.last { Button(report.approvedAt == nil ? "Bericht prüfen" : "Bericht ansehen und teilen") { reportID = report.id }.disabled(blocked) }
                }
            }.buttonStyle(.glassProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    private var reportOptions: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Vorlage", selection: $template) { ForEach(ReportTemplate.allCases) { Text($0.title).tag($0) } }
                    Picker("Länge", selection: $length) { ForEach(ReportLength.allCases) { Text($0.title).tag($0) } }
                }
                Section("Verarbeitung") {
                    Picker("Modus", selection: $mode) { ForEach(ReportExecutionMode.allCases) { Text($0.title).tag($0) } }
                    if mode == .online {
                        if !app.hasOnlineKey || !app.onlineConfiguration.isEnabled { NavigationLink("Online-Zugang einrichten") { OnlineReportSettingsView() } }
                        Text("Online wird nur der geprüfte Text mit deinen Berichtseinstellungen gesendet.").font(.footnote)
                        DisclosureGroup("Text vor dem Senden ansehen") { Text(transcript).font(.footnote).textSelection(.enabled) }
                    } else { Text("Für Offline-Berichte muss das lokale Modell in den Einstellungen installiert sein.").font(.footnote) }
                }
            }.themedBackground().navigationTitle("Bericht anpassen").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { options = false } } }
        }
    }
    private func savePendingText() {
        guard loaded, transcript != lastSavedTranscript else { return }
        let value = transcript
        Task { if await app.saveTranscript(value, at: location) { lastSavedTranscript = value } }
    }
}
