import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class DashboardProjectionTests: XCTestCase {
    private let now = DiaryDate.parse("2026-10-23T12:00:00Z")!
    func testHomeProjectionRetainsHistoryOrderAndChangesWhenTheSnapshotChanges() {
        let store = DiaryStore(); store.workspace = PreviewData.workspace
        let first = store.homeProjection(at: now)
        XCTAssertEqual(first.recent.map(\.id), Array(HistoryQuery().entries(in: store.workspace).prefix(4)).map(\.id))
        XCTAssertEqual(first.watching.map(\.id), store.workspace.activeTitles.filter { $0.status == "watching" }.map(\.id))
        let repeated = store.homeProjection(at: now.addingTimeInterval(1))
        XCTAssertEqual(repeated.recent.map(\.id), first.recent.map(\.id))
        store.workspace = Workspace()
        let cleared = store.homeProjection(at: now)
        XCTAssertTrue(cleared.recent.isEmpty); XCTAssertTrue(cleared.watching.isEmpty); XCTAssertEqual(cleared.overview.watches, 0)
    }
    func testDayRolloverAndTimeZoneInvalidateHomeAndStatsProjections() throws {
        let store = DiaryStore(); store.workspace = PreviewData.workspace
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0)), west = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let instant = try XCTUnwrap(DiaryDate.parse("2026-10-23T00:30:00Z"))
        for (zone, date) in [(utc, instant), (west, instant), (utc, instant.addingTimeInterval(86400))] {
            let calendar = DiaryDate.calendar(timeZone: zone)
            let actual = store.homeProjection(at: date, calendar: calendar).overview
            let expected = HomeOverview(workspace: store.workspace, now: date, calendar: calendar)
            XCTAssertEqual(actual.days.map(\.date), expected.days.map(\.date))
            XCTAssertEqual(actual.days.map(\.future), expected.days.map(\.future))
            XCTAssertEqual(store.statsProjection(period: .today, year: nil, at: date, timeZone: zone),
                StatsOverview(workspace: store.workspace, period: .today, year: nil, now: date, timeZone: zone))
        }
    }
    func testStatsRangeYearAndSnapshotChangesNeverReuseThePreviousChart() {
        let store = DiaryStore(); store.workspace = PreviewData.workspace
        for (period, year) in [(Period.today, nil as Int?), (.all, nil), (.year, 2025), (.month, nil)] {
            let actual = store.statsProjection(period: period, year: year, at: now)
            XCTAssertEqual(actual, StatsOverview(workspace: store.workspace, period: period, year: year, now: now))
        }
        store.workspace = Workspace()
        XCTAssertEqual(store.statsProjection(period: .month, year: nil, at: now), StatsOverview(workspace: Workspace(), period: .month, now: now))
    }
    func testWarmDashboardProjectionBenchmarkRecordsCostWithoutADeviceSpecificTimingGate() throws {
        var snapshot = PreviewData.workspace
        let encoder = JSONEncoder()
        let template = try XCTUnwrap(snapshot.events.first)
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(template)) as? [String: Any])
        let rows: [[String: Any]] = (0..<1000).map { index in var row = source; row["id"] = "benchmark-\(index)"; return row }
        snapshot.events = try JSONDecoder().decode([WatchEvent].self, from: JSONSerialization.data(withJSONObject: rows))
        let store = DiaryStore(); store.workspace = snapshot
        let start = Date.timeIntervalSinceReferenceDate
        let cold = store.homeProjection(at: now)
        let coldStats = store.statsProjection(period: .month, year: nil, at: now)
        let coldMS = (Date.timeIntervalSinceReferenceDate - start) * 1000
        let warmStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<30 {
            XCTAssertEqual(store.homeProjection(at: now).recent.map(\.id), cold.recent.map(\.id))
            XCTAssertEqual(store.statsProjection(period: .month, year: nil, at: now), coldStats)
        }
        let warmMS = (Date.timeIntervalSinceReferenceDate - warmStart) * 1000 / 30
        print(String(format: "Dashboard fixture benchmark: 1000 events, cold %.2f ms, warm pair %.2f ms; timings are diagnostic, not device acceptance.", coldMS, warmMS))
    }
}
