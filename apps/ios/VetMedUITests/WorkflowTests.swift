import XCTest
final class WorkflowTests: XCTestCase {
    @MainActor
    func testManualTranscriptPersistsAfterRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let new = app.buttons["new-dictation"]
        XCTAssertTrue(new.waitForExistence(timeout: 15)); new.tap()
        let editor = app.textViews["transcript-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        let caseLabel = app.navigationBars.element(boundBy: 0).identifier
        let text = "Synthetischer Testfall. Hund 12,5 kg. Kein Fieber."
        editor.typeText(text)
        app.buttons["save-transcript"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Transkript bereit"].firstMatch.waitForExistence(timeout: 10))
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", caseLabel)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertEqual(editor.value as? String, text)
    }
    @MainActor
    func testTypingAutosavesWithoutExplicitSave() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let new = app.buttons["new-dictation"]
        XCTAssertTrue(new.waitForExistence(timeout: 15)); new.tap()
        let editor = app.textViews["transcript-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        let caseLabel = app.navigationBars.element(boundBy: 0).identifier
        let text = "Synthetischer Autosave. Temperatur nicht gemessen."
        editor.typeText(text)
        XCTAssertTrue(app.staticTexts["Transkript bereit"].waitForExistence(timeout: 8))
        XCTAssertEqual(editor.value as? String, text)
        app.terminate(); app.launch()
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", caseLabel)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertEqual(editor.value as? String, text)
    }
    @MainActor
    func testQuickCheckDraftReopensWithoutCreatingClinicalCase() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Fälle"].tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'case-row-'"))
        let before = rows.count
        app.tabBars.buttons["Sparring"].tap()
        let new = app.buttons["new-quick-check"]
        XCTAssertTrue(new.waitForExistence(timeout: 5)); new.tap()
        XCTAssertTrue(app.staticTexts["Schnellcheck · ohne Fall"].waitForExistence(timeout: 5))
        let question = app.textViews["sparring-question"]
        let text = "Schnellcheck QA " + UUID().uuidString.prefix(8)
        question.tap(); question.typeText(text)
        app.buttons["save-sparring-draft"].tap()
        XCTAssertTrue(app.staticTexts["Entwurf lokal gespeichert"].waitForExistence(timeout: 8))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Fälle"].tap(); XCTAssertEqual(rows.count, before)
        app.tabBars.buttons["Sparring"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5)); XCTAssertEqual(question.value as? String, text)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "standalone-quick-check"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor
    func testCaseDeletionUsesRightToLeftSwipeAndExplicitConfirmation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15)); app.buttons["new-dictation"].tap()
        XCTAssertTrue(app.textViews["transcript-editor"].waitForExistence(timeout: 5))
        let label = app.navigationBars.element(boundBy: 0).identifier
        app.tabBars.buttons["Fälle"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'case-row-' AND label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let identifier = row.identifier
        row.swipeLeft()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "case-swipe-right-to-left"; screenshot.lifetime = .keepAlways; add(screenshot)
        let delete = app.buttons["Löschen"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        let confirm = app.buttons["Fall endgültig löschen"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[identifier].exists)
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForNonExistence(timeout: 8))
    }
    @MainActor
    func testCaseDeletionAtBottomCanCancelThenDeleteNestedEncounter() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15)); app.buttons["new-dictation"].tap()
        XCTAssertTrue(app.textViews["transcript-editor"].waitForExistence(timeout: 5))
        let label = app.navigationBars.element(boundBy: 0).identifier
        app.tabBars.buttons["Fälle"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'case-row-' AND label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); let identifier = row.identifier; row.tap()
        let remove = app.buttons["delete-case-bottom"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(remove.frame.minY, app.buttons["Neuen Vorgang anlegen"].frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "case-delete-bottom"; screenshot.lifetime = .keepAlways; add(screenshot)
        remove.tap()
        let cancel = app.buttons["Behalten"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[label].exists)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Entwurf'")).firstMatch.tap()
        XCTAssertTrue(app.textViews["transcript-editor"].waitForExistence(timeout: 5))
        for _ in 0..<5 { if remove.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        app.buttons["Fall endgültig löschen"].tap()
        XCTAssertTrue(app.navigationBars["Fälle"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)[identifier].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Fälle"].tap()
        XCTAssertFalse(app.descendants(matching: .any)[identifier].exists)
    }

}
