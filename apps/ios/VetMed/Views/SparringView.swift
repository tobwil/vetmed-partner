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
    var body: some View {
        Group {
            if let id = app.selectedQuickCheckID, app.document.quickChecks?.contains(where: { $0.id == id }) == true {
                ChatConversationView(caseID: nil, encounterID: id).id(id)
            } else if let c = app.currentCase, let e = app.currentEncounter {
                ChatConversationView(caseID: c.id, encounterID: e.id).id(e.id)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 44)).foregroundStyle(.teal)
                    Text("Gemeinsam weiterdenken").font(.title2.bold())
                    Text("Stell eine Frage oder bring einen Befund mit.\nEin Fall ist dafür nicht nötig.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Schnellcheck starten") { Task { await app.newQuickCheck() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("new-quick-check")
                    if let checks = app.document.quickChecks, !checks.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Letzte Chats").font(.headline)
                                ForEach(checks) { check in
                                    Button { app.selectQuickCheck(check.id) } label: { Label(check.title, systemImage: "bubble.left").lineLimit(2) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        }.frame(maxHeight: 260)
                    }
                }.padding(24).disabled(app.busy || app.captureInProgress)
            }
        }.navigationTitle("Sparring").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChatConversationView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var deleting = false
    @FocusState private var focused: Bool
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
            return try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: preparedDraft, modelID: app.onlineConfiguration.modelID)
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if runs.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(caseID == nil ? "Schnellcheck · ohne Fall" : (app.currentCase?.label ?? "Dein Fall")).font(.caption).foregroundStyle(.secondary)
                            Text("Was möchtest du besprechen?").font(.title2.bold())
                            Text("Schreib einfach los. Über + kannst du Bilder und Befunde hinzufügen.").foregroundStyle(.secondary)
                            HStack {
                                suggestion("Befund erklären")
                                suggestion("Nächste Schritte")
                            }
                        }.padding(.vertical, 24)
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
                                    Text(run.snapshot.draft.question).textSelection(.enabled)
                                }.padding(14).background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                            }
                            if run.status.isActive && run.text.isEmpty { HStack { ProgressView(); Text("Denke nach …").foregroundStyle(.secondary) } }
                            if !run.text.isEmpty { Text(run.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
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
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .onChange(of: runs.last?.text.count) { _, _ in if sending { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
                .onChange(of: runs.last?.id) { _, id in
                    guard let run = runs.last, run.id == id, loaded else { return }
                    if run.snapshot.draft.question == preparedDraft.question, run.snapshot.draft.attachmentIDs == preparedDraft.attachmentIDs {
                        draft = .init(); save()
                    }
                    withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Neuer Chat", systemImage: "square.and.pencil") { Task { await app.newQuickCheck() } }.accessibilityIdentifier("new-quick-check")
                    Menu("Chat wechseln") {
                        ForEach(app.document.quickChecks ?? []) { check in Button(check.title) { app.selectQuickCheck(check.id) } }
                        ForEach(app.document.cases) { item in
                            ForEach(item.encounters) { value in Button("\(item.label) · \(value.date.formatted(date: .abbreviated, time: .shortened))") { app.select(item, value) } }
                        }
                    }
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
        .onAppear { if !loaded { draft = encounter?.sparringDraft ?? .init(); savedDraft = draft; loaded = true } }
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
                }.navigationTitle("Chat-Details").toolbar { Button("Schließen") { details = false } }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 8) {
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
                            }.padding(5).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
                    Button("Foto auswählen", systemImage: "photo") { focused = false; photoPicker = true }
                    Button("Datei hinzufügen", systemImage: "paperclip") { focused = false; filePicker = true }
                    if !attachments.isEmpty {
                        Menu("Vorhandene Anhänge") { ForEach(attachments) { item in Button(item.displayName) { review = item } } }
                    }
                    if let transcript = encounter?.transcripts.last {
                        Button("Falltranskript hinzufügen", systemImage: "doc.text") { draft.context = transcript.editedText; draft.transcriptVersionID = transcript.id }
                    }
                } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .accessibilityIdentifier("chat-add-attachment").disabled(app.busy || app.captureInProgress || photoLoading)
                TextField("Frag mich etwas …", text: $draft.question, axis: .vertical)
                    .lineLimit(1...6).focused($focused).accessibilityIdentifier("sparring-question")
                Button {
                    if sending { app.cancel(); return }
                    if let document = selectedAttachments.first(where: { $0.kind == .document && $0.reviewedAt == nil }) { review = document; return }
                    switch snapshot {
                    case .success(let value): save(); focused = false; app.startAnalysis(value)
                    case .failure(let error): app.error = error.localizedDescription
                    }
                } label: { Image(systemName: sending ? "stop.circle.fill" : "arrow.up.circle.fill").font(.title) }
                .accessibilityLabel(sending ? "Antwort abbrechen" : "Senden").accessibilityIdentifier("send-analysis")
                .disabled((app.busy && !sending) || app.captureInProgress || photoLoading || (!sending && draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedAttachments.isEmpty))
            }.padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            if !app.onlineConfiguration.isEnabled || !app.hasOnlineKey {
                Button("Zum Senden einmalig API-Zugang einrichten") { details = true }.font(.caption)
            }
            Text(savedDraft == draft ? "Lokal gespeichert · KI-Antworten fachlich prüfen" : "Entwurf wird gespeichert …").font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("chat-save-status")
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial)
    }
    private func suggestion(_ title: String) -> some View { Button(title) { draft.question = title + ": "; focused = true }.font(.caption).buttonStyle(.bordered) }
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
