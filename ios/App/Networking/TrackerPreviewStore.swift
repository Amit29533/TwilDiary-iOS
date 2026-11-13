import Foundation
import Observation
import BackgroundTasks
import TwilDiaryCore

/// Work on a service's reply away from the main thread: a whole service library is megabytes of
/// JSON, and decoding it (or MDBList's and WeTrakr's pages) on the main thread froze scrolling for
/// a few hundred milliseconds at a time while the checks ran after the app opened.
private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

/// The same read-and-compare preview for MDBList and WeTrakr as the main tracker. Trakt keeps its own
/// store above (its lists are fetched one by one); these two are read whole when anything changed.
@MainActor @Observable final class TrackerPreviewStore {
    static let shared = TrackerPreviewStore()
    private(set) var libraries: [MainTracker: TraktLibrary] = [:]
    private(set) var reports: [MainTracker: TraktDirectStore.Report] = [:]
    private(set) var running: MainTracker?
    var errors: [MainTracker: String] = [:]
    private(set) var writing: MainTracker?
    private(set) var writeProgress: String? { didSet { if let writeProgress { MatchInBackground.shared.update(writeProgress) } } }
    private(set) var writeResults: [MainTracker: String] = [:]
    /// Each service's plan from its last read (see `TraktDirectStore.plan`).
    private(set) var plans: [MainTracker: TraktWritePlan] = [:]
    /// Changes on sign-out (see `TraktDirectStore.generation`).
    @ObservationIgnored private var generation = UUID()
    /// Reads that came back and replaced the copy here (see `TraktDirectStore.readCount`).
    @ObservationIgnored private var readCounts: [MainTracker: Int] = [:]
    private let folder: URL
    init(folder: URL = URL.applicationSupportDirectory.appending(path: "Trackers")) {
        self.folder = folder
        for tracker in MainTracker.others {
            var saved = (try? Data(contentsOf: file(tracker))).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
            // MDBList copies saved before its show and season rows were left out.
            if tracker == .mdblist { saved?.plays.removeAll { !$0.isMovieOrEpisode } }
            libraries[tracker] = saved
        }
    }
    private func file(_ tracker: MainTracker) -> URL { folder.appending(path: tracker.rawValue + ".json") }

    func check(_ tracker: MainTracker, store: DiaryStore) async {
        guard tracker != .trakt, running == nil else { return }
        if store.isPreview { errors[tracker] = "Direct reads need a real \(tracker.name) connection."; return }
        running = tracker; errors[tracker] = nil
        let started = Date.now, session = generation, editsAtStart = edits
        defer { if session == generation { running = nil } }
        do {
            // Edits still waiting go first; while they can't, the phone keeps showing them.
            if !(pending[tracker] ?? []).isEmpty { guard await sendPending(tracker, store: store, session: session) else { return } }
            let config = await store.freshProviderConfig(tracker.provider)
            let client = store.directClient
            var requests = 1
            let activitiesData = try await client.read(config, path: "/sync/last_activities")
            let activities = try (tracker == .wetrakr ? WeTrakrDecode.activities(from: activitiesData) : TrackerDecode.flatActivities(from: activitiesData))
            var library = libraries[tracker] ?? TraktLibrary()
            var fetched: [TraktDomain] = []
            if tracker == .wetrakr {
                let read = try await readWeTrakr(client, config, into: &library, activities: activities)
                requests += read.requests; fetched = read.fetched
                // WeTrakr's compact lists name titles by id only: names from the diary or the TMDB catalog.
                var names: [String: String] = [:]
                for title in store.workspace.titles { if let key = title.tmdbId.map({ (title.isSeries ? "tv:" : "movie:") + String($0) }) { names[key] = title.name } }
                for (key, title) in PhoneCatalog.shared.titles where names[key] == nil { names[key] = title.name }
                library = library.naming { ref in ref.diaryKey.flatMap { names[$0] } }
            } else if MDBListJournal.unmarked(library.activities) != activities || library.fetchedAt == nil {
                // MDBList: only the lists whose time moved (all of them on the first read).
                let previous = library.fetchedAt == nil ? nil : MDBListJournal.unmarked(library.activities)
                var lists = TrackerDecode.mdblistListsToRead(previous: previous, now: activities) ?? [.history, .ratings, .dropped, .watchlist]
                // Watches and ratings: only what changed since the last read, from MDBList's journal
                // (removals included). A window older than its 30 days, or a failed read, falls back
                // to reading those lists whole.
                let serverTime = ((try? JSONSerialization.jsonObject(with: activitiesData)) as? [String: Any])?["server_time"] as? String
                if previous != nil, let since = library.activities?.stamps["journal.since"], !lists.isDisjoint(with: [.history, .ratings]) {
                    var copy = library, cursor: String?, complete = false
                    do {
                        for _ in 0..<20 {
                            let query = cursor.map { ["cursor": $0, "limit": "1000"] } ?? ["since": since, "limit": "1000"]
                            let data = try await client.read(config, path: "/sync/journal", query: query), before = copy
                            let (result, after) = try await offMain { var next = before; let result = try MDBListJournal.apply(data, to: &next); return (result, next) }
                            copy = after
                            requests += 1
                            if result.needsFullRead { break }
                            guard let next = result.nextCursor else { complete = true; break }
                            cursor = next
                        }
                    } catch { complete = false }
                    if complete {
                        library.plays = copy.plays; library.ratings = copy.ratings
                        lists.subtract([.history, .ratings]); fetched += [.history, .ratings]
                    }
                }
                if lists.contains(.history) {
                    let watched = try await mdblistPages(client, config, "/sync/watched")
                    // Show and season rows ("finished") aren't plays, as in MDBList's journal.
                    library.plays = watched.items.filter { $0.title.kind == .movie || ($0.season != nil && $0.episode != nil) }.map { item in
                        TraktPlay(historyId: TrackerDecode.playID("mdblist|\(item.title.kind.rawValue)|\(item.title.tmdbId ?? 0)|\(item.title.name)|\(item.season ?? -1)|\(item.episode ?? -1)"),
                                  title: item.title, season: item.season, episode: item.episode, watchedAt: item.date)
                    }
                    requests += watched.calls; fetched.append(.history)
                }
                if lists.contains(.ratings) {
                    let ratings = try await mdblistPages(client, config, "/sync/ratings")
                    library.ratings = ratings.items.compactMap { item in item.rating.map { TraktRating(title: item.title, rating: $0, ratedAt: item.date) } }
                    requests += ratings.calls; fetched.append(.ratings)
                }
                if lists.contains(.dropped) {
                    let dropped = try await mdblistPages(client, config, "/sync/dropped")
                    library.dropped = dropped.items.map { TraktListed(title: $0.title, listedAt: $0.date) }
                    requests += dropped.calls; fetched.append(.dropped)
                }
                if lists.contains(.watchlist) {
                    let watchlist = try await mdblistPages(client, config, "/watchlist/items")
                    library.watchlist = watchlist.items.map { TraktListed(title: $0.title, listedAt: $0.date) }
                    requests += watchlist.calls; fetched.append(.watchlist)
                }
                var stamps = activities.stamps
                if let mark = serverTime ?? library.activities?.stamps["journal.since"] { stamps["journal.since"] = mark }
                library.activities = TraktActivities(all: activities.all, stamps: stamps)
            }
            library.fetchedAt = Date.now.formatted(.iso8601)
            // Signed out while reading: the previous account's lists are dropped, not saved.
            guard session == generation else { return }
            if edits != editsAtStart { refreshSoon(tracker, store: store, after: 2); return }
            library = ServiceIDs.shared.filledIn(library)
            libraries[tracker] = library
            readCounts[tracker, default: 0] += 1
            save(library, tracker)
            ServiceIDs.shared.learn(from: library)
            if store.diaryFromTracker == tracker { store.applyDiarySource() }
            guard let analysed = await analyse(tracker, store: store) else { return }
            guard session == generation else { return }
            reports[tracker] = .init(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: fetched, unavailable: [],
                                     skipped: library.skipped, comparison: analysed.comparison)
            plans[tracker] = analysed.plan
            nameUnnamed(tracker, analysed.comparison.unnamedKeys, store: store)
        } catch {
            if !Task.isCancelled, session == generation { errors[tracker] = error.localizedDescription }
        }
    }
    /// Titles the comparison could only show by key ("movie:100068": WeTrakr sends no name for
    /// some, and they aren't in the diary): looked up on TMDB (24 at a time, kept in the phone's
    /// catalog), then the comparison is worked out again with their names.
    private func nameUnnamed(_ tracker: MainTracker, _ keys: Set<String>, store: DiaryStore) {
        guard !keys.isEmpty, naming == nil else { return }
        let session = generation
        naming = Task {
            defer { naming = nil }
            let wanted = keys.sorted()
            for _ in 0..<10 {
                let known = PhoneCatalog.shared.titles
                guard wanted.contains(where: { known[$0] == nil }), await PhoneCatalog.shared.fill(wanted, store: store) else { break }
                if PhoneCatalog.shared.titles.count == known.count { break }
            }
            guard session == generation, let analysed = await analyse(tracker, store: store), let report = reports[tracker] else { return }
            reports[tracker] = .init(seconds: report.seconds, requests: report.requests, fetched: report.fetched, unavailable: report.unavailable,
                                     skipped: report.skipped, comparison: analysed.comparison)
        }
    }
    @ObservationIgnored private var naming: Task<Void, Never>?

