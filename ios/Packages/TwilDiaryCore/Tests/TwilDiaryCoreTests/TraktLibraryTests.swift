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
