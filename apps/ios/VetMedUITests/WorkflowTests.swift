import XCTest
final class WorkflowTests: XCTestCase {
    @MainActor
    private func switchAwayAndBack(_ app: XCUIApplication) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 10), .completed)
        app.activate()
    }
    @MainActor
    func testPhysicalExistingVaultOpensWithoutTestArguments() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Existing user vault acceptance is only performed on the physical device.")
        #else
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Fälle"].exists)
        XCTAssertTrue(app.tabBars.buttons["Chat"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        // Do not open cases, capture screenshots or export user content here.
        #endif
    }
    @MainActor
    func testPhysicalMicrophoneRolloverPauseResumeBackgroundAndReopen() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical microphone; run during device acceptance.")
        #else
        // This intentionally records the microphone into the separate encrypted UI-test vault.
        // No ASR/provider request is made; the synthetic test case is deleted after verification.
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.buttons["new-dictation"].tap()
        let caseLabel = app.navigationBars.element(boundBy: 0).identifier
        let record = app.buttons["record-audio"]
        let elapsed = app.staticTexts["recording-elapsed"]
        func seconds() -> Int {
            let components = elapsed.label.split(separator: ":").compactMap { Int($0) }
            guard components.count == 2 else { return -1 }
            return components[0] * 60 + components[1]
        }
        func waitForDuration(_ target: Int) {
            let progressed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                elapsed.exists && seconds() >= target
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [progressed], timeout: 40), .completed)
            XCTAssertEqual(record.label, "Pause", "Microphone must still run after the 20-second segment rollover")
            XCTAssertEqual(app.staticTexts["recording-status"].label, "Aufnahme läuft")
        }
        let permission = addUIInterruptionMonitor(withDescription: "Microphone access") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label IN {'Allow', 'Erlauben', 'OK'}")).firstMatch
            guard allow.exists else { return false }
            allow.tap(); return true
        }
        defer { removeUIInterruptionMonitor(permission) }
        XCTAssertTrue(record.waitForExistence(timeout: 5)); record.tap()
        // Interact with a harmless label to handle an initial permission sheet if necessary.
        app.navigationBars.element(boundBy: 0).tap()
        waitForDuration(25)
        record.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'record-audio' AND label == 'Fortsetzen' AND enabled == true")).firstMatch.waitForExistence(timeout: 8))
        record.tap(); waitForDuration(50)
        // On this device a synthesized Home press can leave the app in the foreground.
        // Activate a second app and verify the transition rather than assuming it happened.
        switchAwayAndBack(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'record-audio' AND label == 'Fortsetzen' AND enabled == true")).firstMatch.waitForExistence(timeout: 10))
        let savedSeconds = seconds()
        XCTAssertGreaterThanOrEqual(savedSeconds, 50)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", caseLabel)).firstMatch.tap()
        XCTAssertTrue(record.waitForExistence(timeout: 5)); XCTAssertEqual(record.label, "Fortsetzen")
        XCTAssertEqual(seconds(), savedSeconds, "All saved microphone segments must survive process restart")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "physical-microphone-reopened"; screenshot.lifetime = .keepAlways; add(screenshot)
        let remove = app.buttons["delete-case-bottom"]
        for _ in 0..<5 { if remove.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(remove.isHittable); remove.tap(); app.buttons["Fall endgültig löschen"].tap()
        #endif
    }
    @MainActor
    func testCaseReportContextDefaultsCanBePreviewedAndOptOutPersists() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-share-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.buttons["recent-10000000-0000-0000-0000-000000000002"].tap()
        app.buttons["chat-from-dictation"].tap()
        let reports = app.buttons["chat-reports"]
        XCTAssertTrue(reports.waitForExistence(timeout: 5)); XCTAssertTrue(reports.label.contains("1 Fallbericht"))
        reports.tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'chat-report-' ")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["Bericht ansehen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ENDE-DES-TESTBERICHTS'")).firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "case-reports-as-chat-knowledge"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["clear-chat-reports"].tap(); app.navigationBars.buttons["Fertig"].tap()
        XCTAssertTrue(reports.label.contains("Berichte als Wissen hinzufügen"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'chat-save-status' AND label BEGINSWITH 'Lokal gespeichert'")).firstMatch.waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["new-dictation"].waitForExistence(timeout: 15))
        app.buttons["recent-10000000-0000-0000-0000-000000000002"].tap(); app.buttons["chat-from-dictation"].tap()
        XCTAssertTrue(reports.waitForExistence(timeout: 5)); XCTAssertTrue(reports.label.contains("Berichte als Wissen hinzufügen"))
        reports.tap(); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'chat-report-' AND value == '1'")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["Fertig"].tap()
        XCTAssertTrue(reports.label.contains("1 Fallbericht"))
    }
    @MainActor
    func testAppearanceAndThemePersistAfterRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15)); app.buttons["open-settings"].tap()
        let mode = app.segmentedControls["appearance-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.buttons["Tag"].tap()
        app.buttons["Farbthema Ozean"].tap()
        XCTAssertTrue(app.buttons["Farbthema Ozean"].isSelected)
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "theme-settings-day"; settings.lifetime = .keepAlways; add(settings)
        app.navigationBars.buttons["Fertig"].tap()
        XCTAssertTrue(app.buttons["toggle-appearance"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["toggle-appearance"].label, "Nachtmodus")
        let day = XCTAttachment(screenshot: app.screenshot()); day.name = "theme-start-day"; day.lifetime = .keepAlways; add(day)
        app.buttons["toggle-appearance"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'toggle-appearance' AND label == 'Tagmodus'")).firstMatch.waitForExistence(timeout: 5))
        let night = XCTAttachment(screenshot: app.screenshot()); night.name = "theme-start-night"; night.lifetime = .keepAlways; add(night)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["toggle-appearance"].waitForExistence(timeout: 15)); XCTAssertEqual(app.buttons["toggle-appearance"].label, "Tagmodus")
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["Farbthema Ozean"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Farbthema Ozean"].isSelected)
        XCTAssertTrue(mode.buttons["Nacht"].isSelected)
        app.buttons["Farbthema Klinik"].tap(); mode.buttons["Automatisch"].tap()
        app.navigationBars.buttons["Fertig"].tap()
    }
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
        switchAwayAndBack(app)
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
        switchAwayAndBack(app)
        XCTAssertTrue(copy.waitForExistence(timeout: 8), app.debugDescription); copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textViews["report-editor"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["report-editor"].value as? String)?.contains("ENDE-DES-TESTBERICHTS") == true)
    }

}
