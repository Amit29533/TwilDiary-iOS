import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Edits sent the way Cinopsys sends them: queued, sent in the background, and a play just added
/// (no Trakt id here yet) found in Trakt's history at its time before it's removed.
@MainActor final class TraktSendQueueTests: XCTestCase {
    private func body(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testRemovalFindsJustAddedPlaysByTheirTime() throws {
        let show = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 1399, name: "Show")
        let movie = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 603, name: "Movie")
        let found = [
            TraktPlay(historyId: 10, title: show, season: 1, episode: 2, watchedAt: "2026-11-11T10:00:00.000Z"),
            TraktPlay(historyId: 11, title: show, season: 1, episode: 2, watchedAt: "2026-11-11T09:00:00.000Z"),  // an older watch: kept
            TraktPlay(historyId: 12, title: show, season: 1, episode: 3, watchedAt: "2026-11-11T10:00:00.000Z"),  // another episode: kept
            TraktPlay(historyId: 20, title: movie, watchedAt: "2026-11-11T10:00:01.000Z"),
        ]
        let wanted = TraktDirectStore.requestedPlays(try body([
            "movies": [["ids": ["tmdb": 603], "watched_at": "2026-11-11T10:00:00.000Z"]],
            "shows": [["ids": ["tmdb": 1399], "seasons": [["number": 1, "episodes": [["number": 2, "watched_at": "2026-11-11T10:00:00.000Z"]]]]]],
        ]))
        XCTAssertEqual(wanted.count, 2)
        XCTAssertEqual(Set(TraktDirectStore.historyIDs(for: wanted, in: found)), [10, 20])
    }

    func testRemovalLeavesAPlayOutsideTheMinute() throws {
        let movie = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 603, name: "Movie")
        let found = [TraktPlay(historyId: 20, title: movie, watchedAt: "2026-11-11T10:05:00.000Z")]
        let wanted = TraktDirectStore.requestedPlays(try body(["movies": [["ids": ["tmdb": 603], "watched_at": "2026-11-11T10:00:00.000Z"]]]))
        XCTAssertEqual(TraktDirectStore.historyIDs(for: wanted, in: found), [], "a watch at another time is never removed")
    }

    func testFailedSendsAreKeptOrDroppedLikeCinopsys() {
        XCTAssertEqual(TrackerPreviewStore.delivery(URLError(.notConnectedToInternet)), .retryLater, "offline: kept")
        XCTAssertEqual(TrackerPreviewStore.delivery(URLError(.timedOut)), .retryLater, "lost answer: sent again")
        XCTAssertEqual(TrackerPreviewStore.delivery(APIError.rejected(503, "down")), .retryLater)
        XCTAssertEqual(TrackerPreviewStore.delivery(APIError.rejected(429, "busy")), .retryLater)
        XCTAssertEqual(TrackerPreviewStore.delivery(APIError.rejected(401, "sign-in")), .authBlocked, "kept until reconnected")
        XCTAssertEqual(TrackerPreviewStore.delivery(APIError.rejected(400, "bad")), .rejected, "refused: dropped, and the screen put back")
        XCTAssertEqual(TrackerPreviewStore.delivery(APIError.message("MDBList is busy with another change right now. Try again in a minute.")), .retryLater)
        XCTAssertEqual(TraktDelivery.of(APIError.message("Trakt asked TwilDiary to slow down. It tries again after 10:00.")), .retryLater,
                       "a cool-down never drops an edit")
    }

    func testDailyQuotaComesFromWeTrakrsQuotaHeadersOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let daily = ProviderQuota.parse(["X-Quota-Limit": "500", "X-Quota-Remaining": "494", "X-Quota-Reset": "3600"], now: now)
        XCTAssertEqual(daily?.used, 6); XCTAssertEqual(daily?.limit, 500)
        XCTAssertEqual(daily?.resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(ProviderQuota.parse(["x-quota-limit": "1000", "x-quota-remaining": "1000"], now: now)?.used, 0, "header names in any case")
        XCTAssertNil(ProviderQuota.parse(["X-RateLimit-Limit": "1000", "X-RateLimit-Remaining": "10"], now: now),
                     "a rate window isn't a daily allowance")
    }

    func testEverythingCalendarListsEachReleaseOnce() {
        func release(_ id: String) -> UniversalRelease {
            UniversalRelease(id: id, kind: .movie, name: id, poster: nil, day: "2026-11-14", time: nil, detail: "Movie",
                             route: CatalogRoute(kind: .movie, id: 1), anime: nil, genres: [], popularity: 1)
        }
        // TMDB's second page repeating a movie from the first: listed once (a repeated id stops the app).
        XCTAssertEqual(UniversalReleases.unique([release("movie:1"), release("movie:2"), release("movie:1")]).map(\.id), ["movie:1", "movie:2"])
    }

    func testWeTrakrLookUpReadsItsOwnId() throws {
        func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        XCTAssertEqual(TrackerPreviewStore.weTrakrMatch(try data([["id": 7, "type": "movie"], ["id": 9, "type": "show"]]), show: true), 9)
        XCTAssertEqual(TrackerPreviewStore.weTrakrMatch(try data(["id": 42, "type": "movie"]), show: false), 42)
        XCTAssertEqual(TrackerPreviewStore.weTrakrMatch(try data(["data": [["id": 5, "type": "show"]]]), show: true), 5)
        XCTAssertNil(TrackerPreviewStore.weTrakrMatch(try data([["id": 7, "type": "movie"]]), show: true), "never a title of the other kind")
    }

    func testListedAddsAndNotFoundTitlesAreUnderstood() throws {
        func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        XCTAssertTrue(ProviderDeliveryPlanner.confirms(try data(["added": ["movies": [["ids": ["tmdb": 603]]]], "not_found": ["movies": []]])),
                      "a service that lists what it added")
        XCTAssertTrue(ProviderDeliveryPlanner.notFound(try data(["added": ["movies": 0], "not_found": ["movies": [["ids": ["tmdb": 1]]]]])))
        XCTAssertFalse(ProviderDeliveryPlanner.notFound(try data(["added": ["movies": 1], "not_found": ["movies": []]])))
    }

    func testIdOnlyTitlesGetTheirNames() {
        let bare = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 1399, name: "")
        let library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: bare, season: 1, episode: 1, watchedAt: nil)], watchlist: [TraktListed(title: bare, listedAt: nil)])
        let named = library.naming { $0.diaryKey == "tv:1399" ? "Game of Thrones" : nil }
        XCTAssertEqual(named.plays.first?.title.name, "Game of Thrones")
        XCTAssertEqual(named.watchlist.first?.title.name, "Game of Thrones")
    }

    func testServiceLookUpsAndLeftOutTitles() throws {
        func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        XCTAssertTrue(ServiceIDs.weTrakrHasNone(try data([Any]())))
        XCTAssertTrue(ServiceIDs.weTrakrHasNone(try data(["data": [Any]()])))
        XCTAssertFalse(ServiceIDs.weTrakrHasNone(try data([["id": 5, "type": "movie"]])))
        let reply = ServiceIDs.reply(try data(["added": ["movies": 1]]), adding: [["ids": ["tmdb": 9], "slot": "movies"]])
        XCTAssertTrue(ProviderDeliveryPlanner.notFound(reply), "a title the service lacks is reported, not silently dropped")
        XCTAssertEqual(TraktDirectStore.notFoundCount(reply), 1)
    }

    /// Cinopsys merges unsent changes to the same setting of the same title; plays never merge.
    func testOnlyStateChangesToOneTitleMerge() {
        let movie: [String: Any] = ["movies": [["ids": ["tmdb": 603]]]]
        XCTAssertEqual(PendingMerge.key("/sync/ratings", movie), PendingMerge.key("/sync/ratings/remove", movie))
        XCTAssertEqual(PendingMerge.key("/sync/watchlist", movie), "watchlist|movies:603")
        XCTAssertNotEqual(PendingMerge.key("/sync/watchlist", movie), PendingMerge.key("/sync/favorites", movie))
        XCTAssertNil(PendingMerge.key("/sync/history", movie), "A play is an event")
        XCTAssertNil(PendingMerge.key("/sync/tracking", ["movies": [["ids": ["tmdb": 603], "status": "watched"]]]))
        XCTAssertEqual(PendingMerge.key("/sync/tracking", ["movies": [["ids": ["tmdb": 603], "status": "planning"]]]), "tracking|movies:603")
        XCTAssertNil(PendingMerge.key("/sync/ratings", ["movies": [["ids": ["tmdb": 1]], ["ids": ["tmdb": 2]]]]), "Only one title's change merges")
    }
}

