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
}
