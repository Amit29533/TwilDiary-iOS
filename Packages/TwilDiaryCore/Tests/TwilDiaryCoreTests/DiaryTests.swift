import Foundation
import Testing
@testable import TwilDiaryCore

@Test func paginatedWorkspaceDecodesTheRealContract() throws {
    let snapshot = SampleWorkspace.make()
    let data = try JSONSerialization.data(withJSONObject: ["items": JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.titles)), "next": "next-id"])
    let page = try JSONDecoder().decode(WorkspacePage<MediaTitle>.self, from: data)
    #expect(page.items.count == 4)
    #expect(page.next == "next-id")
    #expect(page.items[0].communityScore != page.items[0].score)
}

@Test func episodeRewatchesCountOnceForProgress() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first)
    workspace.events.append(workspace.events[0])
    let progress = SeasonProgress.calculate(title: title, workspace: workspace, season: 1)
    #expect(progress.watched == 2)
    #expect(progress.total == 4)
    #expect(progress.remainingMinutes == 100)
    #expect(progress.fraction == 0.5)
}

@Test func incompleteCatalogueDoesNotInventRemainingTime() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first)
    workspace.episodes.removeLast()
    #expect(SeasonProgress.calculate(title: title, workspace: workspace, season: 1).remainingMinutes == nil)
}

@Test func trashedTitlesAndRevokedWatchesDoNotContribute() throws {
    let original = SampleWorkspace.make()
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var titles = try #require(value["titles"] as? [[String: Any]])
    titles[0]["deletedAt"] = "2026-10-23T00:00:00Z"; value["titles"] = titles
    let workspace = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(workspace.activeTitles.count == 3)
    #expect(workspace.activeEvents.isEmpty)
}

@Test func calendarPeriodsRespectLocalMidnightAndExcludeFuture() throws {
    let now = try #require(DiaryDate.parse("2026-10-23T01:00:00Z"))
    let before = try #require(DiaryDate.parse("2026-10-22T19:30:00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
    #expect(Period.today.contains(before, now: now, calendar: calendar))
    #expect(!Period.all.contains(now.addingTimeInterval(1), now: now, calendar: calendar))
    #expect(DiaryDate.day(before, timeZone: calendar.timeZone) == "2026-10-23")
    #expect(!Period.year.contains(before, now: now, calendar: calendar, year: 2025))
    #expect(DiaryDate.parse(nil) == nil)
}

@Test func movieAndAnimeFiltersRemainCompatible() {
    let titles = SampleWorkspace.make().titles
    #expect(titles.filter { LibraryCategory.movies.includes($0) }.count == 1)
    #expect(titles.filter { LibraryCategory.anime.includes($0) }.count == 1)
    #expect(DiaryDate.duration(273) == "4h 33m")
    #expect(DiaryDate.duration(120) == "2h")
}
