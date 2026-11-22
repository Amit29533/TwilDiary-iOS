import XCTest
@testable import TwilDiary

/// Calendar air times from TVmaze: read from its episode list, matched by day, else by number
/// within a day of TMDB's date.
final class EpisodeAirTimesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_960_000) // 2026-11-17

    private var episodes: Data {
        Data(#"""
        [{"season":2,"number":3,"airdate":"2026-11-14","airstamp":"2026-11-15T02:00:00+00:00"},
         {"season":2,"number":4,"airdate":"2026-11-21","airstamp":"2026-11-22T02:00:00+00:00"},
         {"season":2,"number":5,"airdate":"2026-11-21","airstamp":"2026-11-22T03:00:00+00:00"},
         {"season":1,"number":1,"airdate":"2019-01-01","airstamp":"2019-01-02T02:00:00+00:00"},
         {"season":2,"number":6,"airdate":"","airstamp":null}]
        """#.utf8)
    }

    func testDecodesEachDaysEarliestTimeAndKeepsOnlyNearbyEpisodes() throws {
        let show = TVmazeSchedule.decode(episodes, now: now)
        XCTAssertEqual(show.byDay["2026-11-14"], Date(timeIntervalSince1970: 1_794_708_000))
        XCTAssertEqual(show.byDay["2026-11-21"], Date(timeIntervalSince1970: 1_795_312_800), "two episodes that day: the first one's time")
        XCTAssertNil(show.byDay["2019-01-01"], "years-old episodes aren't kept")
        XCTAssertEqual(show.byNumber.count, 3)
    }

    func testPicksByDayThenByNumberWithinADay() {
        let show = TVmazeSchedule.decode(episodes, now: now)
        XCTAssertNotNil(TVmazeSchedule.pick(show, day: "2026-11-14", season: 9, number: 9), "the show's time that day, whatever the numbering")
        XCTAssertEqual(TVmazeSchedule.pick(show, day: "2026-11-15", season: 2, number: 3), Date(timeIntervalSince1970: 1_794_708_000), "a day off: matched by number")
        XCTAssertNil(TVmazeSchedule.pick(show, day: "2026-11-30", season: 2, number: 3), "too far from TMDB's date: no time rather than a wrong one")
        XCTAssertNil(TVmazeSchedule.pick(show, day: "2026-11-30", season: nil, number: nil))
    }

    func testDaysApart() {
        XCTAssertEqual(TVmazeSchedule.daysApart("2026-11-14", "2026-11-15"), 1)
        XCTAssertEqual(TVmazeSchedule.daysApart("2026-12-31", "2027-01-01"), 1)
        XCTAssertEqual(TVmazeSchedule.daysApart("2026-11-14", "2026-11-14"), 0)
        XCTAssertEqual(TVmazeSchedule.daysApart("bad", "2026-11-14"), .max)
    }

    @MainActor func testTodayRangeAndTabNames() {
        XCTAssertEqual(UniversalCalendarSection.range(1), "Today")
        XCTAssertEqual(UniversalCalendarSection.range(14), "Next 14 days")
        XCTAssertEqual(AiringCalendarView.Tab.allCases.map(\.title), ["Upcoming", "Missed", "Following", "Global"])
        XCTAssertEqual(AiringCalendarView.Tab.everything.rawValue, "Everything", "the saved tab keeps its value")
    }

    @MainActor func testGlobalLoadsTodayAndTomorrowFirstThenWeeks() {
        func steps(_ days: Int) -> [[Int]] { UniversalCalendarSection.steps(days).map { [$0.offset, $0.days] } }
        XCTAssertEqual(steps(1), [[0, 1]])
        XCTAssertEqual(steps(7), [[0, 2], [2, 5]])
        XCTAssertEqual(steps(14), [[0, 2], [2, 7], [9, 5]])
        XCTAssertEqual(steps(30), [[0, 2], [2, 7], [9, 7], [16, 7], [23, 7]])
    }
}
