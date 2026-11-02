import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

private func milestoneEvent(_ id: String, title: String, date: String?, revoked: Bool = false) throws -> WatchEvent {
    let value: [String: Any] = ["id": id, "operationId": id, "titleId": title, "watchedAt": date as Any? ?? NSNull(), "recordedAt": "2026-11-02T00:00:00Z", "revokedAt": revoked ? "2026-11-02T00:00:00Z" as Any : NSNull(), "origin": "manual"]
    return try JSONDecoder().decode(WatchEvent.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func profileMilestonesCountActualWatchesAndExcludeFutureRevokedAndPlannedTitles() throws {
    var workspace = SampleWorkspace.make(); workspace.events = []
    let now = try #require(DiaryDate.parse("2026-11-02T12:00:00Z")), zone = TimeZone(secondsFromGMT: 0)!
    #expect(ProfileMilestone.make(workspace, now: now, timeZone: zone).allSatisfy { !$0.earned && $0.progress == 0 })
    let movie = try #require(workspace.activeTitles.first { !$0.isSeries })
    let other = try #require(workspace.activeTitles.first { $0.id != movie.id })
    workspace.events = [try milestoneEvent("unknown", title: movie.id, date: nil), try milestoneEvent("rewatch", title: movie.id, date: nil), try milestoneEvent("future", title: other.id, date: "2026-12-01T00:00:00Z"), try milestoneEvent("revoked", title: other.id, date: "2026-10-01T00:00:00Z", revoked: true)]
    let values = Dictionary(uniqueKeysWithValues: ProfileMilestone.make(workspace, now: now, timeZone: zone).map { ($0.id, $0) })
    #expect(values["first-watch"]?.progress == 2)
    #expect(values["hundred-titles"]?.progress == 1)
    #expect(values["ten-movies"]?.progress == 1)
    #expect(values["hundred-hours"]?.progress == 0)
    workspace.titles = []
    #expect(ProfileMilestone.make(workspace, now: now, timeZone: zone).allSatisfy { $0.progress == 0 })
}

@Test func profileMilestoneStreakUsesLocalHistoryAndCorrectionsUpdateProgress() throws {
    var workspace = SampleWorkspace.make(); workspace.events = []
    let title = try #require(workspace.activeTitles.first)
    let now = try #require(DiaryDate.parse("2026-11-02T12:00:00Z")), zone = TimeZone(identifier: "Asia/Kolkata")!
    workspace.events = try (25...31).map { try milestoneEvent("day-\($0)", title: title.id, date: "2026-10-\($0)T12:00:00Z") }
    let initial = ProfileMilestone.make(workspace, now: now, timeZone: zone)
    #expect(initial.first { $0.id == "week-streak" }?.earned == true)
    #expect(initial.first { $0.id == "hundred-titles" }?.progress == 1)
    workspace.events.removeAll { $0.id == "day-28" }
    let corrected = ProfileMilestone.make(workspace, now: now, timeZone: zone)
    #expect(corrected.first { $0.id == "week-streak" }?.progress == 3)
    #expect(corrected.first { $0.id == "hundred-hours" }?.progress == 6 * max(0, title.runtimeMinutes ?? 0) / 60)
}
