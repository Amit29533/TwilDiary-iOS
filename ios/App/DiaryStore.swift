import SwiftUI
import Observation
import TwilDiaryCore

@MainActor @Observable final class DiaryStore {
    @ObservationIgnored private var retainedTraktController: TraktController?
    var traktController: TraktController {
        if let retainedTraktController { return retainedTraktController }
        let checkpoint: any TraktApplyCheckpointStoring = isPreview ? MemoryTraktApplyCheckpoint() : PreferencesTraktApplyCheckpoint()
        #if DEBUG
        if isPreview, ProcessInfo.processInfo.arguments.contains("--ui-trakt=cold-quota") { checkpoint.runID = "reference-sync" }
        #endif
        let controller = TraktController(service: makeTraktService(store: self), checkpoint: checkpoint, onTransferFinished: { [weak self] in
            guard let self, !self.needsSignIn, self.quotaBlockedUntil == nil else { return }
            await self.refresh()
        })
        retainedTraktController = controller
        return controller
    }
    func resumeTraktOnForeground() async {
        guard retainedTraktController != nil || (!isPreview && PreferencesTraktApplyCheckpoint().runID != nil) else { return }
        let controller = traktController
        await controller.finishSuspendingTransfer()
        if !controller.busy { await controller.refresh(); await controller.resumeApprovedApply() }
    }
    func suspendTraktForBackground() { retainedTraktController?.suspendForBackground() }
    struct HomeProjection {
        let overview: HomeOverview
        let watching: [MediaTitle]
        let recent: [HistoryEntry]
    }
    @ObservationIgnored private var cachedHome: (day: Date, calendar: Calendar, value: HomeProjection)?
    @ObservationIgnored private var cachedStats: (day: String, zone: String, period: Period, year: Int?, value: StatsOverview)?
    /// Assigning a snapshot directly indexes it synchronously (tests, fixtures, sign-out).
    /// Network snapshots are indexed off the main actor first; see `publishIndexed`.
    var workspace = Workspace() { didSet { if !publishingIndexedSnapshot { indexWorkspace() } } }
    @ObservationIgnored private var publishingIndexedSnapshot = false
    @ObservationIgnored private var titleScopes: [String: Workspace] = [:]
    @ObservationIgnored private var cachedHistory: (query: HistoryQuery, zone: String, value: [HistoryEntry])?
    @ObservationIgnored private var cachedActiveEventCount: Int?
    @ObservationIgnored private var cachedLibrary: (query: LibraryQuery, source: PublicRatingSource, value: [MediaTitle])?
    private var titleIndex: [String: MediaTitle] = [:]
    private var progressIndex: [String: Double] = [:]
    private var seasonProgressIndex: [String: [Int: SeasonProgress]] = [:]
    private var presentTitleIDs = Set<String>()
    private var episodesBySeason: [String: [Int: [Episode]]] = [:]
    private var watchedEpisodesByTitle: [String: Set<String>] = [:]
    private struct CardKey: Hashable {
        let titleID: String
        let revision: UUID
        let session: UUID
        let season: Int?
        let day: String
    }
    private var cardInputs: [String: WorkspaceCardInput] = [:] { didSet { cardInputsToken = UUID() } }
    @ObservationIgnored private var cardInputsToken = UUID()
    private var cardRevisions: [String: UUID] = [:]
    // Not observed: every visible card read this dictionary, so one card's load
    // re-rendered all of them. Cards keep their own loaded value; revisions stay observed.
    @ObservationIgnored private var cachedCards: [CardKey: (at: Date, value: WatchCard)] = [:]
    @ObservationIgnored private var cardReads: [CardKey: (id: UUID, task: Task<WatchCard, Error>)] = [:]
    func cardRevision(_ id: String) -> UUID? { cardRevisions[id] }
    private func clearCards() {
        for read in cardReads.values { read.task.cancel() }
        cardReads = [:]; cachedCards = [:]; cardInputs = [:]; cardRevisions = [:]
    }
    let discoveryCache = DiscoveryCache()
    let communityCache = CommunityInformationCache()
    private(set) var discoveryRevision = UUID()
    func invalidateDiscovery() { discoveryCache.reset(); discoveryRevision = UUID() }
    var cachedPeople: [Int: (at: Date, value: PersonResponse)] = [:]
    var loading = false
    var busy = false { didSet { if !busy { resumeMutationWaiters() } } }
    enum CardAction: Equatable { case mark, remove, menu }
    private(set) var cardActions: [String: CardAction] = [:]
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private func resumeMutationWaiters() {
        let waiting = mutationWaiters; mutationWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    private(set) var needsMutationRefresh = false
    var writesBlocked: Bool { busy || needsMutationRefresh }
    var mutationRefreshNotice: String? {
        needsMutationRefresh ? "Saved, but refreshing failed. Refresh your diary before making another change." : nil
    }
    var needsSignIn = true
    var hasLoadedWorkspace = false
    var error: String?
    private(set) var undoNoticeID = UUID()
    var undoLabel: String? { didSet { undoNoticeID = UUID() } }
    private(set) var showingCachedSnapshot = false
    private(set) var lastRefreshedAt: Date?
    private(set) var cacheWarning: String?
    private var undoAction: (() async throws -> Void)?
    private let api: DiaryAPI
    private let cache: any WorkspaceCaching
    @ObservationIgnored private var cacheRestoration: Task<Void, Never>?
    private(set) var restoringCache = false
    private var sessionGeneration = UUID()
    var sessionRevision: UUID { sessionGeneration }
    private var snapshotGeneration = UUID()
    private var lastForegroundRead: Date?
    private var pendingWatches: [String: [String: Any]] = [:]
    private var pendingProgress: [String: [String: Any]] = [:]
    private var pendingRemovals: [String: WatchCard.Previous] = [:]
    var pendingSeasonAdjustments: [String: SeasonEditTransaction] = [:]
    let isPreview: Bool
    #if DEBUG
    private var fixture: FixtureDiaryBackend?
    private var failNextFixtureRefresh = false
    #endif
    var canMutate: Bool {
        guard !needsMutationRefresh else { return false }
        #if DEBUG
        if isPreview { return fixture != nil }
        #endif
        return !isPreview
    }
    var now: Date { isPreview ? DiaryDate.parse("2026-10-23T12:00:00Z")! : .now }
    init(api: DiaryAPI? = nil, cache: (any WorkspaceCaching)? = nil) {
        self.api = api ?? DiaryAPI()
        if let cache { self.cache = cache }
        else if api == nil { self.cache = ProtectedWorkspaceCache() }
        else { self.cache = MemoryWorkspaceCache() }
        #if DEBUG
        isPreview = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        isPreview = false
        #endif
        #if DEBUG
        if isPreview {
            workspace = PreviewData.workspace; needsSignIn = false; hasLoadedWorkspace = true
            if ProcessInfo.processInfo.arguments.contains("--ui-empty") { workspace = Workspace() }
            if ProcessInfo.processInfo.arguments.contains("--ui-title-metadata") { workspace = PreviewData.metadataWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-long-synopsis") { workspace = PreviewData.longSynopsisWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-upcoming") { workspace = PreviewData.upcomingWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-long-episodes") { workspace = PreviewData.withLongEpisodeSummaries(workspace) }
            if ProcessInfo.processInfo.arguments.contains("--ui-cached-snapshot") {
                showingCachedSnapshot = true; lastRefreshedAt = now.addingTimeInterval(-600)
                cacheWarning = "Your diary is loaded, but its protected offline copy could not be updated."
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-mutations") { fixture = FixtureDiaryBackend(workspace: workspace, scanner: ProcessInfo.processInfo.arguments.contains("--ui-scanner")) }
        }
        #endif
        if !isPreview {
            needsSignIn = self.api.credential == nil
            restoreCachedWorkspace()
        }
        indexWorkspace()
    }
    func connect(_ credential: AccessCredential) async {
        cacheRestoration?.cancel(); cacheRestoration = nil; restoringCache = false
        let previousScope = api.credential?.cacheScope
        retainedTraktController?.invalidateSession(); retainedTraktController = nil
        let generation = UUID(); sessionGeneration = generation; snapshotGeneration = UUID()
        lastForegroundRead = nil
        invalidateDiscovery()
        communityCache.reset()
        do {
            try await api.authenticate(credential)
            guard generation == sessionGeneration else { return }
            // Reads started while authentication still used the previous
            // credential must not survive under the newly authenticated owner.
            invalidateDiscovery()
            communityCache.reset()
            communityRatings.reset(); cachedPeople = [:]; clearCards(); cardActions = [:]; resumeMutationWaiters()
            if previousScope != credential.cacheScope {
                workspace = Workspace(); hasLoadedWorkspace = false; showingCachedSnapshot = false; lastRefreshedAt = nil; cacheWarning = nil
                needsMutationRefresh = false
                pendingWatches.removeAll(); pendingProgress.removeAll(); pendingRemovals.removeAll(); pendingSeasonAdjustments.removeAll()
                undoLabel = nil; undoAction = nil
            }
            loading = false; busy = false
            needsSignIn = false; error = nil; restoreCachedWorkspace(); await refresh()
        } catch { if generation == sessionGeneration { fail(error) } }
    }
    func signOut() {
        cacheRestoration?.cancel(); cacheRestoration = nil; restoringCache = false
        retainedTraktController?.invalidateSession(); retainedTraktController = nil
        if !isPreview { PreferencesTraktApplyCheckpoint().runID = nil }
        #if DEBUG
        fixture = nil
        failNextFixtureRefresh = false
        #endif
        sessionGeneration = UUID(); snapshotGeneration = UUID()
        lastForegroundRead = nil
        invalidateDiscovery()
        communityCache.reset()
        needsMutationRefresh = false
        Task { await PublicArtworkCache.shared.removeAll() }
        api.signOut(); workspace = Workspace(); communityRatings.reset(); cachedPeople = [:]; clearCards(); cardActions = [:]; resumeMutationWaiters(); hasLoadedWorkspace = false; error = nil
        showingCachedSnapshot = false; lastRefreshedAt = nil; loading = false; busy = false
        do { try cache.removeAll(); cacheWarning = nil }
        catch { cacheWarning = "The saved diary could not be removed. It remains encrypted on this device." }
        pendingWatches.removeAll(); pendingProgress.removeAll(); pendingRemovals.removeAll(); undoAction = nil; undoLabel = nil
        pendingSeasonAdjustments.removeAll()
        needsSignIn = true
    }
    func refresh() async {
        guard !loading, !needsSignIn else { return }
        api.retryQuota()
        #if DEBUG
        if isPreview && fixture == nil { return }
        #else
        if isPreview { return }
        #endif
        let session = sessionGeneration
        loading = true; defer { if session == sessionGeneration { loading = false } }
        await cacheRestoration?.value
        guard session == sessionGeneration, !needsSignIn, !Task.isCancelled else { return }
        do { try await reload(); if session == sessionGeneration { error = nil } }
        catch is CancellationError { }
        catch { if session == sessionGeneration { fail(error) } }
    }
    /// No background polling on the phone. Coalesce rapid scene changes and
    /// wait for in-flight write receipts before reading the scheduled D1 result.
    func refreshOnForeground(at date: Date = .now) async {
        guard !needsSignIn, !api.isQuotaBlocked, lastForegroundRead.map({ date.timeIntervalSince($0) >= 10 }) ?? true else { return }
        let session = sessionGeneration
        while busy && session == sessionGeneration && !Task.isCancelled {
            await withCheckedContinuation { mutationWaiters.append($0) }
        }
        guard session == sessionGeneration, !Task.isCancelled, !api.isQuotaBlocked,
              lastForegroundRead.map({ date.timeIntervalSince($0) >= 10 }) ?? true else { return }
        lastForegroundRead = date
        defer { if Task.isCancelled, session == sessionGeneration, lastForegroundRead == date { lastForegroundRead = nil } }
        await refresh()
    }
    func reload() async throws {
        #if DEBUG
        if let fixture {
            if failNextFixtureRefresh {
                failNextFixtureRefresh = false
                throw APIError.message("Synthetic refresh outage")
            }
            workspace = fixture.workspace; hasLoadedWorkspace = true; needsMutationRefresh = false
            return
        }
        #endif
        let session = sessionGeneration, revision = UUID()
        snapshotGeneration = revision
        // Publish only a complete snapshot. A failed page cannot replace good data with a partial diary.
        let snapshot: Workspace
        do { snapshot = try await readWorkspaceSnapshot() }
        catch WorkspaceIntegrityError.incompleteSnapshot {
            try Task.checkCancellation()
            guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
            // A scheduled import may land between section reads. Retry GETs
            // once; persistent inconsistency preserves the last complete diary.
            snapshot = try await readWorkspaceSnapshot()
        }
        try await publish(snapshot, session: session, revision: revision)
    }
    /// Re-read only the titles a write touched and merge them into the current snapshot.
    /// One small consistent request replaces a full multi-page diary download, so the
    /// tapped card is confirmed in roughly one round trip instead of dozens.
    private func reloadTitles(_ ids: Set<String>) async throws {
        #if DEBUG
        if fixture != nil { try await reload(); return }
        #endif
        let session = sessionGeneration, revision = UUID()
        snapshotGeneration = revision
        let base = workspace
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "ids", value: ids.sorted().joined(separator: ","))]
        let refresh: WorkspaceTitleRefresh = try await read("/api/workspace/titles?" + (query.percentEncodedQuery ?? ""))
        try Task.checkCancellation()
        guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
        guard Set(refresh.ids) == ids else { throw WorkspaceIntegrityError.incompleteSnapshot }
        let merging = Task.detached(priority: .userInitiated) { try refresh.merged(into: base) }
        let snapshot = try await merging.value
        try await publish(snapshot, session: session, revision: revision)
    }
    private func publish(_ snapshot: Workspace, session: UUID, revision: UUID) async throws {
        try Task.checkCancellation()
        guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
        let built = await buildIndex(snapshot)
        try Task.checkCancellation()
        guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
        publishIndexed(snapshot, built)
        hasLoadedWorkspace = true; showingCachedSnapshot = false; lastRefreshedAt = .now
        needsMutationRefresh = false
        if let scope = api.credential?.cacheScope {
            var cacheFailure: Error?
            do { try await cache.saveAsynchronously(snapshot, scope: scope, at: .now) }
            catch { cacheFailure = error }
            guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
            if let cacheFailure {
                if !(cacheFailure is CancellationError) { cacheWarning = "Your diary is loaded, but its protected offline copy could not be updated." }
            } else { cacheWarning = nil }
        }
    }
    private func readWorkspaceSnapshot() async throws -> Workspace {
        async let titles = api.allPages("titles", as: MediaTitle.self)
        async let episodes = api.allPages("episodes", as: Episode.self)
        async let events = api.allPages("events", as: WatchEvent.self)
        async let locations = api.allPages("locations", as: FileLocation.self)
        let values = try await (titles, episodes, events, locations)
        try Task.checkCancellation()
        // Identity validation builds sets over every row; keep it off the main actor.
        let validating = Task.detached(priority: .userInitiated) {
            try Workspace(titles: values.0, episodes: values.1, events: values.2, locations: values.3).validatingIdentities()
        }
        return try await validating.value
    }
    private func restoreCachedWorkspace() {
        guard let credential = api.credential, credential.isValid, !hasLoadedWorkspace else { return }
        if let snapshot = cache.residentSnapshot(scope: credential.cacheScope) {
            workspace = snapshot.workspace; hasLoadedWorkspace = true
            showingCachedSnapshot = true; lastRefreshedAt = snapshot.savedAt
            return
        }
        let session = sessionGeneration, revision = snapshotGeneration, scope = credential.cacheScope
        restoringCache = true
        cacheRestoration = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if session == self.sessionGeneration { self.restoringCache = false } }
            guard let snapshot = try? await self.cache.loadAsynchronously(scope: scope),
                  !Task.isCancelled, session == self.sessionGeneration, revision == self.snapshotGeneration,
                  !self.needsSignIn, !self.hasLoadedWorkspace, self.api.credential?.cacheScope == scope else { return }
            let built = await self.buildIndex(snapshot.workspace)
            guard !Task.isCancelled, session == self.sessionGeneration, revision == self.snapshotGeneration,
                  !self.needsSignIn, !self.hasLoadedWorkspace, self.api.credential?.cacheScope == scope else { return }
            self.publishIndexed(snapshot.workspace, built); self.hasLoadedWorkspace = true
            self.showingCachedSnapshot = true; self.lastRefreshedAt = snapshot.savedAt
        }
    }
    private func indexWorkspace() { apply(WorkspaceIndex(workspace), changed: nil) }
    /// Derived lookups for a snapshot are computed on a background executor. Card
    /// revision diffs are computed there too, against the inputs current at start;
    /// if those inputs changed meanwhile, `apply` recomputes the diff on the main actor.
    private func buildIndex(_ snapshot: Workspace) async -> (index: WorkspaceIndex, changed: Set<String>?) {
        let previous = cardInputs, token = cardInputsToken
        let work = Task.detached(priority: .userInitiated) { () -> (WorkspaceIndex, Set<String>) in
            let index = WorkspaceIndex(snapshot)
            return (index, index.changedTitles(since: previous))
        }
        let (index, changed) = await work.value
        return (index, token == cardInputsToken ? changed : nil)
    }
    private func publishIndexed(_ snapshot: Workspace, _ built: (index: WorkspaceIndex, changed: Set<String>?)) {
        publishingIndexedSnapshot = true
        workspace = snapshot
        publishingIndexedSnapshot = false
        apply(built.index, changed: built.changed)
    }
    private func apply(_ index: WorkspaceIndex, changed precomputed: Set<String>?) {
        cachedHome = nil; cachedStats = nil; titleScopes = [:]; cachedHistory = nil; cachedActiveEventCount = nil; cachedLibrary = nil
        titleIndex = index.titles
        progressIndex = index.progress
        seasonProgressIndex = index.seasonProgress
        episodesBySeason = index.episodesBySeason
        watchedEpisodesByTitle = index.watchedEpisodes
        let inputs = index.cardInputs
        let changed = precomputed ?? index.changedTitles(since: cardInputs)
        for id in changed { cardRevisions[id] = inputs[id] == nil ? nil : UUID() }
        cardInputs = inputs
        cachedCards = cachedCards.filter { cardRevisions[$0.key.titleID] == $0.key.revision }
        for (key, read) in cardReads where cardRevisions[key.titleID] != key.revision { read.task.cancel(); cardReads.removeValue(forKey: key) }
        presentTitleIDs = index.presentTitleIDs
    }
    /// Every row belonging to one title, as a small Workspace. The TwilDiaryCore
    /// selection helpers filter by title ID, so they return identical answers on
    /// this scope without scanning the whole diary on every SwiftUI body pass.
    func titleScope(_ id: String) -> Workspace {
        // Reading the observed workspace keeps the caller subscribed to changes.
        let snapshot = workspace
        if let saved = titleScopes[id] { return saved }
        let scope = Workspace(titles: titleIndex[id].map { [$0] } ?? [],
                              episodes: snapshot.episodes.filter { $0.titleId == id },
                              events: snapshot.events.filter { $0.titleId == id },
                              locations: snapshot.locations.filter { $0.titleId == id })
        if titleScopes.count >= 24 { titleScopes.removeAll(keepingCapacity: true) }
        titleScopes[id] = scope
        return scope
    }
    func title(_ id: String) -> MediaTitle? { titleIndex[id] }
    func episodesForSeason(_ titleID: String, season: Int) -> [Episode] { episodesBySeason[titleID]?[season] ?? [] }
    func watchedEpisodeIDs(_ titleID: String) -> Set<String> { watchedEpisodesByTitle[titleID] ?? [] }
    /// History rows for one filter state, reused until the diary or the filters change.
    /// The History body previously re-ran the full query (parse, de-duplicate, sort)
    /// on every update, including every scroll-triggered state change.
    func historyEntries(_ query: HistoryQuery, timeZone: TimeZone = .current) -> [HistoryEntry] {
        let snapshot = workspace
        if let saved = cachedHistory, saved.query == query, saved.zone == timeZone.identifier { return saved.value }
        let value = query.entries(in: snapshot, timeZone: timeZone)
        cachedHistory = (query, timeZone.identifier, value)
        return value
    }
    /// Filtered and sorted Library titles, reused across body passes until the diary or
    /// the filters change. A Trakt-score sort depends on ratings that arrive separately,
    /// so that one combination is always recomputed.
    func libraryTitles(_ query: LibraryQuery, source: PublicRatingSource) -> [MediaTitle] {
        let snapshot = workspace
        let cacheable = query.sort != .score || source == .tmdb
        if cacheable, let saved = cachedLibrary, saved.query == query, saved.source == source { return saved.value }
        let value = query.titles(in: snapshot) { self.publicScore($0, source: source) }
        if cacheable { cachedLibrary = (query, source, value) }
        return value
    }
    var activeEventCount: Int {
        let snapshot = workspace
        if let saved = cachedActiveEventCount { return saved }
        let value = snapshot.activeEvents.count
        cachedActiveEventCount = value
        return value
    }
    func homeProjection(at date: Date, calendar: Calendar = DiaryDate.calendar()) -> HomeProjection {
        // Reading the observed workspace keeps the view subscribed even on a
        // cache hit. Internal cache writes do not trigger another body pass.
        let snapshot = workspace, day = calendar.startOfDay(for: date)
        if let saved = cachedHome, saved.day == day, saved.calendar == calendar { return saved.value }
        let value = HomeProjection(overview: HomeOverview(workspace: snapshot, now: date, calendar: calendar),
            watching: snapshot.activeTitles.filter { $0.status == "watching" },
            recent: Array(HistoryQuery().entries(in: snapshot, timeZone: calendar.timeZone).prefix(4)))
        cachedHome = (day, calendar, value); return value
    }
    func statsProjection(period: Period, year: Int?, at date: Date, timeZone: TimeZone = .current) -> StatsOverview {
        let snapshot = workspace, day = DiaryDate.day(date, timeZone: timeZone)
        if let saved = cachedStats, saved.day == day, saved.zone == timeZone.identifier,
           saved.period == period, saved.year == year { return saved.value }
        let value = StatsOverview(workspace: snapshot, period: period, year: year, now: date, timeZone: timeZone)
        cachedStats = (day, timeZone.identifier, period, year, value); return value
    }
    func seasonProgress(_ title: MediaTitle, season: Int) -> SeasonProgress {
        seasonProgressIndex[title.id]?[season] ?? SeasonProgress.calculate(title: title, workspace: workspace, season: season)
    }
    func cachedCard(_ title: MediaTitle, season: Int? = nil) -> WatchCard? {
        guard !needsSignIn, let revision = cardRevisions[title.id] else { return nil }
        let key = CardKey(titleID: title.id, revision: revision, session: sessionGeneration, season: season, day: DiaryDate.day(now))
        return cachedCards[key]?.value
    }
    func libraryProgress(_ title: MediaTitle) -> Double { progressIndex[title.id] ?? 0 }
    func hasPresentLocation(_ titleID: String) -> Bool { presentTitleIDs.contains(titleID) }
    func browserCredential() -> AccessCredential? { api.credential }
    var quotaBlockedUntil: Date? { api.isQuotaBlocked ? api.quotaBlockedUntil : nil }
    func read<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> T {
        #if DEBUG
        if let fixture {
            let generation = sessionGeneration
            if method != "GET", ProcessInfo.processInfo.arguments.contains("--ui-slow-writes") {
                try await Task.sleep(for: .seconds(2))
                guard generation == sessionGeneration else { throw CancellationError() }
            }
            let value: T = try fixture.request(path, method: method, body: body)
            if method == "POST", path.hasSuffix("/watches"), ProcessInfo.processInfo.arguments.contains("--ui-refresh-failure") {
                failNextFixtureRefresh = true
            }
            return value
        }
        if isPreview { throw APIError.message("The browsing fixture is read-only.") }
        #endif
        let generation = sessionGeneration
        do {
            let value: T = try await api.request(path, method: method, body: body, timeout: timeout)
            guard generation == sessionGeneration else { throw CancellationError() }
            return value
        }
        catch {
            guard generation == sessionGeneration else { throw CancellationError() }
            if case APIError.signIn = error { fail(error) }
            throw error
        }
    }
    @discardableResult func trash(_ title: MediaTitle) async -> Bool {
        await perform(refreshing: [title.id]) {
            let result: TitleReceipt = try await self.read("/api/titles/\(title.id)", method: "DELETE", body: ["expectedVersion": title.version ?? 1])
            self.undoLabel = "Moved to Trash"
            self.undoAction = {
                let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/restore", method: "POST", body: ["expectedVersion": result.title.version])
            }
        }
    }
    @discardableResult func restore(_ title: MediaTitle) async -> Bool {
        await perform(refreshing: [title.id]) {
            let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/restore", method: "POST", body: ["expectedVersion": title.version ?? 1])
        }
    }
    let communityRatings = CommunityRatingsController()
    func publicScore(_ title: MediaTitle, source: PublicRatingSource) -> Double? {
        CommunityScore.value(tmdb: title.communityScore, trakt: communityRatings.entries[title.id], source: source)
    }
    func loadPublicRatings(_ titles: [MediaTitle], source: PublicRatingSource, retry: Bool = false) async {
        if retry { communityRatings.retryUnavailable() }
        guard source == .trakt, !needsSignIn else { return }
        let generation = sessionGeneration
        await communityRatings.prepare(titles.map(\.id)) { ids in
            #if DEBUG
            if self.isPreview {
                if ProcessInfo.processInfo.arguments.contains("--ui-ratings-unavailable") { return [:] }
                return Dictionary(uniqueKeysWithValues: ids.map { id in
                    (id, PublicRating(score: id == "again" ? 7.7 : nil, state: id == "again" ? "rated" : "unrated"))
                })
            }
            #endif
            do {
                let page: PublicRatingsPage = try await self.read(CatalogTools.apiPath("/api/library/ratings", query: ["ids": ids.joined(separator: ",")]), timeout: 8)
                guard generation == self.sessionGeneration else { throw CancellationError() }
                return page.ratings
            } catch APIError.signIn {
                guard generation == self.sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                self.communityRatings.reset()
                self.fail(APIError.signIn)
                // Authentication is handled by the app shell, never cached as a provider outage.
                throw CancellationError()
            }
        }
    }
    func card(_ title: MediaTitle, season: Int? = nil, fresh: Bool = false) async throws -> WatchCard {
        guard !needsSignIn, !Task.isCancelled else { throw CancellationError() }
        let key = CardKey(titleID: title.id, revision: cardRevisions[title.id] ?? snapshotGeneration, session: sessionGeneration, season: season, day: DiaryDate.day(now))
        if !fresh, let cached = cachedCards[key], Date.now.timeIntervalSince(cached.at) < 120 { return cached.value }
        let flight: (id: UUID, task: Task<WatchCard, Error>)
        if !fresh, let existing = cardReads[key] { flight = existing }
        else {
            flight = (UUID(), Task {
                #if DEBUG
                if self.isPreview { return PreviewData.card(title, workspace: self.workspace, season: season) }
                #endif
                var query = "?day=\(key.day)"
                if let season { query += "&season=\(season)" }
                return try await self.read("/api/glance/\(title.id)" + query)
            })
            cardReads[key] = flight
        }
        defer { if cardReads[key]?.id == flight.id { cardReads.removeValue(forKey: key) } }
        let value: WatchCard
        do { value = try await flight.task.value }
        catch {
            guard key.session == sessionGeneration, key.revision == (cardRevisions[title.id] ?? snapshotGeneration) else { throw CancellationError() }
            throw error
        }
        guard key.session == sessionGeneration, !needsSignIn,
              key.revision == (cardRevisions[title.id] ?? snapshotGeneration) else { throw CancellationError() }
        if cachedCards.count >= 128, let oldest = cachedCards.min(by: { $0.value.at < $1.value.at })?.key { cachedCards.removeValue(forKey: oldest) }
        cachedCards[key] = (.now, value)
        try Task.checkCancellation()
        return value
    }
    func loadSeason(_ title: MediaTitle, number: Int) async {
        await perform(refreshing: [title.id]) {
            let _: EmptyResponse = try await self.read("/api/titles/\(title.id)/seasons/\(number)/metadata", method: "POST")
        }
    }
    func markNext(_ title: MediaTitle, season: Int? = nil, expectedEpisode: String? = nil) async {
        await perform(cardID: title.id, cardAction: .mark) {
            let key = title.id
            if self.pendingWatches[key] == nil {
                let card = try await self.card(title, season: season, fresh: true)
                if let expectedEpisode, card.next?.id != expectedEpisode { throw APIError.message("Progress changed. Refresh this title before marking another episode.") }
                if title.isSeries && card.next == nil { throw APIError.message("No aired episode is ready to mark. Load this season’s episodes or choose another season.") }
                self.pendingWatches[key] = ["operationId": UUID().uuidString, "episodeId": card.next?.id as Any? ?? NSNull(), "watchedAt": self.now.ISO8601Format(), "rewatch": false]
            }
            let operation = self.pendingWatches[key]!
            let result: WatchReceipt
            do { result = try await self.read("/api/titles/\(title.id)/watches", method: "POST", body: operation) }
            catch { if Self.definitivelyRejected(error) { self.pendingWatches.removeValue(forKey: key) }; throw error }
            self.pendingWatches.removeValue(forKey: key)
            // Do not undo somebody else's pre-existing watch returned by an idempotent server response.
            if result.added || (result.event.operationId == operation["operationId"] as? String && result.event.version == 1 && result.event.revokedAt == nil) {
                self.undoLabel = "Watch marked"
                self.undoAction = { try await self.changeEvent(result.event, action: "revoke") }
            }
        }
    }
    func removeLatest(_ title: MediaTitle, season: Int? = nil, expected: WatchCard.Previous? = nil) async {
        await perform(cardID: title.id, cardAction: .remove) {
            if self.pendingRemovals[title.id] == nil {
                let card = try await self.card(title, season: season, fresh: true)
                guard let previous = card.previous else { return }
                if let expected, previous != expected { throw APIError.message("Watch history changed. Refresh this title before removing a watch.") }
                self.pendingRemovals[title.id] = previous
            }
            let event = self.pendingRemovals[title.id]!
            let result: EventReceipt
            do { result = try await self.read("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": "revoke", "expectedVersion": event.version]) }
            catch { if Self.definitivelyRejected(error) { self.pendingRemovals.removeValue(forKey: title.id) }; throw error }
            self.pendingRemovals.removeValue(forKey: title.id)
            self.undoLabel = "Watch removed"
            self.undoAction = { try await self.changeEvent(result.event, action: "restore") }
        }
    }
    private func changeEvent(_ event: WatchEvent, action: String) async throws {
        let _: EventReceipt = try await read("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": action, "expectedVersion": event.version ?? 1])
    }
    func pendingViewing(key: String, episode: String?, date: Date, rewatch: Bool) -> [String: Any] {
        if pendingWatches[key] == nil { pendingWatches[key] = ["operationId": UUID().uuidString, "episodeId": episode as Any? ?? NSNull(), "watchedAt": date.ISO8601Format(), "rewatch": rewatch] }
        return pendingWatches[key]!
    }
    func clearPendingViewing(key: String) { pendingWatches.removeValue(forKey: key) }
    func rejectPendingViewing(key: String, error: Error) { if Self.definitivelyRejected(error) { pendingWatches.removeValue(forKey: key) } }
    func rejectPendingSeason(key: String, error: Error) { if Self.definitivelyRejected(error) { pendingSeasonAdjustments.removeValue(forKey: key) } }
    @discardableResult func patch(_ title: MediaTitle, values: [String: Any], expectedVersion: Int? = nil) async -> Bool {
        await perform(refreshing: [title.id]) {
            var body = values; body["expectedVersion"] = expectedVersion ?? title.version
            let _: EmptyResponse = try await self.read("/api/titles/\(title.id)", method: "PATCH", body: body)
        }
    }
    @discardableResult func patchCard(_ titleID: String, values: [String: Any]) async -> Bool {
        await perform(cardID: titleID) {
            guard let title = self.title(titleID), title.deletedAt == nil else { throw APIError.message("This title is no longer in your library.") }
            var body = values; body["expectedVersion"] = title.version
            let _: EmptyResponse = try await self.read("/api/titles/\(titleID)", method: "PATCH", body: body)
        }
    }
    @discardableResult func setStatus(_ title: MediaTitle, status: String, watchedAt: Date? = nil) async -> Bool {
        if status != "planned" && status != "completed" { return await patch(title, values: ["status": status]) }
        return await perform(refreshing: [title.id]) { try await self.applyProgress([title], status: status, watchedAt: watchedAt ?? self.now) }
    }
    @discardableResult func manage(_ reviewed: [MediaTitle], change: CollectionChange) async -> Bool {
        await perform(refreshing: Set(reviewed.map(\.id))) {
            let request = try CollectionRequest(titles: reviewed, change: change)
            if case .status(let status) = change, ["planned", "completed"].contains(status) {
                try await self.applyProgress(reviewed, status: status, watchedAt: self.now)
            } else {
                guard let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] else { throw APIError.message("Invalid collection change.") }
                let receipt: CollectionReceipt = try await self.read("/api/titles/bulk", method: "POST", body: body)
                guard receipt.count == reviewed.count, Set(receipt.ids) == Set(reviewed.map(\.id)), receipt.action == change.action else { throw APIError.message("The selection response was incomplete. Refresh before trying again.") }
            }
        }
    }
    @discardableResult func emptyTrash() async -> Bool {
        await perform { let _: EmptyResponse = try await self.read("/api/trash", method: "DELETE", body: ["confirmation": "EMPTY_TRASH"]) }
    }
    private func applyProgress(_ reviewed: [MediaTitle], status: String, watchedAt: Date) async throws {
        let request = try CollectionRequest(titles: reviewed, change: .status(status))
        let ids = Set(reviewed.map(\.id)), key = status + ":" + ids.sorted().joined(separator: ",")
        if pendingProgress[key] == nil {
            if status == "completed" {
                for title in reviewed where title.isSeries {
                    for season in title.seasons ?? [] where season.number > 0 {
                        let fresh = title.tmdbId == nil || ((season.metadataVersion ?? 1) >= 2 && (DiaryDate.parse(season.metadataLoadedAt).map { self.now.timeIntervalSince($0) < 6 * 60 * 60 } ?? false))
                        if season.metadataLoadedAt == nil || !fresh {
                            let _: EmptyResponse = try await read("/api/titles/\(title.id)/seasons/\(season.number)/metadata", method: "POST")
                        }
                    }
                }
            }
            pendingProgress[key] = ["operationId": UUID().uuidString, "items": request.items.map { ["id": $0.id, "expectedVersion": $0.expectedVersion] as [String: Any] }, "status": status, "watchedAt": watchedAt.ISO8601Format(), "today": DiaryDate.day(now)]
        }
        let receipt: ProgressReceipt
        do { receipt = try await read("/api/progress/status", method: "POST", body: pendingProgress[key]) }
        catch { if Self.definitivelyRejected(error) { pendingProgress.removeValue(forKey: key) }; throw error }
        guard receipt.operationId == pendingProgress[key]?["operationId"] as? String else { throw APIError.message("The progress receipt did not match your request. Refresh before retrying.") }
        pendingProgress.removeValue(forKey: key)
        for id in ids {
            pendingWatches = pendingWatches.filter { $0.key != id && !$0.key.hasPrefix("viewing:" + id + ":") }
            pendingSeasonAdjustments = pendingSeasonAdjustments.filter { !$0.key.hasPrefix(id + ":") }; pendingRemovals.removeValue(forKey: id)
        }
        undoLabel = status == "planned" ? "Progress reset" : "Marked completed"
        let undoBody: [String: Any] = ["operationId": UUID().uuidString, "undoOf": receipt.operationId]
        undoAction = { let _: ProgressReceipt = try await self.read("/api/progress/status", method: "POST", body: undoBody) }
    }
    func undo() async {
        guard let action = undoAction else { return }
        await perform { try await action(); self.undoAction = nil; self.undoLabel = nil }
    }
    func dismissUndo() { undoLabel = nil; undoAction = nil }
    func installUndo(_ actions: [(event: WatchEvent, action: String)], label: String) {
        guard !actions.isEmpty else { return }
        undoLabel = label
        var remaining = actions
        undoAction = {
            while let next = remaining.first {
                try await self.changeEvent(next.event, action: next.action)
                remaining.removeFirst()
            }
        }
    }
    @discardableResult func perform(cardID: String? = nil, cardAction: CardAction = .menu, refreshing titleIDs: Set<String>? = nil, _ action: () async throws -> Void) async -> Bool {
        let scoped: Set<String>? = titleIDs ?? cardID.map { Set([$0]) }
        let generation = sessionGeneration
        if let cardID {
            guard cardActions[cardID] == nil, canMutate else { return false }
            cardActions[cardID] = cardAction
        }
        defer { if let cardID, generation == sessionGeneration { cardActions.removeValue(forKey: cardID) } }
        if cardID != nil {
            while busy && generation == sessionGeneration && !Task.isCancelled {
                await withCheckedContinuation { mutationWaiters.append($0) }
            }
        }
        guard generation == sessionGeneration, !Task.isCancelled, !needsSignIn, !busy, canMutate else { return false }
        snapshotGeneration = UUID()
        busy = true; defer { if generation == sessionGeneration { busy = false } }
        do {
            try await action()
            guard generation == sessionGeneration else { return false }
            // The action's receipt confirms the write. A later read failure cannot undo that fact.
            do {
                try await refreshAfterWrite(scoped)
                error = nil
            } catch {
                guard generation == sessionGeneration else { return false }
                needsMutationRefresh = true
                if case APIError.signIn = error { fail(error) }
                else { self.error = nil }
            }
            return true
        } catch is CancellationError { return false }
        catch {
            if generation == sessionGeneration {
                let failure = error
                if case APIError.signIn = failure { fail(failure) }
                else { try? await refreshAfterWrite(scoped); if generation == sessionGeneration { fail(failure) } }
            }
            return false
        }
    }
    /// Title-scoped writes refresh just those titles; anything else, or any doubt about
    /// the targeted read, falls back to the complete snapshot read.
    func refreshAfterWrite(_ titleIDs: Set<String>?) async throws {
        guard let titleIDs, !titleIDs.isEmpty, titleIDs.count <= Self.targetedRefreshLimit else { return try await reload() }
        do { try await reloadTitles(titleIDs) }
        catch let failure as APIError {
            // Sign-in, quota and connectivity failures would fail the full read too.
            // A rejected targeted read (for example an older backend without the
            // endpoint) still gets the complete snapshot read.
            guard case .rejected = failure else { throw failure }
            try await reload()
        }
        catch is CancellationError { throw CancellationError() }
        catch { try await reload() }
    }
    private static let targetedRefreshLimit = 50
    private func fail(_ cause: Error) {
        if case APIError.signIn = cause {
            retainedTraktController?.invalidateSession(); retainedTraktController = nil
            needsSignIn = true
        }
        error = cause.localizedDescription
    }
    private static func definitivelyRejected(_ cause: Error) -> Bool {
        guard let apiError = cause as? APIError, case .rejected(let status, _) = apiError else { return false }
        return (400..<500).contains(status) && ![408, 425, 429].contains(status)
    }
    private struct WatchReceipt: Decodable { let event: WatchEvent; let added: Bool }
    private struct EventReceipt: Decodable { let event: WatchEvent }
    private struct ProgressReceipt: Decodable { let operationId: String }
    private struct CollectionReceipt: Decodable { let ids: [String]; let action: String; let count: Int }
    private struct PublicRatingsPage: Decodable { let ratings: [String: PublicRating] }
    private struct TitleReceipt: Decodable {
        struct Identity: Decodable { let id: String; let version: Int }
        let title: Identity
    }
}

