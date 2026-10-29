import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

/// The sample has "18 Again": one four-episode season, episodes 1 and 2 watched.
private func watch(_ episode: String, id: String, in workspace: inout Workspace) throws -> WatchEvent {
    var value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.events[0])) as? [String: Any])
    value["id"] = id; value["operationId"] = "op-" + id; value["episodeId"] = episode; value["revokedAt"] = NSNull()
    let event = try JSONDecoder().decode(WatchEvent.self, from: JSONSerialization.data(withJSONObject: value))
    workspace.events.append(event)
    return event
}

@Test func finishingTheLastSeasonFinishesTheSeries() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first { $0.id == "again" })
    let third = try watch("ep-3", id: "w3", in: &workspace)
    #expect(Milestone.after(third, title: title, workspace: workspace) == nil)
    let fourth = try watch("ep-4", id: "w4", in: &workspace)
    #expect(Milestone.after(fourth, title: title, workspace: workspace) == .seriesFinished(title: "18 Again"))
    #expect(Milestone.seriesFinished(title: "18 Again").headline == "Series finished")
}

@Test func finishingAnEarlierSeasonIsASeasonMilestone() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first { $0.id == "again" })
    var later = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.episodes[3])) as? [String: Any])
    later["id"] = "s2-ep-1"; later["season"] = 2; later["number"] = 1
    workspace.episodes.append(try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: later)))
    _ = try watch("ep-3", id: "w3", in: &workspace)
    let fourth = try watch("ep-4", id: "w4", in: &workspace)
    #expect(Milestone.after(fourth, title: title, workspace: workspace) == .seasonFinished(title: "18 Again", season: 1))
}

@Test func aRewatchNeverFinishesASeasonAgain() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first { $0.id == "again" })
    _ = try watch("ep-3", id: "w3", in: &workspace)
    _ = try watch("ep-4", id: "w4", in: &workspace)
    let rewatch = try watch("ep-4", id: "w5", in: &workspace)
    #expect(Milestone.after(rewatch, title: title, workspace: workspace) == nil)
}

@Test func roundWatchCountsAreMilestones() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first { $0.id == "again" })
    var last: WatchEvent?
    // Rewatches of episode 1 never finish the season, so only the count can trigger.
    while workspace.activeEvents.count < 10 { last = try watch("ep-1", id: "c\(workspace.events.count)", in: &workspace) }
    #expect(Milestone.after(try #require(last), title: title, workspace: workspace) == .watchCount(10))
    let eleventh = try watch("ep-1", id: "c-next", in: &workspace)
    #expect(Milestone.after(eleventh, title: title, workspace: workspace) == nil)
}
