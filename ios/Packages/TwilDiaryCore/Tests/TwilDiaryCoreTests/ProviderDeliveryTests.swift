import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func providerDeliveryDoesNotAcknowledgeMissingMappingsOrUnknownReceipts() throws {
    let queue = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: .patchTitle(titleId: "missing", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil), pendingProviders: [.trakt])
    for provider in [SyncProviderKind.trakt, .mdblist, .wetrakr] {
        let plan = ProviderDeliveryPlanner.plan(queue, provider: provider, in: SampleWorkspace.make())
        #expect(plan.deliveries.isEmpty)
        #expect(!plan.blocked.isEmpty)
    }
    #expect(!ProviderDeliveryPlanner.confirms(Data(#"{"ok":true}"#.utf8)))
    for receipt in [#"{"added":true}"#, #"{"added":"ok"}"#, #"{"added":{"movies":true}}"#, #"{"added":{"movies":"1"}}"#, #"{"added":{"movies":0.5}}"#, #"{"added":{"unexpected":1}}"#] {
        #expect(!ProviderDeliveryPlanner.confirms(Data(receipt.utf8)))
    }
    #expect(!ProviderDeliveryPlanner.confirms(Data(#"{"added":{"movies":1},"not_found":{"movies":[{"ids":{"tmdb":1}}]}}"#.utf8)))
    #expect(ProviderDeliveryPlanner.confirms(Data(#"{"deleted":{"movies":1},"not_found":{"movies":[]}}"#.utf8)))
}

/// Phase 5: MDBList's published contract (Trakt-style "ids").
@Test func mdblistGetsItsOwnPathsForWatchesRatingsAndStatus() throws {
    let base = try SampleWorkspace.mapped()
    let movie = try #require(base.titles.first { !$0.isSeries && $0.tmdbId != nil })
    let watch = SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .markWatch(operationId: "w", titleId: movie.id, episodeId: nil,
        watchedAt: "2026-11-05T00:00:00.000Z", recordedAt: "2026-11-05T00:00:00.000Z", rewatch: false), pendingProviders: [.mdblist])
    let watched = ProviderDeliveryPlanner.plan(watch, provider: .mdblist, in: base)
    #expect(watched.blocked.isEmpty && watched.deliveries.map(\.path) == ["/sync/watched"])
    let body = try #require((watched.deliveries[0].body["movies"] as? [[String: Any]])?.first)
    #expect((body["ids"] as? [String: Any])?["tmdb"] as? Int == movie.tmdbId && body["watched_at"] as? String == "2026-11-05T00:00:00.000Z")
    let rated = SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .patchTitle(titleId: movie.id, expectedVersion: 1, status: nil, score: 8,
        clearScore: false, favorite: nil, queued: nil, notes: nil), pendingProviders: [.mdblist])
    #expect(ProviderDeliveryPlanner.plan(rated, provider: .mdblist, in: base).deliveries.map(\.path) == ["/sync/ratings"])
    // Favourites go to Trakt only.
    let favourite = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: nil, score: nil, clearScore: false, favorite: true, queued: nil, notes: nil)
    #expect(ProviderDeliveryPlanner.carries(favourite, provider: .trakt, isSeries: false))
    #expect(!ProviderDeliveryPlanner.carries(favourite, provider: .mdblist, isSeries: false))
    let traktFavourite = ProviderDeliveryPlanner.plan(SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: favourite, pendingProviders: [.trakt]), provider: .trakt, in: base)
    #expect(traktFavourite.blocked.isEmpty && traktFavourite.deliveries.map(\.path) == ["/sync/favorites"])
    let done = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: "completed", score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil)
    // MDBList keeps no Completed, but leaving Planned takes the title off its watchlist.
    #expect(ProviderDeliveryPlanner.carries(done, provider: .mdblist, isSeries: false))
    let offList = ProviderDeliveryPlanner.plan(SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: done, pendingProviders: [.mdblist]), provider: .mdblist, in: base)
    #expect(offList.blocked.isEmpty && offList.deliveries.map(\.path) == ["/watchlist/items/remove"])
    let dropped = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: "dropped", score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil)
    #expect(ProviderDeliveryPlanner.carries(dropped, provider: .trakt, isSeries: true) && ProviderDeliveryPlanner.carries(dropped, provider: .trakt, isSeries: false))
    // A dropped movie: Trakt drops only shows, so just the watchlist removal goes.
    let droppedMovie = ProviderDeliveryPlanner.plan(SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: dropped, pendingProviders: [.trakt]), provider: .trakt, in: base)
    #expect(droppedMovie.deliveries.map(\.path) == ["/sync/watchlist/remove"])
}

