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
        let move = app.buttons["Edit Prepare launch brief priority and deadline"]
        XCTAssertTrue(move.waitForExistence(timeout: 2))
        XCTAssertTrue(String(describing: move.value).contains("P2"))
        XCTAssertFalse(String(describing: move.value).contains("no deadline"))
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

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("founders-office-ui-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryRoots.append(root)
        return root
    }
}
