import XCTest
@testable import TwilDiary

/// The gaps found against Cinopsys: WeTrakr's Idempotency-Key, WeTrakr's held removals, and Trakt's air times.
@MainActor final class TrackerGapTests: XCTestCase {
    func testIdempotencyKeyIsTheSameForTheSameEditAndBody() {
        let body = Data(#"{"movies":[{"ids":{"tmdb":1}}]}"#.utf8)
        let first = DirectProviderClient.idempotencyKey("edit-1", body: body)
        XCTAssertEqual(first, DirectProviderClient.idempotencyKey("edit-1", body: body), "a resend reuses the key")
        XCTAssertTrue(first.hasPrefix("edit-1-"))
        XCTAssertNotEqual(first, DirectProviderClient.idempotencyKey("edit-2", body: body), "another edit gets its own key")
        XCTAssertNotEqual(first, DirectProviderClient.idempotencyKey("edit-1", body: Data(#"{"movies":[{"ids":{"tmdb":2}}]}"#.utf8)), "a changed body is a new request")
    }

    func testABigDropIsHeldUntilTheNextReadAgrees() throws {
        let name = "tracker-gap-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(TrackerPreviewStore.holdsDrop(previous: 100, fresh: 95, defaults: defaults), "a few removals go through")
        XCTAssertFalse(TrackerPreviewStore.holdsDrop(previous: 30, fresh: 15, defaults: defaults), "fewer than 20 lost goes through")
        XCTAssertTrue(TrackerPreviewStore.holdsDrop(previous: 400, fresh: 10, defaults: defaults), "a big drop is held")
        XCTAssertTrue(TrackerPreviewStore.holdsDrop(previous: 400, fresh: 12, defaults: defaults), "a different answer is held again")
        XCTAssertFalse(TrackerPreviewStore.holdsDrop(previous: 400, fresh: 12, defaults: defaults), "the same answer twice goes through")
        XCTAssertTrue(TrackerPreviewStore.holdsDrop(previous: 400, fresh: 12, defaults: defaults), "and the record is cleared after")
        XCTAssertFalse(TrackerPreviewStore.holdsDrop(previous: 400, fresh: 400, defaults: defaults), "a normal read clears a held drop")
        XCTAssertTrue(TrackerPreviewStore.holdsDrop(previous: 400, fresh: 12, defaults: defaults))
    }

    func testTraktCalendarGivesEachEpisodesAirTime() throws {
        let reply = Data(#"""
        [{"first_aired":"2026-11-15T02:00:00.000Z","episode":{"season":2,"number":3},"show":{"title":"Silo","ids":{"trakt":1,"tmdb":125988}}},
         {"first_aired":"2026-11-16T20:30:00Z","episode":{"season":1,"number":1},"show":{"ids":{"tmdb":42}}},
         {"first_aired":null,"episode":{"season":1,"number":2},"show":{"ids":{"tmdb":42}}},
         {"first_aired":"2026-11-17T20:30:00Z","episode":{"season":1,"number":3},"show":{"ids":{"tmdb":null}}}]
        """#.utf8)
        let times = TraktAirTimes.decode(reply)
        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times[TraktAirTimes.key(tmdb: 125988, season: 2, number: 3)], try Date("2026-11-15T02:00:00Z", strategy: .iso8601))
        XCTAssertEqual(times[TraktAirTimes.key(tmdb: 42, season: 1, number: 1)], try Date("2026-11-16T20:30:00Z", strategy: .iso8601))
        XCTAssertTrue(TraktAirTimes.decode(Data("not json".utf8)).isEmpty)
    }
}
