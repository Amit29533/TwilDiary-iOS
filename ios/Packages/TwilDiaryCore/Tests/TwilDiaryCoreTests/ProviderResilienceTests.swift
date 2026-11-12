import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

/// "Too many requests" becomes a saved pause: Retry-After in seconds or as a date, MDBList's and
/// Simkl's reset (epoch or seconds) when the allowance is used up, a minute when unsaid; clamped.
@Test func cooldownsComeFromTheServicesOwnHeaders() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(ProviderCooldown.until(status: 200, headers: [:], now: now) == nil)
    #expect(ProviderCooldown.until(status: 429, headers: ["Retry-After": "30"], now: now) == now.addingTimeInterval(30))
    #expect(ProviderCooldown.until(status: 429, headers: ["retry-after": "Fri, 15 Jan 2027 09:00:00 GMT"], now: now) == now.addingTimeInterval(3_600))
    #expect(ProviderCooldown.until(status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000600"], now: now) == now.addingTimeInterval(600))
    #expect(ProviderCooldown.until(status: 200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "90"], now: now) == now.addingTimeInterval(90))
    #expect(ProviderCooldown.until(status: 200, headers: ["X-RateLimit-Remaining": "12", "X-RateLimit-Reset": "90"], now: now) == nil)
    #expect(ProviderCooldown.until(status: 429, headers: [:], now: now) == now.addingTimeInterval(60))
    #expect(ProviderCooldown.until(status: 429, headers: ["Retry-After": "0"], now: now) == now.addingTimeInterval(5))
}

/// A watch whose answer was lost counts as delivered only when the service shows that play
/// (same title and episode, within two minutes); otherwise it's safe to send again.
@Test func aLostWatchIsCheckedAgainstTheServicesCopyBeforeResending() throws {
    let base = try SampleWorkspace.mapped()
    let movie = try #require(base.titles.first { !$0.isSeries && $0.tmdbId != nil })
    let watch = OptimisticMutation.markWatch(operationId: "o", titleId: movie.id, episodeId: nil, watchedAt: "2026-11-05T20:00:00.000Z",
                                             recordedAt: "2026-11-05T20:00:00.000Z", rewatch: false)
    let ref = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: movie.tmdbId, name: movie.name)
    #expect(LostWriteCheck.delivered(watch, in: base, library: TraktLibrary(plays: [TraktPlay(historyId: 1, title: ref, watchedAt: "2026-11-05T20:01:00Z")])))
    #expect(!LostWriteCheck.delivered(watch, in: base, library: TraktLibrary(plays: [TraktPlay(historyId: 1, title: ref, watchedAt: "2026-11-01T20:00:00Z")])))
    #expect(!LostWriteCheck.delivered(watch, in: base, library: TraktLibrary()))
    let rating = OptimisticMutation.patchTitle(titleId: movie.id, expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil)
    #expect(!LostWriteCheck.delivered(rating, in: base, library: TraktLibrary()))
}

/// Automatic backups: due when there's never been one, then every 1, 7 or 30 days (an hour early
/// is fine); off never runs.
@Test func automaticBackupsFollowTheirSchedule() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(BackupSchedule.weekly.isDue(last: nil, now: now))
    #expect(!BackupSchedule.weekly.isDue(last: now.addingTimeInterval(-6 * 86_400), now: now))
    #expect(BackupSchedule.weekly.isDue(last: now.addingTimeInterval(-7 * 86_400 + 1_800), now: now))
    #expect(BackupSchedule.daily.isDue(last: now.addingTimeInterval(-86_400), now: now))
    #expect(!BackupSchedule.monthly.isDue(last: now.addingTimeInterval(-20 * 86_400), now: now))
    #expect(!BackupSchedule.off.isDue(last: nil, now: now) && BackupSchedule.off.next(after: nil, now: now) == nil)
}

