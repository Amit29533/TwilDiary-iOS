import XCTest

/// Reused by the pinned base, compact and large simulator destinations.
@MainActor final class LayoutScreensTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func openStatistics(_ app: XCUIApplication) {
        app.tabBars.buttons["Profile"].tap()
        let row = app.buttons["settings-statistics"]
        for _ in 0..<10 { if row.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
    }
    private func launch(longSynopsis: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if longSynopsis { app.launchArguments.append("--ui-long-synopsis") }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15)); return app
    }
    func testPhoneChromeGridSearchAndEpisodeTrackStayInsideTheViewport() {
        let app = launch()
        app.tabBars.buttons["Home"].tap(); capture("Home", app: app)
        // Pages scroll under the floating tab bar to the screen's edge, with no black home-indicator band.
        let page = app.scrollViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(page.frame.maxY, app.frame.maxY - 10, "Home ends at \(page.frame.maxY) of \(app.frame.maxY)")
        app.tabBars.buttons["Library"].tap()
        let titles = ["after-rain", "again", "frieren"].map { app.buttons["title-" + $0] }
        for title in titles { XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(title.frame.minX, 10); XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.width - 10) }
        XCTAssertLessThan(titles[0].frame.maxX, titles[1].frame.minX); XCTAssertLessThan(titles[1].frame.maxX, titles[2].frame.minX)
        // Match the phone web grid and controls; measure layout, not text-ink widths.
        XCTAssertEqual(titles[0].frame.minX, 14, accuracy: 1)
        XCTAssertEqual(titles[0].frame.width, (app.frame.width - 48) / 3, accuracy: 1)
        XCTAssertEqual(titles[1].frame.minX - titles[0].frame.maxX, 10, accuracy: 1)
        XCTAssertEqual(titles[2].frame.minX - titles[1].frame.maxX, 10, accuracy: 1)
        // Sort on the left, then the filter and layout buttons as 44 pt circles inside the margins.
        let order = app.buttons["library-order"], filters = app.buttons["library-filters"], layout = app.buttons["library-layout"]
        XCTAssertGreaterThanOrEqual(order.frame.height, 44)
        XCTAssertEqual(filters.frame.width, 44, accuracy: 1); XCTAssertEqual(filters.frame.height, 44, accuracy: 1)
        XCTAssertEqual(layout.frame.width, 44, accuracy: 1); XCTAssertLessThanOrEqual(layout.frame.maxX, app.frame.width - 10)
        XCTAssertLessThan(order.frame.maxX, filters.frame.minX); XCTAssertLessThan(filters.frame.maxX, layout.frame.minX)
        XCTAssertEqual(app.buttons["category-all"].frame.minX, 14, accuracy: 1)
        let chip = app.buttons["library-status-all"]
        XCTAssertGreaterThanOrEqual(chip.frame.minX, 10); XCTAssertLessThan(chip.frame.maxY, order.frame.minY + 1)
        XCTAssertLessThan(order.frame.maxY, titles[0].frame.minY)
        capture("Library", app: app)
        titles[1].tap()
        let track = app.sliders["episode-progress"]
        XCTAssertTrue(track.waitForExistence(timeout: 5)); XCTAssertEqual(track.value as? String, "8 of 16 episodes watched")
        XCTAssertGreaterThanOrEqual(track.frame.minX, 14); XCTAssertLessThanOrEqual(track.frame.maxX, app.frame.width - 14)
        capture("Title", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["search-library-frieren"].exists); XCTAssertFalse(app.buttons["search-library-again"].exists)
        capture("Search", app: app)
        openStatistics(app); XCTAssertTrue(app.buttons["30D"].waitForExistence(timeout: 5)); capture("Stats", app: app)
        for tab in ["home", "library", "glance", "search", "profile"] {
            let button = app.tabBars.buttons[tab.capitalized]
            XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.minX, 0); XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.width)
        }
    }
    func testEveryThemeIsSelectableAndGlassSearchKeepsOneContainedField() {
        let app = launch(); app.tabBars.buttons["Profile"].tap(); openThemes(app)
        let first = app.buttons["theme-twilight"], second = app.buttons["theme-ocean"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.maxX, second.frame.minX)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["theme-jade"].frame.minY, first.frame.maxY)
        capture("Appearance two-column grid", app: app)
        for theme in ["twilight", "ocean", "jade", "rose", "amber"] {
            let item = app.buttons["theme-" + theme]
            for _ in 0..<4 { if item.isHittable { break }; app.swipeUp() }
            for _ in 0..<4 { if item.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(item.isHittable); item.tap(); XCTAssertTrue(item.isSelected); capture("Theme " + theme, app: app)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.tabBars.buttons["Library"].tap(); app.tabBars.buttons["Search"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(search.frame.minX, 14); XCTAssertLessThanOrEqual(search.frame.maxX, app.frame.width - 14)
        search.tap(); search.typeText("Frieren\n"); capture("Glass search", app: app)
        app.buttons["search-library-frieren"].tap()
        XCTAssertTrue(app.staticTexts["title-hero-name"].waitForExistence(timeout: 5))
        capture("Glass lowered title artwork and identity", app: app)
        let compact = app.descendants(matching: .any)["compact-title-navigation"]
        let share = app.buttons["title-share"]
        // The title stays mounted while transparent to avoid toolbar jitter.
        // Its AX identity can exist before scrolling; wait for the real compact
        // actions instead of treating that retained node as the visible state.
        for _ in 0..<8 { if share.exists && share.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(compact.exists); XCTAssertTrue(share.isHittable)
        XCTAssertGreaterThanOrEqual(compact.frame.minX, 0)
        XCTAssertLessThanOrEqual(compact.frame.maxX, app.frame.width)
        capture("Glass compact scrolled title header", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Profile"].tap(); openThemes(app)
        let twilight = app.buttons["theme-twilight"]
        for _ in 0..<5 { if twilight.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(twilight.isHittable); twilight.tap(); XCTAssertTrue(twilight.isSelected)
    }
    func testExpandedSummaryRemainsInsideEveryPhone() {
        let app = launch(longSynopsis: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-frieren"].tap()
        let summary = app.staticTexts["title-synopsis-text"]
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        let leadingFrame = summary.frame
        let leadingText = summary.label.hasSuffix("…") ? String(summary.label.dropLast()) : summary.label
        capture("Collapsed synopsis with More on its last line", app: app)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Less"].waitForExistence(timeout: 5))
        // Expanded, the synopsis is one paragraph at full width: same start, taller, the whole text.
        XCTAssertEqual(summary.frame.minX, leadingFrame.minX, accuracy: 1)
        XCTAssertEqual(summary.frame.minY, leadingFrame.minY, accuracy: 1)
        XCTAssertTrue(summary.label.hasPrefix(leadingText))
        XCTAssertGreaterThan(summary.frame.height, leadingFrame.height)
        XCTAssertLessThanOrEqual(summary.frame.maxX, app.frame.width - 14)
        // Updated device feedback asks for a full-width synopsis below the
        // lowered poster/identity, with only its overflow added on expansion.
        XCTAssertEqual(summary.frame.minX, 16, accuracy: 1)
        XCTAssertGreaterThan(summary.frame.width, app.frame.width - 157, "The opening lines must use more than the old beside-poster column")
        XCTAssertGreaterThan(summary.frame.minY, app.staticTexts["title-hero-name"].frame.maxY)
        let less = app.buttons["title-synopsis-expanded"]
        XCTAssertTrue(less.exists)
        XCTAssertGreaterThan(less.frame.minY, summary.frame.maxY - 1)
        capture("Lowered title identity and full-width expanded synopsis", app: app)
        // (The watch-date row only appears once a past date is chosen, so it is no longer checked here.)
    }
    private func openThemes(_ app: XCUIApplication) {
        let theme = app.buttons["settings-theme"]
        for _ in 0..<8 { if theme.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(theme.isHittable); theme.tap()
    }
    private func capture(_ label: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Layout " + String(Int(app.frame.width)) + " " + label; attachment.lifetime = .keepAlways; add(attachment)
    }
}
