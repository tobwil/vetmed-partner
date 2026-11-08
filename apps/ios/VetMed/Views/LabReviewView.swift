import SwiftUI

/// Lab result review (ADR 0015), same flow as Android's `LabReviewSheet`: the page next to the table, every row
/// editable, rows that could not be found in the original marked red. Only "bestätigen" makes it usable in the chat.
struct LabReviewView: View {
    @EnvironmentObject private var app: VetAppModel
    @Environment(\.dismiss) private var dismiss
    let caseID: UUID?
    let encounterID: UUID
    let attachmentID: UUID
    let autoRead: Bool
    var asText: () -> Void
    var use: (UUID) -> Void
    @State private var pages: [UIImage]?
    @State private var page = 0
    @State private var values: [LabValue] = []
    @State private var editing: UUID?
    @State private var adding: LabValue?
    @State private var started = false
    @State private var zoom: CGFloat = 1
    private var attachment: ChatAttachment? { app.analysisContext(caseID: caseID, encounterID: encounterID)?.chatAttachments?.first { $0.id == attachmentID } }
    private var stored: LabReport? { attachment?.lab }
    private var history: [String: [LabHistory.Entry]] { LabHistory.previous(cases: app.document.cases, caseID: caseID, excluding: attachmentID) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let pages, !pages.isEmpty {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: pages[min(page, pages.count - 1)]).resizable().scaledToFit()
                                .frame(width: 340 * zoom).accessibilityLabel("Befundseite \(page + 1)")
                        }.frame(height: 360).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 14))
                            .gesture(MagnifyGesture().onChanged { zoom = min(5, max(1, $0.magnification)) })
                        if pages.count > 1 {
                            Stepper("Seite \(page + 1) von \(pages.count)", value: $page, in: 0...(pages.count - 1))
                        }
                        Text("Mit zwei Fingern zoomen.").font(.caption2).foregroundStyle(.secondary)
                    } else if pages == nil { Text("Befundseiten werden geladen …").font(.footnote).foregroundStyle(.secondary) }
                }
                if let stored {
                    let open = values.filter(\.needsCheck).count
                    Section {
                        Text([stored.laboratory, stored.sampleDate.isEmpty ? "" : "Probe vom " + stored.sampleDate, stored.method].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(open == 0 ? "\(values.count) Werte. Bitte jede Zeile am Original vergleichen."
                             : "\(values.count) Werte, davon \(open) rot oder orange markiert: bitte besonders genau am Original prüfen.")
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("lab-summary")
                        Text("Referenz und Kennzeichnung stammen vom Labor. Die Bewertung berechnet die App nur aus dem gedruckten Referenzbereich.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Werte") {
                        ForEach(values) { value in
                            if editing == value.id {
                                LabValueEditor(value: value, onCancel: { editing = nil }, onDelete: { values.removeAll { $0.id == value.id }; editing = nil }) { save($0) }
                            } else {
                                Button { if editing == nil && adding == nil { editing = value.id } } label: {
                                    LabRowView(value: value, earlier: history[LabHistory.key(parameter: value.parameter, unit: value.unit)] ?? [])
                                }.buttonStyle(.plain).accessibilityIdentifier("lab-row-\(value.parameter)")
                            }
                        }
                        if let adding {
                            LabValueEditor(value: adding, onCancel: { self.adding = nil }, onDelete: nil) { save($0) }
                        } else if editing == nil {
                            Button("Zeile hinzufügen", systemImage: "plus") { adding = LabValue(parameter: "", value: "", evidence: .edited) }.accessibilityIdentifier("lab-add-row")
                        }
                    }
                    Section {
                        Button("Tabelle am Original geprüft · bestätigen") {
                            var report = stored; report.values = values
                            Task { if await app.confirmLab(caseID: caseID, encounterID: encounterID, id: attachmentID, report: report) { use(attachmentID); dismiss() } }
                        }.buttonStyle(.borderedProminent).disabled(app.busy || values.isEmpty || editing != nil || adding != nil).accessibilityIdentifier("lab-confirm")
                        Button("Neu lesen") { app.readLab(caseID: caseID, encounterID: encounterID, id: attachmentID) }.disabled(app.busy)
                    }
                } else {
                    Section {
                        Text(app.busy ? (app.workStatus.isEmpty ? "Wird gelesen …" : app.workStatus) : "Die Werte sind noch nicht gelesen.")
                        if !app.busy {
                            if app.labRoute == .online {
                                Button("Werte online lesen (beste Qualität)") { app.readLab(caseID: caseID, encounterID: encounterID, id: attachmentID, route: .online) }
                                    .buttonStyle(.borderedProminent).accessibilityIdentifier("lab-read-online")
                            }
                            Button("Auf dem Gerät lesen (jede Zeile prüfen)") { app.readLab(caseID: caseID, encounterID: encounterID, id: attachmentID, route: .device) }
                                .accessibilityIdentifier("lab-read-device")
                            Text("Online gehen nur die Seitenbilder an deinen Anbieter. Namen von Tier und Halter auf dem Befund vorher abdecken, wenn sie nicht gesendet werden sollen.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section { Button("Stattdessen als Text prüfen") { asText() }.disabled(app.busy) }
            }
            .themedBackground().navigationTitle("Laborbefund prüfen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .task {
                do { pages = try await app.labPages(caseID: caseID, encounterID: encounterID, id: attachmentID).compactMap(UIImage.init(data:)) }
                catch { pages = [] }
            }
            .onAppear { values = stored?.values ?? [] }
            .onChange(of: stored?.readAt) { _, _ in values = stored?.values ?? []; editing = nil; adding = nil }
            // A freshly added result is read right away along the default route; nothing is read twice.
            .task(id: app.busy) { if autoRead, stored == nil, !app.busy, !started { started = true; app.readLab(caseID: caseID, encounterID: encounterID, id: attachmentID) } }
            .onChange(of: attachment == nil) { _, missing in if missing { dismiss() } }
        }
    }

    private func save(_ changed: LabValue) {
        var edited = changed; edited.evidence = .edited; edited.uncertain = false
        if let index = values.firstIndex(where: { $0.id == changed.id }) { values[index] = edited } else { values.append(edited) }
        editing = nil; adding = nil
    }
}

private struct LabRowView: View {
    let value: LabValue
    let earlier: [LabHistory.Entry]
    var body: some View {
        let mark: Color? = value.evidence == .notFound ? .red : (value.uncertain || value.flagConflict || value.evidence == .local || value.evidence == .unchecked ? .orange : nil)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(value.parameter.isEmpty ? "–" : value.parameter).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(value.value) \(value.unit)".trimmingCharacters(in: .whitespaces)).font(.subheadline.weight(.semibold))
                    .foregroundStyle(value.assessment == .low || value.assessment == .high ? Color.red : Color.primary)
            }
            HStack(spacing: 10) {
                Text("Ref. " + (value.reference.isEmpty ? "keine" : value.reference))
                if !value.flag.isEmpty { Text("Labor: " + value.flag) }
                Text("App: " + value.assessment.text).foregroundStyle(.tint)
                Text("S. \(value.page)")
            }.font(.caption2).foregroundStyle(.secondary)
            Group {
                switch true {
                case value.evidence == .notFound: Text("Nicht im Original gefunden. Bitte am Befund prüfen.").foregroundStyle(.red)
                case value.flagConflict: Text("Kennzeichnung des Labors passt nicht zum Wert. Bitte Wert und Referenz am Befund prüfen.").foregroundStyle(.orange)
                case value.evidence == .local: Text("Auf dem Gerät gelesen. Bitte am Befund prüfen.").foregroundStyle(.orange)
                case value.uncertain: Text("Als schwer lesbar markiert. Bitte am Befund prüfen.").foregroundStyle(.orange)
                case value.evidence == .unchecked: Text("Kein lokaler Text zum Abgleich. Bitte am Befund prüfen.").foregroundStyle(.orange)
                case value.evidence == .edited: Text("Von dir eingetragen").foregroundStyle(.secondary)
                default: EmptyView()
                }
            }.font(.caption2)
            if !earlier.isEmpty {
                Text("Vorher: " + earlier.prefix(3).map { "\($0.value.value) (\($0.date))" }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background((mark ?? .clear).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// Inline editor in place of a row. Saving requires "am Original verglichen".
private struct LabValueEditor: View {
    let value: LabValue
    var onCancel: () -> Void
    var onDelete: (() -> Void)?
    var onSave: (LabValue) -> Void
    @State private var parameter = ""
    @State private var number = ""
    @State private var unit = ""
    @State private var reference = ""
    @State private var flag = ""
    @State private var checked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.parameter.isEmpty ? "Zeile hinzufügen" : "Zeile bearbeiten").font(.subheadline.weight(.semibold))
            TextField("Parameter", text: $parameter)
            HStack { TextField("Wert", text: $number).accessibilityIdentifier("lab-edit-value"); TextField("Einheit", text: $unit) }
            HStack { TextField("Referenz wie gedruckt", text: $reference); TextField("Kennz. Labor", text: $flag) }
            Toggle("Am Original verglichen", isOn: $checked).accessibilityIdentifier("lab-edit-checked")
            HStack {
                if let onDelete { Button("Löschen", role: .destructive, action: onDelete).buttonStyle(.borderless) }
                Spacer()
                Button("Abbrechen", action: onCancel).buttonStyle(.borderless)
                Button("Übernehmen") {
                    var changed = value
                    changed.parameter = parameter.trimmingCharacters(in: .whitespaces); changed.value = number.trimmingCharacters(in: .whitespaces)
                    changed.unit = unit.trimmingCharacters(in: .whitespaces); changed.reference = reference.trimmingCharacters(in: .whitespaces)
                    changed.flag = flag.trimmingCharacters(in: .whitespaces)
                    onSave(changed)
                }.buttonStyle(.borderless).accessibilityIdentifier("lab-edit-save")
                    .disabled(!checked || parameter.trimmingCharacters(in: .whitespaces).isEmpty || number.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
        .onAppear { parameter = value.parameter; number = value.value; unit = value.unit; reference = value.reference; flag = value.flag }
    }
}
