import Foundation
import Testing
@testable import TwilDiaryCore

private let frieren = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 209867, name: "Frieren")
private let matrix = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 603, name: "The Matrix")
private let dune = TraktTitleRef(kind: .movie, traktId: 3, tmdbId: 438631, name: "Dune")

/// Infuse scrobbles an episode to Trakt: the next read passes that watch on, once.
@Test func aWatchFromAnotherAppIsPassedOn() {
    let old = TraktLibrary(plays: [TraktPlay(historyId: 1, title: frieren, season: 1, episode: 1, watchedAt: "2026-11-18T20:00:00.000Z")], fetchedAt: "2026-11-18T21:00:00Z")
    var new = old
    new.plays.append(TraktPlay(historyId: 2, title: frieren, season: 1, episode: 2, watchedAt: "2026-11-19T20:05:13.000Z"))
    let found = OutsideChanges.find(old: old, new: new)
    #expect(found.plays.count == 1)
    #expect(found.plays.first?.key == "tv:209867" && found.plays.first?.episode == 2 && found.plays.first?.rewatch == false)
    #expect(OutsideChanges.find(old: new, new: new).isEmpty, "read again: nothing new")
}

/// Your own TwilDiary edit is already in the copy (sent everywhere when you made it): the read
/// that brings it back from Trakt, with Trakt's own id and seconds, passes nothing on.
@Test func yourOwnEditIsNotPassedOnTwice() {
    let old = TraktLibrary(plays: [TraktPlay(historyId: -77, title: matrix, watchedAt: "2026-11-19T18:30:00Z")], fetchedAt: "2026-11-19T18:00:00Z")
    let new = TraktLibrary(plays: [TraktPlay(historyId: 98765, title: matrix, watchedAt: "2026-11-19T18:30:41.000Z")], fetchedAt: "2026-11-19T18:31:00Z")
    #expect(OutsideChanges.find(old: old, new: new).isEmpty)
}

@Test func aRewatchIsMarkedAsOne() {
    let old = TraktLibrary(plays: [TraktPlay(historyId: 1, title: matrix, watchedAt: "2025-01-01T20:00:00.000Z")], fetchedAt: "2026-11-18T21:00:00Z")
    var new = old
    new.plays.append(TraktPlay(historyId: 2, title: matrix, watchedAt: "2026-11-19T21:00:00.000Z"))
    #expect(OutsideChanges.find(old: old, new: new).plays.first?.rewatch == true)
}

@Test func ratingsPlannedAndDroppedMadeElsewhereArePassedOnNotRemovals() {
    let old = TraktLibrary(ratings: [TraktRating(title: matrix, rating: 8, ratedAt: nil)], watchlist: [TraktListed(title: dune, listedAt: nil)], fetchedAt: "2026-11-18T21:00:00Z")
    let new = TraktLibrary(ratings: [TraktRating(title: matrix, rating: 9, ratedAt: nil), TraktRating(title: frieren, rating: 10, ratedAt: nil)],
                           watchlist: [], dropped: [TraktListed(title: frieren, listedAt: nil)], fetchedAt: "2026-11-19T21:00:00Z")
    let found = OutsideChanges.find(old: old, new: new)
    #expect(found.ratings.map { "\($0.title.key)=\($0.rating)" }.sorted() == ["movie:603=9", "tv:209867=10"])
    #expect(found.dropped.map(\.key) == ["tv:209867"])
    #expect(found.planned.isEmpty, "Dune off the watchlist isn't passed on (only additions are)")
}

/// The first read (or a service just connected) has nothing to compare with: nothing is pushed.
@Test func theFirstReadPassesNothingOn() {
    let new = TraktLibrary(plays: [TraktPlay(historyId: 1, title: matrix, watchedAt: "2026-11-19T21:00:00.000Z")], fetchedAt: "2026-11-19T21:00:00Z")
    #expect(OutsideChanges.find(old: nil, new: new).isEmpty)
    #expect(OutsideChanges.find(old: TraktLibrary(), new: new).isEmpty)
}

/// A whole history imported on the website at once is left for a match you start yourself.
@Test func aBigImportIsLeftForAMatch() {
    let old = TraktLibrary(fetchedAt: "2026-11-18T21:00:00Z")
    let plays = (1...40).map { TraktPlay(historyId: Int64($0), title: frieren, season: 1, episode: $0, watchedAt: "2026-11-19T10:\(String(format: "%02d", $0 % 60)):00.000Z") }
    let found = OutsideChanges.find(old: old, new: TraktLibrary(plays: plays, fetchedAt: "2026-11-19T21:00:00Z"), limit: 30)
    #expect(found.tooMany && found.isEmpty)
}