private struct WorkspaceCardInput: Equatable, Sendable {
    let title: MediaTitle
    let episodes: [Episode]
    let events: [WatchEvent]
}

/// Everything derived from one snapshot. Plain values only, so it can be built on a
/// background executor and handed to the main actor in one assignment.
private struct WorkspaceIndex: Sendable {
    let titles: [String: MediaTitle]
    let progress: [String: Double]
    let seasonProgress: [String: [Int: SeasonProgress]]
    let cardInputs: [String: WorkspaceCardInput]
    let presentTitleIDs: Set<String>
    let episodesBySeason: [String: [Int: [Episode]]]
    let watchedEpisodes: [String: Set<String>]
    init(_ workspace: Workspace) {
        let titles = Dictionary(workspace.titles.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let events = Dictionary(grouping: workspace.activeEvents, by: \.titleId)
        let episodes = Dictionary(grouping: workspace.episodes, by: \.titleId)
        self.titles = titles
        episodesBySeason = episodes.mapValues { rows in
            Dictionary(grouping: rows, by: \.season).mapValues { $0.sorted { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number } }
        }
        watchedEpisodes = events.mapValues { Set($0.compactMap(\.episodeId)) }
        progress = titles.mapValues { title in
            LibraryProgress.fraction(title: title, episodes: episodes[title.id] ?? [], activeEvents: events[title.id] ?? [])
        }
        seasonProgress = titles.mapValues { title in
            let rows = episodes[title.id] ?? []
            let scoped = Workspace(titles: [title], episodes: rows, events: events[title.id] ?? [])
            let seasons = Set(rows.map(\.season)).union(title.seasons?.map(\.number) ?? [])
            return Dictionary(uniqueKeysWithValues: seasons.map { ($0, SeasonProgress.calculate(title: title, workspace: scoped, season: $0)) })
        }
        cardInputs = titles.mapValues { title in
            WorkspaceCardInput(title: title, episodes: episodes[title.id] ?? [], events: events[title.id] ?? [])
        }
        presentTitleIDs = Set(workspace.locations.filter { $0.evidence == "present" }.map(\.titleId))
    }
    func changedTitles(since previous: [String: WorkspaceCardInput]) -> Set<String> {
        Set(previous.keys).union(cardInputs.keys).filter { previous[$0] != cardInputs[$0] }
    }
}

/// `GET /api/workspace/titles?ids=` — every row of the requested titles, read in one
/// consistent server batch. A requested ID that is absent was permanently deleted.
private struct WorkspaceTitleRefresh: Decodable, Sendable {
    let ids: [String]
    let titles: [MediaTitle]
    let episodes: [Episode]
    let events: [WatchEvent]
    let locations: [FileLocation]
    /// Replace exactly the requested titles' rows, keeping SQLite's BINARY id order
    /// (byte order) that complete snapshots use, then re-run the identity checks.
    func merged(into base: Workspace) throws -> Workspace {
        let requested = Set(ids)
        func merge<Row: Identifiable>(_ current: [Row], _ fresh: [Row], owner: (Row) -> String) -> [Row] where Row.ID == String {
            let kept = current.filter { !requested.contains(owner($0)) }
            let added = fresh.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
            var result: [Row] = []; result.reserveCapacity(kept.count + added.count)
            var i = 0, j = 0
            while i < kept.count && j < added.count {
                if added[j].id.utf8.lexicographicallyPrecedes(kept[i].id.utf8) { result.append(added[j]); j += 1 }
                else { result.append(kept[i]); i += 1 }
            }
            result.append(contentsOf: kept[i...]); result.append(contentsOf: added[j...])
            return result
        }
        guard titles.allSatisfy({ requested.contains($0.id) }),
              episodes.allSatisfy({ requested.contains($0.titleId) }),
              events.allSatisfy({ requested.contains($0.titleId) }),
              locations.allSatisfy({ requested.contains($0.titleId) }) else { throw WorkspaceIntegrityError.incompleteSnapshot }
        return try Workspace(titles: merge(base.titles, titles, owner: \.id),
                             episodes: merge(base.episodes, episodes, owner: \.titleId),
                             events: merge(base.events, events, owner: \.titleId),
                             locations: merge(base.locations, locations, owner: \.titleId)).validatingIdentities()
    }
}
