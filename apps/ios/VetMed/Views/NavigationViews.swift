import SwiftUI

struct StartHome: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var editor: EncounterLocation?
    @State private var settings = false
    private var recent: [(VetCase, Encounter)] {
        Array(app.document.cases.filter { $0.archivedAt == nil }.flatMap { item in item.encounters.map { (item, $0) } }
            .sorted { $0.1.lastActivity > $1.1.lastActivity }.prefix(5))
    }
    var body: some View {
        List {
            Section {
                Button { Task { editor = await app.newEncounter() } } label: {
                    Label { VStack(alignment: .leading, spacing: 5) { Text("Diktat aufnehmen").font(.headline); Text("Behandlung dokumentieren").font(.subheadline).foregroundStyle(.secondary) } } icon: { Image(systemName: "mic.fill").font(.title2).frame(width: 32) }
                        .padding(.vertical, 8)
                }.accessibilityIdentifier("new-dictation").disabled(app.busy || app.captureInProgress)
                Button { Task { await app.newQuickCheck() } } label: {
                    Label { VStack(alignment: .leading, spacing: 5) { Text("Frage stellen").font(.headline); Text("Mit Bildern oder Befunden · auch ohne Fall").font(.subheadline).foregroundStyle(.secondary) } } icon: { Image(systemName: "bubble.left.and.bubble.right.fill").font(.title2).frame(width: 32) }
                        .padding(.vertical, 8)
                }.accessibilityIdentifier("start-chat").disabled(app.busy || app.captureInProgress)
            }
            Section("Weiterarbeiten") {
                if recent.isEmpty { Text("Deine letzten Diktate und Berichte erscheinen hier.").foregroundStyle(.secondary) }
                ForEach(recent, id: \.1.id) { item, encounter in
                    Button { editor = EncounterLocation(caseID: item.id, encounterID: encounter.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: encounter.reports.last?.approvedAt != nil ? "checkmark.seal" : "doc.text").font(.title2).foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.animalName.isEmpty ? item.label : item.animalName + " · " + item.label).font(.headline).foregroundStyle(.primary)
                                Text("\(item.species) · \(encounter.lastActivity.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                Text(encounter.nextAction).font(.subheadline)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }.disabled(app.captureInProgress).accessibilityIdentifier("recent-" + encounter.id.uuidString)
                }
            }
        }.navigationTitle("VetMed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Einstellungen", systemImage: "gearshape") { settings = true }.accessibilityIdentifier("open-settings")
                }
            }
            .navigationDestination(item: $editor) { location in EncounterEditor(location: location, recorder: app.recorder) }
            .sheet(isPresented: $settings) {
                NavigationStack { SettingsView(model: app.model).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { settings = false } } } }
            }
    }
}

struct CasesView: View {
    @EnvironmentObject private var app: VetAppModel
    @State private var toDelete: UUID?
    @State private var search = ""
    private var cases: [VetCase] {
        app.document.cases.filter { search.isEmpty || [$0.label, $0.animalName, $0.species].contains { $0.localizedCaseInsensitiveContains(search) } }
            .sorted { ($0.encounters.map(\.lastActivity).max() ?? $0.createdAt) > ($1.encounters.map(\.lastActivity).max() ?? $1.createdAt) }
    }
    var body: some View {
        List {
            if cases.isEmpty { ContentUnavailableView(search.isEmpty ? "Noch keine Fälle" : "Kein passender Fall", systemImage: "folder", description: Text(search.isEmpty ? "Mit einem Diktat legst du einen Fall an. Spontane Fragen bleiben im Chat ohne Fall möglich." : "Suche nach Kennung, Tiername oder Tierart.")) }
            ForEach(cases) { item in
                NavigationLink { CaseDetailView(caseID: item.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.animalName.isEmpty ? item.label : item.animalName + " · " + item.label).font(.headline)
                        Text("\(item.species) · \(item.encounters.count) Vorgänge").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("case-row-" + item.id.uuidString)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("Löschen", role: .destructive) { toDelete = item.id }.tint(.red) }
            }
        }.navigationTitle("Fälle").searchable(text: $search, prompt: "Kennung, Tiername, Tierart")
            .disabled(app.captureInProgress)
            .alert("Fall mit allen Vorgängen, Berichten und Aufnahmen löschen?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
                Button("Behalten", role: .cancel) { toDelete = nil }
                Button("Fall endgültig löschen", role: .destructive) { if let id = toDelete { Task { await app.deleteCase(id); toDelete = nil } } }.disabled(app.busy)
            }
    }
}

struct CaseDetailView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID
    @State private var editor: EncounterLocation?
    @State private var editingCase = false
    private var item: VetCase? { app.document.cases.first { $0.id == caseID } }
    var body: some View {
        List {
            if let item {
                Section {
                    LabeledContent("Tierart", value: item.species)
                    if !item.animalName.isEmpty { LabeledContent("Tiername", value: item.animalName) }
                    Button("Falldaten bearbeiten", systemImage: "pencil") { editingCase = true }
                }
                Section("Vorgänge") {
                    ForEach(item.encounters) { encounter in
                        let location = EncounterLocation(caseID: item.id, encounterID: encounter.id)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(encounter.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Button { editor = location } label: {
                                HStack { Label(encounter.nextAction, systemImage: "doc.text"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                            }.accessibilityIdentifier("open-encounter-" + encounter.id.uuidString)
                            if !encounter.reports.isEmpty { Text("\(encounter.reports.count) Berichtsversionen").font(.caption).foregroundStyle(.secondary) }
                            Button("Zum Fall chatten", systemImage: "bubble.left.and.bubble.right") { app.openChat(location.chat) }
                                .accessibilityIdentifier("open-case-chat-" + encounter.id.uuidString).disabled(app.busy)
                        }.padding(.vertical, 6).buttonStyle(.borderless)
                    }
                    Button("Neues Diktat zu diesem Fall", systemImage: "plus") { Task { editor = await app.newEncounter(caseID: item.id) } }.accessibilityIdentifier("new-case-dictation").disabled(app.busy)
                }
                Section { DeleteCaseButton(caseID: item.id) { dismiss() } }
            }
        }.navigationTitle(item?.label ?? "Fall").disabled(app.captureInProgress)
            .onChange(of: item == nil) { _, deleted in if deleted { dismiss() } }
            .navigationDestination(item: $editor) { location in EncounterEditor(location: location, recorder: app.recorder) }
            .sheet(isPresented: $editingCase) { CaseEditor(caseID: caseID) }
    }
}

struct CaseEditor: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID
    @State private var label = ""
    @State private var species = ""
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Fallkennung", text: $label).accessibilityIdentifier("case-label")
                TextField("Tierart", text: $species)
                TextField("Tiername (optional)", text: $name)
            }.navigationTitle("Falldaten")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { if await app.updateCase(caseID, label: label, species: species, animalName: name) { dismiss() } } }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.busy || app.captureInProgress) }
                }
        }.onAppear { if let item = app.document.cases.first(where: { $0.id == caseID }) { label = item.label; species = item.species; name = item.animalName } }
    }
}
