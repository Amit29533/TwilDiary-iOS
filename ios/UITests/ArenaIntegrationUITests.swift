import XCTest

@MainActor final class ArenaIntegrationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-personal-profile-reset", "--ui-arena", "--ui-upcoming"]
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        // The suite's first launch on a cold CI simulator can take well over 15 s.
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 40))
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    /// Profile → Connections, where Simkl, MDBList, Trakt and the main tracker live.
    private func openConnections(_ app: XCUIApplication) {
        let row = app.buttons["settings-connections"]
        reveal(row, app: app); row.tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCalendarOpensWithinTheCurrentProfileNavigation() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
        let calendar = app.buttons["settings-calendar"]
        reveal(calendar, app: app); calendar.tap()
        XCTAssertTrue(app.navigationBars["Airing calendar"].waitForExistence(timeout: 5))
        capture("Arena calendar in current navigation", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings-calendar"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 5)
    }
    func testProviderPagesAndCollectionFilterKeepTheCurrentNavigation() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap(); openConnections(app)
        let provider = app.buttons["settings-simkl"]
        reveal(provider, app: app); provider.tap()
        XCTAssertTrue(app.navigationBars["Simkl"].waitForExistence(timeout: 5))
        capture("Arena provider connection in Profile", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-filters"].tap()
        let tag = app.buttons["filter-tag-Weekend"]
        reveal(tag, app: app)
        tag.tap()
        capture("Collection filter in current Library sheet", app: app)
        XCTAssertTrue(tag.exists)
    }
    /// Each service offers both ways in: sign in (when TwilDiary has an app ID for it) or your own
    /// API key or token. The preview server has no Simkl/MDBList app ID, so their pages explain where
    /// to add one.
    func testEveryServiceOffersSignInOrYourOwnKey() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap(); openConnections(app)
        for (row, title, signIn, key) in [("settings-simkl", "Simkl", "simkl-sign-in-unavailable", "simkl-client-id-field"),
                                          ("settings-mdblist", "MDBList", "mdblist-sign-in-unavailable", "mdblist-api-key-field")] {
            let entry = app.buttons[row]
            reveal(entry, app: app); entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
            XCTAssertTrue(app.descendants(matching: .any)[signIn].waitForExistence(timeout: 5), "\(title) explains its sign-in")
            // Your own key is folded away under one button.
            let ownKey = app.buttons[row.replacingOccurrences(of: "settings-", with: "") + "-own-key"]
            reveal(ownKey, app: app); ownKey.tap()
            let field = app.descendants(matching: .any)[key]
            reveal(field, app: app)
            XCTAssertTrue(field.exists, "\(title) still takes your own key or token")
            capture("\(title) connect options", app: app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5))
        }
    }
    /// Profile → Connections: Trakt, Simkl, MDBList and WeTrakr in one list, the main tracker
    /// ticked, and quick actions under ⋯.
    func testConnectionsListTheTrackersWithTheMainOneTicked() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap(); openConnections(app)
        for id in ["settings-trakt", "settings-simkl", "settings-mdblist", "settings-wetrakr"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        XCTAssertTrue(app.buttons["settings-trakt"].label.contains("Main"), "Trakt is the default main tracker")
        XCTAssertFalse(app.buttons["settings-simkl"].label.contains("Main"))
        let actions = app.buttons["simkl-actions"]
        reveal(actions, app: app); actions.tap()
        XCTAssertTrue(app.buttons["Check now"].waitForExistence(timeout: 5))
        capture("Trackers and their actions", app: app)
    }
}
