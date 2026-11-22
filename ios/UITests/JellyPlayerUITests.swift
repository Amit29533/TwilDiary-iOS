import XCTest

/// JellySpace's player in the Simulator, on both decoders (the QA run, `ios-namespace-qa.yml`): the app
/// opens a served test video at once (`--jellyspace-perf`, no Jellyfin server), and each test plays it,
/// uses the controls and menus while it plays, and checks the app is still there and still playing.
/// The video's address comes from JELLY_QA_VIDEO (xcodebuild passes TEST_RUNNER_JELLY_QA_VIDEO); without
/// a served video these tests are skipped.
@MainActor final class JellyPlayerUITests: XCTestCase {
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
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    // MARK: - The tests (each on AetherEngine and on mpv)

    func testAetherPlaysWithControlsUp() throws { try plays(mpv: false) }
    func testMPVPlaysWithControlsUp() throws { try plays(mpv: true) }
    func testAetherMenusWorkWhilePlaying() throws { try menus(mpv: false) }
    func testMPVMenusWorkWhilePlaying() throws { try menus(mpv: true) }
    func testAetherAdvancedTranslateAndDownloads() throws { try advanced(mpv: false) }
    func testMPVAdvancedTranslateAndDownloads() throws { try advanced(mpv: true) }
    func testAetherLockSeekPause() throws { try lockSeekPause(mpv: false) }
    func testMPVLockSeekPause() throws { try lockSeekPause(mpv: true) }
    func testAetherRotationAndBackground() throws { try rotationAndBackground(mpv: false) }
    func testMPVRotationAndBackground() throws { try rotationAndBackground(mpv: true) }
    func testAetherPictureModes() throws { try pictureModes(mpv: false) }
    func testMPVPictureModes() throws { try pictureModes(mpv: true) }
    func testSwitchDecoderWhilePlaying() throws { try switchDecoder(from: false) }
    func testSwitchDecoderBackWhilePlaying() throws { try switchDecoder(from: true) }
    func testAetherMenuStress() throws { try menuStress(mpv: false) }
    func testMPVMenuStress() throws { try menuStress(mpv: true) }
    func testAetherCloses() throws { try closes(mpv: false) }
    func testMPVCloses() throws { try closes(mpv: true) }

    // MARK: - What each test does

    /// Opens with the controls up (the crash on a phone: on the first frame of the controls) and keeps
    /// playing for a while.
    private func plays(mpv: Bool) throws {
        try open(mpv: mpv)
        let first = try position()
        sleep(12)
        alive("after 12 s of playing")
        let later = try position()
        XCTAssertGreaterThan(later, first + 5, "The video plays (\(first) s → \(later) s)")
        showControls()
        XCTAssertTrue(app.buttons["jellyspace-close"].isHittable, "The controls come back on a tap")
        attach("Playing with controls")
    }

    /// Speed, Audio & Subtitles and More open while the video plays, their items stay tappable after a
    /// few seconds (iOS greyed them out when the player redrew behind them), and a choice takes.
    private func menus(mpv: Bool) throws {
        try open(mpv: mpv)
        // Speed: 1.5x.
        try openMenu("jellyspace-speed", expecting: "1.5x")
        tapItem("1.5x")
        showControls()
        XCTAssertTrue(waitFor { (self.app.buttons["jellyspace-speed"].label).contains("1.5") }, "Speed shows 1.5x")
        // Back to 1x.
        try openMenu("jellyspace-speed", expecting: "1x")
        tapItem("1x")

        // Audio & Subtitles: subtitles off, then the Spanish track, then the second audio track.
        try openMenu("jellyspace-tracks", expecting: "Off")
        XCTAssertTrue(item("Download subtitles").exists, "Download subtitles is in Audio & Subtitles")
        attach("Audio and subtitles menu")
        tapItem("Off")
        alive("after subtitles off")
        try openMenu("jellyspace-tracks", expecting: "Spanish")
        tapItem("Spanish")
        alive("after the Spanish subtitles")
        try openMenu("jellyspace-tracks", expecting: "Japanese")
        tapItem("Japanese")
        alive("after the Japanese audio")

        // More: its items, and the sleep timer from its submenu.
        try openMenu("jellyspace-settings", expecting: "Sleep timer")
        for name in ["Picture", "Decoder", "Advanced options"] { XCTAssertTrue(item(name).exists, "More has \(name)") }
        XCTAssertTrue(item(mpv ? "Smooth motion" : "Dialogue boost").exists, "More has the decoder's own options")
        attach("More menu")
        try submenu("Sleep timer", expecting: "15 minutes")
        tapItem("15 minutes")
        showControls()
        XCTAssertTrue(app.descendants(matching: .any)["Sleep timer on"].waitForExistence(timeout: 5), "The sleep timer is on")
        // Upscaling (AetherEngine) or super resolution (mpv) from More: off.
        try openMenu("jellyspace-settings", expecting: mpv ? "Super resolution" : "Upscaling")
        try submenu(mpv ? "Super resolution" : "Upscaling", expecting: "Off")
        tapItem("Off")
        alive("after the upscaler change")
        if mpv {
            try openMenu("jellyspace-settings", expecting: "Smooth motion")
            try submenu("Smooth motion", expecting: "60 Hz")
            tapItem("60 Hz")
            sleep(4)
            alive("with smooth motion at 60 Hz")
        } else {
            try openMenu("jellyspace-settings", expecting: "Night mode")
            tapItem("Night mode")
            alive("with night mode")
        }
        let later = try position()
        sleep(3)
        XCTAssertGreaterThan(try position(), later, "Still playing after the menus")
    }

