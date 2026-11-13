import Foundation
import Testing
@testable import TwilDiaryCore

private func data(_ json: String) -> Data { Data(json.utf8) }

@Test func onlyTheListsWhoseActivityMovedAreFetchedAgain() throws {
    let before = try TraktDecode.activities(from: data("""
    {"all":"2026-11-01T10:00:00.000Z","movies":{"watched_at":"2026-10-01T00:00:00.000Z","rated_at":"2026-10-02T00:00:00.000Z","watchlisted_at":"2026-10-03T00:00:00.000Z","favorited_at":"2026-10-04T00:00:00.000Z"},
     "episodes":{"watched_at":"2026-11-01T10:00:00.000Z"},"shows":{"rated_at":"2026-10-05T00:00:00.000Z","watchlisted_at":"2026-10-06T00:00:00.000Z","favorited_at":"2026-10-07T00:00:00.000Z","hidden_at":"2026-10-08T00:00:00.000Z"}}
    """))
    #expect(before.stamps["episodes.watched_at"] == "2026-11-01T10:00:00.000Z")
    #expect(before.changed(since: nil) == Set(TraktDomain.allCases), "First read fetches everything")
    #expect(before.changed(since: before).isEmpty, "Nothing changed: no list is fetched")
    let watched = try TraktDecode.activities(from: data("""
    {"all":"2026-11-02T10:00:00.000Z","movies":{"watched_at":"2026-10-01T00:00:00.000Z","rated_at":"2026-10-02T00:00:00.000Z","watchlisted_at":"2026-10-03T00:00:00.000Z","favorited_at":"2026-10-04T00:00:00.000Z"},
     "episodes":{"watched_at":"2026-11-02T10:00:00.000Z"},"shows":{"rated_at":"2026-10-05T00:00:00.000Z","watchlisted_at":"2026-10-06T00:00:00.000Z","favorited_at":"2026-10-07T00:00:00.000Z","hidden_at":"2026-10-08T00:00:00.000Z"}}
    """))
    // History moved; notes have no reported field, so they are read whenever anything changed.
    #expect(watched.changed(since: before) == [.history, .notes])
}

@Test func historyKeepsEachPlayWithItsOwnIdAndSkipsWhatCannotBeIdentified() throws {
    let (plays, skipped) = try TraktDecode.history(from: data("""
    [{"id":14593878476,"watched_at":"2026-10-31T23:16:00.000Z","action":"watch","type":"episode",
      "episode":{"season":1,"number":12,"title":"Episode 12","ids":{"trakt":1}},
      "show":{"title":"Spooky in Love","year":2026,"ids":{"trakt":250001,"tmdb":284172,"imdb":"tt1","tvdb":44}}},
     {"id":14573970426,"watched_at":"2021-04-06T18:30:00.000Z","action":"watch","type":"movie",
      "movie":{"title":"Wolf Children","year":2012,"ids":{"trakt":77892,"tmdb":110420,"imdb":"tt2140203"}}},
     {"id":3,"watched_at":"2021-04-06T18:30:00.000Z","type":"movie","movie":{"title":"No ids","ids":{}}},
     {"id":4,"type":"episode","episode":{"season":1},"show":{"title":"No number","ids":{"tmdb":1}}},
     {"id":5,"type":"season"}]
    """))
    #expect(plays.count == 2); #expect(skipped == 3)
    #expect(plays[0].historyId == 14593878476 && plays[0].season == 1 && plays[0].episode == 12)
    #expect(plays[0].title.diaryKey == "tv:284172" && plays[0].title.imdbId == "tt1")
    #expect(plays[1].title.diaryKey == "movie:110420" && plays[1].season == nil)
}

@Test func ratingsAndListsReadMoviesAndShowsOnly() throws {
    let (ratings, badRatings) = try TraktDecode.ratings(from: data("""
    [{"rated_at":"2026-10-31T23:16:00.000Z","rating":8,"type":"show","show":{"title":"Spooky in Love","ids":{"tmdb":284172}}},
     {"rating":11,"type":"movie","movie":{"title":"Too high","ids":{"tmdb":2}}}]
    """))
    #expect(ratings.map(\.rating) == [8]); #expect(badRatings == 1)
    let (watchlist, _) = try TraktDecode.listed(from: data("""
    [{"listed_at":"2026-11-04T18:56:00.000Z","type":"movie","movie":{"title":"Obsession","ids":{"tmdb":3}}},
     {"listed_at":"2026-11-04T18:56:00.000Z","type":"season","season":{"number":1},"show":{"title":"A show","ids":{"tmdb":4}}}]
    """))
    #expect(watchlist.map(\.title.name) == ["Obsession"], "Seasons and episodes in a list are left out")
    let (dropped, _) = try TraktDecode.listed(from: data("""
    [{"hidden_at":"2026-11-03T13:32:00.000Z","type":"show","show":{"title":"Wednesday","ids":{"tmdb":119051}}}]
    """))
    #expect(dropped.first?.listedAt == "2026-11-03T13:32:00.000Z")
}

