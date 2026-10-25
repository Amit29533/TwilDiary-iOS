import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class CommunityReadGate {
    var pending: CheckedContinuation<CommunityInformation, any Error>?
    func read() async throws -> CommunityInformation { try await withCheckedThrowingContinuation { pending = $0 } }
    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if pending != nil { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

@MainActor final class CommunityInformationTests: XCTestCase {
    func testContractDecodesRealTotalsAndSentimentMetadataWithoutPersonalRating() throws {
        let data = Data(#"{"source":"trakt","statsState":"available","sentimentsState":"available","stats":{"watchers":5200,"plays":49300,"collectors":327,"comments":13,"lists":2300},"sentiments":{"good":["Engaging pacing and mysteries"],"bad":["Repetitive storyline"],"analyzedAt":"2026-10-24T10:00:00Z","commentCount":13}}"#.utf8)
        let value = try JSONDecoder().decode(CommunityInformation.self, from: data)
        XCTAssertTrue(value.valid); XCTAssertEqual(value.stats?.plays, 49300)
        XCTAssertEqual(value.sentiments?.good, ["Engaging pacing and mysteries"])
        let missing = try JSONDecoder().decode(CommunityInformation.self, from: Data(#"{"source":"trakt","statsState":"unavailable","sentimentsState":"unavailable","stats":null,"sentiments":null}"#.utf8))
        XCTAssertTrue(missing.valid); XCTAssertNil(missing.stats); XCTAssertNil(missing.sentiments)
    }
    func testIncompleteCountsAndMalformedSentimentsAreNeverDisplayedAsRealStats() throws {
        let negative = CommunityInformation(source: "trakt", statsState: .available, sentimentsState: .unavailable, stats: .init(watchers: -1, plays: 0, collectors: 0, comments: 0, lists: 0), sentiments: nil)
        XCTAssertFalse(negative.valid)
        let incorrectDate = CommunityInformation(source: "trakt", statsState: .unavailable, sentimentsState: .available, stats: nil, sentiments: .init(good: ["Actual text"], bad: [], analyzedAt: "unknown", commentCount: 1))
        XCTAssertFalse(incorrectDate.valid)
        XCTAssertNil(CommunityIdentity(kind: .tv, id: 0)); XCTAssertNil(CommunityIdentity(kind: .movie, id: nil))
        let route = try XCTUnwrap(CommunityIdentity(kind: .tv, id: 123))
        XCTAssertTrue(route.path.contains("kind=show")); XCTAssertTrue(route.path.contains("provider=tmdb"))
    }
    func testAnUnmatchedTitleShowsAnHonestStateWithoutMakingAProviderRequest() async {
        let controller = CommunityInformationController()
        var requests = 0
        await controller.load(nil) { _, _ in requests += 1; return .fixture(unavailable: false) }
        XCTAssertEqual(requests, 0); XCTAssertEqual(controller.value?.statsState, .unmatched)
        XCTAssertFalse(controller.loading); XCTAssertNil(controller.error)
    }
    func testLateTitleResponseCannotReplaceAnotherInformationSheet() async throws {
        let first = try XCTUnwrap(CommunityIdentity(kind: .tv, id: 1)), second = try XCTUnwrap(CommunityIdentity(kind: .movie, id: 2))
        let controller = CommunityInformationController()
        let gate = CommunityReadGate()
        let old = Task { await controller.load(first) { _, _ in try await gate.read() } }
        let started = await gate.waitUntilStarted()
        guard started, let pending = gate.pending else { old.cancel(); XCTFail("Synthetic request did not start"); return }
        await controller.load(second) { _, _ in .fixture(unavailable: true) }
        pending.resume(returning: .fixture(unavailable: false)); await old.value
        XCTAssertEqual(controller.value?.statsState, .unavailable); XCTAssertNil(controller.value?.stats)
        XCTAssertFalse(controller.loading)
    }
    func testResetCacheRejectsAnOldSessionEvenIfItsTransportCompletes() async throws {
        let cache = CommunityInformationCache(), identity = try XCTUnwrap(CommunityIdentity(kind: .tv, id: 1)), oldScope = UUID()
        let gate = CommunityReadGate()
        let old = Task { try await cache.load(identity, scope: oldScope, retry: false) { try await gate.read() } }
        let started = await gate.waitUntilStarted()
        guard started, let pending = gate.pending else { old.cancel(); XCTFail("Synthetic request did not start"); return }
        cache.reset()
        let fresh = try await cache.load(identity, scope: UUID(), retry: false) { .fixture(unavailable: true) }
        pending.resume(returning: .fixture(unavailable: false))
        do { _ = try await old.value; XCTFail("Previous owner must not publish") } catch is CancellationError { }
        XCTAssertEqual(fresh.statsState, .unavailable)
    }
}
