import XCTest
import ObjectiveC

/// How soon the next title opens after coming back from one (owner's video: after going back, taps
/// seemed ignored for a second or more). Runs only with TEST_RUNNER_NAV_PROBE=1
/// (ios-namespace-navprobe.yml). Each round stays on a title a moment, goes back and at once taps
/// the next poster: XCUITest taps only once the app is idle (its animations finished, its main
/// thread free), so `wait` is how long a tap right after Back had to wait. With and without the zoom
/// transition, on the UI-test diary (no network: nothing a title page downloads is in it).
@MainActor final class NavigationRoundTripProbe: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NAV_PROBE"] == "1", "The navigation probe runs on its own.")
        continueAfterFailure = true
    }

    func testWithZoom() { probe(zoom: true) }
    func testWithoutZoom() { probe(zoom: false) }
    /// The title's details, cast and related titles answering 0.7 s late, as a phone's network does:
    /// they arrive around Back and after it.
    func testWithZoomSlowMetadata() { probe(zoom: true, slow: true) }
    /// Back, then the other title tapped 0.15 s later, as in the owner's videos. With UIKit's zoom the
    /// tap waited for the pop's end (0.86 s; the title opened about 1.2 s after Back); with the card
    /// (CardTransition) the pop is immediate. ("--ui-no-zoom" no longer changes anything.)
    func testTapDuringZoomBack() { tapDuringBack(zoom: true) }
    /// Pictures of a title opening as a card and closing into its poster, a few moments apart (for
    /// looking at: the card growing out of the right poster and shrinking back into it).
    func testCardFrames() {
        executionTimeAllowance = 200
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-upcoming", "--ui-nav-timing"]
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Library"].tap()
        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'title-'"))
        guard posters.element(boundBy: 1).waitForExistence(timeout: 10) else { XCTFail("no posters"); return }
        let frame = posters.element(boundBy: 1).frame
        Thread.sleep(forTimeInterval: 1)
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        shot("0 before")
        Self.stopWaitingForIdle()
        let start = Date()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        for _ in 0..<5 { shot(String(format: "open %.2fs", Date().timeIntervalSince(start))) }
        Thread.sleep(forTimeInterval: 1)
        shot("open done")
        let back = Date()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<5 { shot(String(format: "close %.2fs", Date().timeIntervalSince(back))) }
        Thread.sleep(forTimeInterval: 1)
        shot("close done")
        let timing = app.descendants(matching: .any)["nav-timing"]
        print("NAV-PROBE card frames app: " + (timing.exists ? timing.label : "no timing element"))
    }
    func testTapDuringSlideBack() { tapDuringBack(zoom: false) }

    private func tapDuringBack(zoom: Bool) {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-upcoming", "--ui-nav-timing"] + (zoom ? [] : ["--ui-no-zoom"])
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Library"].tap()
        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'title-'"))
        guard posters.element(boundBy: 1).waitForExistence(timeout: 10), posters.element(boundBy: 1).isHittable else {
            XCTFail("Library has fewer than two posters on screen"); return
        }
        let ids = [posters.element(boundBy: 0).identifier, posters.element(boundBy: 1).identifier]
        let frames = ids.map { app.buttons[$0].frame }
        let heroes = app.staticTexts.matching(identifier: "title-hero-name")
        func showing(_ name: String) -> Bool { heroes.allElementsBoundByIndex.contains { $0.exists && $0.label == name } }
        // Each title's name as its page shows it (the ordinary way, waiting as XCUITest does).
        var names: [String] = []
        for id in ids {
            app.buttons[id].tap()
            XCTAssertTrue(heroes.firstMatch.waitForExistence(timeout: 8))
            names.append(heroes.firstMatch.label)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        Self.stopWaitingForIdle()
        func tap(_ index: Int) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frames[index].midX, dy: frames[index].midY)).tap()
        }
        tap(0)
        Thread.sleep(forTimeInterval: 1.5)
        var opened = 0
        for round in 0..<6 {
            let next = (round + 1) % 2
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let back = Date()
            Thread.sleep(forTimeInterval: 0.15)
            tap(next)
            var at: Double?
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if showing(names[next]) { at = Date().timeIntervalSince(back); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let timing = app.descendants(matching: .any)["nav-timing"]
            print(String(format: "NAV-PROBE tap-during-back zoom=%@ round=%d opened=%@", zoom ? "on" : "off", round,
                         at.map { String(format: "yes after %.2fs", $0) } ?? "NO")
                  + " app: " + (timing.exists ? timing.label : "no timing element"))
            if let at { opened += 1; _ = at } else { tap(next) }
            Thread.sleep(forTimeInterval: 1.5)
        }
        print("NAV-PROBE tap-during-back zoom=\(zoom ? "on" : "off"): opened \(opened) of 6")
    }

    /// XCUITest taps only once the app is idle (every animation finished); the owner tapped before that.
    private static func stopWaitingForIdle() {
        guard let process = NSClassFromString("XCUIApplicationProcess") else { print("NAV-PROBE no XCUIApplicationProcess"); return }
        var replaced: [String] = []
        if let method = class_getInstanceMethod(process, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")) {
            let skip: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(skip))
            replaced.append("isPreEvent")
        }
        if let method = class_getInstanceMethod(process, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")) {
            let skip: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(skip))
            replaced.append("plain")
        }
        print("NAV-PROBE idle waits off: " + (replaced.isEmpty ? "NONE FOUND" : replaced.joined(separator: ", ")))
    }

    private func probe(zoom: Bool, slow: Bool = false) {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-upcoming", "--ui-nav-timing"] + (zoom ? [] : ["--ui-no-zoom"]) + (slow ? ["--ui-slow-metadata"] : [])
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        // Library's posters (they zoom into their pages, as Home's Up next does; the test diary has
        // one title planned, so Home's row has a single poster).
        app.tabBars.buttons["Library"].tap()
        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'title-'"))
        let second = posters.element(boundBy: 1)
        _ = second.waitForExistence(timeout: 10)
        guard posters.count >= 2, second.isHittable else {
            print("NAV-PROBE hierarchy: " + String(app.debugDescription.prefix(6000)))
            XCTFail("Library has fewer than two posters on screen"); return
        }
        let ids = [posters.element(boundBy: 0).identifier, posters.element(boundBy: 1).identifier]
        let page = app.buttons["title-personal-rating"]
        app.buttons[ids[0]].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        var waits: [Double] = []
        for round in 0..<6 {
            let visit = round.isMultiple(of: 2) ? 0.6 : 1.6
            Thread.sleep(forTimeInterval: visit)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let back = Date()
            // The app's own timing: how long UIKit took to finish going back, and the main thread's
            // hold-ups after Back (nothing asked of the app meanwhile).
            Thread.sleep(forTimeInterval: 3)
            let timing = app.descendants(matching: .any)["nav-timing"]
            print("NAV-PROBE zoom=\(zoom ? "on" : "off") round=\(round) app: " + (timing.exists ? timing.label : "no timing element"))
            app.buttons[ids[(round + 1) % 2]].tap()
            let tapped = Date().timeIntervalSince(back)
            let shown = page.waitForExistence(timeout: 8)
            let open = Date().timeIntervalSince(back)
            waits.append(tapped)
            print(String(format: "NAV-PROBE zoom=%@ round=%d visit=%.1fs wait=%.2fs page-after-back=%.2fs opened=%@",
                         zoom ? "on" : "off", round, visit, tapped, open, shown ? "yes" : "NO"))
            XCTAssertTrue(shown, "round \(round): the next title didn't open")
        }
        print(String(format: "NAV-PROBE zoom=%@ average wait=%.2fs longest=%.2fs", zoom ? "on" : "off",
                     waits.reduce(0, +) / Double(max(1, waits.count)), waits.max() ?? 0))
    }
}
