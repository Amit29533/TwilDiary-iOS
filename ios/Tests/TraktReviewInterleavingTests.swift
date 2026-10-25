import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class HeldTraktService: TraktServicing {
    let fixture = FixtureTraktService()
    var statusReads = 0
    var reviewReads = 0
    var holdStep = false
    var holdApply = false
    var pending: CheckedContinuation<TraktSync, any Error>?
    var pendingResult: TraktSync?
    func status() async throws -> TraktStatus { statusReads += 1; return try await fixture.status() }
    func review(kind: TraktKind, query: String, after: String?) async throws -> TraktSync {
        reviewReads += 1; return try await fixture.review(kind: kind, query: query, after: after)
    }
    func start(mode: TraktRatingMode) async throws -> String { try await fixture.start(mode: mode) }
    func step(id: String) async throws -> TraktSync {
        let result = try await fixture.step(id: id)
        if holdStep { holdStep = false; return try await suspend(result) }
        return result
    }
    func apply(id: String, change: String?, choice: TraktChoice) async throws -> TraktSync {
        let result = try await fixture.apply(id: id, change: change, choice: choice)
        if holdApply { holdApply = false; return try await suspend(result) }
        return result
    }
    func cancel(id: String) async throws { try await fixture.cancel(id: id) }
    func disconnect() async throws { try await fixture.disconnect() }
    private func suspend(_ result: TraktSync) async throws -> TraktSync {
        pendingResult = result
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func release() {
        if let result = pendingResult { pending?.resume(returning: result) }
        pending = nil; pendingResult = nil
    }
}

@MainActor final class TraktReviewInterleavingTests: XCTestCase {
    func testReviewFiltersDoNotRefetchTheConnectionStatus() async {
        let service = HeldTraktService(), controller = TraktController(service: service)
        await controller.refreshReview()
        XCTAssertEqual(service.statusReads, 1); XCTAssertEqual(service.reviewReads, 1)
        controller.kind = .rating; await controller.refreshReview()
        XCTAssertEqual(service.statusReads, 1); XCTAssertEqual(service.reviewReads, 2)
        XCTAssertEqual(controller.visibleItems.count, 3)
        await controller.refresh()
        XCTAssertEqual(service.statusReads, 2)
    }
    func testFilterRefreshDuringScanWaitsForTheScanAndThenLoadsTheLatestFilter() async {
        let service = HeldTraktService(), controller = TraktController(service: service)
        await controller.refresh(); service.holdStep = true
        let scan = Task { await controller.scan(start: true) }
        guard await waitForRegressionCondition({ service.pending != nil }) else { scan.cancel(); service.release(); XCTFail("Scan did not reach its held step"); return }
        controller.kind = .rating
        await controller.refreshReview()
        XCTAssertEqual(service.statusReads, 1); XCTAssertEqual(service.reviewReads, 1)
        XCTAssertTrue(controller.busy); XCTAssertFalse(controller.loading)
        service.release(); await scan.value
        XCTAssertEqual(controller.sync?.run?.state, "review")
        XCTAssertEqual(service.statusReads, 1); XCTAssertEqual(service.reviewReads, 2)
        XCTAssertEqual(controller.visibleItems.count, 3)
        XCTAssertTrue(controller.visibleItems.allSatisfy { $0.kind == "rating" })
        XCTAssertEqual(controller.sync?.pendingChanges, 8)
        XCTAssertFalse(controller.busy); XCTAssertFalse(controller.loading); XCTAssertNil(controller.error)
    }
    func testFilterRefreshDuringApplyCannotReintroduceTheOldPendingReview() async throws {
        let service = HeldTraktService(), controller = TraktController(service: service)
        await controller.refresh()
        let safe = try XCTUnwrap(controller.sync?.items.first { !$0.review && $0.state == "pending" })
        service.holdApply = true
        let apply = Task { await controller.apply(change: safe) }
        guard await waitForRegressionCondition({ service.pending != nil }) else { apply.cancel(); service.release(); XCTFail("Apply did not reach its held response"); return }
        controller.kind = .rating; await controller.refreshReview()
        XCTAssertEqual(service.reviewReads, 1)
        service.release(); await apply.value
        XCTAssertEqual(controller.sync?.pendingChanges, 7)
        XCTAssertTrue(controller.visibleItems.allSatisfy { $0.kind == "rating" })
        XCTAssertEqual(service.reviewReads, 2); XCTAssertEqual(service.statusReads, 2)
        XCTAssertFalse(controller.busy); XCTAssertFalse(controller.loading); XCTAssertNil(controller.error)
    }
}
