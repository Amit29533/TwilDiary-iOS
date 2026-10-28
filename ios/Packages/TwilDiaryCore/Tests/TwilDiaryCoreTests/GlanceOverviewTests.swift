import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

private func event(_ id: String, title: String, recorded: String, revoked: String? = nil) -> WatchEvent {
    WatchEvent(id: id, operationId: id, titleId: title, episodeId: nil, watchedAt: nil, recordedAt: recorded,
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
    #expect(latest["a"] == DiaryDate.parse("2026-10-27T10:00:00.000Z"))
    #expect(latest["b"] == nil)
}

@Test func glanceOrdersByRecentActivityThenNameAndSupportsOtherSorts() throws {
    let titles = SampleWorkspace.make().titles.filter { $0.deletedAt == nil }
    #expect(titles.count >= 3)
    let first = titles[0], second = titles[1], third = titles[2]
    let activity = [second.id: Date(timeIntervalSince1970: 200), third.id: Date(timeIntervalSince1970: 100)]
    let recent = GlanceOverview.order([first, second, third], sort: .recentlyUpdated, lastActivity: activity, progress: [:])
    #expect(recent.map(\.id).prefix(2) == [second.id, third.id])
    #expect(recent.last?.id == first.id)
    let named = GlanceOverview.order([third, first, second], sort: .title, lastActivity: [:], progress: [:])
    #expect(named.map(\.name) == named.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    let almost = GlanceOverview.order([first, second, third], sort: .almostDone, lastActivity: [:],
                                      progress: [first.id: 0.2, second.id: 0.9, third.id: 0.5])
    #expect(almost.map(\.id) == [second.id, third.id, first.id])
}

@Test func cardTextNamesWhatItCountsAndHidesUnknowns() {
    let text = GlanceCardText.series(season: 1, watched: 5, total: 8, next: 6, remainingMinutes: 80)
    #expect(text.subtitle == "S1 · Watched 5 of 8 · Next E6")
    #expect(text.progressLabel == "63% of season 1")
    #expect(text.timeLeft == "1h 20m left")
    #expect(text.counter == "E5")
    let unknown = GlanceCardText.series(season: 2, watched: 0, total: 12, next: 1, remainingMinutes: nil)
    #expect(unknown.timeLeft == nil)
    #expect(unknown.counter == "–")
    #expect(unknown.progressLabel == "0% of season 2")
    let caughtUp = GlanceCardText.series(season: 3, watched: 10, total: 10, next: nil, remainingMinutes: 0)
    #expect(caughtUp.subtitle == "S3 · Watched 10 of 10")
    #expect(caughtUp.timeLeft == nil)
    #expect(GlanceCardText.series(season: 0, watched: 1, total: 2, next: 2, remainingMinutes: nil).progressLabel == "50% of specials")
}

@Test func longRunningSeasonsShowARunningCountInsteadOfAShare() {
    let text = GlanceCardText.series(season: 1, watched: 35, total: 1100, next: 36, remainingMinutes: nil)
    #expect(text.subtitle == "S1 · 35 watched · Next E36")
    #expect(text.progressLabel == nil)
    #expect(text.counter == "E35")
}

@Test func movieCardsSayWatchedOrHowLongIsLeft() {
    #expect(GlanceCardText.movie(watched: false, runtimeMinutes: 114) ==
            GlanceCardText(subtitle: "Movie", progressLabel: "Not watched yet", timeLeft: "1h 54m left", counter: "–"))
    #expect(GlanceCardText.movie(watched: true, runtimeMinutes: 114).timeLeft == nil)
    #expect(GlanceCardText.movie(watched: false, runtimeMinutes: nil).timeLeft == nil)
}
