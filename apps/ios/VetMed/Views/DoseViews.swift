import SwiftUI
import Charts

/// Dose calculator with fixed warning rules (ADR 0020), same as Android's `DoseScreen`. Every number comes from the
/// user; the app only calculates and checks a short list of known dangers.
struct DoseView: View {
    @EnvironmentObject private var app: VetAppModel
    let caseID: UUID?
    @State private var drug = ""
    @State private var species = ""
    @State private var weight = ""
    @State private var dose = ""
    @State private var strength = ""
    @State private var unit: DoseCalculator.DoseUnit = .mgPerKg
    @State private var form: DoseCalculator.Form = .liquid
    @State private var mdr1: DrugRules.Mdr1 = .unknown
    private var item: VetCase? { app.document.cases.first { $0.id == caseID } }

    var body: some View {
        Form {
            Section {
                if let item { Text("Fall: " + (item.animalName.isEmpty ? item.label : item.animalName + " · " + item.label)).font(.caption).foregroundStyle(.secondary) }
                TextField("Wirkstoff", text: $drug).accessibilityIdentifier("dose-drug")
                TextField("Tierart", text: $species).accessibilityIdentifier("dose-species")
                if DrugRules.species(species) == .dog {
                    Picker("MDR1-Status", selection: $mdr1) { ForEach(DrugRules.Mdr1.allCases) { Text($0.rawValue).tag($0) } }
                }
                TextField("Gewicht in kg", text: $weight).keyboardType(.decimalPad).accessibilityIdentifier("dose-weight")
                HStack {
                    TextField("Dosis", text: $dose).keyboardType(.decimalPad).accessibilityIdentifier("dose-per-kg")
                    Picker("Einheit", selection: $unit) { ForEach(DoseCalculator.DoseUnit.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 140)
                }
                Picker("Darreichung", selection: $form) { ForEach(DoseCalculator.Form.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                TextField("Stärke in \(form.strengthUnit)", text: $strength).keyboardType(.decimalPad).accessibilityIdentifier("dose-strength")
            } footer: { Text("Dosis und Stärke bitte aus der Fachinformation übernehmen. Die App schlägt keine Dosis vor und prüft nicht, ob sie stimmt.") }
            if !weight.isEmpty, !dose.isEmpty, !strength.isEmpty {
                Section("Ergebnis") {
                    switch Result(catching: { try DoseCalculator.calculate(weight: weight, dose: dose, unit: unit, form: form, strength: strength) }) {
                    case let .success(result):
                        Text(result.amountText).font(.largeTitle.bold()).foregroundStyle(.tint).accessibilityIdentifier("dose-amount")
                        ForEach(result.steps, id: \.self) { Text($0).font(.subheadline) }
                        ForEach(result.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    case let .failure(error):
                        Text(error.localizedDescription).foregroundStyle(.red).accessibilityIdentifier("dose-error")
                    }
                }
            }
            let warnings = DrugRules.warnings(drug: drug, species: species, mdr1: mdr1, document: app.document, caseID: caseID)
            if !warnings.isEmpty {
                Section {
                    ForEach(warnings) { warning in
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(warning.severity.label): \(warning.title)").font(.subheadline.weight(.semibold)).foregroundStyle(color(warning.severity))
                                Text(warning.text).font(.subheadline)
                            }
                        } icon: { Image(systemName: icon(warning.severity)).foregroundStyle(color(warning.severity)) }
                            .accessibilityIdentifier("dose-warning-\(warning.severity)")
                    }
                } footer: { Text(DrugRules.disclaimer) }
            }
        }
        .themedBackground().navigationTitle("Dosis berechnen").navigationBarTitleDisplayMode(.inline)
        .onAppear { if species.isEmpty { species = item?.species ?? "" } }
    }

    private func color(_ severity: DrugRules.Severity) -> Color { switch severity { case .stop: .red; case .caution: .orange; case .info: .accentColor } }
    private func icon(_ severity: DrugRules.Severity) -> String { switch severity { case .stop: "nosign"; case .caution: "exclamationmark.triangle.fill"; case .info: "info.circle" } }
}

/// Confirmed lab values of a case over time, one chart per parameter with the printed range shaded (ADR 0020).
struct LabTrendView: View {
    @EnvironmentObject private var app: VetAppModel
    let caseID: UUID

    var body: some View {
        let series = LabTrend.series(app.document, caseID: caseID)
        List {
            Section {
                Text("Nur am Original bestätigte Werte mit Zahl, je Parameter und Einheit. Grün hinterlegt: Referenzbereich des Labors vom neuesten Befund. Bewertung durch die App.")
                    .font(.caption).foregroundStyle(.secondary)
                if series.isEmpty { Text("Für einen Verlauf braucht es mindestens zwei bestätigte Befunde mit demselben Parameter.") }
            }
            ForEach(series) { line in
                Section(line.unit.isEmpty ? line.parameter : "\(line.parameter) (\(line.unit))") {
                    Chart {
                        if let band = line.band, let low = band.low, let high = band.high {
                            RectangleMark(xStart: .value("Beginn", line.points.first!.date), xEnd: .value("Ende", line.points.last!.date), yStart: .value("Unten", low), yEnd: .value("Oben", high))
                                .foregroundStyle(.green.opacity(0.15))
                        }
                        ForEach(line.points) { point in
                            LineMark(x: .value("Datum", point.date), y: .value(line.parameter, point.value))
                            PointMark(x: .value("Datum", point.date), y: .value(line.parameter, point.value))
                                .foregroundStyle(point.assessment == .high || point.assessment == .low ? Color.red : Color.accentColor)
                        }
                    }
                    .frame(height: 160)
                    .accessibilityLabel("Verlauf \(line.parameter): " + line.points.map { "\($0.label) \($0.raw)" }.joined(separator: ", "))
                    ForEach(line.points) { point in
                        HStack {
                            Text(point.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(point.raw) \(point.assessment.symbol)".trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(point.assessment == .high || point.assessment == .low ? Color.red : Color.primary)
                            Text(point.reference.isEmpty ? "Ref. –" : "Ref. \(point.reference)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .themedBackground().navigationTitle("Laborverlauf").navigationBarTitleDisplayMode(.inline)
    }
}
