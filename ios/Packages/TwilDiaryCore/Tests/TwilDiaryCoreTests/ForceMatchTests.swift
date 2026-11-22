import Foundation
import Testing
@testable import TwilDiaryCore

/// The diary: Perfect Blue watched once, Frieren S1E1 and E2, Frieren rated 9.
private func diary() throws -> Workspace {
    let object: [String: Any] = [
        "titles": [
            ["id": "blue", "name": "Perfect Blue", "category": "movie", "overview": "", "tmdbId": 10494, "genres": [], "status": "completed", "favorite": false, "notes": ""],
            ["id": "frieren", "name": "Frieren", "category": "anime", "overview": "", "tmdbId": 209867, "genres": [], "status": "watching", "favorite": false, "score": 9, "notes": ""]
        ],
        "episodes": [
            ["id": "f1", "titleId": "frieren", "season": 1, "number": 1, "name": "", "overview": ""],
            ["id": "f2", "titleId": "frieren", "season": 1, "number": 2, "name": "", "overview": ""]
        ],
        "events": [
            ["id": "w1", "operationId": "o1", "titleId": "blue", "watchedAt": "2026-01-01T20:00:00Z", "recordedAt": "2026-01-01T20:00:00Z", "origin": "trakt"],
            ["id": "w2", "operationId": "o2", "titleId": "frieren", "episodeId": "f1", "watchedAt": "2026-02-01T20:00:00Z", "recordedAt": "2026-02-01T20:00:00Z", "origin": "trakt"],
            ["id": "w3", "operationId": "o3", "titleId": "frieren", "episodeId": "f2", "watchedAt": "2026-02-02T20:00:00Z", "recordedAt": "2026-02-02T20:00:00Z", "origin": "trakt"]
        ],
        "locations": []
    ]
    return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
}
private let blue = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 10494, name: "Perfect Blue")
private let frieren = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 209867, name: "Frieren")
private let loveReset = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 1100, name: "Love Reset")

@Test func forceMatchFromTheDiaryTakesWeTrakrsDuplicateOffByItsPlayID() throws {
    // WeTrakr has Perfect Blue twice at the diary's time (a resend), and Love Reset the diary lacks.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 0, title: blue, watchedAt: "2026-01-01T20:00:00.000Z", remoteId: "p1"),
                TraktPlay(historyId: 0, title: blue, watchedAt: "2026-01-01T20:00:30.000Z", remoteId: "p2"),
                TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z", remoteId: "p3"),
                TraktPlay(historyId: 0, title: frieren, season: 1, episode: 2, watchedAt: "2026-02-02T20:00:00.000Z", remoteId: "p4"),
                TraktPlay(historyId: 0, title: loveReset, watchedAt: "2026-03-01T20:00:00.000Z", remoteId: "p5"),
                TraktPlay(historyId: 0, title: blue, watchedAt: nil, remoteId: "p6")],
        ratings: [TraktRating(title: frieren, rating: 9, ratedAt: nil), TraktRating(title: loveReset, rating: 9, ratedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .wetrakr, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    #expect(plan.send.isEmpty, "WeTrakr already has everything the diary has")
    #expect(plan.plays.compactMap(\.remoteId).sorted() == ["p2", "p5", "p6"], "One copy of Perfect Blue stays; Love Reset goes")
    #expect(plan.ratings.map(\.name) == ["Love Reset"])
    let requests = plan.requests()
    // Timed plays go together, each by its time (only that play); one without a time by its play_id.
    let batch = try #require(requests.first { $0.path == "/sync/tracking/remove" })
    let body = String(decoding: batch.body ?? Data(), as: UTF8.self)
    #expect(batch.count == 2 && body.contains("2026-01-01T20:00:30.000Z") && body.contains("2026-03-01T20:00:00.000Z") && !body.contains("allow_rewatch"))
    #expect(Set(plan.keys(of: batch)) == ["movie:10494", "movie:1100"])
    #expect(requests.filter { $0.method == "DELETE" }.map(\.path) == ["/sync/tracklogs/p6"])
    #expect(requests.contains { $0.path == "/sync/ratings/remove" })
    #expect(plan.summary.contains { $0.contains("taken off WeTrakr history") })
}

@Test func forceMatchToAOneWatchSourceNeverTakesTheDiarysRewatchesOrUnmatchedTitlesOff() throws {
    // Trakt (the diary) has a rewatch of E1 and Love Reset; MDBList has one watch per episode, no
    // Love Reset, and a title it can't name by TMDB id that is Love Reset by IMDb id.
    var trakt = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z"),
                TraktPlay(historyId: 2, title: frieren, season: 1, episode: 1, watchedAt: "2026-05-01T20:00:00.000Z"),
                TraktPlay(historyId: 3, title: frieren, season: 1, episode: 2, watchedAt: "2026-02-02T20:00:00.000Z"),
                TraktPlay(historyId: 4, title: loveReset, watchedAt: "2026-03-01T20:00:00.000Z")])
    let mdblist = TraktLibrary(plays: [TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z"),
                                       TraktPlay(historyId: 0, title: frieren, season: 1, episode: 2, watchedAt: nil)])
    let source = TraktDiary.build(library: mdblist, server: Workspace(), tracker: .mdblist)
    var plan = ForceMatchPlan.make(target: trakt, tracker: .trakt, source: source, sourceHolds: MainTracker.mdblist.capabilities)
    #expect(plan.plays.map(\.historyId) == [4], "The rewatch stays (MDBList can't hold one); Love Reset goes")
    #expect(plan.requests().contains { $0.path == "/sync/history/remove" && String(decoding: $0.body ?? Data(), as: UTF8.self) == #"{"ids":[4]}"# })
    // Love Reset is on MDBList without a TMDB id: it's kept.
    trakt.plays[3] = TraktPlay(historyId: 4, title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 1100, imdbId: "tt999", name: "Love Reset"), watchedAt: nil)
    let keep = ForceMatchPlan.keepTokens([TraktTitleRef(kind: .movie, traktId: nil, tmdbId: nil, imdbId: "tt999", name: "Love Reset (2023)")])
    plan = ForceMatchPlan.make(target: trakt, tracker: .trakt, source: source, sourceHolds: MainTracker.mdblist.capabilities, keep: keep)
    #expect(plan.plays.isEmpty)
}

