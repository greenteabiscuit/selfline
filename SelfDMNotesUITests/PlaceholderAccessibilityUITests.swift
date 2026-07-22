import AppKit
import XCTest

@MainActor
final class NoteTimelineUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testLibraryIdentifier: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testLibraryIdentifier = "SelfDMNotesUITests-\(UUID().uuidString)"
        app = XCUIApplication()
        app.launchEnvironment[
            "SELF_DM_NOTES_TEST_APPLICATION_SUPPORT_DIRECTORY"
        ] = testLibraryIdentifier
        app.launchArguments += ["-SelfDMNotesHasCompletedOnboardingV1", "YES"]
        addTeardownBlock { [app, testLibraryIdentifier] in
            app?.terminate()
            if let testLibraryIdentifier {
                let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    testLibraryIdentifier,
                    isDirectory: true
                )
                try? FileManager.default.removeItem(at: rootURL)
            }
        }
        app.launch()
    }

    func testVisibleSendButtonCreatesAccessibleNote() {
        let composer = composerField()
        composer.click()
        composer.typeText("Sent with the visible button")

        let sendButton = app.buttons["send-button"]
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.click()

        let note = app.staticTexts["note-body"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        waitForValue("Sent with the visible button", in: note)
        waitForValue("", in: composer)

        // Exercise termination/lifecycle flushing immediately after send. The body
        // must remain a note and must not be resurrected as a recovered draft.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["note-body"].waitForExistence(timeout: 5))
        waitForValue("", in: composerField())
    }

    func testCommandReturnSendsAndReturnCreatesMultilineNote() {
        let composer = composerField()
        composer.click()
        composer.typeText("Line one")
        app.typeKey(.return, modifierFlags: [])
        composer.typeText("Line two")
        XCTAssertEqual(composer.value as? String, "Line one\nLine two")

        app.typeKey(.return, modifierFlags: [.command])

        let note = app.staticTexts["note-body"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.value as? String, "Line one\nLine two")
    }

    func testNoteAndDraftSurviveRelaunchAndCommandNRestoresComposerFocus() {
        let composer = composerField()
        composer.click()
        composer.typeText("Persisted note")
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["note-body"].waitForExistence(timeout: 5))

        composer.typeText("Recovered draft")
        Thread.sleep(forTimeInterval: 0.8)
        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["note-body"].waitForExistence(timeout: 5))
        let relaunchedComposer = composerField()
        waitForValue("Recovered draft", in: relaunchedComposer)

        app.typeKey("n", modifierFlags: [.command])
        relaunchedComposer.typeText(" with focus")
        waitForValue("Recovered draft with focus", in: relaunchedComposer)
    }

    func testEditTrashRestoreAndPermanentDeleteRequireDiscoverableControls() {
        let composer = composerField()
        composer.click()
        composer.typeText("Lifecycle note")
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["note-body"].waitForExistence(timeout: 5))

        app.menuButtons["note-actions"].click()
        app.menuItems["Edit"].click()
        let editField = app.textViews["edit-note-field"]
        XCTAssertTrue(editField.waitForExistence(timeout: 5))
        editField.click()
        editField.typeKey("a", modifierFlags: [.command])
        editField.typeText("Edited lifecycle note")
        app.buttons["save-edit-button"].click()
        waitForValue("Edited lifecycle note", in: app.staticTexts["note-body"])

        app.menuButtons["note-actions"].click()
        app.menuItems["Move to Trash"].click()
        waitForNonexistence(app.staticTexts["note-body"])

        app.buttons["trash-button"].click()
        XCTAssertTrue(app.scrollViews["trash-list"].waitForExistence(timeout: 5))
        app.buttons["Restore"].click()
        XCTAssertTrue(app.otherElements["empty-trash"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
        XCTAssertTrue(app.staticTexts["note-body"].waitForExistence(timeout: 5))

        app.menuButtons["note-actions"].click()
        app.menuItems["Move to Trash"].click()
        waitForNonexistence(app.staticTexts["note-body"])
        app.buttons["trash-button"].click()
        let deleteButton = app.buttons["Delete Permanently"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()
        XCTAssertTrue(app.buttons["Permanently Delete"].waitForExistence(timeout: 5))
        app.buttons["Permanently Delete"].click()
        XCTAssertTrue(app.otherElements["empty-trash"].waitForExistence(timeout: 5))
    }

    func testSearchFocusSelectionClearEscapeAndReturnToNewest() {
        let composer = composerField()
        composer.click()
        composer.typeText("Older searchable navigation target")
        app.typeKey(.return, modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["note-body"].waitForExistence(timeout: 5))

        composer.typeText("Newest timeline note")
        app.typeKey(.return, modifierFlags: [.command])

        app.typeKey("f", modifierFlags: [.command])
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("searchable")
        XCTAssertTrue(app.buttons["search-result"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["search-result-count"].waitForExistence(timeout: 5))

        app.buttons["search-result"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["selected-search-result"].waitForExistence(timeout: 5))
        let newestButton = app.buttons["newest-note-button"]
        XCTAssertTrue(newestButton.waitForExistence(timeout: 5))
        newestButton.click()
        waitForNonexistence(app.staticTexts["selected-search-result"])

        app.typeKey("f", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["clear-search-button"].waitForExistence(timeout: 5))
        app.buttons["clear-search-button"].click()
        XCTAssertTrue(app.otherElements["search-prompt"].waitForExistence(timeout: 5))

        let reopenedSearchField = app.textFields["search-field"]
        reopenedSearchField.typeText("no matching phrase")
        XCTAssertTrue(app.otherElements["empty-search-results"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        waitForNonexistence(app.otherElements["search-workspace"])
        composerField().typeText("Escape returned composer focus")
        waitForValue("Escape returned composer focus", in: composerField())
    }

    func testClipboardImageCreatesAttachmentOnlyNoteAndFilenameIsSearchable() throws {
        let imageData = try XCTUnwrap(
            Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mP8z8Dwn4GBgYGJAQoAHgQCAZ7ZqZQAAAAASUVORK5CYII="
            )
        )
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setData(imageData, forType: .png))

        let attachmentMenu = app.menuButtons["add-attachment-button"]
        XCTAssertTrue(attachmentMenu.waitForExistence(timeout: 5))
        attachmentMenu.click()
        app.menuItems["Paste Clipboard Image"].click()

        let pendingAttachment = app.otherElements["pending-attachment"]
        XCTAssertTrue(pendingAttachment.waitForExistence(timeout: 5))
        let sendButton = app.buttons["send-button"]
        let enabledPredicate = NSPredicate(format: "enabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: enabledPredicate,
            object: sendButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabledExpectation], timeout: 5), .completed)
        sendButton.click()

        XCTAssertTrue(app.otherElements["attachment-card"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["note-body"].exists)

        app.typeKey("f", modifierFlags: [.command])
        let searchField = app.textFields["search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("Pasted Image")
        XCTAssertTrue(app.buttons["search-result"].firstMatch.waitForExistence(timeout: 5))
    }

    func testCommandShiftAOpensKeyboardDismissibleAttachmentPicker() {
        app.typeKey("a", modifierFlags: [.command, .shift])
        let openButton = app.buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        waitForNonexistence(openButton)
        XCTAssertTrue(composerField().exists)
    }

    func testLinkPreviewPrivacySettingIsOptInAndExplainsDisclosure() {
        app.buttons["settings-button"].click()
        let toggle = app.checkBoxes["automatic-link-previews-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 0)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'reveal your IP address'")
            ).firstMatch.exists
        )
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        app.buttons["Close"].click()
    }

    func testPendingPreviewCanBeRemovedWithoutChangingNoteURL() {
        let body = "Keep https://example.net/exact?value=One"
        let composer = composerField()
        composer.click()
        composer.typeText(body)
        app.typeKey(.return, modifierFlags: [.command])

        let card = app.otherElements["link-preview-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.menuButtons["link-preview-actions"].click()
        app.menuItems["Remove Preview"].click()
        waitForNonexistence(card)
        waitForValue(body, in: app.staticTexts["note-body"])
    }

    func testOnboardingExplainsLocalStorageBackupPrivacyAndNoSync() {
        app.terminate()
        app.launchArguments = ["-SelfDMNotesHasCompletedOnboardingV1", "NO"]
        app.launch()

        XCTAssertTrue(app.otherElements["onboarding-view"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local-only archive"].exists)
        XCTAssertTrue(app.staticTexts["Backups are essential"].exists)
        XCTAssertTrue(app.staticTexts["Link-preview privacy"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'no account, cloud sync'")
            ).firstMatch.exists
        )
        app.buttons["complete-onboarding-button"].click()
        waitForNonexistence(app.otherElements["onboarding-view"])
        XCTAssertTrue(composerField().exists)
    }

    func testShortcutReferenceAndAboutHealthSurfaceAreDiscoverable() {
        app.typeKey("/", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            app.otherElements["keyboard-shortcuts-view"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Command-Return"].exists)
        XCTAssertTrue(app.staticTexts["Return"].exists)
        app.buttons["Close"].click()

        app.menuBars.menuBarItems["Self DM Notes"].click()
        app.menuItems["About Self DM Notes…"].click()
        XCTAssertTrue(app.otherElements["about-support-view"].waitForExistence(timeout: 5))
        let healthButton = app.buttons["run-health-check-button"]
        XCTAssertTrue(healthButton.waitForExistence(timeout: 5))
        healthButton.click()
        XCTAssertTrue(
            app.otherElements["library-health-result"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["export-support-information-button"].exists)
    }

    private func composerField() -> XCUIElement {
        let composer = app.textViews["composer-field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.label, "Write a note")
        return composer
    }

    private func waitForValue(_ expectedValue: String, in element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func waitForNonexistence(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
