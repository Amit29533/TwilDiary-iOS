import XCTest

@MainActor final class ProfileFormattingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func open(_ kind: String, _ id: Int, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-profile-repairs", "--ui-profile-format=\(kind):\(id)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        let favourite = kind == "cast" ? "person-favourite" : kind == "voice" ? "voice-actor-favourite" : "character-favourite"
        XCTAssertTrue(app.buttons[favourite].waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.count, 0)
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if item.exists && item.isHittable && item.frame.minY > app.navigationBars.firstMatch.frame.maxY && item.frame.maxY < app.frame.maxY - 15 { break }
            app.swipeUp()
        }
        XCTAssertTrue(item.exists, item.identifier)
        XCTAssertTrue(item.isHittable, item.identifier)
        XCTAssertGreaterThanOrEqual(item.frame.minX, 12)
        XCTAssertLessThanOrEqual(item.frame.maxX, app.frame.width - 12)
    }
    private func source(_ app: XCUIApplication, _ id: String, role: String) {
        let action = app.buttons[id]
        XCTAssertTrue(action.exists)
        XCTAssertEqual(action.frame.width, 44, accuracy: 2)
        XCTAssertEqual(action.frame.height, 44, accuracy: 2)
        XCTAssertEqual(action.frame.midY, app.staticTexts[role].firstMatch.frame.midY, accuracy: 4)
    }
    private func factPair(_ app: XCUIApplication, first: String, second: String) {
        let a = element(app, first), b = element(app, second)
        reveal(a, in: app)
        XCTAssertTrue(b.exists)
        XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 1)
        XCTAssertEqual(a.frame.height, b.frame.height, accuracy: 1)
        XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(b.frame.minX, a.frame.maxX)
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCastProfilesKeepLocationsContextAliasesAndAgeAtDeath() {
        executionTimeAllowance = 180
        for id in [974169, 1134684, 172069] {
            let app = open("cast", id)
            source(app, "person-tmdb", role: "Actor")
            factPair(app, first: "person-birthday", second: "person-age")
            let place = element(app, "person-birthplace"); reveal(place, in: app)
            XCTAssertEqual(place.frame.width, app.frame.width - 28, accuracy: 2)
            if id == 974169 { XCTAssertTrue(app.buttons["person-source-role"].exists) }
            if id == 172069 { XCTAssertTrue(element(app, "person-age").label.contains("43")); XCTAssertTrue(element(app, "person-deathday").exists) }
            capture("Cast \(id) balanced facts and full location", app: app)
            let bio = element(app, "profile-biography"); reveal(bio, in: app)
            XCTAssertTrue(app.buttons["Expand biography"].exists)
            app.buttons["Expand biography"].tap()
            XCTAssertTrue(app.buttons["Collapse biography"].exists)
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testCharacterProfilesPreserveRangesYearOnlyDatesAndNativeRelationships() {
        executionTimeAllowance = 200
        for (id, age) in [(70069, "17 (physically)"), (176754, "1000+"), (138100, "6 (self asserted)"), (12, "14-15")] {
            let app = open("character", id)
            source(app, "profile-site-https://anilist.co/character/\(id)", role: "Character")
            let value = element(app, "character-age"); reveal(value, in: app)
            XCTAssertTrue(value.label.contains(age))
            if id == 12 { XCTAssertTrue(element(app, "character-birthday").label.contains("1900")) }
            if id == 176754 { XCTAssertFalse(element(app, "character-birthday").exists) }
            capture("Character \(id) freeform age and optional facts", app: app)
            let bio = element(app, "profile-biography"); reveal(bio, in: app)
            if id == 176754 { XCTAssertFalse(app.buttons["Expand biography"].exists, "Short biographies have no empty More control") }
            if id == 138100 { XCTAssertTrue(element(app, "profile-detail-relatives").exists) }
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testVoiceProfilesSeparateLinksFactsCareerAndBiography() {
        executionTimeAllowance = 180
        for id in [100250, 119331, 95065] {
            let app = open("voice", id)
            source(app, "voice-actor-tmdb", role: "Voice actor")
            XCTAssertEqual(app.staticTexts["voice-actor-watched"].label, "15 anime watched")
            factPair(app, first: "voice-actor-birthday", second: "voice-actor-age")
            let home = element(app, "voice-actor-hometown"); reveal(home, in: app)
            XCTAssertEqual(home.frame.width, app.frame.width - 28, accuracy: 2)
            capture("Voice \(id) complete hometown and aligned facts", app: app)
            let links = element(app, "profile-links-section"); reveal(links, in: app)
            let bio = element(app, "voice-actor-biography"); reveal(bio, in: app)
            XCTAssertGreaterThan(bio.frame.minY, links.frame.maxY)
            XCTAssertFalse(bio.label.contains("Agency:"))
            XCTAssertFalse(bio.label.contains("Height:"))
            capture("Voice \(id) links separated from prose", app: app)
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testLargeTextStacksFactsAndKeepsHeartsPinnedAcrossProfileTypes() {
        executionTimeAllowance = 240
        for (kind, id, prefix) in [("cast", 974169, "person"), ("character", 70069, "character"), ("voice", 95065, "voice-actor")] {
            let app = open(kind, id, large: true)
            let heart = app.buttons[prefix + "-favourite"], heartY = heart.frame.midY
            let first = element(app, prefix + "-birthday"); reveal(first, in: app)
            XCTAssertEqual(first.frame.width, app.frame.width - 28, accuracy: 2)
            let age = element(app, prefix + "-age"); reveal(age, in: app)
            XCTAssertGreaterThanOrEqual(age.frame.minY, first.frame.maxY)
            XCTAssertEqual(heart.frame.midY, heartY, accuracy: 2)
            XCTAssertTrue(heart.isHittable)
            XCTAssertEqual(app.tabBars.count, 0)
            capture("Large text \(kind) full-width facts and pinned heart", app: app)
            app.terminate()
        }
    }
}