/// Removing a watch reaches each service as that one play: Trakt by its history id (never "every
/// play of the title"), WeTrakr by its time, Simkl and MDBList their watch; undoing it sends it again.
@Test func removingAWatchSendsOnlyThatPlay() throws {
    var base = try SampleWorkspace.mapped()
    let movie = try #require(base.titles.first { !$0.isSeries && $0.tmdbId != nil })
    base.events.append(WatchEvent(id: "trakt-42", operationId: "x", titleId: movie.id, episodeId: nil, watchedAt: "2026-11-05T20:00:00.000Z", recordedAt: "2026-11-05T20:00:00.000Z"))
    base.events.append(WatchEvent(id: "local-7", operationId: "y", titleId: movie.id, episodeId: nil, watchedAt: "2026-11-06T20:00:00.000Z", recordedAt: "2026-11-06T20:00:00.000Z"))
    func plan(_ mutation: OptimisticMutation, _ provider: SyncProviderKind) -> ProviderDeliveryPlan {
        ProviderDeliveryPlanner.plan(SyncOutboxEntry(createdAt: "2026-11-07T00:00:00Z", mutation: mutation, pendingProviders: [provider]), provider: provider, in: base)
    }
    let revokeTrakt = OptimisticMutation.revokeWatch(eventId: "trakt-42", titleId: movie.id, expectedVersion: 1, revokedAt: "2026-11-07T00:00:00Z")
    let trakt = plan(revokeTrakt, .trakt)
    #expect(trakt.deliveries.map(\.path) == ["/sync/history/remove"] && (trakt.deliveries[0].body["ids"] as? [Int64]) == [42])
    let revokeLocal = OptimisticMutation.revokeWatch(eventId: "local-7", titleId: movie.id, expectedVersion: 1, revokedAt: "2026-11-07T00:00:00Z")
    // No Trakt id: never a blanket removal. The play is found in Trakt's history at its time
    // and removed by its own id (Cinopsys's way).
    #expect(plan(revokeLocal, .trakt).deliveries.map(\.key) == ["history-remove-timed"] && plan(revokeLocal, .trakt).blocked.isEmpty)
    let wetrakr = plan(revokeLocal, .wetrakr)
    let item = try #require((wetrakr.deliveries.first?.body["movies"] as? [[String: Any]])?.first)
    #expect(wetrakr.deliveries.first?.path == "/sync/tracking/remove" && item["tracked_at"] as? String == "2026-11-06T20:00:00.000Z" && item["allow_rewatch"] == nil)
    // Simkl and MDBList keep one watch for every play: while the diary still has another play of
    // this movie, taking one off leaves them as they are…
    #expect(plan(revokeLocal, .mdblist).deliveries.isEmpty && plan(revokeLocal, .mdblist).blocked.isEmpty)
    #expect(plan(revokeLocal, .simkl).deliveries.isEmpty && plan(revokeLocal, .simkl).blocked.isEmpty)
    // …and the last play takes their watch off.
    for index in base.events.indices where base.events[index].titleId == movie.id && base.events[index].id != "local-7" {
        base.events[index].revokedAt = "2026-11-06T00:00:00Z"
    }
    #expect(plan(revokeLocal, .mdblist).deliveries.map(\.path) == ["/sync/watched/remove"])
    #expect(plan(revokeLocal, .simkl).deliveries.map(\.path) == ["/sync/history/remove"])
    let restore = OptimisticMutation.restoreWatch(eventId: "local-7", titleId: movie.id, expectedVersion: 2)
    #expect(plan(restore, .simkl).deliveries.map(\.path) == ["/sync/history"])
}

/// Most watched cast, counted on the phone: each person once per title, ranked by titles then
/// plays; their role comes from their most-played title, without TMDB's "(voice)".
@Test func castRankingCountsPeopleAcrossWatchedTitles() {
    let watched = [CastRanking.Watched(key: "tv:1", name: "Frieren", plays: 28), CastRanking.Watched(key: "tv:2", name: "Bocchi", plays: 12),
                   CastRanking.Watched(key: "tv:3", name: "Dandadan", plays: 3)]
    let kana = CastRanking.Member(id: 7, name: "Kana Ichinose", character: "Fern (voice)", profilePath: "/k.jpg")
    let atsumi = CastRanking.Member(id: 8, name: "Atsumi Tanezaki", character: "Frieren (voice)", profilePath: nil)
    let casts: [String: [CastRanking.Member]] = [
        "tv:1": [atsumi, kana, kana],
        "tv:2": [CastRanking.Member(id: 7, name: "Kana Ichinose", character: "Ryo (voice)", profilePath: "/k.jpg")],
        "tv:3": [atsumi]
    ]
    let rows = CastRanking.rank(watched, casts: casts)
    #expect(rows.map(\.id) == [7, 8])
    #expect(rows[0].titles == 2 && rows[0].plays == 40 && rows[0].character == "Fern" && rows[0].title == "Frieren")
    #expect(rows[1].titles == 2 && rows[1].plays == 31)
}

/// New-episode alerts: shows you're watching, episodes airing in the next two weeks, one alert
/// per show per day; skipped episodes, specials, past days and shows you're not watching are left out.
@Test func episodeAlertsCoverTheNextTwoWeeksOfShowsYouWatch() throws {
    func show(_ id: String, _ status: String) -> MediaTitle {
        MediaTitle(id: id, name: id.capitalized, category: "show", year: nil, overview: "", poster: nil, backdrop: nil, communityScore: nil, tmdbId: 1,
                   genres: [], tags: [], runtimeMinutes: nil, status: status, favorite: false, queued: false, score: nil, notes: "", deletedAt: nil,
                   version: 1, seasons: nil, createdAt: nil)
    }
    func episode(_ title: String, _ season: Int, _ number: Int, _ day: String, skipped: Bool? = nil) -> Episode {
        Episode(id: "\(title)-\(season)-\(number)", titleId: title, season: season, number: number, name: "", overview: "", airedOn: day,
                still: nil, hidden: true, communityScore: nil, skipped: skipped)
    }
    let workspace = Workspace(titles: [show("frieren", "watching"), show("planned", "planned"), show("dropped", "dropped")],
                              episodes: [episode("frieren", 2, 3, "2026-11-12"), episode("frieren", 2, 4, "2026-11-12"), episode("frieren", 2, 5, "2026-11-19"),
                                         episode("frieren", 2, 6, "2026-11-30"), episode("frieren", 2, 2, "2026-11-05"), episode("frieren", 0, 1, "2026-11-13"),
                                         episode("frieren", 2, 7, "2026-11-20", skipped: true), episode("planned", 1, 1, "2026-11-12"), episode("dropped", 1, 1, "2026-11-12")],
                              events: [])
    let alerts = EpisodeAlerts.upcoming(workspace, today: "2026-11-11")
    #expect(alerts.map(\.day) == ["2026-11-12", "2026-11-19"])
    #expect(alerts[0].title == "Frieren" && alerts[0].body == "S2 E3–E4 are out today." && alerts[0].id == "episode|frieren|2026-11-12")
    #expect(alerts[1].body == "S2 E5 is out today.")
}
