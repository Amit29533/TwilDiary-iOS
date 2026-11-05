import XCTest
import UIKit

@MainActor final class ProfileFormattingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func open(_ kind: String, _ id: Int, large: Bool = false, headerPattern: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-profile-repairs", "--ui-profile-format=\(kind):\(id)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if headerPattern { app.launchArguments.append("--ui-profile-header-pattern") }
        app.launchEnvironment["TZ"] = "Asia/Kolkata"
        app.launch()
        let favourite = kind == "cast" ? "person-favourite" : kind == "voice" ? "voice-actor-favourite" : "character-favourite"
        XCTAssertTrue(app.buttons[favourite].waitForExistence(timeout: 15))
        XCTAssertEqual(app.tabBars.count, 0)
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<20 {
            let header = app.navigationBars.firstMatch.frame.maxY + 8, bottom = app.frame.maxY - 20
            if item.exists && item.isHittable && item.frame.minY >= header && (item.frame.maxY <= bottom || item.frame.height > bottom - header) { break }
            let upward = !item.exists || item.frame.minY >= header
            let distance: CGFloat
            if !item.exists { distance = app.frame.height * 0.3 }
            else { distance = min(app.frame.height * 0.4, max(45, upward ? item.frame.maxY - bottom + 12 : header - item.frame.minY + 12)) }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.75 : 0.3))
            start.press(forDuration: 0.03, thenDragTo: start.withOffset(CGVector(dx: 0, dy: upward ? -distance : distance)))
        }
        XCTAssertTrue(item.exists, item.identifier)
        XCTAssertTrue(item.isHittable, item.identifier)
        XCTAssertGreaterThanOrEqual(item.frame.minX, 12)
        XCTAssertLessThanOrEqual(item.frame.maxX, app.frame.width - 12)
    }
    /// One page per person: the role shows under the name, with no TMDB / AniList logo beside it.
    private func noHeaderLogo(_ app: XCUIApplication, role: String) {
        XCTAssertTrue(app.staticTexts[role].firstMatch.exists)
        XCTAssertFalse(app.buttons["person-tmdb"].exists)
        XCTAssertFalse(app.buttons["voice-actor-tmdb"].exists)
    }
    private func factPair(_ app: XCUIApplication, first: String, second: String) {
        let a = element(app, first), b = element(app, second)
        reveal(a, in: app)
        XCTAssertTrue(b.exists)
        XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 1)
        XCTAssertEqual(a.frame.height, b.frame.height, accuracy: 1)
        XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 1)
        XCTAssertGreaterThan(b.frame.minX, a.frame.maxX)
        XCTAssertLessThanOrEqual(a.frame.height, 76, "Short facts should use the compact borderless layout")
        XCTAssertTrue(a.label.hasPrefix(first.hasPrefix("character-") ? "Birthday" : "Born"), "Fact labels must precede their values")
        XCTAssertTrue(b.label.hasPrefix("Age"))
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func assertPortraitIsSharpBehindToolbar(_ app: XCUIApplication) {
        let shot = app.screenshot().image
        guard let image = shot.cgImage else { XCTFail("Missing header screenshot"); return }
        let scale = CGFloat(image.width) / app.frame.width
        let y = app.navigationBars.firstMatch.frame.midY
        var values: [Int] = []
        // This clear area lies between Back and the hidden compact name. The
        // alternating 4-point stripes should remain sharp beneath the toolbar.
        for x in 96..<128 {
            guard let pixel = image.cropping(to: CGRect(x: CGFloat(x) * scale, y: y * scale, width: 1, height: 1)) else { XCTFail("Missing header pixel"); return }
            var bytes = [UInt8](repeating: 0, count: 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
            }
            XCTAssertTrue(rendered); values.append(Int(bytes[0]))
        }
        XCTAssertGreaterThan((values.max() ?? 0) - (values.min() ?? 0), 100,
            "Portrait detail must remain sharp under the toolbar; hiding its background alone leaves iOS's scroll-edge blur")
    }
    func testPortraitStaysClearBehindPinnedControlsBeforeTheNameCollapses() {
        for (kind, id, prefix) in [("cast", 974169, "person"), ("character", 70069, "character"), ("voice", 100250, "voice-actor")] {
            let app = open(kind, id, headerPattern: true)
            let heart = app.buttons[prefix + "-favourite"], heartY = heart.frame.midY
            capture("Header pattern \(kind) initial portrait", app: app)
            assertPortraitIsSharpBehindToolbar(app)
            let hero = app.staticTexts[prefix + "-name"], initialHeroY = hero.frame.minY
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: app.navigationBars.firstMatch.frame.maxY + 56))
            // End with the finger held still. A quick release adds momentum and
            // can fling the hero into the compact phase before pixel sampling.
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -24)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
            capture("Header pattern \(kind) partly scrolled portrait", app: app)
            // UIKit can retain the hidden principal item's accessibility wrapper.
            // Check the visible hero's position and actual pixels, not AX existence.
            XCTAssertGreaterThan(initialHeroY - hero.frame.minY, 8, "The partial-scroll capture must actually move the portrait")
            XCTAssertGreaterThan(hero.frame.minY,
                                 app.navigationBars.firstMatch.frame.maxY + 8,
                                 "This sharpness sample must still show the expanded hero below the toolbar")
            assertPortraitIsSharpBehindToolbar(app)
            XCTAssertEqual(heart.frame.midY, heartY, accuracy: 2)
            XCTAssertTrue(heart.isHittable)
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testCastProfilesKeepLocationsContextAliasesAndAgeAtDeath() {
        executionTimeAllowance = 180
        for id in [974169, 1134684, 172069, 1116334, 1254672] {
            let app = open("cast", id)
            noHeaderLogo(app, role: "Actor")
            factPair(app, first: "person-birthday", second: "person-age")
            let place = element(app, "person-birthplace"); reveal(place, in: app)
            XCTAssertEqual(place.frame.width, app.frame.width - 28, accuracy: 2)
            if id == 974169 { XCTAssertTrue(app.buttons["person-source-role"].exists) }
            if id == 172069 { XCTAssertTrue(element(app, "person-age").label.contains("43")); XCTAssertTrue(element(app, "person-deathday").exists) }
            capture("Cast \(id) compact borderless facts and full location", app: app)
            let bio = element(app, "profile-biography"); reveal(bio, in: app)
            XCTAssertTrue(app.buttons["Expand biography"].exists)
            app.buttons["Expand biography"].tap()
            XCTAssertTrue(app.buttons["Collapse biography"].exists)
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testCharacterProfilesPreserveRangesYearOnlyDatesAndNativeRelationships() {
        executionTimeAllowance = 200
        for (id, age) in [(70069, "17 (physically)"), (176754, "1000+"), (138100, "6 (self asserted)"), (12, "14-15")] {
            let app = open("character", id)
            noHeaderLogo(app, role: "Character")
            if id == 70069 || id == 12 { factPair(app, first: "character-birthday", second: "character-age") }
            // AniList's page is still one tap away, in the Links row with the other sites.
            XCTAssertTrue(element(app, "profile-site-https://anilist.co/character/\(id)").exists)
            let value = element(app, "character-age"); reveal(value, in: app)
            XCTAssertTrue(value.label.contains(age))
            if id == 12 { XCTAssertTrue(element(app, "character-birthday").label.contains("1900")) }
            if id == 176754 { XCTAssertFalse(element(app, "character-birthday").exists) }
            capture("Character \(id) freeform age and optional facts", app: app)
            let bio = element(app, "profile-biography"); reveal(bio, in: app)
            if id == 176754 { XCTAssertFalse(app.buttons["Expand biography"].exists, "Short biographies have no empty More control") }
            if id == 138100 { XCTAssertTrue(app.staticTexts["Relatives"].exists) }
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testVoiceProfilesSeparateLinksFactsCareerAndBiography() {
        executionTimeAllowance = 180
        for id in [100250, 119331, 95065, 106787] {
            let app = open("voice", id)
            XCTAssertTrue(app.staticTexts["Voice actor"].exists)
            XCTAssertFalse(app.buttons["voice-actor-tmdb"].exists, "TMDB merges into this page; no separate profile")
            XCTAssertTrue(app.descendants(matching: .any)["voice-actor-watched"].label.contains("15 anime"))
            factPair(app, first: "voice-actor-birthday", second: "voice-actor-age")
            let home = element(app, "voice-actor-hometown"); reveal(home, in: app)
            XCTAssertEqual(home.frame.width, app.frame.width - 28, accuracy: 2)
            capture("Voice \(id) compact borderless facts and complete hometown", app: app)
            let links = element(app, "profile-links-section"); reveal(links, in: app)
            let bio = element(app, "voice-actor-biography"); reveal(bio, in: app)
            XCTAssertGreaterThan(bio.frame.minY, links.frame.maxY)
            XCTAssertFalse(bio.label.contains("Agency:"))
            XCTAssertFalse(bio.label.contains("Height:"))
            capture("Voice \(id) links separated from prose", app: app)
            XCTAssertEqual(app.tabBars.count, 0)
            app.terminate()
        }
    }
    func testLargeTextStacksFactsAndKeepsHeartsPinnedAcrossProfileTypes() {
        executionTimeAllowance = 240
        for (kind, id, prefix) in [("cast", 974169, "person"), ("character", 70069, "character"), ("voice", 95065, "voice-actor")] {
            let app = open(kind, id, large: true)
            let heart = app.buttons[prefix + "-favourite"], heartY = heart.frame.midY
            let first = element(app, prefix + "-birthday"); reveal(first, in: app)
            XCTAssertEqual(first.frame.width, app.frame.width - 28, accuracy: 2)
            let age = element(app, prefix + "-age"); reveal(age, in: app)
            XCTAssertGreaterThanOrEqual(age.frame.minY, first.frame.maxY)
            XCTAssertEqual(heart.frame.midY, heartY, accuracy: 2)
            XCTAssertTrue(heart.isHittable)
            XCTAssertEqual(app.tabBars.count, 0)
            capture("Large text \(kind) full-width facts and pinned heart", app: app)
            if kind != "cast" {
                let watched = app.buttons["profile-watched-frieren"]; reveal(watched, in: app)
                XCTAssertEqual(watched.frame.width, app.frame.width - 28, accuracy: 2, "Large-text credits use readable rows rather than narrow poster captions")
                capture("Large text \(kind) readable watched credit row", app: app)
                // Hit the empty trailing edge, beyond the artwork/text bounds
                // that excluded 53 points of the row in the failed candidate.
                let trailing = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.width - 18, dy: watched.frame.minY + 24))
                trailing.tap()
                let title = app.staticTexts["title-hero-name"]
                XCTAssertTrue(title.waitForExistence(timeout: 5), "The whole watched row opens its title")
                XCTAssertTrue(title.label.contains("Frieren"))
                XCTAssertEqual(app.tabBars.count, 0)
            }
            app.terminate()
        }
    }
}