@Test func forceMatchLeavesShowsNumberedDifferently() throws {
    // The service numbers Frieren E2 as S2E1 (anime seasons): missing and extra episodes of one show.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 0, title: blue, watchedAt: nil),
                TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: nil),
                TraktPlay(historyId: 0, title: frieren, season: 2, episode: 1, watchedAt: nil),
                TraktPlay(historyId: 0, title: loveReset, watchedAt: nil)],
        watchlist: [TraktListed(title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 5, name: "Panchayat"), listedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .wetrakr, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    #expect(plan.renumbered == ["Frieren"], "Frieren's S2E1 stays: it's the diary's E2 under the service's number")
    #expect(!plan.plays.contains { $0.title.tmdbId == 209867 })
    #expect(!plan.send.plays.contains { $0.title.tmdbId == 209867 }, "Left as it is: E2 isn't sent either, or the show would never stop looking different")
    #expect(plan.summary.contains { $0.contains("numbered differently") })
}

@Test func aRefusedCallSplitsInHalvesAndNamesItsTitles() throws {
    // Love Reset and Perfect Blue go from WeTrakr by time (no play ids), Frieren's rating too.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 0, title: loveReset, watchedAt: "2026-03-01T20:00:00.000Z")],
        ratings: [TraktRating(title: loveReset, rating: 9, ratedAt: nil), TraktRating(title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 77, name: "Nerve"), rating: 6, ratedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .mdblist, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    let ratings = try #require(plan.requests().first { $0.path == "/sync/ratings/remove" })
    #expect(ratings.count == 2 && Set(plan.keys(of: ratings)) == ["movie:1100", "movie:77"])
    let halves = try #require(ratings.halves())
    #expect(halves.count == 2 && halves.allSatisfy { plan.keys(of: $0).count == 1 && $0.halves() == nil })
    #expect(plan.names["movie:77"] == "Nerve")
    // Leaving a refused title out keeps the rest.
    let rest = plan.without(["movie:77"])
    #expect(rest.ratings.map(\.name) == ["Love Reset"] && rest.plays.count == 1)
    // Trakt's removals by history id split and name their titles too.
    let trakt = ForceMatchPlan.make(target: TraktLibrary(plays: [TraktPlay(historyId: 5, title: loveReset, watchedAt: nil),
                                                                 TraktPlay(historyId: 6, title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 77, name: "Nerve"), watchedAt: nil)]),
                                    tracker: .trakt, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    let history = try #require(trakt.requests().first { $0.path == "/sync/history/remove" })
    #expect(Set(trakt.keys(of: history)) == ["movie:1100", "movie:77"] && history.halves()?.count == 2)
}

@Test func titlesStillDifferentAreClearedWholeWithEachServicesCalls() throws {
    let library = TraktLibrary(plays: [TraktPlay(historyId: 0, title: loveReset, watchedAt: nil), TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: nil)],
                               ratings: [TraktRating(title: loveReset, rating: 9, ratedAt: nil)])
    let wetrakr = ForceMatchPlan.wipe(["movie:1100"], target: library, tracker: .wetrakr)
    #expect(wetrakr.wipe.map(\.name) == ["Love Reset"] && wetrakr.summary.contains { $0.contains("cleared off WeTrakr") })
    let paths = wetrakr.requests().map(\.path)
    #expect(paths.first == "/sync/tracking/remove/all" && paths.contains("/sync/ratings/remove") && paths.contains("/sync/favorites/remove"))
    #expect(ForceMatchPlan.wipe(["movie:1100"], target: library, tracker: .mdblist).requests().map(\.path)
            == ["/sync/watched/remove", "/sync/ratings/remove", "/watchlist/items/remove", "/sync/dropped/remove"])
    #expect(ForceMatchPlan.wipe(["tv:5"], target: library, tracker: .trakt).isEmpty, "A title the target doesn't have has nothing to clear")
    // Only the titles asked for are sent again.
    let plan = ForceMatchPlan.make(target: library, tracker: .mdblist, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    let again = plan.only(["tv:209867"])
    #expect(!again.send.plays.isEmpty && again.send.plays.allSatisfy { $0.title.tmdbId == 209867 } && again.plays.isEmpty && again.ratings.isEmpty)
}