    /// Advanced options: the card, Translate's language menu (it couldn't be tapped while the video
    /// played), and Download subtitles' language menu.
    private func advanced(mpv: Bool) throws {
        try open(mpv: mpv)
        try openMenu("jellyspace-settings", expecting: "Advanced options")
        tapItem("Advanced options")
        let card = app.descendants(matching: .any)["jellyspace-advanced"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Advanced options opens")
        attach("Advanced options")
        let translate = app.descendants(matching: .any)["jellyspace-translate-subtitles"]
        XCTAssertTrue(translate.waitForExistence(timeout: 5), "Translate is on the card (the video has subtitles)")
        sleep(3)
        XCTAssertTrue(translate.isHittable, "Translate can be tapped while the video plays")
        let started = Date()
        translate.tap()
        XCTAssertTrue(item("Off").waitForExistence(timeout: 5), "Translate's languages open")
        timings.append(String(format: "translate menu: %.2f s", Date().timeIntervalSince(started)))
        sleep(3)
        XCTAssertTrue(item("Off").isHittable && item("Off").isEnabled, "Translate's languages stay tappable while the video plays")
        attach("Translate languages")
        tapItem("Off")
        alive("after Translate")
        XCTAssertTrue(card.exists, "The card stays after a language is picked")
        // The subtitle size and position sliders are there.
        XCTAssertTrue(app.descendants(matching: .any)["jellyspace-subtitle-position"].exists, "Subtitle position is on the card")
        // Download subtitles, and its language menu.
        let download = app.buttons["jellyspace-download-subtitles"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.tap()
        let language = app.descendants(matching: .any)["jellyspace-subtitle-language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5), "Download subtitles opens with its language")
        sleep(3)
        language.tap()
        XCTAssertTrue(item("Spanish").waitForExistence(timeout: 5), "The languages open")
        sleep(2)
        XCTAssertTrue(item("Spanish").isHittable, "The languages stay tappable while the video plays")
        attach("Download subtitles languages")
        tapItem("Spanish")
        alive("after picking a download language")
    }

    /// The lock (only the closed lock shows; a tap and the lock opens it), seeking on the bar, and pause.
    private func lockSeekPause(mpv: Bool) throws {
        try open(mpv: mpv)
        showControls()
        app.buttons["jellyspace-lock-screen"].tap()
        XCTAssertTrue(waitFor { !self.app.buttons["jellyspace-close"].isHittable }, "Locking hides the controls")
        attach("Locked")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let unlock = app.buttons["jellyspace-unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 3), "A tap shows the lock")
        XCTAssertLessThan(unlock.frame.midY, app.frame.height * 0.3, "The lock sits at the top, not in the middle")
        XCTAssertLessThan(unlock.frame.width, 80, "The lock is its usual size")
        attach("Lock shown")
        unlock.tap()
        XCTAssertTrue(app.buttons["jellyspace-close"].waitForExistence(timeout: 3) && app.buttons["jellyspace-close"].isHittable, "Unlocking brings the controls back")

        // Seek: three quarters along the bar.
        showControls()
        let bar = positionElement
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(timeout: 8) { ((try? self.position()) ?? 0) >= 80 }, "Seeking moves the video (now \((try? position()) ?? -1) s)")
        alive("after seeking")
        attach("After seeking")
        // Back 10 seconds.
        showControls()
        let before = try position()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back '")).firstMatch
        XCTAssertTrue(back.exists)
        back.tap()
        XCTAssertTrue(waitFor { ((try? self.position()) ?? 999) < before }, "Back jumps back")

        // Pause, and the time stays; play again.
        showControls()
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3), "Pause shows Play")
        let paused = try position()
        sleep(3)
        XCTAssertLessThanOrEqual(try position(), paused + 1, "Paused stays put")
        showControls()
        app.buttons["Play"].tap()
        sleep(3)
        XCTAssertGreaterThan(try position(), paused, "Play carries on")
    }

    /// Sideways and back, and the app in the background and back (the player and its picture stay).
    private func rotationAndBackground(mpv: Bool) throws {
        try open(mpv: mpv)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        alive("sideways")
        showControls()
        XCTAssertTrue(app.buttons["jellyspace-close"].isHittable, "The controls work sideways")
        attach("Landscape")
        try openMenu("jellyspace-settings", expecting: "Advanced options")
        tapItem("Advanced options")
        XCTAssertTrue(app.descendants(matching: .any)["jellyspace-advanced"].waitForExistence(timeout: 5), "Advanced options opens sideways")
        attach("Landscape advanced options")
        app.buttons["Close"].firstMatch.tap()
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        alive("upright again")
        attach("Portrait again")

        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)
        alive("back from the background")
        showControls()
        XCTAssertTrue(app.buttons["jellyspace-close"].waitForExistence(timeout: 5), "The player is still open after the background")
        if app.buttons["Play"].exists { app.buttons["Play"].tap() }
        let back = try position()
        sleep(4)
        XCTAssertGreaterThan(try position(), back, "Plays again after the background")
        attach("Back from the background")
    }

