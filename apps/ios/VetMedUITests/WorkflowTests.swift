import XCTest
final class WorkflowTests: XCTestCase {
    @MainActor
    func testManualTranscriptPersistsAfterRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let new = app.buttons["new-dictation"]
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "start-two-primary-actions"; home.lifetime = .keepAlways; add(home)
        new.tap()
        let recording = XCTAttachment(screenshot: app.screenshot()); recording.name = "focused-dictation-step"; recording.lifetime = .keepAlways; add(recording)
        app.buttons["enter-transcript"].tap()
        let editor = app.textViews["transcript-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        let caseLabel = app.navigationBars.element(boundBy: 0).identifier
        let text = "Synthetischer Testfall. Hund 12,5 kg. Kein Fieber."
        editor.typeText(text)
        app.buttons["save-transcript"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(new.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Text prüfen"].firstMatch.waitForExistence(timeout: 10))
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", caseLabel)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertEqual(editor.value as? String, text)
    }
    @MainActor
    func testTypingAutosavesWithoutExplicitSave() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let new = app.buttons["new-dictation"]
        XCTAssertTrue(new.waitForExistence(timeout: 15)); new.tap()
        app.buttons["enter-transcript"].tap()
        let editor = app.textViews["transcript-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        let caseLabel = app.navigationBars.element(boundBy: 0).identifier
        let text = "Synthetischer Autosave. Temperatur nicht gemessen."
        editor.typeText(text)
        XCTAssertTrue(app.staticTexts["Text gespeichert"].waitForExistence(timeout: 8))
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
        app.tabBars.buttons["Chat"].tap()
        let new = app.buttons["new-quick-check"]
        XCTAssertTrue(new.waitForExistence(timeout: 5)); new.tap()
        XCTAssertTrue(app.staticTexts["chat-scope"].waitForExistence(timeout: 5)); XCTAssertEqual(app.staticTexts["chat-scope"].label, "Ohne Fall")
        let question = app.descendants(matching: .any).matching(identifier: "sparring-question").firstMatch
        let text = "Schnellcheck QA " + UUID().uuidString.prefix(8)
        question.tap(); question.typeText(text)
        let savedStatus = app.staticTexts.matching(NSPredicate(format: "identifier == 'chat-save-status' AND label BEGINSWITH 'Lokal gespeichert'")).firstMatch
        XCTAssertTrue(savedStatus.waitForExistence(timeout: 8))
        app.buttons["chat-add-attachment"].tap()
        XCTAssertTrue(app.buttons["Foto auswählen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Datei hinzufügen"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Fälle"].tap(); XCTAssertEqual(rows.count, before)
        app.tabBars.buttons["Chat"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5)); XCTAssertEqual(question.value as? String, text)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "normal-chat-composer"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor
    func testChatCanAttachPhotoWithoutSendingAndRemoveItFromDraft() throws {
        // The test script seeds one synthetic screenshot into the simulator photo library.
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Chat"].tap()
        let new = app.buttons["new-quick-check"]
        XCTAssertTrue(new.waitForExistence(timeout: 5)); new.tap()
        app.buttons["chat-add-attachment"].tap()
        app.buttons["Foto auswählen"].tap()
        let photo = app.images.matching(NSPredicate(format: "identifier == 'PXGGridLayout-Info' AND label CONTAINS 'Screenshot'")).firstMatch
        guard photo.waitForExistence(timeout: 8) else { XCTFail("Synthetic screenshot missing from PhotosPicker: " + app.debugDescription); return }
        photo.tap()
        let remove = app.buttons["Anhang entfernen"]
        guard remove.waitForExistence(timeout: 15) else { XCTFail("Photo was not attached: " + app.debugDescription); return }
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "chat-with-image-attachment"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertFalse(app.buttons["Antwort abbrechen"].exists)
        remove.tap(); XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }
    @MainActor
    func testCaseDeletionUsesRightToLeftSwipeAndExplicitConfirmation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15)); app.buttons["new-dictation"].tap()
        XCTAssertTrue(app.buttons["record-audio"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["record-audio"].waitForExistence(timeout: 5))
        let label = app.navigationBars.element(boundBy: 0).identifier
        app.tabBars.buttons["Fälle"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'case-row-' AND label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); let identifier = row.identifier; row.tap()
        let remove = app.buttons["delete-case-bottom"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(remove.frame.minY, app.buttons["new-case-dictation"].frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "case-delete-bottom"; screenshot.lifetime = .keepAlways; add(screenshot)
        remove.tap()
        let cancel = app.buttons["Behalten"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[label].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-encounter-'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["record-audio"].waitForExistence(timeout: 5))
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

    @MainActor
    func testEditorsRetainTheirCaseAcrossTabsAndIndependentChat() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15)); app.buttons["new-dictation"].tap()
        let labelA = app.navigationBars.element(boundBy: 0).identifier
        app.buttons["enter-transcript"].tap()
        let editor = app.textViews["transcript-editor"]
        editor.tap(); editor.typeText("Fall A original")
        XCTAssertTrue(app.staticTexts["Text gespeichert"].waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["new-dictation"].tap()
        let labelB = app.navigationBars.element(boundBy: 0).identifier
        XCTAssertNotEqual(labelA, labelB)
        app.buttons["enter-transcript"].tap(); editor.tap(); editor.typeText("Fall B original")
        XCTAssertTrue(app.staticTexts["Text gespeichert"].waitForExistence(timeout: 8))
        app.buttons["Fertig"].tap()
        app.tabBars.buttons["Fälle"].tap()
        let rowA = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'case-row-' AND label BEGINSWITH %@", labelA)).firstMatch
        XCTAssertTrue(rowA.waitForExistence(timeout: 5)); rowA.tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-encounter-' ")).firstMatch.tap()
        XCTAssertEqual(editor.value as? String, "Fall A original")
        app.tabBars.buttons["Chat"].tap(); app.buttons["new-quick-check"].tap()
        XCTAssertEqual(app.staticTexts["chat-scope"].label, "Ohne Fall")
        app.tabBars.buttons["Start"].tap()
        XCTAssertTrue(app.navigationBars[labelB].exists); XCTAssertEqual(editor.value as? String, "Fall B original")
        app.tabBars.buttons["Fälle"].tap()
        XCTAssertTrue(app.navigationBars[labelA].exists); XCTAssertEqual(editor.value as? String, "Fall A original")
        app.buttons["chat-from-dictation"].tap()
        XCTAssertEqual(app.staticTexts["chat-scope"].label, labelA)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "chat-persistent-case-context"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor
    func testMarkdownAnswerAndSharingSurviveAppSwitch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-share-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.buttons["recent-10000000-0000-0000-0000-000000000002"].tap()
        app.buttons["chat-from-dictation"].tap()
        XCTAssertEqual(app.staticTexts["chat-scope"].label, "UI-Prüffall")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Fett dargestellt' AND NOT label CONTAINS '**'")).firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "formatted-chat-answer"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["share-answer-10000000-0000-0000-0000-000000000003"].tap()
        let copy = app.cells.matching(NSPredicate(format: "identifier == 'actionGroupCell' AND label IN {'Copy', 'Kopieren'}")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8), app.debugDescription)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(copy.waitForExistence(timeout: 8), app.debugDescription)
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chat-scope"].waitForExistence(timeout: 5)); XCTAssertEqual(app.staticTexts["chat-scope"].label, "UI-Prüffall")
    }
    @MainActor
    func testReportShareSheetRetainsTextAndReportAfterAppSwitch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-share-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.buttons["recent-10000000-0000-0000-0000-000000000002"].tap()
        app.buttons["Bericht prüfen"].tap()
        app.buttons["share-report-menu"].tap(); app.buttons["share-report-text"].tap()
        let copy = app.cells.matching(NSPredicate(format: "identifier == 'actionGroupCell' AND label IN {'Copy', 'Kopieren'}")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8), app.debugDescription)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "system-share-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "report-text-share-sheet"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(copy.waitForExistence(timeout: 8), app.debugDescription); copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textViews["report-editor"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["report-editor"].value as? String)?.contains("ENDE-DES-TESTBERICHTS") == true)
    }

}