    /// The comparison and the plan, worked out in the background, leaving out what the ledger
    /// holds (sent before and not kept by the service).
    private func analyse(_ tracker: MainTracker, store: DiaryStore) async -> (comparison: TraktComparison, plan: TraktWritePlan?)? {
        guard let read = libraries[tracker] else { return nil }
        let diary = store.diaryToMatch, planned = store.diaryService != tracker
        let ledger = MatchLedger.tokens(tracker), names = PhoneCatalog.shared.titles.mapValues(\.name)
        return await Task.detached(priority: .utility) {
            (TraktComparison.compare(read, with: diary, tracker: tracker, except: ledger, names: names),
             planned ? TraktWritePlan.make(library: read, workspace: diary, tracker: tracker, except: ledger) : nil)
        }.value
    }
    /// "Try them again": the ledger is cleared, so those go with the next match.
    func retryLedger(_ tracker: MainTracker, store: DiaryStore) async {
        MatchLedger.clear(tracker)
        guard let analysed = await analyse(tracker, store: store) else { return }
        if let report = reports[tracker] {
            reports[tracker] = .init(seconds: report.seconds, requests: report.requests, fetched: report.fetched, unavailable: report.unavailable,
                                     skipped: report.skipped, comparison: analysed.comparison)
        }
        plans[tracker] = analysed.plan
    }

    // MARK: Phase 5: edits in the MDBList / WeTrakr diary

    @ObservationIgnored private var lastWrite: Date?
    /// Trakt takes one write a second: every write (your edits, queued ones, the automatic copy,
    /// a restore) takes the next free slot, reserved before waiting so writes started together
    /// queue up instead of landing in the same second.
    private func pace() async throws {
        let slot = max(Date.now, (lastWrite ?? .distantPast).addingTimeInterval(1.1))
        lastWrite = slot
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }
    /// One per service: an edit goes to several at once, and a single shared re-read would leave
    /// all but the last showing the phone's guess until the next sync.
    @ObservationIgnored private var refreshes: [MainTracker: Task<Void, Never>] = [:]
    // MARK: Edits waiting for the service (as Cinopsys keeps them)

