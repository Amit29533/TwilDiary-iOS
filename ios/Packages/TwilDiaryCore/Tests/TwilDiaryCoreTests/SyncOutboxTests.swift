import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func localWatchCardCalculationMatchesSeriesAndMovieProgress() throws {
    let workspace = SampleWorkspace.make()
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
    let base = SampleWorkspace.make()
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

    let workspace = SampleWorkspace.make()
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

@Test func wetrakrFullTwoWaySyncAndDynamicIslandLiveActivityStates() throws {
    let activitiesJSON = Data(#"""
    {
      "movies": { "last_tracking_watched_at": "2026-10-20T10:00:00Z", "last_tracking_planning_at": "2026-10-20T11:00:00Z" },
      "episodes": { "last_tracking_watched_at": "2026-10-21T10:00:00Z" },
      "shows": { "last_tracking_dropped_at": "2026-10-22T10:00:00Z" },
      "ratings": { "all": "2026-10-23T10:00:00Z" },
      "favorites": { "all": "2026-10-23T11:00:00Z" }
    }
    """#.utf8)
    let act1 = try WeTrakrSyncEngine.decodeActivities(from: activitiesJSON)
    #expect(act1.changedDomains(since: nil).anyChanged == true)
    #expect(act1.changedDomains(since: act1).anyChanged == false)

    let workspace = SampleWorkspace.make()
    let series = try #require(workspace.titles.first { $0.id == "again" && $0.tmdbId != nil })
    let tmdbId = try #require(series.tmdbId)
    let card = WatchCard.calculate(title: series, in: workspace, day: "2026-10-23")
    let nextEp = try #require(card.next)
    let ep = try #require(workspace.episodes.first { $0.id == nextEp.id })

    let episodeRowsJSON = Data("""
    [
      {
        "type": "episode",
        "show_ids": { "tmdb": \(tmdbId) },
        "season_number": \(ep.season),
        "number": \(ep.number),
        "watched_at": "2026-10-23T18:00:00Z",
        "plays": 1
      }
    ]
    """.utf8)
    let ratingRowsJSON = Data("""
    [
      {
        "type": "show",
        "ids": { "tmdb": \(tmdbId) },
        "rating": 9.5,
        "rated_at": "2026-10-23T18:30:00Z"
      }
    ]
    """.utf8)
    let favRowsJSON = Data("""
    [
      {
        "type": "show",
        "ids": { "tmdb": \(tmdbId) },
        "favorited_at": "2026-10-23T18:45:00Z"
      }
    ]
    """.utf8)

    let watchedEpisodes = try WeTrakrSyncEngine.decodeCompactRows(from: episodeRowsJSON)
    let ratingsShows = try WeTrakrSyncEngine.decodeCompactRows(from: ratingRowsJSON)
    let favoritesShows = try WeTrakrSyncEngine.decodeCompactRows(from: favRowsJSON)

    let snapshot = WeTrakrSyncEngine.normalizeSnapshot(
        watchedEpisodes: watchedEpisodes,
        ratingsShows: ratingsShows,
        favoritesShows: favoritesShows
    )
    let updatedWorkspace = WeTrakrSyncEngine.applySnapshot(snapshot, to: workspace, recordedAt: "2026-10-23T19:00:00Z")
    let updatedSeries = try #require(updatedWorkspace.titles.first { $0.id == series.id })
    #expect(updatedSeries.score == 9.5)
    #expect(updatedSeries.favorite == true)

    // Verify 3-way diff protection: if local score was changed from baseline (8 -> 10) while WeTrakr still has 8.0,
    // applySnapshot must NOT overwrite the newer local 10.0 score with WeTrakr's 8.0.
    let localEditedWorkspace = updatedWorkspace.applying(.patchTitle(
        titleId: series.id,
        expectedVersion: nil,
        status: nil,
        score: 10.0,
        clearScore: false,
        favorite: nil,
        queued: nil,
        notes: nil
    ))
    let baselineAt8 = DirectTraktSyncBaseline(
        lastActivities: nil,
        titles: [
            series.id: DirectTraktTitleBaseline(titleId: series.id, score: 8, watchlisted: false)
        ]
    )
    let staleRemoteSnapshot = WeTrakrSyncEngine.normalizeSnapshot(
        ratingsShows: [WeTrakrSyncEngine.CompactRow(type: "show", tmdbId: tmdbId, rating: 8.2, ratedAt: "2026-10-20T00:00:00Z")]
    )
    let preservedWorkspace = WeTrakrSyncEngine.applySnapshot(
        staleRemoteSnapshot,
        to: localEditedWorkspace,
        baseline: baselineAt8,
        recordedAt: "2026-10-23T20:00:00Z"
    )
    #expect(preservedWorkspace.titles.first { $0.id == series.id }?.score == 10.0)

    var queue = SyncOutboxQueue()
    queue.enqueue(SyncOutboxEntry(
        id: "wt-1",
        operationId: "op-wt-1",
        createdAt: "2026-10-23T19:00:00Z",
        mutation: .patchTitle(titleId: series.id, expectedVersion: 1, status: "planned", score: 8.5, clearScore: false, favorite: true, queued: true, notes: nil),
        pendingProviders: [.wetrakr]
    ))
    let batch = try #require(MultiProviderOutboxDispatcher.prepareBatch(for: .wetrakr, from: queue, in: workspace))
    #expect(batch.provider == .wetrakr)
    #expect(batch.favoritesPayload != nil)
    #expect(batch.idempotencyKey?.hasPrefix("wetrakr-") == true)

    let diProviderState = SyncLiveActivityState.forProviderBatch(
        provider: .wetrakr,
        completed: 3,
        total: 6,
        phase: .flushingOutbox,
        isBackgrounded: true
    )
    #expect(diProviderState.compactBadge == "WT")
    #expect(diProviderState.percent == 50)
    #expect(diProviderState.title == "Background WeTrakr sync")

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

@Test func providerConnectionSettingsAndLoggingMethods() {
    var settings = ProviderConnectionSettings()
    #expect(settings.wetrakr.statusBadge == "Set up")
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
        wetrakr: ExternalProviderConfig(
            provider: .wetrakr,
            enabled: true,
            loggingMethod: .serverAndDirectAPI,
            clientId: "wtk_123",
            accessToken: "wtk_pat_456",
            username: "cinephile"
        ),
        simkl: ExternalProviderConfig(
            provider: .simkl,
            enabled: false,
            loggingMethod: .serverAndDirectAPI,
            clientId: "simkl-cid"
        ),
        mdblist: ExternalProviderConfig(
            provider: .mdblist,
            enabled: true,
            loggingMethod: .directAPIOnly,
            apiKey: "mdb-key"
        )
    )
    #expect(settings.customTmdbToken == "custom-tmdb-token")
    #expect(settings.wetrakr.statusBadge == "Connected")
    #expect(settings.simkl.statusBadge == "Configured")
    #expect(settings.mdblist.statusBadge == "Connected")
    #expect(settings.trakt.loggingMethod.includesServerLogging == true)
    #expect(settings.trakt.loggingMethod.includesDirectAPI == false)
    #expect(settings.activeDirectLoggingProviders == Set([.wetrakr, .mdblist]))

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
    store.save(settings)

    // Verify UserDefaults payload stripped plaintext tokens and stored them in the secret store
    let rawJSON = String(data: suite.data(forKey: "test.settings") ?? Data(), encoding: .utf8) ?? ""
    #expect(!rawJSON.contains("custom-tmdb-token"))
    #expect(!rawJSON.contains("wtk_pat_456"))
    #expect(!rawJSON.contains("mdb-key"))
    #expect(secretStore.readSecret(for: "test.settings.tmdb.token") == "custom-tmdb-token")
    #expect(secretStore.readSecret(for: "test.settings.wetrakr.accessToken") == "wtk_pat_456")
    #expect(secretStore.readSecret(for: "test.settings.mdblist.apiKey") == "mdb-key")
    #expect(store.load() == settings)
}

@Test func airingScheduleCatchUpIcsAndCollectionTags() throws {
    let anime = MediaTitle(
        id: "frieren",
        name: "Frieren",
        category: "anime",
        year: 2023,
        runtimeMinutes: 24,
        genres: ["Animation"],
        status: "watching",
        score: 9.5,
        favorite: true,
        queued: false,
        notes: "",
        tags: ["Simulcast", "Top 10"],
        tmdbId: 209867,
        seasons: [Season(id: "s1", number: 1, name: "Season 1", expectedEpisodes: 2)],
        version: 1
    )
    let epPast = Episode(id: "ep1", titleId: "frieren", season: 1, number: 1, name: "The Journey's End", overview: "", airedOn: "2026-10-20")
    let epFuture = Episode(id: "ep2", titleId: "frieren", season: 1, number: 2, name: "It Didn't Have to Be Magic", overview: "", airedOn: "2026-10-27")
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

    let csv = "Date,Name,Year,Rating,Watched Date\n2026-10-01,\"Half Star\",2020,0.5,2026-10-01\n"
    let csvExport = try DiaryExport.fromExternalCSV(csv, exportedAt: now)
    #expect(csvExport.titles.first?.score == 1.0)
}
