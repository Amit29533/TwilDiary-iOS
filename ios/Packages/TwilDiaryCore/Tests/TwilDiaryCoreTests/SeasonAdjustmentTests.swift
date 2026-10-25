import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func seasonAdjustmentPreservesExistingDatesAndRevokesAllSuffixRewatches() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first)
    let episodes = workspace.episodes.filter { $0.titleId == title.id && $0.season == 1 }.sorted { $0.number < $1.number }
    var rewatch = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.events[1])) as? [String: Any])
    rewatch["id"] = "fixture-rewatch"; rewatch["operationId"] = "fixture-rewatch-operation"
    workspace.events.append(try JSONDecoder().decode(WatchEvent.self, from: JSONSerialization.data(withJSONObject: rewatch)))
    let lowering = try SeasonAdjustment.plan(workspace: workspace, titleID: title.id, season: 1, count: 1, today: "2026-10-23")
    #expect(lowering.record.isEmpty)
    #expect(lowering.revoke.count == 2)
    #expect(lowering.revoke.allSatisfy { $0.episodeId == episodes[1].id })
    let increasing = try SeasonAdjustment.plan(workspace: workspace, titleID: title.id, season: 1, count: 3, today: "2026-10-23")
    #expect(increasing.revoke.isEmpty)
    #expect(increasing.record.map(\.id) == [episodes[2].id])
    #expect(workspace.events[0].watchedAt == SampleWorkspace.make().events[0].watchedAt)
}

@Test func seasonAdjustmentRejectsInvalidAndFutureEpisodesBeforePlanningAnyWrites() throws {
    let workspace = SampleWorkspace.make(), title = try #require(SampleWorkspace.make().titles.first)
    #expect(throws: SeasonAdjustment.AdjustmentError.self) {
        try SeasonAdjustment.plan(workspace: workspace, titleID: title.id, season: 1, count: 5, today: "2026-10-23")
    }
    #expect(throws: SeasonAdjustment.AdjustmentError.self) {
        try SeasonAdjustment.plan(workspace: workspace, titleID: title.id, season: 1, count: 3, today: "1900-01-01")
    }
    #expect(!SeasonAdjustment.validDay("2026-02-30"))
    #expect(!SeasonAdjustment.validDay("2026-2-01"))
    #expect(!SeasonAdjustment.validDay("+123-02-01"))
    #expect(SeasonAdjustment.validDay("2024-02-29"))
    #expect(!SeasonAdjustment.validDay("2025-02-29"))
}
