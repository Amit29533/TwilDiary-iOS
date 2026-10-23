import XCTest

@MainActor final class NativeScreensTests: XCTestCase {
    func testNativeTabsAndTitleNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pick up where you left off"].waitForExistence(timeout: 10))
        capture("Home")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Search library"].waitForExistence(timeout: 5))
        capture("Library")
        app.buttons["title-again"].tap()
        XCTAssertTrue(app.staticTexts["Episodes"].waitForExistence(timeout: 5))
        capture("Title detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Glance"].tap()
        XCTAssertTrue(app.staticTexts["% complete"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'complete'")).firstMatch.waitForExistence(timeout: 5))
        capture("Glance")
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Watch time"].waitForExistence(timeout: 5))
        capture("Stats")
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
        capture("More")
    }
    func testLibrarySearchAndSelectionPersistAcrossTabs() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.tabBars.buttons["Library"].tap(); app.buttons["Search library"].tap()
        let search = app.textFields["library-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Frieren\n")
        XCTAssertTrue(app.buttons["title-frieren"].exists)
        XCTAssertFalse(app.buttons["title-again"].exists)
        app.tabBars.buttons["Home"].tap(); app.tabBars.buttons["Library"].tap()
        XCTAssertEqual(search.value as? String, "Frieren")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
