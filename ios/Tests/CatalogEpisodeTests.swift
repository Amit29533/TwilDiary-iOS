import XCTest
import SwiftUI
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class CatalogEpisodeTests: XCTestCase {
    func testImportNavigationReplacesThePreviewInsteadOfLeavingAStaleAddPage() {
        let router = AppRouter(); router.paths[.home] = NavigationPath()
        router.paths[.home]?.append(CatalogRoute(kind: .tv, id: 900001))
        router.replaceTitle("tmdb-tv-900001", tab: .home)
        XCTAssertEqual(router.paths[.home]?.count, 1); XCTAssertEqual(router.selectedTab, .home)
    }
    private func page(_ number: Int) -> CatalogEpisodesPage {
        CatalogEpisodesPage(items: [CatalogEpisode(number: number, name: "Chapter", overview: "Summary", airedOn: nil, stillPath: nil, communityScore: nil)])
    }
    func testSeasonCacheUpgradesToRevealedAndKeepsItWhenReturning() async {
        var calls: [String] = []
        let controller = CatalogEpisodeController { season, reveal in calls.append("\(season):\(reveal)"); return self.page(season) }
        await controller.load(1); await controller.load(1)
        await controller.load(1, reveal: true); await controller.load(1)
        await controller.load(2); await controller.load(1)
        XCTAssertEqual(calls, ["1:false", "1:true", "2:false"])
        XCTAssertTrue(controller.revealed); XCTAssertEqual(controller.items.first?.number, 1)
        await controller.load(1, reveal: true, force: true)
        XCTAssertEqual(calls.count, 4)
    }
    func testLateSeasonCannotReplaceTheSelectedSeason() async {
        var pending: CheckedContinuation<CatalogEpisodesPage, any Error>?
        let controller = CatalogEpisodeController { season, _ in
            if season == 1 { return try await withCheckedThrowingContinuation { pending = $0 } }
            return self.page(season)
        }
        let first = Task { await controller.load(1) }
        guard await waitForRegressionCondition({ pending != nil }) else { first.cancel(); XCTFail("The delayed season request did not start"); return }
        await controller.load(2); pending?.resume(returning: page(1)); await first.value
        XCTAssertEqual(controller.season, 2); XCTAssertEqual(controller.items.first?.number, 2); XCTAssertFalse(controller.loading)
    }
    func testFailedRevealPreservesRowsAndCanRetry() async {
        var fail = true
        let controller = CatalogEpisodeController { _, reveal in
            if reveal && fail { throw APIError.message("Provider unavailable") }
            return self.page(1)
        }
        await controller.load(1); await controller.load(1, reveal: true)
        XCTAssertEqual(controller.items.count, 1); XCTAssertNotNil(controller.error); XCTAssertFalse(controller.revealed)
        fail = false; await controller.load(1, reveal: true)
        XCTAssertNil(controller.error); XCTAssertTrue(controller.revealed)
    }
    func testCancelledRevealDoesNotCacheAFalseSuccess() async {
        var pending: CheckedContinuation<CatalogEpisodesPage, any Error>?
        let controller = CatalogEpisodeController { _, reveal in
            if reveal { return try await withCheckedThrowingContinuation { pending = $0 } }
            return self.page(1)
        }
        let task = Task { await controller.load(1, reveal: true) }
        guard await waitForRegressionCondition({ pending != nil }) else { task.cancel(); XCTFail("The delayed season request did not start"); return }
        task.cancel(); pending?.resume(returning: page(1)); await task.value
        XCTAssertFalse(controller.revealed); XCTAssertFalse(controller.loading); XCTAssertNil(controller.error)
        await controller.load(1); XCTAssertEqual(controller.items.count, 1)
    }
    private struct ImportReceipt: Decodable { let title: MediaTitle; let added: Bool }
    private struct ManualReceipt: Decodable { let title: MediaTitle }
    func testManualFixtureRetryPreservesPersonalFieldsAndRejectsChangedIdentity() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let body: [String: Any] = ["id": "manual-reference", "name": "Reference", "category": "movie", "year": 1800, "status": "watching", "score": 7.5]
        let receipt: ManualReceipt = try fixture.request("/api/titles", method: "POST", body: body)
        XCTAssertEqual(receipt.title.year, 1800); XCTAssertEqual(receipt.title.status, "watching"); XCTAssertEqual(receipt.title.score, 7.5)
        let _: EmptyResponse = try fixture.request("/api/titles/manual-reference", method: "PATCH", body: ["expectedVersion": 1, "notes": "Keep this", "score": 8.0])
        let again: ManualReceipt = try fixture.request("/api/titles", method: "POST", body: body)
        XCTAssertEqual(again.title.notes, "Keep this"); XCTAssertEqual(again.title.score, 8.0)
        var changed = body; changed["name"] = "Different"
        XCTAssertThrowsError(try fixture.request("/api/titles", method: "POST", body: changed) as ManualReceipt)
        XCTAssertEqual(fixture.workspace.titles.filter { $0.id == "manual-reference" }.count, 1)
    }
    func testIsolatedImportIsIdempotentAndPreservesPersonalData() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let body: [String: Any] = ["mediaType": "tv", "tmdbId": 900001, "category": "anime", "status": "planned"]
        let first: ImportReceipt = try fixture.request("/api/metadata/import", method: "POST", body: body)
        XCTAssertTrue(first.added); XCTAssertEqual(first.title.id, "tmdb-tv-900001"); XCTAssertNil(first.title.score)
        XCTAssertEqual(first.title.seasons?.count, 2); XCTAssertFalse(fixture.workspace.episodes.contains { $0.titleId == first.title.id })
        let _: EmptyResponse = try fixture.request("/api/titles/" + first.title.id, method: "PATCH", body: ["expectedVersion": 1, "notes": "Keep this", "score": 8.5])
        let again: ImportReceipt = try fixture.request("/api/metadata/import", method: "POST", body: body)
        XCTAssertFalse(again.added); XCTAssertEqual(again.title.notes, "Keep this"); XCTAssertEqual(again.title.score, 8.5)
        XCTAssertEqual(fixture.workspace.titles.filter { $0.id == first.title.id }.count, 1)
        let movie: ImportReceipt = try fixture.request("/api/metadata/import", method: "POST", body: ["mediaType": "movie", "tmdbId": 900001, "category": "movie", "status": "planned"])
        XCTAssertNotEqual(first.title.id, movie.title.id); XCTAssertEqual(movie.title.seasons?.count, 0)
    }
    func testImportedSeasonLoadsLazilyWithoutChangingHistoryOrDuplicatingEpisodes() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let history = fixture.workspace.events.map(\.id)
        let first: ImportReceipt = try fixture.request("/api/metadata/import", method: "POST", body: ["mediaType": "tv", "tmdbId": 900001, "category": "anime", "status": "planned"])
        XCTAssertFalse(fixture.workspace.episodes.contains { $0.titleId == first.title.id })
        for _ in 0..<2 { let _: EmptyResponse = try fixture.request("/api/titles/" + first.title.id + "/seasons/1/metadata", method: "POST", body: [:]) }
        XCTAssertEqual(fixture.workspace.episodes.filter { $0.titleId == first.title.id }.count, 12)
        XCTAssertEqual(fixture.workspace.events.map(\.id), history)
        let updated = try XCTUnwrap(fixture.workspace.titles.first { $0.id == first.title.id })
        XCTAssertEqual(updated.version, first.title.version); XCTAssertEqual(updated.seasons?.first?.metadataVersion, 2)
        XCTAssertFalse(SeasonMetadata.needsPreparation(title: updated, workspace: fixture.workspace, season: 1, now: DiaryDate.parse("2026-10-23T12:00:00Z")!))
    }
    func testIsolatedImportRejectsTrashAndInvalidCategoryAtomically() throws {
        let fixture = FixtureDiaryBackend(workspace: PreviewData.workspace)
        let body: [String: Any] = ["mediaType": "tv", "tmdbId": 900001, "category": "anime", "status": "planned"]
        let first: ImportReceipt = try fixture.request("/api/metadata/import", method: "POST", body: body)
        let _: EmptyResponse = try fixture.request("/api/titles/" + first.title.id, method: "DELETE", body: ["expectedVersion": first.title.version ?? 1])
        let count = fixture.workspace.titles.count
        XCTAssertThrowsError(try fixture.request("/api/metadata/import", method: "POST", body: body) as ImportReceipt)
        XCTAssertThrowsError(try fixture.request("/api/metadata/import", method: "POST", body: ["mediaType": "tv", "tmdbId": 900003, "category": "movie", "status": "planned"]) as ImportReceipt)
        XCTAssertEqual(fixture.workspace.titles.count, count)
    }
}