    /// Fit, Fill and Original from More → Picture (on mpv, the GPU path redraws: the screen went black).
    private func pictureModes(mpv: Bool) throws {
        try open(mpv: mpv)
        for mode in ["Fill", "Original", "Fit"] {
            try openMenu("jellyspace-settings", expecting: "Picture")
            try submenu("Picture", expecting: mode)
            tapItem(mode)
            sleep(3)
            alive("in \(mode)")
            attach("Picture \(mode)")
        }
        let at = try position()
        sleep(3)
        XCTAssertGreaterThan(try position(), at, "Still playing after the picture modes")
    }

    /// More → Decoder: from one to the other while it plays (the player hands over at the same place).
    private func switchDecoder(from mpv: Bool) throws {
        try open(mpv: mpv)
        sleep(4)
        let at = try position()
        try openMenu("jellyspace-settings", expecting: "Decoder")
        try submenu("Decoder", expecting: mpv ? "App" : "mpv")
        tapItem(mpv ? "App" : "mpv")
        sleep(10)
        alive("after switching the decoder")
        showControls()
        XCTAssertTrue(app.buttons["jellyspace-close"].waitForExistence(timeout: 10), "The player is open on the other decoder")
        let now = try position()
        XCTAssertGreaterThanOrEqual(now, at, "The other decoder carries on from the same place (\(at) s → \(now) s)")
        sleep(3)
        XCTAssertGreaterThan(try position(), now, "And plays")
        attach("Other decoder")
    }

    /// Menus opened and closed again and again while it plays: each opens quickly, nothing sticks.
    private func menuStress(mpv: Bool) throws {
        try open(mpv: mpv)
        var slowest = 0.0
        for round in 1...8 {
            for (menu, expected) in [("jellyspace-settings", "Advanced options"), ("jellyspace-speed", "1.5x"), ("jellyspace-tracks", "Off")] {
                let took = try openMenu(menu, expecting: expected, settle: 0)
                slowest = max(slowest, took)
                timings.append(String(format: "round %d %@: %.2f s", round, menu, took))
                dismissMenu()
            }
        }
        timings.append(String(format: "slowest: %.2f s", slowest))
        XCTAssertLessThan(slowest, 3, "Every menu opened within 3 s")
        alive("after opening the menus 24 times")
        let at = try position()
        sleep(3)
        XCTAssertGreaterThan(try position(), at, "Still playing")
    }

