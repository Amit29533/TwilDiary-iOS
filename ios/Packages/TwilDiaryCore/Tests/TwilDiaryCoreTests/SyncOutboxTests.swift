import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func localWatchCardCalculationMatchesSeriesAndMovieProgress() throws {
    let workspace = try SampleWorkspace.mapped()
    let series = try #require(workspace.titles.first { $0.id == "again" })
    let card = WatchCard.calculate(title: series, in: workspace, day: "2026-10-23")
    #expect(card.season?.number == 1)
    #expect(card.progress.total > 0)
    #expect(card.next != nil)

    if let movie = workspace.titles.first(where: { !$0.isSeries }) {
        let movieCard = WatchCard.calculate(title: movie, in: workspace, day: "2026-10-23")
        #expect(movieCard.progress.total == 1)
        #expect(movieCard.season == nil)
    }
}

@Test func outboxCoalescesPatchTitleEditsAndAcknowledgesPerProvider() throws {
    var queue = SyncOutboxQueue()
    let first = SyncOutboxEntry(
        id: "entry-1",
        operationId: "op-1",
        createdAt: "2026-10-23T12:00:00Z",
        mutation: .patchTitle(titleId: "again", expectedVersion: 1, status: "watching", score: 8.5, clearScore: false, favorite: nil, queued: nil, notes: nil),
        pendingProviders: [.cloudflare, .trakt, .simkl]
    )
    let second = SyncOutboxEntry(
        id: "entry-2",
        operationId: "op-2",
        createdAt: "2026-10-23T12:00:05Z",
        mutation: .patchTitle(titleId: "again", expectedVersion: 2, status: nil, score: 9.0, clearScore: false, favorite: true, queued: nil, notes: "Great pacing"),
        pendingProviders: [.cloudflare, .trakt, .simkl]
    )
    queue.enqueue(first)
    let merged = queue.enqueue(second)
    #expect(queue.count == 1)
    #expect(merged.id == "entry-1")

    let projected = queue.project(onto: SampleWorkspace.make())
    let updatedTitle = try #require(projected.titles.first { $0.id == "again" })
    #expect(updatedTitle.score == 9.0)
    #expect(updatedTitle.favorite == true)
    #expect(updatedTitle.notes == "Great pacing")

    queue.acknowledge(entryID: "entry-1", provider: .cloudflare)
    #expect(queue.count == 1)
    #expect(queue.pending(for: .cloudflare).isEmpty)
    #expect(queue.pending(for: .trakt).count == 1)
    #expect(queue.pending(for: .simkl).count == 1)

    queue.acknowledge(entryID: "entry-1", provider: .trakt)
    queue.acknowledge(entryID: "entry-1", provider: .simkl)
    #expect(queue.isEmpty)
}

@Test func optimisticMarkAndRevokeWatchUpdatesWorkspaceImmediately() throws {
    let base = SampleWorkspace.make()
    let series = try #require(base.titles.first { $0.id == "again" })
    let initialCard = WatchCard.calculate(title: series, in: base, day: "2026-10-23")
    let nextEp = try #require(initialCard.next)

    let mutated = base.applying(.markWatch(
        operationId: "watch-op-1",
        titleId: series.id,
        episodeId: nextEp.id,
        watchedAt: "2026-10-23T12:00:00Z",
        recordedAt: "2026-10-23T12:00:00Z",
        rewatch: false
    ))
    let updatedSeries = try #require(mutated.titles.first { $0.id == series.id })
    let afterCard = WatchCard.calculate(title: updatedSeries, in: mutated, day: "2026-10-23")
    #expect(afterCard.progress.watched == initialCard.progress.watched + 1)
    #expect(afterCard.previous?.episodeId == nextEp.id)
}

