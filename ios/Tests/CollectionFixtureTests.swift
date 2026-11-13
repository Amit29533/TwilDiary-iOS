import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class CollectionFixtureTests: XCTestCase {
    private func body(_ titles: [MediaTitle], _ change: CollectionChange) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CollectionRequest(titles: titles, change: change))) as? [String: Any])
    }
    func testStaleBulkSelectionChangesNothing() throws {
        let original = PreviewData.workspace, fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        var request = try body(Array(original.activeTitles.prefix(2)), .trash)
        var items = try XCTUnwrap(request["items"] as? [[String: Any]])
        items[1]["expectedVersion"] = 999; request["items"] = items
        XCTAssertThrowsError(try fixture.request("/api/titles/bulk", method: "POST", body: request) as EmptyResponse)
        XCTAssertEqual(fixture.workspace.titles, original.titles)
        XCTAssertEqual(fixture.workspace.events, original.events)
        XCTAssertEqual(fixture.workspace.locations, original.locations)
    }
    func testQueueAndFavoriteLeaveProgressAndStatusAlone() throws {
        let original = PreviewData.workspace, fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let chosen = Array(original.activeTitles.prefix(2)), ids = Set(chosen.map(\.id))
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body(chosen, .queue(true)))
        let queued = fixture.workspace.activeTitles.filter { ids.contains($0.id) }
        XCTAssertTrue(queued.allSatisfy { $0.queued == true })
        XCTAssertEqual(queued.map(\.status), chosen.map(\.status))
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body(queued, .favorite(true)))
        XCTAssertTrue(fixture.workspace.activeTitles.filter { ids.contains($0.id) }.allSatisfy(\.favorite))
        XCTAssertEqual(fixture.workspace.events, original.events)
        XCTAssertEqual(fixture.workspace.locations, original.locations)
    }
    func testTrashRestoreAndPermanentDeleteKeepUnrelatedDiaryRecords() throws {
        let original = PreviewData.workspace, fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let title = try XCTUnwrap(original.activeTitles.first)
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body([title], .trash))
        let trashed = try XCTUnwrap(fixture.workspace.titles.first { $0.id == title.id })
        XCTAssertNotNil(trashed.deletedAt); XCTAssertEqual(fixture.workspace.events, original.events)
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body([trashed], .restore))
        let restored = try XCTUnwrap(fixture.workspace.activeTitles.first { $0.id == title.id })
        XCTAssertEqual(restored.notes, title.notes); XCTAssertEqual(fixture.workspace.locations, original.locations)
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body([restored], .trash))
        let archived = try XCTUnwrap(fixture.workspace.titles.first { $0.id == title.id })
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body([archived], .purge))
        XCTAssertEqual(fixture.workspace.titles, original.titles.filter { $0.id != title.id })
        XCTAssertEqual(fixture.workspace.events, original.events.filter { $0.titleId != title.id })
        XCTAssertEqual(fixture.workspace.locations, original.locations.filter { $0.titleId != title.id })
        XCTAssertEqual(fixture.workspace.episodes, original.episodes.filter { $0.titleId != title.id })
    }
    func testEmptyTrashRequiresItsExplicitConfirmationAndDoesNotDeleteActiveTitles() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let chosen = Array(fixture.workspace.activeTitles.prefix(2))
        let _: EmptyResponse = try fixture.request("/api/titles/bulk", method: "POST", body: body(chosen, .trash))
        let active = fixture.workspace.activeTitles
        XCTAssertThrowsError(try fixture.request("/api/trash", method: "DELETE", body: [:]) as EmptyResponse)
        let _: EmptyResponse = try fixture.request("/api/trash", method: "DELETE", body: ["confirmation": "EMPTY_TRASH"])
        XCTAssertEqual(fixture.workspace.titles, active)
    }
}
