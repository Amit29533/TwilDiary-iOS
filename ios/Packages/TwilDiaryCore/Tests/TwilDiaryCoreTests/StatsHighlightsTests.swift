import Foundation
import Testing
@testable import TwilDiaryCore

private func title(_ id: String, category: String, runtime: Int) -> [String: Any] {
    ["id": id, "name": id, "category": category, "overview": "", "genres": [String](), "status": "watching", "favorite": false, "notes": "", "runtimeMinutes": runtime]
}
private func play(_ id: String, title: String, episode: String?, at: String) -> [String: Any] {
    var value: [String: Any] = ["id": id, "operationId": id, "titleId": title, "watchedAt": at, "recordedAt": at, "origin": "manual", "version": 1]
    if let episode { value["episodeId"] = episode }
    return value
}

/// A three-episode late-night binge, a movie watched twice, and one bulk-imported day
/// holding 50 episodes (25 hours) under a single date.
private func workspace() throws -> Workspace {
    var events = [
        play("s1", title: "s", episode: "s-e1", at: "2026-10-01T23:00:00.000Z"),
        play("s2", title: "s", episode: "s-e2", at: "2026-10-01T23:30:00.000Z"),
        play("s3", title: "s", episode: "s-e3", at: "2026-10-01T23:50:00.000Z"),
        play("m1", title: "m", episode: nil, at: "2026-10-02T12:00:00.000Z"),
        play("m2", title: "m", episode: nil, at: "2026-10-05T12:00:00.000Z")
    ]
    for index in 1...50 { events.append(play("b\(index)", title: "bulk", episode: "bulk-e\(index)", at: "2026-10-03T00:00:00.000Z")) }
    let value: [String: Any] = ["titles": [title("s", category: "show", runtime: 30), title("m", category: "movie", runtime: 100), title("bulk", category: "show", runtime: 30)],
                                "episodes": [[String: Any]](), "events": events, "locations": [[String: Any]]()]
    return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func highlightsLeaveBulkImportedDaysOutOfBusiestDayAverageAndBinges() throws {
    let data = try workspace(), utc = try #require(TimeZone(identifier: "UTC"))
    let trend = StatsOverview(workspace: data, period: .all, now: try #require(DiaryDate.parse("2026-10-05T18:00:00.000Z")), timeZone: utc).trend
    let value = StatsHighlights(workspace: data, trend: trend, timeZone: utc)
    #expect(value.topTitleIDs == ["bulk", "m", "s"])
    #expect(value.topMinutes == 1500); #expect(value.topPlays == 50)
    #expect(value.bulkDays == 1)
    #expect(value.busiest == StatsHighlights.Day(date: "2026-10-05", minutes: 100), "Ties go to the latest day; the 25-hour day is left out")
    #expect(value.averageMinutes == Double(90 + 100 + 100) / Double(trend.days))
    #expect(value.binge == StatsHighlights.Binge(titleID: "s", episodes: 3, date: "2026-10-01"))
    #expect(value.episodes == 53); #expect(value.movies == 2); #expect(value.minutes == 1790)
}

@Test func funFactsCountLateWatchesFavouriteDaysRewatchesAndNewStarts() throws {
    let data = try workspace(), utc = try #require(TimeZone(identifier: "UTC"))
    let trend = StatsOverview(workspace: data, period: .all, now: try #require(DiaryDate.parse("2026-10-05T18:00:00.000Z")), timeZone: utc).trend
    let value = StatsHighlights(workspace: data, trend: trend, timeZone: utc)
    #expect(value.nightOwl == 60, "Three of five timed plays are after 22:00; midnight imports are not timed")
    #expect(value.weekday == StatsHighlights.Weekday(name: "Thursdays", share: 60))
    #expect(value.rewatches == 1)
    #expect(value.newStarts == 3)
    #expect(StatsHighlights.shortDate("2026-05-27") == "27 May")
    #expect(StatsHighlights.shortDate("not a day") == "not a day")
}