    struct PendingWrite: Codable, Equatable {
        var id: String? = UUID().uuidString
        let path: String
        var body: Data
        /// Tries so far, and the last reason (Cinopsys's retry_count and last_error).
        var attempts: Int?
        var lastError: String?
        /// The setting it assigns, for merging (see `PendingMerge`).
        var merge: String?
    }
    /// Each service's edits, kept on the phone in order until it takes them.
    private(set) var pending: [MainTracker: [PendingWrite]] = TrackerPreviewStore.loadPending() {
        didSet {
            let saved = Dictionary(uniqueKeysWithValues: pending.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "trackers.pendingWrites")
        }
    }
    nonisolated private static func loadPending() -> [MainTracker: [PendingWrite]] {
        guard let data = UserDefaults.standard.data(forKey: "trackers.pendingWrites"),
              let saved = try? JSONDecoder().decode([String: [PendingWrite]].self, from: data) else { return [:] }
        var result: [MainTracker: [PendingWrite]] = [:]
        for (key, writes) in saved {
            guard let tracker = MainTracker(rawValue: key) else { continue }
            result[tracker] = writes.map { write in
                var write = write
                if write.id == nil { write.id = UUID().uuidString }
                return write
            }
        }
        return result
    }
    /// An edit: kept on the phone (the screen already shows it) and sent at once in the background.
    func write(_ tracker: MainTracker, _ path: String, body: [String: Any], store: DiaryStore) throws {
        if store.isPreview { throw APIError.message("Writing to \(tracker.name) needs a real \(tracker.name) connection.") }
        let data = try JSONSerialization.data(withJSONObject: body)
        let merge = PendingMerge.key(path, body)
        if let merge {
            // A newer choice for the same setting replaces one still waiting (not the one being sent).
            let sendingNow = sending.contains(tracker) ? pending[tracker]?.first?.id : nil
            pending[tracker]?.removeAll { $0.merge == merge && $0.id != sendingNow }
        }
        pending[tracker, default: []].append(PendingWrite(path: path, body: data, merge: merge))
        flush(tracker, store: store)
    }
    @ObservationIgnored private var flushing: Set<MainTracker> = []
    @ObservationIgnored private var sending: Set<MainTracker> = []
    @ObservationIgnored private var retries: [MainTracker: Int] = [:]
    @ObservationIgnored private var retryTasks: [MainTracker: Task<Void, Never>] = [:]
    func flush(_ tracker: MainTracker, store: DiaryStore) {
        guard !flushing.contains(tracker), !store.isPreview, !(pending[tracker] ?? []).isEmpty else { return }
        flushing.insert(tracker)
        let session = generation
        Task { [weak self] in
            guard let self else { return }
            let sent = await self.sendPending(tracker, store: store, session: session)
            guard session == self.generation else { return }
            self.flushing.remove(tracker)
            if sent { self.refreshSoon(tracker, store: store) } else { self.retryLater(tracker, store: store) }
        }
    }
    /// Couldn't send yet: again in 30 seconds, ten times at most; after that with the next sync.
    private func retryLater(_ tracker: MainTracker, store: DiaryStore) {
        guard retryTasks[tracker] == nil, !(pending[tracker] ?? []).isEmpty, (retries[tracker] ?? 0) < 10 else { return }
        retries[tracker, default: 0] += 1
        let session = generation
        retryTasks[tracker] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, session == self.generation else { return }
            self.retryTasks[tracker] = nil
            self.flush(tracker, store: store)
        }
    }
    /// Sends the service's waiting edits, oldest first; false while it can't take them yet.
    private func sendPending(_ tracker: MainTracker, store: DiaryStore, session: UUID) async -> Bool {
        guard !sending.contains(tracker) else { return false }
        sending.insert(tracker)
        defer { if session == generation { sending.remove(tracker) } }
        let config = await store.freshProviderConfig(tracker.provider)
        while let next = pending[tracker]?.first {
            guard session == generation, !Task.isCancelled else { return false }
            do {
                try await pace()
                guard session == generation else { return false }
                let reply = try await store.directClient.write(config, path: next.path, body: next.body)
                guard session == generation else { return false }
                pending[tracker]?.removeAll { $0.id == next.id }
                // MDBList answered without saying anything changed: the phone already
                // shows the edit, and their change stamps won't move for one they didn't apply, so
                // the next read is a full one (otherwise the phone's guess would stay for good).
                if tracker == .mdblist, !ProviderDeliveryPlanner.confirms(reply) { libraries[tracker]?.activities = nil }
                if TraktDirectStore.notFoundCount(reply) > 0 {
                    refused(tracker, "\(tracker.name) couldn’t find a title by its TMDB id, so it wasn’t changed there.", store: store)
                }
            } catch {
                guard session == generation, !Task.isCancelled else { return false }
                // The answer was lost: WeTrakr may have logged it. Sent again as a first watch, which
                // WeTrakr won't log twice (a lost rewatch may then need logging again by hand).
                if tracker == .wetrakr, TraktDelivery.of(error) == .uncertain, let index = pending[tracker]?.firstIndex(where: { $0.id == next.id }) {
                    pending[tracker]?[index].body = WeTrakrWrite.withoutRewatch(next.body)
                }
                switch Self.delivery(error) {
                case .rejected:
                    pending[tracker]?.removeAll { $0.id == next.id }
                    DeadLetters.add(tracker.provider, title: Self.describe(next.body, store: store), reason: error.localizedDescription)
                    refused(tracker, "\(tracker.name) refused a change: " + error.localizedDescription, store: store)
                case .authBlocked:
                    errors[tracker] = error.localizedDescription
                    store.error = "\(tracker.name) needs you to reconnect. Your changes are kept and sent once it’s reconnected."
                    return false
                case .notSent, .retryLater, .uncertain:
                    // A finite budget (Cinopsys's retry_count): offline doesn't count; an edit the
                    // service keeps failing is set aside (listed on its page) so the rest, and the
                    // reads, carry on.
                    guard TraktDelivery.of(error) != .notSent, !TraktDelivery.paused(error), let index = pending[tracker]?.firstIndex(where: { $0.id == next.id }) else { return false }
                    let tries = (pending[tracker]?[index].attempts ?? 0) + 1
                    pending[tracker]?[index].attempts = tries
                    pending[tracker]?[index].lastError = error.localizedDescription
                    guard tries >= Self.retryBudget else { return false }
                    pending[tracker]?.removeAll { $0.id == next.id }
                    DeadLetters.add(tracker.provider, title: Self.describe(next.body, store: store), reason: error.localizedDescription)
                    refused(tracker, "\(tracker.name) kept failing on a change, so it was set aside: " + error.localizedDescription, store: store)
                }
            }
        }
        retries[tracker] = 0
        return true
    }
    /// Tries a queued edit gets (not counting offline) before it's set aside.
    static let retryBudget = 12
    /// The titles a queued write names, for the list of set-aside edits.
    static func describe(_ body: Data, store: DiaryStore) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return "An edit" }
        var names: [String] = []
        for slot in ["movies", "shows"] {
            for item in (root[slot] as? [[String: Any]]) ?? [] {
                guard let tmdb = ((item["ids"] as? [String: Any])?["tmdb"] as? NSNumber)?.intValue else { continue }
                names.append(store.workspace.titles.first { $0.tmdbId == tmdb && $0.isSeries == (slot == "shows") }?.name ?? "TMDB \(tmdb)")
            }
        }
        return names.isEmpty ? "An edit" : names.prefix(3).joined(separator: ", ")
    }
    /// What a failed write means: these services keep one watch per episode (or take a rewatch
    /// on purpose), so an edit whose answer was lost is simply sent again.
    static func delivery(_ error: Error) -> TraktDelivery {
        if let error = error as? APIError {
            switch error {
            case .rejected(let status, _):
                if status == 401 || status == 403 { return .authBlocked }
                return status == 408 || status == 429 || status >= 500 ? .retryLater : .rejected
            case .message(let text):
                if text.contains("sign-in") || text.contains("Connect ") || text.contains("Reconnect") { return .authBlocked }
                if text.contains("busy") || text.contains("slow down") { return .retryLater }
                return .rejected
            default:
                return .retryLater
            }
        }
        let kind = TraktDelivery.of(error)
        return kind == .rejected ? .rejected : .retryLater
    }
    /// Check-in, the way Cinopsys does it on each service: WeTrakr's scrobble/checkin,
    /// MDBList's checkin (a movie, or the show's next episode). The service logs the watch when it ends.
    func checkIn(_ tracker: MainTracker, _ title: MediaTitle, episode: Episode?, store: DiaryStore) async throws -> String {
        if store.isPreview { throw APIError.message("Checking in needs a real \(tracker.name) connection.") }
        guard let tmdb = title.tmdbId else { throw APIError.message("“\(title.name)” has no TMDB id, so \(tracker.name) can’t find it.") }
        if title.isSeries && episode == nil { throw APIError.message("There’s no next episode to check in to.") }
        if tracker == .trakt { return try await TraktDirectStore.shared.checkIn(title, episode: episode, store: store) }
        let config = await store.freshProviderConfig(tracker.provider)
        let client = store.directClient
        let slot = title.isSeries ? "show" : "movie"
        var path = "/scrobble/checkin"
        var body: [String: Any] = [:]
        switch tracker {
        case .mdblist:
            path = "/checkin"
            var media: [String: Any] = ["ids": ["tmdb": tmdb]]
            if let episode, title.isSeries { media["season"] = episode.season; media["episode"] = episode.number }
            body[slot] = media
        case .wetrakr:
            body[slot] = ["id": try await weTrakrID(title, tmdb: tmdb, config: config, client: client)]
            if let episode, title.isSeries { body["episode"] = ["season": episode.season, "number": episode.number] }
            body["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        default:
            body[slot] = ["ids": ["tmdb": tmdb]]
            if let episode, title.isSeries { body["episode"] = ["season": episode.season, "number": episode.number] }
        }
        do { _ = try await client.write(config, path: path, body: try JSONSerialization.data(withJSONObject: body)) }
        catch APIError.rejected(let status, _) where status == 409 {
            throw APIError.message("You’re already checked in to something on \(tracker.name). It ends on its own when that finishes.")
        }
        refreshSoon(tracker, store: store, after: 30)
        return title.isSeries ? "Checked in to \(title.name) S\(episode?.season ?? 0) E\(episode?.number ?? 0) on \(tracker.name). It’s logged when the episode ends."
            : "Checked in to \(title.name) on \(tracker.name). It’s logged when the movie ends."
    }
    /// WeTrakr names titles by its own id: from what was read of your WeTrakr library, else its
    /// look-up by TMDB id (GET /media/external/tmdb/{id}).
    private func weTrakrID(_ title: MediaTitle, tmdb: Int, config: ExternalProviderConfig, client: DirectProviderClient) async throws -> Int {
        let kind: TraktTitleRef.Kind = title.isSeries ? .show : .movie
        if let library = libraries[.wetrakr] {
            let refs = library.plays.map(\.title) + library.watchlist.map(\.title) + library.favorites.map(\.title)
                + library.dropped.map(\.title) + library.ratings.map(\.title)
            if let id = refs.first(where: { $0.tmdbId == tmdb && $0.kind == kind && $0.weTrakrId != nil })?.weTrakrId { return id }
        }
        let data = try await client.read(config, path: "/media/external/tmdb/\(tmdb)", query: ["type": title.isSeries ? "show" : "movie"])
        if let id = Self.weTrakrMatch(data, show: title.isSeries) { return id }
        throw APIError.message("WeTrakr couldn’t find “\(title.name)”.")
    }
    /// The id in WeTrakr's external look-up reply: a list of {id, type}, or one of them, or a list
    /// under data/results; the first of the right kind.
    nonisolated static func weTrakrMatch(_ data: Data, show: Bool) -> Int? {
        let root = try? JSONSerialization.jsonObject(with: data)
        var matches: [[String: Any]] = []
        if let list = root as? [[String: Any]] { matches = list }
        else if let object = root as? [String: Any] {
            for key in ["data", "results", "matches", "items"] {
                if let list = object[key] as? [[String: Any]] { matches = list; break }
            }
            if matches.isEmpty { matches = [object] }
        }
        let wanted: Set<String> = show ? ["show", "shows", "tv", "series"] : ["movie", "movies"]
        let match = matches.first { item in (item["type"] as? String).map { wanted.contains($0.lowercased()) } ?? true }
        return (match?["id"] as? NSNumber)?.intValue
    }
    /// A refused edit: you're told, and the service is read in full again so the screen shows what it kept.
    private func refused(_ tracker: MainTracker, _ message: String, store: DiaryStore) {
        errors[tracker] = message
        store.error = message
        libraries[tracker]?.activities = nil
        refreshSoon(tracker, store: store, after: 1)
    }
    /// Applies an edit to the phone's copy and redraws the diary at once.
    @ObservationIgnored private var edits = 0
    func update(_ tracker: MainTracker, store: DiaryStore, _ change: (inout TraktLibrary) -> Void) {
        guard var value = libraries[tracker] else { return }
        edits += 1
        change(&value)
        libraries[tracker] = value
        save(value, tracker)
        store.applyDiarySource()
    }
    /// A quiet re-read a few seconds after an edit.
    func refreshSoon(_ tracker: MainTracker, store: DiaryStore, after seconds: Double = 10) {
        refreshes[tracker]?.cancel()
        let session = generation
        refreshes[tracker] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, session == self.generation else { return }
            await self.check(tracker, store: store)
        }
    }

    // MARK: Phase 5: make MDBList / WeTrakr match the diary

    func matchPlan(_ tracker: MainTracker, store: DiaryStore) -> TraktWritePlan? {
        guard store.diaryService != tracker else { return nil }
        return libraries[tracker].map { TraktWritePlan.make(library: $0, workspace: store.diaryToMatch, tracker: tracker, except: MatchLedger.tokens(tracker)) }
    }
    /// A backup or an import into MDBList or WeTrakr while it holds the diary: only what it
    /// lacks (watches at their dates, ratings where it has none, Planned for titles never
    /// watched), nothing changed or taken off, so running it twice adds nothing twice.
    func restore(_ tracker: MainTracker, _ backup: Workspace, store: DiaryStore) async throws -> String {
        guard writing == nil, running == nil else { throw APIError.message("\(tracker.name) is busy right now. Try again in a moment.") }
        if store.isPreview { throw APIError.message("Writing to \(tracker.name) needs a real \(tracker.name) connection.") }
        let session = generation
        await check(tracker, store: store)
        guard session == generation else { throw CancellationError() }
        if let failure = errors[tracker] { throw APIError.message("\(tracker.name) couldn’t be read, so nothing was added. " + failure) }
        guard let library = libraries[tracker] else { throw APIError.message("\(tracker.name) couldn’t be read, so nothing was added.") }
        let plan = TraktWritePlan.make(library: library, workspace: backup, tracker: tracker, fillOnly: true)
        guard !plan.isEmpty else { return "\(tracker.name) already has everything in it." }
        writing = tracker
        defer { if session == generation { writing = nil; writeProgress = nil } }
        let config = await store.freshProviderConfig(tracker.provider)
        var tally = TraktDirectStore.ReplyTally(), sent = 0
        let requests = plan.requests()
        do {
            for (index, request) in requests.enumerated() {
                writeProgress = "Adding \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                try await pace()
                guard session == generation else { throw CancellationError() }
                tally.add(try await store.directClient.write(config, path: request.path, body: request.body, partial: true))
                sent += request.count
            }
        } catch {
            writing = nil
            await check(tracker, store: store)
            throw APIError.message((sent > 0 ? "Added \(sent) before stopping; run it again to finish (nothing is added twice). " : "") + error.localizedDescription)
        }
        writing = nil
        libraries[tracker]?.activities = nil
        await check(tracker, store: store)
        return "Added to \(tracker.name): " + plan.summary.joined(separator: "; ") + ". " + tally.text(service: tracker.name)
            + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) watches have no date and were left out." : "")
    }
    /// Sends the plan one request a second (each service's own endpoints, within what it keeps),
    /// then reads the service again so the comparison shows the result.
    func makeMatch(_ tracker: MainTracker, store: DiaryStore) async {
        guard writing == nil, running == nil, let plan = matchPlan(tracker, store: store), !plan.isEmpty else { return }
        if store.isPreview { errors[tracker] = "Writing to \(tracker.name) needs a real \(tracker.name) connection."; return }
        writing = tracker; errors[tracker] = nil; writeResults[tracker] = nil
        MatchInBackground.shared.begin("Matching \(tracker.name)", provider: tracker.provider)
        var sent = 0, tally = TraktDirectStore.ReplyTally()
        let session = generation
        defer {
            if session == generation { writing = nil; writeProgress = nil }
            MatchInBackground.shared.end(writeResults[tracker] ?? errors[tracker], success: errors[tracker] == nil)
        }
        do {
            let config = await store.freshProviderConfig(tracker.provider)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                if MatchInBackground.shared.expired { throw APIError.message("iOS stopped it while TwilDiary was in the background. Open TwilDiary and match again; only what's still missing is sent.") }
                MatchInBackground.shared.count(index, of: requests.count)
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                try await pace()
                guard session == generation else { return }
                let reply = try await store.directClient.write(config, path: request.path, body: request.body, partial: true)
                sent += request.count
                tally.add(reply)
            }
            writeResults[tracker] = "Sent to \(tracker.name): " + plan.summary.joined(separator: "; ") + ". " + tally.text(service: tracker.name)
                + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) diary watches have no date and were left out." : "")
        } catch {
            if !Task.isCancelled, session == generation { errors[tracker] = (sent > 0 ? "Sent \(sent) before stopping. " : "") + error.localizedDescription }
        }
        guard session == generation else { return }
        writing = nil; writeProgress = nil
        // Read it all again: a service's change stamps can lag its writes, and an unchanged stamp
        // would keep showing the copy from before the send.
        libraries[tracker]?.activities = nil
        await check(tracker, store: store)
        guard session == generation, errors[tracker] == nil, let stillMissing = matchPlan(tracker, store: store) else { return }
        // Sent, answered, and still not there: into the ledger, so the next match doesn't send it
        // yet again (the loop of match, fail, match). Shown apart, with "Try them again".
        let stuck = plan.tokens.intersection(stillMissing.tokens)
        guard !stuck.isEmpty else { return }
        MatchLedger.add(tracker, stuck)
        writeResults[tracker] = (writeResults[tracker] ?? "") + " \(stuck.count) didn’t stick on \(tracker.name), so they won’t be sent again on their own."
        await retryLedgerless(tracker, store: store)
    }
    /// The comparison and plan again, now leaving out the ledger.
    private func retryLedgerless(_ tracker: MainTracker, store: DiaryStore) async {
        guard let analysed = await analyse(tracker, store: store) else { return }
        if let report = reports[tracker] {
            reports[tracker] = .init(seconds: report.seconds, requests: report.requests, fetched: report.fetched, unavailable: report.unavailable,
                                     skipped: report.skipped, comparison: analysed.comparison)
        }
        plans[tracker] = analysed.plan
    }

    // MARK: Force Match: one side made exactly like the other

    /// Which side wins: the diary, or this service.
    enum ForceSource: String, CaseIterable, Identifiable { case diary, service; var id: Self { self } }
    /// Can the diary be made like this service? Only when the diary lives on a service of its own.
    func canForceIntoDiary(_ tracker: MainTracker, store: DiaryStore) -> Bool {
        guard let home = store.diaryService, home != tracker else { return false }
        return home == .trakt || home == .mdblist || home == .wetrakr
    }
    /// Reads both sides afresh, then works out what Force Match would add and take off.
    func forcePlan(_ tracker: MainTracker, source: ForceSource, store: DiaryStore) async -> ForceMatchPlan? {
        guard writing == nil, running == nil else { return nil }
        return await freshForcePlan(tracker, source: source, store: store, full: false)
    }
    /// `full`: both sides read in full, not just what their change stamps say moved (after a send).
    /// Reads a service now and says whether a new copy actually came back. `check` can end quietly
    /// with the old copy (another read under way, edits still waiting, an edit made meanwhile), and
    /// a plan from an old copy takes off or sends the wrong things; so a read under way is waited
    /// for, and a quiet ending is tried once more before giving up.
    private func readFresh(_ tracker: MainTracker, store: DiaryStore, full: Bool) async -> Bool {
        let session = generation
        for attempt in 0..<2 {
            var waited = 0
            while running != nil, waited < 200, session == generation { try? await Task.sleep(for: .milliseconds(300)); waited += 1 }
            guard session == generation else { return false }
            if full { libraries[tracker]?.activities = nil }
            let before = readCounts[tracker, default: 0]
            await check(tracker, store: store)
            guard session == generation, errors[tracker] == nil else { return false }
            if readCounts[tracker, default: 0] != before { return true }
            if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
        }
        errors[tracker] = "\(tracker.name) couldn’t be read afresh just now (another change was on its way). Try again in a moment."
        return false
    }
    /// The same for Trakt, which has its own store. `note`: the service whose panel shows why not.
    private func readTraktFresh(store: DiaryStore, full: Bool, note tracker: MainTracker) async -> Bool {
        let trakt = TraktDirectStore.shared
        // The on-this-phone diary is its own record: there's nothing to read.
        if trakt.localOnly { return true }
        let session = generation
        for attempt in 0..<2 {
            var waited = 0
            while trakt.running, waited < 200, session == generation { try? await Task.sleep(for: .milliseconds(300)); waited += 1 }
            guard session == generation else { return false }
            let before = trakt.readCount
            if full { await trakt.rereadAfterForce(store: store) } else { await trakt.check(store: store) }
            guard session == generation else { return false }
            if let failure = trakt.error { errors[tracker] = "Trakt couldn’t be read: " + failure; return false }
            if trakt.readCount != before { return true }
            if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
        }
        errors[tracker] = "Trakt couldn’t be read in full just now (a change was on its way, or Trakt didn’t give its favourites or dropped shows). Try again in a moment."
        return false
    }
    private func freshForcePlan(_ tracker: MainTracker, source: ForceSource, store: DiaryStore, full: Bool) async -> ForceMatchPlan? {
        guard await readFresh(tracker, store: store, full: full), let service = libraries[tracker] else { return nil }
        switch source {
        case .diary:
            let diary = store.diaryToMatch
            // An empty source would take everything off the other side: far more likely a diary
            // that hasn't loaded than one you emptied on purpose.
            guard !diary.activeTitles.isEmpty else {
                errors[tracker] = "Your diary is empty here, so Force Match would take everything off \(tracker.name). Nothing was changed."
                return nil
            }
            let holds = (store.diaryService ?? .trakt).capabilities
            return await Task.detached(priority: .userInitiated) {
                ForceMatchPlan.make(target: service, tracker: tracker, source: diary, sourceHolds: holds,
                                    keep: ForceMatchPlan.keepTokens(diary.activeTitles))
            }.value
        case .service:
            guard canForceIntoDiary(tracker, store: store), let home = store.diaryService else { return nil }
            guard !service.plays.isEmpty || !service.ratings.isEmpty || !service.watchlist.isEmpty || !service.favorites.isEmpty || !service.dropped.isEmpty else {
                errors[tracker] = "\(tracker.name) has nothing on it, so Force Match would take everything off your diary. Nothing was changed."
                return nil
            }
            // The side being changed is read afresh too: a failed or skipped read would leave the
            // copy from before the last send, and everything just sent would look still missing.
            if home == .trakt {
                guard await readTraktFresh(store: store, full: full, note: tracker) else { return nil }
            } else {
                guard await readFresh(home, store: store, full: full) else {
                    if errors[tracker] == nil { errors[tracker] = errors[home].map { "\(home.name) couldn’t be read: " + $0 } }
                    return nil
                }
            }
            guard let target = home == .trakt ? TraktDirectStore.shared.library : libraries[home] else { return nil }
            let catalog = PhoneCatalog.shared.titles
            return await Task.detached(priority: .userInitiated) {
                let refs = service.plays.map(\.title) + service.ratings.map(\.title) + service.watchlist.map(\.title)
                    + service.favorites.map(\.title) + service.dropped.map(\.title)
                return ForceMatchPlan.make(target: target, tracker: home, source: TraktDiary.forceSource(library: service, tracker: tracker, catalog: catalog),
                                           sourceHolds: tracker.capabilities, keep: ForceMatchPlan.keepTokens(refs))
            }.value
        }
    }

    /// What a failed Force Match call means for it.
    /// `retry`: a passing failure of this call (asked again, then left for the check). `busy`: the
    /// service is limiting us (asked again, then the run stops: the calls after it would only wait
    /// the same way). `stop`: the service said when to come back, or the account is at its limit.
    /// `refused`: something in the body, so it's halved to find which title. `rejected`: the call
    /// itself, which halving can't help.
    private enum ForceFailure { case retry, busy, uncertain, refused, rejected, signIn, stop }
    private static func classify(_ error: Error) -> ForceFailure {
        func status(_ code: Int) -> ForceFailure {
            switch code {
            case 401, 403: return .signIn
            case 420: return .stop
            case 429: return .busy
            case 408, 425, 500...: return .retry
            case 400, 404, 409, 422: return .refused
            default: return .rejected
            }
        }
        if let error = error as? TraktWriteError { return status(error.status) }
        if let error = error as? APIError {
            switch error {
            case .rejected(let code, _): return status(code)
            case .signIn: return .signIn
            case .transport: return .uncertain
            case .message(let text):
                let lower = text.lowercased()
                // Our own pause after the service asked for one: it says until when.
                if lower.contains("slow down") { return .stop }
                if lower.contains("sign-in") || lower.contains("reconnect") || lower.contains("connect ") { return .signIn }
                if lower.contains("busy") || lower.contains("try again") { return .busy }
                return .refused
            default: return .refused
            }
        }
        if error is DirectProviderClient.DeliveryUnconfirmed { return .uncertain }
        guard (error as NSError).domain == NSURLErrorDomain else { return .refused }
        // Never left the phone: safe to ask again. Otherwise the answer was lost on the way.
        return TraktDelivery.of(error) == .notSent ? .retry : .uncertain
    }
    /// What happened to a Force Match, for its report.
    private struct ForceRun {
        var tally = TraktDirectStore.ReplyTally()
        var names: [String: String] = [:]
        /// Titles the service refused, with why: not sent again.
        var refused: [String: String] = [:]
        /// Answers lost on the way, and calls still failing after three tries: checked, then sent again once.
        var uncertain = Set<String>(), exhausted = Set<String>()
        var waits = 0, splits = 0, passes = 0
        var stopped: String?
        /// What still differed at the last check; nil when that check couldn't read both sides.
        var lastFresh: ForceMatchPlan?
        /// Sent and answered, and still not there at the check: into the ledger.
        var stuck = 0
    }

    /// Force Match: both sides read, the plan worked out and sent, each failure dealt with by what
    /// it means (see `sendForce`), what landed checked, and what failed for a passing reason sent
    /// once more. Titles still different after that are left as they are and named in the report:
    /// they're ones the service can't find or numbers its own way, and clearing them to send again
    /// would lose what the source can't hold (rewatches, specials, favourites) for the same result.
    func forceRun(_ tracker: MainTracker, source: ForceSource, store: DiaryStore) async {
        guard writing == nil, running == nil else { return }
        if store.isPreview { errors[tracker] = "Force Match needs real connections."; return }
        writing = tracker; errors[tracker] = nil; writeResults[tracker] = nil
        MatchInBackground.shared.begin("Force Match · \(tracker.name)", provider: tracker.provider)
        writeProgress = "Reading both sides…"
        let session = generation
        defer {
            if session == generation { writing = nil; writeProgress = nil }
            MatchInBackground.shared.end(writeResults[tracker] ?? errors[tracker], success: errors[tracker] == nil)
        }
        guard let plan = await freshForcePlan(tracker, source: source, store: store, full: false), session == generation else {
            if session == generation, errors[tracker] == nil { errors[tracker] = "Force Match couldn’t read both sides. Try again in a moment." }
            return
        }
        guard !plan.isEmpty else {
            writeResults[tracker] = "Force Match: \(plan.tracker.name) already matches, within what both sides keep."
            return
        }
        // Everything is sent again, what didn't stick before included.
        MatchLedger.clear(tracker)
        var run = ForceRun(), current = plan
        do {
            while run.passes < 2, !current.isEmpty {
                run.passes += 1
                run.names.merge(current.names) { first, _ in first }
                run.uncertain = []; run.exhausted = []
                try await sendForce(current, run: &run, store: store)
                guard session == generation, run.stopped == nil else { break }
                // What actually landed: both sides read in full, what's still different worked out afresh.
                writeProgress = "Checking what landed…"
                // A check that can't read both sides leaves nothing to go by (never the plan from
                // before the send, which would show everything just sent as still missing).
                run.lastFresh = nil
                guard let fresh = await freshForcePlan(tracker, source: source, store: store, full: true), session == generation else { break }
                run.lastFresh = fresh
                run.names.merge(fresh.names) { first, _ in first }
                guard !run.uncertain.isEmpty || !run.exhausted.isEmpty else { break }
                current = fresh.without(Set(run.refused.keys))
            }
        } catch { return }
        guard session == generation else { return }
        writing = nil; writeProgress = nil
        if run.stopped != nil { await check(tracker, store: store) }
        // Sent, answered, and still not there: into the ledger, as a match does, so the ordinary
        // match doesn't keep sending what this service doesn't keep ("Try them again" clears it).
        if source == .diary, run.stopped == nil, let left = run.lastFresh {
            let stuck = plan.send.tokens.intersection(left.send.tokens)
            if !stuck.isEmpty {
                MatchLedger.add(tracker, stuck)
                run.stuck = stuck.count
                await retryLedgerless(tracker, store: store)
                guard session == generation else { return }
            }
        }
        writeResults[tracker] = forceReport(plan, run, source: source, tracker: tracker)
    }
    /// One pass: each call, one a second, each failure dealt with by what it means.
    private func sendForce(_ plan: ForceMatchPlan, run: inout ForceRun, store: DiaryStore) async throws {
        let session = generation
        let config: ExternalProviderConfig? = plan.tracker == .trakt ? nil : await store.freshProviderConfig(plan.tracker.provider)
        var queue = plan.requests()
        var done = 0, total = queue.count
        let pass = run.passes > 1 ? " (checking again)" : ""
        while !queue.isEmpty {
            if MatchInBackground.shared.expired {
                run.stopped = "iOS stopped it while TwilDiary was in the background. Open TwilDiary and run Force Match again; it sends only what's still different."
                return
            }
            let request = queue.removeFirst()
            done += 1
            MatchInBackground.shared.count(done - 1, of: total)
            var tries = 0
            attempts: while true {
                writeProgress = "Changing \(done) of \(total)\(pass): \(request.count) \(request.summary)…"
                do {
                    let reply: Data
                    if let config {
                        try await pace()
                        guard session == generation else { throw CancellationError() }
                        if request.method == "DELETE" { reply = try await store.directClient.read(config, path: request.path, method: "DELETE") }
                        else { reply = try await store.directClient.write(config, path: request.path, body: request.body ?? Data(), partial: true) }
                    } else {
                        reply = try await TraktDirectStore.shared.forcePost(request.path, body: request.body ?? Data(), store: store)
                    }
                    run.tally.add(reply)
                    break attempts
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard session == generation else { throw CancellationError() }
                    // Taking off something that's already gone: done.
                    if request.method == "DELETE", case .rejected(404, _)? = error as? APIError { break attempts }
                    let keys = plan.keys(of: request)
                    switch Self.classify(error) {
                    case .signIn, .stop:
                        // The sign-in, the account's limit, or a pause the service asked for: the
                        // calls after this one would fail the same way.
                        run.stopped = error.localizedDescription
                        return
                    case .retry where tries < 3, .busy where tries < 3:
                        let wait = [5, 15, 45][tries]
                        tries += 1; run.waits += 1
                        writeProgress = "\(plan.tracker.name) is busy; asking again in \(wait) s…"
                        try await Task.sleep(for: .seconds(wait))
                        guard session == generation else { throw CancellationError() }
                        continue attempts
                    case .busy:
                        run.stopped = "\(plan.tracker.name) is still limiting requests after three waits. Run Force Match again in a while; it sends only what’s still different."
                        return
                    case .retry:
                        run.exhausted.formUnion(keys)
                    case .uncertain:
                        run.uncertain.formUnion(keys)
                    case .refused:
                        if let halves = request.halves() {
                            queue.insert(contentsOf: halves, at: 0)
                            total += halves.count; run.splits += 1
                        } else if keys.isEmpty {
                            run.refused[request.summary] = error.localizedDescription
                        } else {
                            for key in keys { run.refused[key] = error.localizedDescription }
                        }
                    case .rejected:
                        // The call itself (a path or method the service doesn't take): not halved.
                        if keys.isEmpty { run.refused[request.summary] = error.localizedDescription }
                        for key in keys { run.refused[key] = error.localizedDescription }
                    }
                    break attempts
                }
            }
        }
    }
    private func forceReport(_ plan: ForceMatchPlan, _ run: ForceRun, source: ForceSource, tracker: MainTracker) -> String {
        func titles(_ keys: [String]) -> String {
            let list = keys.map { run.names[$0] ?? $0 }.sorted()
            return list.prefix(5).joined(separator: ", ") + (list.count > 5 ? " and \(list.count - 5) more" : "")
        }
        let target = plan.tracker.name, winner = source == .diary ? "your diary" : tracker.name
        var text = "Force Match (\(winner) won), on \(target): " + plan.summary.joined(separator: "; ") + "."
        let replies = run.tally.text(service: target)
        if !replies.isEmpty { text += " " + replies }
        if run.waits > 0 { text += " \(target) was busy \(run.waits == 1 ? "once" : "\(run.waits) times"); waited and asked again." }
        if run.passes > 1 { text += " Checked what landed and sent the rest once more." }
        if let stopped = run.stopped { text += " Stopped: \(stopped)" }
        if !run.refused.isEmpty {
            text += " \(target) refused \(titles(Array(run.refused.keys))): \(run.refused.values.first ?? "")."
        }
        guard run.stopped == nil else { return text }
        if let still = run.lastFresh {
            if still.isEmpty {
                text += " Both sides now match."
            } else {
                text += " Still different: \(titles(Array(still.names.keys))). \(target) doesn’t keep them as sent (a title it can’t find, or one it numbers its own way), so they were left as they are; nothing was cleared."
                if run.stuck > 0 { text += " \(run.stuck) of those won’t be sent again on their own." }
            }
        } else {
            text += " What landed couldn’t be checked, because both sides couldn’t be read again. Tap Check now to see where they stand."
        }
        return text
    }

    /// WeTrakr, the way its sync guide describes: the first time (or when the journal can't place
    /// something) its compact lists in full, then only its journal from the last mark: what changed
    /// and how, oldest first, so an unchanged library costs one call.
    private func readWeTrakr(_ client: DirectProviderClient, _ config: ExternalProviderConfig, into library: inout TraktLibrary,
                             activities: TraktActivities) async throws -> (requests: Int, fetched: [TraktDomain]) {
        var requests = 0
        let previous = library.fetchedAt == nil ? nil : library.activities
        let mark = previous?.stamps["journal.mark"]
        var mustReadAll = previous == nil || mark == nil
        var nextMark = mark
        if !mustReadAll, let mark, activities.all != previous?.all {
            var seen = Set<String>()
            for page in 1...20 {
                let data: Data
                do { data = try await client.read(config, path: "/sync/journal", query: ["from_date": mark, "limit": "1000", "page": String(page)]) }
                catch APIError.rejected(let status, _) where (400..<500).contains(status) && status != 429 { mustReadAll = true; break }  // JOURNAL_EXPIRED and the like
                requests += 1
                let before = library, seenBefore = seen
                let (result, after, seenAfter) = try await offMain {
                    var next = before, marks = seenBefore
                    let result = try WeTrakrDecode.applyJournal(data, to: &next, seen: &marks)
                    return (result, next, marks)
                }
                library = after; seen = seenAfter
                if result.needsFullRead { mustReadAll = true; break }
                nextMark = result.mark ?? nextMark
                if result.entries < 1000 { break }
            }
        }
        var fetched: [TraktDomain] = mustReadAll ? [.history, .ratings, .watchlist, .favorites, .dropped] : (nextMark != mark ? [.history] : [])
        if mustReadAll {
            func all(_ path: String) async throws -> [Data] {
                var pages: [Data] = [], after: String?
                for _ in 0..<40 {
                    var query = ["compact": "true", "limit": "5000"]
                    if let after { query["after"] = after }
                    let reply = try await client.readWeTrakr(config, path: path, query: query)
                    requests += 1; pages.append(reply.data)
                    guard let next = reply.next else { break }
                    after = next
                }
                return pages
            }
            var skipped = 0, fresh = TraktLibrary()
            // Each list's pages are decoded away from the main thread.
            func decoded<T: Sendable>(_ pages: [Data], _ decode: @escaping @Sendable (Data, inout Int) throws -> [T]) async throws -> [T] {
                let (items, count) = try await offMain { () throws -> ([T], Int) in
                    var count = 0, items: [T] = []
                    for page in pages { items += try decode(page, &count) }
                    return (items, count)
                }
                skipped += count
                return items
            }
            for path in ["/sync/tracking/watched/history/movies", "/sync/tracking/watched/history/episodes"] {
                fresh.plays += try await decoded(try await all(path)) { try WeTrakrDecode.plays(from: $0, skipped: &$1) }
            }
            for target in ["movies", "shows"] {
                fresh.watchlist += try await decoded(try await all("/sync/tracking/planning/" + target)) { try WeTrakrDecode.listed(from: $0, skipped: &$1) }
                fresh.dropped += try await decoded(try await all("/sync/tracking/dropped/" + target)) { try WeTrakrDecode.listed(from: $0, skipped: &$1) }
                fresh.favorites += try await decoded(try await all("/sync/favorites/" + target)) { try WeTrakrDecode.listed(from: $0, skipped: &$1) }
            }
            fresh.ratings += try await decoded(try await all("/sync/ratings/all")) { try WeTrakrDecode.ratings(from: $0, skipped: &$1) }
            library.plays = fresh.plays; library.watchlist = fresh.watchlist; library.dropped = fresh.dropped
            library.favorites = fresh.favorites; library.ratings = fresh.ratings; library.skipped = skipped
            // Everything up to here is in; the journal carries on from how far it could be read.
            nextMark = activities.stamps["journal_visible_until"] ?? activities.all
        }
        var stamps = activities.stamps
        if let nextMark { stamps["journal.mark"] = nextMark }
        library.activities = TraktActivities(all: activities.all, stamps: stamps)
        if fetched.isEmpty { fetched = [] }
        return (requests, fetched)
    }

    /// Follows MDBList's cursor, 1,000 items a page, at most 50 pages.
    private func mdblistPages(_ client: DirectProviderClient, _ config: ExternalProviderConfig, _ path: String) async throws
        -> (items: [TrackerDecode.MDBListPage.Item], skipped: Int, calls: Int) {
        var items: [TrackerDecode.MDBListPage.Item] = [], skipped = 0, calls = 0, cursor: String?
        repeat {
            var query = ["limit": "1000"]
            if let cursor { query["cursor"] = cursor }
            let data = try await client.read(config, path: path, query: query)
            let page = try await offMain { try TrackerDecode.mdblistPage(from: data) }
            items += page.items; skipped += page.skipped; calls += 1
            cursor = page.next == cursor ? nil : page.next
        } while cursor != nil && calls < 50
        return (items, skipped, calls)
    }

    private func save(_ library: TraktLibrary, _ tracker: MainTracker) {
        BackgroundFiles.save(library, to: file(tracker), protected: true, excludeFolderFromBackup: true)
    }
    /// Sign-out: these copies are diary data, so they go with the diary.
    /// Anything already running for this account can no longer save or show its results.
    func forget() {
        generation = UUID()
        for task in refreshes.values { task.cancel() }
        refreshes = [:]
        running = nil; writing = nil; writeProgress = nil
        libraries = [:]; reports = [:]; errors = [:]; writeResults = [:]; plans = [:]; pending = [:]
        for tracker in MainTracker.others { MatchLedger.clear(tracker) }
        BackgroundFiles.cancel(folder: folder)
        flushing = []; sending = []; retries = [:]
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}