@Test func titlesWithoutANameNeverShareAKeepToken() throws {
    // WeTrakr and MDBList send some titles without a name: one of them without a TMDB id on the
    // source must not keep every nameless title on the target.
    let nameless = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: nil, name: "")
    #expect(ForceMatchPlan.keepTokens([nameless]).isEmpty)
    let library = TraktLibrary(plays: [TraktPlay(historyId: 7, title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 1100, name: ""), watchedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .trakt, source: try diary(), sourceHolds: MainTracker.trakt.capabilities,
                                   keep: ForceMatchPlan.keepTokens([nameless]))
    #expect(plan.plays.map(\.historyId) == [7], "The nameless title the diary lacks still goes")
}

@Test func aServiceAsTheSourceDoesNotPutRatedOnlyTitlesOnTheWatchlist() throws {
    // MDBList: Frieren watched, Love Reset only rated, Perfect Blue on the watchlist.
    let mdblist = TraktLibrary(plays: [TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z")],
                               ratings: [TraktRating(title: loveReset, rating: 8, ratedAt: nil)],
                               watchlist: [TraktListed(title: blue, listedAt: nil)])
    let source = TraktDiary.forceSource(library: mdblist, tracker: .mdblist)
    #expect(source.titles.first { $0.tmdbId == 1100 }?.status == "none")
    #expect(source.titles.first { $0.tmdbId == 10494 }?.status == "planned")
    let plan = ForceMatchPlan.make(target: TraktLibrary(), tracker: .trakt, source: source, sourceHolds: MainTracker.mdblist.capabilities)
    #expect(plan.send.watchlistAdd.map(\.name) == ["Perfect Blue"], "Only what MDBList has on its watchlist")
    #expect(plan.send.ratings.map(\.title.name) == ["Love Reset"])
}

@Test func mdblistShowAndSeasonRowsAreNotWatchesToTakeOff() throws {
    // MDBList lists Frieren as finished (a show row and a season row) beside its two episodes.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: blue, watchedAt: "2026-01-01T20:00:00Z"),
                TraktPlay(historyId: 2, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00Z"),
                TraktPlay(historyId: 3, title: frieren, season: 1, episode: 2, watchedAt: "2026-02-02T20:00:00Z"),
                TraktPlay(historyId: 4, title: frieren, watchedAt: "2026-02-02T20:00:00Z"),
                TraktPlay(historyId: 5, title: frieren, season: 1, watchedAt: "2026-02-02T20:00:00Z")])
    #expect(library.plays.filter(\.isMovieOrEpisode).map(\.historyId) == [1, 2, 3])
    let plan = ForceMatchPlan.make(target: library, tracker: .mdblist, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    #expect(plan.plays.isEmpty, "nothing counted as taken off that the call can't name")
}

@Test func aServiceKeepsTheDiarysTitlesItFilesItsOwnWay() throws {
    // Perfect Blue as a one-episode show (an OVA's way), once with the film's kind but an episode
    // number, once as "tv:10494". None of it is taken off: on the service it's the diary's own title.
    let ova = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 10494, name: "Perfect Blue")
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: blue, season: 1, episode: 1, watchedAt: "2026-01-01T20:00:00Z"),
                TraktPlay(historyId: 2, title: ova, season: 1, episode: 1, watchedAt: "2026-01-01T20:00:00Z"),
                TraktPlay(historyId: 3, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00Z"),
                TraktPlay(historyId: 4, title: frieren, season: 1, episode: 2, watchedAt: "2026-02-02T20:00:00Z")],
        ratings: [TraktRating(title: ova, rating: 8, ratedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .wetrakr, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    #expect(plan.plays.isEmpty, "no watch of the diary's titles is taken off")
    #expect(plan.ratings.isEmpty)
}
