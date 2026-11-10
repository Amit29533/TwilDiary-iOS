import XCTest

/// Screens captured top to bottom on sample data, to compare with the owner's design files.
/// Run on its own (`-only-testing:TwilDiaryUITests/DesignSnapshotTests`); it checks nothing.
@MainActor final class DesignSnapshotTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = true }

    func testHomeSnapshots() { capture(tab: "home", name: "home", pages: 7) }
    /// The title page of the show in Continue watching, top to bottom.
    func testShowSnapshots() {
        capture(tab: "home", name: "show", pages: 9) { app in
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'progress-title-'")).firstMatch
            if title.waitForExistence(timeout: 10) { title.tap() }
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

    private func capture(tab: String, name: String, pages: Int, open: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-design-data", "--ui-keep-launch-tab", "--ui-keep-home-layouts", "-launchTab", tab]
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