/// A small diary: Spooky in Love (two episodes, rated 9, favourite), Obsession (planned) and a
/// title Trakt doesn't have.
private func diary() throws -> Workspace {
    let object: [String: Any] = [
        "titles": [
            ["id": "spooky", "name": "Spooky in Love", "category": "anime", "overview": "", "tmdbId": 284172, "genres": [], "status": "completed", "favorite": true, "score": 9, "notes": ""],
            ["id": "obsession", "name": "Obsession", "category": "movie", "overview": "", "tmdbId": 3, "genres": [], "status": "planned", "favorite": false, "notes": ""],
            ["id": "local", "name": "Diary only", "category": "movie", "overview": "", "tmdbId": 9, "genres": [], "status": "completed", "favorite": false, "notes": ""]
        ],
        "episodes": [
            ["id": "e11", "titleId": "spooky", "season": 1, "number": 11, "name": "", "overview": ""],
            ["id": "e12", "titleId": "spooky", "season": 1, "number": 12, "name": "", "overview": ""]
        ],
        "events": [
            ["id": "w1", "operationId": "o1", "titleId": "spooky", "episodeId": "e11", "watchedAt": "2026-11-04T07:42:00Z", "recordedAt": "2026-11-04T07:42:00Z", "origin": "trakt"],
            ["id": "w2", "operationId": "o2", "titleId": "spooky", "episodeId": "e12", "watchedAt": "2026-10-31T23:16:00Z", "recordedAt": "2026-10-31T23:16:00Z", "origin": "trakt"],
            ["id": "w3", "operationId": "o3", "titleId": "spooky", "episodeId": "e12", "watchedAt": "2026-10-31T23:16:04Z", "recordedAt": "2026-10-31T23:16:04Z", "revokedAt": "2026-11-04T19:30:00Z", "origin": "manual"],
            ["id": "w4", "operationId": "o4", "titleId": "local", "watchedAt": "2026-01-01T00:00:00Z", "recordedAt": "2026-01-01T00:00:00Z", "origin": "manual"]
        ],
        "locations": []
    ]
    return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func theShadowComparisonFindsEveryKindOfDifferenceAndIgnoresRemovedPlays() throws {
    let spooky = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 284172, name: "Spooky in Love")
    let obsession = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 3, name: "Obsession")
    var library = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: spooky, season: 1, episode: 11, watchedAt: "2026-11-04T07:42:00.000Z"),
                TraktPlay(historyId: 2, title: spooky, season: 1, episode: 12, watchedAt: "2026-10-31T23:16:00.000Z")],
        ratings: [TraktRating(title: spooky, rating: 9, ratedAt: nil)],
        watchlist: [TraktListed(title: obsession, listedAt: nil)],
        favorites: [TraktListed(title: spooky, listedAt: nil)])
    var result = TraktComparison.compare(library, with: try diary())
    #expect(result.matchingPlays == 2, "The removed S1E12 copy does not count")
    #expect(result.onlyInDiary.map(\.title) == ["Diary only"])
    #expect(result.onlyOnTrakt.isEmpty && result.ratingDifferences.isEmpty && result.plannedDifferences.isEmpty && result.favoriteDifferences.isEmpty)
    // Trakt says 8, an extra rewatch, Obsession off the watchlist, Spooky dropped and not a favourite.
    library.ratings = [TraktRating(title: spooky, rating: 8, ratedAt: nil)]
    library.plays.append(TraktPlay(historyId: 3, title: spooky, season: 1, episode: 12, watchedAt: "2026-11-05T10:00:00.000Z"))
    library.watchlist = []; library.favorites = []
    library.dropped = [TraktListed(title: spooky, listedAt: nil)]
    library.plays.append(TraktPlay(historyId: 4, title: TraktTitleRef(kind: .movie, traktId: 99, tmdbId: nil, name: "No TMDB id"), watchedAt: nil))
    result = TraktComparison.compare(library, with: try diary())
    #expect(result.onlyOnTrakt.map(\.detail) == ["2 on Trakt, 1 in the diary"])
    #expect(result.ratingDifferences.map(\.detail) == ["diary 9, Trakt 8"])
    #expect(result.plannedDifferences.count == 1 && result.favoriteDifferences.count == 1 && result.droppedDifferences.count == 1)
    #expect(result.unmatchedTraktTitles == 1)
    #expect(!result.matches)
}

