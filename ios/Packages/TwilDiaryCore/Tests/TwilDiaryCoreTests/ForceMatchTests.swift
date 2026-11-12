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
private let frieren = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 209867, name: "Frieren", simklId: 55)
private let loveReset = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 1100, name: "Love Reset")

@Test func forceMatchFromTheDiaryTakesWeTrakrsDuplicateOffByItsPlayID() throws {
    // WeTrakr has Perfect Blue twice at the diary's time (a resend), and Love Reset the diary lacks.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 0, title: blue, watchedAt: "2026-01-01T20:00:00.000Z", remoteId: "p1"),
                TraktPlay(historyId: 0, title: blue, watchedAt: "2026-01-01T20:00:30.000Z", remoteId: "p2"),
                TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z", remoteId: "p3"),
                TraktPlay(historyId: 0, title: frieren, season: 1, episode: 2, watchedAt: "2026-02-02T20:00:00.000Z", remoteId: "p4"),
                TraktPlay(historyId: 0, title: loveReset, watchedAt: "2026-03-01T20:00:00.000Z", remoteId: "p5")],
        ratings: [TraktRating(title: frieren, rating: 9, ratedAt: nil), TraktRating(title: loveReset, rating: 9, ratedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .wetrakr, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    #expect(plan.send.isEmpty, "WeTrakr already has everything the diary has")
    #expect(plan.plays.compactMap(\.remoteId).sorted() == ["p2", "p5"], "One copy of Perfect Blue stays; Love Reset goes")
    #expect(plan.ratings.map(\.name) == ["Love Reset"])
    let requests = plan.requests()
    #expect(requests.filter { $0.method == "DELETE" }.map(\.path).sorted() == ["/sync/tracklogs/p2", "/sync/tracklogs/p5"])
    #expect(requests.contains { $0.path == "/sync/ratings/remove" })
    #expect(plan.summary.contains { $0.contains("taken off WeTrakr history") })
}

@Test func forceMatchToASimklSourceNeverTakesTheDiarysRewatchesOrUnmatchedTitlesOff() throws {
    // Trakt (the diary) has a rewatch of E1 and Love Reset; Simkl has one watch per episode, no
    // Love Reset, and a title it can't name by TMDB id that is Love Reset by IMDb id.
    var trakt = TraktLibrary(
        plays: [TraktPlay(historyId: 1, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z"),
                TraktPlay(historyId: 2, title: frieren, season: 1, episode: 1, watchedAt: "2026-05-01T20:00:00.000Z"),
                TraktPlay(historyId: 3, title: frieren, season: 1, episode: 2, watchedAt: "2026-02-02T20:00:00.000Z"),
                TraktPlay(historyId: 4, title: loveReset, watchedAt: "2026-03-01T20:00:00.000Z")])
    let simkl = TraktLibrary(plays: [TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: "2026-02-01T20:00:00.000Z"),
                                     TraktPlay(historyId: 0, title: frieren, season: 1, episode: 2, watchedAt: nil)])
    let source = TraktDiary.build(library: simkl, server: Workspace(), tracker: .simkl)
    var plan = ForceMatchPlan.make(target: trakt, tracker: .trakt, source: source, sourceHolds: MainTracker.simkl.capabilities)
    #expect(plan.plays.map(\.historyId) == [4], "The rewatch stays (Simkl can't hold one); Love Reset goes")
    #expect(plan.requests().contains { $0.path == "/sync/history/remove" && String(decoding: $0.body ?? Data(), as: UTF8.self) == #"{"ids":[4]}"# })
    // Love Reset is on Simkl without a TMDB id: it's kept.
    trakt.plays[3] = TraktPlay(historyId: 4, title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 1100, imdbId: "tt999", name: "Love Reset"), watchedAt: nil)
    let keep = ForceMatchPlan.keepTokens([TraktTitleRef(kind: .movie, traktId: nil, tmdbId: nil, imdbId: "tt999", name: "Love Reset (2023)")])
    plan = ForceMatchPlan.make(target: trakt, tracker: .trakt, source: source, sourceHolds: MainTracker.simkl.capabilities, keep: keep)
    #expect(plan.plays.isEmpty)
}

@Test func forceMatchLeavesShowsNumberedDifferentlyAndTakesSimklOnlyTitlesOffWhole() throws {
    // Simkl numbers Frieren E2 as S2E1 (its anime seasons): missing and extra episodes of one show.
    let library = TraktLibrary(
        plays: [TraktPlay(historyId: 0, title: blue, watchedAt: nil),
                TraktPlay(historyId: 0, title: frieren, season: 1, episode: 1, watchedAt: nil),
                TraktPlay(historyId: 0, title: frieren, season: 2, episode: 1, watchedAt: nil),
                TraktPlay(historyId: 0, title: loveReset, watchedAt: nil)],
        watchlist: [TraktListed(title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 5, name: "Panchayat"), listedAt: nil)])
    let plan = ForceMatchPlan.make(target: library, tracker: .simkl, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    #expect(plan.send.plays.map { "\($0.title.tmdbId) s\($0.season ?? 0)e\($0.episode ?? 0)" } == ["209867 s1e2"])
    #expect(plan.renumbered == ["Frieren"] && plan.plays.isEmpty, "Frieren's S2E1 stays: it's the E2 being sent")
    #expect(plan.titles.map(\.name).sorted() == ["Love Reset", "Panchayat"], "Titles the diary lacks go whole")
    let removal = try #require(plan.requests().first { $0.summary == "titles taken off" })
    #expect(removal.path == "/sync/history/remove")
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
    #expect(ForceMatchPlan.wipe(["movie:1100"], target: library, tracker: .simkl).requests().map(\.path) == ["/sync/history/remove", "/sync/ratings/remove"])
    #expect(ForceMatchPlan.wipe(["tv:5"], target: library, tracker: .trakt).isEmpty, "A title the target doesn't have has nothing to clear")
    // Only the titles asked for are sent again.
    let plan = ForceMatchPlan.make(target: library, tracker: .mdblist, source: try diary(), sourceHolds: MainTracker.trakt.capabilities)
    let again = plan.only(["tv:209867"])
    #expect(!again.send.plays.isEmpty && again.send.plays.allSatisfy { $0.title.tmdbId == 209867 } && again.plays.isEmpty && again.ratings.isEmpty)
}
