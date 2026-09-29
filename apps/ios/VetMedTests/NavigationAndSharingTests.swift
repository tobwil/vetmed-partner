import XCTest
import CryptoKit
import UIKit
import UniformTypeIdentifiers
@testable import VetMed

@MainActor
final class NavigationAndSharingTests: XCTestCase {
    func testDelayedEditAndReportActionsKeepOriginalCaseAfterChatSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CaseRepository(root: root, key: SymmetricKey(size: .bits256))
        let a = try UITestFixtures.sharing(), b = VetCase(label: "Anderer Fall", species: "Hund", encounters: [.init()])
        let check = QuickCheck(draft: .init(question: "Unabhängig"))
        let document = VaultDocument(cases: [a, b], quickChecks: [check]); try await repository.save(document)
        let model = VetAppModel(testRepository: repository, document: document)
        let original = EncounterLocation(caseID: a.id, encounterID: a.encounters[0].id)
        model.openChat(.init(caseID: nil, encounterID: check.id))
        let saved = await model.saveTranscript("Nur in Fall A geändert", at: original); XCTAssertTrue(saved)
        let report = a.encounters[0].reports[0]
        model.openChat(.init(caseID: b.id, encounterID: b.encounters[0].id))
        await model.approve(report.id, at: original)
        await model.recordShare(report.id, format: "Text", at: original)
        let reopened = try await repository.load()
        XCTAssertEqual(reopened.cases[0].encounters[0].transcripts.last?.editedText, "Nur in Fall A geändert")
        XCTAssertNotNil(reopened.cases[0].encounters[0].reports[0].approvedAt)
        XCTAssertEqual(reopened.cases[0].encounters[0].shares.first?.reportID, report.id)
        XCTAssertEqual(reopened.cases[1], b); XCTAssertEqual(reopened.quickChecks, [check])
        let foreign = await model.saveReportEdit("Falsch", report: report, at: .init(caseID: b.id, encounterID: b.encounters[0].id))
        XCTAssertFalse(foreign)
    }
    func testDeletingCaseDoesNotAllowPendingEditorToRecreateIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CaseRepository(root: root, key: SymmetricKey(size: .bits256)), item = try UITestFixtures.sharing()
        let document = VaultDocument(cases: [item]); try await repository.save(document)
        let app = VetAppModel(testRepository: repository, document: document)
        let location = EncounterLocation(caseID: item.id, encounterID: item.encounters[0].id)
        app.openChat(location.chat); await app.deleteCase(item.id)
        XCTAssertTrue(app.chatPath.isEmpty)
        let saved = await app.saveTranscript("Später Entwurf", at: location); XCTAssertFalse(saved)
        await app.recordShare(item.encounters[0].reports[0].id, format: "Text", at: location)
        let loaded = try await repository.load(); XCTAssertTrue(loaded.cases.isEmpty)
    }
    func testBoldItalicHeadingsListsAndCodeHaveNativeRepresentation() {
        let blocks = ChatMarkdown.blocks(UITestFixtures.markdown + "\n\n```\n**wörtlich**\n```")
        XCTAssertEqual(blocks[0].kind, .heading(2))
        XCTAssertTrue(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(blocks[1].text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertEqual(blocks[2].kind, .list("•", 0))
        XCTAssertEqual(String(blocks[2].text.characters), "Hund 12,5 kg")
        XCTAssertEqual(blocks.last?.kind, .code)
        XCTAssertEqual(blocks.last.map { String($0.text.characters) }, "**wörtlich**")
    }
    func testPlainTextPreservesNumbersNegationsURLsAndLiteralAsterisks() {
        let value = ChatMarkdown.plainText("**Kein** Fieber. 12,5 kg.\n\n[Quelle](https://example.org/paper)\n\n\\*wörtlich\\*\n\n1. Wert < 7,0 mmol/l")
        XCTAssertTrue(value.contains("Kein Fieber. 12,5 kg.")); XCTAssertFalse(value.contains("**Kein**"))
        XCTAssertTrue(value.contains("Quelle (https://example.org/paper)"))
        XCTAssertTrue(value.contains("*wörtlich*")); XCTAssertTrue(value.contains("1. Wert < 7,0 mmol/l"))
        let unsafe = ChatMarkdown.inline("[Nicht öffnen](file:///private/test)")
        XCTAssertFalse(unsafe.runs.contains { $0.link != nil })
    }
    func testClipboardAdvertisesPlainTextForOtherApps() {
        let text = "Synthetischer Text. Kein Fieber. 12,5 kg.\nENDE"
        ExportService.copyText(text)
        XCTAssertTrue(UIPasteboard.general.hasStrings)
        XCTAssertTrue(UIPasteboard.general.types.contains(UTType.utf8PlainText.identifier))
        XCTAssertEqual(UIPasteboard.general.string, text)
    }
    func testWhatsAppActivityReceivesCompleteFrozenTextRatherThanAnAttachment() {
        let text = String(repeating: "Synthetischer Test. 12,5 kg. Kein Fieber.\n", count: 100) + "ENDE"
        let source = SharedTextItem(text), controller = UIActivityViewController(activityItems: ["test"], applicationActivities: nil)
        for activity in [nil, UIActivity.ActivityType.copyToPasteboard, UIActivity.ActivityType("net.whatsapp.WhatsApp.ShareExtension")] {
            XCTAssertEqual(source.activityViewController(controller, itemForActivityType: activity) as? String, text)
            XCTAssertEqual(source.activityViewController(controller, dataTypeIdentifierForActivityType: activity), UTType.utf8PlainText.identifier)
        }
        XCTAssertEqual(source.activityViewControllerPlaceholderItem(controller) as? String, text)
    }
    func testRecentExportSurvivesForegroundCleanupButExpiredFileDoesNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recent = root.appendingPathComponent("recent.pdf"), old = root.appendingPathComponent("old.pdf"), now = Date()
        try Data("PDF snapshot".utf8).write(to: recent); try Data("Expired".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_401)], ofItemAtPath: old.path)
        try ExportService.cleanExpiredFiles(in: root, now: now)
        XCTAssertEqual(try Data(contentsOf: recent), Data("PDF snapshot".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
    func testPartialAnswerKeepsWarningWhenCopiedWithoutMarkdown() throws {
        var run = try XCTUnwrap(UITestFixtures.sharing().encounters[0].analysisRuns?.first)
        run.status = .cancelled
        let text = ChatMarkdown.export(run)
        XCTAssertTrue(text.contains("UNVOLLSTÄNDIGE")); XCTAssertTrue(text.contains("fachlich ungeprüft"))
        XCTAssertFalse(text.contains("**Fett")); XCTAssertTrue(text.hasSuffix("ENDE-DER-TESTANTWORT"))
    }
}