// MARK: Main tracker: MDBList and WeTrakr read into the same library

@Test func everyTrackerSaysWhatStaysInCloudflare() {
    #expect(MainTracker.trakt.keptInCloudflare == ["the full text of notes over 500 characters"])
    #expect(MainTracker.mdblist.keptInCloudflare.contains("rewatch counts"))
    #expect(MainTracker.mdblist.keptInCloudflare.contains("favourite titles"))
    #expect(MainTracker.mdblist.keptInCloudflare.contains("notes"))
    #expect(MainTracker.wetrakr.keptInCloudflare == ["notes"])
    #expect(MainTracker.allCases == [.trakt, .mdblist, .wetrakr])
}

@Test func withoutRewatchesTheComparisonChecksWatchedAtLeastOnce() throws {
    let spooky = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 284172, name: "Spooky in Love")
    let obsession = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 3, name: "Obsession")
    let local = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 9, name: "Diary only")
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: spooky, season: 1, episode: 11, watchedAt: nil),
                TraktPlay(historyId: 2, title: spooky, season: 1, episode: 12, watchedAt: nil),
                TraktPlay(historyId: 3, title: local, watchedAt: nil)],
        ratings: [TraktRating(title: spooky, rating: 9, ratedAt: nil)],
        watchlist: [TraktListed(title: obsession, listedAt: nil)])
    // MDBList keeps no favourites: the diary favourite is not a difference, it stays in Cloudflare.
    let mdblist = TraktComparison.compare(library, with: try diary(), tracker: .mdblist)
    #expect(mdblist.matches)
    #expect(mdblist.matchingPlays == 3)
    var rewatched = library
    rewatched.ratings = [TraktRating(title: spooky, rating: 8, ratedAt: nil)]
    let differs = TraktComparison.compare(rewatched, with: try diary(), tracker: .mdblist)
    #expect(differs.ratingDifferences.map(\.detail) == ["diary 9, MDBList 8"])
    // Trakt holds favourites, so the same library differs there.
    #expect(TraktComparison.compare(library, with: try diary()).favoriteDifferences.count == 1)
}

@Test func mdblistPagesReadTraktStyleAndFlatItemsWithTheirCursor() throws {
    let page = try TrackerDecode.mdblistPage(from: data("""
    {"movies":[{"watched_at":"2026-01-01T00:00:00Z","movie":{"title":"Wolf Children","year":2012,"ids":{"tmdb":110420,"imdb":"tt2140203"}}}],
     "episodes":[{"watched_at":"2026-02-01T00:00:00Z","show":{"title":"Spooky in Love","ids":{"tmdb":284172}},"episode":{"season":1,"number":12}}],
     "items":[{"title":"Rated show","mediatype":"show","rating":8,"rated_at":"2026-03-01T00:00:00Z","ids":{"tmdb":42}},
              {"title":"No ids","mediatype":"movie"}],
     "pagination":{"next_cursor":"abc"}}
    """))
    #expect(page.items.count == 3 && page.skipped == 1)
    #expect(page.items[1].title.kind == .show && page.items[1].season == 1 && page.items[1].episode == 12)
    #expect(page.items[2].rating == 8 && page.items[2].title.kind == .show)
    #expect(page.next == "abc")
    let last = try TrackerDecode.mdblistPage(from: data("""
    [{"movie":{"title":"Office Space","ids":{"tmdb":1542}},"listed_at":"2026-04-01T00:00:00Z"}]
    """))
    #expect(last.items.map(\.title.tmdbId) == [1542] && last.next == nil)
    // Trakt-style watched shows nest their episodes; season 0 (specials) is kept.
    let nested = try TrackerDecode.mdblistPage(from: data("""
    {"shows":[{"show":{"title":"Spooky in Love","ids":{"tmdb":284172}},
               "seasons":[{"number":0,"episodes":[{"number":1,"last_watched_at":"2026-01-01T00:00:00Z"}]},
                          {"number":1,"episodes":[{"number":11},{"number":12}]}]}]}
    """))
    #expect(nested.items.map { "\($0.season ?? -1)x\($0.episode ?? -1)" } == ["0x1", "1x11", "1x12"])
}

