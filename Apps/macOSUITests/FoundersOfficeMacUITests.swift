import AppKit
import XCTest

final class FoundersOfficeMacUITests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
    }

    func testAppearanceSaveSurvivesRelaunch() {
        let root = makeTemporaryRoot()
        var app = launch(
            root: root,
            environment: appearanceEnvironment
        )

        let nativePreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 4))
        nativePreset.click()

        let save = app.buttons["appearance.save"]
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertFalse(save.isEnabled)

        app.terminate()
        app = launch(root: root, environment: appearanceEnvironment)

        let relaunchedPreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(relaunchedPreset.waitForExistence(timeout: 4))
        XCTAssertTrue(relaunchedPreset.isSelected)
        XCTAssertFalse(app.buttons["appearance.save"].isEnabled)
    }

    func testFirstRunOnboardingIsFullyVisibleAndHittable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-onboarding"]
        app.launchEnvironment = [
            "OPENLOOPS_ROOT": makeTemporaryRoot().path,
            "OPENLOOPS_PREVIEW_CALENDAR": "1"
        ]
        app.launch()

        let setup = app.windows["Founder's Office Setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(setup.frame.width, 719)
        XCTAssertGreaterThanOrEqual(setup.frame.height, 499)

        let firstTitle = app.staticTexts["Welcome. What should we call you?"]
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(
            firstTitle.isHittable,
            "The top of onboarding must remain on screen, not grow above the display from a zero-size origin."
        )
        XCTAssertTrue(app.textFields["Preferred name"].isHittable)
        XCTAssertTrue(app.buttons["Continue"].isHittable)
    }

    func testAppearanceDiscardAndEscapePreserveCommittedState() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: appearanceEnvironment
        )
        let nativePreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 4))
        nativePreset.click()
        app.buttons["appearance.discard"].click()
        XCTAssertFalse(app.buttons["appearance.save"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["appearance.preset.manish"].isSelected)

        nativePreset.click()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let unsaved = app.descendants(matching: .any)["appearance.unsaved.editor"]
        XCTAssertTrue(unsaved.waitForExistence(timeout: 2))
        app.buttons["appearance.unsaved.discard"].click()
        XCTAssertFalse(unsaved.exists)
        XCTAssertTrue(app.buttons["nav.home"].isSelected)
    }

    func testUncommittedAppearanceIsNeverRestoredAfterRelaunch() {
        let root = makeTemporaryRoot()
        var app = launch(root: root, environment: appearanceEnvironment)
        let nativePreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 4))
        nativePreset.click()
        XCTAssertTrue(app.buttons["appearance.save"].isEnabled)

        // UI-test termination deliberately bypasses the customer quit prompt,
        // which proves an uncommitted in-memory draft cannot leak to storage.
        app.terminate()
        app = launch(root: root, environment: appearanceEnvironment)

        XCTAssertTrue(
            app.descendants(matching: .any)["appearance.preset.manish"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.descendants(matching: .any)["appearance.preset.manish"].isSelected)
        XCTAssertFalse(app.buttons["appearance.save"].isEnabled)
    }

    func testEscapeFromUnsavedAppearanceReturnsToTheDraftWithoutDiscardingIt() {
        let app = launch(root: makeTemporaryRoot(), environment: appearanceEnvironment)
        let nativePreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 4))
        nativePreset.click()

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let editor = app.descendants(matching: .any)["appearance.unsaved.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        XCTAssertTrue(editor.waitForNonExistence(timeout: 2))
        XCTAssertTrue(nativePreset.isSelected)
        XCTAssertTrue(app.buttons["appearance.save"].isEnabled)
    }

    func testExplicitCloseRequiresAnAppearanceOutcome() {
        let app = launch(root: makeTemporaryRoot(), environment: appearanceEnvironment)
        let nativePreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 4))
        nativePreset.click()

        app.buttons["notch.close"].click()
        XCTAssertTrue(
            app.staticTexts["Save your appearance before closing?"]
                .waitForExistence(timeout: 2)
        )
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable)
        cancel.click()
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["appearance.save"].isEnabled)
    }

    func testReducedEffectsKeepAppearanceAndPopupLifecycleUsable() throws {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: appearanceEnvironment.merging([
                "OPENLOOPS_UI_TEST_REDUCE_MOTION": "1",
                "OPENLOOPS_UI_TEST_REDUCE_TRANSPARENCY": "1"
            ]) { current, _ in current }
        )
        let nativePreset = app.descendants(matching: .any)["appearance.preset.native"]
        XCTAssertTrue(nativePreset.waitForExistence(timeout: 4))
        nativePreset.click()

        let colourWell = app.descendants(matching: .any)["appearance.colour.0"]
        colourWell.click()
        let colours = try requireNativeColourPanel(in: app)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(colours.waitForNonExistence(timeout: 2))

        let save = app.buttons["appearance.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertTrue(save.isHittable)
        save.click()
        XCTAssertFalse(save.isEnabled)
    }

    func testTaskPlanningEditsPriorityAndDeadline() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_UI_TEST_FIXTURE": "1",
                "OPENLOOPS_PREVIEW_SECTION": "loops",
                "OPENLOOPS_PREVIEW_PLANNING_EDITOR": "1"
            ]
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["movePlanning.editor"]
                .waitForExistence(timeout: 4)
        )

        app.buttons["movePlanning.priority.p2"].click()
        app.switches["movePlanning.deadlineEnabled"].click()
        let save = app.buttons["movePlanning.save"]
        XCTAssertTrue(save.isEnabled)
        save.click()

        XCTAssertFalse(app.descendants(matching: .any)["movePlanning.editor"].exists)
        let move = app.buttons["Edit Prepare launch brief"]
        XCTAssertTrue(move.waitForExistence(timeout: 2))
        XCTAssertTrue(String(describing: move.value).contains("P2"))
        XCTAssertFalse(String(describing: move.value).contains("no deadline"))
    }

    func testPriorityDragTargetIsExposedAsOneMagneticDestination() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_UI_TEST_FIXTURE": "1",
                "OPENLOOPS_PREVIEW_SECTION": "loops",
                "OPENLOOPS_PREVIEW_MOVE_GROUPING": "priority",
                "OPENLOOPS_PREVIEW_PRIORITY_DROP_TARGET": "P1"
            ]
        )

        let priorityScroll = app.descendants(matching: .any)["moves.priority.scroll"]
        XCTAssertTrue(priorityScroll.waitForExistence(timeout: 4))
        let targetLane = app.descendants(matching: .any)["moves.priorityLane.p1"]
        XCTAssertTrue(targetLane.waitForExistence(timeout: 2))
        XCTAssertTrue(String(describing: targetLane.value).contains("Drop target"))
        XCTAssertFalse(
            String(describing: app.descendants(matching: .any)["moves.priorityLane.p0"].value)
                .contains("Drop target")
        )
    }

    func testPriorityDragAutoScrollsToAHiddenLaneAndPersistsTheDrop() {
        let root = makeTemporaryRoot()
        let draggedMoveID = "aaaaaaaa-bbbb-cccc-dddd-000000000001"
        let environment = [
            "OPENLOOPS_UI_TEST_LONG_PRIORITY_FIXTURE": "1",
            "OPENLOOPS_PREVIEW_SECTION": "loops",
            "OPENLOOPS_PREVIEW_MOVE_GROUPING": "priority"
        ]
        var app = launch(root: root, environment: environment)

        let priorityScroll = app.descendants(matching: .any)["moves.priority.scroll"]
        XCTAssertTrue(priorityScroll.waitForExistence(timeout: 4))
        waitForValue("Saved", of: app.descendants(matching: .any)["moves.persistence"])

        let row = app.descendants(matching: .any)["move.row.\(draggedMoveID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.isHittable)
        XCTAssertFalse(
            app.descendants(matching: .any)["moves.priorityLane.p3"].isHittable,
            "The low-priority lane must begin below the viewport so this tests auto-scroll."
        )

        let source = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let lowerEdge = priorityScroll.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)
        )
        source.click(
            forDuration: 0.45,
            thenDragTo: lowerEdge,
            withVelocity: .slow,
            thenHoldForDuration: 3.2
        )

        let planningButton = app.buttons["Edit Priority drag fixture 1"]
        XCTAssertTrue(planningButton.waitForExistence(timeout: 4))
        waitForValueContaining("P3", of: planningButton)
        waitForValue("Saved", of: app.descendants(matching: .any)["moves.persistence"])
        XCTAssertTrue(String(describing: priorityScroll.value).contains("Idle"))

        app.terminate()
        app = launch(
            root: root,
            environment: environment.merging([
                "OPENLOOPS_PREVIEW_PLANNING_EDITOR": "1",
                "OPENLOOPS_PREVIEW_PLANNING_EDITOR_ID": draggedMoveID
            ]) { current, _ in current }
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["movePlanning.editor"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.buttons["movePlanning.priority.p3"].isSelected)
    }

    func testNewMoveDescriptionCanBeWrittenReadAndEdited() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_UI_TEST_FIXTURE": "1",
                "OPENLOOPS_PREVIEW_SECTION": "loops",
                "OPENLOOPS_PREVIEW_ADDING": "1"
            ]
        )

        let title = app.textFields["newMove.title"]
        let description = app.textFields["newMove.description"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        XCTAssertTrue(description.isHittable)
        title.typeText("Send the launch note")
        description.click()
        description.typeText("Include the beta link and the feedback form.")
        app.buttons["newMove.add"].click()

        let edit = app.buttons["Edit Send the launch note"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.click()
        let editorDescription = app.textFields["movePlanning.description"]
        XCTAssertTrue(editorDescription.waitForExistence(timeout: 2))
        XCTAssertEqual(
            editorDescription.value as? String,
            "Include the beta link and the feedback form."
        )

        editorDescription.click()
        app.typeKey("a", modifierFlags: .command)
        editorDescription.typeText("Include the beta link, feedback form, and deadline.")
        app.buttons["movePlanning.save"].click()
        edit.click()
        XCTAssertEqual(
            app.textFields["movePlanning.description"].value as? String,
            "Include the beta link, feedback form, and deadline."
        )
    }

    func testCalendarCreationUsesTheTopLayerEditor() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_PREVIEW_CALENDAR": "1",
                "OPENLOOPS_PREVIEW_SECTION": "calendar",
                "OPENLOOPS_PREVIEW_EVENT_EDITOR": "1"
            ]
        )
        let editor = app.descendants(matching: .any)["calendarEvent.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))

        let title = app.textFields["calendarEvent.title"]
        title.typeText("UI test event")
        let save = app.buttons["calendarEvent.save"]
        XCTAssertTrue(save.isEnabled)
        save.click()

        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.staticTexts["UI test event"].waitForExistence(timeout: 2))
    }

    func testHomeUpNextSkipsFinishedCalendarEvents() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: ["OPENLOOPS_PREVIEW_CALENDAR": "1"]
        )

        XCTAssertTrue(app.staticTexts["Product review"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Finished planning review"].exists)
    }

    func testNativeColourPanelRestoresTheNotchAfterClosing() throws {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: appearanceEnvironment
        )
        let colourWell = app.descendants(matching: .any)["appearance.colour.0"]
        XCTAssertTrue(colourWell.waitForExistence(timeout: 4))
        colourWell.click()

        let colours = try requireNativeColourPanel(in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(colours.waitForNonExistence(timeout: 2))

        let save = app.buttons["appearance.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isHittable)
    }

    func testPhotoChooserOwnsTheFrontLayerUntilCancelRestoresTheNotch() throws {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_PREVIEW_SETTINGS": "1",
                "OPENLOOPS_PREVIEW_PERSONALIZE_PAGE": "profile",
                "OPENLOOPS_UI_TEST_REDUCE_MOTION": "1"
            ]
        )
        let choosePhoto = app.buttons["personalize.photo.choose"]
        XCTAssertTrue(choosePhoto.waitForExistence(timeout: 4))
        XCTAssertTrue(choosePhoto.isHittable)
        let notch = app.windows["Founder's Office"]
        XCTAssertTrue(notch.exists)
        choosePhoto.click()

        let chooser = app.windows["foundersOffice.native-open-panel"]
        XCTAssertTrue(
            chooser.waitForExistence(timeout: 3),
            "The app-owned native chooser must be exposed above the notch."
        )
        let cancel = chooser.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(
            notch.waitForNonExistence(timeout: 2),
            "The status-bar notch must be ordered out while the chooser owns the interaction."
        )
        XCTAssertFalse(
            choosePhoto.isHittable,
            "The suspended notch must not intercept the chooser's controls."
        )

        cancel.click()
        XCTAssertTrue(chooser.waitForNonExistence(timeout: 3))
        XCTAssertTrue(choosePhoto.waitForExistence(timeout: 3))
        XCTAssertTrue(choosePhoto.isHittable)
    }

    func testSupportReportPreviewsEveryWhitelistedFieldBeforeSave() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_PREVIEW_SETTINGS": "1",
                "OPENLOOPS_PREVIEW_PERSONALIZE_PAGE": "health",
                "OPENLOOPS_PREVIEW_CALENDAR": "1"
            ]
        )
        XCTAssertTrue(app.descendants(matching: .any)["health.page"].waitForExistence(timeout: 4))
        app.buttons["health.previewSupportReport"].click()

        let preview = app.descendants(matching: .any)["health.supportReport.fields"]
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        for key in [
            "support_report_version", "incident_id", "captured_at_utc", "app_version",
            "build_number", "platform", "operating_system", "architecture",
            "local_data_state", "local_data_last_success_utc", "sync_state",
            "sync_last_success_utc", "calendar_state", "calendar_last_success_utc",
            "startup_state", "assistant_state"
        ] {
            XCTAssertTrue(app.staticTexts[key].exists, "Missing preview field: \(key)")
        }
        XCTAssertTrue(app.staticTexts["No Moves, events, names, paths, prompts, or credentials."].exists)
    }

    func testAccountAndSyncFailsClosedWithoutConfiguration() {
        let app = launch(
            root: makeTemporaryRoot(),
            environment: [
                "OPENLOOPS_PREVIEW_SETTINGS": "1",
                "OPENLOOPS_PREVIEW_PERSONALIZE_PAGE": "account"
            ]
        )

        XCTAssertTrue(app.descendants(matching: .any)["account.page"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Stored on this Mac"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["account.localOnlyExplanation"].exists)
        XCTAssertFalse(app.buttons["account.signIn.google"].exists)
        XCTAssertFalse(app.buttons["account.signIn.apple"].exists)
        XCTAssertFalse(app.staticTexts["Sync is live"].exists)
    }

    private var appearanceEnvironment: [String: String] {
        [
            "OPENLOOPS_PREVIEW_SETTINGS": "1",
            "OPENLOOPS_PREVIEW_PERSONALIZE_PAGE": "appearance"
        ]
    }

    private func launch(root: URL, environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = environment.merging([
            "OPENLOOPS_ROOT": root.path,
            "OPENLOOPS_PREVIEW_CALENDAR": environment["OPENLOOPS_PREVIEW_CALENDAR"] ?? "0"
        ]) { current, _ in current }
        app.launch()
        XCTAssertTrue(app.windows["Founder's Office"].waitForExistence(timeout: 5))
        return app
    }

    private func requireNativeColourPanel(in app: XCUIApplication) throws -> XCUIElement {
        let panel = app.windows["foundersOffice.native-color-panel"]
        return try XCTUnwrap(
            panel.waitForExistence(timeout: 3) ? panel : nil,
            "The required native colour panel was not exposed to UI automation."
        )
    }

    private func waitForValue(
        _ expectedValue: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = expectation(for: predicate, evaluatedWith: element)
        wait(for: [expectation], timeout: timeout)
    }

    private func waitForValueContaining(
        _ expectedFragment: String,
        of element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        let predicate = NSPredicate(
            format: "value CONTAINS[c] %@",
            expectedFragment
        )
        let expectation = expectation(for: predicate, evaluatedWith: element)
        wait(for: [expectation], timeout: timeout)
    }

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("founders-office-ui-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryRoots.append(root)
        return root
    }
}
