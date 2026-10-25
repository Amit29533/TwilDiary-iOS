import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class CommunityRatingsTests: XCTestCase {
    func testBatchesUniqueIDsAndMarksMissingScoresUnavailable() async {
        let ratings = CommunityRatingsController()
        var batches: [[String]] = []
        let ids = (0..<50).map { "title-\($0)" }
        await ratings.prepare(ids + ids) { batch in
            batches.append(batch)
            return [batch[0]: PublicRating(score: 7.3, state: "rated"), "unrequested": PublicRating(score: 9.9, state: "rated")]
        }
        XCTAssertEqual(batches.map(\.count), Array(repeating: 4, count: 12) + [2])
        XCTAssertEqual(batches.flatMap { $0 }, ids)
        XCTAssertEqual(ratings.entries.count, 50)
        XCTAssertNil(ratings.entries["unrequested"])
        XCTAssertEqual(ratings.entries["title-1"]?.state, "unavailable")
        XCTAssertTrue(ratings.unavailable); XCTAssertFalse(ratings.loading)
    }
    func testRatedAndUnratedExpireAfterADayButUnavailableRetriesAfterOneMinute() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let ratings = CommunityRatingsController(clock: { now })
        var batches: [[String]] = []
        let fetch: ([String]) async throws -> [String: PublicRating] = { ids in
            batches.append(ids)
            return ["rated": PublicRating(score: 7.3, state: "rated"), "unrated": PublicRating(score: nil, state: "unrated")]
        }
        await ratings.prepare(["rated", "unrated", "missing"], fetch: fetch)
        now = now.addingTimeInterval(59)
        await ratings.prepare(["rated", "unrated", "missing"], fetch: fetch)
        XCTAssertEqual(batches.count, 1)
        now = now.addingTimeInterval(1)
        await ratings.prepare(["rated", "unrated", "missing"], fetch: fetch)
        XCTAssertEqual(batches.last, ["missing"])
        now = Date(timeIntervalSince1970: 1_086_400)
        await ratings.prepare(["rated", "unrated"], fetch: fetch)
        XCTAssertEqual(batches.last, ["rated", "unrated"])
        XCTAssertEqual(batches.count, 3)
    }
    func testOverlappingPrepareRequestsDoNotFetchTheSameIDTwice() async {
        let ratings = CommunityRatingsController()
        var suspended: CheckedContinuation<[String: PublicRating], any Error>?
        let first = Task { await ratings.prepare(["shared"]) { _ in try await withCheckedThrowingContinuation { suspended = $0 } } }
        guard await waitForRegressionCondition({ suspended != nil }) else { first.cancel(); XCTFail("The suspended ratings request did not start"); return }
        XCTAssertTrue(ratings.loading)
        var secondIDs: [String] = []
        await ratings.prepare(["shared", "other"]) { ids in secondIDs = ids; return [:] }
        XCTAssertEqual(secondIDs, ["other"])
        suspended?.resume(returning: ["shared": PublicRating(score: 8.1, state: "rated")])
        await first.value
        XCTAssertEqual(ratings.entries["shared"]?.score, 8.1)
        XCTAssertFalse(ratings.loading); XCTAssertEqual(ratings.pending, 0)
    }
    func testProviderFailureIsCachedBrieflyAndCanRecoverWithoutAPersonalFallback() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let ratings = CommunityRatingsController(clock: { now })
        await ratings.prepare(["one"]) { _ in throw APIError.message("Synthetic provider failure") }
        XCTAssertEqual(ratings.entries["one"]?.state, "unavailable")
        XCTAssertNil(CommunityScore.value(tmdb: 9.9, trakt: ratings.entries["one"], source: .trakt))
        var called = false
        await ratings.prepare(["one"]) { _ in called = true; return [:] }
        XCTAssertFalse(called)
        now = now.addingTimeInterval(60)
        await ratings.prepare(["one"]) { _ in ["one": PublicRating(score: 6.4, state: "rated")] }
        XCTAssertFalse(ratings.unavailable)
        XCTAssertEqual(ratings.entries["one"]?.score, 6.4)
    }
    func testSessionResetDiscardsLateResultsAndCanFetchAgain() async {
        let ratings = CommunityRatingsController()
        var suspended: CheckedContinuation<[String: PublicRating], any Error>?
        let first = Task { await ratings.prepare(["one"]) { _ in try await withCheckedThrowingContinuation { suspended = $0 } } }
        guard await waitForRegressionCondition({ suspended != nil }) else { first.cancel(); XCTFail("The suspended ratings request did not start"); return }
        ratings.reset()
        await ratings.prepare(["one"]) { _ in ["one": PublicRating(score: 6.4, state: "rated")] }
        suspended?.resume(returning: ["one": PublicRating(score: 9.9, state: "rated")])
        await first.value
        XCTAssertEqual(ratings.entries["one"]?.score, 6.4)
        XCTAssertEqual(ratings.pending, 0)
    }
    func testCancellationDoesNotCacheAProviderFailureOrPreventRetry() async {
        let ratings = CommunityRatingsController()
        var suspended: CheckedContinuation<[String: PublicRating], any Error>?
        let first = Task { await ratings.prepare(["one"]) { _ in try await withCheckedThrowingContinuation { suspended = $0 } } }
        guard await waitForRegressionCondition({ suspended != nil }) else { first.cancel(); XCTFail("The suspended ratings request did not start"); return }
        first.cancel(); suspended?.resume(throwing: CancellationError()); await first.value
        XCTAssertTrue(ratings.entries.isEmpty); XCTAssertFalse(ratings.loading)
        await ratings.prepare(["one"]) { _ in ["one": PublicRating(score: 8.1, state: "rated")] }
        XCTAssertEqual(ratings.entries["one"]?.score, 8.1)
    }
    func testProviderOutageStopsRemainingBatchesAndExplicitRetryBypassesShortFailureCache() async {
        let ratings = CommunityRatingsController()
        let ids = (0..<100).map { "title-\($0)" }
        var calls = 0
        await ratings.prepare(ids) { _ in calls += 1; throw APIError.message("Offline") }
        XCTAssertEqual(calls, 1); XCTAssertEqual(ratings.entries.count, 100)
        XCTAssertFalse(ratings.loading); XCTAssertTrue(ratings.unavailable)
        ratings.retryUnavailable()
        await ratings.prepare(ids) { batch in calls += 1; return Dictionary(uniqueKeysWithValues: batch.map { ($0, PublicRating(score: nil, state: "unrated")) }) }
        XCTAssertEqual(calls, 26); XCTAssertFalse(ratings.unavailable)
    }
    func testUnavailableEnvelopeAlsoStopsFutileBatchesWithoutTreatingUnratedAsAnOutage() async {
        let ratings = CommunityRatingsController()
        var calls = 0
        await ratings.prepare((0..<60).map(String.init)) { batch in calls += 1; return Dictionary(uniqueKeysWithValues: batch.map { ($0, PublicRating(score: nil, state: "unavailable")) }) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(ratings.entries.count, 60); XCTAssertFalse(ratings.loading)
    }

    func testSlowSuccessfulProviderStopsAtTheWholeLoadBudgetAndPublishesItsFirstBatch() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let ratings = CommunityRatingsController(clock: { now })
        var calls = 0
        await ratings.prepare((0..<60).map(String.init)) { batch in
            calls += 1; now = now.addingTimeInterval(13)
            return Dictionary(uniqueKeysWithValues: batch.map { ($0, PublicRating(score: 8.1, state: "rated")) })
        }
        XCTAssertEqual(calls, 1); XCTAssertEqual(ratings.entries["0"]?.score, 8.1)
        XCTAssertEqual(ratings.entries["59"]?.state, "unavailable"); XCTAssertFalse(ratings.loading)
    }

}