/// MDBList's published examples: watched episodes nest their show, watchlist items are flat with
/// the TMDB id in "id", and last activities are flat (server_time ignored).
@Test func mdblistDocumentedShapesAreRead() throws {
    let watched = try TrackerDecode.mdblistPage(from: data("""
    {"movies":[],"shows":[],"seasons":[],"episodes":[{"last_watched_at":"2026-10-17T21:30:00.000Z","episode":{"season":2,"number":5,"name":"Episode 5",
      "ids":{"tmdb":111111},"show":{"title":"Example Show","year":2005,"ids":{"tmdb":1000,"trakt":2000,"imdb":"tt0000001","mdblist":"example-show","tvdb":3000}},
      "display_code":"S23E05","tvdb":{"season":23,"number":5}}}],"pagination":{"limit":100,"next_cursor":null}}
    """))
    #expect(watched.items.count == 1 && watched.skipped == 0)
    #expect(watched.items[0].title.tmdbId == 1000 && watched.items[0].title.kind == .show)
    #expect(watched.items[0].season == 2 && watched.items[0].episode == 5)
    #expect(watched.next == nil)
    let watchlist = try TrackerDecode.mdblistPage(from: data("""
    {"movies":[{"id":917496,"title":"Beetlejuice Beetlejuice","imdb_id":"tt2049403","ids":{"mdblist":"m917496","imdb":"tt2049403","tmdb":917496},"mediatype":"movie","release_year":2024}],
     "shows":[{"id":258902,"title":"English Teacher","imdb_id":"tt20782190","tvdb_id":421968,"mediatype":"show","release_year":2024}]}
    """))
    #expect(watchlist.items.map(\.title.tmdbId) == [917496, 258902])
    #expect(watchlist.items[1].title.kind == .show && watchlist.items[1].title.year == 2024)
    let first = try TrackerDecode.flatActivities(from: data(#"{"watched_at":"2026-11-01T00:00:00Z","rated_at":"2026-10-01T00:00:00Z","server_time":"2026-11-05T10:00:00Z"}"#))
    let again = try TrackerDecode.flatActivities(from: data(#"{"watched_at":"2026-11-01T00:00:00Z","rated_at":"2026-10-01T00:00:00Z","server_time":"2026-11-05T10:05:00Z"}"#))
    #expect(first == again, "Only server_time moved: nothing to read again")
    #expect(first.stamps["watched_at"] == "2026-11-01T00:00:00Z")
}


// MARK: Phase 2: make Trakt match the diary

@Test func makeTraktMatchSendsOnlyWhatTraktLacksWithTheDiarysOwnTimes() throws {
    let spooky = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 284172, name: "Spooky in Love")
    let alya = TraktTitleRef(kind: .show, traktId: 7, tmdbId: 777, name: "Alya")
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: spooky, season: 1, episode: 11, watchedAt: "2026-11-04T07:42:20.000Z")],
        ratings: [TraktRating(title: spooky, rating: 8, ratedAt: nil)],
        favorites: [TraktListed(title: alya, listedAt: nil)])
    let plan = TraktWritePlan.make(library: library, workspace: try diary())
    // E11 is on Trakt (20 s apart counts as the same watch); E12 and the movie are not; the revoked copy never goes.
    #expect(plan.plays.map { "\($0.title.tmdbId) s\($0.season ?? 0)e\($0.episode ?? 0) \($0.watchedAt)" }.sorted()
            == ["284172 s1e12 2026-10-31T23:16:00.000Z", "9 s0e0 2026-01-01T00:00:00.000Z"])
    #expect(plan.ratings.map(\.rating) == [9], "The diary's rating wins")
    #expect(plan.watchlistAdd.map(\.tmdbId) == [3])
    #expect(plan.favouritesAdd.map(\.name) == ["Spooky in Love"])
    #expect(plan.diaryFavourites.isEmpty, "Alya isn't in the diary, so there's nothing to mark")
    #expect(plan.dropped.isEmpty && plan.watchlistRemove.isEmpty)
    let requests = plan.requests()
    #expect(requests.map(\.path) == ["/sync/history", "/sync/ratings", "/sync/watchlist", "/sync/favorites"])
    let history = String(decoding: requests[0].body, as: UTF8.self)
    #expect(history.contains("\"watched_at\":\"2026-10-31T23:16:00.000Z\"") && history.contains("\"tmdb\":284172"))
    #expect(!plan.summary.isEmpty)
    // Once Trakt has everything, nothing is sent.
    var done = library
    done.plays += [TraktPlay(historyId: 2, title: spooky, season: 1, episode: 12, watchedAt: "2026-10-31T23:16:00.000Z"),
                   TraktPlay(historyId: 3, title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 9, name: "Diary only"), watchedAt: "2026-01-01T00:00:00.000Z")]
    done.ratings = [TraktRating(title: spooky, rating: 9, ratedAt: nil)]
    done.watchlist = [TraktListed(title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 3, name: "Obsession"), listedAt: nil)]
    done.favorites = [TraktListed(title: spooky, listedAt: nil)]
    #expect(TraktWritePlan.make(library: done, workspace: try diary()).isEmpty)
}

