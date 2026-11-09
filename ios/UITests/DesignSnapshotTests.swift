import XCTest

/// Screens captured top to bottom on sample data, to compare with the owner's design files.
/// Run on its own (`-only-testing:TwilDiaryUITests/DesignSnapshotTests`); it checks nothing.
@MainActor final class DesignSnapshotTests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = true }

    func testHomeSnapshots() { capture(tab: "home", name: "home", pages: 7) }

    private func capture(tab: String, name: String, pages: Int) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-keep-launch-tab", "--ui-keep-home-layouts", "-launchTab", tab]
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        Thread.sleep(forTimeInterval: 4)
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
