import XCTest

/// Drives every page interaction in demo mode (no server, microphone or camera):
/// first run, Home, the live call (talk, look, mute, approval, end), the call
/// record, notes, reminders, every Library filter and search, and Settings.
/// `testScreensInEveryAppearance` attaches a screenshot of each main page in
/// light, dark and the largest accessibility text size.
final class LunaUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - First run

    func testFirstRunExplainsAndFinishes() {
        let app = launch(firstRun: true)
        XCTAssertTrue(app.staticTexts["A little company.\nA clearer day."].waitForExistence(timeout: 5))
        app.element("onboarding.next").tap()
        XCTAssertTrue(app.staticTexts["Pair with Hermes"].waitForExistence(timeout: 3))
        app.element("onboarding.server.next").tap()
        XCTAssertTrue(app.staticTexts["Connect your glasses"].waitForExistence(timeout: 3))
        app.element("onboarding.glasses.next").tap()
        XCTAssertTrue(app.staticTexts["Two quick permissions"].waitForExistence(timeout: 3))
        app.element("onboarding.done").tap()
        XCTAssertTrue(app.element("home.talk").waitForExistence(timeout: 5))
    }

    // MARK: - Home

    func testHomeShowsOneTalkButtonAndFiveShortcuts() {
        let app = launch()
        XCTAssertTrue(app.element("home.talk").waitForExistence(timeout: 5))
        XCTAssertTrue(app.element("home.orb").exists)
        for action in ["look", "capture", "video", "note", "remind"] {
            XCTAssertTrue(app.element("home.action.\(action)").exists, "missing shortcut \(action)")
        }
        for tab in ["home", "library", "talk", "tasks", "you"] {
            XCTAssertTrue(app.element("tab.\(tab)").exists, "missing tab \(tab)")
        }
        XCTAssertTrue(app.element("home.bento.count").exists)
    }

    // MARK: - Live call

    func testCallHappensOnHomeAndLeavesARecord() {
        let app = launch()
        app.element("home.talk").waitAndTap()
        XCTAssertTrue(app.element("call.status").waitForLabel("Luna: I'm listening", timeout: 5))
        XCTAssertFalse(app.element("home.talk").exists, "Talk is replaced by the call while it runs")

        app.element("call.look").tap()
        XCTAssertTrue(app.element("call.tool").waitForExistence(timeout: 3), "tool chip appears while Luna looks")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'desk'")).firstMatch
            .waitForExistence(timeout: 5), "Luna's caption appears")
        XCTAssertTrue(app.staticTexts["YOU"].exists, "your side of the conversation is captioned")

        app.element("call.mute").tap()
        XCTAssertTrue(app.element("call.status").waitForLabel("Luna: Microphone muted", timeout: 2))
        app.element("call.mute").tap()

        // The call survives a tab switch; the centre Talk button brings you back.
        app.element("tab.library").tap()
        app.element("tab.talk").waitAndTap()
        XCTAssertTrue(app.element("call.end").waitForExistence(timeout: 3))

        app.element("call.end").tap()
        XCTAssertTrue(app.element("home.talk").waitForExistence(timeout: 3))

        app.element("tab.library").tap()
        app.element("library.filter.Calls").waitAndTap()
        app.element("library.row").waitAndTap()
        XCTAssertTrue(app.navigationBars["Call"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Luna"].exists)
        XCTAssertTrue(app.element("call.detail.continue").exists)
    }

    func testApprovalCardDeclinesWithoutActing() {
        let app = launch(extra: ["-LunaDemoScript", "approval"])
        app.element("home.talk").waitAndTap()
        XCTAssertTrue(app.element("call.approval").waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Nothing happens unless you tap Approve."].exists)
        app.element("call.approval.decline").tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'cancelled'")).firstMatch
            .waitForExistence(timeout: 3))
        XCTAssertFalse(app.element("call.approval").exists)
        app.element("call.end").tap()
    }

    // MARK: - Notes

    func testNoteCanBeSavedEditedAndDeleted() {
        let app = launch()
        app.element("home.action.note").waitAndTap()
        let field = app.element("memory-note-field")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Order tomatoes for Friday")
        app.element("remember.save").tap()

        app.element("tab.library").waitAndTap()
        app.element("library.filter.Notes").waitAndTap()
        app.element("library.row").waitAndTap()
        app.element("note.detail.edit").waitAndTap()
        let text = app.element("note.detail.text")
        text.waitAndTap()
        text.typeText(" and onions")
        app.element("note.detail.edit").tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'onions'")).firstMatch
            .waitForExistence(timeout: 3))
        app.element("note.detail.delete").tap()
        app.buttons["Delete note"].firstMatch.waitAndTap()
        XCTAssertTrue(app.element("library.filter.Notes").waitForExistence(timeout: 3))
    }

    // MARK: - Reminders

    func testReminderCompletesWithUndoAndDeletes() {
        let app = launch()
        app.element("home.action.remind").waitAndTap()
        let title = app.element("reminder.add.title")
        title.waitAndTap()
        title.typeText("Call the supplier")
        app.element("reminder.add.save").tap()
        allowSystemAlertIfShown(app)

        app.element("tab.tasks").waitAndTap()
        app.element("tasks.segment.Reminders").waitAndTap()
        app.element("tasks.reminder.toggle").waitAndTap()
        app.element("tasks.reminder.toggle").waitAndTap()

        app.element("tasks.reminder").waitAndTap()
        XCTAssertTrue(app.element("reminder.detail.complete").waitForExistence(timeout: 3))
        app.element("reminder.detail.delete").tap()
        app.buttons["Delete reminder"].firstMatch.waitAndTap()
    }

    // MARK: - Library

    func testEveryLibraryFilterAndSearch() {
        let app = launch()
        app.element("tab.library").waitAndTap()
        for filter in ["All", "Photos", "Videos", "Calls", "Notes"] {
            app.element("library.filter.\(filter)").waitAndTap()
            XCTAssertTrue(app.element("library.filter.\(filter)").isSelected, "\(filter) is selected")
        }
        app.element("library.filter.All").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("zzzz-nothing-matches")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 3))
        app.element("library.new").tap()
        XCTAssertTrue(app.buttons["New note"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["New reminder"].exists)
    }

    // MARK: - Settings

    func testSettingsPrivacyControlsAndHiddenDeveloperSection() {
        let app = launch()
        app.element("home.settings").waitAndTap()
        let camera = app.element("settings.privacy.camera")
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        XCTAssertTrue(camera.isOn)
        camera.switches.firstMatch.tap()
        XCTAssertFalse(app.element("settings.privacy.keepReady").isEnabled, "keep-ready depends on camera use")
        camera.switches.firstMatch.tap()

        XCTAssertFalse(app.element("settings.developer.demoLuna").exists, "developer settings start hidden")
        let version = app.element("settings.version")
        version.scrollIntoView(in: app)
        for _ in 0..<7 { version.tap() }
        XCTAssertTrue(app.element("settings.developer.demoLuna").waitForExistence(timeout: 3))
        app.element("settings.developer.hide").scrollIntoView(in: app)
        app.element("settings.developer.hide").tap()
        XCTAssertFalse(app.element("settings.developer.demoLuna").waitForExistence(timeout: 1))
    }

    // MARK: - Every appearance

    func testScreensInEveryAppearance() {
        let variants: [(name: String, dark: Bool, size: String?)] = [
            ("light", false, nil), ("dark", true, nil), ("accessibility-xl", false, "UICTContentSizeCategoryAccessibilityXL"),
        ]
        for variant in variants {
            XCUIDevice.shared.appearance = variant.dark ? .dark : .light
            var extra: [String] = []
            if let size = variant.size { extra += ["-UIPreferredContentSizeCategoryName", size] }
            let app = launch(extra: extra)
            XCTAssertTrue(app.element("home.talk").waitForExistence(timeout: 5))
            attach(app, "home-\(variant.name)")
            app.element("home.talk").tap()
            _ = app.element("call.status").waitForLabel("Luna: I'm listening", timeout: 5)
            attach(app, "call-\(variant.name)")
            app.element("call.end").tap()
            app.element("tab.library").tap()
            attach(app, "library-\(variant.name)")
            app.element("tab.home").tap()
            app.element("home.settings").waitAndTap()
            attach(app, "settings-\(variant.name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    // MARK: - Helpers

    private func launch(firstRun: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-settings.mockHermes", "YES",
            "-settings.mockGlasses", "YES",
            "-settings.onboardingComplete", firstRun ? "NO" : "YES",
            // Throwaway data folder: runs on a real iPhone never touch real calls, notes or reminders.
            "-LunaUITestData",
        ] + (firstRun ? ["-LunaShowOnboarding"] : []) + extra
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Notification permission is asked the first time a reminder is saved.
    private func allowSystemAlertIfShown(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        app.activate()
    }
}

private extension XCUIApplication {
    /// Any element with this accessibility identifier, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}

private extension XCUIElement {
    func waitAndTap(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(identifier) did not appear", file: file, line: line)
        tap()
    }

    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    var isOn: Bool {
        let toggle = switches.firstMatch.exists ? switches.firstMatch : self
        return (toggle.value as? String) == "1"
    }

    func scrollIntoView(in app: XCUIApplication) {
        var attempts = 0
        while !isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }
}
