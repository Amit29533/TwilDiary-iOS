import XCTest

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

    private func probe(zoom: Bool) {
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-upcoming"] + (zoom ? [] : ["--ui-no-zoom"])
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
