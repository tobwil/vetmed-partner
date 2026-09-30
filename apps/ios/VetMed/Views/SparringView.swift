import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO
import PDFKit

private struct ImportedChatPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let bytes = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard bytes <= ChatAttachmentImporter.maximumOriginalBytes else { throw AppFailure("Bitte ein Bild bis 20 MB auswählen.") }
            try AppPaths.prepare(AppPaths.scratch)
            let url = AppPaths.scratch.appendingPathComponent("photo-import-" + UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: url)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return Self(url: url)
        }
    }
}

struct SparringHome: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var search = ""
    private var checks: [QuickCheck] {
        (app.document.quickChecks ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.runs.last?.createdAt ?? $0.createdAt) > ($1.runs.last?.createdAt ?? $1.createdAt) }
    }
    private var caseChats: [(VetCase, Encounter)] {
        app.document.cases.flatMap { item in item.encounters.compactMap { encounter in
            let hasChat = !(encounter.analysisRuns ?? []).isEmpty || !(encounter.sparringDraft?.question ?? "").isEmpty || !(encounter.chatAttachments ?? []).isEmpty
            guard hasChat, search.isEmpty || item.label.localizedCaseInsensitiveContains(search) || (encounter.sparringDraft?.question ?? "").localizedCaseInsensitiveContains(search) else { return nil }
            return (item, encounter)
        } }.sorted { $0.1.lastActivity > $1.1.lastActivity }
    }
    var body: some View {
        List {
            if checks.isEmpty && caseChats.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Was möchtest du besprechen?" : "Kein passender Chat", systemImage: "bubble.left.and.bubble.right", description: Text(search.isEmpty ? "Starte einen Chat und füge bei Bedarf Bilder oder Befunde hinzu. Ein Fall ist dafür nicht nötig." : "Suche nach einer Frage oder Fallkennung."))
            }
            if !checks.isEmpty {
                Section("Ohne Fall") {
                    ForEach(checks) { check in
                        NavigationLink(value: ChatLocation(caseID: nil, encounterID: check.id)) {
                            HStack(spacing: 14) {
                                GradientIcon(systemName: "bubble.left.fill", size: 38)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(check.title).font(.headline).lineLimit(2)
                                    Text(check.runs.last?.text.isEmpty == false ? String(check.runs.last!.text.prefix(100)) : "Entwurf").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("chat-row-" + check.id.uuidString)
                    }
                }
            }
            if !caseChats.isEmpty {
                Section("Zu einem Fall") {
                    ForEach(caseChats, id: \.1.id) { item, encounter in
                        NavigationLink(value: ChatLocation(caseID: item.id, encounterID: encounter.id)) {
                            HStack(spacing: 14) {
                                GradientIcon(systemName: SpeciesIcon.symbol(for: item.species), size: 38)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.label).font(.headline)
                                    Text(encounter.analysisRuns?.first?.snapshot.draft.question ?? encounter.sparringDraft?.question ?? "Fall-Chat").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.themedBackground().navigationTitle("Chats").searchable(text: $search, prompt: "Frage oder Fall suchen")
            .disabled(app.captureInProgress)
            .toolbar {
                if app.chatPath.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { NewChatButton() }
                }
            }
    }
}
struct NewChatButton: View {
    @EnvironmentObject private var app: VetAppModel
    var body: some View {
        Button("Neuer Chat", systemImage: "square.and.pencil") { Task { await app.newQuickCheck() } }
            .accessibilityIdentifier("new-quick-check").disabled(app.busy || app.captureInProgress)
    }
}

struct ChatConversationView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accentTheme) private var theme
    let caseID: UUID?
    let encounterID: UUID
    @State private var draft = SparringDraft()
    @State private var loaded = false
    @State private var savedDraft: SparringDraft?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoPicker = false
    @State private var photoLoading = false
    @State private var filePicker = false
    @State private var review: ChatAttachment?
    @State private var details = false
    @State private var reportPicker = false
    @State private var share: SharePayload?
    @State private var copiedID: UUID?
    @State private var deleting = false
    @FocusState private var focused: Bool
    private var caseLabel: String { caseID.flatMap { id in app.document.cases.first { $0.id == id }?.label } ?? "Ohne Fall" }
    private var caseContext: VetCase? { caseID.flatMap { id in app.document.cases.first { $0.id == id } } }
    private var availableReports: [ChatReportContext] { caseContext.map { ChatReportSelection.available(in: $0) } ?? [] }
    private var selectedReports: [ChatReportContext] { availableReports.filter { (draft.reportIDs ?? []).contains($0.id) } }
    private var encounter: Encounter? { app.analysisContext(caseID: caseID, encounterID: encounterID) }
    private var runs: [AnalysisRun] { encounter?.analysisRuns ?? [] }
    private var attachments: [ChatAttachment] { encounter?.chatAttachments ?? [] }
    private var selectedAttachments: [ChatAttachment] { attachments.filter { (draft.attachmentIDs ?? []).contains($0.id) } }
    private var sending: Bool { runs.contains { $0.id == app.activeAnalysisID } }
    private var preparedDraft: SparringDraft {
        var value = draft
        value.historyIDs = runs.filter { $0.status == .completed }.map(\.id)
        value.mode = .question
        if value.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(value.attachmentIDs ?? []).isEmpty { value.question = "Bitte diese Anhänge fachlich einordnen." }
        return value
    }
    private var snapshot: Result<SparringSnapshot, Error> {
        Result {
            guard let encounter else { throw AppFailure("Dieser Chat ist nicht mehr vorhanden.") }
            return try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: preparedDraft, modelID: app.onlineConfiguration.modelID, caseContext: caseContext)
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if runs.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            GradientIcon(systemName: "sparkles", size: 64)
                                .symbolEffect(.breathe, options: .repeat(.continuous))
                            Text("Was möchtest du besprechen?").font(.title2.bold())
                            Text(selectedReports.isEmpty ? "Schreib einfach los. Über + kannst du Bilder und Befunde hinzufügen." : "Stell deine Frage zum Fall. Die unten ausgewählten Berichte werden beim Senden mitgegeben; über + kannst du Bilder und Befunde ergänzen.").foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                suggestion("Befund erklären", symbol: "text.magnifyingglass")
                                suggestion("Nächste Schritte", symbol: "list.bullet.clipboard")
                                suggestion("Differenzialdiagnosen", symbol: "stethoscope")
                                suggestion("Dosierung prüfen", symbol: "pills")
                            }
                        }.padding(.vertical, 24).appearEffect()
                    }
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Spacer(minLength: 30)
                                VStack(alignment: .leading, spacing: 10) {
                                    if !(run.snapshot.images ?? []).isEmpty {
                                        ScrollView(.horizontal) { HStack { ForEach(run.snapshot.images ?? [], id: \.attachmentID) { image in
                                            ChatImageThumbnail(caseID: caseID, encounterID: encounterID, id: image.attachmentID)
                                                .onTapGesture { review = attachments.first { $0.id == image.attachmentID } }
                                        } } }
                                    }
                                    if !(run.snapshot.documents ?? []).isEmpty { Label("\(run.snapshot.documents?.count ?? 0) Dokumenttexte", systemImage: "doc.text").font(.caption) }
                                    if let reports = run.snapshot.reports, !reports.isEmpty {
                                        Label("\(reports.count) Fallbericht\(reports.count == 1 ? "" : "e") verwendet", systemImage: "doc.text").font(.caption)
                                    }
                                    Text(run.snapshot.draft.question).textSelection(.enabled)
                                }
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(theme.gradient, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                                .shadow(color: theme.primary.opacity(0.25), radius: 8, y: 4)
                            }
                            if run.status.isActive || !run.text.isEmpty {
                                HStack(spacing: 8) {
                                    GradientIcon(systemName: "sparkles", size: 26)
                                        .symbolEffect(.pulse, isActive: run.status.isActive)
                                    Text("VetMed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if run.status.isActive && run.text.isEmpty {
                                        TypingIndicator()
                                        Text("Denke nach …").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if !run.text.isEmpty {
                                ChatMarkdownView(text: run.text).frame(maxWidth: .infinity, alignment: .leading).card(cornerRadius: 20)
                                HStack(spacing: 10) {
                                    Button(copiedID == run.id ? "Kopiert" : "Kopieren", systemImage: copiedID == run.id ? "checkmark" : "doc.on.doc") { withAnimation(.snappy) { copiedID = run.id }; ExportService.copyText(ChatMarkdown.export(run)) }.accessibilityIdentifier("copy-answer-" + run.id.uuidString)
                                        .contentTransition(.symbolEffect(.replace)).sensoryFeedback(.success, trigger: copiedID == run.id)
                                    Button("Teilen", systemImage: "square.and.arrow.up") { share = SharePayload(content: .text(ChatMarkdown.export(run)), reportID: nil, format: "Chat") }.accessibilityIdentifier("share-answer-" + run.id.uuidString)
                                }.font(.caption.weight(.medium)).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).disabled(run.status.isActive)
                            }
                            if !run.status.isActive {
                                HStack {
                                    Text(run.status == .completed ? "KI-Antwort · fachlich prüfen" : run.status.title).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if run.status != .completed {
                                        Button("Erneut versuchen") { draft = run.snapshot.draft; focused = true }.font(.caption)
                                    }
                                }
                            }
                            if let notice = run.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        }.id(run.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }.padding(20)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: runs.map(\.id))
            }.scrollDismissesKeyboard(.interactively)
                .background { AmbientBackground() }
                .onChange(of: runs.last?.text.count) { _, _ in if sending { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
                .onChange(of: runs.last?.id) { _, id in
                    guard let run = runs.last, run.id == id, loaded else { return }
                    if run.snapshot.draft.question == preparedDraft.question, run.snapshot.draft.attachmentIDs == preparedDraft.attachmentIDs {
                        draft = .init(reportIDs: draft.reportIDs); save()
                    }
                    withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
        }
        .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Label(caseLabel, systemImage: caseID == nil ? "bubble.left" : "folder").font(.subheadline.weight(.semibold)).accessibilityIdentifier("chat-scope")
                Spacer()
                if caseID != nil, let date = encounter?.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular.tint(theme.primary.opacity(0.10)), in: .capsule)
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { NewChatButton().disabled(photoLoading) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Chat-Details", systemImage: "info.circle") { details = true }
                    if caseID == nil { Button("Chat löschen", systemImage: "trash", role: .destructive) { deleting = true } }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityIdentifier("chat-menu")
                .disabled(app.busy || app.captureInProgress || photoLoading)
            }
        }
        .alert("Diesen Chat mit allen Nachrichten und Anhängen löschen?", isPresented: $deleting) {
            Button("Behalten", role: .cancel) {}
            Button("Chat löschen", role: .destructive) { Task { await app.deleteQuickCheck(encounterID) } }
        }
        .onAppear {
            if !loaded {
                draft = encounter?.sparringDraft ?? .init(); savedDraft = draft
                if draft.reportIDs == nil, let caseContext {
                    draft.reportIDs = ChatReportSelection.defaultIDs(in: caseContext, encounterID: encounterID)
                }
                loaded = true
            }
        }
        .task(id: draft) {
            guard loaded else { return }
            let value = draft
            do { try await Task.sleep(for: .milliseconds(700)); try Task.checkCancellation(); if await app.saveSparringDraft(value, caseID: caseID, encounterID: encounterID) { savedDraft = value } }
            catch {}
        }
        .onDisappear { save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
        .photosPicker(isPresented: $photoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            photoLoading = true
            Task {
                defer { photoLoading = false; selectedPhoto = nil }
                do {
                    guard let file = try await item.loadTransferable(type: ImportedChatPhoto.self) else { throw AppFailure("Das Foto konnte nicht geladen werden.") }
                    importFile(file.url, temporary: true)
                } catch { app.error = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, .plainText, .image, UTType(filenameExtension: "md") ?? .plainText]) { result in
            switch result { case .success(let url): importFile(url); case .failure(let error): app.error = error.localizedDescription }
        }
        .sheet(item: $review) { attachment in
            ChatAttachmentReview(caseID: caseID, encounterID: encounterID, attachment: attachment) { id in
                if !(draft.attachmentIDs ?? []).contains(id) { draft.attachmentIDs = (draft.attachmentIDs ?? []) + [id] }
            }
        }
        .sheet(item: $share) { payload in
            ActivitySheet(content: payload.content) { _, error in
                if error != nil { app.error = "Die Antwort konnte nicht übergeben werden. Du kannst sie auch über Kopieren einfügen." }
            }
        }
        .sheet(isPresented: $reportPicker) { reportSelection }
        .sheet(isPresented: $details) {
            NavigationStack {
                List {
                    Section("Verbindung") {
                        Text("OpenAI · \(app.onlineConfiguration.modelID.isEmpty ? "Noch nicht eingerichtet" : app.onlineConfiguration.modelID)")
                        NavigationLink("API-Key & Modell") { OnlineReportSettingsView() }
                        Text("Nur beim Senden wird dein Chat übertragen. Kein automatischer Neuversand. Webrecherche ist derzeit aus.").font(.footnote)
                    }
                    if let transcript = encounter?.transcripts.last {
                        Section { Button("Falltranskript hinzufügen") { draft.context = transcript.editedText; draft.transcriptVersionID = transcript.id; details = false } }
                    }
                    Section("Nächste Anfrage") {
                        switch snapshot {
                        case .success(let value): ChatPayloadPreview(snapshot: value)
                        case .failure(let error): Text(error.localizedDescription).font(.footnote)
                        }
                    }
                    ForEach(runs) { run in
                        Section(run.createdAt.formatted()) {
                            Text(run.actualModelID ?? run.snapshot.modelID).font(.caption)
                            if let usage = run.usage { Text("Tokens: \(usage.inputTokens) Eingabe · \(usage.outputTokens) Ausgabe · Preis unbekannt").font(.caption) }
                            ChatPayloadPreview(snapshot: run.snapshot)
                        }
                    }
                }.themedBackground().navigationTitle("Chat-Details").toolbar { Button("Schließen") { details = false } }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if caseID != nil {
                Button { focused = false; reportPicker = true } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "doc.text")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedReports.isEmpty ? "Berichte als Wissen hinzufügen" : "\(selectedReports.count) Fallbericht\(selectedReports.count == 1 ? "" : "e") als Wissen").font(.caption.weight(.semibold))
                            if selectedReports.count == 1, let report = selectedReports.first {
                                Text(report.title + " · " + report.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("chat-reports").disabled(sending)
            }
            if !selectedAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(selectedAttachments) { item in
                            HStack(spacing: 6) {
                                Button { review = item } label: {
                                    if item.kind == .image { ChatImageThumbnail(caseID: caseID, encounterID: encounterID, id: item.id) }
                                    else { Label(item.originalName, systemImage: item.reviewedAt == nil ? "doc.badge.clock" : "doc.text").lineLimit(1).font(.caption) }
                                }
                                Button { draft.attachmentIDs?.removeAll { $0 == item.id } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Anhang entfernen")
                            }.padding(5).background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
            if !draft.context.isEmpty {
                HStack { Label("Falltext hinzugefügt", systemImage: "doc.text").font(.caption); Spacer(); Button("Entfernen") { draft.context = ""; draft.transcriptVersionID = nil }.font(.caption) }
            }
            if photoLoading { HStack { ProgressView(); Text("Bild wird geladen …").font(.caption) } }
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    if caseID != nil {
                        Button("Fallberichte auswählen", systemImage: "doc.text") { focused = false; reportPicker = true }
                    }
                    Button("Foto auswählen", systemImage: "photo") { focused = false; photoPicker = true }
                    Button("Datei hinzufügen", systemImage: "paperclip") { focused = false; filePicker = true }
                    if !attachments.isEmpty {
                        Menu("Vorhandene Anhänge") { ForEach(attachments) { item in Button(item.displayName) { review = item } } }
                    }
                    if let transcript = encounter?.transcripts.last {
                        Button("Falltranskript hinzufügen", systemImage: "doc.text") { draft.context = transcript.editedText; draft.transcriptVersionID = transcript.id }
                    }
                } label: {
                    Image(systemName: "plus").font(.headline.weight(.semibold)).foregroundStyle(.tint)
                        .frame(width: 36, height: 36).background(theme.primary.opacity(0.14), in: Circle())
                }
                .accessibilityIdentifier("chat-add-attachment").disabled(app.busy || app.captureInProgress || photoLoading)
                TextField("Frag mich etwas …", text: $draft.question, axis: .vertical)
                    .lineLimit(1...6).focused($focused).accessibilityIdentifier("sparring-question")
                    .padding(.vertical, 8)
                Button {
                    if sending { app.cancel(); return }
                    if let document = selectedAttachments.first(where: { $0.kind == .document && $0.reviewedAt == nil }) { review = document; return }
                    switch snapshot {
                    case .success(let value): save(); focused = false; app.startAnalysis(value)
                    case .failure(let error): app.error = error.localizedDescription
                    }
                } label: {
                    Image(systemName: sending ? "stop.fill" : "arrow.up")
                        .font(.headline.weight(.bold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(sendDisabled ? AnyShapeStyle(Color.secondary.opacity(0.35)) : (sending ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(theme.gradient))))
                        .scaleEffect(sendDisabled ? 0.9 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: sendDisabled)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(sending ? "Antwort abbrechen" : "Senden").accessibilityIdentifier("send-analysis")
                .disabled(sendDisabled)
                .sensoryFeedback(.impact(weight: .light), trigger: sending)
            }
            .padding(6)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(focused ? theme.primary.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 1))
            .shadow(color: focused ? theme.primary.opacity(0.18) : .clear, radius: 10, y: 2)
            .animation(.easeInOut(duration: 0.2), value: focused)
            if !app.onlineConfiguration.isEnabled || !app.hasOnlineKey {
                Button("Zum Senden einmalig API-Zugang einrichten") { details = true }.font(.caption)
            }
            Text(savedDraft == draft ? "Lokal gespeichert · KI-Antworten fachlich prüfen" : "Entwurf wird gespeichert …").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("chat-save-status")
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedAttachments.map(\.id))
    }
    private var reportSelection: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ausgewählte Berichte werden mit deiner nächsten Nachricht gesendet. Die Auswahl bleibt für weitere Fragen erhalten.").font(.footnote)
                    if !runs.isEmpty { Text("Frühere Chatnachrichten bleiben im Verlauf. Abgewählte Berichte werden nicht erneut als Quelldokument gesendet.").font(.footnote).foregroundStyle(.secondary) }
                }
                if availableReports.isEmpty {
                    ContentUnavailableView("Noch kein Bericht", systemImage: "doc.text", description: Text("Erstelle zuerst einen Bericht zu diesem Fall. Ein vorhandenes Transkript kannst du über + hinzufügen."))
                } else {
                    Section("Berichte dieses Falls") {
                        ForEach(availableReports) { report in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { (draft.reportIDs ?? []).contains(report.id) }, set: { selected in
                                    var ids = draft.reportIDs ?? []
                                    ids.removeAll { $0 == report.id }
                                    if selected { ids.append(report.id) }
                                    draft.reportIDs = ids
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(report.title).font(.headline)
                                        Text("Vorgang: " + report.encounterDate.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                        Text("Version: " + report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                        Text(report.status + (report.isOlderVersion ? " · ältere Version" : "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.accessibilityIdentifier("chat-report-" + report.id.uuidString)
                                DisclosureGroup("Bericht ansehen") {
                                    Text(report.text).font(.footnote).textSelection(.enabled)
                                    if !report.warnings.isEmpty { Text(report.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    Section {
                        Button("Alle Berichte abwählen") { draft.reportIDs = [] }.accessibilityIdentifier("clear-chat-reports")
                    }
                }
            }.themedBackground().navigationTitle("Berichte als Wissen").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { save(); reportPicker = false } } }
        }
    }
    private var sendDisabled: Bool {
        (app.busy && !sending) || app.captureInProgress || photoLoading || (!sending && draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedAttachments.isEmpty)
    }
    private func suggestion(_ title: String, symbol: String) -> some View {
        Button { draft.question = title + ": "; focused = true } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
    }
    private func save() {
        guard loaded else { return }
        let value = draft
        Task { if await app.saveSparringDraft(value, caseID: caseID, encounterID: encounterID) { savedDraft = value } }
    }
    private func importFile(_ url: URL, temporary: Bool = false) {
        app.importChatAttachment(url: url, caseID: caseID, encounterID: encounterID, removeAfterImport: temporary) { attachment in
            draft.attachmentIDs = (draft.attachmentIDs ?? []) + [attachment.id]
            if attachment.kind == .document { review = attachment }
            save()
        }
    }
}

private struct ChatImageThumbnail: View {
    @EnvironmentObject private var app: VetAppModel
    let caseID: UUID?
    let encounterID: UUID
    let id: UUID
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 72, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: id) {
                guard let data = try? await app.chatAttachmentData(caseID: caseID, encounterID: encounterID, id: id, upload: true),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary) else { return }
                image = UIImage(cgImage: cg)
            }
    }
}

private struct ChatPayloadPreview: View {
    let snapshot: SparringSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.userText).font(.footnote).textSelection(.enabled)
            Text("\(snapshot.draft.historyIDs.count) frühere Antworten · \(snapshot.requestImages?.count ?? 0) Bilder im Anfragekontext").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Anfragedetails") { Text(String(decoding: snapshot.payload, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }
}

private struct ChatAttachmentReview: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID?
    let encounterID: UUID
    let attachment: ChatAttachment
    var use: (UUID) -> Void
    @State private var data: Data?
    @State private var text = ""
    @State private var showOriginal = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Group {
                if attachment.kind == .image {
                    VStack(spacing: 16) {
                        if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
                        else if let failure { Text(failure) } else { ProgressView() }
                        Text("Dieses Bild wird gesendet. \(attachment.width ?? 0) × \(attachment.height ?? 0) Pixel. Das Original bleibt lokal; Standort- und Kamerametadaten wurden aus dieser Version entfernt.").font(.caption).foregroundStyle(.secondary)
                        Text("Bitte eingeblendete Namen oder Kontaktdaten im Bild vor dem Anhängen entfernen.").font(.caption).foregroundStyle(.secondary)
                    }.padding()
                } else {
                    Form {
                        Section {
                            Text(attachment.usedOCR ? "Text wurde lokal erkannt. Bitte besonders Zahlen, Einheiten und Tabellen am Original prüfen." : "Prüfe den ausgelesenen Text am Original. Nur dieser Text wird an den Chat übergeben.").font(.footnote)
                            Button("Original ansehen") { showOriginal = true }
                            TextEditor(text: $text).frame(minHeight: 360)
                            Button("Text geprüft übernehmen") { Task { if await app.reviewChatDocument(caseID: caseID, encounterID: encounterID, id: attachment.id, text: text) { use(attachment.id); dismiss() } } }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }.navigationTitle(attachment.kind == .image ? "Bildvorschau" : "Dokument prüfen").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                    if attachment.kind == .image { ToolbarItem(placement: .confirmationAction) { Button("Verwenden") { use(attachment.id); dismiss() }.disabled(data == nil) } }
                }
                .task {
                    text = attachment.reviewedText ?? attachment.extractedText ?? ""
                    do { data = try await app.chatAttachmentData(caseID: caseID, encounterID: encounterID, id: attachment.id, upload: attachment.kind == .image) }
                    catch { failure = error.localizedDescription }
                }
                .sheet(isPresented: $showOriginal) {
                    NavigationStack {
                        Group {
                            if let data, attachment.originalExtension == "pdf" { LocalPDFPreview(data: data) }
                            else if let data { ScrollView { Text(String(decoding: data, as: UTF8.self)).textSelection(.enabled).padding() } }
                            else { Text(failure ?? "Original wird geladen …") }
                        }.navigationTitle("Original").toolbar { Button("Schließen") { showOriginal = false } }
                    }
                }
        }
    }
}
private struct LocalPDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