    /// Close: the player goes, and the app stays.
    private func closes(mpv: Bool) throws {
        try open(mpv: mpv)
        sleep(5)
        showControls()
        app.buttons["jellyspace-close"].tap()
        XCTAssertTrue(waitFor(timeout: 8) { !self.app.buttons["jellyspace-close"].exists }, "The player closes")
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "The app is still running after the player closes")
        attach("Closed")
    }

    // MARK: - Helpers

    private func open(mpv: Bool) throws {
        let address = ProcessInfo.processInfo.environment["JELLY_QA_VIDEO"] ?? ""
        guard !address.isEmpty else { throw XCTSkip("No served test video (JELLY_QA_VIDEO)") }
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--jellyspace-perf", address] + (mpv ? ["--jellyspace-perf-mpv"] : [])
            + ["-jellyspace.playback.ratingCard", "NO", "-jellyspace.faceLock", "NO"]
        // The run's settings for the app itself (a sanitizer's log file): JELLY_QA_APP_<NAME> → <NAME>.
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("JELLY_QA_APP_") {
            app.launchEnvironment[String(key.dropFirst("JELLY_QA_APP_".count))] = value
        }
        let started = Date()
        app.launch()
        XCTAssertTrue(app.buttons["jellyspace-close"].waitForExistence(timeout: 40), "The player opens")
        XCTAssertTrue(waitFor(timeout: 40) { ((try? self.position()) ?? 0) > 0 }, "The video starts")
        timings.append(String(format: "open to playing: %.2f s", Date().timeIntervalSince(started)))
        attach("Opened")
    }

    private var positionElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Position'")).firstMatch
    }

    /// The video's time in seconds, from the bar ("1:05" or "1:02:03").
    private func position() throws -> Double {
        showControls()
        let bar = positionElement
        guard bar.waitForExistence(timeout: 5), let value = bar.value as? String else {
            throw NSError(domain: "JellyQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "No position on the bar"])
        }
        return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// The controls up (a tap in the upper middle, clear of the buttons, when they're hidden).
    private func showControls() {
        let close = app.buttons["jellyspace-close"]
        if close.exists && close.isHittable { return }
        if app.buttons["jellyspace-unlock"].exists { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = waitFor(timeout: 3) { close.exists && close.isHittable }
    }

    /// A menu button tapped: waits for one of its items, then a few seconds more while the video
    /// plays, and checks the item is still tappable. Returns how long it took to open.
    @discardableResult
    private func openMenu(_ id: String, expecting expected: String, settle: UInt32 = 3) throws -> Double {
        showControls()
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(id) is there")
        XCTAssertTrue(button.isHittable, "\(id) can be tapped")
        let started = Date()
        button.tap()
        let target = item(expected)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(id) opens with \(expected)")
        let took = Date().timeIntervalSince(started)
        if settle > 0 {
            sleep(settle)
            XCTAssertTrue(target.exists && target.isHittable && target.isEnabled, "\(expected) in \(id) is still tappable \(settle) s later, while the video plays")
            alive("with \(id) open")
        }
        return took
    }

    /// A submenu inside an open menu.
    private func submenu(_ name: String, expecting expected: String) throws {
        let row = item(name)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) is in the menu")
        row.tap()
        XCTAssertTrue(item(expected).waitForExistence(timeout: 5), "\(name) opens with \(expected)")
        sleep(2)
        XCTAssertTrue(item(expected).isHittable, "\(expected) in \(name) stays tappable while the video plays")
    }

    /// A menu item by its name (the first one whose label starts with it, as tracks read "Spanish · …").
    private func item(_ name: String) -> XCUIElement {
        let exact = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        if exact.exists { return exact }
        let starts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if starts.exists { return starts }
        return exact
    }

    private func tapItem(_ name: String) {
        let target = item(name)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(name) is there")
        target.tap()
        sleep(1)
    }

    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(1)
    }

    /// The app hasn't crashed or quit.
    private func alive(_ when: String) {
        XCTAssertEqual(app.state, .runningForeground, "The app is running \(when)")
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