/// A watch taken off a diary that lives on a service reaches the mirrors without the diary: the
/// removal carries the title, episode and time itself.
@Test func aRemovalFromAServiceDiaryReachesTheMirrorsWithoutLookingTheWatchUp() throws {
    let watch = DetachedWatch(tmdbId: 209867, movie: false, season: 1, number: 2, watchedAt: "2026-02-02T20:00:00.000Z", othersRemain: false)
    #expect(DetachedWatch(eventID: watch.eventID) == watch && DetachedWatch(eventID: "trakt-777") == nil)
    func plan(_ value: DetachedWatch, _ provider: SyncProviderKind) -> ProviderDeliveryPlan {
        let entry = SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .revokeWatch(eventId: value.eventID, titleId: "tv:209867", expectedVersion: 1, revokedAt: "2026-11-05T00:00:00.000Z"), pendingProviders: [provider])
        // An empty diary: the title and its episode are already gone from it.
        return ProviderDeliveryPlanner.plan(entry, provider: provider, in: Workspace())
    }
    let trakt = plan(watch, .trakt)
    #expect(trakt.blocked.isEmpty && trakt.deliveries.map(\.key) == ["history-remove-timed"])
    #expect(String(describing: trakt.deliveries[0].body).contains("2026-02-02T20:00:00.000Z"))
    #expect(plan(watch, .mdblist).deliveries.map(\.path) == ["/sync/watched/remove"])
    let wetrakr = plan(watch, .wetrakr)
    #expect(wetrakr.deliveries.map(\.path) == ["/sync/tracking/remove"] && !String(describing: wetrakr.deliveries[0].body).contains("allow_rewatch"))
    // Another play of the episode is still in the diary: MDBList's one watch stays; Trakt loses just that play.
    let rewatch = DetachedWatch(tmdbId: 209867, movie: false, season: 1, number: 2, watchedAt: "2026-02-02T20:00:00.000Z", othersRemain: true)
    #expect(plan(rewatch, .mdblist).deliveries.isEmpty && plan(rewatch, .mdblist).blocked.isEmpty && plan(rewatch, .trakt).deliveries.count == 1)
    // No time: Trakt can't tell which play, so it's said rather than every play taken off.
    let undated = DetachedWatch(tmdbId: 10494, movie: true, season: nil, number: nil, watchedAt: nil, othersRemain: false)
    #expect(plan(undated, .trakt).deliveries.isEmpty && !plan(undated, .trakt).blocked.isEmpty && plan(undated, .mdblist).deliveries.count == 1)
}

@Test func providerDeliveryProgressSurvivesEncodingAndCannotBeCoalesced() throws {
    let mutation = OptimisticMutation.patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: true, notes: nil)
    let entry = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: mutation, pendingProviders: [.mdblist])
    var queue = SyncOutboxQueue(entries: [entry])
    queue.recordDelivery(entryID: entry.id, key: "mdblist:rating", confirmed: true)
    queue.recordDelivery(entryID: entry.id, key: "mdblist:history", confirmed: false)
    queue = try JSONDecoder().decode(SyncOutboxQueue.self, from: JSONEncoder().encode(queue))
    #expect(queue.entries[0].confirmedActions == ["mdblist:rating"])
    #expect(queue.entries[0].uncertainActions == ["mdblist:history"])
    queue.enqueue(SyncOutboxEntry(createdAt: entry.createdAt, mutation: mutation, pendingProviders: [.mdblist]))
    #expect(queue.count == 2)
    queue.recordDelivery(entryID: entry.id, key: "mdblist:history", confirmed: false, rejected: true)
    #expect(queue.entries[0].uncertainActions?.isEmpty == true)
}

@Test func remoteUnknownWatchDatesRemainUnknown() throws {
    let base = SampleWorkspace.make()
    let movie = try #require(base.titles.first { !$0.isSeries })
    var clean = base; clean.events.removeAll { $0.titleId == movie.id }
    let plan = DirectTraktPlan(actions: [.pullWatch(titleId: movie.id, episodeId: nil, watchedAt: nil)])
    let merged = DirectTraktEngine.applyPulls(from: plan, to: clean, recordedAt: "2026-11-03T00:00:00Z")
    let event = try #require(merged.activeEvents.first { $0.titleId == movie.id })
    #expect(event.watchedAt == nil)
}

/// Cinopsys's way: only a real rewatch asks WeTrakr to log another play; Queue isn't a watchlist;
/// a play from another service is removed from Trakt by finding it at its time.
@Test func rewatchQueueAndForeignPlaysFollowCinopsys() throws {
    var base = try SampleWorkspace.mapped()
    let movie = try #require(base.titles.first { !$0.isSeries && $0.tmdbId != nil })
    func watch(_ rewatch: Bool) -> SyncOutboxEntry {
        SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .markWatch(operationId: rewatch ? "r" : "f", titleId: movie.id, episodeId: nil,
            watchedAt: "2026-11-05T00:00:00.000Z", recordedAt: "2026-11-05T00:00:00.000Z", rewatch: rewatch), pendingProviders: [.wetrakr])
    }
    func allowed(_ entry: SyncOutboxEntry) -> Bool? {
        (ProviderDeliveryPlanner.plan(entry, provider: .wetrakr, in: base).deliveries.first?.body["movies"] as? [[String: Any]])?.first?["allow_rewatch"] as? Bool
    }
    #expect(allowed(watch(false)) == false)
    #expect(allowed(watch(true)) == true)
    let queued = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: nil, score: nil, clearScore: false, favorite: nil, queued: true, notes: nil)
    for provider in [SyncProviderKind.trakt, .mdblist, .wetrakr] { #expect(!ProviderDeliveryPlanner.carries(queued, provider: provider, isSeries: false)) }
    // A play read from another service (once Simkl): its id isn't Trakt's.
    base.events.append(WatchEvent(id: "trakt-777", operationId: "trakt-777", titleId: movie.id, episodeId: nil, watchedAt: "2026-11-01T10:00:00.000Z",
                                  recordedAt: "2026-11-01T10:00:00.000Z", origin: "simkl"))
    let removal = SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .revokeWatch(eventId: "trakt-777", titleId: movie.id, expectedVersion: 1, revokedAt: "2026-11-05T00:00:00.000Z"), pendingProviders: [.trakt])
    let planned = ProviderDeliveryPlanner.plan(removal, provider: .trakt, in: base)
    #expect(planned.deliveries.map(\.key) == ["history-remove-timed"])
    let rewatchOff = WeTrakrWrite.withoutRewatch(Data(#"{"movies":[{"ids":{"tmdb":1},"allow_rewatch":true}]}"#.utf8))
    #expect(String(decoding: rewatchOff, as: UTF8.self).contains("\"allow_rewatch\":false"))
}