@Test func directTraktThreeWayDiffPlansPullsPushesAndConflicts() throws {
    let base = try SampleWorkspace.mapped()
    let series = try #require(base.titles.first { $0.id == "again" && $0.tmdbId != nil })
    let tmdbId = try #require(series.tmdbId)
    let card = WatchCard.calculate(title: series, in: base, day: "2026-10-23")
    let nextEp = try #require(card.next)
    let episode = try #require(base.episodes.first { $0.id == nextEp.id })

    let remote = DirectTraktRemoteSnapshot(
        plays: [
            DirectTraktWatchPlay(tmdbId: tmdbId, isSeries: true, season: episode.season, episode: episode.number, watchedAt: "2026-10-23T18:00:00Z"),
            DirectTraktWatchPlay(tmdbId: 999888, isSeries: false, watchedAt: "2026-10-23T19:00:00Z")
        ],
        ratings: [
            DirectTraktRatingItem(tmdbId: tmdbId, isSeries: true, rating: 10, ratedAt: "2026-10-23T18:00:00Z")
        ],
        watchlist: []
    )
    let baseline = DirectTraktSyncBaseline(
        lastActivities: nil,
        titles: [
            series.id: DirectTraktTitleBaseline(
                titleId: series.id,
                score: series.score.map { Int($0.rounded()) },
                watchlisted: false
            )
        ]
    )
    let plan = DirectTraktEngine.plan(workspace: base, remote: remote, baseline: baseline)
    #expect(plan.pulls.contains(.pullWatch(titleId: series.id, episodeId: episode.id, watchedAt: "2026-10-23T18:00:00Z")))
    #expect(plan.pulls.contains(.pullRating(titleId: series.id, score: 10.0)))
    #expect(plan.missingImports.contains(.importMissingTmdb(tmdbId: 999888, isSeries: false)))

    let applied = DirectTraktEngine.applyPulls(from: plan, to: base, recordedAt: "2026-10-23T20:00:00Z")
    let updatedTitle = try #require(applied.titles.first { $0.id == series.id })
    #expect(updatedTitle.score == 10.0)
}

