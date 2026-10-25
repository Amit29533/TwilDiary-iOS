import XCTest
@testable import TwilDiary

final class ContinueCarouselTests: XCTestCase {
    func testPreviousAndNextWrapAndHandleEmptyOrRemovedSelection() {
        let ids = ["one", "two", "three"]
        XCTAssertEqual(ContinueCarouselPolicy.destination(ids: ids, current: "three", forward: true), "one")
        XCTAssertEqual(ContinueCarouselPolicy.destination(ids: ids, current: "one", forward: false), "three")
        XCTAssertEqual(ContinueCarouselPolicy.destination(ids: ids, current: "two", forward: true), "three")
        XCTAssertEqual(ContinueCarouselPolicy.destination(ids: ids, current: "removed", forward: false), "one")
        XCTAssertEqual(ContinueCarouselPolicy.destination(ids: ["one"], current: "one", forward: true), "one")
        XCTAssertNil(ContinueCarouselPolicy.destination(ids: [], current: nil, forward: true))
    }
    func testManualInteractionRequiresFiveSecondsAndRejectsBackwardOrInvalidClock() {
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(ContinueCarouselPolicy.cooldownEnded(at: date.addingTimeInterval(4.999), lastInteraction: date))
        XCTAssertTrue(ContinueCarouselPolicy.cooldownEnded(at: date.addingTimeInterval(5), lastInteraction: date))
        XCTAssertFalse(ContinueCarouselPolicy.cooldownEnded(at: date.addingTimeInterval(-1), lastInteraction: date))
        XCTAssertFalse(ContinueCarouselPolicy.cooldownEnded(at: Date(timeIntervalSince1970: .infinity), lastInteraction: date))
    }
}