@Test func aWatchKeptAtAnotherTimeIsNotSentAgain() throws {
    // WeTrakr (rewatches kept) has E11 at another time: it stands for the diary's one, so nothing
    // is logged twice; a second diary watch of it would still go.
    let spooky = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 284172, name: "Spooky in Love")
    let library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: spooky, season: 1, episode: 11, watchedAt: "2025-01-01T00:00:00.000Z")])
    let plan = TraktWritePlan.make(library: library, workspace: try diary(), tracker: .wetrakr)
    #expect(!plan.plays.contains { $0.title.tmdbId == 284172 && $0.episode == 11 })
    #expect(plan.plays.contains { $0.title.tmdbId == 284172 && $0.episode == 12 && !$0.rewatch }, "A first watch: WeTrakr isn't asked to log another play")
    let body = String(decoding: try #require(plan.requests().first { $0.path == "/sync/tracking" }).body, as: UTF8.self)
    #expect(body.contains("\"allow_rewatch\":false") && !body.contains("\"allow_rewatch\":true"))
}

@Test func whatDidntStickIsNeitherResentNorADifference() throws {
    // The ledger (sent once, not kept by the service) is left out of the plan and the differences.
    let library = TraktLibrary()
    let full = TraktWritePlan.make(library: library, workspace: try diary(), tracker: .mdblist)
    let stuck = Set(full.tokens.filter { $0.hasPrefix("play|") }.prefix(1))
    #expect(!stuck.isEmpty)
    let again = TraktWritePlan.make(library: library, workspace: try diary(), tracker: .mdblist, except: stuck)
    #expect(again.tokens.isDisjoint(with: stuck) && again.plays.count == full.plays.count - 1)
    let before = TraktComparison.compare(library, with: try diary(), tracker: .mdblist).onlyInDiary.count
    let after = TraktComparison.compare(library, with: try diary(), tracker: .mdblist, except: stuck).onlyInDiary.count
    #expect(after == before - 1)
}

// MARK: Phase 5: MDBList matches the diary

@Test func mdblistGetsOneWatchPerEpisodeAndItsOwnEndpoints() throws {
    let spooky = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 284172, name: "Spooky in Love")
    let obsession = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 3, name: "Obsession")
    let diaryOnly = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 9, name: "Diary only")
    // E11 is there at another time: one watch per episode, so that counts. "Diary only" is on
    // the watchlist though the diary has it completed.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: spooky, season: 1, episode: 11, watchedAt: "2025-01-01T00:00:00.000Z")],
        watchlist: [TraktListed(title: diaryOnly, listedAt: nil)])
    let mdblist = TraktWritePlan.make(library: library, workspace: try diary(), tracker: .mdblist)
    #expect(mdblist.plays.map { "\($0.title.tmdbId) s\($0.season ?? 0)e\($0.episode ?? 0)" }.sorted() == ["284172 s1e12", "9 s0e0"])
    #expect(mdblist.favouritesAdd.isEmpty && mdblist.diaryFavourites.isEmpty, "MDBList keeps no favourites")
    #expect(mdblist.watchlistAdd.map(\.tmdbId) == [3])
    #expect(mdblist.watchlistRemove.map(\.tmdbId) == [9], "Diary only is completed in the diary, so it leaves the watchlist")
    #expect(mdblist.summary.contains { $0.contains("MDBList history") })
    #expect(mdblist.requests().map(\.path) == ["/sync/watched", "/sync/ratings", "/watchlist/items/add", "/watchlist/items/remove"])
    // Once the service has a watch of each, nothing more is sent.
    var done = library
    done.plays += [TraktPlay(historyId: 2, title: spooky, season: 1, episode: 12, watchedAt: nil),
                   TraktPlay(historyId: 3, title: diaryOnly, watchedAt: nil)]
    done.ratings = [TraktRating(title: spooky, rating: 9, ratedAt: nil)]
    done.watchlist = [TraktListed(title: obsession, listedAt: nil)]
    #expect(TraktWritePlan.make(library: done, workspace: try diary(), tracker: .mdblist).isEmpty)
}

