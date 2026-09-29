import SwiftUI

struct SparringHome: View {
    @EnvironmentObject private var app: VetAppModel
    var body: some View {
        Group {
            if let id = app.selectedQuickCheckID, app.document.quickChecks?.contains(where: { $0.id == id }) == true {
                SparringEditor(caseID: nil, encounterID: id).id(id)
            } else if let c = app.currentCase, let e = app.currentEncounter {
                SparringEditor(caseID: c.id, encounterID: e.id).id(e.id)
            } else {
                List {
                    Section {
                        Text("Eine kurze fachliche Frage? Starte einen Schnellcheck ohne einen Fall anzulegen.").foregroundStyle(.secondary)
                        Button("Schnellcheck starten", systemImage: "bolt.bubble") { Task { await app.newQuickCheck() } }
                            .accessibilityIdentifier("new-quick-check")
                        Button("Neuen Fall für Sparring anlegen", systemImage: "folder.badge.plus") { Task { await app.newEncounter() } }
                    }.disabled(app.busy || app.captureInProgress)
                    if let checks = app.document.quickChecks, !checks.isEmpty {
                        Section("Bisherige Schnellchecks") {
                            ForEach(checks) { check in
                                Button { app.selectQuickCheck(check.id) } label: { VStack(alignment: .leading) { Text(check.title); Text(check.createdAt.formatted()).font(.caption).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Sparring")
    }
}

private struct SparringEditor: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.scenePhase) private var scenePhase
    let caseID: UUID?
    let encounterID: UUID
    @State private var draft = SparringDraft()
    @State private var loaded = false
    @State private var savedDraft: SparringDraft?
    @State private var showingPreview = false
    @State private var deletingQuickCheck = false
    private var encounter: Encounter? { app.analysisContext(caseID: caseID, encounterID: encounterID) }
    private var snapshot: Result<SparringSnapshot, Error> {
        Result {
            guard let encounter else { throw AppFailure("Der Vorgang ist nicht mehr vorhanden.") }
            return try SparringRequestBuilder.prepare(caseID: caseID, encounter: encounter, draft: draft, modelID: app.onlineConfiguration.modelID)
        }
    }
    var body: some View {
        Form {
            Section {
                Text(caseID == nil ? "Schnellcheck · ohne Fall" : (app.document.cases.first { $0.id == caseID }?.label ?? "Fall")).font(.headline)
                Button("Neuer Schnellcheck", systemImage: "plus.bubble") { Task { await app.newQuickCheck() } }.disabled(app.busy || app.captureInProgress).accessibilityIdentifier("new-quick-check")
                if let encounter { Text(encounter.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                Menu("Gespräch auswählen") {
                    ForEach(app.document.quickChecks ?? []) { check in
                        Button("Schnellcheck · " + check.title) { app.selectQuickCheck(check.id) }
                    }
                    ForEach(app.document.cases.filter { $0.archivedAt == nil }) { c in
                        ForEach(c.encounters) { e in
                            Button("\(c.label) · \(e.date.formatted(date: .abbreviated, time: .shortened))") { app.select(c, e) }
                        }
                    }
                }.disabled(app.busy || app.captureInProgress)
            }
            Section("Deine Frage") {
                Picker("Aufgabe", selection: $draft.mode) { ForEach(SparringMode.allCases) { Text($0.title).tag($0) } }
                TextEditor(text: $draft.question).frame(minHeight: 100).accessibilityIdentifier("sparring-question")
                Text(savedDraft == draft ? "Entwurf lokal gespeichert" : "Entwurf wird lokal gespeichert …").font(.caption).foregroundStyle(.secondary)
                Button("Entwurf speichern") { save() }.accessibilityIdentifier("save-sparring-draft")
            }
            Section("Falltext für diese Anfrage") {
                TextEditor(text: $draft.context).frame(minHeight: 100).accessibilityIdentifier("sparring-context")
                if let transcript = encounter?.transcripts.last {
                    Button("Gespeichertes Transkript als bearbeitbare Kopie einsetzen") {
                        draft.context = transcript.editedText; draft.transcriptVersionID = transcript.id
                    }
                }
                Text("Nur dieser Text wird zusätzlich zur Frage verwendet. Entferne Namen und Kontaktdaten aus der Kopie. Das Original bleibt erhalten.").font(.caption).foregroundStyle(.secondary)
            }
            if let runs = encounter?.analysisRuns, !runs.isEmpty {
                Section("Gespräch in diesem Vorgang") {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(run.snapshot.draft.question).font(.headline)
                            Text(run.status.title).font(.caption).foregroundStyle(run.status == .completed ? Color.secondary : Color.orange)
                            if !run.text.isEmpty { Text(run.text).textSelection(.enabled).font(.body) }
                            if let notice = run.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                            Text("OpenAI · \(run.actualModelID ?? run.snapshot.modelID)").font(.caption).foregroundStyle(.secondary)
                            if let usage = run.usage { Text("Tokens: \(usage.inputTokens) Eingabe · \(usage.outputTokens) Ausgabe · Preis unbekannt").font(.caption).foregroundStyle(.secondary) }
                            else { Text("Tokenverbrauch und Kosten: noch unbekannt").font(.caption).foregroundStyle(.secondary) }
                            if run.status == .completed {
                                Toggle("Diese Frage und Antwort erneut mitsenden", isOn: Binding(get: { draft.historyIDs.contains(run.id) }, set: { selected in
                                    draft.historyIDs.removeAll { $0 == run.id }
                                    if selected { draft.historyIDs.append(run.id) }
                                })).font(.footnote)
                            }
                            DisclosureGroup("Tatsächlich versendete Anfrage") { PayloadView(data: run.snapshot.payload) }
                        }.padding(.vertical, 5)
                    }
                }
            }
            Section("Analyse starten") {
                Text("OpenAI · \(app.onlineConfiguration.modelID.isEmpty ? "Modell noch nicht eingerichtet" : app.onlineConfiguration.modelID)").font(.subheadline)
                Text("Webrecherche: aus · Anhänge: keine").font(.caption).foregroundStyle(.secondary)
                Button("Versandvorschau öffnen") { showingPreview = true }.accessibilityIdentifier("sparring-preview")
                Text("Senden überträgt deine Auswahl an OpenAI und kann API-Kosten verursachen. Jede Antwort ist fachlich ungeprüft. Bei Abbruch bleibt der Zwischenstand erhalten; kein automatischer Neuversand.").font(.caption).foregroundStyle(.secondary)
                Button("Analyse senden", systemImage: "arrow.up.circle.fill") {
                    switch snapshot {
                    case .success(let value):
                        let sentDraft = draft
                        Task { if await app.saveSparringDraft(sentDraft, caseID: caseID, encounterID: encounterID) { app.startAnalysis(value) } }
                    case .failure(let error): app.error = error.localizedDescription
                    }
                }.buttonStyle(.borderedProminent).disabled(app.busy || app.captureInProgress || !app.onlineConfiguration.isEnabled || !app.hasOnlineKey || draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("send-analysis")
                if !app.onlineConfiguration.isEnabled || !app.hasOnlineKey { NavigationLink("API-Key & Modell einrichten") { OnlineReportSettingsView() } }
                Text("Dieser Stand unterstützt Text und ausgewählten Verlauf. Bilder, Laborimport und Brave-Recherche werden noch ergänzt.").font(.caption).foregroundStyle(.secondary)
            }
            if caseID == nil {
                Section {
                    Button("Schnellcheck löschen", role: .destructive) { deletingQuickCheck = true }.disabled(app.busy || app.captureInProgress)
                }
            }
        }
        .confirmationDialog("Diesen Schnellcheck mit seinem Verlauf löschen?", isPresented: $deletingQuickCheck) {
            Button("Schnellcheck löschen", role: .destructive) { Task { await app.deleteQuickCheck(encounterID) } }
        }
        .onAppear { if !loaded { draft = encounter?.sparringDraft ?? .init(); savedDraft = draft; loaded = true } }
        .task(id: draft) {
            guard loaded else { return }
            let value = draft
            do {
                try await Task.sleep(for: .milliseconds(700)); try Task.checkCancellation()
                if await app.saveSparringDraft(value, caseID: caseID, encounterID: encounterID) { savedDraft = value }
            } catch { /* A newer edit replaces this pending save. */ }
        }
        .onDisappear { save() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                ScrollView {
                    switch snapshot {
                    case .success(let value):
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Empfänger: OpenAI · \(value.modelID)").font(.headline)
                            Text("Enthalten sind die Frage, der bearbeitete Falltext, \(draft.historyIDs.count) ausgewählte frühere Frage-Antwort-Paare und die folgenden Anweisungen. API-Key, Fallkennung, Tiername und Audio werden nicht automatisch ergänzt.").font(.footnote)
                            PayloadView(data: value.payload)
                        }.padding()
                    case .failure(let error): Text(error.localizedDescription).padding()
                    }
                }.navigationTitle("Versandvorschau").toolbar { Button("Schließen") { showingPreview = false } }
            }
        }
    }
    private func save() {
        guard loaded else { return }
        let value = draft
        Task { if await app.saveSparringDraft(value, caseID: caseID, encounterID: encounterID) { savedDraft = value } }
    }
}

private struct PayloadView: View {
    let data: Data
    var body: some View {
        Text(String(decoding: data, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
    }
}
