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
    var workspace = Workspace() { didSet { indexWorkspace() } }
    private var titleIndex: [String: MediaTitle] = [:]
    private var progressIndex: [String: Double] = [:]
    private var seasonProgressIndex: [String: [Int: SeasonProgress]] = [:]
    private var presentTitleIDs = Set<String>()
    private struct CardInput: Equatable {
        let title: MediaTitle
        let episodes: [Episode]
        let events: [WatchEvent]
    }
    private struct CardKey: Hashable {
        let titleID: String
        let revision: UUID
        let session: UUID
        let season: Int?
        let day: String
    }
    private var cardInputs: [String: CardInput] = [:]
    private var cardRevisions: [String: UUID] = [:]
    private var cachedCards: [CardKey: (at: Date, value: WatchCard)] = [:]
    private var cardReads: [CardKey: (id: UUID, task: Task<WatchCard, Error>)] = [:]
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
    @ObservationIgnored private var foregroundReadID: UUID?
    private var knownWorkspaceRevision: String?
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
        foregroundReadID = nil; knownWorkspaceRevision = nil
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
        guard !needsSignIn, !api.isQuotaBlocked, !loading, foregroundReadID == nil,
              foregroundReadDue(at: date) else { return }
        let session = sessionGeneration
        let ticket = UUID(); foregroundReadID = ticket
        defer { if foregroundReadID == ticket { foregroundReadID = nil } }
        while busy && session == sessionGeneration && !Task.isCancelled {
            await withCheckedContinuation { mutationWaiters.append($0) }
        }
        guard session == sessionGeneration, !Task.isCancelled, !api.isQuotaBlocked, !loading,
              foregroundReadDue(at: date) else { return }
        lastForegroundRead = date
        defer { if Task.isCancelled, session == sessionGeneration, lastForegroundRead == date { lastForegroundRead = nil } }
        let snapshot = snapshotGeneration
        loading = true; defer { if session == sessionGeneration { loading = false } }
        do {
            let revision = try await readWorkspaceRevision()
            guard session == sessionGeneration, snapshot == snapshotGeneration,
                  !Task.isCancelled else { return }
            if let revision, revision == knownWorkspaceRevision, hasLoadedWorkspace, !needsMutationRefresh {
                lastRefreshedAt = date; error = nil
                return
            }
            try await reload(expectedRevision: revision)
            if session == sessionGeneration { error = nil }
        } catch is CancellationError { }
        catch { if session == sessionGeneration { fail(error) } }
    }
    private func foregroundReadDue(at date: Date) -> Bool {
        if needsMutationRefresh { return lastForegroundRead.map { date.timeIntervalSince($0) >= 60 } ?? true }
        let latest = [lastForegroundRead, lastRefreshedAt].compactMap { $0 }.max()
        return latest.map { date.timeIntervalSince($0) >= 60 } ?? true
    }
    private struct WorkspaceRevisionResponse: Decodable { let revision: String }
    private func readWorkspaceRevision() async throws -> String? {
        #if DEBUG
        if fixture != nil || isPreview { return nil }
        #endif
        do {
            let value: WorkspaceRevisionResponse = try await api.request("/api/workspace/revision")
            guard value.revision.count == 32, value.revision.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw APIError.message("The diary freshness check returned an invalid revision.")
            }
            return value.revision
        } catch APIError.rejected(let status, _) where status == 404 {
            // Rolling deployment: old backends retain the bounded 60s full read.
            return nil
        }
    }
    func reload(expectedRevision: String? = nil) async throws {
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
        var snapshot: Workspace?
        var expected = expectedRevision
        for attempt in 0...1 {
            do {
                let value = try await readWorkspaceSnapshot()
                if let before = expected {
                    let after = try await readWorkspaceRevision()
                    guard session == sessionGeneration, revision == snapshotGeneration, !Task.isCancelled else { throw CancellationError() }
                    if after != before {
                        guard attempt == 0, let after else { throw APIError.message("Your diary changed during refresh. Your saved view is kept; refresh again.") }
                        expected = after
                        continue
                    }
                }
                snapshot = value
                break
            } catch WorkspaceIntegrityError.incompleteSnapshot {
                guard attempt == 0 else { throw WorkspaceIntegrityError.incompleteSnapshot }
                try Task.checkCancellation()
                guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
            }
        }
        guard let snapshot else { throw APIError.message("Your diary changed during refresh. Your saved view is kept; refresh again.") }
        try Task.checkCancellation()
        guard session == sessionGeneration, revision == snapshotGeneration, !needsSignIn else { throw CancellationError() }
        workspace = snapshot; hasLoadedWorkspace = true; showingCachedSnapshot = false; lastRefreshedAt = .now
        knownWorkspaceRevision = expected
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
        return try Workspace(titles: values.0, episodes: values.1, events: values.2, locations: values.3).validatingIdentities()
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
            self.workspace = snapshot.workspace; self.hasLoadedWorkspace = true
            self.showingCachedSnapshot = true; self.lastRefreshedAt = snapshot.savedAt
        }
    }
    private func indexWorkspace() {
        cachedHome = nil; cachedStats = nil
        titleIndex = Dictionary(workspace.titles.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let events = Dictionary(grouping: workspace.activeEvents, by: \.titleId)
        let episodes = Dictionary(grouping: workspace.episodes, by: \.titleId)
        progressIndex = titleIndex.mapValues { title in
            LibraryProgress.fraction(title: title, episodes: episodes[title.id] ?? [], activeEvents: events[title.id] ?? [])
        }
        seasonProgressIndex = titleIndex.mapValues { title in
            let rows = episodes[title.id] ?? []
            let scoped = Workspace(titles: [title], episodes: rows, events: events[title.id] ?? [])
            let seasons = Set(rows.map(\.season)).union(title.seasons?.map(\.number) ?? [])
            return Dictionary(uniqueKeysWithValues: seasons.map { ($0, SeasonProgress.calculate(title: title, workspace: scoped, season: $0)) })
        }
        let inputs = titleIndex.mapValues { title in CardInput(title: title, episodes: episodes[title.id] ?? [], events: events[title.id] ?? []) }
        let changed = Set(cardInputs.keys).union(inputs.keys).filter { cardInputs[$0] != inputs[$0] }
        for id in changed { cardRevisions[id] = inputs[id] == nil ? nil : UUID() }
        cardInputs = inputs
        cachedCards = cachedCards.filter { cardRevisions[$0.key.titleID] == $0.key.revision }
        for (key, read) in cardReads where cardRevisions[key.titleID] != key.revision { read.task.cancel(); cardReads.removeValue(forKey: key) }
        presentTitleIDs = Set(workspace.locations.filter { $0.evidence == "present" }.map(\.titleId))
    }
    func title(_ id: String) -> MediaTitle? { titleIndex[id] }
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
        await perform {
            let result: TitleReceipt = try await self.read("/api/titles/\(title.id)", method: "DELETE", body: ["expectedVersion": title.version ?? 1])
            self.undoLabel = "Moved to Trash"
            self.undoAction = {
                let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/restore", method: "POST", body: ["expectedVersion": result.title.version])
            }
        }
    }
    @discardableResult func restore(_ title: MediaTitle) async -> Bool {
        await perform {
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
        await perform {
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
        await perform {
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
        return await perform { try await self.applyProgress([title], status: status, watchedAt: watchedAt ?? self.now) }
    }
    @discardableResult func manage(_ reviewed: [MediaTitle], change: CollectionChange) async -> Bool {
        await perform {
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
    @discardableResult func perform(cardID: String? = nil, cardAction: CardAction = .menu, _ action: () async throws -> Void) async -> Bool {
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
                try await reload()
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
                else { try? await reload(); if generation == sessionGeneration { fail(failure) } }
            }
            return false
        }
    }
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
