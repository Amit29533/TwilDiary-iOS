import XCTest

/// Reused by the pinned base, compact and large simulator destinations.
@MainActor final class LayoutScreensTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(longSynopsis: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if longSynopsis { app.launchArguments.append("--ui-long-synopsis") }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15)); return app
    }
    func testPhoneChromeGridSearchAndEpisodeTrackStayInsideTheViewport() {
        let app = launch()
        app.tabBars.buttons["Home"].tap(); capture("Home", app: app)
        app.tabBars.buttons["Library"].tap()
        let titles = ["after-rain", "again", "frieren"].map { app.buttons["title-" + $0] }
        for title in titles { XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(title.frame.minX, 10); XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.width - 10) }
        XCTAssertLessThan(titles[0].frame.maxX, titles[1].frame.minX); XCTAssertLessThan(titles[1].frame.maxX, titles[2].frame.minX)
        // Match the phone web grid and controls; measure layout, not text-ink widths.
        XCTAssertEqual(titles[0].frame.minX, 14, accuracy: 1)
        XCTAssertEqual(titles[0].frame.width, (app.frame.width - 48) / 3, accuracy: 1)
        XCTAssertEqual(titles[1].frame.minX - titles[0].frame.maxX, 10, accuracy: 1)
        XCTAssertEqual(titles[2].frame.minX - titles[1].frame.maxX, 10, accuracy: 1)
        let order = app.buttons["library-order"], layout = app.buttons["library-layout"], genres = app.buttons["library-genres"]
        XCTAssertEqual(order.frame.width, app.frame.width < 359 ? 150 : 185, accuracy: 1)
        XCTAssertEqual(order.frame.height, 46, accuracy: 1)
        XCTAssertEqual(layout.frame.width, 42, accuracy: 1); XCTAssertEqual(layout.frame.height, 44, accuracy: 1)
        XCTAssertEqual(genres.frame.width, 36, accuracy: 1); XCTAssertEqual(genres.frame.height, 44, accuracy: 1)
        XCTAssertEqual(app.buttons["category-all"].frame.minX, 14, accuracy: 1)
        XCTAssertEqual(titles[0].frame.minY - app.buttons["random-pick-logo"].frame.minY, 211, accuracy: 2)
        capture("Library", app: app)
        titles[1].tap()
        let track = app.sliders["episode-progress"]
        XCTAssertTrue(track.waitForExistence(timeout: 5)); XCTAssertEqual(track.value as? String, "8 of 16 episodes watched")
        XCTAssertGreaterThanOrEqual(track.frame.minX, 14); XCTAssertLessThanOrEqual(track.frame.maxX, app.frame.width - 14)
        capture("Title", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Search library"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["search-library-frieren"].exists); XCTAssertFalse(app.buttons["search-library-again"].exists)
        capture("Search", app: app)
        app.tabBars.buttons["Stats"].tap(); XCTAssertTrue(app.buttons["stats-calendar"].waitForExistence(timeout: 5)); capture("Stats", app: app)
        for tab in ["home", "library", "glance", "stats", "more"] {
            let button = app.tabBars.buttons[tab.capitalized]
            XCTAssertTrue(button.isHittable); XCTAssertGreaterThanOrEqual(button.frame.minX, 0); XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.width)
        }
    }
    func testEveryThemeIsSelectableAndGlassSearchKeepsOneContainedField() {
        let app = launch(); app.tabBars.buttons["More"].tap(); openThemes(app)
        let first = app.buttons["theme-twilight"], second = app.buttons["theme-ocean"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.maxX, second.frame.minX)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["theme-jade"].frame.minY, first.frame.maxY)
        capture("Appearance two-column grid", app: app)
        for theme in ["twilight", "ocean", "jade", "rose", "amber", "glass"] {
            let item = app.buttons["theme-" + theme]
            for _ in 0..<4 { if item.isHittable { break }; app.swipeUp() }
            for _ in 0..<4 { if item.isHittable { break }; app.swipeDown() }
            XCTAssertTrue(item.isHittable); item.tap(); XCTAssertTrue(item.isSelected); capture("Theme " + theme, app: app)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.tabBars.buttons["Library"].tap(); app.buttons["Search library"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(search.frame.minX, 14); XCTAssertLessThanOrEqual(search.frame.maxX, app.frame.width - 14)
        search.typeText("Frieren\n"); capture("Glass search", app: app)
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
        app.tabBars.buttons["More"].tap(); openThemes(app)
        let twilight = app.buttons["theme-twilight"]
        for _ in 0..<5 { if twilight.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(twilight.isHittable); twilight.tap(); XCTAssertTrue(twilight.isSelected)
    }
    func testExpandedSummaryAndWatchDateRemainInsideEveryPhone() {
        let app = launch(longSynopsis: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-frieren"].tap()
        let summary = app.staticTexts["title-synopsis-text"]
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
        let leadingFrame = summary.frame
        let leadingText = summary.label.hasSuffix("…") ? String(summary.label.dropLast()) : summary.label
        app.buttons["More"].tap()
        let continuation = app.staticTexts["title-synopsis-continuation"]
        XCTAssertTrue(continuation.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.frame.minX, leadingFrame.minX, accuracy: 1)
        XCTAssertEqual(summary.frame.minY, leadingFrame.minY, accuracy: 1)
        // Accessibility reports glyph ink, so removing the ellipsis legitimately
        // changes its width. Check the retained copy, position and two-line height.
        XCTAssertEqual(summary.label, leadingText)
        XCTAssertEqual(summary.frame.height, leadingFrame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(summary.frame.maxX, app.frame.width - 14)
        // Updated device feedback asks for a full-width synopsis below the
        // lowered poster/identity, with only its overflow added on expansion.
        XCTAssertEqual(summary.frame.minX, 14, accuracy: 1)
        XCTAssertGreaterThan(summary.frame.width, app.frame.width - 157, "The opening lines must use more than the old beside-poster column")
        XCTAssertGreaterThan(summary.frame.minY, app.staticTexts["title-hero-name"].frame.maxY)
        let expandedRegion = app.descendants(matching: .any)["title-synopsis-expanded"]
        XCTAssertTrue(expandedRegion.exists)
        XCTAssertEqual(expandedRegion.frame.minX, 14, accuracy: 1)
        // AX groups report the union of child ink, even for a full-width VStack.
        // Short final lines need not reach the edge; they must remain contained.
        XCTAssertLessThanOrEqual(expandedRegion.frame.maxX, app.frame.width - 14)
        XCTAssertLessThan(continuation.frame.minX, 24)
        XCTAssertGreaterThan(continuation.frame.minY, summary.frame.maxY)
        XCTAssertLessThan(continuation.frame.minY - summary.frame.maxY, 15, "A paragraph continuation must not add a blank section-sized line")
        capture("Lowered title identity and full-width expanded synopsis", app: app)
        let watched = app.buttons["watch-date"]
        for _ in 0..<5 { if watched.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(watched.isHittable); watched.tap()
        let value = app.buttons["title-watch-date-value"]
        for _ in 0..<3 { if value.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(value.isHittable); XCTAssertGreaterThanOrEqual(value.frame.minX, 14); XCTAssertLessThanOrEqual(value.frame.maxX, app.frame.width - 14)
        capture("Watch date contained", app: app)
        value.tap(); XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
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
