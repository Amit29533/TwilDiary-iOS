import XCTest
import UIKit

@MainActor final class NativeScreensTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(mutations: Bool = false, scanner: Bool = false, ratingsUnavailable: Bool = false, titleMetadata: Bool = false, empty: Bool = false, traktScenario: String? = nil, refreshFailure: Bool = false, upcoming: Bool = false, slowWrites: Bool = false, slowMetadata: Bool = false, communityUnavailable: Bool = false, cachedSnapshot: Bool = false, longEpisodes: Bool = false, automaticCarousel: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if mutations || scanner { app.launchArguments.append("--ui-mutations") }
        if scanner { app.launchArguments.append("--ui-scanner") }
        if ratingsUnavailable { app.launchArguments.append("--ui-ratings-unavailable") }
        if titleMetadata { app.launchArguments.append("--ui-title-metadata") }
        if empty { app.launchArguments.append("--ui-empty") }
        if refreshFailure { app.launchArguments.append("--ui-refresh-failure") }
        if upcoming { app.launchArguments.append("--ui-upcoming") }
        if slowWrites { app.launchArguments.append("--ui-slow-writes") }
        if slowMetadata { app.launchArguments.append("--ui-slow-metadata") }
        if communityUnavailable { app.launchArguments.append("--ui-community-unavailable") }
        if cachedSnapshot { app.launchArguments.append("--ui-cached-snapshot") }
        if longEpisodes { app.launchArguments.append("--ui-long-episodes") }
        if automaticCarousel { app.launchArguments.append("--ui-automatic-carousel") }
        if let traktScenario { app.launchArguments.append("--ui-trakt=" + traktScenario) }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        let home = app.tabBars.buttons["Home"]
        if !home.waitForExistence(timeout: 15) { print("Native tab launch hierarchy: " + String(app.debugDescription.prefix(18000))) }
        XCTAssertTrue(home.exists); return app
    }
    func testCachedDiaryStatusDoesNotCoverScreensAndRemainsAvailableInSettings() {
        let app = launch(cachedSnapshot: true)
        let warning = "Your diary is loaded, but its protected offline copy could not be updated."
        for tab in ["home", "library", "glance", "stats"] {
            app.tabBars.buttons[tab.capitalized].tap()
            XCTAssertFalse(app.staticTexts["Saved diary"].exists)
            XCTAssertFalse(app.staticTexts[warning].exists)
        }
        app.tabBars.buttons["Glance"].tap(); capture("Glance without saved-diary status overlay")
        app.tabBars.buttons["More"].tap()
        let storage = app.buttons["settings-refresh-diary"]
        for _ in 0..<10 { if storage.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(storage.isHittable)
        XCTAssertTrue(storage.label.contains("Saved copy"))
        XCTAssertTrue(app.staticTexts["settings-cache-warning"].exists)
        capture("Cache information contained in Settings")
    }
    func testContinueCarouselSwipesAndRestoresAcrossTabsWithoutOverflowMenu() {
        let app = launch()
        app.tabBars.buttons["Home"].tap()
        let carousel = app.descendants(matching: .any).matching(identifier: "continue-carousel").firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["continue-controls"].exists)
        guard let original = carousel.value as? String, !original.isEmpty else { XCTFail("Carousel has no selected title"); return }
        carousel.swipeLeft()
        expectation(for: NSPredicate(format: "value != nil AND value != %@ AND value != ''", original), evaluatedWith: carousel)
        waitForExpectations(timeout: 5)
        assertContinueCardIsFullyVisible(app)
        XCTAssertFalse(app.buttons["title-personal-rating"].exists)
        let advanced = carousel.value as? String
        app.tabBars.buttons["More"].tap(); app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(carousel.value as? String, advanced)
        carousel.swipeRight()
        expectation(for: NSPredicate(format: "value == %@", original), evaluatedWith: carousel)
        waitForExpectations(timeout: 5)
        assertContinueCardIsFullyVisible(app)
        capture("Continuation carousel swipes without overflow menu")
    }
    private func assertContinueCardIsFullyVisible(_ app: XCUIApplication) {
        let visible = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "progress-cover-")).allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(visible.count, 1, "Only the selected continuation card should be an active visible cover")
        guard let cover = visible.first else { return }
        XCTAssertGreaterThanOrEqual(cover.frame.minX, app.frame.minX + 8)
        XCTAssertLessThanOrEqual(cover.frame.maxX, app.frame.maxX - 8)
    }
    func testNativeTabsAndTitleNavigation() {
        let app = launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '% complete'")).firstMatch.waitForExistence(timeout: 5))
        capture("Glance")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5)); capture("Home")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Search library"].waitForExistence(timeout: 5)); capture("Library")
        XCTAssertEqual(app.tabBars.count, 1, "The system Liquid Glass tab bar must be the only tab bar")
        let first = app.buttons["title-after-rain"].frame, second = app.buttons["title-again"].frame, third = app.buttons["title-frieren"].frame
        XCTAssertLessThan(first.maxX, second.minX)
        XCTAssertLessThan(second.maxX, third.minX)
        XCTAssertLessThanOrEqual(third.maxX, app.frame.width - 10)
        app.buttons["title-again"].tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        let track = app.sliders["episode-progress"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        XCTAssertEqual(track.value as? String, "8 of 16 episodes watched")
        capture("Title detail")
        assertEpisodePieces(track, app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["title-quiet-orbit"].tap()
        XCTAssertTrue(app.progressIndicators["movie-progress"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["episode-progress"].exists)
        capture("Movie detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Watch time"].waitForExistence(timeout: 5)); capture("Stats")
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5)); capture("More")
    }
    func testSideSwipesChangeCategoriesNotTabsAndKeepCardGestures() {
        let app = launch(mutations: true)
        // `advance` moves forward like a page view: the finger travels left, on plain content.
        func swipe(_ advance: Bool, at fraction: CGFloat) {
            let y = app.frame.height * fraction
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * (advance ? 0.8 : 0.2), dy: y))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * (advance ? 0.2 : 0.8), dy: y))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        func expectCategory(_ name: String) {
            let chip = app.buttons["category-" + name]
            wait(for: [expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: chip)], timeout: 5)
            XCTAssertTrue(app.tabBars.buttons["Library"].isSelected, "A side swipe must never change app tabs")
        }
        // Home has no categories: a side swipe leaves it where it is.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["random-pick-logo"].waitForExistence(timeout: 5))
        swipe(true, at: 0.68)
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected, "Home must not page to Library")
        // Library: All → Movies → Shows, then back to Movies; the tab stays Library throughout.
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["category-all"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["category-all"].isSelected)
        swipe(true, at: 0.62); expectCategory("movies")
        swipe(true, at: 0.62); expectCategory("shows")
        swipe(false, at: 0.62); expectCategory("movies")
        capture("Side swipes move between Library categories")
        app.buttons["category-all"].tap()
        app.tabBars.buttons["Glance"].tap()
        let count = app.staticTexts["watch-count-again"]
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 5)
        // Cards keep their own buttons: the mark button logs exactly one watch and
        // Undo restores it on the same tab.
        app.buttons["Mark next watch for 18 Again"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '9 / 16'"), evaluatedWith: count)], timeout: 8)
        XCTAssertTrue(app.tabBars.buttons["Glance"].isSelected, "Marking a watch must not change tabs")
        app.buttons["Undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 8)
        capture("Glance mark and Undo stay on the Glance tab")
    }
    func testApprovedLargeTraktImportKeepsRunningAcrossNativeTabsAndOffersPause() {
        let app = launch(traktScenario: "large-import")
        app.tabBars.buttons["More"].tap(); openTrakt(app)
        let apply = app.buttons["trakt-apply-ready"]
        for _ in 0..<16 { if apply.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(apply.isHittable); apply.tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5))
        app.tabBars.buttons["More"].tap()
        let counts = app.staticTexts["trakt-apply-counts"]
        for _ in 0..<16 { if counts.isHittable { break }; app.swipeDown() }
        let progressed = NSPredicate { _, _ in counts.exists && !counts.label.hasPrefix("0 saved") }
        wait(for: [expectation(for: progressed, evaluatedWith: counts)], timeout: 10)
        let pause = app.buttons["trakt-pause-import"]
        XCTAssertTrue(pause.isHittable); XCTAssertTrue(pause.isEnabled)
        XCTAssertTrue(app.progressIndicators["trakt-apply-progress"].exists)
        capture("Approved Trakt import continues across native tabs with global percentage")
        pause.tap()
        let resume = app.buttons["trakt-resume-import"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        let pausedCount = counts.label
        app.tabBars.buttons["Home"].tap(); app.tabBars.buttons["More"].tap()
        XCTAssertEqual(counts.label, pausedCount)
        capture("Explicit import pause retains completed work and resume action")
    }
    func testColdQuotaImportRestoresAcrossTabsAfterResetWithoutManualRetry() {
        let app = launch(traktScenario: "cold-quota")
        app.tabBars.buttons["More"].tap(); openTrakt(app)
        XCTAssertTrue(app.staticTexts["Restoring approved import"].waitForExistence(timeout: 8))
        let restorationPause = app.buttons["trakt-pause-restoration"]
        guard restorationPause.waitForExistence(timeout: 8) else {
            capture("Cold quota restoration missing Pause control")
            print("Cold quota restoration hierarchy: " + String(app.debugDescription.prefix(18000)))
            XCTFail("The restoration panel must expose its own Pause button"); return
        }
        XCTAssertTrue(restorationPause.isEnabled); XCTAssertTrue(restorationPause.isHittable)
        XCTAssertFalse(app.progressIndicators["trakt-apply-progress"].exists, "No invented percentage before review loads")
        capture("Cold quota restoration waits without a fake percentage")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5))
        app.tabBars.buttons["More"].tap()
        let counts = app.staticTexts["trakt-apply-counts"]
        let progressed = NSPredicate { _, _ in counts.exists && !counts.label.hasPrefix("0 saved") }
        wait(for: [expectation(for: progressed, evaluatedWith: counts)], timeout: 35)
        let pause = app.buttons["trakt-pause-import"]
        for _ in 0..<8 { if pause.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(pause.isHittable); pause.tap()
        XCTAssertTrue(app.buttons["trakt-resume-import"].waitForExistence(timeout: 8))
        capture("Cold quota import restores automatically and still supports explicit Pause")
    }
    func testTraktComparisonShowsFiniteRecordsAndStopsWithoutPartialApplyActions() {
        let app = launch(traktScenario: "comparing")
        app.tabBars.buttons["More"].tap(); openTrakt(app)
        let progress = app.staticTexts["trakt-scan-progress-detail"]
        for _ in 0..<6 { if progress.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(progress.exists); XCTAssertEqual(progress.label, "480 of 2,185 records compared")
        // A connected account mid-scan never offers to connect again.
        XCTAssertFalse(app.buttons["Connect Trakt"].exists)
        let stop = app.buttons["trakt-stop-manual-scan"]
        for _ in 0..<5 { if stop.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(stop.isEnabled)
        XCTAssertFalse(app.buttons["trakt-apply-ready"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'trakt-skip-' OR identifier BEGINSWITH 'trakt-apply-' ")).count, 0)
        capture("Manual comparison counts records instead of pages")
        stop.tap()
        let stopped = app.staticTexts["Scan stopped. Scan again when you’re ready to continue."]
        for _ in 0..<6 { if stopped.exists { break }; app.swipeUp() }
        XCTAssertTrue(stopped.waitForExistence(timeout: 5)); capture("Manual comparison stopped without applying")
    }
    func testCommunityInformationSheetUsesOverallStatsAndReturnsToTheTitle() {
        let app = launch(titleMetadata: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let information = app.buttons["title-information"]
        XCTAssertTrue(information.waitForExistence(timeout: 5)); information.tap()
        XCTAssertTrue(app.staticTexts["Community stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What people are saying"].exists)
        let positive = app.descendants(matching: .any)["community-positive-0"]
        let negative = app.descendants(matching: .any)["community-negative-0"]
        capture("Community information content before accessibility checks")
        if !positive.exists || !negative.exists { print("Community fixture hierarchy: " + String(app.debugDescription.prefix(22000))) }
        XCTAssertTrue(positive.exists); XCTAssertEqual(positive.label, "Positive: Engaging pacing and mysteries")
        XCTAssertTrue(negative.exists); XCTAssertEqual(negative.label, "Negative: Repetitive storyline")
        XCTAssertFalse(app.buttons["title-personal-rating"].isHittable)
        capture("Trakt community information fixture")
        // The sheet uses a fixed heading instead of a navigation bar, so its title
        // no longer fades across detents while dragging.
        let sheetBar = app.staticTexts["community-information-heading"]
        XCTAssertTrue(sheetBar.isHittable)
        sheetBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheetBar)
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(information.waitForExistence(timeout: 5)); XCTAssertTrue(information.isHittable)
        XCTAssertEqual(app.sliders["episode-progress"].value as? String, "8 of 16 episodes watched")
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["title-quiet-orbit"].tap()
        app.buttons["title-information"].tap()
        XCTAssertTrue(app.staticTexts["Match this title to TMDB to see its community information."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["community-positive-0"].exists)
        capture("Community information unmatched title")
    }
    func testCommunityUnavailableOffersRetryWithoutInventingCountsOrSentiments() {
        let app = launch(titleMetadata: true, communityUnavailable: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        app.buttons["title-information"].tap()
        XCTAssertTrue(app.staticTexts["Trakt’s community stats are temporarily unavailable."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Trakt’s community sentiment summary is temporarily unavailable."].exists)
        XCTAssertFalse(app.descendants(matching: .any)["community-positive-0"].exists)
        let retry = app.buttons["Retry community information"]
        XCTAssertTrue(retry.exists); retry.tap()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: retry)], timeout: 5)
        capture("Community information unavailable with honest retry")
    }
    func testEmptyDiaryScreensRetainNavigationAndSourceEmptyStates() {
        let app = launch(empty: true)
        XCTAssertTrue(app.staticTexts["A clear little corner"].waitForExistence(timeout: 5)); capture("Empty Glance")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Continue watching"].exists); XCTAssertFalse(app.staticTexts["Recently watched"].exists)
        XCTAssertTrue(app.staticTexts["0m"].exists); capture("Empty Home")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Nothing here just yet"].waitForExistence(timeout: 5)); capture("Empty Library")
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Log a movie or episode to start your stats."].waitForExistence(timeout: 5)); capture("Empty Stats")
        XCTAssertTrue(app.buttons["7D"].isHittable)
    }

    func testUpcomingEpisodeOpensItsLinkedSeasonAndEpisodesWithoutChangingOrdinaryTitleNavigation() {
        let app = launch(upcoming: true); app.tabBars.buttons["Home"].tap()
        let upcoming = app.buttons["home-upcoming-again"]
        for _ in 0..<12 { if upcoming.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(upcoming.isHittable); capture("Home upcoming later season"); upcoming.tap()
        let season = app.buttons["title-season"]
        XCTAssertTrue(season.waitForExistence(timeout: 10)); XCTAssertEqual(season.value as? String, "Season 2")
        XCTAssertTrue(season.isHittable, "Upcoming navigation must land at Episodes, as the web hash link does")
        XCTAssertTrue(app.buttons["title-episode-1"].isHittable); capture("Upcoming linked season Episodes")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        for _ in 0..<8 { if season.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(season.isHittable); XCTAssertEqual(season.value as? String, "Season 1")
    }

    func testCanvasShowsAMosaicForTitlesAndCollagesForTraktLists() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let canvas = app.buttons["canvas-shortcut"]
        for _ in 0..<4 { if canvas.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(canvas.isHittable); XCTAssertTrue(app.buttons["explore-shortcut"].isHittable)
        capture("Home Explore and Canvas buttons"); canvas.tap()
        XCTAssertTrue(app.buttons["canvas-tab-movies"].waitForExistence(timeout: 5))
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'canvas-tile-'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["canvas-sort"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["canvas-genre"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["canvas-network"].exists, "Networks are for shows only")
        // The first tile is a wide hero across the page; the next row holds three posters.
        let hero = tiles.element(boundBy: 0), poster = tiles.element(boundBy: 1)
        XCTAssertGreaterThan(hero.frame.width, app.frame.width * 0.85)
        XCTAssertLessThan(poster.frame.width, app.frame.width * 0.4)
        capture("Canvas Movies mosaic")
        app.buttons["canvas-tab-shows"].tap()
        XCTAssertTrue(app.buttons["canvas-network"].waitForExistence(timeout: 5)); capture("Canvas Shows with Networks")
        app.buttons["canvas-tab-lists"].tap()
        let list = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'canvas-list-'")).matching(NSPredicate(format: "identifier != 'canvas-list-sort' AND identifier != 'canvas-list-kind'")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["canvas-list-sort"].exists)
        capture("Canvas Lists collages"); list.tap()
        XCTAssertTrue(app.staticTexts["by preview1"].waitForExistence(timeout: 5))
        capture("Canvas list titles")
    }
    func testRandomPickKeepsPlannedScopeAndLogoRerollsWithoutRepeating() throws {
        try XCTSkipIf(true, "Home's Pick for me button is not in the owner's Home design; skipped until the owner decides where it goes")
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let planned = app.buttons["home-pick-planned"]
        func revealPlanned() {
            // A partially visible row can be AX-hittable while its lower part
            // sits beneath the floating navigation bar. Reveal the whole action.
            for _ in 0..<8 {
                if planned.isHittable && planned.frame.minY > 120 && planned.frame.maxY < app.tabBars.buttons["Home"].frame.minY - 8 { break }
                guard planned.exists else { app.swipeUp(); continue }
                // A full-screen flick overshoots this nearby row and bounces
                // between above/below the viewport. Stop a short, real scroll
                // before release so momentum cannot move the target away.
                let navigationTop = app.tabBars.buttons["Home"].frame.minY
                let down = planned.frame.minY < 120
                let distance = min(CGFloat(150), max(CGFloat(45), down ? 144 - planned.frame.minY : planned.frame.maxY - navigationTop + 32))
                let startY = down ? CGFloat(160) : navigationTop - 40
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 8, dy: startY))
                let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 8, dy: startY + (down ? distance : -distance)))
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            XCTAssertTrue(planned.isHittable)
            XCTAssertLessThan(planned.frame.maxY, app.tabBars.buttons["Home"].frame.minY - 8)
        }
        revealPlanned(); planned.tap()
        let name = app.staticTexts["random-picked-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); XCTAssertEqual(name.label, "A Quiet Orbit")
        let dialog = app.descendants(matching: .any)["random-pick-dialog"]
        XCTAssertTrue(dialog.exists, app.debugDescription); XCTAssertLessThan(dialog.frame.height, app.frame.height * 0.75)
        XCTAssertGreaterThan(dialog.frame.minY, 70)
        XCTAssertFalse(app.buttons["random-pick-again"].isEnabled, "The planned fixture has only one eligible title")
        capture("Home planned random pick")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["random-pick-open"].exists, "A background tap must keep Surprise open")
        dialog.swipeUp()
        XCTAssertFalse(app.buttons["Close random pick"].exists)
        revealPlanned(); planned.tap(); XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["random-pick-dialog"].swipeDown()
        XCTAssertFalse(app.buttons["Close random pick"].exists)
        let logo = app.buttons["random-pick-logo"]
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dialog)], timeout: 5)
        wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: logo)], timeout: 5)
        logo.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(name.waitForExistence(timeout: 5)); let previous = name.label
        let again = app.buttons["random-pick-again"]
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: again)], timeout: 5)
        again.tap()
        wait(for: [expectation(for: NSPredicate(format: "label != %@", previous), evaluatedWith: name)], timeout: 5)
        capture("Collection random pick")
        app.buttons["random-pick-open"].tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Close random pick"].exists)
    }
    func testEmptyRandomPickOpensTheWorkingAddSearch() {
        let app = launch(empty: true)
        app.buttons["random-pick-logo"].tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(app.staticTexts["Your next story starts here"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["random-pick-open"].exists); capture("Empty collection random pick")
        app.buttons["Add a title"].tap()
        XCTAssertTrue(app.textFields["Search library and online"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add manually"].exists); capture("Library catalog-only add search")
        app.buttons["Close search"].tap()
        XCTAssertTrue(app.staticTexts["Nothing here just yet"].waitForExistence(timeout: 5))
    }

    func testHistoryUnknownDatesSearchPagingAndReturnKeepTheSourceFilters() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let history = app.buttons["All history →"]
        for _ in 0..<12 { if history.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        let count = app.staticTexts["history-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); capture("History first page")
        app.buttons["Date filters"].tap()
        let unknown = app.switches["Unknown dates only"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 5)); unknown.tap()
        XCTAssertEqual(count.label, "1 watch")
        XCTAssertTrue(app.staticTexts["Watch date unknown"].waitForExistence(timeout: 5)); capture("History unknown dates")
        app.buttons["Clear filters"].tap()
        let search = app.textFields["Filter watch history"]
        search.tap(); search.typeText("Ｆｒｉｅｒｅｎ\n")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'")).firstMatch.waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'")).firstMatch
        XCTAssertTrue(row.label.contains("Frieren")); row.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(search.value as? String, "Ｆｒｉｅｒｅｎ")
        XCTAssertEqual(unknown.value as? String, "0"); capture("History retained search")
        app.buttons["Clear filters"].tap()
        let more = app.buttons["history-load-more"]
        for _ in 0..<12 { if more.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(more.isHittable); let before = more.label; more.tap()
        XCTAssertTrue(!more.exists || more.label != before, "Paging must reveal the next twelve watches")
        capture("History expanded page")
    }

    func testMoreTraktSummaryUsesConnectionAndScanStateInsteadOfStaleCounts() {
        for (scenario, badge) in [("disconnected", "Not connected"), ("reconnect", "Reconnect"), ("scanning", "Connected"), ("unavailable", "Unavailable")] {
            let app = launch(traktScenario: scenario); app.tabBars.buttons["More"].tap()
            let row = app.buttons["settings-trakt"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", badge), evaluatedWith: row)], timeout: 5)
            XCTAssertFalse(app.staticTexts["8 changes to review"].exists)
            capture("More Trakt " + scenario); app.terminate()
        }
    }


    func testLibrarySearchAndSelectionPersistAcrossTabs() {
        let app = launch()
        app.tabBars.buttons["Library"].tap(); app.buttons["Search library"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["search-library-frieren"].exists); XCTAssertFalse(app.buttons["search-library-again"].exists)
        capture("Library search")
        app.tabBars.buttons["Home"].tap(); app.tabBars.buttons["Library"].tap()
        XCTAssertEqual(search.value as? String, "Frieren")
        app.buttons["Close search"].tap(); app.buttons["List layout"].tap(); capture("Library list")
        app.buttons["Genre sections"].tap(); capture("Library genres")
    }
    func testLibraryStatusChipsAndFilterSheetComposeThenClearTogether() {
        let app = launch(); app.tabBars.buttons["Library"].tap()
        let watching = app.buttons["library-status-watching"]
        XCTAssertTrue(watching.waitForExistence(timeout: 5)); XCTAssertEqual(watching.value as? String, "4 titles"); watching.tap()
        app.buttons["library-filters"].tap()
        let romance = app.buttons["filter-genre-Romance"]
        XCTAssertTrue(romance.waitForExistence(timeout: 5)); romance.tap()
        let toshiba = app.buttons["E: Toshiba (4TB)"]
        for _ in 0..<5 { if toshiba.isHittable { break }; scrollSheet(app) }
        toshiba.tap()
        XCTAssertTrue(app.buttons["filter-show"].label.hasPrefix("Show 1 title")); capture("Library filter sheet")
        // Pulled up by its top, the whole board shows (it used to stay at half height and only scroll).
        // Build #32: a drag on the chips scrolls them instead, so this pulls the Filters bar.
        let board = app.navigationBars["Filters"]
        XCTAssertTrue(board.waitForExistence(timeout: 5))
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.06)))
        for _ in 0..<10 where board.frame.minY >= app.frame.height * 0.2 { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertLessThan(board.frame.minY, app.frame.height * 0.2, "The filter sheet pulls up to full height"); capture("Library filter sheet full height")
        app.buttons["filter-show"].tap()
        XCTAssertTrue(app.buttons["title-night"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["title-again"].exists); XCTAssertFalse(app.buttons["title-frieren"].exists)
        XCTAssertEqual(app.buttons["library-filters"].value as? String, "2 active"); capture("Library composed filters")
        tapStatusChip(app, "dropped")
        XCTAssertTrue(app.staticTexts["No titles match"].waitForExistence(timeout: 5)); capture("Library filters match nothing")
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(app.buttons["title-again"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["title-frieren"].exists)
        XCTAssertEqual(app.buttons["library-filters"].value as? String, "None")
        XCTAssertEqual(app.buttons["library-layout"].value as? String, "Grid"); XCTAssertTrue(app.buttons["List layout"].exists)
        capture("Library filters cleared")
    }
    func testOpensOnSettingChoosesTheTabAFreshLaunchStartsOn() {
        let app = launch(); app.tabBars.buttons["More"].tap()
        let picker = app.buttons["settings-launch-tab"]
        for _ in 0..<6 { if picker.exists && picker.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(picker.isHittable); XCTAssertEqual(picker.value as? String, "Glance")
        picker.tap()
        // The menu's Library, not the tab bar's.
        let option = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Library", "tab-library")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        XCTAssertEqual(picker.value as? String, "Library"); capture("Settings opens on Library")
        app.launchArguments.append("--ui-keep-launch-tab")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["library-order"].waitForExistence(timeout: 15), "A fresh launch starts on Library")
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
    }
    func testT31LibraryLayoutAndSortSurviveAProcessRelaunch() {
        let app = launch(); app.tabBars.buttons["Library"].tap()
        app.buttons["List layout"].tap()
        app.buttons["library-order"].tap(); app.buttons["Highest TMDB rating"].tap()
        XCTAssertEqual(app.buttons["library-layout"].value as? String, "List")
        app.launchArguments.append("--ui-keep-library-preferences")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15)); app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["library-layout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["library-layout"].value as? String, "List")
        XCTAssertEqual(app.buttons["library-order"].value as? String, "Highest TMDB rating")
        capture("Library persisted list layout and typed rating order after relaunch")
    }
    func testT35WatchedEpisodeOffersRewatchAndUndoKeepsItsOriginalWatch() {
        let app = launch(mutations: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let episode = app.buttons["title-episode-8"]
        for _ in 0..<7 {
            if episode.exists, episode.isHittable {
                if episode.frame.minY > 120, episode.frame.maxY < app.frame.maxY - 40 { break }
                if episode.frame.minY <= 120 { episode.swipeDown() } else { episode.swipeUp() }
            } else { app.swipeUp() }
        }
        XCTAssertTrue(episode.isHittable); XCTAssertGreaterThan(episode.frame.minY, 120); XCTAssertLessThan(episode.frame.maxY, app.frame.maxY - 40)
        episode.tap()
        XCTAssertTrue(app.staticTexts["episode-summary-8"].waitForExistence(timeout: 5))
        let rewatch = app.buttons["episode-rewatch-8"]
        XCTAssertTrue(rewatch.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if rewatch.isHittable, rewatch.frame.maxY < app.frame.maxY - 40 { break }
            app.swipeUp()
        }
        XCTAssertTrue(rewatch.isHittable); XCTAssertLessThan(rewatch.frame.maxY, app.frame.maxY - 40)
        capture("Visible watched episode rewatch action")
        rewatch.tap()
        // The helper itself waits for the toast; a separate existence query here
        // spent ~1.8 s of the 4.5 s Undo window on Intel runners.
        tapVisibleUndo(app)
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["undo-action"])], timeout: 8)
        XCTAssertTrue(app.buttons["Mark episode 8 unwatched"].exists, "Undoing the rewatch must keep the original watch")
        // Detail pages hide the tab bar: go back until it shows (one tap can land mid-animation).
        let more = app.tabBars.buttons["More"]
        for _ in 0..<3 where !more.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap(); app.buttons["settings-history"].tap()
        let filter = app.textFields["Filter watch history"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap(); filter.typeText("18 Again\n")
        XCTAssertEqual(app.staticTexts["history-count"].label, "8 watches", "Undo must remove the extra play, not merely keep the original episode checked")
        capture("Episode rewatch Undo restores the original eight history entries")
    }

    func testLibraryCommunityRatingPreferenceNeverDisplaysPersonalScores() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let picker = app.buttons["settings-rating-source"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap(); app.buttons["Trakt"].tap()
        app.tabBars.buttons["Library"].tap()
        let title = app.buttons["title-again"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue((title.value as? String)?.contains("Rating 7.7") == true)
        XCTAssertFalse((title.value as? String)?.contains("Rating 7.5") == true)
        capture("Library Trakt community ratings")
        app.buttons["List layout"].tap()
        XCTAssertTrue((title.value as? String)?.contains("Rating 7.7") == true)
        XCTAssertFalse((title.value as? String)?.contains("Rating 7.5") == true)
        capture("Library list Trakt community ratings")
        app.tabBars.buttons["More"].tap(); picker.tap(); app.buttons["TMDB"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertFalse((title.value as? String)?.contains("Rating") == true, "This fixture has no TMDB score; its personal rating must not substitute")
        capture("Library TMDB missing scores")
    }
    func testUnavailableCommunityScoresKeepLibraryUsableAndCanSwitchBack() {
        let app = launch(ratingsUnavailable: true)
        app.tabBars.buttons["More"].tap()
        let picker = app.buttons["settings-rating-source"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap(); app.buttons["Trakt"].tap()
        app.tabBars.buttons["Library"].tap()
        let message = app.staticTexts["Some Trakt ratings are unavailable."]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["title-again"].isHittable)
        XCTAssertFalse((app.buttons["title-again"].value as? String)?.contains("Rating") == true)
        XCTAssertTrue(app.buttons["ratings-retry"].exists); app.buttons["ratings-retry"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5)); capture("Library community ratings unavailable")
        app.tabBars.buttons["More"].tap(); picker.tap(); app.buttons["TMDB"].tap()
        app.tabBars.buttons["Library"].tap(); XCTAssertFalse(message.exists)
    }
    func testCatalogSearchReviewAndCastProfile() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Search'")).count, 1, "Inactive tabs must not expose controls to VoiceOver")
        app.buttons["search-twildiary"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Clockmaker\n")
        let result = app.buttons["search-movie:900001"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); capture("Catalog search"); result.tap()
        XCTAssertTrue(app.buttons["Add to Planned"].waitForExistence(timeout: 10)); capture("Catalog review")
        let actor = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Reference Actor 1'")).firstMatch
        if !actor.isHittable { app.swipeUp() }
        XCTAssertTrue(actor.waitForExistence(timeout: 5)); actor.tap()
        XCTAssertTrue(app.staticTexts["Facts & trivia"].waitForExistence(timeout: 10)); capture("Cast profile")
    }
    func testSavedEpisodeRevealPersistsAfterCollapseWithoutRevealingOtherRows() {
        let app = launch(); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let episode = app.buttons["title-episode-9"]
        for _ in 0..<8 { if episode.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(episode.isHittable); XCTAssertEqual(episode.value as? String, "A story for later")
        // Episode tiles are taller now; nudge the lazy grid until the next one is created too.
        let tenth = app.buttons["title-episode-10"]
        if !tenth.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))) }
        XCTAssertTrue(tenth.waitForExistence(timeout: 5)); XCTAssertTrue(episode.isHittable)
        episode.tap()
        XCTAssertEqual(episode.value as? String, "Episode 9"); capture("Title revealed episode")
        episode.tap()
        XCTAssertEqual(episode.value as? String, "Episode 9", "Collapsing a revealed synopsis must not hide its title again")
        XCTAssertEqual(app.buttons["title-episode-10"].value as? String, "A story for later", "A season metadata response must not reveal unselected rows")
        capture("Title revealed episode collapsed")
    }

    func testCatalogSearchOmitsManualCreationEverywhere() {
        let app = launch(mutations: true)
        app.tabBars.buttons["Home"].tap(); app.buttons["search-twildiary"].tap()
        XCTAssertTrue(app.textFields["Search library and online"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add manually"].exists)
        XCTAssertFalse(app.buttons["manual-save"].exists)
        app.tabBars.buttons["Library"].tap(); app.buttons["search-library"].tap()
        XCTAssertFalse(app.buttons["Add manually"].exists)
        app.tabBars.buttons["Glance"].tap(); app.buttons["search-glance"].tap()
        XCTAssertFalse(app.buttons["Add manually"].exists)
        capture("Native searches expose catalog import without manual creation")
    }

    func testCatalogSeriesSeasonsSpoilersAndImport() {
        let app = launch(mutations: true); app.tabBars.buttons["Home"].tap(); app.buttons["search-twildiary"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Quiet Journey\n")
        let result = app.buttons["search-tv:900002"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        XCTAssertTrue(app.buttons["catalog-add"].waitForExistence(timeout: 10)); capture("Catalog series hero")
        let season = app.buttons["catalog-season"]
        for _ in 0..<6 { if season.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(season.isHittable)
        let first = app.buttons["catalog-episode-1"]
        for _ in 0..<6 { if first.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(first.waitForExistence(timeout: 5)); capture("Catalog spoiler-safe episodes")
        first.tap(); XCTAssertTrue(app.staticTexts["Reference episode summary."].waitForExistence(timeout: 5)); capture("Catalog revealed episode")
        // Details open in the same sheet as a saved title's episodes.
        app.buttons["Done"].tap(); XCTAssertTrue(season.waitForExistence(timeout: 5))
        season.tap(); app.buttons["Season 2"].tap()
        XCTAssertTrue(app.buttons["catalog-episode-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Reference episode summary."].exists, "Expansion state must reset on season change")
        capture("Catalog second season")
        let showAll = app.buttons["Show all 12 episodes"]
        for _ in 0..<6 { if showAll.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(showAll.isHittable); showAll.tap()
        let last = app.buttons["catalog-episode-12"]
        for _ in 0..<8 { if last.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(last.isHittable); capture("Catalog all episodes")
        let add = app.buttons["catalog-add"]
        for _ in 0..<12 { if add.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(add.isHittable); add.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["title-personal-rating"].value as? String, "Not rated")
        XCTAssertTrue(app.buttons["title-watch-status"].exists)
        let importedTrack = app.sliders["episode-progress"]
        XCTAssertTrue(importedTrack.waitForExistence(timeout: 10)); XCTAssertEqual(importedTrack.value as? String, "0 of 12 episodes watched")
        capture("Catalog imported title")
    }

    func testExploreAndHomeStatsShortcut() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let explore = app.buttons["explore-shortcut"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5)); explore.tap()
        XCTAssertTrue(app.buttons["explore-daily-pick"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Highest rated shows"].exists); capture("Explore")
        let more = app.buttons["explore-more-rated-shows"]
        if !more.isHittable { app.swipeUp() }
        XCTAssertTrue(more.isHittable); more.tap()
        XCTAssertTrue(app.staticTexts["Highest rated shows"].waitForExistence(timeout: 5)); capture("Explore rated shows")
        let minimum = app.buttons["explore-minimum"]
        XCTAssertTrue(minimum.waitForExistence(timeout: 5)); minimum.tap(); app.buttons["9+"].tap()
        XCTAssertTrue(app.staticTexts["No titles in this mix"].waitForExistence(timeout: 5)); capture("Explore filtered empty")
        app.buttons["Reset filters"].tap()
        XCTAssertTrue(app.staticTexts["12 titles"].waitForExistence(timeout: 5))
        let loadMore = app.buttons["Load more"]
        for _ in 0..<10 { if loadMore.isHittable && loadMore.frame.maxY < app.tabBars.buttons["Home"].frame.minY { break }; app.swipeUp() }
        XCTAssertTrue(loadMore.isHittable); XCTAssertLessThan(loadMore.frame.maxY, app.tabBars.buttons["Home"].frame.minY); capture("Explore Load more reachable"); loadMore.tap()
        let lastResult = app.buttons["catalog-tv:900002"]
        for _ in 0..<8 { if lastResult.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lastResult.isHittable, "The second page must publish its final unique result")
        capture("Explore second page")
        let count = app.staticTexts["16 titles"]
        for _ in 0..<12 { if count.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(count.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["explore-daily-pick"].waitForExistence(timeout: 5))
    }
    func testHomeStatsUsesTodayAndKeepsTheOriginalRangeBar() {
        let app = launch(); app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.buttons["30D"].waitForExistence(timeout: 5))
        app.buttons["1Y"].tap()
        XCTAssertTrue(app.buttons["1Y"].isSelected)
        capture("Stats year")
        assertRangeHighlight(app.buttons["1Y"], app: app)
        app.tabBars.buttons["Home"].tap()
        app.buttons["home-stats"].tap()
        XCTAssertTrue(app.staticTexts["Today"].exists || app.buttons.containing(NSPredicate(format: "label CONTAINS 'Today'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["7D"].exists)
        XCTAssertTrue(app.buttons["90D"].exists)
        XCTAssertFalse(app.buttons["1Y"].isSelected)
        capture("Stats from Home")
    }
    func testCloudflareUsageShowsTodayAndDailyChartsFromSettings() {
        let app = launch(); app.tabBars.buttons["More"].tap()
        let row = app.buttons["settings-cloudflare"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<8 { if row.isHittable { break }; app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Cloudflare"].waitForExistence(timeout: 10))
        for key in ["requests", "reads", "writes", "storage"] { XCTAssertTrue(app.descendants(matching: .any)["cloudflare-today-\(key)"].waitForExistence(timeout: 5), key) }
        XCTAssertTrue(app.descendants(matching: .any)["cloudflare-reset"].exists)
        capture("Cloudflare usage today")
        let range = app.segmentedControls["cloudflare-range"]
        for _ in 0..<4 { if range.isHittable { break }; app.swipeUp() }
        range.buttons["30 days"].tap()
        let reads = app.descendants(matching: .any)["cloudflare-chart-reads"]
        for _ in 0..<4 { if reads.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reads.waitForExistence(timeout: 5)); XCTAssertTrue(reads.label.contains("Peak 4.5M"), reads.label)
        capture("Cloudflare usage 30 days")
    }
    func testAPIsShowKeyEndingsReplaceAndTestAndJellyfinMapsOnlyMoviesAndShows() {
        let app = launch(); app.tabBars.buttons["More"].tap()
        let row = app.buttons["settings-apis"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<8 { if row.isHittable { break }; app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["APIs"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["••••Q2xk"].waitForExistence(timeout: 5), "Only the last four characters are shown")
        XCTAssertTrue(app.staticTexts["Saved here"].exists); XCTAssertTrue(app.staticTexts["Not set"].exists)
        capture("APIs")
        app.buttons["api-replace-TMDB_ACCESS_TOKEN"].tap()
        let field = app.secureTextFields["api-key-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("eyJhbGciOiJIUzI1NiJ9.new-token-ZZ91")
        capture("APIs replace key")
        app.buttons["api-key-save"].tap()
        XCTAssertTrue(app.staticTexts["••••ZZ91"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["api-status-TMDB_ACCESS_TOKEN"].waitForExistence(timeout: 5))
        let jellyfin = app.buttons["jellyfin-setup"]
        for _ in 0..<6 { if jellyfin.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(jellyfin.isHittable); capture("APIs Jellyfin and server")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let files = app.buttons["settings-files"]
        for _ in 0..<8 { if files.isHittable { break }; app.swipeDown() }
        files.tap()
        let card = app.descendants(matching: .any)["jellyfin-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["jellyfin-library-movies"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["jellyfin-library-shows"].isSelected)
        XCTAssertFalse(app.buttons["jellyfin-library-photos"].exists, "Photos and home videos are never offered")
        app.buttons["jellyfin-sync"].tap()
        XCTAssertTrue(app.staticTexts["jellyfin-summary"].waitForExistence(timeout: 5))
        capture("Files Jellyfin synced")
        // The Jellyfin page: everything on Jellyfin, filtered by the diary and by drive.
        app.buttons["jellyfin-browse"].tap()
        XCTAssertTrue(app.staticTexts["jellyfin-library-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["jellyfin-item-j-arrival"].exists); XCTAssertTrue(app.buttons["jellyfin-item-j-frieren"].exists)
        capture("Jellyfin page")
        app.buttons["jellyfin-show-missing"].tap()
        XCTAssertTrue(app.buttons["jellyfin-item-j-arrival"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["jellyfin-item-j-frieren"].exists, "In-diary titles leave Not in diary")
        app.buttons["jellyfin-show-all"].tap()
        app.buttons["jellyfin-drive-D:"].tap()
        XCTAssertTrue(app.buttons["jellyfin-item-j-severance"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["jellyfin-item-j-arrival"].exists, "A drive filter keeps only that drive")
        capture("Jellyfin page drive filter")
        // Library's Jellyfin chip (before Queue): everything on Jellyfin, from the saved list: the
        // diary titles, then the ones not in the diary.
        let library = app.tabBars.buttons["Library"]
        for _ in 0..<3 where !library.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        tapStatusChip(app, "jellyfin")
        XCTAssertTrue(app.buttons["title-frieren"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["title-severance"].exists)
        XCTAssertFalse(app.buttons["title-quiet-orbit"].exists, "Titles not on Jellyfin leave the Jellyfin chip")
        XCTAssertEqual(app.buttons["library-status-jellyfin"].value as? String, "5 titles", "2 in the diary and 3 only on Jellyfin")
        XCTAssertLessThan(app.buttons["library-status-jellyfin"].frame.maxX, app.buttons["library-status-queue"].frame.minX, "Jellyfin sits before Queue")
        let extras = app.descendants(matching: .any)["library-jellyfin-extras"]
        for _ in 0..<4 { if extras.exists && extras.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(extras.exists, "Jellyfin titles not in the diary get their own section")
        XCTAssertTrue(app.buttons["jellyfin-item-j-arrival"].exists); XCTAssertTrue(app.buttons["jellyfin-item-j-bocchi"].exists)
        capture("Library Jellyfin chip with titles not in the diary")
        // Library's filters apply to them too: Movies keeps Arrival and Dune, not the anime show.
        for _ in 0..<4 where !app.buttons["category-movies"].isHittable { app.swipeDown() }
        app.buttons["category-movies"].tap()
        XCTAssertTrue(app.buttons["jellyfin-item-j-arrival"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["jellyfin-item-j-bocchi"].exists, "Movies leaves out Jellyfin's shows")
        app.buttons["category-anime"].tap()
        XCTAssertTrue(app.buttons["jellyfin-item-j-bocchi"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["jellyfin-item-j-arrival"].exists, "Anime keeps only Jellyfin's animation")
        capture("Library Jellyfin chip anime")
    }
    func testAnimeCharactersOpenTheirPageAndHeartsCollectInFavourites() {
        let app = launch(); app.tabBars.buttons["Library"].tap()
        let show = app.buttons["title-frieren"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.tap()
        let character = app.buttons["anime-character-2"]
        for _ in 0..<10 { if character.exists && character.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(character.isHittable, "Anime pages list their characters"); capture("Anime characters row")
        character.tap()
        let heart = app.buttons["character-favourite"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'spoiler'")).firstMatch.exists, "Spoilers stay hidden")
        capture("Anime character page")
        heart.tap()
        XCTAssertEqual(heart.label, "Remove from favourites")
        // Detail pages hide the tab bar: back to the Library list first.
        let library = app.tabBars.buttons["Home"]
        for _ in 0..<3 where !library.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        let all = app.buttons["home-favourites"]
        for _ in 0..<12 { if all.exists && all.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(all.isHittable, "Home shows recent favourites"); capture("Home favourites")
        // Favourites sit right under Up next, above New episodes.
        let episodes = app.staticTexts["New episodes"]
        if episodes.exists { XCTAssertLessThan(all.frame.minY, episodes.frame.minY, "Favourites come before New episodes") }
        all.tap()
        XCTAssertTrue(app.buttons["favourites-tab-character"].waitForExistence(timeout: 5))
        // "Favourites" titles the page, with the Cast and Characters tabs below it.
        XCTAssertTrue(app.navigationBars["Favourites"].exists)
        XCTAssertGreaterThan(app.buttons["favourites-tab-cast"].frame.minY, app.navigationBars["Favourites"].frame.minY)
        XCTAssertTrue(app.buttons["favourite-character:2"].exists)
        // Characters rank from AniList: the profile lives in Settings → Connections; the tab links there.
        let connect = app.buttons["anilist-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5)); XCTAssertFalse(app.textFields["anilist-user-field"].exists, "No input box on the tab")
        connect.tap()
        let profile = app.textFields["anilist-user-field"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5)); profile.tap(); profile.typeText("https://anilist.co/user/twilight29533/stats/anime/voiceActors")
        app.buttons["anilist-user-save"].tap()
        XCTAssertTrue(app.buttons["anilist-user-remove"].waitForExistence(timeout: 5)); capture("Settings AniList connected")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["top-character-1"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["anilist-user"].exists)
        capture("Favourites most watched characters")
        // Cast and voice actors rank from the diary.
        app.buttons["favourites-tab-cast"].tap()
        XCTAssertFalse(app.buttons["favourite-character:2"].exists)
        XCTAssertTrue(app.buttons["top-cast-525"].waitForExistence(timeout: 5), "Cast has its Most watched ranking"); capture("Favourites cast tab")
        app.buttons["favourites-tab-voice"].tap()
        let top = app.buttons["top-voice-actor-1001"]
        XCTAssertTrue(top.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["anilist-connect"].exists, "Voice actors need no AniList profile")
        capture("Favourites most watched voice actors")
        top.tap()
        let voiceHeart = app.buttons["voice-actor-favourite"]
        XCTAssertTrue(voiceHeart.waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["voice-actor-watched"].exists)
        voiceHeart.tap(); XCTAssertEqual(voiceHeart.label, "Remove from favourites"); capture("Voice actor page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let hearted = app.buttons["favourite-voice:11"]
        for _ in 0..<6 { if hearted.exists && hearted.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(hearted.exists, "The hearted voice actor shows as a poster")
    }
    func testCharacterAppearancesAndVoiceActorAnimeOpenTheirTitleAndKeepCharacterLinks() {
        let app = launch(); app.tabBars.buttons["Library"].tap()
        let show = app.buttons["title-frieren"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.tap()
        let character = app.buttons["anime-character-2"]
        for _ in 0..<10 { if character.exists && character.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(character.isHittable); character.tap()
        let appearance = app.buttons["anime-appearance-154587"]
        for _ in 0..<10 { if appearance.exists && appearance.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(appearance.isHittable); capture("Character appearance opens a diary title")
        appearance.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5))
        let voice = app.buttons["voice-actor-12"]
        for _ in 0..<10 { if voice.exists && voice.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(voice.isHittable); voice.tap()
        let anime = app.buttons["voice-actor-anime-154587-2"]
        for _ in 0..<10 { if anime.exists && anime.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(anime.isHittable); capture("Voice actor has a separate anime link")
        anime.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let role = app.buttons["voice-actor-role-2"]
        XCTAssertTrue(role.waitForExistence(timeout: 5)); XCTAssertTrue(role.isHittable); role.tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5))
    }
    func testIncomingTraktWatchesCanBeEnabledDisabledAndReviewedWithoutAProgressOverlay() {
        let app = launch(); app.tabBars.buttons["More"].tap()
        openTrakt(app)
        let toggle = app.switches["trakt-incoming-toggle"]
        XCTAssertTrue(app.navigationBars["Trakt"].waitForExistence(timeout: 10))
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        let toggleExists = toggle.waitForExistence(timeout: 5)
        if !toggleExists {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Incoming fixture accessibility hierarchy"; attachment.lifetime = .keepAlways; add(attachment)
            print("Incoming fixture accessibility hierarchy:\n" + app.debugDescription)
        }
        XCTAssertTrue(toggleExists)
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0")
        print("Incoming fixture control: enabled=\(toggle.isEnabled), value=\(String(describing: toggle.value)), frame=\(toggle.frame)")
        if !toggle.isEnabled { print("Incoming fixture disabled hierarchy:\n" + app.debugDescription) }
        XCTAssertTrue(toggle.isEnabled, "The confirmed initial status must enable the native switch")
        capture("Incoming native switch before enabling")
        // SwiftUI exposes the labelled row as one Switch accessibility frame.
        // Touch the actual trailing switch, rather than the label's row centre.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        print("Incoming fixture after enable touch: value=\(String(describing: toggle.value))")
        if (toggle.value as? String) != "1" { print("Incoming fixture post-touch hierarchy:\n" + app.debugDescription) }
        let enabled = expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
        wait(for: [enabled], timeout: 5)
        XCTAssertTrue(app.staticTexts["Waiting for the first scheduled check"].exists)
        XCTAssertFalse(app.staticTexts["Saved diary"].exists)
        capture("Trakt incoming watches enabled awaiting scheduler")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let disabled = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        wait(for: [disabled], timeout: 5)
        XCTAssertFalse(app.staticTexts["Waiting for the first scheduled check"].exists)
        capture("Trakt incoming watches disabled")
    }
    func testTraktReviewResolvesAWholeGroupOnlyAfterConfirmation() {
        let app = launch(traktScenario: "removals"); app.tabBars.buttons["More"].tap()
        openTrakt(app)
        XCTAssertTrue(app.staticTexts["Review changes"].waitForExistence(timeout: 10))
        let useTrakt = app.buttons["trakt-group-pull-trakt"]
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        for _ in 0..<10 { if useTrakt.isHittable && useTrakt.frame.maxY < tabBarTop - 8 { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Removed on Trakt · 30"].exists)
        XCTAssertTrue(useTrakt.isHittable); capture("Trakt review groups")
        useTrakt.tap()
        // The dialog's title repeats the action's label, so pick the action itself.
        let labelled = app.buttons.matching(NSPredicate(format: "label == %@", "Use Trakt for 30 items"))
        XCTAssertTrue(labelled.firstMatch.waitForExistence(timeout: 5)); capture("Trakt group confirmation")
        XCTAssertTrue(app.staticTexts["Removes these items from your diary to match Trakt."].exists)
        // iOS can keep a second, off-screen copy of the dialog's action: tap the visible one.
        let identified = app.buttons.matching(identifier: "trakt-group-confirm")
        let candidates = (0..<identified.count).map { identified.element(boundBy: $0) }
            + (0..<labelled.count).map { labelled.element(boundBy: $0) }
        let confirm = candidates.first { $0.isHittable } ?? labelled.element(boundBy: labelled.count - 1)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Removed on Trakt · 30"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(useTrakt.exists, "A resolved group leaves the panel")
        XCTAssertTrue(app.staticTexts["8 remaining"].exists)
        capture("Trakt group resolved")
    }
    func testTraktReviewAppliesSafeChangesThenRequiresAnExplicitConflictChoice() {
        let app = launch(); app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.buttons["settings-trakt"].waitForExistence(timeout: 5))
        openTrakt(app)
        XCTAssertTrue(app.staticTexts["Review changes"].waitForExistence(timeout: 10))
        capture("Trakt review")
        // Kind filters are chips now (All · History · Ratings · Watchlist).
        let ratings = app.buttons["trakt-kind-rating"]
        for _ in 0..<4 { if ratings.isHittable { break }; app.swipeUp() }
        ratings.tap()
        XCTAssertTrue(app.staticTexts["Showing 3 of 3 loaded changes"].waitForExistence(timeout: 5))
        capture("Trakt ratings")
        app.buttons["trakt-kind-all"].tap()
        let ready = app.buttons["trakt-apply-ready"]
        for _ in 0..<12 {
            if ready.isHittable && ready.frame.maxY < app.tabBars.buttons["More"].frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(ready.isHittable)
        XCTAssertLessThan(ready.frame.maxY, app.tabBars.buttons["More"].frame.minY, "The entire Apply button must clear the capsule")
        capture("Trakt Apply visible"); ready.tap()
        XCTAssertTrue(app.staticTexts["1 remaining"].waitForExistence(timeout: 5))
        let useTrakt = app.buttons["trakt-trakt-change-2"]
        // isHittable stays true while the button sits under the translucent navigation
        // bar, so the tap landed on the bar (native62/65 runs: button at y 59–88, bar to 116).
        // Drag in short steps until the whole button clears both bars.
        let navigationBottom = app.navigationBars["Trakt"].frame.maxY
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        for _ in 0..<12 {
            let frame = useTrakt.frame
            if useTrakt.isHittable && frame.minY > navigationBottom + 8 && frame.maxY < tabBarTop - 8 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            // Dragging down reveals content above; dragging up reveals content below.
            let step: CGFloat = !useTrakt.exists || frame.minY <= navigationBottom + 8 ? 180 : -180
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: step)))
        }
        XCTAssertEqual(app.buttons.matching(identifier: "trakt-trakt-change-2").count, 1, "One conflict must expose exactly one Trakt action")
        XCTAssertTrue(useTrakt.isHittable); useTrakt.tap()
        if !app.staticTexts["You’re up to date"].waitForExistence(timeout: 8) {
            // Readable in the run's diagnostics: the review state after the choice.
            print("DIAG trakt conflict: useTrakt exists=\(useTrakt.exists) enabled=\(useTrakt.exists && useTrakt.isEnabled) remaining=\(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'remaining'")).firstMatch.label)")
            for line in app.debugDescription.split(separator: "\n").prefix(120) { print("DIAG trakt conflict | " + String(line.prefix(170))) }
            XCTFail("The last conflict choice must complete the review")
        }
        capture("Trakt applied")
    }
    func testStatsCalendarRangesEmptyBucketsAndUndatedHistory() {
        let app = launch(); app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.buttons["30D"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["30D"].isSelected, "Fresh Stats starts with Today, as on the web")
        app.buttons["30D"].tap(); XCTAssertTrue(app.buttons["30D"].isSelected)
        let firstDay = app.buttons["stats-bucket-0"]
        if !firstDay.isHittable { app.swipeUp() }
        XCTAssertTrue(firstDay.waitForExistence(timeout: 5)); firstDay.tap()
        XCTAssertTrue(app.staticTexts["1 Oct 2026"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No watches logged in this period."].exists)
        capture("Stats empty day")
        app.buttons["Close"].tap(); app.swipeDown()
        // One range control now: Today · 7D · 30D · 90D · 1Y · All.
        app.buttons["7D"].tap()
        XCTAssertTrue(app.buttons["7D"].isSelected)
        XCTAssertFalse(app.buttons["30D"].isSelected)
        capture("Stats week")
        let review = app.buttons["Review dates"]
        if !review.isHittable { app.swipeDown() }
        review.tap()
        XCTAssertTrue(app.staticTexts["Recently watched"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 watch"].waitForExistence(timeout: 5))
        capture("Undated history")
    }
    func testLibraryBulkQueueTrashRestoreAndPermanentDeleteInIsolatedFixture() {
        let app = launch(mutations: true); app.tabBars.buttons["Library"].tap()
        app.buttons["title-again"].press(forDuration: 1)
        app.buttons["Select"].tap()
        let other = app.buttons["select-title-after-rain"]
        XCTAssertTrue(other.waitForExistence(timeout: 5)); other.tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists); capture("Library select mode")
        app.buttons["selection-queue"].tap()
        let confirm = app.buttons["confirm-collection"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); capture("Bulk Queue review"); confirm.tap()
        XCTAssertTrue(app.buttons["title-again"].waitForExistence(timeout: 5))
        // Home no longer has a Queue shortcut (owner's design); Library's status filter is the way in.
        tapStatusChip(app, "queue")
        XCTAssertTrue(app.buttons["title-again"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["title-after-rain"].exists); XCTAssertFalse(app.buttons["title-frieren"].exists)
        app.buttons["title-again"].press(forDuration: 1); app.buttons["Move to Trash"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        // Trash is reached from the bottom of the filter sheet.
        let trash = app.buttons["Open Trash"]
        app.buttons["library-filters"].tap(); XCTAssertTrue(trash.waitForExistence(timeout: 5))
        for _ in 0..<6 { if trash.isHittable { break }; scrollSheet(app) }
        trash.tap()
        XCTAssertTrue(app.staticTexts["In Trash"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Trash"].exists)
        let trashLayout = app.buttons["trash-layout"]
        XCTAssertTrue(trashLayout.exists); trashLayout.tap()
        XCTAssertEqual(trashLayout.value as? String, "List"); capture("Dedicated Trash list")
        trashLayout.tap(); XCTAssertEqual(trashLayout.value as? String, "Grid")
        XCTAssertFalse(app.buttons["library-status-all"].exists, "Trash is an independent recovery page, not an archived Library filter")
        app.buttons["empty-trash"].tap(); XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5)); app.buttons["Cancel"].tap()
        capture("Trash populated")
        let restore = app.buttons["trash-restore-again"]
        for _ in 0..<6 { if restore.isHittable && restore.frame.maxY < app.tabBars.buttons["Library"].frame.minY - 8 { break }; app.swipeUp() }
        XCTAssertTrue(restore.isHittable)
        XCTAssertLessThan(restore.frame.maxY, app.tabBars.buttons["Library"].frame.minY - 8)
        restore.tap(); XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["Trash is clear"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["title-again"].waitForExistence(timeout: 5))
        app.buttons["title-again"].press(forDuration: 1); app.buttons["Move to Trash"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        app.buttons["library-filters"].tap(); XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap(); app.buttons["Delete permanently"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["Trash is clear"].waitForExistence(timeout: 5)); capture("Trash after permanent delete")
    }
    func testFilesAndScannerMatchPublishLocationWithoutChangingWatchHistory() {
        let app = launch(scanner: true); app.tabBars.buttons["More"].tap()
        app.buttons["settings-files"].tap()
        XCTAssertTrue(app.staticTexts["Mapped folders"].waitForExistence(timeout: 5)); capture("Files and drives")
        let review = app.buttons["Fix mismatches →"]
        let filesContent = app.scrollViews["files-content"]
        for _ in 0..<8 {
            if review.isHittable && review.frame.maxY < app.tabBars.buttons["More"].frame.minY { break }
            filesContent.swipeUp()
        }
        XCTAssertTrue(review.isHittable)
        XCTAssertLessThan(review.frame.maxY, app.tabBars.buttons["More"].frame.minY, "The last Files action must scroll fully above the floating tab bar")
        capture("Files final action above navigation"); review.tap()
        let match = app.buttons["match-scan-fixture-unmatched"]
        XCTAssertTrue(match.waitForExistence(timeout: 5)); capture("Unmatched scan"); match.tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("18 Again\n")
        let chosen = app.buttons["match-title-again"]
        XCTAssertTrue(chosen.waitForExistence(timeout: 5)); chosen.tap()
        XCTAssertTrue(app.staticTexts["No unmatched scans"].waitForExistence(timeout: 5)); capture("Scanner resolved")
        let done = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThan(done.frame.maxY, app.tabBars.buttons["More"].frame.minY, "Dismiss must never overlap the tab bar")
        done.tap()
        XCTAssertTrue(app.staticTexts["Mapped folders"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["More"].isSelected)
        let path = app.staticTexts["R:\\Reference\\Unmatched Series"]
        for _ in 0..<10 { if path.isHittable { break }; filesContent.swipeUp() }
        XCTAssertTrue(path.exists); capture("Confirmed scanned location")
        let filesDone = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(filesDone.isHittable); filesDone.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
    }
    func testStatsMoreAndFilesOfferInlineSearchWithoutChangingTheActiveTab() {
        let app = launch()
        for tab in ["stats", "more"] {
            // The More tab's page is headed Settings, so its search button is search-settings.
            app.tabBars.buttons[tab.capitalized].tap(); app.buttons[tab == "more" ? "search-settings" : "search-" + tab].tap()
            let field = app.textFields["Search library and online"]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("Frieren\n")
            XCTAssertTrue(app.buttons["search-library-frieren"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.buttons[tab.capitalized].isSelected); capture("Inline search " + tab)
            app.buttons["Close search"].tap()
            XCTAssertFalse(field.exists)
        }
        app.buttons["settings-files"].tap(); app.buttons["search-files"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["search-library-frieren"].waitForExistence(timeout: 5)); capture("Inline search Files")
        app.buttons["Close search"].tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
    }
    func testGlanceSwipeLogsExactlyOneWatchAndUndoPreservesTheCardPosition() {
        let app = launch(mutations: true)
        let count = app.staticTexts["watch-count-again"], mark = app.buttons["Mark next watch for 18 Again"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 5)
        let originalY = mark.frame.minY
        mark.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '9 / 16'"), evaluatedWith: count)], timeout: 10)
        XCTAssertEqual(mark.frame.minY, originalY, accuracy: 1, "Release must not reflow the page")
        app.buttons["Undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 10)
        XCTAssertEqual(mark.frame.minY, originalY, accuracy: 1)
        app.buttons["Remove latest watch for 18 Again"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '7 / 16'"), evaluatedWith: count)], timeout: 10)
        app.buttons["Undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 10)
        XCTAssertTrue(app.tabBars.buttons["Glance"].isSelected); XCTAssertTrue(count.isHittable)
        capture("Glance Undo restored")
    }
    func testConfirmedWatchRefreshFailureRecoversWithoutAnotherWatchAndPreservesUndo() {
        let app = launch(mutations: true, refreshFailure: true)
        app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let progress = app.sliders["episode-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.value as? String, "8 of 16 episodes watched")
        let mark = app.buttons["mark-title-watch"]
        if !mark.isHittable { app.swipeUp() }
        mark.tap()
        XCTAssertTrue(app.staticTexts["confirmed-write-notice"].waitForExistence(timeout: 10))
        XCTAssertFalse(mark.isEnabled)
        XCTAssertTrue(app.buttons["Undo"].exists); XCTAssertFalse(app.buttons["Undo"].isEnabled)
        capture("Confirmed watch refresh pending")
        app.buttons["confirmed-write-refresh"].tap()
        let undo = app.buttons["Undo"]
        // Touch within the short user-facing deadline; final count proves one watch + Undo.
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo)], timeout: 10)
        undo.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == '8 of 16 episodes watched'"), evaluatedWith: progress)], timeout: 10)
        capture("Confirmed watch recovery undone")
    }
    func testTitleWatchAndUndoUpdateTheEpisodePiecesAndMovieHistory() {
        let app = launch(mutations: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let progress = app.sliders["episode-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5)); XCTAssertEqual(progress.value as? String, "8 of 16 episodes watched")
        let mark = app.buttons["mark-title-watch"]
        if !mark.isHittable { app.swipeUp() }
        mark.tap()
        // On Intel, extra value/frame queries can exhaust the real4.5s Undo
        // window before XCTest synthesizes the touch. Undo first, then check
        // the result; observe intermediate values in separate actual edits.
        tapVisibleUndo(app)
        waitForProgress("8 of 16 episodes watched", slider: progress)
        let start = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.625, dy: 0.5)))
        tapVisibleUndo(app)
        waitForProgress("8 of 16 episodes watched", slider: progress)
        mark.tap(); waitForProgress("9 of 16 episodes watched", slider: progress)
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5625, dy: 0.5)).press(forDuration: 0.05, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: 0.625, dy: 0.5)))
        waitForProgress("10 of 16 episodes watched", slider: progress)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["title-quiet-orbit"].tap()
        let movieMark = app.buttons["mark-title-watch"]
        XCTAssertTrue(movieMark.waitForExistence(timeout: 5)); movieMark.tap()
        tapVisibleUndo(app)
        XCTAssertTrue(app.buttons["Log a watch"].waitForExistence(timeout: 5)); capture("Movie watch undone")
        movieMark.tap(); XCTAssertTrue(app.buttons["Log a rewatch"].waitForExistence(timeout: 5))
    }
    func testPersonShelvesOpenFilmographyLayoutsAndPreserveReturnNavigation() {
        let app = launch(); app.tabBars.buttons["Home"].tap(); app.buttons["search-twildiary"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.typeText("Clockmaker\n")
        let result = app.buttons["search-movie:900001"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        let actor = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Reference Actor 1'")).firstMatch
        for _ in 0..<5 { if actor.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(actor.isHittable); actor.tap()
        XCTAssertTrue(app.staticTexts["Facts & trivia"].waitForExistence(timeout: 10))
        let factLabel = app.staticTexts["person-fact-known-for-label"], factValue = app.staticTexts["person-fact-known-for-value"]
        XCTAssertTrue(factLabel.waitForExistence(timeout: 5)); XCTAssertTrue(factValue.exists)
        XCTAssertGreaterThan(factLabel.frame.width, 0); XCTAssertLessThan(factLabel.frame.height, 60)
        // Text accessibility frames describe glyph ink, not its 104pt layout column.
        XCTAssertEqual(factValue.frame.minX - factLabel.frame.minX, 120, accuracy: 2)
        XCTAssertLessThan(abs(factValue.frame.minY - factLabel.frame.minY), 8)
        XCTAssertLessThan(app.staticTexts["person-fact-birthplace-label"].frame.minY - factLabel.frame.minY, 75)
        capture("Person facts")
        let more = app.buttons["person-more-shows"]
        for _ in 0..<12 { if more.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(more.isHittable); capture("Person credit shelves"); more.tap()
        let count = app.staticTexts["person-result-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "16 titles"); capture("Person show filmography")
        let layout = app.buttons["catalog-layout"]
        XCTAssertTrue(layout.exists); layout.tap(); XCTAssertEqual(layout.value as? String, "List")
        let firstCredit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog-tv:' OR identifier BEGINSWITH 'catalog-movie:'")).firstMatch
        XCTAssertTrue(firstCredit.exists); XCTAssertGreaterThan(firstCredit.frame.width, app.frame.width * 0.8)
        capture("Person filmography list"); layout.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "catalog-layout").count, 1)
        XCTAssertFalse(app.buttons["person-filters"].exists); XCTAssertFalse(app.buttons["person-reset"].exists)
        XCTAssertFalse(app.textFields["Search filmography"].exists)
        let heading = app.staticTexts["person-filmography-heading"]
        XCTAssertTrue(heading.exists); XCTAssertGreaterThan(layout.frame.minX, heading.frame.minX)
        XCTAssertLessThan(abs(layout.frame.midY - heading.frame.midY), 8)
        XCTAssertEqual(count.label, "16 titles")
        capture("Person layout control replaces filters beside heading")
        XCTAssertFalse(app.buttons["person-filmography-done"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["person-more-shows"].waitForExistence(timeout: 5))
    }
    func testTitleMenuRevealsAndScrollsNotesAndLocationsAndCopiesAPath() {
        let app = launch(); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let editor = app.textViews["title-notes"]
        XCTAssertFalse(editor.exists)
        app.buttons["title-more"].tap(); app.buttons["title-menu-notes"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertTrue(editor.isHittable); capture("Title menu Notes revealed")
        app.buttons["Cancel"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)], timeout: 5)
        app.buttons["title-more"].tap(); app.buttons["title-menu-files"].tap()
        let empty = app.staticTexts["No mapped files yet. A Jellyfin sync in Files & drives adds matching locations here."]
        XCTAssertTrue(empty.waitForExistence(timeout: 5)); XCTAssertTrue(empty.isHittable)
        app.buttons["title-all-files"].tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5)); app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["title-more"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["title-frieren"].tap()
        app.buttons["title-more"].tap(); app.buttons["title-menu-files"].tap()
        let copy = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'title-copy-location-'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); XCTAssertTrue(copy.isHittable); copy.tap()
        XCTAssertEqual(copy.value as? String, "Copied"); capture("Title mapped location copied")
    }

    func testTitleRatingEditsInlineWithoutChangingItsWatchCount() {
        let app = launch(mutations: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        let personal = app.buttons["title-personal-rating"]
        XCTAssertTrue(personal.waitForExistence(timeout: 5)); XCTAssertEqual(personal.value as? String, "7.5"); personal.tap()
        let clear = app.buttons["Clear your rating"]
        for _ in 0..<6 { if clear.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(clear.isHittable); capture("Title inline rating"); clear.tap()
        let rate = app.buttons["Rate 7.0"]
        XCTAssertTrue(rate.waitForExistence(timeout: 5)); rate.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); capture("Title rating saved")
        for _ in 0..<6 { if personal.isHittable { break }; app.swipeDown() }
        XCTAssertEqual(personal.value as? String, "7.0")
        XCTAssertEqual(app.sliders["episode-progress"].value as? String, "8 of 16 episodes watched")
    }
    func testNotesSheetSavesTheDraftAndCancelDiscardsIt() {
        let app = launch(mutations: true, titleMetadata: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        app.buttons["title-more"].tap(); app.buttons["title-menu-notes"].tap()
        let editor = app.textViews["title-notes"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("Native note saved from the sheet")
        let done = app.buttons["notes-keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap(); capture("Notes sheet draft")
        app.buttons["Save notes"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)], timeout: 10)
        app.buttons["title-more"].tap(); app.buttons["title-menu-notes"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Native note saved from the sheet") == true)
        editor.tap(); editor.typeText(" and an unsaved line")
        app.buttons["notes-keyboard-done"].tap(); app.buttons["Cancel"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)], timeout: 5)
        app.buttons["title-more"].tap(); app.buttons["title-menu-notes"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String)?.contains("unsaved line") == true, "Cancel must discard the draft")
        capture("Notes sheet after Cancel")
    }
    /// Status chips scroll sideways; later ones start past the right edge.
    private func tapStatusChip(_ app: XCUIApplication, _ key: String) {
        let chip = app.buttons["library-status-" + key]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        // Off-screen chips can't even report hittability; compare frames instead and
        // drag the row from a point that is always on screen.
        let row = app.buttons["library-status-all"]
        for _ in 0..<3 where chip.frame.maxX > app.frame.width - 8 {
            let y = row.frame.midY
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.8, dy: y))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.2, dy: y)))
        }
        XCTAssertLessThanOrEqual(chip.frame.maxX, app.frame.width); chip.tap()
    }
    /// Half-height sheets scroll inside their lower half (Library's filters grow by their top instead).
    private func scrollSheet(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66)))
    }
    /// Settings keeps Trakt as a row under Connections; scroll to it and open the Trakt page.
    private func openTrakt(_ app: XCUIApplication) {
        let row = app.buttons["settings-trakt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<8 { if row.isHittable { break }; app.swipeUp() }
        row.tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func assertEpisodePieces(_ track: XCUIElement, app: XCUIApplication) {
        guard let image = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing episode screenshot"); return }
        let scale = CGFloat(image.width) / app.frame.width
        // Accessibility reports the visible ink bounds, excluding the SVG's outer margins.
        // Count actual foreground runs instead of deriving slot positions from those bounds.
        let left = floor(track.frame.minX * scale)
        let width = Int(ceil(track.frame.maxX * scale) - left)
        guard width > 0, let row = image.cropping(to: CGRect(x: left, y: floor(track.frame.midY * scale), width: CGFloat(width), height: 1)) else { XCTFail("Missing episode row"); return }
        var bytes = [UInt8](repeating: 0, count: width * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(row, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: 1)); return true
        }
        XCTAssertTrue(rendered)
        var pieces: [(start: Int, end: Int)] = []
        var insidePiece = false
        for x in 0..<width {
            let foreground = bytes[x * 4] > 35 || bytes[x * 4 + 1] > 35 || bytes[x * 4 + 2] > 40
            if foreground {
                if !insidePiece { pieces.append((start: x, end: x)) }
                else { pieces[pieces.count - 1].end = x }
            }
            insidePiece = foreground
        }
        guard pieces.count == 16 else { XCTFail("Expected 16 separate episode pieces; rendered \(pieces.count)"); return }
        for index in pieces.indices {
            let center = (pieces[index].start + pieces[index].end) / 2
            let piece = [Int(bytes[center * 4]), Int(bytes[center * 4 + 2])]
            if index > 0 { XCTAssertGreaterThan(pieces[index].start - pieces[index - 1].end, 2, "Every adjacent pair must have a visible gap") }
            if index < 8 {
                XCTAssertGreaterThan(piece[0], 120, "Each watched episode must have its own filled piece")
                XCTAssertGreaterThan(piece[1], 180)
            } else {
                XCTAssertLessThan(piece[0], 120, "Unwatched episodes must not appear filled")
                if index == 8 { XCTAssertGreaterThan(piece[1], 70, "Up next must have a softer accent tint") }
            }
        }
    }
    func testNativeExploreReturnsByBackActiveHomeTabAndFullContentSwipe() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let explore = app.buttons["explore-shortcut"]
        for _ in 0..<4 { if explore.isHittable { break }; app.swipeUp() }
        explore.tap(); XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["explore-done"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5))
        explore.tap(); XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["Explore"])], timeout: 5)
        explore.tap(); XCTAssertTrue(app.navigationBars["Explore"].waitForExistence(timeout: 5))
        completeContentBack(app, beside: app.staticTexts["Recommendation of the day"], from: 0.12, velocity: .slow)
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["Explore"])], timeout: 5)
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5))
        capture("Native Explore returned Home")
    }
    func testSearchReturnsDirectlyToRetainedResultsAndGlanceRemainsScoped() {
        let app = launch(); app.tabBars.buttons["Home"].tap(); app.buttons["search-twildiary"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("Frieren")
        for _ in 0..<2 {
            app.buttons["search-library-frieren"].tap()
            XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertFalse(app.tabBars.buttons["Home"].exists, "The presented title must hide root chrome before a native Back gesture")
            // The plain synopsis is below the poster and has no horizontal
            // control. A long content stroke here avoids depending on velocity
            // to finish a shorter pan across the hero's artwork hit region.
            completeContentBack(app, beside: app.staticTexts["title-synopsis-text"])
            XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Frieren")
        }
        XCTAssertTrue(app.buttons["search-library-frieren"].exists); capture("Search retained after content Back")
        app.tabBars.buttons["Library"].tap(); app.buttons["Search library"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.typeText("Clockmaker")
        XCTAssertTrue(app.buttons["search-movie:900001"].waitForExistence(timeout: 10))
        app.buttons["search-movie:900001"].tap()
        XCTAssertTrue(app.buttons["catalog-add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // A short edge gesture cancels the interactive pop; the old search keyboard stays dismissed.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.3)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.3)), withVelocity: .slow, thenHoldForDuration: 0.7)
        XCTAssertTrue(app.buttons["catalog-add"].exists); XCTAssertFalse(app.keyboards.firstMatch.exists)
        let information = app.buttons["catalog-information"], share = app.buttons["title-share"]
        XCTAssertTrue(information.isHittable)
        for _ in 0..<8 { if share.exists && share.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(share.isHittable, "Catalog uses the same compact header action as saved titles")
        XCTAssertFalse(information.exists, "An invisible information action must not remain beside compact Share")
        capture("Catalog compact header retains one native action")
        for _ in 0..<8 { if information.exists && information.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(information.isHittable); XCTAssertFalse(share.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Clockmaker")
        XCTAssertFalse(app.keyboards.firstMatch.exists); capture("Online search return keeps keyboard dismissed")
        app.buttons["Clear search"].tap(); field.typeText("Clockmaker\n")
        XCTAssertTrue(app.buttons["search-movie:900001"].waitForExistence(timeout: 10), "Clearing and retyping the same query must fetch results again")
        app.tabBars.buttons["Glance"].tap(); app.buttons["search-glance"].tap()
        let scoped = app.textFields["Find a current watch"]
        XCTAssertTrue(scoped.waitForExistence(timeout: 5)); scoped.typeText("Clockmaker\n")
        XCTAssertFalse(app.buttons["search-movie:900001"].exists)
        XCTAssertTrue(app.staticTexts["A clear little corner"].exists); capture("Glance scoped search")
    }
    private func waitForProgress(_ value: String, slider: XCUIElement) {
        // A false format predicate on an XCUIElement asks XCTest to dump the entire
        // hierarchy. That diagnostic can outlast the real, deliberately short Undo
        // window. Poll the same actual accessibility value without that extra dump.
        let condition = NSPredicate { _, _ in (slider.value as? String) == value }
        wait(for: [expectation(for: condition, evaluatedWith: "episode progress")], timeout: 10)
    }
    private func tapVisibleUndo(_ app: XCUIApplication) {
        // The floating toast is already onscreen. A semantic tap can ask XCTest
        // to scroll its gesture-containing ancestor, consuming the short window.
        // Touch the actual action's current bounds instead; never extend expiry.
        // Every XCTest query costs 0.3–1.8 s on Intel runners and the 4.5 s window
        // (production behaviour, kept) starts as soon as the write is confirmed —
        // often while XCTest is still waiting out the previous action's animation.
        // So no separate existence check and no settle delay: each poll is one
        // snapshot (existence, enabled state and frame together), then tap at once.
        // The action's own idle wait has already covered the toast's slide-in.
        let undo = app.buttons["undo-action"]
        let deadline = Date().addingTimeInterval(4)
        var target: CGRect?
        while target == nil, Date() < deadline {
            if let snapshot = try? undo.snapshot(), snapshot.isEnabled, !snapshot.frame.isEmpty {
                target = snapshot.frame
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard let bounds = target else { XCTFail("The Undo action never appeared enabled"); return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.midY)).tap()
    }
    private func completeContentBack(_ app: XCUIApplication, beside anchor: XCUIElement,
                                     from fraction: CGFloat = 0.12, velocity: XCUIGestureVelocity = .slow) {
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        // Start in content, outside the screen-edge strip, and cross most of
        // the viewport. The shorter central stroke can legitimately cancel
        // when XCTest's release velocity varies. Use visible plain text as
        // the height anchor, avoiding carousels, artwork and progress controls.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = anchor.frame.midY
        origin.withOffset(CGVector(dx: app.frame.width * fraction, dy: y)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.98, dy: y)), withVelocity: velocity, thenHoldForDuration: 0)
    }
    func testToastExpiresAndCardCoverAndUsefulMenuWork() {
        let app = launch(mutations: true)
        let mark = app.buttons["Mark next watch for 18 Again"]
        XCTAssertTrue(mark.waitForExistence(timeout: 5))
        for control in [mark, app.buttons["Remove latest watch for 18 Again"]] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(control.frame.height, 43.5)
        }
        mark.tap()
        let toast = app.otherElements["undo-toast"]
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        if toast.exists { XCTAssertLessThanOrEqual(toast.frame.height, 48); XCTAssertLessThanOrEqual(toast.frame.width, 330) }
        capture("Compact watch toast")
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Undo"])], timeout: 8)
        XCTAssertFalse(app.buttons["Dismiss undo"].exists)
        app.buttons["progress-menu-again"].tap()
        XCTAssertTrue(app.buttons["Favorite"].exists); XCTAssertTrue(app.buttons["Dropped"].exists)
        XCTAssertFalse(app.buttons["Open title"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Complete Season'")).firstMatch.exists)
        app.buttons["Notes"].tap()
        XCTAssertTrue(app.textViews["title-notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["title-notes"].isHittable); capture("Glance menu reveals Notes")
        app.buttons["Cancel"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.textViews["title-notes"])], timeout: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let cover = app.buttons["progress-cover-again"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.tabBars.buttons["Home"].tap()
        let pickup = app.buttons["progress-cover-again"]
        XCTAssertTrue(pickup.waitForExistence(timeout: 5))
        pickup.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
    }
    func testSlowGlanceWriteKeepsOtherCardsUsableAndCategoryReturnRetainsCounts() {
        let app = launch(mutations: true, slowWrites: true)
        let again = app.buttons["Mark next watch for 18 Again"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        // Locate the actual fixture label without depending on curly apostrophe spelling.
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mark next watch for Frieren'")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5)); XCTAssertTrue(other.isEnabled)
        again.tap()
        XCTAssertTrue(other.isEnabled, "An unrelated card must remain available during this write")
        other.tap()
        let firstCount = app.staticTexts["watch-count-again"], otherCount = app.staticTexts["watch-count-frieren"]
        wait(for: [expectation(for: NSPredicate(format: "label == '9 / 16'"), evaluatedWith: firstCount), expectation(for: NSPredicate(format: "label == '13 / 28'"), evaluatedWith: otherCount)], timeout: 15)
        XCTAssertTrue(again.isEnabled); XCTAssertTrue(other.isEnabled)
        app.buttons["category-anime"].tap(); XCTAssertEqual(otherCount.label, "13 / 28")
        app.buttons["category-movies"].tap(); app.buttons["category-anime"].tap()
        XCTAssertEqual(otherCount.label, "13 / 28"); capture("Glance cached category counts")
    }
    func testGlanceCurrentSeasonCompletionAndUndoPreserveTheUnwatchedLaterSeason() {
        let app = launch(mutations: true, upcoming: true)
        let count = app.staticTexts["watch-count-again"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 5)
        app.buttons["progress-menu-again"].tap(); app.buttons["Complete Season 1"].tap()
        // Undo first (project rule: never spend the real 4.5 s window on slow value
        // reads). A semantic tap tried to scroll the toast's ancestor and missed it.
        // The helper waits for Undo to be enabled, i.e. the completion was saved.
        tapVisibleUndo(app)
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 10)
        app.buttons["progress-title-again"].tap()
        let season = app.buttons["title-season"]
        XCTAssertTrue(season.waitForExistence(timeout: 5)); season.tap(); app.buttons["Season 2"].tap()
        let progress = app.sliders["episode-progress"]
        wait(for: [expectation(for: NSPredicate(format: "value == '0 of 3 episodes watched'"), evaluatedWith: progress)], timeout: 10)
        capture("Glance complete Undo preserves later season")
    }
    func testTitleArtworkScrollsAwayBeforeTheEpisodeAndNotesContent() {
        let app = launch(); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].tap()
        XCTAssertTrue(app.buttons["title-more"].waitForExistence(timeout: 5))
        guard let topImage = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing top screenshot"); return }
        let scale = CGFloat(topImage.width) / app.frame.width
        for y in [30.0, 180] {
            let initialArt = sample(topImage, at: CGPoint(x: 5, y: y), scale: scale)
            XCTAssertGreaterThan(initialArt.prefix(3).max() ?? 0, 30, "The clear hero art must retain its full-bleed top coverage")
        }
        capture("Title clear art before scroll")
        app.swipeUp(); app.swipeUp()
        guard let scrolled = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing scrolled screenshot"); return }
        for y in [170.0, 220, 270] {
            let margin = sample(scrolled, at: CGPoint(x: 5, y: y), scale: scale)
            XCTAssertLessThan(margin.prefix(3).max() ?? 255, 18, "The hero must scroll away, not remain pinned behind episodes/notes")
        }
        let compact = app.descendants(matching: .any)["compact-title-navigation"]
        XCTAssertTrue(compact.exists); XCTAssertTrue(app.buttons["title-share"].exists)
        XCTAssertGreaterThanOrEqual(compact.frame.minX, 0); XCTAssertLessThanOrEqual(compact.frame.maxX, app.frame.width)
        capture("Title scrolled clean Episodes and Notes")
    }
    func testNativeBackReturnsFromEverySettingsDestination() {
        let app = launch(); app.tabBars.buttons["More"].tap()
        for (entryID, title) in [("settings-history", "Recently watched"), ("settings-files", "Files & drives"), ("settings-theme", "Appearance"), ("settings-tmdb", "TMDB"), ("settings-trakt", "Trakt"), ("settings-about", "About")] {
            let entry = app.buttons[entryID]
            for _ in 0..<12 {
                if entry.isHittable { break }
                if entry.exists && entry.frame.minY < 120 { app.swipeDown() } else { app.swipeUp() }
            }
            XCTAssertTrue(entry.isHittable, entryID); entry.tap()
            let done = app.navigationBars[title].buttons.element(boundBy: 0)
            // Build #31: the first tap right after switching to More was lost (nothing opened). Tap
            // again only if the row is still there to tap, so a page that did open is never doubled.
            if !done.waitForExistence(timeout: 5), entry.isHittable { entry.tap() }
            XCTAssertTrue(done.waitForExistence(timeout: 10), title); done.tap()
            XCTAssertTrue(app.buttons["settings-refresh-diary"].waitForExistence(timeout: 5))
            wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)], timeout: 5)
            XCTAssertTrue(entry.exists, "Back must return to the same settings stack")
            XCTAssertTrue(entry.isHittable); entry.tap()
            let content = app.scrollViews.staticTexts.element(boundBy: 0)
            // Preserve the long baseline settings content stroke.
            completeContentBack(app, beside: content, from: 0.12, velocity: .slow)
            XCTAssertTrue(app.buttons["settings-refresh-diary"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars[title].exists)
        }
        capture("All settings native Back and content swipe destinations return")
    }
    func testGlanceNotesWaitForLateCastAndRelatedLayoutThenKeepEditorVisible() {
        let app = launch(mutations: true, titleMetadata: true, slowMetadata: true)
        app.tabBars.buttons["Glance"].tap()
        XCTAssertTrue(app.buttons["progress-menu-again"].waitForExistence(timeout: 5))
        app.buttons["progress-menu-again"].tap(); app.buttons["Notes"].tap()
        let editor = app.textViews["title-notes"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["catalog-layout"].waitForExistence(timeout: 10), "Related titles must finish growing the content before checking the destination")
        let contained = NSPredicate { _, _ in editor.exists && editor.isHittable && editor.frame.minY > 120 && editor.frame.maxY < app.frame.height - 25 }
        wait(for: [expectation(for: contained, evaluatedWith: editor)], timeout: 10)
        capture("Glance Notes editor after late metadata")
        editor.tap(); editor.typeText("Visible from Glance")
        XCTAssertTrue(app.buttons["notes-keyboard-done"].waitForExistence(timeout: 5)); app.buttons["notes-keyboard-done"].tap()
        app.buttons["Save notes"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)], timeout: 10)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["progress-menu-again"].waitForExistence(timeout: 5))
        app.buttons["progress-menu-again"].tap(); app.buttons["Notes"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertTrue((editor.value as? String)?.contains("Visible from Glance") == true)
        capture("Saved Glance Notes reopen at editor")
    }
    func testCollectionGridsKeepEpisodeActionsFoldersAndHistoryEntries() {
        let app = launch(mutations: true, titleMetadata: true, longEpisodes: true); app.tabBars.buttons["Glance"].tap()
        let glance = app.buttons["glance-layout"]
        XCTAssertTrue(glance.waitForExistence(timeout: 5)); glance.tap(); XCTAssertEqual(glance.value as? String, "Grid")
        // The most recently updated title stays a full-width hero above the grid.
        let again = app.buttons["progress-menu-again"], frieren = app.buttons["progress-menu-frieren"], night = app.buttons["progress-menu-night"]
        XCTAssertTrue(again.waitForExistence(timeout: 5)); XCTAssertTrue(frieren.exists); XCTAssertTrue(night.exists)
        XCTAssertLessThan(again.frame.maxY, frieren.frame.minY)
        XCTAssertLessThan(frieren.frame.minX, night.frame.minX); XCTAssertEqual(frieren.frame.minY, night.frame.minY, accuracy: 2)
        XCTAssertTrue(app.buttons["Mark next watch for 18 Again"].isEnabled)
        XCTAssertTrue(app.buttons["Remove latest watch for 18 Again"].isEnabled)
        capture("Glance two-column grid with watch actions")
        app.buttons["progress-title-again"].tap()
        let episodes = app.buttons["episodes-layout"]
        for _ in 0..<6 { if episodes.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(episodes.isHittable); episodes.tap()
        let eighth = app.buttons["title-episode-8"], ninth = app.buttons["title-episode-9"]
        XCTAssertTrue(eighth.exists); XCTAssertTrue(ninth.exists)
        XCTAssertLessThan(eighth.frame.minX, ninth.frame.minX)
        XCTAssertTrue(app.buttons["Mark episode 9 watched"].exists); capture("Episode grid retains spoiler and watched controls")
        // Watch controls stay inside each fixed-size grid tile.
        for number in [8, 9] {
            let watch = app.buttons["Mark episode \(number) " + (number == 8 ? "unwatched" : "watched")]
            XCTAssertTrue(watch.exists)
            let thumbnail = app.descendants(matching: .any)["episode-thumbnail-\(number)"]
            XCTAssertTrue(thumbnail.exists)
            XCTAssertGreaterThanOrEqual(watch.frame.minX, thumbnail.frame.minX)
            XCTAssertLessThanOrEqual(watch.frame.maxX, thumbnail.frame.maxX)
            XCTAssertGreaterThanOrEqual(watch.frame.minY, thumbnail.frame.minY)
            XCTAssertLessThanOrEqual(watch.frame.maxY, thumbnail.frame.maxY)
            XCTAssertLessThan(abs(watch.frame.maxY - thumbnail.frame.maxY), 8)
            XCTAssertLessThan(abs(watch.frame.maxX - thumbnail.frame.maxX), 8)
        }
        // Summaries open in a sheet, so revealing or reading one never moves the grid.
        let ninthFrame = ninth.frame
        eighth.tap()
        let eighthSummary = app.staticTexts["episode-summary-8"]
        XCTAssertTrue(eighthSummary.waitForExistence(timeout: 5)); capture("Episode details sheet")
        app.buttons["Done"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: eighthSummary)], timeout: 5)
        XCTAssertEqual(ninth.frame.minY, ninthFrame.minY, accuracy: 1, "Opening episode details must not reflow the grid")
        ninth.tap() // An unwatched, hidden episode is revealed in place first.
        XCTAssertEqual(ninth.frame.height, ninthFrame.height, accuracy: 1, "Revealing must not change the tile height")
        ninth.tap()
        let ninthSummary = app.staticTexts["episode-summary-9"]
        XCTAssertTrue(ninthSummary.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: ninthSummary)], timeout: 5)
        capture("Episode grid keeps captions and watch controls; details open in a sheet")
        episodes.tap()
        let recommendations = app.staticTexts["You might like"], recommendationLayout = app.buttons["catalog-layout"]
        for _ in 0..<10 { if recommendationLayout.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(recommendations.exists); XCTAssertTrue(recommendationLayout.isHittable)
        XCTAssertEqual(recommendations.frame.midY, recommendationLayout.frame.midY, accuracy: 2)
        XCTAssertEqual(app.buttons.matching(identifier: "catalog-layout").count, 1)
        capture("Recommendations layout control shares the heading row")
        app.navigationBars.buttons.element(boundBy: 0).tap(); glance.tap()
        app.tabBars.buttons["More"].tap(); app.buttons["settings-files"].tap()
        let files = app.buttons["files-layout"]
        for _ in 0..<5 { if files.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(files.isHittable); files.tap()
        let first = app.otherElements["file-folder-loc-frieren"], second = app.otherElements["file-folder-loc-night"]
        XCTAssertTrue(first.exists); XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minX, second.frame.minX)
        XCTAssertTrue(app.buttons["Copy path for Frieren: Beyond Journey’s End"].exists)
        capture("Mapped folders two-column grid")
        files.tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        let history = app.buttons["settings-history"]
        for _ in 0..<5 { if history.isHittable { break }; app.swipeUp() }; XCTAssertTrue(history.isHittable); history.tap()
        let layout = app.buttons["history-layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 5)); layout.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertLessThan(rows.element(boundBy: 0).frame.minX, rows.element(boundBy: 1).frame.minX)
        capture("Watch history grid keeps separate watch identities")
        layout.tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    func testNavigationLensCanBeHeldAndSlidAcrossTheBarAndCancelledOutsideIt() {
        let app = launch()
        let library = app.tabBars.buttons["Library"], more = app.tabBars.buttons["More"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.press(forDuration: 0.3, thenDragTo: more)
        XCTAssertTrue(more.isSelected); XCTAssertTrue(app.staticTexts["Appearance"].exists)
        capture("Glass navigation scrub More")
        more.press(forDuration: 0.3, thenDragTo: app.tabBars.buttons["Home"])
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
        XCTAssertTrue(app.staticTexts["Continue watching"].exists)
        let start = library.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -170)))
        XCTAssertEqual(["home", "library", "glance", "stats", "more"].filter { app.tabBars.buttons[$0.capitalized].isSelected }.count, 1)
        XCTAssertEqual(app.tabBars.count, 1)
        app.tabBars.buttons["Library"].tap(); XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        capture("Glass navigation cancelled and tap restored")
    }
    func testHoldingTheUndoToastPausesItsShortExpiryUntilTheTouchFinishes() {
        let app = launch(mutations: true)
        let count = app.staticTexts["watch-count-again"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        app.buttons["Mark next watch for 18 Again"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '9 / 16'"), evaluatedWith: count)], timeout: 10)
        let undo = app.buttons["Undo"]
        undo.press(forDuration: 3)
        wait(for: [expectation(for: NSPredicate(format: "label == '8 / 16'"), evaluatedWith: count)], timeout: 10)
        capture("Undo survives held touch")
    }
    private func sample(_ image: CGImage, at point: CGPoint, scale: CGFloat) -> [Int] {
        guard let pixel = image.cropping(to: CGRect(x: floor(point.x * scale), y: floor(point.y * scale), width: 1, height: 1)) else { XCTFail("Missing pixel sample"); return [0, 0, 0, 0] }
        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        XCTAssertTrue(rendered)
        return bytes.map(Int.init)
    }
    private func assertRangeHighlight(_ button: XCUIElement, app: XCUIApplication) {
        // The range bar sits under the chart; lift it clear of the floating tab bar before sampling.
        let bar = app.tabBars.firstMatch
        for _ in 0..<4 where bar.exists && button.frame.maxY > bar.frame.minY - 12 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        guard let source = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing screenshot"); return }
        let scale = CGFloat(source.width) / app.frame.width
        // Sample the clear left side of the segment, away from label glyphs and borders.
        let point = CGPoint(x: button.frame.minX + button.frame.width * 0.15, y: button.frame.midY)
        let bytes = sample(source, at: point, scale: scale)
        XCTAssertGreaterThan(bytes[0], 120, "The selected range must visibly use the accent fill")
        XCTAssertGreaterThan(bytes[2], 180, "A selected accessibility trait alone is insufficient")
    }
}
