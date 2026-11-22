import Foundation
import Testing
@testable import TwilDiaryCore

private func title(_ id: String, category: String, runtime: Int, year: Int, score: Double? = nil) -> [String: Any] {
    var value: [String: Any] = ["id": id, "name": id, "category": category, "overview": "", "genres": [String](), "status": "watching", "favorite": false, "notes": "", "runtimeMinutes": runtime, "year": year]
    if let score { value["score"] = score }
    return value
}
private func play(_ id: String, title: String, episode: String?, at: String) -> [String: Any] {
    var value: [String: Any] = ["id": id, "operationId": id, "titleId": title, "watchedAt": at, "recordedAt": at, "origin": "manual", "version": 1]
    if let episode { value["episodeId"] = episode }
    return value
}

/// A three-episode Wednesday marathon, a movie watched twice (a rewatch) and a 2025 episode.
private func workspace() throws -> Workspace {
    let events = [
        play("s1", title: "show", episode: "e1", at: "2026-11-04T16:00:00.000Z"),
        play("s2", title: "show", episode: "e2", at: "2026-11-04T16:30:00.000Z"),
        play("s3", title: "show", episode: "e3", at: "2026-11-04T17:00:00.000Z"),
        play("m1", title: "film", episode: nil, at: "2026-10-02T21:00:00.000Z"),
        play("m2", title: "film", episode: nil, at: "2026-11-05T21:00:00.000Z"),
        play("o1", title: "old", episode: "o-e1", at: "2025-01-06T10:00:00.000Z")
    ]
    let value: [String: Any] = ["titles": [title("show", category: "anime", runtime: 24, year: 2022, score: 8),
                                           title("film", category: "movie", runtime: 120, year: 2016, score: 10),
                                           title("old", category: "show", runtime: 45, year: 1999)],
                                "episodes": [[String: Any]](), "events": events, "locations": [[String: Any]]()]
    return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func statsInsightsCountKindsTimeHabitsAndTaste() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(DiaryDate.parse("2026-11-09T12:00:00.000Z"))
    let value = StatsInsights(workspace: try workspace(), now: now, timeZone: utc)
    #expect(value.episodes == 4 && value.shows == 2 && value.movies == 1)
    #expect(value.showMinutes == 24 * 3 + 45 && value.movieMinutes == 240 && value.totalMinutes == 357)
    #expect(value.monthPlays == 4 && value.monthMinutes == 24 * 3 + 120)
    #expect(value.yearPlays == 5 && value.yearMinutes == 24 * 3 + 240)
    #expect(value.perYear.map(\.year) == [2025, 2026] && value.perYear.first?.minutes == 45)
    #expect(value.peakHour == 16 && value.hours[21] == 2)
    #expect(value.peakWeekday == 2, "Wednesday, with Monday first")
    #expect(value.biggestDay?.minutes == 120 && value.biggestDay.map { DiaryDate.day($0.day, timeZone: utc) } == "2026-10-02")
    #expect(value.first?.title.id == "old" && value.latest?.title.id == "film")
    #expect(value.marathons.count == 1 && value.marathons.first?.episodes == 3 && value.marathons.first?.title.id == "show")
    #expect(value.mostPlayedShows.first?.title.id == "show" && value.mostPlayedShows.first?.count == 3)
    #expect(value.mostPlayedMovies.first?.count == 2 && value.mostPlayedMovies.first?.minutes == 240)
    #expect(value.rewatches == 1)
    #expect(value.topRatedMovies.first?.id == "film" && value.topRatedShows.first?.id == "show")
    #expect(value.ratingCounts[9] == 1 && value.ratingCounts[7] == 1 && value.ratedCount == 2)
    #expect(value.movieAverage == 10 && value.showAverage == 8)
    #expect(value.decades.map(\.decade) == [1990, 2010, 2020])
    #expect(value.averageRuntime == 63 && value.longestMovie?.id == "film")
}

@Test func statsInsightsAreEmptyForAnEmptyDiary() throws {
    let empty = try JSONDecoder().decode(Workspace.self, from: Data(#"{"titles":[],"episodes":[],"events":[],"locations":[]}"#.utf8))
    let value = StatsInsights(workspace: empty)
    #expect(value.totalMinutes == 0 && value.perYear.isEmpty && value.biggestDay == nil && value.peakHour == nil && value.first == nil)
}
