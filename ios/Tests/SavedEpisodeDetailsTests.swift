import XCTest
@testable import TwilDiary

@MainActor final class SavedEpisodeDetailsTests: XCTestCase {
    private func rows(_ season: Int) throws -> [RevealedEpisode] {
        try JSONDecoder().decode([RevealedEpisode].self, from: Data("[{\"id\":\"s\(season)e1\",\"number\":1,\"name\":\"Season \(season) episode\",\"overview\":\"Details\"}]".utf8))
    }
    func testSwitchingSeasonsStartsTheNewRevealWhileTheOldOneIsStillPending() async throws {
        let controller = SavedEpisodeDetailsController()
        var pending: CheckedContinuation<[RevealedEpisode], any Error>?
        let first = Task { await controller.load(1) { try await withCheckedThrowingContinuation { pending = $0 } } }
        guard await waitForRegressionCondition({ pending != nil }) else { first.cancel(); XCTFail("First reveal did not start"); return }
        first.cancel() // Mirrors SwiftUI cancelling .task(id: season) during selection changes.
        await controller.load(2) { try self.rows(2) }
        XCTAssertEqual(controller.episodes["s2e1"]?.name, "Season 2 episode")
        XCTAssertTrue(controller.isLoading(1)); XCTAssertFalse(controller.isLoading(2))
        pending?.resume(returning: try rows(1)); await first.value
        XCTAssertEqual(controller.episodes["s1e1"]?.name, "Season 1 episode")
        XCTAssertEqual(controller.episodes["s2e1"]?.name, "Season 2 episode")
        XCTAssertFalse(controller.isLoading(1))
    }
    func testRepeatedEpisodeTapsCoalesceAndReturningToTheSeasonReusesItsDetails() async throws {
        let controller = SavedEpisodeDetailsController()
        var pending: CheckedContinuation<[RevealedEpisode], any Error>?, calls = 0, joined = false
        let first = Task { await controller.load(1) { calls += 1; return try await withCheckedThrowingContinuation { pending = $0 } } }
        guard await waitForRegressionCondition({ pending != nil }) else { first.cancel(); XCTFail("Reveal did not start"); return }
        let second = Task { joined = true; await controller.load(1) { calls += 1; return try self.rows(1) } }
        guard await waitForRegressionCondition({ joined }) else { first.cancel(); second.cancel(); pending?.resume(throwing: CancellationError()); XCTFail("Second observer did not start"); return }
        pending?.resume(returning: try rows(1)); await first.value; await second.value
        await controller.load(1) { calls += 1; return try self.rows(1) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(controller.episodes.count, 1)
        XCTAssertFalse(controller.isLoading(1)); XCTAssertNil(controller.error(for: 1))
    }
    func testFailedSeasonCanRetryWithoutRemovingAnotherSeasonsDetails() async throws {
        let controller = SavedEpisodeDetailsController()
        await controller.load(1) { try self.rows(1) }
        await controller.load(2) { throw APIError.message("Synthetic reveal outage") }
        XCTAssertEqual(controller.error(for: 2), "Synthetic reveal outage")
        XCTAssertNil(controller.error(for: 1)); XCTAssertNotNil(controller.episodes["s1e1"])
        await controller.load(2) { try self.rows(2) }
        XCTAssertNil(controller.error(for: 2)); XCTAssertNotNil(controller.episodes["s2e1"])
        XCTAssertNotNil(controller.episodes["s1e1"])
    }
    func testSessionResetIgnoresAnOldRevealEvenWhenItsTransportIgnoresCancellation() async throws {
        let controller = SavedEpisodeDetailsController()
        var pending: CheckedContinuation<[RevealedEpisode], any Error>?
        let first = Task { await controller.load(1) { try await withCheckedThrowingContinuation { pending = $0 } } }
        guard await waitForRegressionCondition({ pending != nil }) else { first.cancel(); XCTFail("Reveal did not start"); return }
        controller.reset()
        await controller.load(1) { try self.rows(2) }
        pending?.resume(returning: try rows(1)); await first.value
        XCTAssertNil(controller.episodes["s1e1"]); XCTAssertNotNil(controller.episodes["s2e1"])
        XCTAssertFalse(controller.isLoading(1)); XCTAssertNil(controller.error(for: 1))
    }
}
