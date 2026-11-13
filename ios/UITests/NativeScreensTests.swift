import XCTest
import UIKit

@MainActor final class NativeScreensTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func openStatistics(_ app: XCUIApplication) {
        app.tabBars.buttons["Profile"].tap()
        let row = app.buttons["settings-statistics"]
        for _ in 0..<10 { if row.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
    }
    private func launch(ratingsUnavailable: Bool = false, titleMetadata: Bool = false, empty: Bool = false, upcoming: Bool = false, slowMetadata: Bool = false, communityUnavailable: Bool = false, longEpisodes: Bool = false, automaticCarousel: Bool = false, animeNavigation: Bool = false, favouritesGallery: Bool = false, profileRepairs: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]
        if ratingsUnavailable { app.launchArguments.append("--ui-ratings-unavailable") }
        if titleMetadata { app.launchArguments.append("--ui-title-metadata") }
        if empty { app.launchArguments.append("--ui-empty") }
        if upcoming { app.launchArguments.append("--ui-upcoming") }
        if slowMetadata { app.launchArguments.append("--ui-slow-metadata") }
        if communityUnavailable { app.launchArguments.append("--ui-community-unavailable") }
        if longEpisodes { app.launchArguments.append("--ui-long-episodes") }
        if automaticCarousel { app.launchArguments.append("--ui-automatic-carousel") }
        if animeNavigation { app.launchArguments.append("--ui-anime-navigation") }
        if profileRepairs { app.launchArguments.append("--ui-profile-repairs") }
        if favouritesGallery { app.launchArguments.append("--ui-favourites-gallery") }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        let home = app.tabBars.buttons["Home"]
        if !home.waitForExistence(timeout: 15) { print("Native tab launch hierarchy: " + String(app.debugDescription.prefix(18000))) }
        XCTAssertTrue(home.exists); return app
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
        app.tabBars.buttons["Profile"].tap(); app.tabBars.buttons["Home"].tap()
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
        // Glance cards show "S1 · E8 of 16 · 50%" above each bar.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'watch-progress-'")).firstMatch.waitForExistence(timeout: 5))
        capture("Glance")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5)); capture("Home")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["title-after-rain"].waitForExistence(timeout: 5)); capture("Library")
        XCTAssertFalse(app.buttons["library-select"].exists, "Select starts from a long press, not the header")
        XCTAssertEqual(app.tabBars.count, 1, "The system Liquid Glass tab bar must be the only tab bar")
        let first = app.buttons["title-after-rain"].frame, second = app.buttons["title-again"].frame, third = app.buttons["title-frieren"].frame
        XCTAssertLessThan(first.maxX, second.minX)
        XCTAssertLessThan(second.maxX, third.minX)
        XCTAssertLessThanOrEqual(third.maxX, app.frame.width - 10)
        app.buttons["title-again"].waitAndTap()
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
        openStatistics(app)
        XCTAssertTrue(app.staticTexts["Watch time"].waitForExistence(timeout: 5)); capture("Stats")
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.staticTexts["APPEARANCE"].waitForExistence(timeout: 5)); capture("More")
    }
    func testCommunityInformationSheetUsesOverallStatsAndReturnsToTheTitle() {
        let app = launch(titleMetadata: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].waitAndTap()
        // Sentiments opens from the ··· menu; saved titles have no ⓘ button.
        let more = app.buttons["title-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        app.buttons["title-information"].tap()
        XCTAssertTrue(app.staticTexts["Sentiments"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertTrue(more.isHittable)
        XCTAssertEqual(app.sliders["episode-progress"].value as? String, "8 of 16 episodes watched")
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["title-quiet-orbit"].tap()
        app.buttons["title-more"].tap(); app.buttons["title-information"].tap()
        XCTAssertTrue(app.staticTexts["Match this title to TMDB to see its community information."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["community-positive-0"].exists)
        capture("Community information unmatched title")
    }
    func testCommunityUnavailableOffersRetryWithoutInventingCountsOrSentiments() {
        let app = launch(titleMetadata: true, communityUnavailable: true); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].waitAndTap()
        app.buttons["title-more"].tap(); app.buttons["title-information"].tap()
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
        openStatistics(app)
        XCTAssertTrue(app.staticTexts["Log a movie or episode to start your stats."].waitForExistence(timeout: 5)); capture("Empty Stats")
        XCTAssertFalse(app.staticTexts["0 watches dated"].exists, "No dates bar before the first watch")
        let week = app.buttons["7D"]
        for _ in 0..<4 where !week.isHittable { app.swipeUp() }
        XCTAssertTrue(week.isHittable)
    }

    func testHomeMediaShelvesAndListCardsKeepRoutesAndIndependentSavedLayouts() {
        executionTimeAllowance = 180
        let app = launch(upcoming: true, favouritesGallery: true)
        app.tabBars.buttons["Home"].tap()
        capture("Home upper section retained before new media shelves")
        func reveal(_ element: XCUIElement, down: Bool = false) {
            for _ in 0..<18 {
                let headerBottom = app.buttons["random-pick-logo"].frame.maxY + 6
                let bottom = app.tabBars.firstMatch.frame.minY
                if element.exists && element.isHittable && element.frame.minY >= headerBottom && element.frame.maxY < bottom { return }
                let towardTop = element.exists ? element.frame.minY < headerBottom : down
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.32 : 0.76))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.76 : 0.32))
                start.press(forDuration: 0.02, thenDragTo: end)
            }
            XCTAssertTrue(element.isHittable, element.identifier)
        }
        let planned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-planned-'")).firstMatch
        reveal(planned)
        XCTAssertGreaterThan(planned.frame.width, 95)
        XCTAssertLessThan(planned.frame.width, app.frame.width * 0.4)
        XCTAssertGreaterThan(planned.frame.height, planned.frame.width * 1.5)
        capture("Home Up next normal portrait posters")
        planned.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let favourite = app.buttons["favourite-cast:525"]
        reveal(favourite)
        XCTAssertGreaterThan(favourite.frame.height, favourite.frame.width * 1.5)
        let nextFavourite = app.buttons["favourite-cast:77"]
        XCTAssertEqual(nextFavourite.frame.width, favourite.frame.width, accuracy: 1)
        XCTAssertEqual(nextFavourite.frame.minY, favourite.frame.minY, accuracy: 1)
        capture("Home favourite portraits preserve provider navigation")
        favourite.tap()
        XCTAssertTrue(app.buttons["person-favourite"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let upcomingLayout = app.buttons["upcoming-layout"]
        reveal(upcomingLayout)
        XCTAssertEqual(upcomingLayout.value as? String, "List")
        let upcoming = app.buttons["home-upcoming-again"]
        reveal(upcoming)
        XCTAssertTrue(upcoming.label.contains("S2 · E1"), upcoming.label)
        XCTAssertTrue(upcoming.label.contains("Tomorrow"))
        XCTAssertGreaterThan(upcoming.frame.width, app.frame.width * 0.8)
        XCTAssertEqual(upcoming.frame.minX, 16, accuracy: 1, "Home design inset (16 pt), independent of decorative mockup bezel")
        XCTAssertEqual(upcoming.frame.width, app.frame.width - 32, accuracy: 2)
        XCTAssertGreaterThanOrEqual(upcoming.frame.height, 78)
        XCTAssertLessThanOrEqual(upcoming.frame.height, 82)
        let rowHeight = upcoming.frame.height
        capture("Home upcoming compact landscape list rows")
        reveal(upcomingLayout, down: true); upcomingLayout.tap()
        XCTAssertEqual(upcomingLayout.value as? String, "Cards")
        XCTAssertLessThan(upcoming.frame.width, app.frame.width * 0.8)
        XCTAssertEqual(upcoming.frame.width, 236, accuracy: 2, "Home design: 236 pt landscape episode cards")
        let cardHeight = upcoming.frame.height
        XCTAssertGreaterThan(cardHeight, 170)
        XCTAssertLessThan(cardHeight, 220, "Landscape artwork (133 pt) and a content-sized footer, without a forced empty panel")
        capture("Home upcoming horizontal artwork cards")
        upcoming.tap()
        let season = app.buttons["title-season"]
        XCTAssertTrue(season.waitForExistence(timeout: 10))
        XCTAssertEqual(season.value as? String, "Season 2")
        XCTAssertTrue(season.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let historyLayout = app.buttons["home-history-layout"]
        reveal(historyLayout)
        XCTAssertEqual(historyLayout.value as? String, "List", "Upcoming layout must not change history layout")
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-history-event-'")).firstMatch
        reveal(history)
        let firstID = history.identifier, firstLabel = history.label
        let recentRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-history-event-'"))
        XCTAssertGreaterThan(history.frame.width, app.frame.width * 0.8)
        XCTAssertEqual(history.frame.minX, 16, accuracy: 1, "Home design inset (16 pt)")
        XCTAssertEqual(history.frame.width, app.frame.width - 32, accuracy: 2)
        XCTAssertEqual(history.frame.height, rowHeight, accuracy: 2, "Matching activity row geometry")
        XCTAssertFalse(history.label.contains("% complete"))
        capture("Home recently watched uses the same compact list component")
        // Lazy stacks instantiate on demand: discover identities by scrolling, not by
        // assuming all four off-screen rows already have accessibility snapshots.
        var eventIDs = recentRows.allElementsBoundByIndex.map(\.identifier)
        for _ in 0..<4 {
            if Set(eventIDs).count == 3 { break }
            app.swipeUp()
            for id in recentRows.allElementsBoundByIndex.map(\.identifier) where !eventIDs.contains(id) { eventIDs.append(id) }
        }
        XCTAssertEqual(Set(eventIDs).count, 3, "Four watches; the two back-to-back 18 Again episodes share one row")
        reveal(historyLayout, down: true); historyLayout.tap()
        XCTAssertEqual(historyLayout.value as? String, "Cards")
        let retained = app.buttons[firstID]
        XCTAssertTrue(retained.label.hasPrefix(firstLabel.components(separatedBy: ", ").prefix(2).joined(separator: ", ")), retained.label)
        XCTAssertLessThan(retained.frame.width, app.frame.width * 0.8)
        XCTAssertEqual(retained.frame.width, 236, accuracy: 2, "Home design: 236 pt cards, the next one peeking")
        let watchedCardWidth = retained.frame.width
        XCTAssertEqual(retained.frame.height, cardHeight, accuracy: 3, "Upcoming and watched cards share image/footer geometry")
        reveal(retained)
        let secondRecent = recentRows.element(boundBy: 1)
        XCTAssertEqual(secondRecent.frame.minY, retained.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(secondRecent.frame.minX, retained.frame.maxX, "The next watched card follows (peeking at the edge)")
        capture("Home recent horizontal cards keep individual watch events")
        // Exercise the real horizontal scroller in both directions, keeping every event identity.
        let laneY = retained.frame.midY
        let left = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: laneY))
        let right = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 24, dy: laneY))
        let lastEvent = app.buttons[eventIDs.last!]
        for _ in 0..<4 {
            if lastEvent.exists && lastEvent.isHittable && lastEvent.frame.maxX <= app.frame.maxX - 10 { break }
            right.press(forDuration: 0.03, thenDragTo: left)
        }
        XCTAssertTrue(lastEvent.isHittable)
        XCTAssertLessThanOrEqual(lastEvent.frame.maxX, app.frame.maxX - 10)
        XCTAssertEqual(lastEvent.frame.width, watchedCardWidth, accuracy: 1)
        capture("Home recent grid swipes to the last distinct watch event")
        for _ in 0..<4 {
            if retained.exists && retained.isHittable && retained.frame.minX >= 10 { break }
            left.press(forDuration: 0.03, thenDragTo: right)
        }
        XCTAssertTrue(retained.label.hasPrefix(firstLabel.components(separatedBy: ", ").prefix(2).joined(separator: ", ")), retained.label)
        XCTAssertGreaterThanOrEqual(retained.frame.minX, 10)
        retained.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(historyLayout, down: true); historyLayout.tap()
        XCTAssertEqual(historyLayout.value as? String, "List")
        app.tabBars.buttons["Profile"].tap(); app.tabBars.buttons["Home"].tap()
        reveal(historyLayout)
        XCTAssertEqual(historyLayout.value as? String, "List")

        app.terminate()
        app.launchArguments.append("--ui-keep-home-layouts")
        app.launch(); app.tabBars.buttons["Home"].tap()
        reveal(upcomingLayout)
        XCTAssertEqual(upcomingLayout.value as? String, "Cards", "Saved Home card preference survives relaunch")
        reveal(historyLayout)
        XCTAssertEqual(historyLayout.value as? String, "List", "Home sections retain independent saved layouts")
        capture("Home independent list and card choices restored after process relaunch")
        app.swipeUp(); app.swipeUp()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-history-event-'"))
        XCTAssertEqual(rows.count, 3, "Recent rows (back-to-back episodes grouped) remain available at the bottom")
        let last = rows.allElementsBoundByIndex.last!
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThan(last.frame.maxY, app.tabBars.firstMatch.frame.minY - 8, "Last row clears the native tab bar")
        capture("Home lower list geometry and final row clear of native bars")
    }
    func testUpcomingEpisodeOpensItsLinkedSeasonAndEpisodesWithoutChangingOrdinaryTitleNavigation() {
        let app = launch(upcoming: true); app.tabBars.buttons["Home"].tap()
        let upcoming = app.buttons["home-upcoming-again"]
        for _ in 0..<12 { if upcoming.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(upcoming.isHittable); capture("Home upcoming later season"); upcoming.tap()
        let season = app.buttons["title-season"]
        XCTAssertTrue(season.waitForExistence(timeout: 10)); XCTAssertEqual(season.value as? String, "Season 2", "the episode's season is chosen")
        // The show opens at its top (owner's choice), not scrolled down to Episodes.
        capture("Upcoming opens the show")
        for _ in 0..<8 { if season.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(season.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].waitAndTap()
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
        // The header scrolls with the page now (true full screen): back to the top for the logo.
        for _ in 0..<8 where !logo.isHittable { app.swipeDown() }
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
        let logo = app.buttons["random-pick-logo"], empty = app.staticTexts["Your next story starts here"]
        // Let the empty diary finish loading first: a session change closes an open pick.
        XCTAssertTrue(app.descendants(matching: .any)["glance-content"].waitForExistence(timeout: 10))
        // The logo (and its triple-tap random pick) lives on Home only.
        app.tabBars.buttons["Home"].tap()
        wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: logo)], timeout: 5)
        for _ in 0..<3 where !empty.exists {
            logo.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            _ = empty.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(app.buttons["random-pick-open"].exists); capture("Empty collection random pick")
        app.buttons["Add a title"].tap()
        XCTAssertTrue(app.textFields["Search library and online"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add manually"].exists); capture("Library catalog-only add search")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Nothing here just yet"].waitForExistence(timeout: 5))
    }

    func testHistoryGridReusesCompactWatchedCardsAndKeepsTitleNavigation() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
        let link = app.buttons["settings-history"]
        for _ in 0..<6 { if link.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(link.isHittable); link.tap()
        let layout = app.buttons["history-layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 5)); layout.tap()
        XCTAssertEqual(layout.value as? String, "Grid")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        let first = rows.element(boundBy: 0), second = rows.element(boundBy: 1)
        let identity = first.identifier, label = first.label
        XCTAssertEqual(first.frame.width, (app.frame.width - 28 - 12) / 2, accuracy: 2)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        XCTAssertEqual(second.frame.minX - first.frame.maxX, 12, accuracy: 2)
        XCTAssertLessThan(first.frame.height, 215, "History must use the landscape card without an empty footer")
        XCTAssertTrue(first.isHittable)
        capture("History compact landscape grid with inline episode and date")
        first.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(layout.value as? String, "Grid")
        XCTAssertEqual(app.buttons[identity].label, label)
        layout.tap()
        XCTAssertEqual(layout.value as? String, "List")
        XCTAssertGreaterThan(app.buttons[identity].frame.width, app.frame.width * 0.8)
        capture("History grid to list preserves individual watch and return route")
    }
    func testHistoryUnknownDatesSearchPagingAndReturnKeepTheSourceFilters() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let history = app.buttons["home-history-more"]
        for _ in 0..<12 { if history.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        let count = app.staticTexts["history-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); capture("History first page")
        // History's chips: presets, Custom, then Unknown dates (scroll the row to reach it).
        let unknown = app.buttons["Unknown dates"]
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        for _ in 0..<3 where unknown.frame.maxX > app.frame.width - 8 {
            let y = unknown.frame.midY
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.8, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.2, dy: y)))
        }
        unknown.tap()
        XCTAssertEqual(count.label, "1 watch")
        XCTAssertTrue(app.staticTexts["Date unknown"].waitForExistence(timeout: 5)); capture("History unknown dates")
        app.buttons["Clear filters"].tap()
        app.tabBars.buttons["Search"].tap()
        let search = app.textFields["Search library and online"]
        search.tap(); search.typeText("Ｆｒｉｅｒｅｎ\n")
        let matches = app.buttons["search-history-matches"]
        for _ in 0..<10 { if matches.isHittable { break }; app.swipeUp() }
        matches.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'")).firstMatch.waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'")).firstMatch
        XCTAssertTrue(row.label.contains("Frieren")); row.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Clear filters"].exists)
        XCTAssertFalse(app.textFields["Filter watch history"].exists)
        capture("History retained universal search query")
        app.buttons["Clear filters"].tap()
        // No "Show more" button: scrolling to the end loads the next twelve watches by itself.
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-event-'"))
        var seen = Set<String>()
        for _ in 0..<14 {
            seen.formUnion(rows.allElementsBoundByIndex.map(\.identifier))
            if seen.count > 12 { break }
            app.swipeUp()
        }
        XCTAssertGreaterThan(seen.count, 12, "Scrolling must reveal the next twelve watches")
        capture("History expanded page")
    }


    func testLibrarySearchAndSelectionPersistAcrossTabs() {
        let app = launch()
        app.tabBars.buttons["Library"].tap(); app.tabBars.buttons["Search"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["search-library-frieren"].exists); XCTAssertFalse(app.buttons["search-library-again"].exists)
        capture("Library search")
        app.tabBars.buttons["Home"].tap(); app.tabBars.buttons["Search"].tap()
        XCTAssertEqual(search.value as? String, "Frieren")
        app.tabBars.buttons["Library"].tap(); app.buttons["List layout"].tap(); capture("Library list")
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
        let app = launch(); app.tabBars.buttons["Profile"].tap()
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
        app.buttons["library-order"].tap(); app.buttons["Highest rating"].tap()
        XCTAssertEqual(app.buttons["library-layout"].value as? String, "List")
        app.launchArguments.append("--ui-keep-library-preferences")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15)); app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["library-layout"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["library-layout"].value as? String, "List")
        XCTAssertEqual(app.buttons["library-order"].value as? String, "Highest rating")
        capture("Library persisted list layout and typed rating order after relaunch")
    }

    func testLibraryCommunityRatingPreferenceNeverDisplaysPersonalScores() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
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
        app.tabBars.buttons["Profile"].tap(); picker.tap(); app.buttons["TMDB"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertFalse((title.value as? String)?.contains("Rating") == true, "This fixture has no TMDB score; its personal rating must not substitute")
        capture("Library TMDB missing scores")
    }
    func testUnavailableCommunityScoresKeepLibraryUsableAndCanSwitchBack() {
        let app = launch(ratingsUnavailable: true)
        app.tabBars.buttons["Profile"].tap()
        let picker = app.buttons["settings-rating-source"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap(); app.buttons["Trakt"].tap()
        app.tabBars.buttons["Library"].tap()
        let message = app.staticTexts["Some Trakt ratings are unavailable."]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["title-again"].isHittable)
        XCTAssertFalse((app.buttons["title-again"].value as? String)?.contains("Rating") == true)
        XCTAssertTrue(app.buttons["ratings-retry"].exists); app.buttons["ratings-retry"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5)); capture("Library community ratings unavailable")
        app.tabBars.buttons["Profile"].tap(); picker.tap(); app.buttons["TMDB"].tap()
        app.tabBars.buttons["Library"].tap(); XCTAssertFalse(message.exists)
    }
    func testCatalogSearchReviewAndCastProfile() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Search'")).count, 1, "Inactive tabs must not expose controls to VoiceOver")
        app.tabBars.buttons["Search"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Clockmaker\n")
        let result = app.buttons["search-movie:900001"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); capture("Catalog search"); result.tap()
        XCTAssertTrue(app.buttons["Add to Planned"].waitForExistence(timeout: 10)); capture("Catalog review")
        let actor = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Reference Actor 1'")).firstMatch
        if !actor.isHittable { app.swipeUp() }
        XCTAssertTrue(actor.waitForExistence(timeout: 5)); actor.tap()
        XCTAssertTrue(app.buttons["person-favourite"].waitForExistence(timeout: 10)); capture("Cast profile")
    }
    func testSavedEpisodeRevealPersistsAfterCollapseWithoutRevealingOtherRows() {
        let app = launch(); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].waitAndTap()
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
        XCTAssertTrue(minimum.waitForExistence(timeout: 5))
        // The pills scroll sideways (order first); bring Rating into view.
        if minimum.frame.maxX > app.frame.width - 8 { app.buttons["explore-sort"].swipeLeft() }
        minimum.tap(); app.buttons["9+"].tap()
        XCTAssertTrue(app.staticTexts["No titles in this mix"].waitForExistence(timeout: 5)); capture("Explore filtered empty")
        app.buttons["Reset filters"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog-'")).firstMatch.waitForExistence(timeout: 5))
        // No "Load more" button: reaching the end loads the second page by itself.
        XCTAssertFalse(app.buttons["Load more"].exists)
        let lastResult = app.buttons["catalog-tv:900002"]
        for _ in 0..<14 { if lastResult.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lastResult.isHittable, "The second page must publish its final unique result")
        capture("Explore second page")
        // Scrolled past the heading, the bar names the list instead of "Explore".
        XCTAssertTrue(app.navigationBars.staticTexts["Highest rated shows"].exists || app.navigationBars.staticTexts["Highest rated"].exists)
        for _ in 0..<12 { if app.buttons["explore-minimum"].isHittable { break }; app.swipeDown() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["explore-daily-pick"].waitForExistence(timeout: 5))
    }
    func testHomeStatsUsesTodayAndKeepsTheOriginalRangeBar() {
        let app = launch(); openStatistics(app)
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
        let app = launch(); app.tabBars.buttons["Profile"].tap(); openConnections(app)
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
        let app = launch(); app.tabBars.buttons["Profile"].tap(); openConnections(app)
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
        // APIs sits under Connections: go back to the Profile page.
        let files = app.buttons["settings-files"]
        for _ in 0..<3 where !files.exists { app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1) }
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
        // No AniList pill on Favourites (owner's request); the ranking still loads from the profile.
        XCTAssertTrue(app.buttons["top-character-1"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["anilist-user"].exists)
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
        XCTAssertTrue(voiceHeart.waitForExistence(timeout: 5)); XCTAssertTrue(app.descendants(matching: .any)["voice-actor-watched"].exists)
        voiceHeart.tap(); XCTAssertEqual(voiceHeart.label, "Remove from favourites"); capture("Voice actor page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let hearted = app.buttons["favourite-voice:11"]
        for _ in 0..<6 { if hearted.exists && hearted.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(hearted.exists, "The hearted voice actor shows as a poster")
    }
    func testFavouritesShelvesViewAllAndIndependentLayoutsKeepProfileNavigation() {
        let app = launch(favouritesGallery: true)
        app.tabBars.buttons["Home"].tap()
        let entry = app.buttons["home-favourites"]
        for _ in 0..<10 { if entry.exists && entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
        let castTab = app.buttons["favourites-tab-cast"]
        XCTAssertTrue(castTab.isSelected)
        XCTAssertGreaterThan(castTab.frame.minY, app.navigationBars["Favourites"].frame.minY)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[cd] 'From your'")).firstMatch.exists)
        let first = app.buttons["top-cast-525"], second = app.buttons["top-cast-77"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.isHittable)
        XCTAssertLessThan(first.frame.width, app.frame.width * 0.4)
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX)
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 2)
        // Grid · list is a two-button switch beside Hearted.
        let gridButton = app.buttons["Show favourites as grid"], listButton = app.buttons["Show favourites as list"]
        let castFavourite = app.buttons["favourite-cast:525"]
        XCTAssertTrue(castFavourite.isHittable, "Hearted portraits are visible above the bottom navigation")
        XCTAssertTrue(gridButton.isSelected); capture("Favourites Cast keeps original header with horizontal ranks and Hearted grid")
        listButton.tap(); XCTAssertTrue(listButton.isSelected)
        XCTAssertGreaterThan(castFavourite.frame.width, app.frame.width * 0.8)
        castFavourite.tap(); XCTAssertTrue(app.buttons["person-favourite"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(listButton.isSelected, "Returning from a profile preserves layout")
        let shelf = app.scrollViews["top-cast-shelf"]
        let last = app.buttons["top-cast-707"]
        for _ in 0..<5 { if last.exists && last.isHittable { break }; shelf.swipeLeft() }
        XCTAssertTrue(last.isHittable, "The ranking strip scrolls independently")
        app.buttons["top-cast-more"].tap()
        XCTAssertTrue(app.navigationBars["Most watched"].waitForExistence(timeout: 5))
        let lastRow = app.buttons["ranking-top-cast-707"]
        for _ in 0..<8 { if lastRow.exists && lastRow.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(lastRow.isHittable)
        XCTAssertTrue(lastRow.label.contains("An intentionally long character role"))
        capture("All Cast ranks retain roles and counts")
        lastRow.tap(); XCTAssertTrue(app.buttons["person-favourite"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["favourites-tab-character"].tap()
        XCTAssertTrue(app.buttons["top-character-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(gridButton.isSelected, "Characters keep an independent layout preference")
        capture("Favourites Characters gallery without source caption")
        app.buttons["top-character-more"].tap()
        XCTAssertTrue(app.buttons["ranking-top-character-2"].waitForExistence(timeout: 5))
        app.buttons["ranking-top-character-2"].tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["favourites-tab-voice"].tap()
        XCTAssertTrue(app.buttons["top-voice-actor-1001"].waitForExistence(timeout: 5))
        XCTAssertTrue(gridButton.isSelected)
        XCTAssertTrue(app.buttons["favourite-voice:11"].isHittable)
        capture("Favourites Voice actors gallery without source caption")
        app.buttons["top-voice-actor-more"].tap()
        app.buttons["ranking-top-voice-actor-1001"].tap()
        XCTAssertTrue(app.buttons["voice-actor-favourite"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["voice-actor-watched"].label.contains("14 anime"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["favourites-tab-cast"].tap()
        XCTAssertTrue(listButton.isSelected)
        capture("Favourites Cast list preference retained across categories")
    }
    private func revealProfileControl(_ item: XCUIElement, in app: XCUIApplication) {
        // As in the profile-format matrix, correct both overshoot directions.
        // One-way full-screen swipes can pass a short character shelf entirely.
        for _ in 0..<30 {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 8 : app.frame.maxY - 20
            let known = item.exists && item.frame.height > 0
            if known && item.isHittable && item.frame.minY >= top && item.frame.maxY <= bottom { return }
            let downward = known && item.frame.minY < top
            let outside = known ? (downward ? top - item.frame.minY : item.frame.maxY - bottom) : 160
            let distance = min(160, max(48, outside + 12))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.32 : 0.72))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: downward ? distance : -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        capture("Profile control not revealed: " + item.identifier)
        XCTAssertTrue(item.exists, item.identifier)
        XCTAssertTrue(item.isHittable, item.identifier)
    }
    func testCharacterAppearancesAndVoiceActorAnimeOpenTheirTitleAndKeepCharacterLinks() {
        executionTimeAllowance = 240
        let app = launch(animeNavigation: true); app.tabBars.buttons["Library"].tap()
        let show = app.buttons["title-frieren"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 15))
        let character = app.buttons["anime-character-2"]
        revealProfileControl(character, in: app)
        XCTAssertTrue(character.isHittable); character.tap()
        let appearance = app.buttons["anime-appearance-154587"]
        revealProfileControl(appearance, in: app)
        XCTAssertTrue(appearance.isHittable); capture("Character appearance opens a diary title")
        appearance.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5))
        let voice = app.buttons["voice-actor-12"]
        revealProfileControl(voice, in: app)
        XCTAssertTrue(voice.isHittable); voice.tap()
        XCTAssertTrue(app.buttons["voice-actor-favourite"].waitForExistence(timeout: 5))
        capture("Voice actor shared hero before scrolling")
        // One merged page: no TMDB / AniList logo in the header; TMDB's shelves join the page.
        XCTAssertFalse(app.buttons["person-tmdb"].exists)
        let credits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-more-'")).firstMatch
        XCTAssertTrue(credits.waitForExistence(timeout: 10), "The TMDB side is matched in place")
        let birthday = app.descendants(matching: .any)["voice-actor-birthday"]
        XCTAssertTrue(birthday.exists)
        XCTAssertLessThan(app.staticTexts["Voice actor"].firstMatch.frame.maxY, birthday.frame.minY, "Facts sit below the role")
        XCTAssertTrue(app.buttons["profile-site-https://x.com/reference"].exists, "Website lists become labelled icon buttons")
        XCTAssertFalse(app.staticTexts["Facts"].exists)
        let voiceHeart = app.buttons["voice-actor-favourite"]
        let heartY = voiceHeart.frame.midY
        capture("Voice actor compact metadata and website icons")
        app.swipeUp()
        XCTAssertTrue(voiceHeart.isHittable)
        XCTAssertEqual(voiceHeart.frame.midY, heartY, accuracy: 2, "Favourite stays in the native toolbar while scrolling")
        capture("Voice actor pinned favourite after scrolling")
        XCTAssertFalse(app.buttons["voice-actor-tmdb"].exists, "No separate TMDB profile page any more")
        revealProfileControl(credits, in: app)
        credits.tap()
        XCTAssertTrue(app.staticTexts["person-filmography-heading"].waitForExistence(timeout: 10), "TMDB credits open natively")
        XCTAssertEqual(app.state, .runningForeground)
        capture("Voice actor TMDB credits stay native")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["voice-actor-favourite"].waitForExistence(timeout: 5))
        let anime = app.buttons["voice-actor-anime-154587-2"]
        revealProfileControl(anime, in: app)
        XCTAssertTrue(anime.isHittable)
        // The profile shows three characters like every other section; the grid/list toggle lives on
        // the full list behind the round > (this fixture voices fewer than four, so there's none).
        XCTAssertFalse(app.buttons["voice-actor-characters-layout"].exists)
        XCTAssertFalse(app.buttons["voice-actor-characters-more"].exists)
        capture("Voice actor has a separate anime link")
        anime.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let role = app.buttons["voice-actor-role-2"]
        XCTAssertTrue(role.waitForExistence(timeout: 5)); XCTAssertTrue(role.isHittable); role.tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5))
    }
    func testAnimeExactMatchesSkipTheSearchPageWithUnrelatedDiaryResults() {
        let app = launch(animeNavigation: true); app.tabBars.buttons["Library"].tap()
        let show = app.buttons["title-frieren"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.tap()
        let character = app.buttons["anime-character-2"]
        for _ in 0..<10 { if character.exists && character.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(character.isHittable); character.tap()
        for id in [900001, 900002] {
            let appearance = app.buttons["anime-appearance-\(id)"]
            for _ in 0..<10 { if appearance.exists && appearance.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(appearance.isHittable); appearance.tap()
            XCTAssertTrue(app.buttons["catalog-add"].waitForExistence(timeout: 10), "An exact remote title opens directly")
            XCTAssertFalse(app.navigationBars["Find anime"].exists)
            XCTAssertFalse(app.navigationBars["Choose title"].exists)
            capture(id == 900001 ? "Knapsack Kid opens directly" : "Santa Claus exact match ignores unrelated library hit")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5))
        }
    }
    func testStatsCalendarRangesEmptyBucketsAndUndatedHistory() {
        let app = launch(); openStatistics(app)
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
    func testStatsMoreAndFilesOfferInlineSearchWithoutChangingTheActiveTab() {
        // The former inline entry points now share the single Search tab.
        let app = launch(); openStatistics(app)
        XCTAssertFalse(app.buttons["search-stats"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["search-settings"].exists)
        let files = app.buttons["settings-files"]
        for _ in 0..<6 { if files.isHittable { break }; app.swipeUp() }
        files.tap(); XCTAssertFalse(app.buttons["search-files"].exists)
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["search-library-frieren"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.navigationBars["Files & drives"].waitForExistence(timeout: 5))
        capture("Universal Search preserves the previous Profile destination")
    }
    func testProfileRepairsKeepNativeLinksWatchedRatingsAndHiddenTabs() {
        executionTimeAllowance = 240
        let app = launch(animeNavigation: true, profileRepairs: true)
        func reveal(_ element: XCUIElement, down: Bool = false) {
            for _ in 0..<14 { if element.exists && element.isHittable { return }; if down { app.swipeDown() } else { app.swipeUp() } }
            XCTAssertTrue(element.isHittable, element.identifier)
        }
        func assertDetailTabsHidden() { XCTAssertEqual(app.tabBars.count, 1, "The tab bar stays on profile and detail pages") }
        app.tabBars.buttons["Library"].tap(); app.buttons["title-frieren"].tap()
        let rating = app.buttons["title-personal-rating"]
        XCTAssertTrue(rating.waitForExistence(timeout: 5))
        // Title redesign: your rating sits in the rating circles (community scores in the logo boxes),
        // reachable and inside the page margins (scrolled clear of the tab bar, which title pages keep).
        reveal(rating)
        XCTAssertGreaterThanOrEqual(rating.frame.minX, 12); XCTAssertLessThanOrEqual(rating.frame.maxX, app.frame.width - 12)
        capture("Saved title ratings strip and personal rating")
        let cast = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cast-person-'")).firstMatch
        reveal(cast)
        XCTAssertEqual(cast.frame.width, 111, accuracy: 2, "Show page design: 111 pt cast cards")
        XCTAssertGreaterThan(cast.frame.height, 148)
        let shelf = app.scrollViews["related-titles-shelf"]
        reveal(shelf)
        let posters = shelf.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        guard posters.count >= 2 else { XCTFail("Two horizontal recommendations should be visible"); return }
        XCTAssertGreaterThan(posters[1].frame.minX, posters[0].frame.maxX)
        XCTAssertEqual(posters[0].frame.minY, posters[1].frame.minY, accuracy: 2)
        capture("Recommendations use one horizontal poster shelf")
        let fern = app.buttons["anime-character-2"]; reveal(fern, down: true); fern.tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5)); assertDetailTabsHidden()
        let watched = app.buttons["profile-watched-frieren"]; reveal(watched)
        XCTAssertTrue(watched.label.contains("Frieren"))
        app.swipeUp(); assertDetailTabsHidden()
        capture("Character Watched titles and toolbar without root tabs")
        let voice = app.buttons["voice-actor-12"]; reveal(voice, down: true)
        XCTAssertEqual(voice.frame.width, 96, accuracy: 2); voice.tap()
        XCTAssertTrue(app.buttons["voice-actor-favourite"].waitForExistence(timeout: 5)); assertDetailTabsHidden()
        capture("Voice actor initial transparent toolbar and accent heart")
        app.swipeUp(); app.swipeDown(); assertDetailTabsHidden()
        let characterLink = app.buttons["profile-reference-https://anilist.co/character/2"]
        reveal(characterLink); characterLink.tap()
        XCTAssertTrue(app.buttons["character-favourite"].waitForExistence(timeout: 5)); assertDetailTabsHidden()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let animeLink = app.buttons["profile-reference-https://anilist.co/anime/154587"]
        reveal(animeLink, down: true); animeLink.tap()
        XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 10)); assertDetailTabsHidden()
        XCTAssertFalse(app.navigationBars["Find anime"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The voice actor's TMDB credits live on the same merged page, behind each shelf's >.
        let castCredits = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-more-'")).firstMatch
        XCTAssertTrue(castCredits.waitForExistence(timeout: 10))
        reveal(castCredits, down: true); castCredits.tap()
        XCTAssertTrue(app.staticTexts["person-filmography-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        capture("Cast TMDB action stays inside native credits")
        app.navigationBars.buttons.element(boundBy: 0).tap(); assertDetailTabsHidden()
    }
    func testPersonShelvesOpenFilmographyLayoutsAndPreserveReturnNavigation() {
        let app = launch(); app.tabBars.buttons["Home"].tap(); app.tabBars.buttons["Search"].tap()
        let search = app.textFields["Search library and online"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Clockmaker\n")
        let result = app.buttons["search-movie:900001"]
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
        let actor = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Reference Actor 1'")).firstMatch
        for _ in 0..<5 { if actor.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(actor.isHittable); actor.tap()
        let heart = app.buttons["person-favourite"]
        XCTAssertTrue(heart.waitForExistence(timeout: 10))
        let topY = heart.frame.midY
        XCTAssertTrue(app.staticTexts["person-name"].exists)
        XCTAssertFalse(app.staticTexts["Facts & trivia"].exists, "Profile facts use compact details rather than a table")
        capture("Person shared hero and compact details")
        let more = app.buttons["person-more-shows"]
        for _ in 0..<12 { if more.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(more.isHittable)
        XCTAssertTrue(heart.isHittable); XCTAssertEqual(heart.frame.midY, topY, accuracy: 2)
        capture("Person credit shelves and pinned favourite"); more.tap()
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
        let app = launch(); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].waitAndTap()
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

    /// Status chips scroll sideways; later ones start past the right edge.
    private func tapStatusChip(_ app: XCUIApplication, _ key: String) {
        let chip = app.buttons["library-status-" + key]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        // Off-screen chips can't even report hittability; compare frames instead and
        // drag the row from a point that is always on screen.
        let row = app.buttons["library-status-watching"]
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
    /// Profile → Connections: every service lives on its own page now.
    private func openConnections(_ app: XCUIApplication) {
        let row = app.buttons["settings-connections"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<8 { if row.isHittable { break }; app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
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
        let back = app.navigationBars["Explore"].buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        let initialBackFrame = back.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.7)
        XCTAssertTrue(back.isHittable)
        XCTAssertEqual(back.frame.minX, initialBackFrame.minX, accuracy: 1)
        XCTAssertEqual(back.frame.minY, initialBackFrame.minY, accuracy: 1)
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)
        completeContentBack(app, beside: app.staticTexts["Recommendation of the day"], from: 0.12, velocity: .slow)
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.navigationBars["Explore"])], timeout: 5)
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 5))
        capture("Native Explore returned Home")
    }
    /// Tapping Search again (a double tap from anywhere) puts the cursor in the search field.
    func testTappingSearchAgainFocusesTheSearchField() {
        let app = launch(); app.tabBars.buttons["Home"].tap()
        let tab = app.tabBars.buttons["Search"]
        tab.tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "One tap opens Search without the keyboard")
        tab.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "The second tap focuses the field")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
        field.typeText("Frieren")
        XCTAssertTrue(app.buttons["search-library-frieren"].waitForExistence(timeout: 5))
        capture("Search focused by a second tap")
        app.tabBars.buttons["Home"].tap(); tab.doubleTap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "A double tap from another tab focuses too")
    }
    func testSearchReturnsDirectlyToRetainedResultsAndGlanceRemainsScoped() {
        let app = launch(); app.tabBars.buttons["Home"].tap(); app.tabBars.buttons["Search"].tap()
        let field = app.textFields["Search library and online"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Frieren")
        for _ in 0..<2 {
            app.buttons["search-library-frieren"].tap()
            XCTAssertTrue(app.buttons["title-personal-rating"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertTrue(app.tabBars.buttons["Home"].exists, "The tab bar stays on title pages")
            // The plain synopsis is below the poster and has no horizontal
            // control. A long content stroke here avoids depending on velocity
            // to finish a shorter pan across the hero's artwork hit region.
            completeContentBack(app, beside: app.staticTexts["title-synopsis-text"])
            XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Frieren")
        }
        XCTAssertTrue(app.buttons["search-library-frieren"].exists); capture("Search retained after content Back")
        app.tabBars.buttons["Library"].tap(); app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "Clockmaker")
        XCTAssertTrue(app.buttons["search-movie:900001"].waitForExistence(timeout: 10))
        app.buttons["search-movie:900001"].tap()
        XCTAssertTrue(app.buttons["catalog-add"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // A short edge gesture cancels the interactive pop; the old search keyboard stays dismissed.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.3)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.3)), withVelocity: .slow, thenHoldForDuration: 0.7)
        XCTAssertTrue(app.buttons["catalog-add"].exists); XCTAssertFalse(app.keyboards.firstMatch.exists)
        // The preview has the same single ••• button as a saved title; Sentiments is in its menu.
        let more = app.buttons["catalog-more"]
        XCTAssertTrue(more.isHittable)
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(more.isHittable, "The ••• button stays as the header compacts")
        capture("Catalog compact header retains one native action")
        more.tap()
        XCTAssertTrue(app.buttons["catalog-information"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["title-share"].exists)
        app.buttons["catalog-information"].tap()
        app.swipeDown(velocity: .fast)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Clockmaker")
        XCTAssertFalse(app.keyboards.firstMatch.exists); capture("Online search return keeps keyboard dismissed")
        app.buttons["Clear search"].tap(); field.tap(); field.typeText("Clockmaker\n")
        XCTAssertTrue(app.buttons["search-movie:900001"].waitForExistence(timeout: 10), "Clearing and retyping the same query must fetch results again")
        app.tabBars.buttons["Glance"].tap(); app.tabBars.buttons["Search"].tap()
        // Search is universal: a trip to Glance keeps the query and its results.
        let scoped = app.textFields["Search library and online"]
        XCTAssertTrue(scoped.waitForExistence(timeout: 5)); XCTAssertEqual(scoped.value as? String, "Clockmaker")
        XCTAssertTrue(app.buttons["search-movie:900001"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Glance"].tap()
        XCTAssertFalse(app.textFields["Find a current watch"].exists); capture("Glance uses universal Search")
    }
    private func waitForProgress(_ value: String, slider: XCUIElement) {
        // A false format predicate on an XCUIElement asks XCTest to dump the entire
        // hierarchy. That diagnostic can outlast the real, deliberately short Undo
        // window. Poll the same actual accessibility value without that extra dump.
        let condition = NSPredicate { _, _ in (slider.value as? String) == value }
        wait(for: [expectation(for: condition, evaluatedWith: "episode progress")], timeout: 10)
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
    func testTitleArtworkScrollsAwayBeforeTheEpisodeAndNotesContent() {
        let app = launch(); app.tabBars.buttons["Library"].tap(); app.buttons["title-again"].waitAndTap()
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
        XCTAssertTrue(compact.exists); XCTAssertTrue(app.buttons["title-more"].exists)
        XCTAssertGreaterThanOrEqual(compact.frame.minX, 0); XCTAssertLessThanOrEqual(compact.frame.maxX, app.frame.width)
        capture("Title scrolled clean Episodes and Notes")
    }
    func testNativeBackReturnsFromEverySettingsDestination() {
        let app = launch(); app.tabBars.buttons["Profile"].tap()
        for (entryID, title) in [("settings-history", "Recently watched"), ("settings-files", "Files & drives"), ("settings-theme", "Appearance"), ("settings-connections", "Connections"), ("settings-about", "About")] {
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
    func testNavigationLensCanBeHeldAndSlidAcrossTheBarAndCancelledOutsideIt() {
        let app = launch()
        let library = app.tabBars.buttons["Library"], more = app.tabBars.buttons["Profile"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.press(forDuration: 0.3, thenDragTo: more)
        XCTAssertTrue(more.isSelected); XCTAssertTrue(app.staticTexts["APPEARANCE"].exists)
        capture("Glass navigation scrub More")
        more.press(forDuration: 0.3, thenDragTo: app.tabBars.buttons["Home"])
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
        XCTAssertTrue(app.staticTexts["Continue watching"].exists)
        let start = library.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -170)))
        XCTAssertEqual(["Home", "Library", "Glance", "Search", "Profile"].filter { app.tabBars.buttons[$0].exists && app.tabBars.buttons[$0].isSelected }.count, 1)
        XCTAssertEqual(app.tabBars.count, 1)
        app.tabBars.buttons["Library"].tap(); XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        capture("Glass navigation cancelled and tap restored")
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
        // Let the selection pill finish its spring before sampling (it slides from the previous range).
        Thread.sleep(forTimeInterval: 0.8)
        guard let source = XCUIScreen.main.screenshot().image.cgImage else { XCTFail("Missing screenshot"); return }
        let scale = CGFloat(source.width) / app.frame.width
        // Sample the clear left side of the segment, away from label glyphs and borders.
        let point = CGPoint(x: button.frame.minX + button.frame.width * 0.15, y: button.frame.midY)
        let bytes = sample(source, at: point, scale: scale)
        XCTAssertGreaterThan(bytes[0], 120, "The selected range must visibly use the accent fill")
        XCTAssertGreaterThan(bytes[2], 180, "A selected accessibility trait alone is insufficient")
    }
}

extension XCUIElement {
    /// Waits for the element (a list loads a moment after the tab opens), then taps it.
    func waitAndTap(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitForExistence(timeout: timeout), identifier)
        tap()
    }
}
