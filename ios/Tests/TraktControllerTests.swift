import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class TraktRegressionService: TraktServicing {
    let fixture = FixtureTraktService()
    var delayed: CheckedContinuation<TraktSync, any Error>?
    var steps = 0
    var stagnate = false
    func status() async throws -> TraktStatus { try await fixture.status() }
    func review(kind: TraktKind, query: String, after: String?) async throws -> TraktSync {
        try Task.checkCancellation()
        if after != nil { return try await withCheckedThrowingContinuation { delayed = $0 } }
        var result = try await fixture.review(kind: kind, query: query, after: nil); result.next = "synthetic-next-page"; return result
    }
    func start(mode: TraktRatingMode) async throws -> String { try await fixture.start(mode: mode) }
    func step(id: String) async throws -> TraktSync {
        steps += 1
        var result = try await fixture.step(id: id)
        if stagnate { result.run?.state = "building" }
        return result
    }
    func apply(id: String, change: String?, choice: TraktChoice) async throws -> TraktSync { try await fixture.apply(id: id, change: change, choice: choice) }
    func cancel(id: String) async throws { try await fixture.cancel(id: id) }
    func disconnect() async throws { try await fixture.disconnect() }
}

@MainActor final class TraktControllerTests: XCTestCase {
    func testScanPreparesReviewWithoutApplyingAnyChanges() async {
        let controller = TraktController(service: FixtureTraktService())
        await controller.refresh(); await controller.scan(start: true)
        XCTAssertEqual(controller.sync?.run?.state, "review")
        XCTAssertEqual(controller.sync?.pendingChanges, 8)
        XCTAssertTrue(controller.sync?.items.allSatisfy { $0.state == "pending" } == true)
        XCTAssertFalse(controller.busy)
    }
    func testBulkApplyLeavesConflictsForExplicitReview() async {
        let controller = TraktController(service: FixtureTraktService())
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(controller.sync?.pendingChanges, 1)
        XCTAssertEqual(controller.sync?.readyChanges, 0)
        XCTAssertEqual(controller.sync?.items.filter { $0.state == "pending" }.count, 1)
        XCTAssertTrue(controller.sync?.items.first { $0.state == "pending" }?.review == true)
    }
    func testKeepLocalAndUseTraktAreSeparateExplicitChoices() async throws {
        for choice in [TraktChoice.local, .trakt] {
            let controller = TraktController(service: FixtureTraktService())
            await controller.refresh()
            let conflict = try XCTUnwrap(controller.sync?.items.first { $0.review })
            await controller.apply(change: conflict, choice: choice)
            XCTAssertEqual(controller.sync?.items.first { $0.id == conflict.id }?.state, "applied")
            XCTAssertEqual(controller.sync?.pendingChanges, 7)
            XCTAssertNil(controller.error)
        }
    }
    func testConflictDefaultSettlesConflictsAfterReadyChanges() async throws {
        for (side, choice) in [(TraktConflictDefault.local, "local"), (.trakt, "trakt")] {
            let controller = TraktController(service: FixtureTraktService(), defaults: try XCTUnwrap(UserDefaults(suiteName: "trakt-\(UUID())")))
            controller.conflictDefault = side
            await controller.refresh(); await controller.apply()
            XCTAssertEqual(controller.sync?.run?.state, "complete", choice)
            XCTAssertTrue(controller.sync?.items.allSatisfy { $0.state == "applied" } == true, choice)
            XCTAssertNil(controller.error, choice)
        }
    }
    func testConflictDefaultIsRememberedAndAsksByDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "trakt-\(UUID())"))
        XCTAssertEqual(TraktController(service: FixtureTraktService(), defaults: defaults).conflictDefault, .ask)
        TraktController(service: FixtureTraktService(), defaults: defaults).conflictDefault = .trakt
        XCTAssertEqual(TraktController(service: FixtureTraktService(), defaults: defaults).conflictDefault, .trakt)
    }
    func testScanWithAConflictDefaultAppliesItselfToTheEnd() async throws {
        let controller = TraktController(service: FixtureTraktService(), defaults: try XCTUnwrap(UserDefaults(suiteName: "trakt-\(UUID())")))
        controller.conflictDefault = .local
        await controller.refresh(); await controller.scan(start: true)
        for _ in 0..<100 where controller.sync?.run?.state != "complete" { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(controller.sync?.run?.state, "complete")
        XCTAssertEqual(controller.sync?.items.filter { $0.state == "pending" }.count, 0)
    }
    func testSkippingLeavesOtherItemsPendingAndFiltersDoNotChangeCounts() async throws {
        let controller = TraktController(service: FixtureTraktService())
        await controller.refresh()
        let item = try XCTUnwrap(controller.sync?.items.first)
        await controller.apply(change: item, choice: .skip)
        XCTAssertEqual(controller.sync?.items.first { $0.id == item.id }?.state, "skipped")
        XCTAssertEqual(controller.sync?.pendingChanges, 7)
        controller.kind = .rating; await controller.refresh()
        XCTAssertEqual(controller.visibleItems.count, 3)
        XCTAssertTrue(controller.visibleItems.allSatisfy { $0.kind == "rating" })
        XCTAssertEqual(controller.sync?.pendingChanges, 7)
    }
    func testDisconnectKeepsTheDiaryOutsideProviderState() async {
        let controller = TraktController(service: FixtureTraktService())
        await controller.refresh(); await controller.disconnect()
        XCTAssertFalse(controller.status?.connected ?? true)
        XCTAssertNil(controller.sync?.run)
        XCTAssertNil(controller.error)
    }
    func testLatePagingFailureCannotOverwriteANewerReviewFilter() async {
        let service = TraktRegressionService(), controller = TraktController(service: service)
        await controller.refresh(); await controller.loadMore()
        let page = Task { await controller.loadMore() }
        guard await waitForRegressionCondition({ service.delayed != nil }) else { page.cancel(); XCTFail("The delayed Trakt page did not start"); return }
        controller.kind = .rating; await controller.refresh()
        service.delayed?.resume(throwing: APIError.message("Old page failed")); await page.value
        XCTAssertTrue(controller.visibleItems.allSatisfy { $0.kind == "rating" })
        XCTAssertNil(controller.error); XCTAssertFalse(controller.busy)
    }
    func testCancelledPagingDoesNotShowAnErrorOrLoseConfirmedItems() async {
        let service = TraktRegressionService(), controller = TraktController(service: service)
        await controller.refresh(); await controller.loadMore()
        let confirmed = controller.sync?.items.map(\.id)
        let page = Task { await controller.loadMore() }
        guard await waitForRegressionCondition({ service.delayed != nil }) else { page.cancel(); XCTFail("The delayed Trakt page did not start"); return }
        page.cancel(); service.delayed?.resume(throwing: CancellationError()); await page.value
        XCTAssertNil(controller.error); XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.sync?.items.map(\.id), confirmed)
    }
    func testUnchangedScanProgressPausesInsteadOfSpinningRequests() async {
        let service = TraktRegressionService(), controller = TraktController(service: service)
        service.stagnate = true
        await controller.refresh(); await controller.scan(start: true)
        XCTAssertEqual(service.steps, 2); XCTAssertTrue(controller.paused); XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.sync?.run?.state, "building"); XCTAssertNil(controller.error)
    }

}
