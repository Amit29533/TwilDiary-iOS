import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

private func event(_ id: String, title: String, recorded: String, watched: String? = nil, revoked: String? = nil) -> WatchEvent {
    WatchEvent(id: id, operationId: id, titleId: title, episodeId: nil, watchedAt: watched, recordedAt: recorded,
               revokedAt: revoked, origin: "manual", version: 1)
}

@Test func lastActivityIsTheNewestActiveLogPerTitle() throws {
    let events = [
        event("a1", title: "a", recorded: "2026-10-20T10:00:00.000Z"),
        event("a2", title: "a", recorded: "2026-10-27T10:00:00.000Z"),
        event("a3", title: "a", recorded: "2026-10-28T10:00:00.000Z", revoked: "2026-10-28T11:00:00.000Z"),
        event("b1", title: "b", recorded: "not a date")
    ]
    let latest = GlanceOverview.lastActivity(events: events)
    #expect(latest["a"]?.recorded == DiaryDate.parse("2026-10-27T10:00:00.000Z"))
    #expect(latest["b"] == nil)
}

@Test func importedPlaysLoggedTogetherOrderByWhenTheyWereWatched() throws {
    let imported = "2026-10-21T00:00:00.000Z"
    let events = [
        event("a1", title: "a", recorded: imported, watched: "2026-09-01T12:00:00.000Z"),
        event("b1", title: "b", recorded: imported, watched: "2026-10-20T12:00:00.000Z"),
        event("b2", title: "b", recorded: imported, watched: "2026-08-01T12:00:00.000Z")
    ]
    let latest = GlanceOverview.lastActivity(events: events)
    #expect(latest["b"]?.watched == DiaryDate.parse("2026-10-20T12:00:00.000Z"))
    #expect(try #require(latest["b"]) > #require(latest["a"]))
}

@Test func glanceOrdersByRecentActivityThenNameAndSupportsOtherSorts() throws {
    let titles = SampleWorkspace.make().titles.filter { $0.deletedAt == nil }
    #expect(titles.count >= 3)
    let first = titles[0], second = titles[1], third = titles[2]
    let activity = [second.id: GlanceActivity(recorded: Date(timeIntervalSince1970: 200)),
                    third.id: GlanceActivity(recorded: Date(timeIntervalSince1970: 100))]
    let recent = GlanceOverview.order([first, second, third], sort: .recentlyUpdated, lastActivity: activity, progress: [:])
    #expect(recent.map(\.id).prefix(2) == [second.id, third.id])
    #expect(recent.last?.id == first.id)
    let named = GlanceOverview.order([third, first, second], sort: .title, lastActivity: [:], progress: [:])
    #expect(named.map(\.name) == named.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    let almost = GlanceOverview.order([first, second, third], sort: .almostDone, lastActivity: [:],
                                      progress: [first.id: 0.2, second.id: 0.9, third.id: 0.5])
    #expect(almost.map(\.id) == [second.id, third.id, first.id])
}

@Test func cardTextUsesTheOwnersWording() {
    let text = GlanceCardText.series(season: 1, watched: 5, total: 8, next: 6, remainingMinutes: 80)
    #expect(text == GlanceCardText(subtitle: "S1 · E5 of 8", progressLabel: "63% complete", timeLeft: "1h 20m left", counter: "5 / 8"))
    let unknown = GlanceCardText.series(season: 2, watched: 0, total: 12, next: 1, remainingMinutes: nil)
    #expect(unknown.timeLeft == "Time unknown")
    #expect(unknown.counter == "0 / 12")
    #expect(unknown.progressLabel == "0% complete")
    let caughtUp = GlanceCardText.series(season: 3, watched: 10, total: 10, next: nil, remainingMinutes: nil)
    #expect(caughtUp.subtitle == "S3 · E10 of 10")
    #expect(caughtUp.timeLeft == nil)
    #expect(GlanceCardText.series(season: 0, watched: 1, total: 2, next: 2, remainingMinutes: nil).subtitle == "Specials · E1 of 2")
}

@Test func veryLongSeasonsShowTheirSizeAsOneThousandPlus() {
    let text = GlanceCardText.series(season: 1, watched: 35, total: 1100, next: 36, remainingMinutes: nil)
    #expect(text.subtitle == "S1 · E35 of 1000+")
    #expect(text.progressLabel == "3% complete")
    #expect(text.counter == "35 / 1000+")
}

@Test func movieCardsSayHowMuchIsLeft() {
    #expect(GlanceCardText.movie(watched: false, runtimeMinutes: 114) ==
            GlanceCardText(subtitle: "Movie", progressLabel: "0% complete", timeLeft: "1h 54m left", counter: "0 / 1"))
    #expect(GlanceCardText.movie(watched: true, runtimeMinutes: 114).timeLeft == nil)
    #expect(GlanceCardText.movie(watched: false, runtimeMinutes: nil).timeLeft == "Time unknown")
}