// MARK: Phase 4a: the diary built from Trakt

@Test func theTraktDiaryTakesWatchesAndListsFromTraktAndExtrasFromTheServer() throws {
    let spooky = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 284172, name: "Spooky in Love")
    let alya = TraktTitleRef(kind: .show, traktId: 7, tmdbId: 777, name: "Alya Sometimes Hides Her Feelings in Russian", year: 2024)
    let obsession = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 3, name: "Obsession")
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 10, title: spooky, season: 1, episode: 11, watchedAt: "2026-11-04T07:42:00.000Z"),
                TraktPlay(historyId: 11, title: spooky, season: 2, episode: 1, watchedAt: "2026-11-05T07:00:00.000Z"),
                TraktPlay(historyId: 12, title: alya, season: 1, episode: 1, watchedAt: "2026-10-01T00:00:00.000Z")],
        ratings: [TraktRating(title: spooky, rating: 8, ratedAt: nil)],
        watchlist: [TraktListed(title: obsession, listedAt: nil)],
        favorites: [TraktListed(title: alya, listedAt: nil)])
    let server = try diary()
    let built = TraktDiary.build(library: library, server: server)
    let byName = Dictionary(uniqueKeysWithValues: built.titles.map { ($0.name, $0) })
    // Server titles keep their ids (so notes, tags and files stay attached); Trakt decides the rest.
    let spookyTitle = try #require(byName["Spooky in Love"])
    #expect(spookyTitle.id == "spooky" && spookyTitle.score == 8 && spookyTitle.favorite == false && spookyTitle.status == "completed")
    #expect(byName["Obsession"]?.status == "planned")
    // A Trakt-only title joins with its Trakt name, as a show being watched and a favourite.
    let alyaTitle = try #require(byName["Alya Sometimes Hides Her Feelings in Russian"])
    #expect(alyaTitle.id == "tv:777" && alyaTitle.status == "watching" && alyaTitle.favorite && alyaTitle.year == 2024)
    // Watches come from Trakt only: the server's own (E12, the movie) aren't there; S2E1 gets an episode.
    #expect(built.events.allSatisfy { $0.origin == "trakt" })
    #expect(built.events.count == 3)
    let s2e1 = try #require(built.episodes.first { $0.titleId == "spooky" && $0.season == 2 && $0.number == 1 })
    #expect(built.events.contains { $0.episodeId == s2e1.id })
    #expect(built.events.contains { $0.episodeId == "e11" }, "A known episode keeps the server's id")
    #expect(built.locations == server.locations)
    // Titles Trakt doesn't know stay as the server has them.
    #expect(byName["Diary only"]?.status == "completed")
    // MDBList keeps no favourites: the server's favourite stands.
    let mdblist = TraktDiary.build(library: library, server: server, tracker: .mdblist)
    #expect(mdblist.titles.first { $0.id == "spooky" }?.favorite == true)
}


// MARK: MDBList per-list reads

