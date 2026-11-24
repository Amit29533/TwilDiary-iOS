import XCTest
import SwiftUI
@testable import TwilDiary

/// Settings → Text size: iPhone's Text Size by default, or your own size within 80%–140%.
final class TextScaleTests: XCTestCase {
    func testTextFollowsIPhoneUntilYouSetYourOwnSize() throws {
        let name = "text-scale-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertEqual(TextScale.value(for: .large, defaults: defaults), 1)
        XCTAssertEqual(TextScale.value(for: .xxLarge, defaults: defaults), 1.15)

        defaults.set(false, forKey: TextScale.followsKey)
        defaults.set(1.2, forKey: TextScale.customKey)
        XCTAssertEqual(TextScale.value(for: .xxLarge, defaults: defaults), 1.2, accuracy: 0.0001)

        defaults.set(2.0, forKey: TextScale.customKey)
        XCTAssertEqual(TextScale.value(for: .large, defaults: defaults), 1.4, accuracy: 0.0001)
        defaults.set(0.5, forKey: TextScale.customKey)
        XCTAssertEqual(TextScale.value(for: .large, defaults: defaults), 0.8, accuracy: 0.0001)

        defaults.set(true, forKey: TextScale.followsKey)
        XCTAssertEqual(TextScale.value(for: .xSmall, defaults: defaults), 0.85)
    }

    func testPercentLabels() {
        XCTAssertEqual(TextSizeView.percent(1), "100%")
        XCTAssertEqual(TextSizeView.percent(1.15), "115%")
    }
}
