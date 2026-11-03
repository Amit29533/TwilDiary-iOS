import SwiftUI
import Observation
import Network
import CryptoKit
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
        BackgroundSyncCoordinator.shared.endBackgroundExecution()
        await flushOutbox()
        await pushProviderVaultToServer()
        guard retainedTraktController != nil || (!isPreview && PreferencesTraktApplyCheckpoint().runID != nil) else { return }
        let controller = traktController
        await controller.finishSuspendingTransfer()
        if !controller.busy { await controller.refresh(); await controller.resumeApprovedApply() }
    }
    func suspendTraktForBackground() {
        retainedTraktController?.suspendForBackground()
        BackgroundSyncCoordinator.shared.scheduleBackgroundTasks(hasPendingOutbox: !outbox.isEmpty)
    }
    /// Requests a background execution window on iOS while updating the Dynamic Island Live Activity,
    /// suspending cleanly when the OS background time expires.
    func continueSyncInBackground() {
        BackgroundSyncCoordinator.shared.scheduleBackgroundTasks(hasPendingOutbox: !outbox.isEmpty)
        BackgroundSyncCoordinator.shared.beginBackgroundExecution { [weak self] in
            self?.suspendTraktForBackground()
        }
    }
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
    /// Library asks for its list, its status counts and its genre counts on every update; keep a few.
    @ObservationIgnored private var cachedLibrary: [(query: LibraryQuery, source: PublicRatingSource, value: [MediaTitle])] = []
    @ObservationIgnored private var catalogLookup: (active: [String: Int], tmdb: [String: Int])?
    @ObservationIgnored private var cachedPersonSections: (person: Int, credits: Int, value: PersonSections)?
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
    @ObservationIgnored let animeNavigation = AnimeNavigationLookup()
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
    var writesBlocked: Bool { busy || replayingOutbox || needsMutationRefresh }
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
    private var undoAction: (() async throws -> Void)? { didSet { undoTitles = nil } }
    /// Titles an Undo changes, so it refreshes just those; nil means a complete diary read.
    private var undoTitles: Set<String>?
    private let api: DiaryAPI
    private let cache: any WorkspaceCaching
    private let outboxStore: any SyncOutboxStoring
    private let providerSettingsStore: any ProviderSettingsStoring
    private(set) var outbox = SyncOutboxQueue()
    private var confirmedWorkspace = Workspace()
    @ObservationIgnored private var connectivityMonitor: NWPathMonitor?
    private(set) var replayingOutbox = false
    private(set) var outboxNotice: String?
    private var savedLocallyInAction = false
    @ObservationIgnored private var directFlushActive = false
    var pendingDiaryEdits: Int { outbox.pending(for: .cloudflare).count }
    struct VaultDirtyField: Codable { let baseline: String; let generation: UUID }
    private var vaultDirty: [String: VaultDirtyField] = [:]
    private let vaultStateDefaults: UserDefaults?
    @ObservationIgnored private var vaultSyncTask: Task<Void, Never>?
    private var vaultSending = false
    private var vaultResolving = false
    var providerVaultBusy: Bool { vaultSending || vaultResolving }
    private(set) var providerVaultNotice: String?
    var providerSettings = ProviderConnectionSettings()
    @ObservationIgnored let directClient: DirectProviderClient
    @ObservationIgnored private var cacheRestoration: Task<Void, Never>?
    private(set) var restoringCache = false
    private var sessionGeneration = UUID()
    var sessionRevision: UUID { sessionGeneration }
    private var snapshotGeneration = UUID()
    private var lastForegroundRead: Date?
    /// The server's diary revision read just before the last complete foreground download.
    @ObservationIgnored private var knownWorkspaceRevision: (token: String, at: Date)?
    @ObservationIgnored private var knownDeltaCursor: String?
    @ObservationIgnored private var completeReads = 0
    /// Unconfirmed watch requests and their operation IDs. Saved on the phone (the app's own store
    /// only), so retrying after a restart reuses the ID and the server can't log the watch twice.
    private var pendingWatches: [String: [String: Any]] = [:] { didSet { savePendingWatches() } }
    @ObservationIgnored private var persistsPendingWatches = false
    private static let pendingWatchesKey = "pendingWatches.v1"
    private var pendingProgress: [String: [String: Any]] = [:]
    private var pendingRemovals: [String: WatchCard.Previous] = [:]
    var pendingSeasonAdjustments: [String: SeasonEditTransaction] = [:]
    let isPreview: Bool
    #if DEBUG
    private var fixture: FixtureDiaryBackend?
    private var failNextFixtureRefresh = false
    #endif
    var canMutate: Bool {
        guard !needsMutationRefresh, !replayingOutbox else { return false }
        #if DEBUG
        if isPreview { return fixture != nil }
        #endif
        return !isPreview
    }
    var now: Date { isPreview ? DiaryDate.parse("2026-10-23T12:00:00Z")! : .now }
    init(
        api: DiaryAPI? = nil,
        cache: (any WorkspaceCaching)? = nil,
        outboxStore: (any SyncOutboxStoring)? = nil,
        providerSettingsStore: (any ProviderSettingsStoring)? = nil,
        directClient: DirectProviderClient? = nil
    ) {
        self.api = api ?? DiaryAPI()
        self.vaultStateDefaults = api == nil ? .standard : nil
        self.directClient = directClient ?? DirectProviderClient()
        if let cache { self.cache = cache }
        else if api == nil { self.cache = ProtectedWorkspaceCache() }
        else { self.cache = MemoryWorkspaceCache() }
        if let outboxStore { self.outboxStore = outboxStore }
        else if api == nil { self.outboxStore = FileSyncOutboxStore() }
        else { self.outboxStore = MemorySyncOutboxStore() }
        self.providerSettingsStore = providerSettingsStore ?? UserDefaultsProviderSettingsStore()
        do { self.providerSettings = try self.providerSettingsStore.load() }
        catch { self.providerSettings = ProviderConnectionSettings(); self.error = error.localizedDescription }
        self.api.customTmdbToken = self.providerSettings.customTmdbToken
        self.api.customMdblistApiKey = self.providerSettings.mdblist.apiKey
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
            if ProcessInfo.processInfo.arguments.contains("--ui-profile-repairs") { workspace = PreviewData.profileRepairWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-arena"), let index = workspace.titles.firstIndex(where: { $0.deletedAt == nil }) { workspace.titles[index].tags = ["Weekend"] }
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
            if let scope = self.api.credential?.cacheScope {
                outbox = outboxStore.load(scope: scope)
            }
            if let scope = self.api.credential?.cacheScope,
               let data = vaultStateDefaults?.data(forKey: "providerVault.pending." + scope),
               let pending = try? JSONDecoder().decode([String: VaultDirtyField].self, from: data) { vaultDirty = Self.validVaultDirty(pending) }
            restoreCachedWorkspace()
            if api == nil { persistsPendingWatches = true; restorePendingWatches() }
        }
        indexWorkspace()
    }
    private func savePendingWatches() {
        guard persistsPendingWatches else { return }
        guard let scope = api.credential?.cacheScope, !pendingWatches.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["scope": scope, "items": pendingWatches] as [String: Any]) else {
            UserDefaults.standard.removeObject(forKey: Self.pendingWatchesKey); return
        }
        UserDefaults.standard.set(data, forKey: Self.pendingWatchesKey)
    }
    /// Only the signed-in diary's own requests, and none older than a week.
    private func restorePendingWatches() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingWatchesKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              saved["scope"] as? String == api.credential?.cacheScope,
              let items = saved["items"] as? [String: [String: Any]] else { pendingWatches = [:]; return }
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        pendingWatches = items.filter { (DiaryDate.parse($0.value["watchedAt"] as? String) ?? .distantPast) > cutoff }
    }
    func connect(_ credential: AccessCredential) async {
        vaultSyncTask?.cancel(); vaultSyncTask = nil
        cacheRestoration?.cancel(); cacheRestoration = nil; restoringCache = false
        let previousScope = api.credential?.cacheScope
        retainedTraktController?.invalidateSession(); retainedTraktController = nil
        let generation = UUID(); sessionGeneration = generation; snapshotGeneration = UUID()
        lastForegroundRead = nil; knownWorkspaceRevision = nil; knownDeltaCursor = nil
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
                outbox = outboxStore.load(scope: credential.cacheScope)
                vaultDirty = [:]
                if let data = vaultStateDefaults?.data(forKey: "providerVault.pending." + credential.cacheScope),
                   let pending = try? JSONDecoder().decode([String: VaultDirtyField].self, from: data) { vaultDirty = Self.validVaultDirty(pending) }
                pendingWatches.removeAll(); pendingProgress.removeAll(); pendingRemovals.removeAll(); pendingSeasonAdjustments.removeAll()
                undoLabel = nil; undoAction = nil
            }
            loading = false; busy = false
            needsSignIn = false; error = nil; restoreCachedWorkspace(); await refresh()
        } catch { if generation == sessionGeneration { fail(error) } }
    }
    func signOut() {
        BackgroundSyncCoordinator.shared.endLiveActivity()
        BackgroundSyncCoordinator.shared.endBackgroundExecution()
        vaultSyncTask?.cancel(); vaultSyncTask = nil; vaultDirty = [:]; providerVaultNotice = nil
        cacheRestoration?.cancel(); cacheRestoration = nil; restoringCache = false
        retainedTraktController?.invalidateSession(); retainedTraktController = nil
        if !isPreview { PreferencesTraktApplyCheckpoint().runID = nil }
        #if DEBUG
        fixture = nil
        failNextFixtureRefresh = false
        #endif
        sessionGeneration = UUID(); snapshotGeneration = UUID()
        lastForegroundRead = nil; knownWorkspaceRevision = nil; knownDeltaCursor = nil
        invalidateDiscovery()
        communityCache.reset()
        needsMutationRefresh = false
        Task { await PublicArtworkCache.shared.removeAll() }
        api.signOut(); workspace = Workspace(); communityRatings.reset(); cachedPeople = [:]; clearCards(); cardActions = [:]; resumeMutationWaiters(); hasLoadedWorkspace = false; error = nil
        showingCachedSnapshot = false; lastRefreshedAt = nil; loading = false; busy = false
        do { try cache.removeAll(); cacheWarning = nil }
        catch { cacheWarning = "The saved diary could not be removed. It remains encrypted on this device." }
        confirmedWorkspace = Workspace(); outboxNotice = nil
        outbox = SyncOutboxQueue(); try? outboxStore.removeAll()
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
        // One primary-key read decides whether the multi-page diary download is needed.
        let canUseDelta = hasLoadedWorkspace && !showingCachedSnapshot && !needsMutationRefresh
        let freshKnown = canUseDelta ? knownWorkspaceRevision.flatMap({ date.timeIntervalSince($0.at) < Self.revisionTrust ? $0 : nil }) : nil
        if let known = freshKnown, let cursor = knownDeltaCursor,
           await applyWorkspaceChanges(since: cursor, known: known.token, at: date) { return }
        let revision = await readWorkspaceRevision(known: freshKnown?.token)
        guard session == sessionGeneration, !Task.isCancelled else { return }
        if let revision, let known = knownWorkspaceRevision, known.token == revision.revision,
           date.timeIntervalSince(known.at) < Self.revisionTrust,
           canUseDelta { return }
        if let revision, canUseDelta, freshKnown != nil,
           let changedIds = revision.changedTitleIds, !changedIds.isEmpty, changedIds.count <= Self.targetedRefreshLimit {
            if let _ = try? await reloadTitles(Set(changedIds)) {
                guard session == sessionGeneration else { return }
                knownWorkspaceRevision = (token: revision.revision, at: date)
                error = nil
                return
            }
        }
        let reads = completeReads
        await refresh()
        // Remember the revision read before this download. A write that landed during it
        // changes the server's token, so the next resume downloads again.
        guard session == sessionGeneration else { return }
        knownWorkspaceRevision = completeReads != reads ? revision.map { (token: $0.revision, at: date) } : nil
    }
    /// Trust a matching revision for at most this long; then download in full anyway.
    private static let revisionTrust: TimeInterval = 6 * 3600
    private struct WorkspaceRevision: Decodable {
        let revision: String
        let changedTitleIds: [String]?
        let cursor: String?
    }
    /// nil when the check is unavailable (an older backend, offline, an unexpected reply):
    /// the caller then makes the complete download it always made.
    private func readWorkspaceRevision(since: Date? = nil, known: String? = nil) async -> WorkspaceRevision? {
        #if DEBUG
        if isPreview { return nil }
        #endif
        var path = "/api/workspace/revision"
        if let since {
            let stamp = since.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            var query: [String: String] = ["since": stamp]
            if let known { query["known"] = known }
            path = CatalogTools.apiPath(path, query: query)
        }
        guard let value: WorkspaceRevision = try? await read(path),
              value.revision.count == 32,
              value.revision.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        knownDeltaCursor = value.cursor
        return value
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
        completeReads &+= 1
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
        let base = confirmedWorkspace
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
        confirmedWorkspace = snapshot
        let projected = outbox.project(onto: snapshot)
        let projectedIndex = outbox.pending(for: .cloudflare).isEmpty ? built : await buildIndex(projected)
        publishIndexed(projected, projectedIndex)
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
            confirmedWorkspace = snapshot.workspace
            workspace = outbox.project(onto: snapshot.workspace); hasLoadedWorkspace = true
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
            self.confirmedWorkspace = snapshot.workspace
            let projected = self.outbox.project(onto: snapshot.workspace)
            let built = await self.buildIndex(projected)
            guard !Task.isCancelled, session == self.sessionGeneration, revision == self.snapshotGeneration,
                  !self.needsSignIn, !self.hasLoadedWorkspace, self.api.credential?.cacheScope == scope else { return }
            self.publishIndexed(projected, built); self.hasLoadedWorkspace = true
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
        cachedHome = nil; cachedStats = nil; cachedHighlights = nil; titleScopes = [:]; cachedHistory = nil; cachedActiveEventCount = nil; cachedLibrary = []; catalogLookup = nil; cachedPersonSections = nil
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
        if cacheable, let saved = cachedLibrary.first(where: { $0.query == query && $0.source == source }) { return saved.value }
        let value = query.titles(in: snapshot) { self.publicScore($0, source: source) }
        if cacheable { cachedLibrary = [(query, source, value)] + cachedLibrary.prefix(3) }
        return value
    }
    /// Same answer as `CatalogTools.libraryIdentity` (the first active title, in snapshot
    /// order, matching the server-linked id or the TMDB identity), from two dictionaries
    /// built once per snapshot instead of filtering the library for every catalog cell.
    func libraryIdentity(_ item: CatalogItem) -> String? {
        let snapshot = workspace
        let lookup: (active: [String: Int], tmdb: [String: Int])
        if let saved = catalogLookup { lookup = saved }
        else {
            var active: [String: Int] = [:], tmdb: [String: Int] = [:]
            for (order, title) in snapshot.titles.enumerated() where title.deletedAt == nil {
                if active[title.id] == nil { active[title.id] = order }
                if let id = title.tmdbId {
                    let key = (title.isSeries ? "tv:" : "movie:") + String(id)
                    if tmdb[key] == nil { tmdb[key] = order }
                }
            }
            lookup = (active, tmdb); catalogLookup = lookup
        }
        let linked = item.inLibraryId.flatMap { lookup.active[$0] }
        let matched = lookup.tmdb[(item.mediaType == .tv ? "tv:" : "movie:") + String(item.id)]
        guard let order = [linked, matched].compactMap({ $0 }).min() else { return nil }
        return snapshot.titles[order].id
    }
    /// Person shelves are read by three parts of the person screen; build them once.
    func personSections(_ person: PersonDetails) -> PersonSections {
        let snapshot = workspace
        if let saved = cachedPersonSections, saved.person == person.id, saved.credits == person.credits.count { return saved.value }
        let value = PersonSections(person: person, workspace: snapshot)
        cachedPersonSections = (person.id, person.credits.count, value)
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
    @ObservationIgnored private var cachedHighlights: (key: String, value: StatsHighlights)?
    /// Busiest day, top titles and averages for a Stats period. They sort every watch, so they're kept
    /// with the period's overview instead of being rebuilt on every Stats redraw (a chart tap included).
    func statsHighlights(_ overview: StatsOverview, period: Period, year: Int?, at date: Date) -> StatsHighlights {
        let zone = DiaryDate.calendar().timeZone
        let key = "\(DiaryDate.day(date, timeZone: zone))|\(zone.identifier)|\(period)|\(year ?? 0)"
        if let saved = cachedHighlights, saved.key == key { return saved.value }
        let value = StatsHighlights(workspace: workspace, trend: overview.trend, timeZone: zone)
        cachedHighlights = (key, value); return value
    }
    func seasonProgress(_ title: MediaTitle, season: Int) -> SeasonProgress {
        seasonProgressIndex[title.id]?[season] ?? SeasonProgress.calculate(title: title, workspace: workspace, season: season)
    }
    func cachedCard(_ title: MediaTitle, season: Int? = nil) -> WatchCard? {
        guard !needsSignIn, let revision = cardRevisions[title.id] else { return nil }
        let key = CardKey(titleID: title.id, revision: revision, session: sessionGeneration, season: season, day: DiaryDate.day(now))
        return cachedCards[key]?.value
    }
    /// Returns a server-confirmed WatchCard if cached, or calculates it locally from `workspace` without a network request.
    func localCard(_ title: MediaTitle, season: Int? = nil) -> WatchCard {
        cachedCard(title, season: season) ?? WatchCard.calculate(title: title, in: workspace, day: DiaryDate.day(now), season: season)
    }
    /// Persist first: a failed disk write must never look like a saved local edit.
    @discardableResult
    func enqueueOptimistic(_ mutation: OptimisticMutation, operationId: String = UUID().uuidString, providers: Set<SyncProviderKind> = [.cloudflare], uncertain: Bool = false) throws -> SyncOutboxEntry {
        guard let scope = api.credential?.cacheScope else { throw APIError.signIn }
        var next = outbox
        let entry = next.enqueue(SyncOutboxEntry(operationId: operationId, createdAt: now.ISO8601Format(), mutation: mutation, pendingProviders: providers, attempts: uncertain ? 1 : 0))
        try outboxStore.save(next, scope: scope)
        outbox = next
        // Apply just the new intent; a coalesced entry must not replay its old watch effects.
        workspace = outbox.project(onto: confirmedWorkspace)
        indexWorkspace()
        outboxNotice = "Saved on this device · \(pendingDiaryEdits) pending sync"
        return entry
    }
    func acknowledgeOutbox(_ entryID: String, provider: SyncProviderKind) throws {
        guard let scope = api.credential?.cacheScope else { throw APIError.signIn }
        var next = outbox
        next.acknowledge(entryID: entryID, provider: provider)
        try outboxStore.save(next, scope: scope)
        outbox = next
    }
    /// Updates the custom TMDB API Read Access Token and persists provider connection settings.
    @discardableResult func updateCustomTmdbToken(_ token: String?) -> Bool {
        var next = providerSettings
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.customTmdbToken = trimmed?.isEmpty == false ? trimmed : nil
        let previous = providerSettings
        guard persistProviderSettings(next) else { return false }
        invalidateDiscovery()
        stageVaultChanges(from: previous, to: next)
        return true
    }
    @discardableResult func updateProviderConfig(_ config: ExternalProviderConfig, syncVault: Bool = true) -> Bool {
        let previous = providerSettings
        var next = previous; next.setConfig(config)
        guard persistProviderSettings(next) else { return false }
        if syncVault { stageVaultChanges(from: previous, to: next) }
        return true
    }
    private func persistProviderSettings(_ next: ProviderConnectionSettings) -> Bool {
        do { try providerSettingsStore.save(next) }
        catch { error = error.localizedDescription; return false }
        providerSettings = next
        api.customTmdbToken = next.customTmdbToken
        api.customMdblistApiKey = next.mdblist.apiKey
        return true
    }
    struct ProviderVaultResponse: Decodable {
        struct Entry: Decodable {
            let enabled: Bool?
            let clientId: String?
            let accessToken: String?
            let apiKey: String?
            let username: String?
            let loggingMethod: WatchLoggingMethod?
        }
        struct Payload: Decodable {
            let customTmdbToken: String?
            let trakt: Entry?
            let wetrakr: Entry?
            let simkl: Entry?
            let mdblist: Entry?
            func entry(_ key: String) -> Entry? {
                switch key { case "trakt": trakt; case "wetrakr": wetrakr; case "simkl": simkl; case "mdblist": mdblist; default: nil }
            }
        }
        let protocolVersion: Int?
        let synced: Bool
        let revision: String?
        let settings: Payload?
    }
    private static let vaultPaths = ["customTmdbToken"] + ["trakt", "wetrakr", "simkl", "mdblist"].flatMap { provider in
        ["enabled", "clientId", "accessToken", "apiKey", "username", "loggingMethod"].map { provider + "." + $0 }
    }
    private static func validVaultDirty(_ fields: [String: VaultDirtyField]) -> [String: VaultDirtyField] {
        fields.filter { vaultPaths.contains($0.key) && $0.value.baseline.count == 64 && $0.value.baseline.allSatisfy { $0.isHexDigit } }
    }
    private func vaultValue(_ path: String, settings: ProviderConnectionSettings) -> Any {
        if path == "customTmdbToken" { return settings.customTmdbToken as Any? ?? NSNull() }
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count == 2, let provider = SyncProviderKind(rawValue: parts[0]) else { return NSNull() }
        let cfg = settings.config(for: provider)
        switch parts[1] {
        case "enabled": return cfg.enabled
        case "clientId": return cfg.clientId as Any? ?? NSNull()
        case "accessToken": return cfg.accessToken as Any? ?? NSNull()
        case "apiKey": return cfg.apiKey as Any? ?? NSNull()
        case "username": return cfg.username as Any? ?? NSNull()
        case "loggingMethod": return cfg.loggingMethod.rawValue
        default: return NSNull()
        }
    }
    private func vaultValue(_ path: String, remote: ProviderVaultResponse.Payload?) -> Any {
        if path == "customTmdbToken" { return remote?.customTmdbToken as Any? ?? NSNull() }
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return NSNull() }
        let entry = remote?.entry(parts[0])
        switch parts[1] {
        case "enabled": return entry?.enabled ?? false
        case "clientId": return entry?.clientId as Any? ?? NSNull()
        case "accessToken": return entry?.accessToken as Any? ?? NSNull()
        case "apiKey": return entry?.apiKey as Any? ?? NSNull()
        case "username": return entry?.username as Any? ?? NSNull()
        case "loggingMethod": return (entry?.loggingMethod ?? .serverAndDirectAPI).rawValue
        default: return NSNull()
        }
    }
    private func vaultHash(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func saveVaultDirty() {
        guard let scope = api.credential?.cacheScope, let data = try? JSONEncoder().encode(vaultDirty) else { return }
        vaultStateDefaults?.set(data, forKey: "providerVault.pending." + scope)
    }
    private func stageVaultChanges(from previous: ProviderConnectionSettings, to next: ProviderConnectionSettings) {
        guard !isPreview else { return }
        for path in Self.vaultPaths where vaultHash(vaultValue(path, settings: previous)) != vaultHash(vaultValue(path, settings: next)) {
            vaultDirty[path] = VaultDirtyField(baseline: vaultDirty[path]?.baseline ?? vaultHash(vaultValue(path, settings: previous)), generation: UUID())
        }
        saveVaultDirty()
        guard vaultSyncTask == nil else { return }
        vaultSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pushProviderVaultToServer()
            self.vaultSyncTask = nil
        }
    }
    func pushProviderVaultToServer() async {
        guard !isPreview, !needsSignIn, !vaultSending, !vaultResolving else { return }
        vaultSending = true; defer { vaultSending = false }
        let session = sessionGeneration
        while !vaultDirty.isEmpty, session == sessionGeneration, !Task.isCancelled {
            let pending = vaultDirty
            let desired = providerSettings
            do {
                let remote: ProviderVaultResponse = try await read("/api/providers/vault/v2")
                guard remote.protocolVersion == 2 else { throw APIError.message("Online settings sync requires an updated diary server. Device settings are unchanged.") }
                if remote.revision != nil && !remote.synced { throw APIError.message("Saved provider settings could not be decrypted. They have been preserved.") }
                var changes: [String: Any] = [:]
                for (path, field) in pending {
                    let wanted = vaultValue(path, settings: desired)
                    let remoteHash = vaultHash(vaultValue(path, remote: remote.settings))
                    guard remoteHash == field.baseline || remoteHash == vaultHash(wanted) else {
                        throw APIError.message("Provider settings changed on another device. Review which settings to keep.")
                    }
                    if path == "customTmdbToken" { changes[path] = wanted }
                    else {
                        let parts = path.split(separator: ".").map(String.init)
                        var entry = changes[parts[0]] as? [String: Any] ?? [:]
                        entry[parts[1]] = wanted; changes[parts[0]] = entry
                    }
                }
                let receipt: ProviderVaultResponse = try await read("/api/providers/vault/v2", method: "PUT", body: ["expectedRevision": remote.revision as Any? ?? NSNull(), "changes": changes])
                guard receipt.protocolVersion == 2, receipt.synced, receipt.revision != nil else { throw APIError.message("Online settings returned no confirmation. Sync remains pending.") }
                guard session == sessionGeneration else { return }
                for (path, field) in pending where vaultDirty[path]?.generation == field.generation { vaultDirty.removeValue(forKey: path) }
                saveVaultDirty(); providerVaultNotice = nil
            } catch {
                guard session == sessionGeneration else { return }
                providerVaultNotice = "Provider settings are saved on this device; online sync is pending. " + error.localizedDescription
                return
            }
        }
    }
    private func applyingVault(_ remote: ProviderVaultResponse.Payload?, paths: Set<String>, to original: ProviderConnectionSettings) -> ProviderConnectionSettings {
        var result = original
        for path in paths {
            let value = vaultValue(path, remote: remote)
            if path == "customTmdbToken" { result.customTmdbToken = value as? String; continue }
            let parts = path.split(separator: ".").map(String.init)
            guard parts.count == 2, let provider = SyncProviderKind(rawValue: parts[0]) else { continue }
            var config = result.config(for: provider)
            switch parts[1] {
            case "enabled": config.enabled = value as? Bool ?? false
            case "clientId": config.clientId = value as? String
            case "accessToken": config.accessToken = value as? String
            case "apiKey": config.apiKey = value as? String
            case "username": config.username = value as? String
            case "loggingMethod": config.loggingMethod = (value as? String).flatMap(WatchLoggingMethod.init(rawValue:)) ?? .serverAndDirectAPI
            default: break
            }
            result.setConfig(config)
        }
        return result
    }
    func pullProviderVaultFromServer() async {
        guard !isPreview, !needsSignIn else { return }
        do {
            let remote: ProviderVaultResponse = try await read("/api/providers/vault/v2")
            guard remote.synced else { return }
            // Existing local credentials are never replaced implicitly; dirty clears are never resurrected.
            let paths = Set(Self.vaultPaths.filter { path in
                guard vaultDirty[path] == nil else { return false }
                if path == "customTmdbToken" { return providerSettings.customTmdbToken == nil }
                let parts = path.split(separator: ".").map(String.init)
                guard parts.count == 2, let provider = SyncProviderKind(rawValue: parts[0]) else { return false }
                let current = providerSettings.config(for: provider)
                if !current.hasCredentials, !vaultDirty.keys.contains(where: { $0.hasPrefix(parts[0] + ".") }) { return true }
                if current.clientId != remote.settings?.entry(parts[0])?.clientId { return false }
                return vaultValue(path, settings: providerSettings) is NSNull
            })
            _ = persistProviderSettings(applyingVault(remote.settings, paths: paths, to: providerSettings))
            if !vaultDirty.isEmpty { await pushProviderVaultToServer() }
        } catch { providerVaultNotice = "Online provider settings are unavailable. Device settings are unchanged." }
    }
    func resolveProviderVaultConflict(keepDevice: Bool) async {
        guard !needsSignIn, !isPreview, !vaultSending, !vaultResolving else { return }
        vaultResolving = true; defer { vaultResolving = false }
        let selected = vaultDirty, session = sessionGeneration
        var shouldFlush = false
        do {
            let remote: ProviderVaultResponse = try await read("/api/providers/vault/v2")
            guard session == sessionGeneration else { return }
            guard remote.protocolVersion == 2 else { throw APIError.message("Update the diary server before syncing provider settings.") }
            guard remote.revision == nil || remote.synced else { throw APIError.message("Saved provider settings could not be decrypted.") }
            let paths = Set(selected.keys.filter { vaultDirty[$0]?.generation == selected[$0]?.generation })
            if keepDevice {
                for path in paths { vaultDirty[path] = VaultDirtyField(baseline: vaultHash(vaultValue(path, remote: remote.settings)), generation: UUID()) }
                saveVaultDirty(); shouldFlush = true
            } else {
                guard persistProviderSettings(applyingVault(remote.settings, paths: paths, to: providerSettings)) else { return }
                for path in paths { vaultDirty.removeValue(forKey: path) }
                saveVaultDirty(); providerVaultNotice = nil; shouldFlush = !vaultDirty.isEmpty
            }
        } catch { if session == sessionGeneration { providerVaultNotice = error.localizedDescription } }
        vaultResolving = false
        if shouldFlush { await pushProviderVaultToServer() }
    }
    /// Hosted imports publish only after the server confirms the merge. Offline imports never claim success.
    @discardableResult
    func importDiaryArchive(_ data: Data) async throws -> (titles: Int, events: Int) {
        guard !busy, !replayingOutbox, pendingDiaryEdits == 0 else { throw APIError.message("Sync pending edits before importing a diary.") }
        let session = sessionGeneration
        busy = true; defer { if session == sessionGeneration { busy = false } }
        let body: [String: Any]
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard !isPreview else { throw APIError.message("CSV import requires your online diary server.") }
            body = ["csv": text, "timeZone": TimeZone.current.identifier]
        } else {
            let archive = try await Task.detached(priority: .userInitiated) { try DiaryExport.decoded(from: data) }.value
            guard session == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
            if isPreview {
                workspace = try archive.merged(into: workspace); indexWorkspace()
                return (archive.titles.count, archive.events.count)
            }
            let encoded = try archive.encoded()
            guard let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw APIError.message("This diary archive is invalid.") }
            body = decoded
        }
        struct ImportReceipt: Decodable { let importedTitles: Int; let importedEvents: Int }
        let receipt: ImportReceipt = try await read("/api/workspace/import", method: "POST", body: body)
        do { try await reload() }
        catch { if session == sessionGeneration { needsMutationRefresh = true } }
        guard session == sessionGeneration else { throw CancellationError() }
        return (receipt.importedTitles, receipt.importedEvents)
    }
    /// Records a watch or title mutation for any enabled direct providers (`wetrakr`, `simkl`, `mdblist`, `trakt`)
    /// while keeping the primary server logging method intact, and flushes pending direct provider batches in the background.
    func recordDirectProviderMutation(_ mutation: OptimisticMutation, operationId: String = UUID().uuidString) {
        let activeProviders = providerSettings.activeDirectLoggingProviders
        guard !activeProviders.isEmpty, !outbox.pending(for: .cloudflare).contains(where: { $0.mutation.titleId == mutation.titleId }) else { return }
        guard let scope = api.credential?.cacheScope else { return }
        if case .patchTitle(_, _, let status, let score, let clearScore, let favorite, let queued, _, _) = mutation,
           status == nil, score == nil, !clearScore, favorite == nil, queued == nil { return }
        var next = outbox
        _ = next.enqueue(SyncOutboxEntry(operationId: operationId, createdAt: now.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), mutation: mutation, pendingProviders: activeProviders))
        do { try outboxStore.save(next, scope: scope); outbox = next }
        catch { self.error = "Provider delivery could not be saved: " + error.localizedDescription; return }
        Task { await flushDirectProviders() }
    }
    /// Flushes pending outbox mutations to all enabled and authenticated direct providers (`trakt`, `wetrakr`, `simkl`, `mdblist`).
    func flushDirectProviders() async {
        guard !directFlushActive, !needsSignIn else { return }
        let session = sessionGeneration
        directFlushActive = true; defer { directFlushActive = false }
        let activeProviders = providerSettings.activeDirectLoggingProviders
        guard !activeProviders.isEmpty else { return }
        for provider in activeProviders {
            let pending = outbox.pending(for: provider).filter { !$0.pendingProviders.contains(.cloudflare) }
            var completed = 0
            var blockedTitles = Set<String>()
            if !pending.isEmpty { BackgroundSyncCoordinator.shared.updateForProviderBatch(provider: provider, completed: 0, total: pending.count) }
            for entry in pending {
                if blockedTitles.contains(entry.mutation.titleId) { continue }
                let config = providerSettings.config(for: provider)
                let plan = ProviderDeliveryPlanner.plan(entry, provider: provider, in: workspace)
                do {
                    for delivery in plan.deliveries {
                        let key = provider.rawValue + ":" + delivery.key
                        guard let current = outbox.entries.first(where: { $0.id == entry.id }) else { break }
                        if current.confirmedActions?.contains(key) == true { continue }
                        if current.uncertainActions?.contains(key) == true { throw APIError.message("A previous history request needs reconciliation before retrying; no duplicate watch was sent.") }
                        if delivery.history { try persistDelivery(entryID: entry.id, key: key, confirmed: false) }
                        do { try await directClient.deliver(delivery, entry: entry, config: config) }
                        catch APIError.rejected(let status, let message) {
                            guard session == sessionGeneration, !Task.isCancelled else { return }
                            if (400..<500).contains(status) { try persistDelivery(entryID: entry.id, key: key, confirmed: false, rejected: true) }
                            throw APIError.rejected(status, message)
                        }
                        guard session == sessionGeneration, !Task.isCancelled else { return }
                        let currentConfig = providerSettings.config(for: provider)
                        guard config.clientId == currentConfig.clientId, config.accessToken == currentConfig.accessToken, config.apiKey == currentConfig.apiKey, currentConfig.enabled else {
                            throw APIError.message("The provider connection changed during delivery. Review pending edits before retrying.")
                        }
                        try persistDelivery(entryID: entry.id, key: key, confirmed: true)
                    }
                    if !plan.blocked.isEmpty { throw APIError.message(plan.blocked.joined(separator: " ")) }
                    guard !plan.deliveries.isEmpty else { throw APIError.message("This edit has no supported provider operation.") }
                    try acknowledgeOutbox(entry.id, provider: provider)
                    completed += 1
                    BackgroundSyncCoordinator.shared.updateForProviderBatch(provider: provider, completed: completed, total: pending.count, phase: completed == pending.count ? .completed : .flushingOutbox)
                    var updated = providerSettings.config(for: provider)
                    updated.lastSyncedAt = now.ISO8601Format()
                    updateProviderConfig(updated, syncVault: false)
                } catch {
                    guard session == sessionGeneration else { return }
                    BackgroundSyncCoordinator.shared.updateForProviderBatch(provider: provider, completed: completed, total: pending.count, phase: .failed)
                    var next = outbox
                    next.recordFailure(entryID: entry.id, error: error.localizedDescription)
                    if let scope = api.credential?.cacheScope {
                        do { try outboxStore.save(next, scope: scope); outbox = next }
                        catch { self.error = error.localizedDescription }
                    }
                    if error.localizedDescription == plan.blocked.joined(separator: " ") || error.localizedDescription.hasPrefix("A previous history request needs reconciliation") {
                        blockedTitles.insert(entry.mutation.titleId)
                        continue
                    }
                    // Transport/auth failures stop the provider; unsupported titles do not block unrelated titles.
                    break
                }
            }
        }
    }
    private func persistDelivery(entryID: String, key: String, confirmed: Bool, rejected: Bool = false) throws {
        guard let scope = api.credential?.cacheScope else { throw APIError.signIn }
        var next = outbox
        next.recordDelivery(entryID: entryID, key: key, confirmed: confirmed, rejected: rejected)
        try outboxStore.save(next, scope: scope)
        outbox = next
    }
    /// Tests an external provider's API credentials directly from the device (or simulates verification in UI preview mode).
    func testProviderConnection(_ config: ExternalProviderConfig) async throws {
        guard config.hasCredentials else {
            throw APIError.message("Enter the required API credentials before testing.")
        }
        #if DEBUG
        if isPreview { return }
        #endif
        switch config.provider {
        case .trakt:
            guard let clientId = config.clientId, !clientId.isEmpty,
                  let token = config.accessToken, !token.isEmpty else {
                throw APIError.message("Enter both a Trakt Client ID and Access Token to test direct API access.")
            }
            _ = try await directClient.fetchTraktLastActivities(
                credentials: DirectTraktCredentials(clientId: clientId, accessToken: token)
            )
        case .wetrakr:
            guard config.isAuthenticated else {
                throw APIError.message("Enter both a WeTrakr API Key and Access Token / PAT.")
            }
            _ = try await directClient.fetchWeTrakrActivities(config: config)
        case .simkl:
            guard config.isAuthenticated else {
                throw APIError.message("Enter both a Simkl Client ID and Access Token.")
            }
            _ = try await directClient.fetchSimklActivities(config: config)
        case .mdblist:
            guard let apiKey = config.apiKey, !apiKey.isEmpty else {
                throw APIError.message("Enter your MDBList API Key.")
            }
            _ = try await directClient.fetchMDBListRatings(apiKey: apiKey, tmdbId: 550, isSeries: false)
        case .cloudflare:
            break
        }
    }
    /// Restores or deterministically merges a `DiaryExport` JSON archive on-device (for standalone
    /// local mode, iCloud Drive backup sync, or cross-device recovery).
    func importArchive(_ data: Data, merge: Bool = true) throws {
        let archive = try DiaryExport.decoded(from: data)
        let updated = try (merge ? archive.merged(into: confirmedWorkspace) : archive.toWorkspace())
        confirmedWorkspace = updated
        workspace = outbox.project(onto: updated)
        hasLoadedWorkspace = true
        indexWorkspace()
        if let scope = api.credential?.cacheScope {
            try cache.save(updated, scope: scope, at: now)
        }
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
            if let mutation = queuedMutation(path, method: method, body: body),
               outbox.pending(for: .cloudflare).contains(where: { $0.mutation.titleId == mutation.titleId }) {
                return try localReceipt(mutation)
            }
            if method != "GET", pendingDiaryEdits > 0 {
                throw APIError.message("Sync your pending edits before making this change.")
            }
            let value: T = try await api.request(path, method: method, body: body, timeout: timeout)
            guard generation == sessionGeneration else { throw CancellationError() }
            return value
        }
        catch {
            guard generation == sessionGeneration else { throw CancellationError() }
            if case APIError.transport = error, hasLoadedWorkspace,
               let mutation = queuedMutation(path, method: method, body: body) {
                return try localReceipt(mutation, uncertain: true)
            }
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
            self.undoTitles = [title.id]
        }
    }
    @discardableResult func restore(_ title: MediaTitle) async -> Bool {
        await perform(refreshing: [title.id]) {
            let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/restore", method: "POST", body: ["expectedVersion": title.version ?? 1])
        }
    }
    @discardableResult func refreshTitleMetadata(_ title: MediaTitle) async -> Bool {
        guard title.tmdbId != nil else { return false }
        return await perform(refreshing: [title.id]) {
            let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/metadata", method: "POST")
        }
    }
    let communityRatings = CommunityRatingsController()
    func publicScore(_ title: MediaTitle, source: PublicRatingSource) -> Double? {
        CommunityScore.value(tmdb: title.communityScore, trakt: communityRatings.source == source ? communityRatings.entries[title.id] : nil, source: source)
    }
    func loadPublicRatings(_ titles: [MediaTitle], source: PublicRatingSource, retry: Bool = false) async {
        guard source == .trakt || source == .mdblist, !needsSignIn, !Task.isCancelled else { return }
        communityRatings.selectSource(source)
        if retry { communityRatings.retryUnavailable() }
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
                var query: [String: String] = ["ids": ids.joined(separator: ",")]
                if source == .mdblist { query["source"] = "mdblist" }
                let page: PublicRatingsPage = try await self.read(CatalogTools.apiPath("/api/library/ratings", query: query), timeout: 8)
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
        if pendingDiaryEdits > 0 { return localCard(title, season: season) }
        // The key changes with the title's episodes and watches (revision) and with the day, so a card stays
        // right for longer than the old 2 minutes; returning to Glance no longer refetches every card.
        if !fresh, let cached = cachedCards[key], Date.now.timeIntervalSince(cached.at) < 900 { return cached.value }
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
        catch APIError.transport(_) where hasLoadedWorkspace { return localCard(title, season: season) }
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
        var confirmed: WatchEvent?
        defer { if let confirmed { celebrate(confirmed, title: title) } }
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
            let opID = (operation["operationId"] as? String) ?? result.event.id
            self.recordDirectProviderMutation(
                .markWatch(
                    operationId: result.event.operationId,
                    titleId: title.id,
                    episodeId: result.event.episodeId,
                    watchedAt: result.event.watchedAt ?? result.event.recordedAt,
                    recordedAt: result.event.recordedAt,
                    rewatch: false
                ),
                operationId: opID
            )
            // Do not undo somebody else's pre-existing watch returned by an idempotent server response.
            if result.added || (result.event.operationId == operation["operationId"] as? String && result.event.version == 1 && result.event.revokedAt == nil) {
                self.undoLabel = "Watch marked"
                self.undoAction = { try await self.changeEvent(result.event, action: "revoke") }
                self.undoTitles = [title.id]
                confirmed = result.event
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
            self.recordDirectProviderMutation(
                .revokeWatch(
                    eventId: result.event.id,
                    titleId: title.id,
                    expectedVersion: event.version,
                    revokedAt: result.event.revokedAt ?? self.now.ISO8601Format()
                )
            )
            self.undoLabel = "Watch removed"
            self.undoAction = { try await self.changeEvent(result.event, action: "restore") }
            self.undoTitles = [title.id]
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
            self.recordDirectProviderMutation(
                .patchTitle(
                    titleId: title.id,
                    expectedVersion: expectedVersion ?? title.version,
                    status: values["status"] as? String,
                    score: values["score"] as? Double,
                    clearScore: values["score"] is NSNull,
                    favorite: values["favorite"] as? Bool,
                    queued: values["queued"] as? Bool,
                    notes: values["notes"] as? String
                )
            )
        }
    }
    @discardableResult func patchCard(_ titleID: String, values: [String: Any]) async -> Bool {
        await perform(cardID: titleID) {
            guard let title = self.title(titleID), title.deletedAt == nil else { throw APIError.message("This title is no longer in your library.") }
            var body = values; body["expectedVersion"] = title.version
            let _: EmptyResponse = try await self.read("/api/titles/\(titleID)", method: "PATCH", body: body)
            self.recordDirectProviderMutation(
                .patchTitle(
                    titleId: titleID,
                    expectedVersion: title.version,
                    status: values["status"] as? String,
                    score: values["score"] as? Double,
                    clearScore: values["score"] is NSNull,
                    favorite: values["favorite"] as? Bool,
                    queued: values["queued"] as? Bool,
                    notes: values["notes"] as? String
                )
            )
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
            if status == "completed" { try await prepareSeasonsForCompletion(reviewed) }
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
        undoTitles = ids
    }
    /// Completing a show needs every regular season's episode list. Only seasons that
    /// are missing, incomplete, in an old format, or possibly still airing with stale
    /// metadata are reloaded, four at a time. Previously every season older than six
    /// hours was reloaded one after another before the status request could start.
    private func prepareSeasonsForCompletion(_ titles: [MediaTitle]) async throws {
        let today = DiaryDate.day(now)
        let recent = DiaryDate.day(now.addingTimeInterval(-21 * 24 * 60 * 60))
        var needed: [(title: String, season: Int)] = []
        for title in titles where title.isSeries {
            for season in title.seasons ?? [] where season.number > 0 {
                let rows = episodesForSeason(title.id, season: season.number)
                let fresh = title.tmdbId == nil || ((season.metadataVersion ?? 1) >= 2 && (DiaryDate.parse(season.metadataLoadedAt).map { now.timeIntervalSince($0) < 6 * 60 * 60 } ?? false))
                let incomplete = season.expectedEpisodes.map { rows.count < $0 } ?? true
                let mayStillAir = rows.isEmpty || rows.contains { episode in
                    guard let aired = episode.airedOn else { return true }
                    return aired > today || aired >= recent
                }
                if season.metadataLoadedAt == nil || (!fresh && (incomplete || mayStillAir || (season.metadataVersion ?? 1) < 2)) {
                    needed.append((title.id, season.number))
                }
            }
        }
        guard !needed.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = needed.makeIterator(), running = 0
            while true {
                while running < 4, let next = queue.next() {
                    group.addTask {
                        let _: EmptyResponse = try await self.read("/api/titles/\(next.title)/seasons/\(next.season)/metadata", method: "POST")
                    }
                    running += 1
                }
                if running == 0 { break }
                _ = try await group.next()
                running -= 1
            }
        }
    }
    // MARK: Delight

    struct Celebration: Identifiable, Equatable { let id = UUID(); let milestone: Milestone }
    /// A milestone worth the starfall: a season or show finished, or a round number of watches.
    private(set) var celebration: Celebration?
    /// Round counts already celebrated this session: undo and mark again never repeats "100 watches".
    @ObservationIgnored private var celebratedCounts = Set<Int>()
    func dismissCelebration(_ id: UUID) { if celebration?.id == id { celebration = nil } }
    /// After a confirmed new watch. The refresh may not have brought the event back yet, so it is added here.
    func celebrate(_ event: WatchEvent, title: MediaTitle) {
        var snapshot = workspace
        if !snapshot.events.contains(where: { $0.id == event.id }) { snapshot.events.append(event) }
        guard let milestone = Milestone.after(event, title: title, workspace: snapshot) else { return }
        if case .watchCount(let count) = milestone { guard celebratedCounts.insert(count).inserted else { return } }
        celebration = Celebration(milestone: milestone)
    }
    func undo() async {
        celebration = nil
        guard let action = undoAction else { return }
        let titles = undoTitles
        await perform(refreshing: titles) {
            try await action(); self.undoAction = nil; self.undoLabel = nil
            // An undone season edit is over: its unfinished rest must not be offered as a retry.
            self.pendingSeasonAdjustments = self.pendingSeasonAdjustments.filter { entry in titles.map { !$0.contains { entry.key.hasPrefix($0 + ":") } } ?? false }
        }
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
        undoTitles = Set(actions.map(\.event.titleId))
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
        savedLocallyInAction = false
        busy = true; defer { if generation == sessionGeneration { busy = false } }
        do {
            try await action()
            guard generation == sessionGeneration else { return false }
            if savedLocallyInAction {
                undoLabel = "Saved on this device · waiting to sync"
                error = nil
                return true
            }
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

// Kept beside the store so private session and persistence guards cannot be bypassed.
extension DiaryStore {
    private func queuedMutation(_ path: String, method: String, body: [String: Any]?) -> OptimisticMutation? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "api", let body else { return nil }
        if parts.count >= 3, parts[1] == "titles", let title = title(parts[2]), title.deletedAt == nil {
            if parts.count == 3, method == "PATCH",
               Set(body.keys).isSubset(of: ["expectedVersion", "status", "score", "favorite", "queued", "notes", "tags"]),
               body["expectedVersion"] as? Int != nil {
                return .patchTitle(titleId: title.id, expectedVersion: body["expectedVersion"] as? Int,
                    status: body["status"] as? String, score: body["score"] as? Double,
                    clearScore: body["score"] is NSNull, favorite: body["favorite"] as? Bool,
                    queued: body["queued"] as? Bool, notes: body["notes"] as? String, tags: body["tags"] as? [String])
            }
            if parts.count == 4, parts[3] == "watches", method == "POST",
               let operation = body["operationId"] as? String, !operation.isEmpty,
               let watchedAt = body["watchedAt"] as? String, DiaryDate.parse(watchedAt) != nil {
                return .markWatch(operationId: operation, titleId: title.id, episodeId: body["episodeId"] as? String,
                    watchedAt: watchedAt, recordedAt: now.ISO8601Format(), rewatch: body["rewatch"] as? Bool ?? false)
            }
        }
        if parts.count == 3, parts[1] == "watch-events", method == "PATCH",
           let event = workspace.events.first(where: { $0.id == parts[2] }),
           let version = body["expectedVersion"] as? Int {
            if body["action"] as? String == "revoke" {
                return .revokeWatch(eventId: event.id, titleId: event.titleId, expectedVersion: version, revokedAt: now.ISO8601Format())
            }
            if body["action"] as? String == "restore" {
                return .restoreWatch(eventId: event.id, titleId: event.titleId, expectedVersion: version)
            }
        }
        return nil
    }

    private struct WorkspaceChangesReceipt: Decodable {
        let revision: String
        let cursor: String
        let fullRefreshRequired: Bool
        let ids: [String]
        let titles: [MediaTitle]
        let episodes: [Episode]
        let events: [WatchEvent]
        let locations: [FileLocation]
    }
    private func applyWorkspaceChanges(since: String, known: String, at date: Date) async -> Bool {
        let session = sessionGeneration
        do {
            let value: WorkspaceChangesReceipt = try await read(CatalogTools.apiPath("/api/workspace/changes", query: ["since": since, "known": known]))
            guard !value.fullRefreshRequired, value.ids.count <= Self.targetedRefreshLimit,
                  value.revision.count == 32, value.revision.allSatisfy({ "0123456789abcdef".contains($0) }),
                  DiaryDate.parse(value.cursor) != nil, session == sessionGeneration, !Task.isCancelled else { return false }
            if !value.ids.isEmpty {
                let delta = WorkspaceTitleRefresh(ids: value.ids, titles: value.titles, episodes: value.episodes, events: value.events, locations: value.locations)
                let snapshot = try delta.merged(into: confirmedWorkspace)
                let revision = UUID(); snapshotGeneration = revision
                try await publish(snapshot, session: session, revision: revision)
            }
            knownWorkspaceRevision = (token: value.revision, at: date)
            knownDeltaCursor = value.cursor
            error = nil
            return true
        } catch { return false } // Existing revision/full snapshot path supports older deployments.
    }

    func discardPendingEdits() async {
        guard !busy, !replayingOutbox, let scope = api.credential?.cacheScope else { return }
        let session = sessionGeneration
        replayingOutbox = true; defer { replayingOutbox = false }
        do {
            let snapshot = try await readWorkspaceSnapshot()
            guard session == sessionGeneration, !Task.isCancelled else { return }
            let next = SyncOutboxQueue(entries: outbox.entries.filter { !$0.pendingProviders.contains(.cloudflare) })
            try outboxStore.save(next, scope: scope)
            outbox = next
            let revision = UUID(); snapshotGeneration = revision
            try await publish(snapshot, session: session, revision: revision)
            outboxNotice = nil
        } catch { if session == sessionGeneration { fail(error) } }
    }
    func observeConnectivity() {
        guard connectivityMonitor == nil, !isPreview else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                await self?.flushOutbox()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.amit29533.TwilDiary.connectivity", qos: .utility))
        connectivityMonitor = monitor
    }
    private struct LocalWriteReceipt: Encodable { let title: MediaTitle?; let event: WatchEvent?; let added: Bool }
    private func localReceipt<T: Decodable>(_ mutation: OptimisticMutation, uncertain: Bool = false) throws -> T {
        let operation: String
        if case .markWatch(let id, _, _, _, _, _) = mutation { operation = id }
        else { operation = UUID().uuidString }
        // Never extend an ambiguous write by coalescing another patch into it.
        _ = try enqueueOptimistic(mutation, operationId: operation,
            providers: providerSettings.activeDirectLoggingProviders.union([.cloudflare]), uncertain: uncertain)
        let event: WatchEvent?
        switch mutation {
        case .markWatch(let id, let title, let episode, _, _, _):
            event = workspace.events.first { $0.operationId == id } ?? workspace.events.first { $0.titleId == title && $0.episodeId == episode && $0.revokedAt == nil }
        case .revokeWatch(let id, _, _, _), .restoreWatch(let id, _, _): event = workspace.events.first { $0.id == id }
        default: event = nil
        }
        let data = try JSONEncoder().encode(LocalWriteReceipt(title: title(mutation.titleId), event: event, added: event?.operationId == operation))
        let value = try JSONDecoder().decode(T.self, from: data)
        savedLocallyInAction = true
        return value
    }

    private func deliveryRequest(_ mutation: OptimisticMutation) throws -> (path: String, method: String, body: [String: Any]) {
        switch mutation {
        case .markWatch(let operation, let title, let episode, let watchedAt, _, let rewatch):
            return ("/api/titles/\(title)/watches", "POST", ["operationId": operation, "episodeId": episode as Any? ?? NSNull(), "watchedAt": watchedAt, "rewatch": rewatch])
        case .patchTitle(let title, let version, let status, let score, let clear, let favorite, let queued, let notes, let tags):
            var body: [String: Any] = [:]
            body["expectedVersion"] = version
            body["status"] = status; body["score"] = score; body["favorite"] = favorite
            body["queued"] = queued; body["notes"] = notes; body["tags"] = tags
            if clear { body["score"] = NSNull() }
            return ("/api/titles/\(title)", "PATCH", body)
        case .revokeWatch(let event, _, let version, _):
            return ("/api/watch-events/\(event)", "PATCH", ["action": "revoke", "expectedVersion": version])
        case .restoreWatch(let event, _, let version):
            return ("/api/watch-events/\(event)", "PATCH", ["action": "restore", "expectedVersion": version])
        default: throw APIError.message("This pending edit requires a newer app to sync.")
        }
    }

    /// Server delivery is serialized with UI writes. A conflict stops the chain without rebasing over another device.
    func flushOutbox() async {
        guard !replayingOutbox, !busy, !needsSignIn, !isPreview, !api.isQuotaBlocked,
              let scope = api.credential?.cacheScope else { return }
        let session = sessionGeneration
        replayingOutbox = true
        defer { replayingOutbox = false }
        while let entry = outbox.pending(for: .cloudflare).first {
            guard session == sessionGeneration, !Task.isCancelled else { return }
            do {
                let request = try deliveryRequest(entry.mutation)
                struct Receipt: Decodable { let title: TitleReceipt.Identity; let event: WatchEvent? }
                let receipt: Receipt?
                do { receipt = try await api.request(request.path, method: request.method, body: request.body) }
                catch APIError.rejected(let status, _) where status == 409 { receipt = nil }
                guard session == sessionGeneration, !Task.isCancelled else { return }
                let delta: WorkspaceTitleRefresh = try await api.request(CatalogTools.apiPath("/api/workspace/titles", query: ["ids": entry.mutation.titleId]))
                let authoritative = try delta.merged(into: confirmedWorkspace)
                guard let remote = authoritative.titles.first(where: { $0.id == entry.mutation.titleId }),
                      let version = remote.version else { throw APIError.message("This title changed on another device. Review the pending edit.") }
                if receipt == nil, !entry.mutation.isSatisfied(in: authoritative) {
                    throw APIError.message("This title changed on another device. Your pending edits are kept on this device; review them before retrying.")
                }
                let event = receipt?.event ?? authoritative.events.first { $0.operationId == entry.operationId }
                let next = outbox.confirming(entry, titleVersion: receipt?.title.version ?? version, event: event)
                guard session == sessionGeneration, !Task.isCancelled else { return }
                try outboxStore.save(next, scope: scope)
                outbox = next
                let revision = UUID(); snapshotGeneration = revision
                try await publish(authoritative, session: session, revision: revision)
                outboxNotice = pendingDiaryEdits > 0 ? "Saved on this device · \(pendingDiaryEdits) pending sync" : nil
            } catch {
                guard session == sessionGeneration else { return }
                var next = outbox
                next.recordFailure(entryID: entry.id, error: error.localizedDescription)
                do { try outboxStore.save(next, scope: scope); outbox = next }
                catch { outboxNotice = "Pending edits are kept on this device. Their sync status could not be saved."; return }
                outboxNotice = "\(pendingDiaryEdits) pending sync · \(error.localizedDescription)"
                if case APIError.signIn = error { fail(error) }
                return
            }
        }
        await flushDirectProviders()
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
