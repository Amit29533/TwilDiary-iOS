import Observation
import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class DashboardProjectionTests: XCTestCase {
    private let now = DiaryDate.parse("2026-10-23T12:00:00Z")!
    func testHomeProjectionRetainsHistoryOrderAndChangesWhenTheSnapshotChanges() async throws {
        let store = DiaryStore(); store.workspace = PreviewData.workspace
        let request = store.homeProjectionRequest(at: now)
        await store.prepareHomeProjection(request)
        let first = try XCTUnwrap(store.homeProjection)
        // Home groups recent watches into rows (RecentWatchGroup), so the projection keeps up to 40.
        XCTAssertEqual(first.recent.map(\.id), Array(HistoryQuery().entries(in: store.workspace).prefix(40)).map(\.id))
        XCTAssertEqual(first.watching.map(\.id), store.workspace.activeTitles.filter { $0.status == "watching" }.map(\.id))
        XCTAssertEqual(store.homeProjectionRequest(at: now.addingTimeInterval(1)), request)
        store.workspace = Workspace()
        XCTAssertEqual(store.homeProjection?.recent.map(\.id), first.recent.map(\.id))
        await store.prepareHomeProjection(store.homeProjectionRequest(at: now))
        let cleared = try XCTUnwrap(store.homeProjection)
        XCTAssertTrue(cleared.recent.isEmpty); XCTAssertTrue(cleared.watching.isEmpty); XCTAssertEqual(cleared.overview.watches, 0)
        await store.prepareHomeProjection(request)
        XCTAssertEqual(store.homeProjection?.overview.watches, 0)
    }
    func testUnchangedWorkspaceDoesNotRepublishHomeProjection() async throws {
        let store = DiaryStore()
        let snapshot = PreviewData.workspace
        store.workspace = snapshot
        await store.prepareHomeProjection(store.homeProjectionRequest(at: now))
        let first = try XCTUnwrap(store.homeProjection)
        withObservationTracking {
            _ = store.homeProjection
        } onChange: {
            XCTFail("An unchanged workspace should reuse the displayed Home projection")
        }
        store.workspace = snapshot
        await store.prepareHomeProjection(store.homeProjectionRequest(at: now))
        XCTAssertEqual(store.homeProjection?.recent.map(\.id), first.recent.map(\.id))
    }
    func testDayRolloverAndTimeZoneInvalidateHomeAndStatsProjections() async throws {
        let store = DiaryStore(); store.workspace = PreviewData.workspace
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0)), west = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let instant = try XCTUnwrap(DiaryDate.parse("2026-10-23T00:30:00Z"))
        for (zone, date) in [(utc, instant), (west, instant), (utc, instant.addingTimeInterval(86400))] {
            let calendar = DiaryDate.calendar(timeZone: zone)
            await store.prepareHomeProjection(store.homeProjectionRequest(at: date, calendar: calendar))
            let actual = try XCTUnwrap(store.homeProjection).overview
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
    func testWarmDashboardProjectionBenchmarkRecordsCostWithoutADeviceSpecificTimingGate() async throws {
        var snapshot = PreviewData.workspace
        let encoder = JSONEncoder()
        let template = try XCTUnwrap(snapshot.events.first)
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(template)) as? [String: Any])
        let rows: [[String: Any]] = (0..<1000).map { index in var row = source; row["id"] = "benchmark-\(index)"; return row }
        snapshot.events = try JSONDecoder().decode([WatchEvent].self, from: JSONSerialization.data(withJSONObject: rows))
        let store = DiaryStore(); store.workspace = snapshot
        let start = Date.timeIntervalSinceReferenceDate
        let request = store.homeProjectionRequest(at: now)
        await store.prepareHomeProjection(request)
        let cold = try XCTUnwrap(store.homeProjection)
        let coldStats = store.statsProjection(period: .month, year: nil, at: now)
        let coldMS = (Date.timeIntervalSinceReferenceDate - start) * 1000
        let warmStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<30 {
            await store.prepareHomeProjection(request)
            XCTAssertEqual(store.homeProjection?.recent.map(\.id), cold.recent.map(\.id))
            XCTAssertEqual(store.statsProjection(period: .month, year: nil, at: now), coldStats)
        }
        let warmMS = (Date.timeIntervalSinceReferenceDate - warmStart) * 1000 / 30
        print(String(format: "Dashboard fixture benchmark: 1000 events, cold %.2f ms, warm pair %.2f ms; timings are diagnostic, not device acceptance.", coldMS, warmMS))
    }
}
