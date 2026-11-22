import XCTest

/// JellySpace's pages against the QA run's stand-in Jellyfin server (ios/tools/qa/fake_jellyfin.py on
/// JELLY_QA_SERVER, from TEST_RUNNER_JELLY_QA_SERVER): Home's rows, a film (resumed), a show's
/// episodes and Next Episode, search, Face ID before entering, and the saved home on the next launch.
/// Without the server these tests are skipped.
@MainActor final class JellySpaceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var timings: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func setUp() async throws {
        try await super.setUp()
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        if let app {
            attach("End")
            if !timings.isEmpty {
                let text = XCTAttachment(string: timings.joined(separator: "\n")); text.name = "Timings"; text.lifetime = .keepAlways; add(text)
                print("JELLY-QA-TIMINGS " + name + "\n" + timings.joined(separator: "\n"))
            }
            app.terminate()
        }
        try await super.tearDown()
    }

    func testHomeShowsTheServersRows() throws {
        try launch()
        try enter()
        XCTAssertTrue(app.buttons["jellyspace-title-m2"].exists || scrollTo("jellyspace-title-m2"), "Paper Lantern (Continue Watching / newest) is on the home")
        attach("Home top")
        XCTAssertTrue(scrollTo("jellyspace-title-s1"), "Harbor Lights (Shows) is on the home")
        attach("Home shows")
        // Scrolled to the bottom and back: nothing crashes, the page stays.
        for _ in 0..<4 { app.swipeUp() }
        attach("Home bottom")
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["jellyspace-search"].exists, "Still on JellySpace's home")
    }

    func testAFilmResumesWhereYouStopped() throws {
        try launch()
        try enter()
        XCTAssertTrue(scrollTo("jellyspace-title-m2"), "Paper Lantern is on the home")
        let started = Date()
        app.buttons["jellyspace-title-m2"].firstMatch.tap()
        let play = app.buttons["jellyspace-detail-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The film's page opens with Play")
        timings.append(String(format: "film page: %.2f s", Date().timeIntervalSince(started)))
        attach("Film page")
        let tapped = Date()
        play.tap()
        XCTAssertTrue(app.buttons["jellyspace-close"].waitForExistence(timeout: 30), "The player opens")
        XCTAssertTrue(waitFor(timeout: 40) { ((try? self.position()) ?? 0) >= 55 }, "It resumes at about 1:00 (now \((try? position()) ?? -1) s)")
        timings.append(String(format: "play to playing (resumed): %.2f s", Date().timeIntervalSince(tapped)))
        attach("Resumed")
        XCTAssertTrue(app.buttons["jellyspace-start-over"].exists || app.descendants(matching: .any)["jellyspace-start-over"].exists, "Start over is offered")
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground)
        showControls()
        app.buttons["jellyspace-close"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Closing the player goes back to the film's page")
    }

    func testAShowsEpisodesAndNextEpisode() throws {
        try launch()
        try enter()
        XCTAssertTrue(scrollTo("jellyspace-title-s1"), "Harbor Lights is on the home")
        app.buttons["jellyspace-title-s1"].firstMatch.tap()
        let episode = app.buttons["jellyspace-episode-s1-s1e3"]
        XCTAssertTrue(episode.waitForExistence(timeout: 15) || scrollTo("jellyspace-episode-s1-s1e3"), "The show's episodes are listed")
        attach("Show page")
        episode.tap()
        XCTAssertTrue(app.buttons["jellyspace-close"].waitForExistence(timeout: 30), "The episode plays")
        XCTAssertTrue(waitFor(timeout: 40) { ((try? self.position()) ?? 0) > 0 }, "It starts")
        showControls()
        let next = app.buttons["jellyspace-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Next Episode is offered")
        attach("Episode playing")
        let tapped = Date()
        next.tap()
        XCTAssertTrue(waitFor(timeout: 30) { let p = (try? self.position()) ?? 999; return p > 0 && p < 30 }, "The next episode starts from the beginning")
        timings.append(String(format: "next episode to playing: %.2f s", Date().timeIntervalSince(tapped)))
        sleep(4)
        XCTAssertEqual(app.state, .runningForeground)
        attach("Next episode")
        // The Episodes panel lists the season.
        showControls()
        let episodes = app.buttons["jellyspace-episodes"]
        if episodes.exists {
            episodes.tap()
            XCTAssertTrue(app.descendants(matching: .any)["jellyspace-episodes-panel"].waitForExistence(timeout: 8), "The Episodes panel opens")
            attach("Episodes panel")
        }
    }

    func testSearchFindsAFilm() throws {
        try launch()
        try enter()
        app.buttons["jellyspace-search"].tap()
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Search opens with a field")
        field.tap()
        field.typeText("Copper")
        let result = app.buttons.matching(NSPredicate(format: "identifier == 'jellyspace-title-m8' OR label CONTAINS 'Copper Sky'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Copper Sky is found")
        attach("Search result")
    }

    /// Face ID's lock on: the scan happens on Home, and JellySpace opens only after it passes (no grey
    /// page first). The run's background helper answers Face ID with a match once the test asks
    /// (/tmp/qa-faceid-match).
    func testFaceIDBeforeEntering() throws {
        try launch(extra: ["-jellyspace.faceLock", "YES", "-jellyspace.faceLock.after", "0"])
        let logo = homeLogo()
        logo.tap()
        sleep(2)
        let search = app.buttons["jellyspace-search"]
        let prompted = !search.exists
        timings.append(prompted ? "Face ID asked on Home: yes" : "Face ID asked on Home: no (the Simulator let it through)")
        attach("After tapping JellySpace with the lock on")
        if prompted {
            XCTAssertFalse(app.staticTexts["JellySpace is locked"].exists, "No locked JellySpace page while Face ID asks")
            FileManager.default.createFile(atPath: "/tmp/qa-faceid-match", contents: Data())
        }
        XCTAssertTrue(search.waitForExistence(timeout: 25), "JellySpace opens after Face ID")
        XCTAssertFalse(app.staticTexts["JellySpace is locked"].exists, "And it isn't covered")
        attach("JellySpace after Face ID")
    }

    /// The home saved on disk shows at once on the next launch (refreshed in place after).
    func testTheSavedHomeShowsAtOnceNextLaunch() throws {
        try launch()
        try enter()
        sleep(4)
        app.terminate()
        try launch()
        let logo = homeLogo()
        let started = Date()
        logo.tap()
        XCTAssertTrue(app.buttons["jellyspace-title-m1"].waitForExistence(timeout: 20) || scrollTo("jellyspace-title-m1"), "The home's rows show")
        let took = Date().timeIntervalSince(started)
        timings.append(String(format: "second launch, tap to first poster: %.2f s", took))
        attach("Saved home")
    }

    /// Opening and closing JellySpace again and again: it opens quickly each time, and the app is fine.
    func testGoingInAndOutOfJellySpace() throws {
        try launch()
        try enter()
        var slowest = 0.0
        for round in 1...6 {
            // Back to Home: the bar's back button, else the edge swipe.
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable { back.tap() } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            }
            XCTAssertTrue(waitFor(timeout: 5) { !self.app.buttons["jellyspace-search"].exists }, "Back on Home (round \(round))")
            let logo = homeLogo()
            let started = Date()
            logo.tap()
            XCTAssertTrue(app.buttons["jellyspace-search"].waitForExistence(timeout: 10), "JellySpace opens (round \(round))")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'jellyspace-title-'")).firstMatch.waitForExistence(timeout: 10), "With its posters")
            let took = Date().timeIntervalSince(started)
            slowest = max(slowest, took)
            timings.append(String(format: "round %d, tap to posters: %.2f s", round, took))
        }
        timings.append(String(format: "slowest: %.2f s", slowest))
        XCTAssertLessThan(slowest, 3, "JellySpace opened within 3 s each time")
    }

    // MARK: - Helpers

    private func launch(extra: [String] = []) throws {
        let server = ProcessInfo.processInfo.environment["JELLY_QA_SERVER"] ?? ""
        guard !server.isEmpty else { throw XCTSkip("No stand-in Jellyfin server (JELLY_QA_SERVER)") }
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-jellyfinAddress", server, "--ui-jellyfin-key", "qa-key",
                               "-jellyspace.playback.ratingCard", "NO"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20), "The app opens")
    }

    private func homeLogo() -> XCUIElement {
        let home = app.tabBars.buttons["Home"]
        if home.waitForExistence(timeout: 10) { home.tap() }
        let logo = app.buttons["random-pick-logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "The JellySpace logo is on Home")
        return logo
    }

    /// From Home into JellySpace, timed to its page and to its first poster.
    private func enter() throws {
        let logo = homeLogo()
        let started = Date()
        logo.tap()
        XCTAssertTrue(app.buttons["jellyspace-search"].waitForExistence(timeout: 15), "JellySpace opens")
        timings.append(String(format: "tap to JellySpace page: %.2f s", Date().timeIntervalSince(started)))
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'jellyspace-title-' OR identifier BEGINSWITH 'jellyspace-hero-'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "JellySpace shows the server's titles")
        timings.append(String(format: "tap to first poster: %.2f s", Date().timeIntervalSince(started)))
        attach("JellySpace home")
    }

    @discardableResult
    private func scrollTo(_ id: String, swipes: Int = 8) -> Bool {
        let target = app.buttons[id].firstMatch
        for _ in 0..<swipes {
            if target.exists && target.isHittable { return true }
            app.swipeUp()
        }
        return target.exists
    }

    private func position() throws -> Double {
        showControls()
        let bar = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Position'")).firstMatch
        guard bar.waitForExistence(timeout: 5), let value = bar.value as? String else {
            throw NSError(domain: "JellyQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "No position on the bar"])
        }
        return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private func showControls() {
        let close = app.buttons["jellyspace-close"]
        if close.exists && close.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = waitFor(timeout: 3) { close.exists && close.isHittable }
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
