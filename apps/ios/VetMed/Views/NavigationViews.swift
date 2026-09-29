import SwiftUI

struct StartHome: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.accentTheme) private var theme
    @State private var editor: EncounterLocation?
    @State private var settings = false
    private var recent: [(VetCase, Encounter)] {
        Array(app.document.cases.filter { $0.archivedAt == nil }.flatMap { item in item.encounters.map { (item, $0) } }
            .sorted { $0.1.lastActivity > $1.1.lastActivity }.prefix(5))
    }
    private var openReviews: Int {
        app.document.cases.flatMap(\.encounters).filter { $0.reports.last.map { $0.approvedAt == nil } ?? false }.count
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header.appearEffect()
                stats.appearEffect(delay: 0.05)
                Button { Task { editor = await app.newEncounter() } } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "mic.fill").font(.title2.weight(.semibold)).foregroundStyle(theme.primary)
                            .frame(width: 56, height: 56).background(.white, in: Circle())
                            .symbolEffect(.pulse, options: .repeat(.periodic(delay: 2.5)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Diktat aufnehmen").font(.title3.bold())
                            Text("Behandlung dokumentieren").font(.subheadline).opacity(0.85)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.headline).accessibilityHidden(true)
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                    .background {
                        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(theme.gradient)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "waveform").font(.system(size: 90, weight: .bold)).foregroundStyle(.white.opacity(0.12))
                                    .offset(x: 10, y: -8).accessibilityHidden(true)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .shadow(color: theme.primary.opacity(0.35), radius: 16, y: 8)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier("new-dictation").disabled(app.busy || app.captureInProgress)
                .appearEffect(delay: 0.1)
                Button { Task { await app.newQuickCheck() } } label: {
                    HStack(spacing: 16) {
                        GradientIcon(systemName: "bubble.left.and.bubble.right.fill", size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Frage stellen").font(.title3.bold()).foregroundStyle(.primary)
                            Text("Mit Bildern oder Befunden · auch ohne Fall").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.headline).foregroundStyle(.tint).accessibilityHidden(true)
                    }.card(cornerRadius: 26, inset: 20)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier("start-chat").disabled(app.busy || app.captureInProgress)
                .appearEffect(delay: 0.15)
                Text("Weiterarbeiten").font(.title3.bold()).padding(.top, 10).appearEffect(delay: 0.2)
                if recent.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("Deine letzten Diktate und Berichte erscheinen hier.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).card().appearEffect(delay: 0.25)
                }
                ForEach(Array(recent.enumerated()), id: \.element.1.id) { index, entry in
                    let item = entry.0
                    let encounter = entry.1
                    let approved = encounter.reports.last?.approvedAt != nil
                    Button { editor = EncounterLocation(caseID: item.id, encounterID: encounter.id) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: approved ? "checkmark.seal.fill" : SpeciesIcon.symbol(for: item.species))
                                .font(.title3).foregroundStyle(approved ? Color.green : theme.primary)
                                .frame(width: 46, height: 46)
                                .background((approved ? Color.green : theme.primary).opacity(0.14), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.animalName.isEmpty ? item.label : item.animalName + " · " + item.label).font(.headline).foregroundStyle(.primary).lineLimit(1)
                                Text("\(item.species) · \(encounter.lastActivity.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                Text(encounter.nextAction).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(theme.primary.opacity(0.12), in: Capsule())
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }.card(inset: 14)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(app.captureInProgress).accessibilityIdentifier("recent-" + encounter.id.uuidString)
                    .appearEffect(delay: 0.25 + Double(index) * 0.05)
                    .scrollTransition(.animated) { content, phase in
                        content.opacity(phase.isIdentity ? 1 : 0.5).scaleEffect(phase.isIdentity ? 1 : 0.96)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background { AmbientBackground() }
        .navigationTitle("VetMed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { DayNightToggle() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Einstellungen", systemImage: "gearshape") { settings = true }.accessibilityIdentifier("open-settings")
                }
            }
            .navigationDestination(item: $editor) { location in EncounterEditor(location: location, recorder: app.recorder) }
            .sheet(isPresented: $settings) {
                NavigationStack { SettingsView(model: app.model).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { settings = false } } } }
            }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: Greeting.symbol()).symbolRenderingMode(.multicolor).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Greeting.text()).font(.headline)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private var stats: some View {
        HStack(spacing: 10) {
            StatTile(value: app.document.cases.count, title: "Fälle", symbol: "folder.fill") { app.activeTab = .cases }
            StatTile(value: openReviews, title: "Zu prüfen", symbol: "doc.badge.clock.fill") { app.activeTab = .cases }
            StatTile(value: (app.document.quickChecks ?? []).count, title: "Chats", symbol: "bubble.left.fill") { app.activeTab = .chat }
        }
    }
}

private struct StatTile: View {
    let value: Int
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(.tint).accessibilityHidden(true)
                Text("\(value)").font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(value)))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).card(cornerRadius: 18, inset: 12)
        }
        .buttonStyle(PressableButtonStyle())
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}

struct CasesView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.accentTheme) private var theme
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
                    HStack(spacing: 14) {
                        Image(systemName: SpeciesIcon.symbol(for: item.species)).font(.headline).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(theme.gradient, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.animalName.isEmpty ? item.label : item.animalName + " · " + item.label).font(.headline)
                            Text("\(item.species) · \(item.encounters.count) Vorgänge").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("case-row-" + item.id.uuidString)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { Button("Löschen", role: .destructive) { toDelete = item.id }.tint(.red) }
            }
        }.themedBackground()
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: cases.map(\.id))
            .navigationTitle("Fälle").searchable(text: $search, prompt: "Kennung, Tiername, Tierart")
            .disabled(app.captureInProgress)
            .alert("Fall mit allen Vorgängen, Berichten und Aufnahmen löschen?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
                Button("Behalten", role: .cancel) { toDelete = nil }
                Button("Fall endgültig löschen", role: .destructive) { if let id = toDelete { Task { await app.deleteCase(id); toDelete = nil } } }.disabled(app.busy)
            }
    }
}

struct CaseDetailView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.accentTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID
    @State private var editor: EncounterLocation?
    @State private var editingCase = false
    private var item: VetCase? { app.document.cases.first { $0.id == caseID } }
    var body: some View {
        List {
            if let item {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: SpeciesIcon.symbol(for: item.species)).font(.title).foregroundStyle(.white)
                            .frame(width: 64, height: 64).background(theme.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: theme.primary.opacity(0.3), radius: 8, y: 4)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.animalName.isEmpty ? item.label : item.animalName).font(.title3.bold())
                            Text(item.animalName.isEmpty ? item.species : item.species + " · " + item.label).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                    Button("Falldaten bearbeiten", systemImage: "pencil") { editingCase = true }
                }
                Section("Vorgänge") {
                    ForEach(item.encounters) { encounter in
                        let location = EncounterLocation(caseID: item.id, encounterID: encounter.id)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(encounter.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Button { editor = location } label: {
                                HStack {
                                    Label(encounter.nextAction, systemImage: encounter.reports.last?.approvedAt != nil ? "checkmark.seal.fill" : "doc.text").font(.headline)
                                    Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
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
        }.themedBackground().navigationTitle(item?.label ?? "Fall").disabled(app.captureInProgress)
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
            }.themedBackground().navigationTitle("Falldaten")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { if await app.updateCase(caseID, label: label, species: species, animalName: name) { dismiss() } } }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.busy || app.captureInProgress) }
                }
        }.onAppear { if let item = app.document.cases.first(where: { $0.id == caseID }) { label = item.label; species = item.species; name = item.animalName } }
    }
}
