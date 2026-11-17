import XCTest

@MainActor final class PersonalSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(reset: Bool = true, large: Bool = false, searchRegression: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if reset { app.launchArguments.append("--ui-personal-profile-reset") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if searchRegression { app.launchArguments.append("--ui-search-regression") }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 15)); return app
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testTheTVDBOpensFromKeysBelowTMDB() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
        let connections = app.buttons["settings-connections"]
        for _ in 0..<8 { if connections.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(connections.isHittable); connections.tap()
        let tvdb = app.buttons["settings-tvdb"]
        for _ in 0..<8 { if tvdb.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tvdb.isHittable)
        XCTAssertLessThan(app.buttons["settings-tmdb"].frame.minY, tvdb.frame.minY)
        XCTAssertLessThan(tvdb.frame.minY, app.buttons["settings-apis"].frame.minY)
        tvdb.tap()
        XCTAssertTrue(app.navigationBars["TheTVDB"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tvdb-check-connection"].exists)
        let toggle = app.buttons["tvdb-api-toggle"]
        XCTAssertTrue(toggle.isEnabled)
        toggle.tap()
        XCTAssertEqual(toggle.label, "Hide", app.debugDescription)
        XCTAssertTrue(app.secureTextFields["tvdb-api-key-field"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["tvdb-api-save"].isEnabled)
    }
    func testProfileMenuOrderPersonalPageAvatarAndMilestones() {
        let app = launch(); app.tabBars.buttons["Profile"].tap()
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertFalse(app.tabBars.buttons["More"].exists); XCTAssertFalse(app.tabBars.buttons["Stats"].exists)
        let personal = app.buttons["settings-personal-profile"], statistics = app.buttons["settings-statistics"], diary = app.buttons["settings-refresh-diary"]
        // Settings design: your profile first, then Your diary, with Statistics as that card's last row.
        XCTAssertTrue(personal.waitForExistence(timeout: 5)); XCTAssertLessThan(personal.frame.minY, diary.frame.minY)
        XCTAssertLessThan(diary.frame.minY, statistics.frame.minY)
        XCTAssertFalse(app.buttons["search-profile"].exists); XCTAssertFalse(app.staticTexts["Milestones"].exists)
        capture("Profile menu identity then Statistics then Your diary", app)
        personal.tap()
        let avatar = app.buttons["profile-avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5)); XCTAssertEqual(app.tabBars.count, 0)
        // Profile redesign: characters and your own photo are chosen from the avatar picker (tap the picture).
        XCTAssertFalse(app.buttons["profile-custom-photo"].exists, "Custom photo is reached by tapping the picture")
        capture("Personal profile before avatar selection", app)
        avatar.tap(); XCTAssertTrue(app.buttons["profile-custom-photo"].waitForExistence(timeout: 5))
        let frieren = app.buttons["profile-character-176754"]
        XCTAssertTrue(frieren.waitForExistence(timeout: 5)); frieren.tap(); XCTAssertEqual(frieren.value as? String, "Selected")
        capture("Avatar tap presents custom photo and character picker", app)
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings-statistics"].waitForExistence(timeout: 5))
    }
    func testNameAndCharacterPersistAcrossRelaunch() {
        var app = launch(); app.tabBars.buttons["Profile"].tap(); app.buttons["settings-personal-profile"].tap()
        // Edit profile: pick a character and change the name, then Save.
        let edit = app.buttons["profile-edit-name"]; XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let choice = app.buttons["profile-character-176754"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        let field = app.textFields["Name"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Amit Test")
        app.buttons["profile-save"].tap(); app.terminate()
        app = launch(reset: false); app.tabBars.buttons["Profile"].tap()
        // The name is part of the profile row's combined label.
        let row = app.buttons["settings-personal-profile"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); XCTAssertTrue(row.label.contains("Amit Test"), row.label)
        app.buttons["settings-personal-profile"].tap()
        let avatar = app.buttons["profile-avatar"]; XCTAssertTrue(avatar.waitForExistence(timeout: 5)); avatar.tap()
        let chosen = app.buttons["profile-character-176754"]; XCTAssertTrue(chosen.waitForExistence(timeout: 5))
        XCTAssertEqual(chosen.value as? String, "Selected")
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
        XCTAssertTrue(app.staticTexts["Top 10 shows this week"].waitForExistence(timeout: 5))
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
    func testSearchBrowseScrollsBelowTheChartAndOpensAwards() {
        let app = launch(); app.tabBars.buttons["Search"].tap()
        let chart = app.staticTexts["Top 10 shows this week"]
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue(field.exists)

        let awards = app.buttons["search-browse-more-awards"]
        for _ in 0..<10 { if awards.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(awards.isHittable)
        XCTAssertFalse(field.isHittable)
        XCTAssertFalse(app.staticTexts["Trending movies"].exists)
        XCTAssertFalse(app.staticTexts["Trending anime"].exists)
        capture("Search collections below the weekly chart", app)

        awards.tap()
        XCTAssertTrue(app.navigationBars["Awards"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-award-ceremony-1"].exists)
        let emmys = app.buttons["search-award-ceremony-5"]
        XCTAssertTrue(emmys.waitForExistence(timeout: 5)); emmys.tap()
        XCTAssertTrue(app.navigationBars["Primetime Emmy Awards 2004"].waitForExistence(timeout: 5))
        let year = app.buttons["search-award-year-filter"]
        XCTAssertTrue(year.exists)
        XCTAssertTrue(app.buttons["search-award-type-filter"].exists)
        XCTAssertTrue(app.buttons["search-award-category-filter"].exists)
        XCTAssertFalse(app.buttons["search-award-year-2004"].exists)
        year.tap()
        app.buttons["1999"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Primetime Emmy Awards 1999"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-award-nominee-4"].exists)
        year.tap()
        app.buttons["2004"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Primetime Emmy Awards 2004"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Outstanding Drama Series"].waitForExistence(timeout: 5))
        let winner = app.buttons["search-award-nominee-1"]
        let nominee = app.buttons["search-award-nominee-2"]
        XCTAssertTrue(winner.exists)
        XCTAssertTrue(nominee.exists)
        app.buttons["search-award-winners-filter"].tap()
        XCTAssertTrue(winner.exists)
        XCTAssertFalse(nominee.exists)
        app.buttons["search-award-type-filter"].tap()
        app.buttons["Acting"].firstMatch.tap()
        XCTAssertTrue(app.buttons["search-award-nominee-5"].exists)
        XCTAssertFalse(winner.exists)
        app.buttons["search-award-type-filter"].tap()
        app.buttons["All"].firstMatch.tap()
        XCTAssertTrue(winner.waitForExistence(timeout: 5)); winner.tap()
        XCTAssertTrue(app.buttons["catalog-more"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open title"].exists)
    }

    func testSearchLoadsLaterPagesAndKeepsAnimeFilmsInAnime() {
        let app = launch(searchRegression: true)
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Animation sample\n")
        app.buttons["search-kind-anime"].tap()
        let film = app.buttons["search-movie:901001"]
        XCTAssertTrue(film.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search-tv:901002"].exists)
        XCTAssertTrue(app.buttons["search-add-movie:901001"].exists)
        app.buttons["search-show-all"].tap()
        XCTAssertTrue(app.buttons["search-tv:901003"].waitForExistence(timeout: 5))
        XCTAssertTrue(film.exists)
    }

    func testPeopleSearchLoadsLaterPagesThenShowsAnEmptyStateForANewQuery() {
        let app = launch(searchRegression: true)
        app.tabBars.buttons["Search"].tap()
        app.buttons["search-kind-people"].tap()
        let field = app.textFields["Search library and online"]
        field.tap(); field.typeText("Reference\n")
        XCTAssertTrue(app.buttons["search-person-cast:525"].waitForExistence(timeout: 5))
        app.buttons["search-people-more"].tap()
        XCTAssertTrue(app.buttons["search-person-cast:526"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-person-cast:525"].exists)
        app.buttons["Clear search"].tap()
        field.typeText("No matching person\n")
        XCTAssertTrue(app.staticTexts["search-people-empty"].waitForExistence(timeout: 5))
    }

    func testSearchOffersTagSearchAndSearchLabBelowTheChart() {
        let app = launch()
        app.tabBars.buttons["Search"].tap()
        let find = app.buttons["search-browse-more-tags"]
        for _ in 0..<8 { if find.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(find.isHittable); find.tap()
        let field = app.textFields["Find tags"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Time trav\n")
        XCTAssertTrue(app.buttons["search-tag-time travel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let lab = app.buttons["search-browse-lab"]
        for _ in 0..<24 { if lab.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lab.isHittable); lab.tap()
        XCTAssertTrue(app.navigationBars["Search Lab"].waitForExistence(timeout: 5))
    }
    func testSearchLabCanReachMatchesAfterAnEmptyFilteredPage() {
        let app = launch(searchRegression: true)
        app.tabBars.buttons["Search"].tap()
        let lab = app.buttons["search-browse-lab"]
        for _ in 0..<24 { if lab.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lab.isHittable); lab.tap()
        let keyword = app.textFields["search-lab-keyword"]
        XCTAssertTrue(keyword.waitForExistence(timeout: 5))
        keyword.tap(); keyword.typeText("Library filter sample\n")
        let inLibrary = app.buttons["In library"]
        for _ in 0..<12 { if inLibrary.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(inLibrary.isHittable); inLibrary.tap()
        app.buttons["search-lab-show"].tap()
        let more = app.buttons["search-lab-load-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["search-lab-title-tv:990101"].exists)
        more.tap()
        XCTAssertTrue(app.buttons["search-lab-title-tv:990102"].waitForExistence(timeout: 5))
        XCTAssertFalse(more.exists)
    }
    func testPopularFranchisesOpensTwilDiaryPosterGrid() {
        let app = launch(); app.tabBars.buttons["Search"].tap()
        let all = app.buttons["search-browse-more-franchises"]
        for _ in 0..<14 { if all.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(all.isHittable)
        all.tap()
        XCTAssertTrue(app.navigationBars["Popular franchises"].waitForExistence(timeout: 5))
        app.buttons["search-tvdb-list-4"].tap()
        XCTAssertTrue(app.navigationBars["Marvel Cinematic Universe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catalog-movie:900001"].waitForExistence(timeout: 5))
    }
    func testSearchThemesOpensFilteredBrowsePage() {
        let app = launch(); app.tabBars.buttons["Search"].tap()
        let more = app.buttons["search-browse-more-themes"]
        for _ in 0..<10 { if more.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(more.isHittable)
        more.tap()
        XCTAssertTrue(app.navigationBars["Themes"].waitForExistence(timeout: 5))
        app.buttons["search-theme-sitcoms"].tap()
        XCTAssertTrue(app.navigationBars["Sitcoms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search-browse-sort"].exists)
        XCTAssertTrue(app.buttons["search-browse-rating"].exists)
        XCTAssertTrue(app.buttons["search-browse-studio"].exists)
        XCTAssertTrue(app.buttons["search-browse-period"].exists)
    }
    func testSearchCastCharactersAndVoiceActorsOpenNativeProfiles() {
        executionTimeAllowance = 240
        let app = launch(); app.tabBars.buttons["Search"].tap()
        let field = app.textFields["Search library and online"]
        for (scope, query, result, heart) in [("Cast", "Reference", "cast:525", "person-favourite"), ("Characters", "Fern", "character:2", "character-favourite"), ("Voice actors", "Kana", "voice:12", "voice-actor-favourite")] {
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + query + "\n")
            // One results page: people show under the titles (no category chips).
            let choice = app.buttons["search-person-" + result]
            XCTAssertTrue(choice.waitForExistence(timeout: 8))
            for _ in 0..<8 { if choice.isHittable { break }; app.swipeUp() }
            choice.tap()
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
