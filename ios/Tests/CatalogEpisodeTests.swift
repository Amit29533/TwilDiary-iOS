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
}
