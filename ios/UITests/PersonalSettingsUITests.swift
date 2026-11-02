import XCTest

@MainActor final class PersonalSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(reset: Bool = true, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if reset { app.launchArguments.append("--ui-personal-profile-reset") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 15)); return app
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testProfileMenuOrderPersonalPageAvatarAndMilestones() {
        let app = launch(); app.tabBars.buttons["Profile"].tap()
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertFalse(app.tabBars.buttons["More"].exists); XCTAssertFalse(app.tabBars.buttons["Stats"].exists)
        let personal = app.buttons["settings-personal-profile"], statistics = app.buttons["settings-statistics"], diary = app.buttons["settings-refresh-diary"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5)); XCTAssertLessThan(personal.frame.maxY, statistics.frame.minY)
        XCTAssertLessThan(statistics.frame.maxY, diary.frame.minY)
        XCTAssertFalse(app.buttons["search-profile"].exists); XCTAssertFalse(app.staticTexts["Milestones"].exists)
        capture("Profile menu identity then Statistics then Your diary", app)
        personal.tap()
        let avatar = app.buttons["profile-avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5)); XCTAssertEqual(app.tabBars.count, 0)
        let characters = app.staticTexts["Popular Characters"], milestones = app.staticTexts["Milestones"]
        XCTAssertTrue(characters.waitForExistence(timeout: 5)); XCTAssertLessThan(characters.frame.minY, milestones.frame.minY)
        XCTAssertFalse(app.buttons["profile-custom-photo"].exists, "Custom photo is reached by tapping the picture")
        let frieren = app.buttons["profile-character-176754"]
        XCTAssertTrue(frieren.waitForExistence(timeout: 5)); frieren.tap(); XCTAssertEqual(frieren.value as? String, "Selected")
        capture("Personal profile popular character avatars above minimal milestones", app)
        avatar.tap(); XCTAssertTrue(app.buttons["profile-custom-photo"].waitForExistence(timeout: 5))
        capture("Avatar tap presents custom photo and character picker", app)
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings-statistics"].waitForExistence(timeout: 5))
    }
    func testNameAndCharacterPersistAcrossRelaunch() {
        var app = launch(); app.tabBars.buttons["Profile"].tap(); app.buttons["settings-personal-profile"].tap()
        let choice = app.buttons["profile-character-176754"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        app.buttons["profile-edit-name"].tap()
        let field = app.alerts.textFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Amit Test")
        app.alerts.buttons["Save"].tap(); app.terminate()
        app = launch(reset: false); app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.staticTexts["Amit Test"].waitForExistence(timeout: 5))
        app.buttons["settings-personal-profile"].tap()
        XCTAssertEqual(app.buttons["profile-character-176754"].value as? String, "Selected")
        capture("Personal name and character avatar survive relaunch", app)
    }
    func testStatisticsIsNestedAndFunFactsAreRemoved() {
        let app = launch(); app.tabBars.buttons["Profile"].tap(); app.buttons["settings-statistics"].tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["7D"].exists); XCTAssertTrue(app.buttons["1Y"].exists)
        XCTAssertFalse(app.buttons["search-stats"].exists)
        for _ in 0..<6 { XCTAssertFalse(app.staticTexts["Fun facts"].exists); app.swipeUp() }
        XCTAssertFalse(app.otherElements["stats-fun-facts"].exists)
        capture("Statistics without Fun facts", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings-personal-profile"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        let shortcut = app.buttons["home-stats"]
        for _ in 0..<8 { if shortcut.isHittable { break }; app.swipeUp() }
        shortcut.tap(); XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
    }
    func testUniversalSearchTrendingLocalMatchAndReturnToSearch() {
        let app = launch(); app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Trending this week"].waitForExistence(timeout: 5))
        capture("Universal Search with weekly TMDB trends", app)
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.exists); field.tap(); field.typeText("Frieren\n")
        let result = app.buttons["search-library-frieren"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Frieren")
        capture("Universal Search preserves query on return", app)
        app.tabBars.buttons["Library"].tap(); XCTAssertFalse(app.buttons["Search library"].exists)
        app.tabBars.buttons["Glance"].tap(); XCTAssertFalse(app.buttons["search-glance"].exists)
        app.tabBars.buttons["Home"].tap(); XCTAssertFalse(app.buttons["search-twildiary"].exists)
    }
    func testSearchCastCharactersAndVoiceActorsOpenNativeProfiles() {
        executionTimeAllowance = 240
        let app = launch(); app.tabBars.buttons["Search"].tap()
        let field = app.textFields["Search library and online"]
        for (scope, query, result, heart) in [("Cast", "Reference", "cast:525", "person-favourite"), ("Characters", "Fern", "character:2", "character-favourite"), ("Voice actors", "Kana", "voice:12", "voice-actor-favourite")] {
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + query + "\n")
            let chip = app.buttons[scope], shelf = app.scrollViews["search-scopes"]
            for _ in 0..<6 { if chip.isHittable { break }; shelf.swipeLeft() }
            XCTAssertTrue(chip.isHittable); chip.tap()
            let choice = app.buttons["search-person-" + result]
            XCTAssertTrue(choice.waitForExistence(timeout: 8)); choice.tap()
            XCTAssertTrue(app.buttons[heart].waitForExistence(timeout: 8)); XCTAssertEqual(app.webViews.count, 0)
            capture(scope + " search opens the native profile", app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, query)
        }
    }
    func testEveryRootScrollsUnderTheTopAreaAndStatisticsUsesTheSameViewport() {
        executionTimeAllowance = 240
        let app = launch()
        for tab in ["Home", "Library", "Glance", "Search", "Profile"] {
            app.tabBars.buttons[tab].tap()
            let page = app.scrollViews.firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            app.swipeUp()
            XCTAssertLessThanOrEqual(page.frame.minY, 1, tab + " content reaches the top edge while scrolling")
            XCTAssertGreaterThanOrEqual(page.frame.maxY, app.frame.maxY - 2, tab + " content extends behind floating tabs")
            capture(tab + " edge-to-edge scroll with Cast-style feathered top blur", app)
        }
        app.tabBars.buttons["Profile"].tap()
        let statistics = app.buttons["settings-statistics"]
        for _ in 0..<8 { if statistics.isHittable { break }; app.swipeDown() }
        statistics.tap(); XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertLessThanOrEqual(app.scrollViews.firstMatch.frame.minY, 1)
        capture("Statistics edge-to-edge scrolling with feathered top blur", app)
    }
    func testLargeTextPersonalProfileKeepsAvatarAndSectionsReadable() {
        let app = launch(large: true); app.tabBars.buttons["Profile"].tap()
        app.buttons["settings-personal-profile"].tap()
        XCTAssertTrue(app.buttons["profile-avatar"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        for _ in 0..<3 { app.swipeUp() }
        capture("Large text personal profile minimal milestones", app)
        XCTAssertFalse(app.buttons["profile-custom-photo"].exists)
    }
}