extension DiaryStore {
    /// Trakt holds the diary (the diary on screen comes from it).
    var traktHoldsDiary: Bool { diaryFromTrakt }

    /// Keeps the service your diary lives on current while the app is open: a read when you open or
    /// come back to the app (unless one ran in the last two minutes), then every ten minutes. Each
    /// read first asks the service what changed, so a quiet check is one small request; edits made
    /// offline are sent first. Runs until the app leaves the foreground (the task is cancelled).
    func keepDiaryServiceCurrent() async {
        while !Task.isCancelled {
            await readDiaryServiceIfDue(olderThan: 120)
            try? await Task.sleep(for: .seconds(600))
        }
    }
    func readDiaryServiceIfDue(olderThan seconds: TimeInterval) async {
        guard !isPreview, hasLoadedWorkspace, !Task.isCancelled else { return }
        // Edits still waiting for the other services go out on the same beat (the phone's queue).
        if phoneOnly, !outbox.entries.isEmpty { Task { await self.flushDirectProviders() } }
        func due(_ stamp: String?) -> Bool {
            guard let stamp, let date = try? Date(stamp, strategy: .iso8601) else { return true }
            return Date.now.timeIntervalSince(date) >= seconds
        }
        if traktHoldsDiary {
            let trakt = TraktDirectStore.shared
            guard !trakt.running, !trakt.writing, due(trakt.library?.fetchedAt) || !trakt.pending.isEmpty else { return }
            await trakt.check(store: self)
        } else if let tracker = diaryFromTracker {
            let others = TrackerPreviewStore.shared
            guard others.running == nil, others.writing == nil, due(others.libraries[tracker]?.fetchedAt) || !(others.pending[tracker] ?? []).isEmpty else { return }
            await others.check(tracker, store: self)
        }
    }
    /// What the mirrors are compared with and made to match: the diary you see.
    var diaryToMatch: Workspace { workspace }
}

/// One of Trakt's caps for an account, from /users/settings ("list" · "item_count" · 100).
struct TraktAccountLimit: Identifiable, Hashable, Sendable {
    let group: String
    let name: String
    let value: Int
    let vip: Bool
    var id: String { group + "." + name }
    /// "Lists", "Items per list", "Watchlist items"…
    var label: String {
        let thing = group.replacingOccurrences(of: "_", with: " ").capitalized
        switch name {
        case "count": return thing == "List" ? "Lists" : thing
        case "item_count": return thing == "List" ? "Items per list" : thing + " items"
        default: return thing + " · " + name.replacingOccurrences(of: "_", with: " ")
        }
    }
}