@Test func simklAndMDBListNormalizationAndOutboxFanout() throws {
    let simklJSON = Data(#"""
    {
      "movies": [
        {
          "status": "completed",
          "last_watched_at": "2026-10-20T10:00:00Z",
          "user_rating": 9,
          "movie": { "ids": { "tmdb": "12345" } }
        }
      ],
      "anime": [
        {
          "status": "plantowatch",
          "added_to_watchlist_at": "2026-10-21T10:00:00Z",
          "show": { "ids": { "tmdb": 67890 } }
        }
      ]
    }
    """#.utf8)
    let snapshot = try SimklSyncEngine.decodeAllItems(from: simklJSON)
    #expect(snapshot.plays.count == 1)
    #expect(snapshot.plays.first?.tmdbId == 12345)
    #expect(snapshot.ratings.first?.rating == 9)
    #expect(snapshot.watchlist.first?.tmdbId == 67890)

    let mdbJSON = Data(#"""
    {
      "score": 86,
      "ratings": [
        { "source": "imdb", "value": 8.7, "score": 87, "votes": 12000 },
        { "source": "trakt", "value": 85, "score": 85, "votes": 3400 }
      ]
    }
    """#.utf8)
    let summary = try MDBListSyncEngine.decodeRatingSummary(from: mdbJSON, tmdbId: 12345, isSeries: false)
    #expect(summary.aggregatedScore == 86)
    #expect(summary.score(for: "imdb") == 87)

    let workspace = try SampleWorkspace.mapped()
    let series = try #require(workspace.titles.first { $0.id == "again" })
    var queue = SyncOutboxQueue()
    queue.enqueue(SyncOutboxEntry(
        id: "fanout-1",
        operationId: "op-fanout-1",
        createdAt: "2026-10-23T12:00:00Z",
        mutation: .patchTitle(titleId: series.id, expectedVersion: 1, status: "planned", score: 9.0, clearScore: false, favorite: nil, queued: true, notes: nil),
        pendingProviders: [.simkl, .mdblist]
    ))
    let simklBatch = try #require(MultiProviderOutboxDispatcher.prepareBatch(for: .simkl, from: queue, in: workspace))
    #expect(simklBatch.entryIDs == ["fanout-1"])
    #expect(simklBatch.ratingsPayload != nil)
    #expect(simklBatch.watchlistPayload != nil)
}

@Test func anEditTheServerNoLongerTakesGoesToTheServiceHoldingTheDiary() {
    var queue = SyncOutboxQueue()
    let watch = queue.enqueue(SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .markWatch(operationId: "w", titleId: "t", episodeId: nil,
        watchedAt: "2026-11-05T00:00:00Z", recordedAt: "2026-11-05T00:00:00Z", rewatch: false), pendingProviders: [.cloudflare, .simkl]))
    queue.handOver(entryID: watch.id, to: .trakt)
    #expect(queue.pending(for: .cloudflare).isEmpty)
    #expect(queue.entries.first?.pendingProviders == [.simkl, .trakt])
    let revoke = queue.enqueue(SyncOutboxEntry(createdAt: "2026-11-05T00:00:00Z", mutation: .revokeWatch(eventId: "e", titleId: "u", expectedVersion: 1,
        revokedAt: "2026-11-05T00:00:00Z"), pendingProviders: [.cloudflare]))
    queue.handOver(entryID: revoke.id, to: nil)
    #expect(queue.count == 1, "Nothing left to send it to: it's done")
}

@Test func movieDeduplicationRevokeStatusAndFileOutboxStorePersistence() throws {
    let base = SampleWorkspace.make()
    let movie = try #require(base.titles.first { !$0.isSeries })
    let existingMovieEvents = base.activeEvents.filter { $0.titleId == movie.id }

    // 1. Revoke all existing watches on the movie so it has 0 watches -> status reverts to "planned".
    var current = base
    for ev in existingMovieEvents {
        current = current.applying(.revokeWatch(
            eventId: ev.id,
            titleId: movie.id,
            expectedVersion: ev.version ?? 1,
            revokedAt: "2026-10-23T12:00:00Z"
        ))
    }
    let plannedMovie = try #require(current.titles.first { $0.id == movie.id })
    #expect(plannedMovie.status == "planned")

    // 2. Marking a first watch transitions to "completed", and a non-rewatch duplicate is ignored.
    current = current.applying(.markWatch(
        operationId: "movie-op-1",
        titleId: movie.id,
        episodeId: nil,
        watchedAt: "2026-10-23T13:00:00Z",
        recordedAt: "2026-10-23T13:00:00Z",
        rewatch: false
    ))
    let countAfterFirst = current.activeEvents.filter { $0.titleId == movie.id }.count
    #expect(countAfterFirst == 1)
    #expect(current.titles.first { $0.id == movie.id }?.status == "completed")

    let deduplicated = current.applying(.markWatch(
        operationId: "movie-op-2",
        titleId: movie.id,
        episodeId: nil,
        watchedAt: "2026-10-23T14:00:00Z",
        recordedAt: "2026-10-23T14:00:00Z",
        rewatch: false
    ))
    #expect(deduplicated.activeEvents.filter { $0.titleId == movie.id }.count == 1)

    // 3. Rewatch adds a second watch event.
    let rewatched = current.applying(.markWatch(
        operationId: "movie-op-3",
        titleId: movie.id,
        episodeId: nil,
        watchedAt: "2026-10-23T15:00:00Z",
        recordedAt: "2026-10-23T15:00:00Z",
        rewatch: true
    ))
    #expect(rewatched.activeEvents.filter { $0.titleId == movie.id }.count == 2)

    // 4. FileSyncOutboxStore persists and reloads SyncOutboxQueue on disk.
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = FileSyncOutboxStore(directory: tempDir)
    var queue = SyncOutboxQueue()
    queue.enqueue(SyncOutboxEntry(
        id: "disk-1",
        operationId: "disk-op-1",
        createdAt: "2026-10-23T12:00:00Z",
        mutation: .trashTitle(titleId: movie.id, expectedVersion: movie.version ?? 1, deletedAt: "2026-10-23T12:00:00Z")
    ))
    try store.save(queue, scope: "test")
    let reloaded = store.load(scope: "test")
    #expect(reloaded == queue)
}

@Test func providerBatchesAndDynamicIslandLiveActivityStates() throws {
    let workspace = try SampleWorkspace.mapped()
    let series = try #require(workspace.titles.first { $0.id == "again" && $0.tmdbId != nil })
    var queue = SyncOutboxQueue()
    queue.enqueue(SyncOutboxEntry(
        id: "sk-1",
        operationId: "op-sk-1",
        createdAt: "2026-10-23T19:00:00Z",
        mutation: .patchTitle(titleId: series.id, expectedVersion: 1, status: "planned", score: 8.5, clearScore: false, favorite: nil, queued: true, notes: nil),
        pendingProviders: [.simkl]
    ))
    let batch = try #require(MultiProviderOutboxDispatcher.prepareBatch(for: .simkl, from: queue, in: workspace))
    #expect(batch.provider == .simkl)
    #expect(batch.ratingsPayload != nil && batch.watchlistPayload != nil)
    #expect(batch.idempotencyKey == nil)
    // Simkl keeps no favourites: an edit that changes one is held back, never half-sent.
    var favourite = SyncOutboxQueue()
    favourite.enqueue(SyncOutboxEntry(createdAt: "2026-10-23T19:00:00Z",
        mutation: .patchTitle(titleId: series.id, expectedVersion: 1, status: nil, score: nil, clearScore: false, favorite: true, queued: nil, notes: nil),
        pendingProviders: [.simkl]))
    #expect(MultiProviderOutboxDispatcher.prepareBatch(for: .simkl, from: favourite, in: workspace) == nil)

    let diProviderState = SyncLiveActivityState.forProviderBatch(
        provider: .simkl,
        completed: 3,
        total: 6,
        phase: .flushingOutbox,
        isBackgrounded: true
    )
    #expect(diProviderState.compactBadge == "SK")
    #expect(diProviderState.percent == 50)
    #expect(diProviderState.title == "Background Simkl sync")

    let traktSync = TraktSync(
        next: nil,
        run: TraktSync.Run(id: "r1", state: "applying", stage: "done", page: 1, progress: 100, ratingMode: "round", error: nil, retryAfter: 0),
        items: [],
        counts: ["applied": 30, "skipped": 10, "pending": 10]
    )
    let diTraktState = try #require(SyncLiveActivityState.fromTrakt(traktSync, paused: false, isBackgrounded: true))
    #expect(diTraktState.compactBadge == "TK")
    #expect(diTraktState.percent == 80)
    #expect(diTraktState.title == "Background Trakt import")
}

@Test func providerConnectionSettingsAndLoggingMethods() throws {
    var settings = ProviderConnectionSettings()
    #expect(settings.simkl.statusBadge == "Set up")
    #expect(settings.activeDirectLoggingProviders.isEmpty)

    settings.customTmdbToken = "  custom-tmdb-token  "
    settings = ProviderConnectionSettings(
        customTmdbToken: settings.customTmdbToken,
        trakt: ExternalProviderConfig(
            provider: .trakt,
            enabled: true,
            loggingMethod: .serverOnly,
            clientId: "trakt-cid",
            accessToken: "trakt-token"
        ),
        simkl: ExternalProviderConfig(
            provider: .simkl,
            enabled: true,
            loggingMethod: .serverAndDirectAPI,
            clientId: "simkl-cid",
            accessToken: "simkl_token_456",
            username: "cinephile"
        ),
        mdblist: ExternalProviderConfig(
            provider: .mdblist,
            enabled: true,
            loggingMethod: .directAPIOnly,
            apiKey: "mdb-key"
        )
    )
    #expect(settings.customTmdbToken == "custom-tmdb-token")
    #expect(settings.simkl.statusBadge == "Connected")
    #expect(settings.mdblist.statusBadge == "Connected")
    #expect(settings.trakt.loggingMethod.includesServerLogging == true)
    #expect(settings.trakt.loggingMethod.includesDirectAPI == false)
    #expect(settings.activeDirectLoggingProviders == Set([.simkl, .mdblist]))

    final class MemorySecretStore: ProviderSecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        func readSecret(for account: String) -> String? { values[account] }
        func writeSecret(_ value: String?, for account: String) -> Bool {
            if let value, !value.isEmpty { values[account] = value }
            else { values.removeValue(forKey: account) }
            return true
        }
    }
    let suite = UserDefaults(suiteName: "twildiary.test.\(UUID().uuidString)")!
    let secretStore = MemorySecretStore()
    let store = UserDefaultsProviderSettingsStore(defaults: suite, key: "test.settings", secrets: secretStore)
    try store.save(settings)

    // Verify UserDefaults payload stripped plaintext tokens and stored them in the secret store
    let rawJSON = String(data: suite.data(forKey: "test.settings") ?? Data(), encoding: .utf8) ?? ""
    #expect(!rawJSON.contains("custom-tmdb-token"))
    #expect(!rawJSON.contains("simkl_token_456"))
    #expect(!rawJSON.contains("mdb-key"))
    let sealed = try #require(secretStore.readSecret(for: "test.settings.credentials.v2"))
    let protectedSettings = try JSONDecoder().decode(ProviderConnectionSettings.self, from: Data(sealed.utf8))
    #expect(protectedSettings.customTmdbToken == "custom-tmdb-token")
    #expect(protectedSettings.simkl.accessToken == "simkl_token_456")
    #expect(protectedSettings.mdblist.apiKey == "mdb-key")
    #expect(try store.load() == settings)
}

@Test func airingScheduleCatchUpIcsAndCollectionTags() throws {
    let anime = MediaTitle(id: "frieren", name: "Frieren", category: "anime", year: 2023,
        overview: "", poster: nil, backdrop: nil, communityScore: nil, tmdbId: 209867,
        genres: ["Animation"], tags: ["Simulcast", "Top 10"], runtimeMinutes: 24,
        status: "watching", favorite: true, queued: false, score: 9.5, notes: "", deletedAt: nil,
        version: 1, seasons: [Season(number: 1, name: "Season 1", expectedEpisodes: 2, metadataLoadedAt: nil, metadataVersion: nil)], createdAt: nil)
    let epPast = Episode(id: "ep1", titleId: "frieren", season: 1, number: 1, name: "The Journey's End", overview: "", airedOn: "2026-10-20", still: nil, hidden: nil, communityScore: nil)
    let epFuture = Episode(id: "ep2", titleId: "frieren", season: 1, number: 2, name: "It Didn't Have to Be Magic", overview: "", airedOn: "2026-10-27", still: nil, hidden: nil, communityScore: nil)
    let workspace = Workspace(titles: [anime], episodes: [epPast, epFuture], events: [], locations: [])
    let now = try #require(DiaryDate.parse("2026-10-23T12:00:00Z"))

    let upcoming = UpcomingSchedule(workspace: workspace, now: now, category: .all, horizonDays: 14, mode: .upcoming)
    #expect(upcoming.totalCount == 1)
    #expect(upcoming.animeCount == 1)
    #expect(upcoming.thisWeekCount == 1)
    #expect(upcoming.items.first?.episode.id == "ep2")
    let ics = upcoming.icsString(hideSpoilers: false)
    #expect(ics.contains("BEGIN:VCALENDAR"))
    #expect(ics.contains("SUMMARY:Frieren · S01E02"))

    let catchup = UpcomingSchedule(workspace: workspace, now: now, category: .all, horizonDays: 14, mode: .catchup)
    #expect(catchup.totalCount == 1)
    #expect(catchup.thisWeekCount == 1)
    #expect(catchup.items.first?.episode.id == "ep1")
    #expect(catchup.strip.first?.daysAway == -1)

    // CSV rating/date behaviour is covered by the canonical server parser regression suite.

}

/// A service the app no longer knows: a saved outbox naming it still loads, with every other
/// pending edit kept and that service simply dropped.
@Test func aSavedOutboxNamingARemovedProviderStillLoads() throws {
    let entry = SyncOutboxEntry(createdAt: "2026-10-23T19:00:00Z",
                                mutation: .patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil),
                                pendingProviders: [.cloudflare, .simkl])
    // The real encoding of a mutation, with a removed provider added to the saved list.
    var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncOutboxQueue(entries: [entry]))) as? [String: Any])
    var entries = try #require(saved["entries"] as? [[String: Any]])
    entries[0]["pendingProviders"] = ["cloudflare", "simkl", "retired-service"]
    saved["entries"] = entries
    let queue = try JSONDecoder().decode(SyncOutboxQueue.self, from: JSONSerialization.data(withJSONObject: saved))
    #expect(queue.entries.count == 1)
    #expect(queue.entries[0].pendingProviders == [.cloudflare, .simkl])
    #expect(queue.entries[0].mutation == entry.mutation)
}
