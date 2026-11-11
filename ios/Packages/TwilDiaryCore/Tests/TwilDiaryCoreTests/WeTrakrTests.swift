import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

private func data(_ text: String) -> Data { Data(text.utf8) }

/// WeTrakr's compact lists (from its docs' examples): every play with its own play_id, titles by
/// TMDB id and WeTrakr id, ratings rounded to whole numbers; unreadable rows are counted.
@Test func weTrakrCompactListsReadIntoTheSharedLibrary() throws {
    var skipped = 0
    let plays = try WeTrakrDecode.plays(from: data(#"""
    [{"type":"episode","id":5092071,"ids":{"tmdb":5119022},"show_id":1333953,"show_ids":{"tmdb":245318},"season_id":426081,"season_number":1,"number":1,"play_id":"6aa9d0450aa463e732ebd373","watched_at":"2026-09-15T21:09:53.772Z"},
     {"type":"movie","id":126,"ids":{"tmdb":155,"imdb":"tt0468569"},"play_id":"p2","watched_at":"2026-09-10T21:14:00.000Z","watched_at_unknown":true},
     {"type":"movie","id":127,"ids":{"tmdb":156}}]
    """#), skipped: &skipped)
    #expect(plays.count == 2 && skipped == 1)
    #expect(plays[0].title.tmdbId == 245318 && plays[0].title.weTrakrId == 1333953 && plays[0].season == 1 && plays[0].episode == 1)
    #expect(plays[0].remoteId == "6aa9d0450aa463e732ebd373" && plays[0].watchedAt == "2026-09-15T21:09:53.772Z")
    #expect(plays[1].title.kind == .movie && plays[1].watchedAt == nil, "an unknown date stays unknown")
    let planned = try WeTrakrDecode.listed(from: data(#"[{"type":"movie","id":126,"ids":{"tmdb":155},"status":"planning","tracked_at":"2026-09-20T18:02:00.000Z"},{"type":"show","id":1391953,"ids":{"tmdb":1396}}]"#), skipped: &skipped)
    #expect(planned.map(\.title.tmdbId) == [155, 1396] && planned[0].listedAt == "2026-09-20T18:02:00.000Z")
    let ratings = try WeTrakrDecode.ratings(from: data(#"[{"type":"movie","id":126,"ids":{"tmdb":155},"rating":8.6,"rated_at":"2026-09-12T20:41:00.000Z"},{"type":"episode","id":1,"ids":{"tmdb":2},"rating":9}]"#), skipped: &skipped)
    #expect(ratings.count == 1 && ratings[0].rating == 9)
    let activities = try WeTrakrDecode.activities(from: data(#"{"all":"2026-09-22T10:09:59Z","journal_visible_until":"2026-09-22T10:09:54Z","movies":{"all":"x","last_tracking_watched_at":"2026-09-22T01:18:05Z"}}"#))
    #expect(activities.stamps["movies.last_tracking_watched_at"] == "2026-09-22T01:18:05Z" && activities.stamps["journal_visible_until"] != nil)
    var moved = activities.stamps; moved["movies.last_tracking_planning_at"] = "new"
    #expect(WeTrakrDecode.listsToRead(previous: activities, now: TraktActivities(all: "later", stamps: moved)) == [.watchlist])
    #expect(WeTrakrDecode.listsToRead(previous: activities, now: activities) == [])
    #expect(WeTrakrDecode.listsToRead(previous: nil, now: activities) == nil)
}

/// The journal, oldest first: plays added and removed by play_id, list moves, ratings; an entry
/// read twice applies once; an episode of a show this copy never saw asks for a full read.
@Test func weTrakrJournalUpdatesTheCopyWithoutRereadingLists() throws {
    let show = TraktTitleRef(kind: .show, traktId: nil, tmdbId: 1396, name: "", weTrakrId: 1396000)
    var library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: show, season: 1, episode: 1, watchedAt: "2026-09-01T20:00:00Z", remoteId: "old")],
                               watchlist: [TraktListed(title: TraktTitleRef(kind: .movie, traktId: nil, tmdbId: 155, name: "", weTrakrId: 126), listedAt: nil)])
    var seen = Set<String>()
    let page = data(#"""
    {"visible_until":"2026-09-26T09:10:00.000Z","journal":[
     {"entry_id":"a","category":"planning","status":"removed","action_at":"2026-09-26T08:14:02.311Z","type":"movie","id":126,"ids":{"tmdb":155}},
     {"entry_id":"b","category":"watched","status":"added","action_at":"2026-09-26T08:14:02.311Z","type":"movie","id":126,"ids":{"tmdb":155},"play_id":"p1","watched_at":"2026-09-25T21:10:00.000Z"},
     {"entry_id":"c","category":"watched","status":"added","action_at":"2026-09-26T08:20:00.000Z","type":"episode","id":62086,"ids":{"tmdb":62086},"media_id":1396000,"season_number":1,"number":2,"play_id":"p2","watched_at":"2026-09-26T08:00:00.000Z"},
     {"entry_id":"d","category":"watched","status":"removed","action_at":"2026-09-26T09:02:40.090Z","type":"episode","id":62085,"media_id":1396000,"season_number":1,"number":1,"play_id":"old"},
     {"entry_id":"e","category":"ratings","status":"added","action_at":"2026-09-26T09:03:00.000Z","type":"show","id":1396000,"ids":{"tmdb":1396},"rating":9.4},
     {"entry_id":"f","category":"watching","status":"added","action_at":"2026-09-26T09:04:00.000Z","type":"show","id":1396000,"ids":{"tmdb":1396}}]}
    """#)
    let result = try WeTrakrDecode.applyJournal(page, to: &library, seen: &seen)
    #expect(result.applied == 5 && !result.needsFullRead && result.mark == "2026-09-26T09:04:00.000Z")
    #expect(library.watchlist.isEmpty && library.ratings.first?.rating == 9)
    #expect(Set(library.plays.compactMap(\.remoteId)) == ["p1", "p2"])
    #expect(library.plays.first { $0.remoteId == "p2" }?.title.tmdbId == 1396, "the episode joins its show by WeTrakr id")
    // The same page again (an overlapping re-read) changes nothing.
    let again = try WeTrakrDecode.applyJournal(page, to: &library, seen: &seen)
    #expect(again.applied == 0 && library.plays.count == 2)
    // An episode of an unknown show can't be placed.
    let unknown = try WeTrakrDecode.applyJournal(data(#"{"journal":[{"entry_id":"g","category":"watched","status":"added","action_at":"2026-09-27T00:00:00Z","type":"episode","media_id":9,"season_number":1,"number":1,"play_id":"p3"}]}"#), to: &library, seen: &seen)
    #expect(unknown.needsFullRead)
    // Nothing new: the next mark is how far the journal could be read.
    let empty = try WeTrakrDecode.applyJournal(data(#"{"visible_until":"2026-09-28T00:00:00Z","journal":[]}"#), to: &library, seen: &seen)
    #expect(empty.mark == "2026-09-28T00:00:00Z")
}

/// Edits go to WeTrakr in its own shapes: watches with status "watched" and tracked_at (rewatches
/// allowed), Planned as its planning list, favourites; its notFound/errored mean "not done".
@Test func weTrakrEditsUseItsTrackingWrites() throws {
    let base = try SampleWorkspace.mapped()
    let movie = try #require(base.titles.first { !$0.isSeries && $0.tmdbId != nil })
    let watch = SyncOutboxEntry(createdAt: "2026-09-10T21:14:00Z", mutation: .markWatch(operationId: "o", titleId: movie.id, episodeId: nil,
        watchedAt: "2026-09-10T21:14:00Z", recordedAt: "2026-09-10T21:14:00Z", rewatch: false), pendingProviders: [.wetrakr])
    let plan = ProviderDeliveryPlanner.plan(watch, provider: .wetrakr, in: base)
    #expect(plan.blocked.isEmpty && plan.deliveries.first?.path == "/sync/tracking")
    let item = try #require((plan.deliveries.first?.body["movies"] as? [[String: Any]])?.first)
    #expect(item["status"] as? String == "watched" && item["tracked_at"] as? String == "2026-09-10T21:14:00Z" && item["allow_rewatch"] as? Bool == true)
    let planned = SyncOutboxEntry(createdAt: "x", mutation: .patchTitle(titleId: movie.id, expectedVersion: 1, status: "planned", score: nil, clearScore: false,
        favorite: true, queued: nil, notes: nil), pendingProviders: [.wetrakr])
    let edits = ProviderDeliveryPlanner.plan(planned, provider: .wetrakr, in: base).deliveries
    #expect(edits.map(\.path) == ["/sync/tracking", "/sync/favorites"])
    #expect(((edits[0].body["movies"] as? [[String: Any]])?.first?["status"] as? String) == "planning")
    #expect(ProviderDeliveryPlanner.confirms(data(#"{"added":{"total":1,"movies":1},"notFound":{"movies":[]},"errored":{}}"#)))
    #expect(!ProviderDeliveryPlanner.confirms(data(#"{"added":{"total":0},"notFound":{"movies":[{"ids":{"tmdb":1}}]}}"#)))
    #expect(!ProviderDeliveryPlanner.confirms(data(#"{"added":{"total":0},"errored":{"movies":[{"error":"Already watched!"}]}}"#)))
    let headers = WeTrakrWrite.headers(clientId: "app", accessToken: "tok")
    #expect(headers["wetrakr-api-key"] == "app" && headers["wetrakr-api-version"] == "1" && headers["Authorization"] == "Bearer tok")
    // Sign-in: WeTrakr's page with PKCE, back to the app.
    let start = try #require(ProviderWebSignIn.start(provider: .wetrakr, clientId: "app"))
    #expect(start.url.host == "api.wetrakr.com" && start.url.path == "/oauth/authorize" && start.url.absoluteString.contains("redirect_uri=https://twildiary-auth.amit29533.workers.dev/wetrakr"))
    let exchange = try #require(JSONSerialization.jsonObject(with: WeTrakrWrite.codeBody(code: "c", clientId: "app", verifier: start.verifier, redirect: ProviderWebSignIn.redirect(for: .wetrakr))) as? [String: String])
    #expect(exchange["client_id"] == "app" && exchange["code_verifier"] == start.verifier && exchange["client_secret"] == nil)
    // Saved settings from before WeTrakr came back still load.
    let old = data(#"{"trakt":{"provider":"trakt","enabled":false,"loggingMethod":"server_and_direct"},"simkl":{"provider":"simkl","enabled":false,"loggingMethod":"server_and_direct"},"mdblist":{"provider":"mdblist","enabled":false,"loggingMethod":"server_and_direct"}}"#)
    #expect(try JSONDecoder().decode(ProviderConnectionSettings.self, from: old).wetrakr.provider == .wetrakr)
    #expect(MainTracker.wetrakr.capabilities.keepsRewatches && MainTracker.wetrakr.capabilities.holdsFavourites)
}
