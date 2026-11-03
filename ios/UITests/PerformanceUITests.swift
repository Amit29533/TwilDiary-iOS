import XCTest

/// Simulator measurements are diagnostic baselines, not claims about physical-device frame rate.
@MainActor final class PerformanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func application() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-personal-profile-reset", "--ui-upcoming"]
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        return app
    }
    func testMeasuredApplicationLaunch() {
        let app = application()
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) { app.launch() }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
    }
    func testMeasuredHomeScrollCPUAndMemory() {
        let app = application(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Home"].tap()
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp(); app.swipeUp(); app.swipeDown(); app.swipeDown()
        }
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Home after measured scrolling"; image.lifetime = .keepAlways; add(image)
    }
}
