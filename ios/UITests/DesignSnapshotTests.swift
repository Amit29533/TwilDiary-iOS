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
