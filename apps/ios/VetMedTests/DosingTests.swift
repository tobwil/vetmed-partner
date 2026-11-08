import XCTest
@testable import VetMed

/// Dose calculator, fixed warning rules and lab course (ADR 0020). Same cases as Android `DosingTests`.
@MainActor
final class DosingTests: XCTestCase {
    private func fails(_ text: String, _ block: () throws -> Void, line: UInt = #line) {
        do { try block(); XCTFail("must fail: \(text)", line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, line: line) }
    }

    func testLiquidDoseIsCalculatedAndWrittenOut() async throws {
        let result = try DoseCalculator.calculate(weight: "12,5", dose: "0,1", unit: .mgPerKg, form: .liquid, strength: "1,5")
        XCTAssertEqual(result.totalMg, 1.25, accuracy: 1e-9)
        XCTAssertEqual(result.amountText, "0,83 ml")
        XCTAssertEqual(result.steps, ["12,5 kg × 0,1 mg/kg = 1,25 mg", "1,25 mg ÷ 1,5 mg/ml = 0,83 ml"])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testMicrogramsSmallVolumesAndTablets() async throws {
        let small = try DoseCalculator.calculate(weight: "4", dose: "10", unit: .ugPerKg, form: .liquid, strength: "0,5")
        XCTAssertEqual(small.steps.first, "4 kg × 10 µg/kg = 40 µg")
        XCTAssertEqual(small.amountText, "0,08 ml")
        XCTAssertTrue(small.notes.first?.hasPrefix("Sehr kleine Menge") == true)
        let tablets = try DoseCalculator.calculate(weight: "30", dose: "4", unit: .mgPerKg, form: .tablet, strength: "50")
        XCTAssertEqual(tablets.amountText, "2,4 Tabletten")
        XCTAssertEqual(tablets.notes, ["Auf Vierteltabletten gerundet: 2 ½ Tabletten (+4 % gegenüber der berechneten Menge). Ob die Tablette teilbar ist, steht in der Fachinformation."])
        XCTAssertEqual(try DoseCalculator.calculate(weight: "10", dose: "5", unit: .mgPerKg, form: .tablet, strength: "50").amountText, "1 Tablette")
        XCTAssertTrue(try DoseCalculator.calculate(weight: "2", dose: "1", unit: .mgPerKg, form: .tablet, strength: "20").notes.first?.contains("zu stark") == true)
    }

    func testNonsenseIsRefusedAndUnitMixUpsAreFlagged() async throws {
        fails("Gewicht") { _ = try DoseCalculator.calculate(weight: "zwölf", dose: "0,1", unit: .mgPerKg, form: .liquid, strength: "1,5") }
        fails("Gewicht") { _ = try DoseCalculator.calculate(weight: "-3", dose: "0,1", unit: .mgPerKg, form: .liquid, strength: "1,5") }
        fails("1.500 kg") { _ = try DoseCalculator.calculate(weight: "2000", dose: "0,1", unit: .mgPerKg, form: .liquid, strength: "1,5") }
        fails("größer als 0") { _ = try DoseCalculator.calculate(weight: "10", dose: "0", unit: .mgPerKg, form: .liquid, strength: "1,5") }
        XCTAssertTrue(try DoseCalculator.calculate(weight: "10", dose: "200", unit: .mgPerKg, form: .liquid, strength: "100").notes.contains { $0.contains("Einheit prüfen") })
    }

    func testFixedRulesForCatsAndMdr1() async throws {
        XCTAssertEqual(DrugRules.warnings(drug: "Paracetamol 500 mg", species: "Katze", mdr1: .unknown).map(\.severity), [.stop])
        XCTAssertEqual(DrugRules.warnings(drug: "Permethrin Spot-on", species: "Kater, EKH", mdr1: .unknown).map(\.severity), [.stop])
        XCTAssertTrue(DrugRules.warnings(drug: "Paracetamol", species: "Hund", mdr1: .unknown).isEmpty)
        XCTAssertEqual(DrugRules.warnings(drug: "Ivermectin", species: "Hund", mdr1: .defect).map(\.severity), [.caution])
        XCTAssertEqual(DrugRules.warnings(drug: "Milbemycinoxim + Praziquantel", species: "Hund (Collie)", mdr1: .unknown).map(\.severity), [.info])
        XCTAssertTrue(DrugRules.warnings(drug: "Ivermectin", species: "Hund", mdr1: .normal).isEmpty)
        XCTAssertTrue(DrugRules.warnings(drug: "Ivermectin", species: "Katze", mdr1: .defect).isEmpty)
        XCTAssertEqual(DrugRules.warnings(drug: "Ibuprofen 400", species: "Hund", mdr1: .unknown).map(\.title), ["Humanes NSAID beim Hund"])
    }

    private func lab(_ id: String, _ date: String, _ confirmed: TimeInterval?, _ values: [LabValue]) -> ChatAttachment {
        var attachment = ChatAttachment(id: UUID(), kind: .document, originalName: "\(id).pdf", originalExtension: "pdf", originalByteCount: 1, originalSHA256: id,
                                        uploadSHA256: nil, uploadByteCount: nil, width: nil, height: nil, usedOCR: false)
        var report = LabReport(method: "Synthetisch")
        report.sampleDate = date; report.values = values; report.confirmedAt = confirmed.map { Date(timeIntervalSince1970: $0) }
        attachment.lab = report
        return attachment
    }
    private let caseID = UUID()
    private func document(_ attachments: [ChatAttachment]) -> VaultDocument {
        var encounter = Encounter(); encounter.chatAttachments = attachments
        var item = VetCase(label: "Synthetisch", species: "Hund"); item.id = caseID; item.encounters = [encounter]
        return VaultDocument(cases: [item])
    }
    private func value(_ parameter: String, _ value: String, _ unit: String, _ reference: String = "") -> LabValue {
        LabValue(parameter: parameter, value: value, unit: unit, reference: reference, evidence: .found)
    }

    func testNsaidsAreCheckedAgainstConfirmedKidneyValues() async throws {
        let high = document([lab("a", "01.10.2026", 1_790_000_000, [value("Kreatinin", "180", "µmol/l", "40 - 130")])])
        let warning = try XCTUnwrap(DrugRules.warnings(drug: "Meloxicam 1,5 mg/ml", species: "Hund", mdr1: .unknown, document: high, caseID: caseID).first)
        XCTAssertEqual(warning.severity, .caution)
        XCTAssertTrue(warning.text.hasPrefix("Kreatinin 180 µmol/l (Ref. 40 - 130) am 01.10.2026."), warning.text)
        let normal = document([lab("a", "01.10.2026", 1_790_000_000, [value("Kreatinin", "90", "µmol/l", "40 - 130")])])
        XCTAssertTrue(DrugRules.warnings(drug: "Carprofen", species: "Hund", mdr1: .unknown, document: normal, caseID: caseID).isEmpty)
        let ck = document([lab("a", "01.10.2026", 1_790_000_000, [value("Kreatinkinase", "900", "U/l", "10 - 200")])])
        XCTAssertEqual(DrugRules.warnings(drug: "Carprofen", species: "Hund", mdr1: .unknown, document: ck, caseID: caseID).map(\.severity), [.info])
        XCTAssertTrue(DrugRules.warnings(drug: "Carprofen", species: "Hund", mdr1: .unknown).isEmpty)
        let recovered = document([lab("a", "01.10.2026", 1_790_000_000, [value("Kreatinin", "180", "µmol/l", "40 - 130")]),
                                  lab("b", "15.10.2026", 1_790_100_000, [value("Kreatinin", "110", "µmol/l", "40 - 130")])])
        XCTAssertTrue(DrugRules.warnings(drug: "Meloxicam", species: "Hund", mdr1: .unknown, document: recovered, caseID: caseID).isEmpty)
    }

    func testLabCourseIsOrderedBySampleDate() async throws {
        let doc = document([
            lab("b", "15.10.2026", 1_790_000_000, [value("Kreatinin", "150", "µmol/l", "40 - 130"), value("CRP", "< 0,1", "mg/dl")]),
            lab("a", "01.10.2026", 1_790_100_000, [value("kreatinin", "120", "µmol/l", "40 - 130"), value("Kreatinin", "1,4", "mg/dl", "0,5 - 1,5")]),
            lab("c", "20.10.2026", nil, [value("Kreatinin", "999", "µmol/l")]),
        ])
        let series = LabTrend.series(doc, caseID: caseID)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.parameter, "Kreatinin")
        XCTAssertEqual(series.first?.points.map(\.value), [120, 150])
        XCTAssertEqual(series.first?.points.map(\.assessment), [.normal, .high])
        XCTAssertEqual(series.first?.band?.low, 40); XCTAssertEqual(series.first?.band?.high, 130)
        XCTAssertEqual(LabTrend.series(doc, caseID: caseID, minimumPoints: 1).count, 2)
        XCTAssertNotNil(LabTrend.date("Probe vom 5.1.26"))
    }
}
