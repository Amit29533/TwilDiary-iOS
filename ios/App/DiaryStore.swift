import SwiftUI
import Observation
import Network
import CryptoKit
import TwilDiaryCore

@MainActor @Observable final class DiaryStore {
    @ObservationIgnored private var retainedTraktController: TraktController?
    var traktController: TraktController {
        if let retainedTraktController { return retainedTraktController }
        let controller = TraktController(service: makeTraktService(store: self))
        retainedTraktController = controller
        return controller
    }
    func resumeTraktOnForeground() async {
        BackgroundSyncCoordinator.shared.endBackgroundExecution()
        await flushDirectProviders()
    }
    /// Any edit still on its way anywhere: the queue for the other services, or the service
    /// diary's own (Trakt, MDBList, WeTrakr).
    var hasWaitingEdits: Bool {
        !outbox.isEmpty || !TraktDirectStore.shared.pending.isEmpty || TrackerPreviewStore.shared.pending.values.contains { !$0.isEmpty }
    }
    func suspendTraktForBackground() {
        BackgroundSyncCoordinator.shared.scheduleBackgroundTasks(hasPendingOutbox: hasWaitingEdits)
    }
    struct HomeProjection: Sendable {
        let overview: HomeOverview
        let watching: [MediaTitle]
        let recent: [HistoryEntry]
    }
    struct HomeProjectionRequest: Equatable, Sendable {
        fileprivate let session: UUID
        fileprivate let workspaceRevision: UUID
        fileprivate let day: Date
        fileprivate let calendar: Calendar
    }
    private(set) var homeWorkspaceRevision = UUID()
    private(set) var homeProjection: HomeProjection?
    @ObservationIgnored private var preparedHome: (request: HomeProjectionRequest, workspace: Workspace)?
    @ObservationIgnored private var homeLoadID = UUID()
    @ObservationIgnored private var cachedStats: (day: String, zone: String, period: Period, year: Int?, value: StatsOverview)?
    /// Assigning a snapshot directly indexes it synchronously (tests, fixtures, sign-out).
    /// Network snapshots are indexed off the main actor first; see `publishIndexed`.
    var workspace = Workspace() {
        didSet {
            homeWorkspaceRevision = UUID()
            if !publishingIndexedSnapshot { indexWorkspace() }
        }
    }
    @ObservationIgnored private var publishingIndexedSnapshot = false
    @ObservationIgnored private var titleScopes: [String: Workspace] = [:]
    @ObservationIgnored private var cachedHistory: (query: HistoryQuery, zone: String, value: [HistoryEntry])?
    @ObservationIgnored private var cachedActiveEventCount: Int?
    /// Library asks for its list, its status counts and its genre counts on every update; keep a few.
    @ObservationIgnored private var cachedLibrary: [(query: LibraryQuery, source: PublicRatingSource, value: [MediaTitle])] = []
    /// The diary's titles and watches outside Trash, and the watches newest first, worked out once
    /// per diary change: screens read them on every redraw, and each read used to filter the whole
    /// diary again (and Profile sorted every watch).
    @ObservationIgnored private var cachedActive: (titles: [MediaTitle], events: [WatchEvent])?
    @ObservationIgnored private var cachedNewestFirst: [WatchEvent]?
    var activeTitles: [MediaTitle] { active.titles }
    var activeEvents: [WatchEvent] { active.events }
    var activeEventsNewestFirst: [WatchEvent] {
        // Read the diary's revision so a screen showing these is redrawn when the diary changes.
        _ = homeWorkspaceRevision
        if let cachedNewestFirst { return cachedNewestFirst }
        let value = active.events.sorted { ($0.watchedAt ?? $0.recordedAt) > ($1.watchedAt ?? $1.recordedAt) }
        cachedNewestFirst = value
        return value
    }
    private var active: (titles: [MediaTitle], events: [WatchEvent]) {
        _ = homeWorkspaceRevision
        if let cachedActive { return cachedActive }
        let titles = workspace.activeTitles, ids = Set(titles.map(\.id))
        let value = (titles, workspace.events.filter { $0.revokedAt == nil && ids.contains($0.titleId) })
        cachedActive = value
        return value
    }
    /// Library's genre shelves per query, kept like its titles: they were worked out on every redraw.
    @ObservationIgnored private var cachedShelves: [(query: LibraryQuery, source: PublicRatingSource, value: [LibraryShelf])] = []
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
    /// Why the read after a saved change failed ("HTTP 503", "offline"), shown on the notice.
    private(set) var mutationRefreshReason: String?
    @ObservationIgnored private var mutationRefreshRetry: Task<Void, Never>?
    var writesBlocked: Bool { busy || needsMutationRefresh }
    /// Trakt-first phase 4a: show the diary built from Trakt (read-only) instead of the server's.
    static let diarySourceKey = "diarySource"
    /// Titles only on Trakt already sent to the server diary this session (each tried once).
    @ObservationIgnored var adoptedTraktKeys = Set<String>()
    /// Titles whose adoption failed: how many tries, and when the next may run.
    @ObservationIgnored var adoptionRetry: [String: (tries: Int, after: Date)] = [:]
    @ObservationIgnored var adoptingTraktTitles = false
    static let phoneOnlyKey = "phoneOnlyDiary"
    /// Signed in with Trakt only (as Cinopsys works): no TwilDiary server session. The diary is
    /// built on the phone from Trakt and TMDB; what Trakt can't hold (tags, Queue, full notes,
    /// statuses, file folders, Trash, favourite people) is kept on the phone and in its backups.
    private(set) var phoneOnly = false
    /// The service a phone-only diary comes from (an older saved "true" means Trakt).
    static var savedPhoneOnly: MainTracker? {
        let value = UserDefaults.standard.object(forKey: phoneOnlyKey)
        if let name = value as? String { return MainTracker(rawValue: name) }
        return (value as? Bool) == true ? .trakt : nil
    }
    /// Which diary is on screen: "server", "trakt", "mdblist" or "wetrakr".
    var diarySource = UserDefaults.standard.string(forKey: DiaryStore.diarySourceKey) ?? "server" {
        didSet {
            UserDefaults.standard.set(diarySource, forKey: Self.diarySourceKey)
            applyDiarySource()
        }
    }
    var diaryFromTrakt: Bool {
        get { diarySource == "trakt" }
        set { diarySource = newValue ? "trakt" : "server" }
    }
    /// Phase 5: the diary built from MDBList or WeTrakr; edits go to it (TraktDiaryEditing).
    var diaryFromTracker: MainTracker? {
        get { MainTracker(rawValue: diarySource).flatMap { $0 == .trakt ? nil : $0 } }
        set { diarySource = newValue?.rawValue ?? "server" }
    }
    var mutationRefreshNotice: String? {
        needsMutationRefresh ? "Saved, but refreshing failed. Refresh your diary before making another change." : nil
    }
    var needsSignIn = true
    var hasLoadedWorkspace = false
    var error: String?
    private(set) var undoNoticeID = UUID()
    var undoLabel: String? { didSet { undoNoticeID = UUID() } }
    private var undoAction: (() async throws -> Void)? { didSet { undoTitles = nil } }
    /// Titles an Undo changes, so it refreshes just those; nil means a complete diary read.
    private var undoTitles: Set<String>?
    /// A server sign-in kept from when the diary lived on the server (moved to the phone at launch).
    private let sessionStorage: any SessionStoring
    private let outboxStore: any SyncOutboxStoring
    /// Token renewals under way, one per service.
    @ObservationIgnored private var renewals: [SyncProviderKind: Task<ExternalProviderConfig, Never>] = [:]
    private let providerSettingsStore: any ProviderSettingsStoring
    private(set) var outbox = SyncOutboxQueue()
    private var confirmedWorkspace = Workspace()
    /// The server's diary with pending edits, whichever diary is on screen (comparisons use this).
    @ObservationIgnored private var connectivityMonitor: NWPathMonitor?
    @ObservationIgnored private var directFlushActive = false
    var providerSettings = ProviderConnectionSettings()
    @ObservationIgnored let directClient: DirectProviderClient
    private var sessionGeneration = UUID() {
        didSet { clearHomeProjection() }
    }
    var sessionRevision: UUID { sessionGeneration }
    private var snapshotGeneration = UUID()
    private var lastForegroundRead: Date?
    /// The server's diary revision read just before the last complete foreground download.
    /// Unconfirmed watch requests and their operation IDs. Saved on the phone (the app's own store
    /// only), so retrying after a restart reuses the ID and the server can't log the watch twice.
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
    init(
        sessionStorage: (any SessionStoring)? = nil,
        outboxStore: (any SyncOutboxStoring)? = nil,
        providerSettingsStore: (any ProviderSettingsStoring)? = nil,
        directClient: DirectProviderClient? = nil
    ) {
        // Establish every immutable dependency before reading observed settings.
        #if DEBUG
        self.isPreview = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        self.isPreview = false
        #endif
        self.sessionStorage = sessionStorage ?? KeychainSessionStorage()
        self.directClient = directClient ?? DirectProviderClient()
        if let outboxStore { self.outboxStore = outboxStore }
        else if sessionStorage == nil { self.outboxStore = FileSyncOutboxStore() }
        else { self.outboxStore = MemorySyncOutboxStore() }
        #if DEBUG
        // UI tests run unsigned in the simulator, where the Keychain refuses writes; keep provider
        // settings in memory there instead of showing "could not be saved securely" on every screen.
        self.providerSettingsStore = providerSettingsStore ?? (isPreview ? MemoryProviderSettingsStore() : UserDefaultsProviderSettingsStore())
        #else
        self.providerSettingsStore = providerSettingsStore ?? UserDefaultsProviderSettingsStore()
        #endif
        do { self.providerSettings = try self.providerSettingsStore.load() }
        catch { self.providerSettings = ProviderConnectionSettings(); self.error = error.localizedDescription }
        if !isPreview { removeSimkl() }
        #if DEBUG
        if isPreview {
            workspace = PreviewData.workspace; needsSignIn = false; hasLoadedWorkspace = true
            if ProcessInfo.processInfo.arguments.contains("--ui-empty") { workspace = Workspace() }
            if ProcessInfo.processInfo.arguments.contains("--ui-title-metadata") { workspace = PreviewData.metadataWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-long-synopsis") { workspace = PreviewData.longSynopsisWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-upcoming") { workspace = PreviewData.upcomingWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-design-data") { workspace = PreviewData.designWorkspace; FavouritesStore.shared.seedForDesign(); error = nil }
            if ProcessInfo.processInfo.arguments.contains("--ui-many-titles") { workspace = PreviewData.withManyTitles(workspace) }
            if ProcessInfo.processInfo.arguments.contains("--ui-large-diary") { workspace = PreviewData.scaled(workspace) }
            if ProcessInfo.processInfo.arguments.contains("--ui-old-watches") { workspace = PreviewData.withOldWatches(workspace) }
            if ProcessInfo.processInfo.arguments.contains("--ui-on-this-day") { workspace = PreviewData.withAnniversaries(workspace, now: now) }
            if ProcessInfo.processInfo.arguments.contains("--ui-profile-repairs") { workspace = PreviewData.profileRepairWorkspace }
            if ProcessInfo.processInfo.arguments.contains("--ui-arena"), let index = workspace.titles.firstIndex(where: { $0.deletedAt == nil }) { workspace.titles[index].tags = ["Weekend"] }
            if ProcessInfo.processInfo.arguments.contains("--ui-long-episodes") { workspace = PreviewData.withLongEpisodeSummaries(workspace) }
            if ProcessInfo.processInfo.arguments.contains("--ui-signed-out") { needsSignIn = true; hasLoadedWorkspace = false }
            if ProcessInfo.processInfo.arguments.contains("--ui-mutations") { fixture = FixtureDiaryBackend(workspace: workspace) }
        }
        #endif
        if !isPreview {
            // Opens on the diary you keep: on this phone, or the service signed in on it. A server
            // sign-in kept from before moves the same way at launch (`leaveServerDiary`).
            needsSignIn = true
            if needsSignIn, TraktDirectStore.shared.localOnly {
                phoneOnly = true; needsSignIn = false; hasLoadedWorkspace = true
                loadPhoneOutbox()
                if diarySource != "trakt" { UserDefaults.standard.set("trakt", forKey: Self.diarySourceKey); diarySource = "trakt" }
                applyDiarySource()
            } else if needsSignIn, let tracker = Self.savedPhoneOnly, tracker == .trakt ? traktSignedInOnPhone : providerSettings.config(for: tracker.provider).isAuthenticated {
                phoneOnly = true; needsSignIn = false; hasLoadedWorkspace = true
                loadPhoneOutbox()
                if diarySource != tracker.rawValue { UserDefaults.standard.set(tracker.rawValue, forKey: Self.diarySourceKey); diarySource = tracker.rawValue }
                applyDiarySource()
            }
        }
        indexWorkspace()
    }
    /// Opens the app on Trakt alone: after a Trakt sign-in when your server can't be reached
    /// (Cloudflare Access in front of it), or by choice. Nothing is read from the server.
    /// "On this phone": no account at all. The diary lives in a file on this iPhone and every edit
    /// is made there; connect Trakt or your server later from Connections.
    func startOnThisPhone() async {
        // No server from here on: a sign-in kept from before would be tried first at every launch.
        sessionStorage.delete()
        TraktDirectStore.shared.useLocal(true)
        UserDefaults.standard.removeObject(forKey: Self.phoneOnlyKey)
        sessionGeneration = UUID(); snapshotGeneration = UUID()
        phoneOnly = true; error = nil
        confirmedWorkspace = Workspace(); hasLoadedWorkspace = true
        loadPhoneOutbox()
        if diarySource != "trakt" { diarySource = "trakt" } else { applyDiarySource() }
        needsSignIn = false
    }
    var onThisPhone: Bool { phoneOnly && TraktDirectStore.shared.localOnly }
    /// A server sign-in kept from before, when the diary lived on the server: it becomes the
    /// session for backups and extras, and the diary moves to the phone. At launch.
    func leaveServerDiary() async {
        guard !isPreview, !phoneOnly, let credential = sessionStorage.read() else { return }
        await signInWithServer(credential)
    }
    /// Where the queue of edits for the other services is kept: your server sign-in's, or with no
    /// server this iPhone's own (as Cinopsys keeps its queue on the device), so edits made in the
    /// Trakt-only diary still reach MDBList and WeTrakr.
    var outboxScope: String? { phoneOnly ? "phone" : nil }
    /// With no server: the phone's queue, loaded when the phone-only diary starts.
    private func loadPhoneOutbox() {
        guard let scope = outboxScope else { return }
        outbox = outboxStore.load(scope: scope)
        Task { await self.flushDirectProviders() }
    }
    func startPhoneOnly(_ tracker: MainTracker = .trakt) async {
        if TraktDirectStore.shared.localOnly { TraktDirectStore.shared.useLocal(false) }
        if tracker == .trakt { await PendingTraktSignIn.adopt(store: self) }
        let signedIn = tracker == .trakt ? traktSignedInOnPhone : providerSettings.config(for: tracker.provider).isAuthenticated
        guard signedIn else { error = "\(tracker.name) didn’t finish signing in. Try again."; return }
        // The service is the sign-in now: a server sign-in kept from before (one Cloudflare Access
        // refuses) would be tried first at every launch and ask to sign in again.
        sessionStorage.delete()
        UserDefaults.standard.set(tracker.rawValue, forKey: Self.phoneOnlyKey)
        sessionGeneration = UUID(); snapshotGeneration = UUID()
        phoneOnly = true; error = nil
        confirmedWorkspace = Workspace(); hasLoadedWorkspace = true
        loadPhoneOutbox()
        if diarySource != tracker.rawValue { diarySource = tracker.rawValue } else { applyDiarySource() }
        UserDefaults.standard.set(tracker.rawValue, forKey: MainTrackerView.key)
        needsSignIn = false
        await readService()
    }
    /// Phone-only: reads the service the diary comes from.
    private func readService() async {
        if let tracker = diaryFromTracker { await TrackerPreviewStore.shared.check(tracker, store: self) }
        else { await TraktDirectStore.shared.check(store: self) }
        applyDiarySource()
    }
    #if DEBUG
    /// Tests: the phone-only state without a real Trakt sign-in.
    func enterPhoneOnlyForTesting() { phoneOnly = true; needsSignIn = false; hasLoadedWorkspace = true }
    #endif
    func signOut() {
        if phoneOnly, TraktDirectStore.shared.localOnly {
            // On this phone: leaving keeps the diary (choose On this phone again to come back).
            phoneOnly = false
            TraktDirectStore.shared.useLocal(false)
        } else if phoneOnly {
            // The service was the sign-in: signing out ends it too.
            let tracker = Self.savedPhoneOnly ?? .trakt
            phoneOnly = false; UserDefaults.standard.removeObject(forKey: Self.phoneOnlyKey)
            if tracker == .trakt { Task { await self.signOutTraktOnPhone() } }
            else {
                var cleared = providerSettings.config(for: tracker.provider)
                cleared.accessToken = nil; cleared.refreshToken = nil; cleared.tokenExpiresAt = nil; cleared.enabled = false; cleared.connection = nil
                updateProviderConfig(cleared)
                TrackerPreviewStore.shared.forget()
            }
        }
        BackgroundSyncCoordinator.shared.endLiveActivity()
        BackgroundSyncCoordinator.shared.endBackgroundExecution()
        retainedTraktController?.invalidateSession(); retainedTraktController = nil
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
        URLCache.shared.removeAllCachedResponses()
        TraktDirectStore.shared.forget(); TrackerPreviewStore.shared.forget(); PhoneServerSync.shared.forget()
        adoptedTraktKeys = []; adoptionRetry = [:]
        sessionStorage.delete(); workspace = Workspace(); communityRatings.reset(); cachedPeople = [:]; clearCards(); cardActions = [:]; resumeMutationWaiters(); hasLoadedWorkspace = false; error = nil
        loading = false; busy = false
        confirmedWorkspace = Workspace()
        outbox = SyncOutboxQueue(); try? outboxStore.removeAll()
        pendingWatches.removeAll(); pendingProgress.removeAll(); pendingRemovals.removeAll(); undoAction = nil; undoLabel = nil
        pendingSeasonAdjustments.removeAll()
        needsSignIn = true
    }
    func refresh() async {
        guard !loading, !needsSignIn else { return }
        if phoneOnly {
            loading = true; defer { loading = false }
            await readService()
            return
        }
        #if DEBUG
        if isPreview && fixture == nil { return }
        #else
        if isPreview { return }
        #endif
        let session = sessionGeneration
        loading = true; defer { if session == sessionGeneration { loading = false } }
        guard session == sessionGeneration, !needsSignIn, !Task.isCancelled else { return }
        do { try await reload(); if session == sessionGeneration { error = nil } }
        catch is CancellationError { }
        catch { if session == sessionGeneration { fail(error) } }
    }
    /// Coming back to the app: the diary's service is read again (rapid scene changes coalesce).
    func refreshOnForeground(at date: Date = .now) async {
        guard !needsSignIn else { return }
        if phoneOnly { await refresh(); return }
        guard lastForegroundRead.map({ date.timeIntervalSince($0) >= 10 }) ?? true else { return }
        lastForegroundRead = date
        await refresh()
    }
    func reload() async throws {
        #if DEBUG
        if let fixture {
            if failNextFixtureRefresh {
                failNextFixtureRefresh = false
                throw APIError.message("Synthetic refresh outage")
            }
            // The test diary: kept as the confirmed copy too, or applyDiarySource() (which shows
            // pending edits on top of the confirmed copy) would show an empty diary.
            confirmedWorkspace = fixture.workspace
            workspace = fixture.workspace; hasLoadedWorkspace = true; needsMutationRefresh = false
        }
        #endif
        applyDiarySource()
    }
    /// The diary on screen: the server's (with pending edits on top), or the one built from Trakt
    /// with the server's extras. Reads Trakt first when there's no Trakt read yet.
    func applyDiarySource() {
        guard hasLoadedWorkspace else { return }
        if diaryFromTrakt {
            if let library = TraktDirectStore.shared.library {
                let server = confirmedWorkspace, titles = PhoneCatalog.shared.titles, episodes = PhoneCatalog.shared.episodes
                let extras = phoneOnly ? (PhoneExtras.shared.entries, PhoneExtras.shared.locations) : nil
                buildDiary {
                    // No server: the phone's extras (tags, Queue, full notes, statuses, files) take its place.
                    let record = extras.map { PhoneExtras.workspace($0.0, locations: $0.1, library: library, catalog: titles) } ?? server
                    return TraktDiary.addingCatalogEpisodes(TraktDiary.build(library: library, server: record, catalog: titles), catalog: episodes)
                }
            } else if !TraktDirectStore.shared.running {
                Task { await TraktDirectStore.shared.check(store: self) }
            }
        } else if let tracker = diaryFromTracker {
            if let library = TrackerPreviewStore.shared.libraries[tracker] {
                let server = confirmedWorkspace, titles = PhoneCatalog.shared.titles
                let extras = phoneOnly ? (PhoneExtras.shared.entries, PhoneExtras.shared.locations) : nil
                buildDiary {
                    let record = extras.map { PhoneExtras.workspace($0.0, locations: $0.1, library: library, catalog: titles) } ?? server
                    return TraktDiary.build(library: library, server: record, tracker: tracker, catalog: titles)
                }
            } else {
                workspace = outbox.project(onto: confirmedWorkspace)
                if TrackerPreviewStore.shared.running == nil { Task { await TrackerPreviewStore.shared.check(tracker, store: self) } }
            }
        } else {
            workspace = outbox.project(onto: confirmedWorkspace)
        }
    }
    /// Builds the diary from the service's copy away from the main thread (it reads every play),
    /// then shows it. A run of edits builds once: an older build still running is dropped. Previews
    /// and tests build at once, as before.
    private func buildDiary(_ make: @escaping @Sendable () -> Workspace) {
        diaryBuildTicket += 1
        let ticket = diaryBuildTicket
        diaryBuild?.cancel()
        // The first build after opening happens at once, under the splash, so Home opens complete.
        if isPreview || Self.runningTests || !builtFromService {
            builtFromService = true
            workspace = make(); fillServiceOnlyTitles(); return
        }
        // Later builds (every pull to refresh reads the service again) are built, compared and
        // indexed off the main thread: an unchanged diary is not published again, and a changed
        // one no longer re-indexes on the main thread while the page bounces back, which made
        // Home stutter for a moment on each pull.
        let current = workspace, revision = homeWorkspaceRevision
        diaryBuild = Task { [weak self] in
            let (built, same) = await Task.detached(priority: .userInitiated) { () -> (Workspace, Bool) in
                let built = make()
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let same = (try? encoder.encode(built)).map { $0 == (try? encoder.encode(current)) } ?? false
                return (built, same)
            }.value
            guard let self, !Task.isCancelled, ticket == self.diaryBuildTicket else { return }
            if !(same && revision == self.homeWorkspaceRevision) {
                let indexed = await self.buildIndex(built)
                guard !Task.isCancelled, ticket == self.diaryBuildTicket else { return }
                self.publishIndexed(built, indexed)
            }
            self.fillServiceOnlyTitles()
        }
    }
    @ObservationIgnored private var diaryBuild: Task<Void, Never>?
    @ObservationIgnored private var diaryBuildTicket = 0
    @ObservationIgnored private var builtFromService = false
    private static let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// Titles only on the service get their details on the phone (TMDB, with your key) instead of
    /// being copied into the server diary; without a key they still join the server, as before.
    private func fillServiceOnlyTitles() {
        PhoneCatalog.shared.prune(keeping: Set(workspace.titles.compactMap { title in title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } }))
        let missing = workspace.titles.filter { isServiceOnly($0) && $0.poster == nil }.map(\.id)
        // Episode lists for the shows in the diary, from TMDB on the phone.
        if phoneHoldsDiary {
            let shows = workspace.titles.filter { $0.isSeries && $0.deletedAt == nil }.compactMap { $0.tmdbId.map { "tv:" + String($0) } }
            Task { await PhoneCatalog.shared.fillEpisodes(shows, store: self) }
        }
        guard !missing.isEmpty else { return }
        if TMDBDirect.token(self) != nil { Task { await PhoneCatalog.shared.fill(missing, store: self) } }
        else if workspace.titles.contains(where: { isServiceOnly($0) && !adoptedTraktKeys.contains($0.id) }) {
            Task { await self.adoptServiceOnlyTitles() }
        }
    }
    /// Trakt holds the diary and the phone reads it (signed in here, with a TMDB key): episode
    /// lists come from TMDB on the phone.
    var phoneHoldsDiary: Bool { diaryFromTrakt && traktSignedInOnPhone && TMDBDirect.token(self) != nil }
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
        cachedStats = nil; cachedHighlights = nil; titleScopes = [:]; cachedHistory = nil; cachedActiveEventCount = nil; cachedLibrary = []; cachedShelves = []; cachedActive = nil; cachedNewestFirst = nil; catalogLookup = nil; cachedPersonSections = nil
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
    func libraryTitles(_ base: LibraryQuery, source: PublicRatingSource) -> [MediaTitle] {
        var query = base
        query.ignoreArticles = UserDefaults.standard.bool(forKey: "ignoreTitleArticles")
        let snapshot = workspace
        let cacheable = query.sort != .score || source == .tmdb
        if cacheable, let saved = cachedLibrary.first(where: { $0.query == query && $0.source == source }) { return saved.value }
        let value = query.titles(in: snapshot) { self.publicScore($0, source: source) }
        if cacheable { cachedLibrary = [(query, source, value)] + cachedLibrary.prefix(3) }
        return value
    }
    /// The query's titles grouped by genre (`LibraryShelf.make`), kept until the diary changes.
    func libraryShelves(_ base: LibraryQuery, source: PublicRatingSource) -> [LibraryShelf] {
        var query = base
        query.ignoreArticles = UserDefaults.standard.bool(forKey: "ignoreTitleArticles")
        let cacheable = query.sort != .score || source == .tmdb
        _ = homeWorkspaceRevision
        if cacheable, let saved = cachedShelves.first(where: { $0.query == query && $0.source == source }) { return saved.value }
        let value = LibraryShelf.make(libraryTitles(base, source: source))
        if cacheable { cachedShelves = [(query, source, value)] + cachedShelves.prefix(3) }
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
    func homeProjectionRequest(at date: Date, calendar: Calendar = DiaryDate.calendar()) -> HomeProjectionRequest {
        HomeProjectionRequest(session: sessionGeneration, workspaceRevision: homeWorkspaceRevision,
                              day: calendar.startOfDay(for: date), calendar: calendar)
    }
    func prepareHomeProjection(_ request: HomeProjectionRequest) async {
        guard !Task.isCancelled, request.session == sessionGeneration, request.workspaceRevision == homeWorkspaceRevision else { return }
        let loadID = UUID()
        homeLoadID = loadID
        let previous = preparedHome
        guard previous?.request != request else { return }
        let snapshot = Workspace(titles: workspace.titles, episodes: workspace.episodes, events: workspace.events)
        let work = Task.detached(priority: .userInitiated) { () -> HomeProjection? in
            // Comparing the rows can also be expensive. A no-op refresh keeps the
            // already published projection, avoiding a redraw while scrolling.
            if let previous, previous.request.day == request.day, previous.request.calendar == request.calendar,
               previous.workspace.titles == snapshot.titles, previous.workspace.episodes == snapshot.episodes,
               previous.workspace.events == snapshot.events { return nil }
            guard !Task.isCancelled else { return nil }
            let overview = HomeOverview(workspace: snapshot, now: request.day, calendar: request.calendar)
            guard !Task.isCancelled else { return nil }
            return HomeProjection(overview: overview, watching: snapshot.activeTitles.filter { $0.status == "watching" },
                                  recent: HistoryQuery().entries(in: snapshot, timeZone: request.calendar.timeZone, limit: 40))
        }
        let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        guard !Task.isCancelled, loadID == homeLoadID, request.session == sessionGeneration,
              request.workspaceRevision == homeWorkspaceRevision else { return }
        preparedHome = (request, snapshot)
        if let result { homeProjection = result }
    }
    private func clearHomeProjection() {
        homeLoadID = UUID()
        preparedHome = nil
        homeProjection = nil
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
    /// Simkl support was removed (owner's choice, 2026-11-13). Once: the provider settings are saved
    /// again (they're read without Simkl's entry, so its sign-in leaves the Keychain), along with the
    /// older per-field Keychain items; it's no longer the main tracker, the phone-only service or the
    /// diary's service; and the phone's copy of its library and reports go. Nothing on Simkl changes.
    private func removeSimkl() {
        let doneKey = "simkl.removed.v2"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        // Not saved (the Keychain refused): tried again next launch.
        guard (try? providerSettingsStore.save(providerSettings)) != nil else { return }
        let keychain = KeychainProviderSecretStore()
        for field in ["accessToken", "apiKey"] { _ = keychain.writeSecret(nil, for: "twildiary.provider.connection.settings.simkl." + field) }
        if defaults.string(forKey: Self.phoneOnlyKey) == "simkl" { defaults.removeObject(forKey: Self.phoneOnlyKey) }
        if defaults.string(forKey: MainTrackerView.key) == "simkl" { defaults.set(MainTracker.trakt.rawValue, forKey: MainTrackerView.key) }
        if diarySource == "simkl" { diarySource = "server" }
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appending(path: "Trackers/simkl.json"))
        for key in ["syncReport.simkl", "deadLetters.simkl", "matchLedger.simkl"] { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: doneKey)
    }
    func acknowledgeOutbox(_ entryID: String, provider: SyncProviderKind) throws {
        guard let scope = outboxScope else { throw APIError.signIn }
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
        guard persistProviderSettings(next) else { return false }
        invalidateDiscovery()
        return true
    }
    @discardableResult func updateProviderConfig(_ config: ExternalProviderConfig) -> Bool {
        var next = providerSettings; next.setConfig(config)
        return persistProviderSettings(next)
    }
    private func persistProviderSettings(_ next: ProviderConnectionSettings) -> Bool {
        do { try providerSettingsStore.save(next) }
        catch { self.error = error.localizedDescription; return false }
        providerSettings = next
        return true
    }
    /// Records a watch or title mutation for any enabled direct providers (`trakt`, `mdblist`, `wetrakr`)
    /// while keeping the primary server logging method intact, and flushes pending direct provider batches in the background.
    func recordDirectProviderMutation(_ mutation: OptimisticMutation, operationId: String = UUID().uuidString, providers: Set<SyncProviderKind>? = nil) {
        let isSeries = title(mutation.titleId)?.isSeries ?? true
        let activeProviders = providerSettings.activeDirectLoggingProviders.intersection(providers ?? providerSettings.activeDirectLoggingProviders)
            .filter { ProviderDeliveryPlanner.carries(mutation, provider: $0, isSeries: isSeries) }
        guard !activeProviders.isEmpty, !outbox.pending(for: .cloudflare).contains(where: { $0.mutation.titleId == mutation.titleId }) else { return }
        guard let scope = outboxScope else { return }
        if case .patchTitle(_, _, let status, let score, let clearScore, let favorite, let queued, _, _) = mutation,
           status == nil, score == nil, !clearScore, favorite == nil, queued == nil { return }
        var next = outbox
        _ = next.enqueue(SyncOutboxEntry(operationId: operationId, createdAt: now.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), mutation: mutation, pendingProviders: activeProviders))
        do { try outboxStore.save(next, scope: scope); outbox = next }
        catch { self.error = "Provider delivery could not be saved: " + error.localizedDescription; return }
        Task { await flushDirectProviders() }
    }
    /// Flushes pending outbox mutations to all enabled and authenticated direct providers (`trakt`, `mdblist`, `wetrakr`).
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
                let config = await freshProviderConfig(provider)
                guard session == sessionGeneration, !Task.isCancelled else { return }
                let plan = ProviderDeliveryPlanner.plan(entry, provider: provider, in: workspace)
                do {
                    for delivery in plan.deliveries {
                        let key = provider.rawValue + ":" + delivery.key
                        guard let current = outbox.entries.first(where: { $0.id == entry.id }) else { break }
                        if current.confirmedActions?.contains(key) == true { continue }
                        if current.uncertainActions?.contains(key) == true {
                            // The answer to an earlier send was lost: read the service and see.
                            switch await lostWriteArrived(provider, entry.mutation) {
                            case true?: try persistDelivery(entryID: entry.id, key: key, confirmed: true); continue
                            case false?: break  // not there: safe to send again (marked unsure again first)
                            case nil: throw APIError.message("A previous history request needs reconciliation before retrying; no duplicate watch was sent.")
                            }
                        }
                        if delivery.history { try persistDelivery(entryID: entry.id, key: key, confirmed: false) }
                        do { try await directClient.deliver(delivery, entry: entry, config: config) }
                        catch let unconfirmed as DirectProviderClient.DeliveryUnconfirmed {
                            guard session == sessionGeneration, !Task.isCancelled else { return }
                            // Nothing added, nothing refused. A rating or list change: it was already
                            // so. A watch: the service is read to see it's there before counting it.
                            if unconfirmed.history {
                                switch await lostWriteArrived(provider, entry.mutation) {
                                case true?: break
                                case false?: throw OutboxDeadLetter(reason: "\(provider.displayName) answered but didn’t keep this watch.")
                                case nil: throw APIError.message("\(provider.displayName) couldn’t be read to check this watch; it’s tried again later.")
                                }
                            }
                        }
                        catch APIError.rejected(let status, let message) {
                            guard session == sessionGeneration, !Task.isCancelled else { return }
                            // Busy (429) or timed out (408): kept for later, as Cinopsys leaves the batch queued.
                            // A sign-in problem stops this service until it's reconnected; any other
                            // refusal is final for this edit (set aside with its reason, the rest go on).
                            if (400..<500).contains(status), status != 429, status != 408 {
                                try persistDelivery(entryID: entry.id, key: key, confirmed: false, rejected: true)
                                if status != 401, status != 403 { throw OutboxDeadLetter(reason: message) }
                            }
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
                    // No deliveries and nothing blocked: this service keeps none of it, so it's done.
                    try acknowledgeOutbox(entry.id, provider: provider)
                    completed += 1
                    BackgroundSyncCoordinator.shared.updateForProviderBatch(provider: provider, completed: completed, total: pending.count, phase: completed == pending.count ? .completed : .flushingOutbox)
                    var updated = providerSettings.config(for: provider)
                    updated.lastSyncedAt = now.ISO8601Format()
                    updateProviderConfig(updated)
                } catch let deadLetter as OutboxDeadLetter {
                    // Cinopsys's dead letter: the service won't take it, so it's set aside where you can
                    // see why, and the edits behind it carry on.
                    guard session == sessionGeneration else { return }
                    setAside(entry, provider: provider, reason: deadLetter.reason)
                    continue
                } catch {
                    guard session == sessionGeneration else { return }
                    BackgroundSyncCoordinator.shared.updateForProviderBatch(provider: provider, completed: completed, total: pending.count, phase: .failed)
                    // Offline, a pause the service asked for, or a sign-in to renew: the edit waits
                    // and isn't counted. (Counted, a few edits made offline used up the first
                    // one's tries and set it aside before it was ever sent.)
                    if TraktDelivery.keepsWaiting(error) { break }
                    // A finite retry budget (as Cinopsys has): one that keeps failing is set aside
                    // instead of holding up every edit behind it.
                    if entry.attempts + 1 >= Self.outboxRetryBudget {
                        setAside(entry, provider: provider, reason: error.localizedDescription)
                        continue
                    }
                    var next = outbox
                    next.recordFailure(entryID: entry.id, error: error.localizedDescription)
                    if let scope = outboxScope {
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
    /// Tries an edit gets before it's set aside.
    static let outboxRetryBudget = 8
    /// An edit a service won't take: off its queue, and listed (with why) on its page.
    private func setAside(_ entry: SyncOutboxEntry, provider: SyncProviderKind, reason: String) {
        try? acknowledgeOutbox(entry.id, provider: provider)
        DeadLetters.add(provider, title: title(entry.mutation.titleId)?.name ?? entry.mutation.titleId, reason: reason)
    }
    private func persistDelivery(entryID: String, key: String, confirmed: Bool, rejected: Bool = false) throws {
        guard let scope = outboxScope else { throw APIError.signIn }
        var next = outbox
        next.recordDelivery(entryID: entryID, key: key, confirmed: confirmed, rejected: rejected)
        try outboxStore.save(next, scope: scope)
        outbox = next
    }
    /// The provider's settings, with a sign-in token renewed first when it is about to expire
    /// (a day ahead; 15 minutes for Trakt). One renewal at a time per service: callers arriving
    /// while it runs get its result, so a rotated refresh token is never spent twice. A failed
    /// renewal keeps the old token; the request then reports it.
    func freshProviderConfig(_ provider: SyncProviderKind) async -> ExternalProviderConfig {
        if let running = renewals[provider] { return await running.value }
        let task = Task { @MainActor in await self.renewProviderConfig(provider) }
        renewals[provider] = task
        let result = await task.value
        renewals[provider] = nil
        return result
    }
    private func renewProviderConfig(_ provider: SyncProviderKind) async -> ExternalProviderConfig {
        let config = providerSettings.config(for: provider)
        // Trakt through TwilDiary's server (signed in before phone sign-in existed): the server
        // keeps the refresh token and hands out a current one.
        let traktExpiry = config.tokenExpiresAt.flatMap { try? Date($0, strategy: .iso8601) }
        let traktDue = traktExpiry.map { $0.timeIntervalSince(now) < 86_400 } ?? true
        if provider == .trakt, config.connection == .signIn, config.refreshToken == nil, traktDue,
           let token: TraktDirectToken = try? await read("/api/trakt/token") {
            guard providerSettings.config(for: provider) == config else { return providerSettings.config(for: provider) }
            var renewed = config
            renewed.clientId = token.clientId; renewed.accessToken = token.accessToken
            renewed.tokenExpiresAt = Date(timeIntervalSince1970: token.expiresAt / 1000).ISO8601Format()
            return updateProviderConfig(renewed) ? renewed : config
        }
        guard config.needsRefresh(now: now), let clientId = config.clientId, let refresh = config.refreshToken else { return config }
        let tokens: ProviderDeviceSignIn.Tokens
        do { tokens = try await directClient.refreshSignIn(provider: provider, clientId: clientId, refreshToken: refresh) }
        catch ProviderRenewalError.signInEnded {
            // Spent or revoked: keep the settings (so pending edits stay) and ask for a new sign-in.
            if providerSettings.config(for: provider) == config { error = "\(provider.displayName) needs signing in again (Profile → Connections)." }
            return config
        } catch { return config }
        // Settings changed while renewing (disconnect, another sign-in): leave them alone.
        guard providerSettings.config(for: provider) == config else { return providerSettings.config(for: provider) }
        var renewed = config
        renewed.accessToken = tokens.accessToken
        renewed.refreshToken = tokens.refreshToken ?? refresh
        renewed.tokenExpiresAt = tokens.expiresAt
        // A renewed token stays on this iPhone; only a new sign-in changes what other devices see.
        return updateProviderConfig(renewed) ? renewed : config
    }
    /// Whether a watch whose answer was lost is on the service: true when its fresh copy shows the
    /// play, false when it doesn't, nil when the service couldn't be read just now.
    func lostWriteArrived(_ provider: SyncProviderKind, _ mutation: OptimisticMutation) async -> Bool? {
        guard let tracker = MainTracker(rawValue: provider.rawValue) else { return nil }
        let started = Date.now.addingTimeInterval(-1)
        let library: TraktLibrary?
        if tracker == .trakt {
            await TraktDirectStore.shared.check(store: self)
            library = TraktDirectStore.shared.library
        } else {
            await TrackerPreviewStore.shared.check(tracker, store: self)
            library = TrackerPreviewStore.shared.libraries[tracker]
        }
        guard let library, let fetched = library.fetchedAt.flatMap({ DiaryDate.parse($0) }), fetched >= started else { return nil }
        return LostWriteCheck.delivered(mutation, in: workspace, library: library)
    }
    /// Trakt signed in on this iPhone (its own refresh token in the Keychain), rather than through
    /// TwilDiary's server.
    var traktSignedInOnPhone: Bool {
        let config = providerSettings.config(for: .trakt)
        return config.connection == .signIn && config.refreshToken != nil && config.isAuthenticated
    }
    /// A current Trakt token: from this iPhone's own sign-in (renewed here when due), else from the
    /// server's connection (`GET /api/trakt/token`) for a sign-in made before.
    func traktToken() async throws -> TraktDirectToken {
        if traktSignedInOnPhone {
            let config = await freshProviderConfig(.trakt)
            guard let clientId = config.clientId, let access = config.accessToken else { throw APIError.message("Trakt isn’t connected.") }
            let expires = config.tokenExpiresAt.flatMap { try? Date($0, strategy: .iso8601) } ?? now.addingTimeInterval(3_600)
            return TraktDirectToken(accessToken: access, expiresAt: expires.timeIntervalSince1970 * 1000, clientId: clientId, username: config.username ?? "")
        }
        return try await read("/api/trakt/token")
    }
    /// Saves a Trakt sign-in made on this iPhone: checks which account it is first (a sign-in whose
    /// account can't be read is withdrawn, not kept), then turns Trakt on. Another account than
    /// before starts over, so nothing read or queued for the old one reaches it.
    func finishTraktPhoneSignIn(clientId: String, tokens: ProviderDeviceSignIn.Tokens) async throws {
        let username: String
        do { username = try await directClient.traktUsername(clientId: clientId, accessToken: tokens.accessToken) }
        catch {
            await directClient.revokeTrakt(clientId: clientId, token: tokens.accessToken)
            throw error
        }
        let before = providerSettings.config(for: .trakt)
        if let previous = before.username, previous.caseInsensitiveCompare(username) != .orderedSame { TraktDirectStore.shared.forget() }
        var signedIn = before
        signedIn.clientId = clientId; signedIn.accessToken = tokens.accessToken
        signedIn.refreshToken = tokens.refreshToken; signedIn.tokenExpiresAt = tokens.expiresAt
        signedIn.username = username; signedIn.connection = .signIn; signedIn.enabled = true
        if !signedIn.loggingMethod.includesDirectAPI { signedIn.loggingMethod = .serverAndDirectAPI }
        guard updateProviderConfig(signedIn) else { throw APIError.message(error ?? "The Trakt sign-in couldn’t be saved.") }
        TraktDirectStore.shared.dropToken()
    }
    /// Signs this iPhone out of Trakt: Trakt is told to end the sign-in, the tokens leave the
    /// Keychain, and the phone's Trakt copy is forgotten. Edits still waiting stay queued.
    func signOutTraktOnPhone() async {
        let config = providerSettings.config(for: .trakt)
        if let clientId = config.clientId, let token = config.accessToken {
            await directClient.revokeTrakt(clientId: clientId, token: token)
        }
        var cleared = config
        cleared.accessToken = nil; cleared.refreshToken = nil; cleared.tokenExpiresAt = nil
        cleared.enabled = false; cleared.connection = nil
        updateProviderConfig(cleared)
        TraktDirectStore.shared.forget()
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
        case .mdblist:
            guard config.isAuthenticated else {
                throw APIError.message("Sign in to MDBList or enter your MDBList API key.")
            }
            _ = try await directClient.fetchMDBListRatings(config: config, tmdbId: 550, isSeries: false)
        case .wetrakr:
            guard config.isAuthenticated else { throw APIError.message("Sign in to WeTrakr, or enter its app key and an access token.") }
            _ = try await directClient.read(config, path: "/sync/last_activities")
        case .cloudflare:
            break
        }
    }
    func libraryProgress(_ title: MediaTitle) -> Double { progressIndex[title.id] ?? 0 }
    func hasPresentLocation(_ titleID: String) -> Bool { presentTitleIDs.contains(titleID) }
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
        if phoneOnly {
            // Signed in to your server (Cloudflare): its own pages (usage, API keys, saved keys,
            // backups, Jellyfin's copy) and its fallbacks go through that sign-in. Never the diary:
            // it isn't on the server.
            let diaryOnly = ["/api/workspace", "/api/titles", "/api/watch-events", "/api/glance", "/api/progress/status", "/api/trash", "/api/favourites", "/api/trakt/sync"].contains { path.hasPrefix($0) }
            if ExtrasStorage.server, !diaryOnly {
                let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
                return try JSONDecoder().decode(T.self, from: try await PhoneServerSync.shared.send(path, method: method, body: data, store: self))
            }
            // Details, cast, lists and discovery come from TMDB on the phone when it has a key; the
            // server is only their backup. Without a key, the key is the fix, not a server.
            let tmdbBacked = ["/api/metadata", "/api/catalog", "/api/canvas", "/api/discovery", "/api/people", "/api/person", "/api/search", "/api/stats"].contains { path.hasPrefix($0) }
            throw APIError.message(tmdbBacked && TMDBDirect.token(self) == nil ? Self.needsTMDB : Self.needsServer)
        }
        // No diary on a server: nothing else asks it.
        throw APIError.message(Self.needsServer)
    }
    @discardableResult func trash(_ title: MediaTitle) async -> Bool {
        // No server: Trash is kept on the phone (the watches and the title leave the service).
        if phoneOnly { return await trashOnPhone(title) }
        // Everything "Remove from watch history" does comes first: the watches go too.
        if workspace.events.contains(where: { $0.titleId == title.id && $0.revokedAt == nil }) { await removeWatchHistory(title) }
        return await perform(refreshing: [title.id]) {
            // Trash is kept on your server: a title only on the service joins it first.
            let title = try await self.joinServer(title)
            let result: TitleReceipt = try await self.read("/api/titles/\(title.id)", method: "DELETE", body: ["expectedVersion": title.version ?? 1])
            // A service holds the diary: a Planned title leaves its watchlist too (Undo puts it back).
            let onService = self.diaryFromService || self.traktHoldsDiary
            if onService { try await self.serviceWatchlist([title], listed: false) }
            self.undoLabel = "Moved to Trash"
            self.undoAction = {
                let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/restore", method: "POST", body: ["expectedVersion": result.title.version])
                if onService { try await self.serviceWatchlist([title], listed: true) }
            }
            self.undoTitles = [title.id]
        }
    }
    @discardableResult func restore(_ title: MediaTitle) async -> Bool {
        if phoneOnly, PhoneTrash.shared.contains(title.id) {
            do { try await restoreOnPhone(title); return true } catch { self.error = error.localizedDescription; return false }
        }
        return await perform(refreshing: [title.id]) {
            let title = try await self.joinServer(title)
            let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/restore", method: "POST", body: ["expectedVersion": title.version ?? 1])
            if self.diaryFromService || self.traktHoldsDiary { try await self.serviceWatchlist([title], listed: true) }
        }
    }
    @discardableResult func refreshTitleMetadata(_ title: MediaTitle) async -> Bool {
        guard let tmdb = title.tmdbId else { return false }
        // No server: details and episodes from TMDB on the phone.
        if phoneOnly {
            guard TMDBDirect.token(self) != nil else { error = Self.needsTMDB; return false }
            let key = (title.isSeries ? "tv:" : "movie:") + String(tmdb)
            await PhoneCatalog.shared.fill([key], store: self, force: true)
            if title.isSeries { await PhoneCatalog.shared.fillEpisodes([key], store: self, force: true) }
            return true
        }
        return await perform(refreshing: [title.id]) {
            let _: TitleReceipt = try await self.read("/api/titles/\(title.id)/metadata", method: "POST")
        }
    }
    let communityRatings = CommunityRatingsController(folder: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? URL.cachesDirectory : nil, pause: 2)
    func publicScore(_ title: MediaTitle, source: PublicRatingSource) -> Double? {
        CommunityScore.value(tmdb: title.communityScore, trakt: communityRatings.source == source ? communityRatings.entries[title.id] : nil, source: source)
    }
    func loadPublicRatings(_ titles: [MediaTitle], source: PublicRatingSource, retry: Bool = false) async {
        guard source == .trakt || source == .mdblist, !needsSignIn, !Task.isCancelled else { return }
        communityRatings.selectSource(source)
        if retry { communityRatings.retryUnavailable() }
        let generation = sessionGeneration
        let direct = source == .mdblist && providerSettings.mdblist.isAuthenticated
        await communityRatings.prepare(titles.map(\.id), batch: direct ? 4 : 4, seconds: direct ? 240 : 12) { ids in
            #if DEBUG
            if self.isPreview {
                if ProcessInfo.processInfo.arguments.contains("--ui-ratings-unavailable") { return [:] }
                return Dictionary(uniqueKeysWithValues: ids.map { id in
                    (id, PublicRating(score: id == "again" ? 7.7 : nil, state: id == "again" ? "rated" : "unrated"))
                })
            }
            #endif
            // MDBList with your own sign-in: read straight from MDBList on the phone (as the title page
            // does). The server's MDBList read needs a server API key, which usually isn't set, so
            // every score came back empty and the Library showed none.
            if source == .mdblist, self.providerSettings.mdblist.isAuthenticated {
                let config = await self.freshProviderConfig(.mdblist)
                var result: [String: PublicRating] = [:], failures = 0
                var wanted: [(id: String, tmdb: Int, series: Bool)] = []
                for id in ids {
                    guard let title = self.title(id), let tmdb = title.tmdbId else { result[id] = PublicRating(score: nil, state: "unrated"); continue }
                    wanted.append((id, tmdb, title.isSeries))
                }
                // The batch at once (MDBList answers each title on its own), not one after another.
                let client = self.directClient
                let tasks = wanted.map { item in
                    Task { @MainActor () -> (String, PublicRating?) in
                        // MDBList asks us to slow down now and then (HTTP 429): wait and ask again.
                        var summary: MDBListSyncEngine.RatingSummary?
                        for attempt in 0..<3 where summary == nil {
                            do { summary = try await client.fetchMDBListRatings(config: config, tmdbId: item.tmdb, isSeries: item.series) }
                            catch APIError.rejected(let status, _) where status == 429 || status >= 500 {
                                try? await Task.sleep(for: .seconds(Double(2 << attempt)))
                            } catch APIError.rejected(let status, _) where status == 404 {
                                return (item.id, PublicRating(score: nil, state: "unrated"))
                            } catch { break }
                        }
                        guard let summary else { return (item.id, nil) }
                        let score = summary.aggregatedScore.map { $0 > 10 ? $0 / 10 : $0 }
                        return (item.id, score.map { $0 > 0 ? PublicRating(score: min(10, $0), state: "rated") : PublicRating(score: nil, state: "unrated") }
                            ?? PublicRating(score: nil, state: "unrated"))
                    }
                }
                var found: [(String, PublicRating?)] = []
                for task in tasks { found.append(await task.value) }
                if Task.isCancelled { throw CancellationError() }
                for (id, rating) in found { if let rating { result[id] = rating } else { failures += 1 } }
                guard generation == self.sessionGeneration else { throw CancellationError() }
                if failures > 0 && result.isEmpty { throw APIError.message("MDBList ratings are unavailable right now.") }
                return result
            }
            // Trakt with your sign-in: each title's rating straight from Trakt (search by TMDB id,
            // extended), four at a time, instead of the server asking Trakt for you.
            if source == .trakt, self.traktSignedInOnPhone, let client = try? await TraktDirectStore.shared.client(store: self) {
                var result: [String: PublicRating] = [:], failures = 0
                let wanted: [(id: String, tmdb: Int, type: String)] = ids.compactMap { id in
                    guard let title = self.title(id), let tmdb = title.tmdbId else { result[id] = PublicRating(score: nil, state: "unrated"); return nil }
                    return (id, tmdb, title.isSeries ? "show" : "movie")
                }
                for start in stride(from: 0, to: wanted.count, by: 4) {
                    let chunk = Array(wanted[start..<min(start + 4, wanted.count)])
                    let found = await withTaskGroup(of: (String, Double??).self) { group in
                        for item in chunk {
                            group.addTask {
                                guard let reply = try? await client.get("search/tmdb/\(item.tmdb)", query: ["type": item.type, "extended": "full"]),
                                      let rows = try? JSONSerialization.jsonObject(with: reply.data) as? [[String: Any]] else { return (item.id, nil) }
                                let media = rows.compactMap { $0[item.type] as? [String: Any] }.first { ($0["ids"] as? [String: Any])?["tmdb"] as? Int == item.tmdb }
                                return (item.id, .some((media?["rating"] as? Double).flatMap { $0 > 0 ? min(10, $0) : nil }))
                            }
                        }
                        var all: [(String, Double??)] = []
                        for await value in group { all.append(value) }
                        return all
                    }
                    for (id, score) in found {
                        guard let score else { failures += 1; continue }
                        result[id] = score.map { PublicRating(score: $0, state: "rated") } ?? PublicRating(score: nil, state: "unrated")
                    }
                    guard generation == self.sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                }
                if failures > 0 && result.isEmpty { throw APIError.message("Trakt ratings are unavailable right now.") }
                return result
            }
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
        if diarySource != "server" { return localCard(title, season: season) }
        let key = CardKey(titleID: title.id, revision: cardRevisions[title.id] ?? snapshotGeneration, session: sessionGeneration, season: season, day: DiaryDate.day(now))
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
        // No server: the phone's catalog reads the show's seasons from TMDB again.
        if phoneOnly {
            guard let tmdb = title.tmdbId, title.isSeries else { return }
            guard TMDBDirect.token(self) != nil else { error = Self.needsTMDB; return }
            await PhoneCatalog.shared.fillEpisodes(["tv:\(tmdb)"], store: self, force: true)
            return
        }
        await perform(refreshing: [title.id]) {
            let _: EmptyResponse = try await self.read("/api/titles/\(title.id)/seasons/\(number)/metadata", method: "POST")
        }
    }
    /// A watch added to the service the diary comes from: said, with no Undo. Undoing it there
    /// raced the send (the watch could be on its way, or already on the other services), so a
    /// watch logged by mistake is taken off with "Undo last watch" or from the title's history,
    /// which reach every service.
    func offerServiceUndo(_ title: MediaTitle, at when: String) {
        undoAction = nil
        undoLabel = "Watch marked"
    }
    func markNext(_ title: MediaTitle, season: Int? = nil, expectedEpisode: String? = nil) async {
        if diaryFromService {
            await perform(cardID: title.id, cardAction: .mark) {
                let card = self.localCard(title, season: season)
                if title.isSeries {
                    guard let next = card.next, let episode = self.workspace.episodes.first(where: { $0.id == next.id }) else {
                        throw APIError.message("No aired episode is ready to mark. Load this season’s episodes or choose another season.")
                    }
                    let when = try await self.serviceAddPlays(title, episodes: [(season: episode.season, number: episode.number)], at: self.now)
                    self.offerServiceUndo(title, at: when)
                } else {
                    let when = try await self.serviceAddPlays(title, episodes: [], at: self.now)
                    self.offerServiceUndo(title, at: when)
                }
            }
            return
        }
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
        if diaryFromService {
            await perform(cardID: title.id, cardAction: .remove) {
                let event = expected.flatMap { previous in self.workspace.activeEvents.first { $0.id == previous.id } }
                    ?? self.latestServiceEvent(titleID: title.id, any: true)
                guard let event else { throw APIError.message("There’s no watch to remove.") }
                try await self.serviceRemoveWatches([event])
            }
            return
        }
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
        if diaryFromService { return await perform(refreshing: [title.id]) { try await self.servicePatch(title, values: values) } }
        return await perform(refreshing: [title.id]) {
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
        if diaryFromService, let title = self.title(titleID) { return await perform(cardID: titleID) { try await self.servicePatch(title, values: values) } }
        return await perform(cardID: titleID) {
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
        if diaryFromService {
            return await perform(refreshing: [title.id]) { try await self.serviceSetStatus(title, status: status, watchedAt: watchedAt ?? self.now) }
        }
        if status != "planned" && status != "completed" { return await patch(title, values: ["status": status]) }
        return await perform(refreshing: [title.id]) { try await self.applyProgress([title], status: status, watchedAt: watchedAt ?? self.now) }
    }
    @discardableResult func manage(_ reviewed: [MediaTitle], change: CollectionChange) async -> Bool {
        // The phone's Trash: restore puts titles back, delete forever just forgets them here.
        if phoneOnly, change == .restore || change == .purge {
            if change == .purge { PhoneTrash.shared.remove(Set(reviewed.map(\.id))); return true }
            var all = true
            for title in reviewed { if await !restore(title) { all = false } }
            return all
        }
        if phoneOnly, case .queue(let queued) = change {
            // No server: the Queue is kept on this phone.
            for title in reviewed { PhoneExtras.shared.update(title, ["queued": queued]) }
            applyDiarySource()
            return true
        }
        if phoneOnly, change == .trash {
            var all = true
            for title in reviewed { if await !trash(title) { all = false } }
            return all
        }
        if diaryFromService {
            switch change {
            case .status(let status):
                return await perform(refreshing: Set(reviewed.map(\.id))) {
                    for title in reviewed { try await self.serviceSetStatus(title, status: status, watchedAt: self.now) }
                }
            case .favorite(let favourite):
                return await perform(refreshing: Set(reviewed.map(\.id))) {
                    for title in reviewed { try await self.servicePatch(title, values: ["favorite": favourite]) }
                }
            default:
                break
            }
        }
        // Trash, restore, delete and Queue are your server's: titles only on the service aren't there yet.
        let selected = reviewed.count
        let reviewed = diaryFromService ? reviewed.filter { !isServiceOnly($0) } : reviewed
        guard !reviewed.isEmpty else { error = "These titles are only on \(diaryService?.name ?? "Trakt") so far. They join your server diary on their own in a moment."; return false }
        let skipped = selected - reviewed.count
        // Say plainly when only part of the selection changed (the rest join the server diary soon).
        defer {
            if skipped > 0, error == nil {
                error = "\(reviewed.count) of \(selected) changed. \(skipped) \(skipped == 1 ? "is" : "are") only on \(diaryService?.name ?? "Trakt") so far and weren’t changed; they join your server diary on their own in a moment."
            }
        }
        return await perform(refreshing: Set(reviewed.map(\.id))) {
            let request = try CollectionRequest(titles: reviewed, change: change)
            if case .status(let status) = change, ["planned", "completed"].contains(status) {
                try await self.applyProgress(reviewed, status: status, watchedAt: self.now)
            } else {
                guard let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] else { throw APIError.message("Invalid collection change.") }
                let receipt: CollectionReceipt = try await self.read("/api/titles/bulk", method: "POST", body: body)
                guard receipt.count == reviewed.count, Set(receipt.ids) == Set(reviewed.map(\.id)), receipt.action == change.action else { throw APIError.message("The selection response was incomplete. Refresh before trying again.") }
                // A service holds the diary: Trash and Restore also update its watchlist.
                if self.diaryFromService || self.traktHoldsDiary, change == .trash || change == .restore {
                    try await self.serviceWatchlist(reviewed, listed: change == .restore)
                }
            }
        }
    }
    @discardableResult func emptyTrash() async -> Bool {
        if phoneOnly { PhoneTrash.shared.removeAll(); return true }
        return await perform { let _: EmptyResponse = try await self.read("/api/trash", method: "DELETE", body: ["confirmation": "EMPTY_TRASH"]) }
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
                mutationRefreshReason = Self.shortReason(error)
                if case APIError.signIn = error { fail(error) }
                else { self.error = nil; retryMutationRefreshSoon() }
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
    /// After a write: the diary is read again.
    func refreshAfterWrite(_ titleIDs: Set<String>?) async throws { try await reload() }
    /// The change was saved but the read after it failed: tried again a few times on its own
    /// (owner's report: the notice stayed up), so a brief failure clears without a tap.
    private func retryMutationRefreshSoon() {
        mutationRefreshRetry?.cancel()
        let session = sessionGeneration
        mutationRefreshRetry = Task { @MainActor [weak self] in
            for delay in [2.0, 6.0, 15.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, session == self.sessionGeneration, self.needsMutationRefresh else { return }
                do { try await self.reload() } catch { self.mutationRefreshReason = Self.shortReason(error); continue }
                if !self.needsMutationRefresh { self.mutationRefreshReason = nil; return }
            }
        }
    }
    /// A few words on why a read failed, for a small notice.
    static func shortReason(_ error: Error) -> String? {
        if let error = error as? APIError {
            switch error {
            case .rejected(let status, _): return "HTTP \(status)"
            case .databaseLimit: return "database limit"
            case .transport: return "offline"
            default: return nil
            }
        }
        if error is URLError { return "offline" }
        return nil
    }
    static let needsServer = "Your TwilDiary server does this, and it isn’t connected. Connect it in Profile → Connections if you want it."
    static let needsTMDB = "This needs your TMDB key. Add it in Profile → Connections → TMDB."
    private func fail(_ cause: Error) {
        if case APIError.signIn = cause, !phoneOnly {
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

extension DiaryStore {
    /// Back online: what waits for the other services (MDBList, WeTrakr, Trakt) goes.
    func observeConnectivity() {
        guard connectivityMonitor == nil, !isPreview else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                await self?.flushDirectProviders()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.amit29533.TwilDiary.connectivity", qos: .utility))
        connectivityMonitor = monitor
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


#if DEBUG
/// UI tests: provider settings kept in memory (unsigned simulator test builds have no Keychain access).
final class MemoryProviderSettingsStore: ProviderSettingsStoring, @unchecked Sendable {
    private var settings = ProviderConnectionSettings()
    func load() throws -> ProviderConnectionSettings { settings }
    func save(_ settings: ProviderConnectionSettings) throws { self.settings = settings }
}
#endif
