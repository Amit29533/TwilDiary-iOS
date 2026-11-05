import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func providerDeliveryDoesNotAcknowledgeMissingMappingsOrUnknownReceipts() throws {
    let queue = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: .patchTitle(titleId: "missing", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil), pendingProviders: [.trakt])
    for provider in [SyncProviderKind.trakt, .simkl, .mdblist] {
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

/// Phase 5: MDBList's published contract (Trakt-style "ids") and Simkl's lists.
@Test func mdblistAndSimklGetTheirOwnPathsForWatchesRatingsAndStatus() throws {
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
    let completed = SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .patchTitle(titleId: movie.id, expectedVersion: 1, status: "completed",
        score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil), pendingProviders: [.simkl])
    let moved = ProviderDeliveryPlanner.plan(completed, provider: .simkl, in: base)
    #expect(moved.blocked.isEmpty && moved.deliveries.map(\.path) == ["/sync/add-to-list"])
    #expect((moved.deliveries[0].body["movies"] as? [[String: Any]])?.first?["to"] as? String == "completed")
    // Favourites go to Trakt only; a status MDBList takes from the watches isn't queued for it.
    let favourite = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: nil, score: nil, clearScore: false, favorite: true, queued: nil, notes: nil)
    #expect(ProviderDeliveryPlanner.carries(favourite, provider: .trakt, isSeries: false))
    #expect(!ProviderDeliveryPlanner.carries(favourite, provider: .simkl, isSeries: false) && !ProviderDeliveryPlanner.carries(favourite, provider: .mdblist, isSeries: false))
    let traktFavourite = ProviderDeliveryPlanner.plan(SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: favourite, pendingProviders: [.trakt]), provider: .trakt, in: base)
    #expect(traktFavourite.blocked.isEmpty && traktFavourite.deliveries.map(\.path) == ["/sync/favorites"])
    let done = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: "completed", score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil)
    #expect(!ProviderDeliveryPlanner.carries(done, provider: .mdblist, isSeries: false) && ProviderDeliveryPlanner.carries(done, provider: .simkl, isSeries: false))
    let dropped = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: "dropped", score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil)
    #expect(ProviderDeliveryPlanner.carries(dropped, provider: .trakt, isSeries: true) && !ProviderDeliveryPlanner.carries(dropped, provider: .trakt, isSeries: false))
}

@Test func providerDeliveryProgressSurvivesEncodingAndCannotBeCoalesced() throws {
    let mutation = OptimisticMutation.patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: true, notes: nil)
    let entry = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: mutation, pendingProviders: [.simkl])
    var queue = SyncOutboxQueue(entries: [entry])
    queue.recordDelivery(entryID: entry.id, key: "simkl:rating", confirmed: true)
    queue.recordDelivery(entryID: entry.id, key: "simkl:history", confirmed: false)
    queue = try JSONDecoder().decode(SyncOutboxQueue.self, from: JSONEncoder().encode(queue))
    #expect(queue.entries[0].confirmedActions == ["simkl:rating"])
    #expect(queue.entries[0].uncertainActions == ["simkl:history"])
    queue.enqueue(SyncOutboxEntry(createdAt: entry.createdAt, mutation: mutation, pendingProviders: [.simkl]))
    #expect(queue.count == 2)
    queue.recordDelivery(entryID: entry.id, key: "simkl:history", confirmed: false, rejected: true)
    #expect(queue.entries[0].uncertainActions?.isEmpty == true)
}

@Test func remoteUnknownWatchDatesRemainUnknownAndNewSimklAccountsCanHaveNoActivity() throws {
    let activities = try SimklSyncEngine.decodeActivities(from: Data(#"{"all":null}"#.utf8))
    #expect(activities.all == nil)
    #expect(throws: DecodingError.self) { try SimklSyncEngine.decodeActivities(from: Data(#"{}"#.utf8)) }
    let snapshot = try SimklSyncEngine.decodeAllItems(from: Data(#"{"movies":[{"movie":{"ids":{"tmdb":1}},"status":"completed"}],"shows":[{"show":{"ids":{"tmdb":2}},"last_watched_at":"2026-10-01T12:00:00Z","seasons":[{"number":1,"episodes":[{"number":1}]}]}]}"#.utf8))
    #expect(snapshot.plays.count == 2)
    #expect(snapshot.plays.allSatisfy { $0.watchedAt == nil })
    let base = SampleWorkspace.make()
    let movie = try #require(base.titles.first { !$0.isSeries })
    var clean = base; clean.events.removeAll { $0.titleId == movie.id }
    let plan = DirectTraktPlan(actions: [.pullWatch(titleId: movie.id, episodeId: nil, watchedAt: nil)])
    let merged = DirectTraktEngine.applyPulls(from: plan, to: clean, recordedAt: "2026-11-03T00:00:00Z")
    let event = try #require(merged.activeEvents.first { $0.titleId == movie.id })
    #expect(event.watchedAt == nil)
}
