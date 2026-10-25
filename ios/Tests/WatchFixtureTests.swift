import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class WatchFixtureTests: XCTestCase {
    private struct Receipt: Decodable { let event: WatchEvent; let added: Bool }
    private struct EventReceipt: Decodable { let event: WatchEvent }
    private let date = "2026-10-23T12:00:00Z"
    private func body(_ episode: String?, operation: String = UUID().uuidString, rewatch: Bool = false) -> [String: Any] {
        ["operationId": operation, "episodeId": episode as Any? ?? NSNull(), "watchedAt": date, "rewatch": rewatch]
    }
    private func record(_ fixture: FixtureDiaryBackend, title: String = "again", episode: String?, operation: String = UUID().uuidString, rewatch: Bool = false) throws -> Receipt {
        try fixture.request("/api/titles/\(title)/watches", method: "POST", body: body(episode, operation: operation, rewatch: rewatch))
    }
    private func change(_ fixture: FixtureDiaryBackend, event: WatchEvent, action: String) throws -> WatchEvent {
        let receipt: EventReceipt = try fixture.request("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": action, "expectedVersion": event.version ?? 1]); return receipt.event
    }
    func testWatchRetryAfterUndoNeverCreatesAnotherEventOrReactivatesIt() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let episode = try XCTUnwrap(fixture.workspace.episodes.first { $0.titleId == "again" && $0.number == 9 })
        let operation = UUID().uuidString, before = fixture.workspace.events.count
        let first = try record(fixture, episode: episode.id, operation: operation)
        XCTAssertTrue(first.added); XCTAssertEqual(fixture.workspace.events.count, before + 1)
        let retry = try record(fixture, episode: episode.id, operation: operation)
        XCTAssertFalse(retry.added); XCTAssertEqual(retry.event.id, first.event.id)
        let revoked = try change(fixture, event: first.event, action: "revoke")
        XCTAssertEqual(revoked.version, 2); XCTAssertNotNil(revoked.revokedAt)
        let afterUndo = try record(fixture, episode: episode.id, operation: operation)
        XCTAssertEqual(afterUndo.event.id, first.event.id); XCTAssertNotNil(afterUndo.event.revokedAt)
        XCTAssertFalse(afterUndo.added); XCTAssertEqual(fixture.workspace.events.count, before + 1)
    }
    func testOperationConflictCannotChangeItsEpisodeDateOrRewatchIntent() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let ninth = try XCTUnwrap(fixture.workspace.episodes.first { $0.titleId == "again" && $0.number == 9 })
        let tenth = try XCTUnwrap(fixture.workspace.episodes.first { $0.titleId == "again" && $0.number == 10 })
        let operation = UUID().uuidString
        _ = try record(fixture, episode: ninth.id, operation: operation)
        let before = fixture.workspace.events
        XCTAssertThrowsError(try record(fixture, episode: tenth.id, operation: operation))
        XCTAssertThrowsError(try record(fixture, episode: ninth.id, operation: operation, rewatch: true))
        var altered = body(ninth.id, operation: operation); altered["watchedAt"] = "2026-10-22T12:00:00Z"
        XCTAssertThrowsError(try fixture.request("/api/titles/again/watches", method: "POST", body: altered) as Receipt)
        XCTAssertEqual(fixture.workspace.events, before)
    }
    func testDuplicateWatchDoesNotOverwriteManualStatusAndExplicitRewatchDoes() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let title = try XCTUnwrap(fixture.workspace.activeTitles.first { $0.id == "again" })
        let episode = try XCTUnwrap(fixture.workspace.episodes.first { $0.titleId == "again" && $0.number == 1 })
        let _: EmptyResponse = try fixture.request("/api/titles/again", method: "PATCH", body: ["status": "dropped", "expectedVersion": title.version ?? 1])
        let before = fixture.workspace.events.count
        let duplicate = try record(fixture, episode: episode.id)
        XCTAssertFalse(duplicate.added); XCTAssertEqual(fixture.workspace.events.count, before)
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "again" }?.status, "dropped")
        let rewatch = try record(fixture, episode: episode.id, rewatch: true)
        XCTAssertTrue(rewatch.added); XCTAssertEqual(fixture.workspace.events.count, before + 1)
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "again" }?.status, "watching")
        XCTAssertEqual(Set(fixture.workspace.activeEvents.filter { $0.titleId == "again" }.compactMap(\.episodeId)).count, 8)
    }
    func testMovieRewatchMinusAndUndoPreserveTheEarlierViewing() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let first = try record(fixture, title: "quiet-orbit", episode: nil)
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "quiet-orbit" }?.status, "completed")
        let second = try record(fixture, title: "quiet-orbit", episode: nil, rewatch: true)
        let removed = try change(fixture, event: second.event, action: "revoke")
        XCTAssertEqual(fixture.workspace.activeEvents.filter { $0.titleId == "quiet-orbit" }.map(\.id), [first.event.id])
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "quiet-orbit" }?.status, "completed")
        let restored = try change(fixture, event: removed, action: "restore")
        XCTAssertEqual(restored.version, 3); XCTAssertNil(restored.revokedAt)
        XCTAssertEqual(fixture.workspace.activeEvents.filter { $0.titleId == "quiet-orbit" }.count, 2)
        let repeated = try change(fixture, event: removed, action: "restore")
        XCTAssertEqual(repeated, restored)
        XCTAssertThrowsError(try change(fixture, event: second.event, action: "revoke"))
    }
    func testUnwatchAndUndoDoNotLoseOtherSeasonsOrLocationMappings() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace), original = PreviewData.workspace
        let event = try XCTUnwrap(fixture.workspace.activeEvents.first { $0.titleId == "again" })
        let revoked = try change(fixture, event: event, action: "revoke")
        let restored = try change(fixture, event: revoked, action: "restore")
        XCTAssertEqual(restored.watchedAt, event.watchedAt)
        XCTAssertEqual(fixture.workspace.episodes, original.episodes); XCTAssertEqual(fixture.workspace.locations, original.locations)
        XCTAssertEqual(Set(fixture.workspace.activeEvents.map(\.id)), Set(original.activeEvents.map(\.id)))
    }
    func testInvalidCallerReceiptCannotPublishAnyWatchOrIdempotencyState() throws {
        struct WrongReceipt: Decodable { let requiredField: String }
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace), original = PreviewData.workspace
        let episode = try XCTUnwrap(fixture.workspace.episodes.first { $0.titleId == "again" && $0.number == 9 }), operation = UUID().uuidString
        XCTAssertThrowsError(try fixture.request("/api/titles/again/watches", method: "POST", body: body(episode.id, operation: operation)) as WrongReceipt)
        XCTAssertEqual(fixture.workspace.events, original.events); XCTAssertEqual(fixture.workspace.titles, original.titles)
        let first = try record(fixture, episode: episode.id, operation: operation)
        XCTAssertTrue(first.added)
    }
    func testLastRegularEpisodeCompletesTheTitleAndUndoReturnsToWatching() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let remaining = fixture.workspace.episodes.filter { $0.titleId == "again" && $0.season == 1 && $0.number > 8 }.sorted { $0.number < $1.number }
        var latest: Receipt?
        for episode in remaining { latest = try record(fixture, episode: episode.id) }
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "again" }?.status, "completed")
        let last = try XCTUnwrap(latest)
        _ = try change(fixture, event: last.event, action: "revoke")
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "again" }?.status, "watching")
        XCTAssertEqual(Set(fixture.workspace.activeEvents.filter { $0.titleId == "again" }.compactMap(\.episodeId)).count, 15)
    }
    func testUnloadedSeasonPreventsAFalseCompletedStatus() throws {
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PreviewData.workspace)) as? [String: Any])
        var titles = try XCTUnwrap(archive["titles"] as? [[String: Any]])
        let index = try XCTUnwrap(titles.firstIndex { $0["id"] as? String == "again" })
        var seasons = try XCTUnwrap(titles[index]["seasons"] as? [[String: Any]])
        seasons.append(["number": 2, "name": "Season 2", "expectedEpisodes": 20, "metadataLoadedAt": NSNull()])
        titles[index]["seasons"] = seasons; archive["titles"] = titles
        let workspace = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: archive))
        let fixture = FixtureDiaryBackend(workspace: workspace)
        for episode in workspace.episodes.filter({ $0.titleId == "again" && $0.number > 8 }) { _ = try record(fixture, episode: episode.id) }
        XCTAssertEqual(fixture.workspace.titles.first { $0.id == "again" }?.status, "watching")
    }
}