@Test func mdblistRereadsOnlyTheListsThatMoved() throws {
    let before = try TrackerDecode.flatActivities(from: data(#"{"watched_at":"2026-11-01T00:00:00Z","rated_at":"2026-10-01T00:00:00Z","watchlisted_at":"2026-10-01T00:00:00Z"}"#))
    let rated = try TrackerDecode.flatActivities(from: data(#"{"watched_at":"2026-11-01T00:00:00Z","rated_at":"2026-11-05T00:00:00Z","watchlisted_at":"2026-10-01T00:00:00Z"}"#))
    #expect(TrackerDecode.mdblistListsToRead(previous: before, now: rated) == [.ratings])
    let listed = try TrackerDecode.flatActivities(from: data(#"{"watched_at":"2026-11-02T00:00:00Z","rated_at":"2026-10-01T00:00:00Z","watchlisted_at":"2026-11-05T00:00:00Z"}"#))
    #expect(TrackerDecode.mdblistListsToRead(previous: before, now: listed) == [.history, .watchlist])
    let unknown = try TrackerDecode.flatActivities(from: data(#"{"watched_at":"2026-11-01T00:00:00Z","rated_at":"2026-10-01T00:00:00Z","watchlisted_at":"2026-10-01T00:00:00Z","lists_at":"2026-11-05T00:00:00Z"}"#))
    #expect(TrackerDecode.mdblistListsToRead(previous: before, now: unknown) == nil, "Something new moved: read everything")
    #expect(TrackerDecode.mdblistListsToRead(previous: nil, now: before) == nil)
}

/// MDBList's journal (its published schema): a watched episode added, a movie unwatched, a rating
/// changed, season rows skipped, the cursor and server time kept; an expired window asks for a full read.
@Test func mdblistJournalAppliesTheLatestStatePerItem() throws {
    let show = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 1396, name: "Breaking Bad")
    let movie = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 155, name: "The Dark Knight")
    var library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: movie, watchedAt: "2026-09-01T00:00:00Z")],
                               ratings: [TraktRating(title: movie, rating: 7, ratedAt: nil)])
    let page = Data(#"""
    {"server_time":"2026-09-30T10:00:00Z","pagination":{"has_more":true,"next_cursor":"c2"},"journal":[
     {"category":"watched","item_type":"episode","ids":{"tmdb":1396},"status":"added","action_at":"2026-09-29T21:00:00Z","value_at":"2026-09-29T20:00:00Z","season":1,"episode":2},
     {"category":"watched","item_type":"season","ids":{"tmdb":1396},"status":"added","action_at":"2026-09-29T21:00:00Z","season":1},
     {"category":"watched","item_type":"movie","ids":{"tmdb":155},"status":"removed","action_at":"2026-09-29T22:00:00Z"},
     {"category":"rated","item_type":"movie","ids":{"tmdb":155},"status":"added","action_at":"2026-09-29T22:00:00Z","rating":9,"rating_precise":8.5}]}
    """#.utf8)
    let result = try MDBListJournal.apply(page, to: &library)
    #expect(result.applied == 3 && result.nextCursor == "c2" && result.serverTime == "2026-09-30T10:00:00Z" && !result.needsFullRead)
    #expect(library.plays.count == 1 && library.plays[0].title.tmdbId == show.tmdbId && library.plays[0].episode == 2)
    #expect(library.ratings.map(\.rating) == [9])
    // The same rows again change nothing (each row is that item's current state).
    _ = try MDBListJournal.apply(page, to: &library)
    #expect(library.plays.count == 1 && library.ratings.count == 1)
    let expired = try MDBListJournal.apply(Data(#"{"requires_full_sync":true,"reason":"sync_window_expired"}"#.utf8), to: &library)
    #expect(expired.needsFullRead)
}

/// A title only on Trakt takes its poster, seasons and category from the phone's TMDB catalog
/// (keeping Trakt's word on its status), so it doesn't need a server record to look right.
@Test func traktOnlyTitlesUseThePhonesCatalog() throws {
    let details = try JSONDecoder().decode(CatalogDetails.self, from: data(#"""
    {"id":209867,"mediaType":"tv","name":"Frieren: Beyond Journey's End","year":2023,"overview":"An elf mage.","posterPath":"/frieren.jpg",
     "backdropPath":"/back.jpg","genres":["Animation","Drama"],"runtimeMinutes":24,"communityScore":8.8,"suggestedCategory":"anime",
     "seasons":[{"number":1,"name":"Season 1","expectedEpisodes":28}]}
    """#))
    let catalog = TraktDiary.catalogTitle(details)
    #expect(catalog.id == "tv:209867" && catalog.category == "anime" && catalog.poster == "https://image.tmdb.org/t/p/w500/frieren.jpg")
    #expect(catalog.seasons?.first?.expectedEpisodes == 28 && catalog.backdrop == "https://image.tmdb.org/t/p/w780/back.jpg")
    let show = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 209867, name: "Frieren")
    let library = TraktLibrary(plays: [TraktPlay(historyId: 9, title: show, season: 1, episode: 1, watchedAt: "2026-11-01T20:00:00Z")])
    let diary = TraktDiary.build(library: library, server: Workspace(), catalog: [catalog.id: catalog])
    let title = try #require(diary.titles.first)
    #expect(title.id == "tv:209867" && title.category == "anime" && title.poster != nil && title.status == "watching")
    #expect(diary.events.count == 1 && diary.episodes.first?.titleId == "tv:209867")
}

/// The phone's TMDB episode lists fill in a show: every episode with its air date; watched ones
/// show their name and still, unwatched ones stay hidden; a marked (skipped) episode keeps its mark.
@Test func catalogEpisodesFillShowsWithoutTheServersCopy() throws {
    let show = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 209867, name: "Frieren")
    let library = TraktLibrary(plays: [TraktPlay(historyId: 9, title: show, season: 1, episode: 1, watchedAt: "2026-11-01T20:00:00Z")])
    var built = TraktDiary.build(library: library, server: Workspace())
    let facts = (1...3).map { CatalogEpisodeFact(season: 1, number: $0, name: "Episode \($0)", overview: "Summary \($0)", airedOn: "2023-10-0\($0)",
                                                  stillPath: "/still\($0).jpg", communityScore: 8.5) }
    built.episodes[0].skipped = true
    let diary = TraktDiary.addingCatalogEpisodes(built, catalog: ["tv:209867": facts])
    #expect(diary.episodes.count == 3)
    let first = try #require(diary.episodes.first { $0.number == 1 })
    #expect(first.id == built.episodes[0].id && first.name == "Episode 1" && first.still != nil && first.hidden == false && first.skipped == true)
    let second = try #require(diary.episodes.first { $0.number == 2 })
    #expect(second.id == "tv:209867|s1e2" && second.name.isEmpty && second.still == nil && second.hidden == true && second.airedOn == "2023-10-02")
}

/// Trakt has no Completed: a show whose every listed episode is watched reads as Completed (so it
/// leaves Glance); one announced episode still unwatched keeps it Watching; a chosen status stays.
@Test func showsWithEveryEpisodeWatchedReadAsCompleted() throws {
    let show = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 209867, name: "Frieren")
    let plays = (1...2).map { TraktPlay(historyId: Int64($0), title: show, season: 1, episode: $0, watchedAt: "2026-11-0\($0)T20:00:00Z") }
    let built = TraktDiary.build(library: TraktLibrary(plays: plays), server: Workspace())
    func facts(_ count: Int) -> [CatalogEpisodeFact] {
        (1...count).map { CatalogEpisodeFact(season: 1, number: $0, name: "", overview: "", airedOn: nil, stillPath: nil, communityScore: nil) }
            + [CatalogEpisodeFact(season: 0, number: 1, name: "Special", overview: "", airedOn: nil, stillPath: nil, communityScore: nil)]
    }
    #expect(TraktDiary.addingCatalogEpisodes(built, catalog: ["tv:209867": facts(2)]).titles.first?.status == "completed", "specials don't count")
    #expect(TraktDiary.addingCatalogEpisodes(built, catalog: ["tv:209867": facts(3)]).titles.first?.status == "watching", "an episode still to watch")
    var paused = built
    paused.titles[0].status = "paused"
    #expect(TraktDiary.addingCatalogEpisodes(paused, catalog: ["tv:209867": facts(2)]).titles.first?.status == "paused")
}

/// Trakt's notes show on their titles; a longer note the server keeps in full stays in full.
@Test func traktNotesShowInTheTraktDiary() {
    let movie = TraktTitleRef(kind: .movie, traktId: 1, tmdbId: 603, name: "The Matrix")
    let show = TraktTitleRef(kind: .show, traktId: 2, tmdbId: 1399, name: "Show")
    let long = String(repeating: "a", count: 600)
    var server = MediaTitle(id: "m1", name: "The Matrix", category: "movie", year: 1999, overview: "", poster: nil, backdrop: nil, communityScore: nil,
                            tmdbId: 603, genres: [], tags: [], runtimeMinutes: nil, status: "completed", favorite: false, queued: false, score: nil,
                            notes: long, deletedAt: nil, version: 1, seasons: nil, createdAt: nil)
    let library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: movie, watchedAt: "2026-01-01T00:00:00Z")],
                               watchlist: [TraktListed(title: show, listedAt: nil)],
                               notes: [TraktNote(id: 5, title: movie, text: String(long.prefix(500)), updatedAt: nil),
                                       TraktNote(id: 6, title: show, text: "Start with season 2", updatedAt: nil)])
    var diary = TraktDiary.build(library: library, server: Workspace(titles: [server]))
    #expect(diary.titles.first { $0.id == "m1" }?.notes == long, "the server's full note wins over Trakt's first 500 characters")
    #expect(diary.titles.first { $0.id == "tv:1399" }?.notes == "Start with season 2")
    server.notes = "Old note"
    diary = TraktDiary.build(library: library, server: Workspace(titles: [server]))
    #expect(diary.titles.first { $0.id == "m1" }?.notes == String(long.prefix(500)), "a different note on Trakt is the newer word")
}
