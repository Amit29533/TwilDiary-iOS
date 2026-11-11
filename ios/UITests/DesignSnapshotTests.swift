import XCTest

/// Screens captured top to bottom on sample data, to compare with the owner's design files.
/// Run on its own (`-only-testing:TwilDiaryUITests/DesignSnapshotTests`); it checks nothing.
@MainActor final class DesignSnapshotTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = true }

    /// The animated splash, recorded from outside the test (simctl recordVideo) while it plays.
    func testSplashPlays() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-splash"]
        app.launch()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "splash"; shot.lifetime = .keepAlways; add(shot)
        // It lifts once it has played and the diary is ready: the tabs are there after it.
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }
    /// The first screen, signed out: where your library lives (as Cinopsys asks it).
    func testFirstScreenSnapshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-signed-out"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "first-screen"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.buttons["sign-in-trakt"].exists && app.buttons["sign-in-wetrakr"].exists)
    }
    func testHomeSnapshots() { capture(tab: "home", name: "home", pages: 7) }
    /// The title page of the show in Continue watching, top to bottom.
    func testShowSnapshots() {
        capture(tab: "home", name: "show", pages: 9) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// Settings: the root, then each restyled page (one screen each, plus a scroll of the root).
    func testSettingsSnapshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-keep-launch-tab", "-launchTab", "more"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 3)
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1.2) }
        func open(_ id: String) -> Bool {
            let target = app.descendants(matching: .any)[id]
            for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp() }
            guard target.exists else { return false }
            target.tap(); Thread.sleep(forTimeInterval: 2); return true
        }
        shot("settings-0")
        app.swipeUp(); Thread.sleep(forTimeInterval: 1); shot("settings-1")
        app.swipeDown(); app.swipeDown()
        if open("settings-theme") { shot("settings-appearance"); back() }
        if open("settings-connections") {
            shot("settings-connections")
            if open("connections-backups") { shot("settings-backups"); back() }
            back()
        }
        app.swipeDown(); app.swipeDown()
        if open("settings-language-region") { shot("settings-language"); back() }
        if open("settings-backups") { shot("settings-sync"); back() }
        app.swipeDown(); app.swipeDown()
        if open("settings-trash") || open("Trash") { shot("settings-trash") }
    }

    /// The service pages under Settings → Connections, plus Watch history and Trash selection.
    func testSettingsServiceSnapshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-keep-launch-tab", "-launchTab", "more"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 3)
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1.2) }
        func open(_ id: String) -> Bool {
            let target = app.descendants(matching: .any)[id]
            for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp() }
            guard target.exists else { return false }
            target.tap(); Thread.sleep(forTimeInterval: 2.5); return true
        }
        func scrolled(_ name: String) { app.swipeUp(); Thread.sleep(forTimeInterval: 1); shot(name) }
        if open("settings-connections") {
            for id in ["settings-trakt", "settings-simkl", "settings-mdblist", "settings-tmdb", "settings-anilist", "settings-apis"] {
                if open(id) { shot("svc-" + id); scrolled("svc-" + id + "-2"); back(); app.swipeDown(); app.swipeDown() }
            }
            shot("svc-connections")
            if open("settings-signin-methods") {
                shot("svc-signin")
                let other = app.buttons["sign-in-other-ways"]
                if other.exists { other.tap(); Thread.sleep(forTimeInterval: 1); shot("svc-signin-other") }
                app.swipeDown(velocity: .fast); Thread.sleep(forTimeInterval: 1)
            }
            back()
        }
        app.swipeDown(); app.swipeDown()
        if open("settings-history") { shot("svc-history"); back() }
    }

    /// A person (Home → title → first cast member), top to bottom, then their Photos page and viewer.
    func testPersonSnapshots() {
        capture(tab: "home", name: "person", pages: 5) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let cast = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cast-person-'")).firstMatch
            for _ in 0..<10 where !(cast.exists && cast.isHittable) { app.swipeUp() }
            if cast.exists { cast.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }
    /// The person's photo viewer, opened from the Photos shelf.
    func testPhotoViewerSnapshots() {
        capture(tab: "home", name: "viewer", pages: 1) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let cast = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cast-person-'")).firstMatch
            for _ in 0..<10 where !(cast.exists && cast.isHittable) { app.swipeUp() }
            if cast.exists { cast.tap() }
            Thread.sleep(forTimeInterval: 3)
            let photo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo of' OR label BEGINSWITH 'Photo from'")).firstMatch
            for _ in 0..<4 where !(photo.exists && photo.isHittable) { app.swipeUp() }
            if photo.exists { photo.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// Profile, then Statistics (each tab, scrolled), Milestones and Edit profile.
    func testProfileStatsSnapshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-keep-launch-tab", "-launchTab", "more"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 3)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        func step() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3); Thread.sleep(forTimeInterval: 1)
        }
        func pages(_ name: String, _ count: Int) { for page in 0..<count { shot("\(name)-\(page)"); if page < count - 1 { step() } } }
        func open(_ id: String) -> Bool {
            let target = app.descendants(matching: .any)[id]
            for _ in 0..<8 where !(target.exists && target.isHittable) { step() }
            guard target.exists else { return false }
            target.tap(); Thread.sleep(forTimeInterval: 2.5); return true
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1.5) }
        if open("settings-personal-profile") {
            pages("prof", 4)
            for _ in 0..<6 { app.swipeDown() }
            if open("profile-statistics") {
                for tab in ["overview", "habits", "taste", "library"] {
                    let button = app.buttons["stats-tab-" + tab]
                    for _ in 0..<6 where !(button.exists && button.isHittable) { app.swipeDown() }
                    if button.exists { button.tap(); Thread.sleep(forTimeInterval: 2) }
                    pages("stats-" + tab, 3)
                }
                // Monthly (owner's board 3).
                for _ in 0..<6 { app.swipeDown() }
                let scope = app.buttons["stats-scope"]
                if scope.waitForExistence(timeout: 3) {
                    scope.tap(); Thread.sleep(forTimeInterval: 1)
                    let monthly = app.buttons["Monthly"].firstMatch
                    if monthly.waitForExistence(timeout: 3) { monthly.tap(); Thread.sleep(forTimeInterval: 2) }
                    pages("stats-monthly", 4)
                    // Yearly (owner's request).
                    for _ in 0..<6 { app.swipeDown() }
                    scope.tap(); Thread.sleep(forTimeInterval: 1)
                    let yearly = app.buttons["Yearly"].firstMatch
                    if yearly.waitForExistence(timeout: 3) { yearly.tap(); Thread.sleep(forTimeInterval: 2) }
                    pages("stats-yearly", 3)
                }
                back()
            }
            for _ in 0..<6 { app.swipeDown() }
            if open("profile-milestones") {
                shot("milestones")
                // A badge opens its detail: it spins, then settles with what it's for and the next level.
                let badge = app.buttons["milestone-week-streak"]
                if badge.waitForExistence(timeout: 3) { badge.tap(); Thread.sleep(forTimeInterval: 0.45); shot("milestone-spin"); Thread.sleep(forTimeInterval: 1.6); shot("milestone-detail") }
                let close = app.buttons["milestone-close"]
                if close.exists { close.tap(); Thread.sleep(forTimeInterval: 0.6) }
                back()
            }
            for _ in 0..<6 { app.swipeDown() }
            if open("profile-edit-name") || open("profile-avatar") { shot("editprofile") }
        }
    }

    /// Profile headers with long names, long hometowns and extra facts (favourites, blood type, died).
    func testProfileHeaderSnapshots() {
        for (kind, id) in [("character", 138100), ("character", 417), ("voice", 124390), ("cast", 172069), ("voice", 95065)] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--ui-profile-repairs", "--ui-profile-format=\(kind):\(id)"]
            app.launch()
            Thread.sleep(forTimeInterval: 4)
            for page in 0..<3 {
                let a = XCTAttachment(screenshot: app.screenshot()); a.name = "hdr-\(kind)\(id)-\(page)"; a.lifetime = .keepAlways; add(a)
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: .slow, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 1)
            }
            app.terminate()
        }
    }

    /// Glance (list, then grid), top to bottom.
    func testGlanceSnapshots() {
        capture(tab: "glance", name: "glance", pages: 4)
        capture(tab: "glance", name: "glancegrid", pages: 2) { app in
            let layout = app.buttons["glance-layout"]
            if layout.waitForExistence(timeout: 5) { layout.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Library top to bottom, then its Filters sheet.
    func testLibrarySnapshots() {
        capture(tab: "library", name: "library", pages: 3)
        capture(tab: "library", name: "libfilters", pages: 1) { app in
            let filters = app.buttons["library-filters"]
            if filters.waitForExistence(timeout: 5) { filters.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Scrolling down shrinks the tab bar; scrolling back up restores it.
    func testTabBarMinimizeSnapshots() {
        capture(tab: "home", name: "tabbar", pages: 3, extra: ["--ui-tabbar-minimize"])
        let app = XCUIApplication()
        app.swipeDown(); Thread.sleep(forTimeInterval: 1.2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "tabbar-restored"; shot.lifetime = .keepAlways; add(shot)
    }

    /// Profile → On this day: the carousel and every earlier month/year with a watch on this date.
    func testOnThisDaySnapshots() {
        capture(tab: "more", name: "onthisday", pages: 3, extra: ["--ui-on-this-day"]) { app in
            let profile = app.descendants(matching: .any)["settings-personal-profile"]
            for _ in 0..<6 where !(profile.exists && profile.isHittable) { app.swipeUp() }
            if profile.exists { profile.tap(); Thread.sleep(forTimeInterval: 2.5) }
            let card = app.descendants(matching: .any)["profile-on-this-day"]
            for _ in 0..<6 where !(card.exists && card.isHittable) { app.swipeUp() }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "onthisday-card"; shot.lifetime = .keepAlways; self.add(shot)
            if card.exists { card.tap() }
            Thread.sleep(forTimeInterval: 2.5)
        }
    }

    /// Statistics' Over time (per year) with a long, sparse history (a 1970 watch, then 2008 on).
    func testOverTimeSnapshots() {
        capture(tab: "more", name: "overtime", pages: 3, extra: ["--ui-old-watches"]) { app in
            let profile = app.descendants(matching: .any)["settings-personal-profile"]
            for _ in 0..<6 where !(profile.exists && profile.isHittable) { app.swipeUp() }
            if profile.exists { profile.tap(); Thread.sleep(forTimeInterval: 2.5) }
            let stats = app.buttons["profile-statistics"].firstMatch
            for _ in 0..<6 where !(stats.exists && stats.isHittable) { app.swipeUp() }
            if stats.exists { stats.tap() }
            Thread.sleep(forTimeInterval: 2.5)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Library as a real (bigger) library opens: five posters, "+N See all", genres.
    func testLibraryOverviewSnapshots() {
        capture(tab: "library", name: "liboverview", pages: 3, extra: ["--ui-many-titles"])
    }

    /// Explore top to bottom, a › page, Search Lab top to bottom, then its results.
    func testExploreSnapshots() {
        func openExplore(_ app: XCUIApplication) {
            let explore = app.buttons["explore-shortcut"]
            for _ in 0..<4 where !(explore.exists && explore.isHittable) { app.swipeUp() }
            if explore.exists { explore.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
        capture(tab: "home", name: "explore", pages: 4, open: openExplore)
        capture(tab: "home", name: "exploremore", pages: 2) { app in
            openExplore(app)
            let more = app.buttons["explore-more-rated-shows"]
            for _ in 0..<4 where !(more.exists && more.isHittable) { app.swipeUp() }
            if more.exists { more.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
        capture(tab: "home", name: "lab", pages: 4) { app in
            openExplore(app)
            app.buttons["explore-search-lab"].firstMatch.tap(); Thread.sleep(forTimeInterval: 2)
            for label in ["Animation", "TV-14", "7+", "2020s", "Returning", "Japanese", "Not yet"] {
                let chip = app.buttons[label].firstMatch
                for _ in 0..<4 where !(chip.exists && chip.isHittable) { app.swipeUp() }
                if chip.exists && chip.isHittable { chip.tap() }
            }
            for _ in 0..<6 { app.swipeDown() }
            Thread.sleep(forTimeInterval: 2)
        }
        capture(tab: "home", name: "labresults", pages: 2) { app in
            openExplore(app)
            app.buttons["explore-search-lab"].firstMatch.tap(); Thread.sleep(forTimeInterval: 2)
            for label in ["Animation", "7+"] {
                let chip = app.buttons[label].firstMatch
                for _ in 0..<4 where !(chip.exists && chip.isHittable) { app.swipeUp() }
                if chip.exists && chip.isHittable { chip.tap() }
            }
            app.buttons["search-lab-show"].firstMatch.tap(); Thread.sleep(forTimeInterval: 3)
        }
    }

    /// Canvas: Movies top to bottom, Shows, the Genres sheet with two picked, then Lists.
    func testCanvasSnapshots() {
        func openCanvas(_ app: XCUIApplication) {
            let canvas = app.buttons["canvas-shortcut"]
            for _ in 0..<4 where !(canvas.exists && canvas.isHittable) { app.swipeUp() }
            if canvas.exists { canvas.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
        capture(tab: "home", name: "canvas", pages: 3, open: openCanvas)
        capture(tab: "home", name: "canvasshows", pages: 1) { app in
            openCanvas(app); app.buttons["canvas-tab-shows"].tap(); Thread.sleep(forTimeInterval: 3)
        }
        capture(tab: "home", name: "canvasgenres", pages: 1) { app in
            openCanvas(app); app.buttons["canvas-genre"].tap(); Thread.sleep(forTimeInterval: 1.5)
            app.buttons["canvas-genre-Animation"].tap(); app.buttons["canvas-genre-Anime"].tap(); Thread.sleep(forTimeInterval: 1)
        }
        capture(tab: "home", name: "canvaslists", pages: 2) { app in
            openCanvas(app); app.buttons["canvas-tab-lists"].tap(); Thread.sleep(forTimeInterval: 3)
        }
    }

    /// Search: the start page top to bottom, then results for a query.
    func testSearchSnapshots() {
        capture(tab: "search", name: "search", pages: 3)
        capture(tab: "search", name: "searchresults", pages: 2) { app in
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 5) { field.tap(); field.typeText("Frieren"); app.keyboards.buttons["search"].firstMatch.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// A title that isn't in the library (Home → Recommended), top to bottom.
    func testPreviewSnapshots() {
        capture(tab: "home", name: "preview", pages: 8) { app in
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-recommended-' AND identifier != 'home-recommended-more'")).firstMatch
            for _ in 0..<6 where !(card.exists && card.isHittable) { app.swipeUp() }
            if card.exists { card.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// The title page's episodes as sideways cards.
    func testEpisodeGridSnapshots() {
        capture(tab: "home", name: "episodegrid", pages: 1) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let layout = app.buttons["episodes-layout"]
            for _ in 0..<6 where !(layout.exists && layout.isHittable) { app.swipeUp() }
            if layout.exists { layout.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// A saved title's "Show all N episodes" page.
    func testEpisodesPageSnapshots() {
        capture(tab: "home", name: "episodespage", pages: 1) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let all = app.buttons["title-all-episodes"]
            for _ in 0..<8 where !(all.exists && all.isHittable) { app.swipeUp() }
            if all.exists { all.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// The title page's ••• (clear glass), then Mark season as watched opening from its button.
    func testMarkSeasonSnapshots() {
        capture(tab: "home", name: "titlemore", pages: 1) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
        capture(tab: "home", name: "markseason", pages: 1) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let all = app.buttons["title-all-episodes"]
            for _ in 0..<8 where !(all.exists && all.isHittable) { app.swipeUp() }
            if all.exists { all.tap() }
            Thread.sleep(forTimeInterval: 2)
            let mark = app.buttons["episodes-mark-season"]
            for _ in 0..<10 where !(mark.exists && mark.isHittable) { app.swipeUp() }
            if mark.exists && mark.isHittable { mark.tap() }
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    /// Favourites: Characters (grid, then list), Cast, Voice actors, and a Most watched page.
    func testFavouritesSnapshots() {
        let extra = ["-anilistUser", "twilight29533", "--ui-favourites-gallery"]
        func openFavourites(_ app: XCUIApplication) {
            let all = app.buttons["home-favourites"]
            for _ in 0..<12 where !(all.exists && all.isHittable) { app.swipeUp() }
            if all.exists { all.tap() }
            Thread.sleep(forTimeInterval: 2.5)
            let characters = app.buttons["favourites-tab-character"]
            if characters.exists { characters.tap(); Thread.sleep(forTimeInterval: 1.5) }
        }
        capture(tab: "home", name: "favchars", pages: 2, extra: extra, open: openFavourites)
        capture(tab: "home", name: "favlist", pages: 1, extra: extra) { app in
            openFavourites(app)
            let list = app.buttons["Show favourites as list"]
            if list.exists { list.tap(); Thread.sleep(forTimeInterval: 1) }
        }
        capture(tab: "home", name: "favcast", pages: 1, extra: extra) { app in
            openFavourites(app); app.buttons["favourites-tab-cast"].tap(); Thread.sleep(forTimeInterval: 2)
        }
        capture(tab: "home", name: "favvoice", pages: 1, extra: extra) { app in
            openFavourites(app); app.buttons["favourites-tab-voice"].tap(); Thread.sleep(forTimeInterval: 2)
        }
        capture(tab: "home", name: "favmore", pages: 1, extra: extra) { app in
            openFavourites(app)
            let more = app.buttons["top-character-more"]
            if more.waitForExistence(timeout: 5) { more.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Airing calendar: Upcoming top to bottom, Catch-up, All, then the Genres sheet.
    func testCalendarSnapshots() {
        func openCalendar(_ app: XCUIApplication) {
            let calendar = app.buttons["home-calendar-more"]
            for _ in 0..<6 where !(calendar.exists && calendar.isHittable) { app.swipeUp() }
            if calendar.exists { calendar.tap() }
            Thread.sleep(forTimeInterval: 2.5)
        }
        capture(tab: "home", name: "calendar", pages: 2, open: openCalendar)
        capture(tab: "home", name: "calcatchup", pages: 1) { app in
            openCalendar(app); app.buttons["calendar-tab-Catch-up"].tap(); Thread.sleep(forTimeInterval: 1.5)
        }
        capture(tab: "home", name: "calall", pages: 1) { app in
            openCalendar(app); app.buttons["calendar-tab-All"].tap(); Thread.sleep(forTimeInterval: 1.5)
        }
        capture(tab: "home", name: "calgenres", pages: 1) { app in
            openCalendar(app); app.buttons["calendar-genres"].tap(); Thread.sleep(forTimeInterval: 1.5)
            let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar-genre-'")).firstMatch
            if chip.exists { chip.tap() }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    /// A preview title's "Show all N episodes" page.
    func testPreviewEpisodesSnapshots() {
        capture(tab: "home", name: "previewepisodes", pages: 2) { app in
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-recommended-' AND identifier != 'home-recommended-more'")).firstMatch
            for _ in 0..<6 where !(card.exists && card.isHittable) { app.swipeUp() }
            if card.exists { card.tap() }
            Thread.sleep(forTimeInterval: 3)
            let all = app.descendants(matching: .any)["catalog-all-episodes"]
            for _ in 0..<8 where !(all.exists && all.isHittable) { app.swipeUp() }
            if all.exists { all.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// A › page (More like this) from the title page, scrolled under its header.
    func testSeeAllPageSnapshots() {
        capture(tab: "home", name: "seeall", pages: 3) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let more = app.descendants(matching: .any)["title-related-all"]
            for _ in 0..<12 where !(more.exists && more.isHittable) { app.swipeUp() }
            if more.exists { more.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    /// The episode sheet: at rest, half-way through a swipe to the next episode, then settled.
    func testEpisodeSheetSnapshots() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-keep-launch-tab", "--ui-keep-home-layouts", "-launchTab", "home"]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 4)
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
        if title.waitForExistence(timeout: 10) { title.tap() }
        Thread.sleep(forTimeInterval: 3)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'title-episode-'")).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        guard row.exists else { return }
        row.tap(); Thread.sleep(forTimeInterval: 2); shot("sheet-0")
        // Hold half-way through a swipe.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.5); shot("sheet-1")
        app.swipeLeft(); Thread.sleep(forTimeInterval: 1.5); shot("sheet-2")
        app.buttons["Previous episode"].firstMatch.tap(); Thread.sleep(forTimeInterval: 1.5); shot("sheet-3")
    }

    /// Both full Episodes pages (saved title, then preview) in grid mode.
    func testEpisodesPageGridSnapshots() {
        capture(tab: "home", name: "gridsaved", pages: 1) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
            Thread.sleep(forTimeInterval: 3)
            let all = app.buttons["title-all-episodes"]
            for _ in 0..<8 where !(all.exists && all.isHittable) { app.swipeUp() }
            if all.exists { all.tap() }
            Thread.sleep(forTimeInterval: 2)
            let layout = app.buttons["episodes-page-layout"]
            if layout.waitForExistence(timeout: 5), layout.value as? String != "grid", layout.label.hasSuffix("grid") { layout.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
        capture(tab: "home", name: "gridpreview", pages: 1) { app in
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-recommended-' AND identifier != 'home-recommended-more'")).firstMatch
            for _ in 0..<6 where !(card.exists && card.isHittable) { app.swipeUp() }
            if card.exists { card.tap() }
            Thread.sleep(forTimeInterval: 3)
            let all = app.descendants(matching: .any)["catalog-all-episodes"]
            for _ in 0..<8 where !(all.exists && all.isHittable) { app.swipeUp() }
            if all.exists { all.tap() }
            Thread.sleep(forTimeInterval: 3)
            let layout = app.buttons["episodes-page-layout"]
            if layout.waitForExistence(timeout: 5), layout.label.hasSuffix("grid") { layout.tap() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func capture(tab: String, name: String, pages: Int, extra: [String] = [], open: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-keep-launch-tab", "--ui-keep-home-layouts", "-launchTab", tab] + extra
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 4)
        open?(app)
        for page in 0..<pages {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(name)-\(page)"
            shot.lifetime = .keepAlways
            add(shot)
            // Half a screen per step, without a fling, so neighbouring shots overlap.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.33))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1.2)
        }
    }
}
