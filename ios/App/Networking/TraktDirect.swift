import Foundation
import Observation
import TwilDiaryCore

// Trakt-first plan, phase 1 (ios/docs/TRAKT-CLIENT-PLAN.md): the app reads Trakt directly
// (api.trakt.tv) with the access token the Worker hands out, keeps the last read on this
// iPhone, and compares it with the current diary. Read-only: nothing is written anywhere.

/// A current Trakt access token: from this iPhone's own sign-in, or (signed in before that
/// existed) `GET /api/trakt/token`, where the server keeps the refresh token.
struct TraktDirectToken: Decodable, Sendable {
    let accessToken: String
    /// Milliseconds since 1970, as the Worker stores it.
    let expiresAt: Double
    let clientId: String
    let username: String
    var usable: Bool { Date.now.timeIntervalSince1970 * 1000 < expiresAt - 300_000 }
}

/// Trakt's API with the owner's token: version 2 headers, waits out "too many requests"
/// (Retry-After, at most twice), and reports how many pages a list has.
struct TraktDirectClient: Sendable {
    let token: TraktDirectToken
    var session: URLSession = .shared
    private static let base = URL(string: "https://api.trakt.tv")!
    struct Reply: Sendable { let data: Data; let pageCount: Int }
    /// A write (Trakt allows one a second): waits out "too many requests", and never retries a
    /// write whose answer was lost, so a play is never sent twice.
    func post(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: Self.base.appending(path: path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TwilDiary/2.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(token.clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        try ProviderCooldowns.check(Self.base)
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
            if status == 429, attempt == 2, let http { ProviderCooldowns.record(Self.base, http) }
            // 429 means Trakt refused before writing anything, so asking again is safe.
            if status == 429 && attempt < 2 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(max(wait, 1), 30)))
                continue
            }
            if status == 420 { throw TraktWriteError(status: 420, message: "Trakt says your account is at its limit (HTTP 420) for \(path). A Trakt VIP account lifts it.") }
            if status == 401 || status == 403 { throw TraktWriteError(status: status, message: "Trakt didn’t accept the sign-in (HTTP \(status)). Reconnect Trakt, then try again.") }
            guard (200..<300).contains(status) else { throw TraktWriteError(status: status, message: "Trakt answered HTTP \(status) for \(path).") }
            return data
        }
        throw TraktWriteError(status: 429, message: "Trakt is busy right now. Try again in a minute.")
    }
    /// PUT or DELETE (a note): one try; a refusal or a lost answer throws.
    func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        try ProviderCooldowns.check(Self.base)
        var request = URLRequest(url: Self.base.appending(path: path), timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TwilDiary/2.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(token.clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
        if status == 429, let http { ProviderCooldowns.record(Self.base, http) }
        if status == 420 { throw TraktWriteError(status: 420, message: "Trakt says your account is at its notes limit (HTTP 420). A Trakt VIP account lifts it.") }
        guard (200..<300).contains(status) || (method == "DELETE" && status == 404) else { throw TraktWriteError(status: status, message: "Trakt answered HTTP \(status) for \(path).") }
        return data
    }
    func get(_ path: String, query: [String: String] = [:]) async throws -> Reply {
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The same identity as the Worker's Trakt requests, which Trakt's edge accepts.
        request.setValue("TwilDiary/2.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(token.clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer " + token.accessToken, forHTTPHeaderField: "Authorization")
        try ProviderCooldowns.check(Self.base)
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
            if status == 429, attempt == 2, let http { ProviderCooldowns.record(Self.base, http) }
            if status == 429 && attempt < 2 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(max(wait, 1), 30)))
                continue
            }
            if status == 401 || status == 403 { throw APIError.message("Trakt didn’t accept the sign-in (HTTP \(status)). Reconnect Trakt, then check again.") }
            guard (200..<300).contains(status) else { throw APIError.message("Trakt answered HTTP \(status) for \(path).") }
            return Reply(data: data, pageCount: Int(http?.value(forHTTPHeaderField: "X-Pagination-Page-Count") ?? "") ?? 1)
        }
        throw APIError.message("Trakt is busy right now. Try again in a minute.")
    }
}

/// A Trakt write that reached Trakt and was answered with this HTTP status.
struct TraktWriteError: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// What a failed write means for the edit.
enum TraktDelivery: Equatable, Sendable {
    /// Never left the phone (no network): safe to send later.
    case notSent
    /// Trakt may or may not have it (the answer was lost): check before sending again.
    case uncertain
    /// Trakt is busy or down (429 after waiting, 5xx): send later.
    case retryLater
    /// The sign-in needs renewing: keep it until Trakt is reconnected.
    case authBlocked
    /// Trakt refused this edit (other 4xx, account limit): sending it again won't help.
    case rejected

    static func of(_ error: Error) -> TraktDelivery {
        // Our own cool-down after the service asked us to slow down: nothing was sent.
        if let error = error as? APIError, case .message(let text) = error, text.contains("slow down") { return .retryLater }
        if let error = error as? TraktWriteError {
            switch error.status {
            case 401, 403: return .authBlocked
            case 429, 500...: return .retryLater
            default: return .rejected
            }
        }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return .rejected }
        let neverSent: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                                   NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
                                   NSURLErrorCallIsActive, NSURLErrorAppTransportSecurityRequiresSecureConnection]
        return neverSent.contains(error.code) ? .notSent : .uncertain
    }
}

/// Whether something removed on the service holding your diary is removed from the diary too
/// (on, the default) or put back from your diary on the next sync (off). Cinopsys asks the same.
enum ServiceRemovals {
    static let key = "applyServiceRemovals"
    static var apply: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// The last direct read of Trakt and how it compares with the diary (Trakt page → Direct from Trakt).
@MainActor @Observable final class TraktDirectStore {
    static let shared = TraktDirectStore()
    struct Report: Equatable {
        let seconds: Double
        let requests: Int
        /// Lists re-read this time; empty when Trakt reported no change.
        let fetched: [TraktDomain]
        /// Lists Trakt wouldn't give this time; re-read on the next check.
        let unavailable: [TraktDomain]
        let skipped: Int
        let comparison: TraktComparison
    }
    private(set) var library: TraktLibrary?
    private(set) var report: Report?
    private(set) var running = false
    var error: String?
    private var token: TraktDirectToken?
    /// Changes on sign-out. Reads and sends compare it after every wait, so work started for the
    /// previous account can't save, show or send anything once it's gone.
    @ObservationIgnored private var generation = UUID()
    private var file: URL
    private let traktFile: URL
    /// "On this phone" (no account): the same diary and edits as Trakt's, kept in its own file and
    /// never sent anywhere.
    static let localKey = "localDiary"
    private(set) var localOnly = UserDefaults.standard.bool(forKey: TraktDirectStore.localKey)
    private static let localFile = URL.applicationSupportDirectory.appending(path: "Local/library.json")
    init(file: URL = URL.applicationSupportDirectory.appending(path: "Trakt/library.json")) {
        self.traktFile = file
        self.file = UserDefaults.standard.bool(forKey: TraktDirectStore.localKey) ? Self.localFile : file
        library = (try? Data(contentsOf: self.file)).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
    }
    /// Switches between the on-this-phone diary and Trakt's copy (each keeps its own file).
    func useLocal(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.localKey)
        localOnly = on
        generation = UUID(); pending = []; token = nil; report = nil; plan = nil
        resetSender()
        file = on ? Self.localFile : traktFile
        library = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
        if on, library == nil {
            let empty = TraktLibrary(fetchedAt: Date.now.formatted(.iso8601))
            library = empty; save(empty)
        }
    }

    func check(store: DiaryStore) async {
        guard !running else { return }
        if localOnly { store.applyDiarySource(); return }
        if store.isPreview { error = "Direct Trakt reads need a real Trakt connection."; return }
        running = true; error = nil
        let started = Date.now, session = generation, editsAtStart = edits
        defer { if session == generation { running = false } }
        do {
            if token?.usable != true { token = try await store.traktToken() }
            guard session == generation, let token else { return }
            let client = TraktDirectClient(token: token)
            // Edits made offline go first; still offline means there's nothing to read either.
            guard await sendPending(client, owner: token.username, session: session, store: store) else { return }
            var requests = 1
            let activities = try TraktDecode.activities(from: try await client.get("/sync/last_activities").data)
            var library = self.library ?? TraktLibrary()
            let changed = activities.changed(since: library.activities)
            let due = TraktDomain.allCases.filter { changed.contains($0) }
            var skipped = 0, unavailable: [TraktDomain] = []
            for domain in due {
                do {
                    switch domain {
                    case .history:
                        let (items, bad, calls) = try await pages(client, "/sync/history", decode: TraktDecode.history)
                        library.plays = items; skipped += bad; requests += calls
                    case .ratings:
                        let (items, bad, calls) = try await both(client, "/sync/ratings", decode: TraktDecode.ratings)
                        library.ratings = items; skipped += bad; requests += calls
                    case .watchlist:
                        let (items, bad, calls) = try await both(client, "/sync/watchlist", decode: TraktDecode.listed)
                        library.watchlist = items; skipped += bad; requests += calls
                    case .favorites:
                        let (items, bad, calls) = try await both(client, "/sync/favorites", decode: TraktDecode.listed)
                        library.favorites = items; skipped += bad; requests += calls
                    case .dropped:
                        let (items, bad, calls) = try await pages(client, "/users/hidden/dropped", query: ["type": "show"], decode: TraktDecode.listed)
                        library.dropped = items; skipped += bad; requests += calls
                    case .notes:
                        let (items, bad, calls) = try await pages(client, "/users/me/notes", decode: TraktDecode.notes)
                        library.notes = items; skipped += bad; requests += calls
                    }
                } catch {
                    // Newer Trakt features: one that fails leaves the rest of the check intact.
                    guard [.favorites, .dropped, .notes].contains(domain) else { throw error }
                    unavailable.append(domain); requests += 1
                }
            }
            // A list Trakt wouldn't give keeps the old activity times, so the next check asks again.
            library.activities = unavailable.isEmpty ? activities : library.activities
            library.skipped = skipped
            library.fetchedAt = Date.now.formatted(.iso8601)
            // Signed out while reading: the previous account's lists are dropped, not saved.
            guard session == generation else { return }
            // You edited while this read was on its way: it predates the edit, so the screen keeps
            // your edit and Trakt is read again in a moment (with the edit on it).
            if edits != editsAtStart { refreshSoon(store: store, after: 2); return }
            self.library = library
            save(library)
            ServiceIDs.shared.learn(from: library)
            if store.traktHoldsDiary { rememberSeen(library) }
            // The diary on screen first; the comparison follows.
            if store.diaryFromTrakt { store.applyDiarySource() }
            // Compare with the server's diary (the record until the switch-over), not the Trakt view;
            // after it, only what that old copy has and Trakt lacks altogether.
            // The comparison and the plan read the whole library: worked out in the background.
            let analysis = await analysis(library, store: store)
            guard session == generation else { return }
            report = Report(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: due, unavailable: unavailable,
                            skipped: skipped, comparison: analysis.comparison)
            plan = analysis.plan
            autoFillIfNeeded(store: store)
        } catch {
            if !Task.isCancelled, session == generation { self.error = error.localizedDescription }
        }
    }

    /// Once Trakt holds the diary, what the old server copy has and Trakt lacks is copied in on its
    /// own after each read (so on every open), with nothing to tap; something removed on Trakt
    /// comes back only when your diary change is newer (see `settled`). Each item is tried on its
    /// own once per app session: one Trakt can't take (a title it can't find) stays listed for
    /// Sync now instead of being re-sent after every read, since the send itself reads Trakt again.
    private func autoFillIfNeeded(store: DiaryStore) {
        guard store.traktHoldsDiary, !store.isPreview, !writing, let plan, !plan.isEmpty else { return }
        let fresh = plan.tokens.subtracting(autoTried)
        guard !fresh.isEmpty else { return }
        autoTried.formUnion(plan.tokens)
        Task { await self.makeTraktMatch(store: store) }
    }
    @ObservationIgnored private var autoTried = Set<String>()
    /// Everything Trakt has held (plays, ratings, watchlist, favourites, dropped), as plan tokens.
    nonisolated static func tokens(_ library: TraktLibrary) -> Set<String> {
        func key(_ ref: TraktTitleRef) -> String? { ref.tmdbId.map { (ref.kind == .movie ? "movie:" : "tv:") + String($0) } }
        var result = Set<String>()
        for play in library.plays {
            guard let key = key(play.title) else { continue }
            result.insert("play|" + key + (play.title.kind == .movie ? "" : play.season.map { "|s\($0)e\(play.episode ?? 0)" } ?? ""))
        }
        for item in library.ratings { if let key = key(item.title) { result.insert("rating|" + key) } }
        for item in library.watchlist { if let key = key(item.title) { result.insert("planned|" + key) } }
        for item in library.favorites { if let key = key(item.title) { result.insert("favourite|" + key) } }
        for item in library.dropped { if let key = key(item.title) { result.insert("dropped|" + key) } }
        return result
    }
    private var seenFile: URL { file.deletingLastPathComponent().appending(path: "seen.json") }
    /// What Trakt has held since it took over the diary: a difference for one of these means it
    /// was removed on Trakt, which stands.
    @ObservationIgnored private var seenOnTrakt: Set<String> = []
    @ObservationIgnored private var seenLoaded = false
    private func loadSeen() {
        guard !seenLoaded else { return }
        seenLoaded = true
        seenOnTrakt = (try? Data(contentsOf: seenFile)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }
    private func rememberSeen(_ library: TraktLibrary) {
        loadSeen()
        let merged = seenOnTrakt.union(Self.tokens(library))
        guard merged.count != seenOnTrakt.count else { return }
        seenOnTrakt = merged
        try? JSONEncoder().encode(merged).write(to: seenFile, options: .atomic)
    }
    /// Left out of the differences and the copy: what Trakt held (or was sent) and no longer
    /// has, unless your change in the diary is newer than Trakt's last change to that list (the
    /// newer change wins). Without a time for the diary change, Trakt's removal stands.
    private func settled(_ library: TraktLibrary, _ diary: Workspace) -> Set<String> {
        loadSeen()
        return Self.settled(library, diary, known: copied.union(seenOnTrakt), removals: ServiceRemovals.apply)
    }
    nonisolated static func settled(_ library: TraktLibrary, _ diary: Workspace, known: Set<String>, removals: Bool) -> Set<String> {
        // Removals on Trakt switched off: the diary puts back what Trakt no longer has.
        guard removals else { return [] }
        let plan = TraktWritePlan.make(library: library, workspace: diary, fillOnly: true)
        return plan.tokens.filter { token in
            guard known.contains(token) else { return false }
            guard let mine = diaryTime(token, diary), let theirs = traktTime(token, library) else { return true }
            return mine <= theirs
        }
    }
    /// When the diary last changed what a token sends: the title for ratings and lists, the
    /// watch itself for a play.
    nonisolated static func diaryTime(_ token: String, _ diary: Workspace) -> Date? {
        let parts = token.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return nil }
        let ref = parts[1].split(separator: ":")
        guard ref.count == 2, let tmdb = Int(ref[1]) else { return nil }
        let series = ref[0] == "tv"
        guard let title = diary.activeTitles.first(where: { $0.tmdbId == tmdb && $0.isSeries == series }) else { return nil }
        guard parts[0] == "play" else { return DiaryDate.parse(title.updatedAt) }
        var episodeID: String?
        if parts.count > 2 {
            let numbers = parts[2].dropFirst().split(separator: "e").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            episodeID = diary.episodes.first { $0.titleId == title.id && $0.season == numbers[0] && $0.number == numbers[1] }?.id
            if episodeID == nil { return nil }
        }
        return diary.activeEvents.filter { $0.titleId == title.id && $0.episodeId == episodeID }
            .compactMap { DiaryDate.parse($0.recordedAt) }.max()
    }
    /// Trakt's last change to the list a token belongs to (from its activity times).
    nonisolated static func traktTime(_ token: String, _ library: TraktLibrary) -> Date? {
        let domain: TraktDomain
        switch token.split(separator: "|").first.map(String.init) {
        case "play": domain = .history
        case "rating": domain = .ratings
        case "planned": domain = .watchlist
        case "favourite": domain = .favorites
        case "dropped": domain = .dropped
        default: return nil
        }
        return domain.activityKeys.compactMap { library.activities?.stamps[$0] }.compactMap { DiaryDate.parse($0) }.max()
    }

    /// A paged list, up to 1,000 items a page (Trakt reports the page count), at most 100 pages.
    private func pages<Item>(_ client: TraktDirectClient, _ path: String, query: [String: String] = [:],
                             decode: (Data) throws -> (items: [Item], skipped: Int)) async throws -> ([Item], Int, Int) {
        var items: [Item] = [], skipped = 0, page = 1, count = 1, calls = 0
        repeat {
            var paged = query; paged["page"] = String(page); paged["limit"] = "1000"
            let reply = try await client.get(path, query: paged)
            let decoded = try decode(reply.data)
            items += decoded.items; skipped += decoded.skipped; calls += 1
            count = min(reply.pageCount, 100); page += 1
        } while page <= count
        return (items, skipped, calls)
    }
    /// A list Trakt splits into movies and shows (`…/movies`, `…/shows`), every page of each
    /// (Trakt pages watchlists, ratings and favourites for larger accounts). A page that fails
    /// fails the whole read, so a partial list never replaces the saved one.
    private func both<Item>(_ client: TraktDirectClient, _ path: String,
                            decode: (Data) throws -> (items: [Item], skipped: Int)) async throws -> ([Item], Int, Int) {
        let movies = try await pages(client, path + "/movies", decode: decode)
        let shows = try await pages(client, path + "/shows", decode: decode)
        return (movies.0 + shows.0, movies.1 + shows.1, movies.2 + shows.2)
    }

    /// Written in the background (a run of edits writes once); the copy on screen is the record
    /// until then, and the next check saves it again if a write fails.
    private func save(_ library: TraktLibrary) {
        BackgroundFiles.save(library, to: file, protected: true, excludeFolderFromBackup: true)
    }
    // MARK: Phase 2: make Trakt match the diary

    private(set) var writing = false
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
    @ObservationIgnored private var refresh: Task<Void, Never>?
    private(set) var writeProgress: String?
    private(set) var writeResult: String?
    /// The plan from the last read, for the pages to show (worked out once per read, not on every
    /// redraw; sending always works it out afresh).
    private(set) var plan: TraktWritePlan?
    /// What "Make Trakt match" would send, from the last read (nil before a read). Once Trakt
    /// holds the diary: only what the old server copy has and Trakt lacks, each thing once.
    func matchPlan(store: DiaryStore) -> TraktWritePlan? {
        let fill = store.traktHoldsDiary
        return library.map { TraktWritePlan.make(library: $0, workspace: store.serverDiary, fillOnly: fill, except: fill ? settled($0, store.serverDiary) : []) }
    }
    private func comparison(_ library: TraktLibrary, store: DiaryStore) -> TraktComparison {
        let fill = store.traktHoldsDiary
        return TraktComparison.compare(library, with: store.serverDiary, oneWay: fill, except: fill ? settled(library, store.serverDiary) : [])
    }
    /// The comparison with the diary and the plan for "Make Trakt match", away from the main thread.
    private func analysis(_ library: TraktLibrary, store: DiaryStore) async -> (comparison: TraktComparison, plan: TraktWritePlan) {
        let fill = store.traktHoldsDiary, diary = store.serverDiary
        loadSeen()
        let known = copied.union(seenOnTrakt), removals = ServiceRemovals.apply
        return await Task.detached(priority: .utility) {
            let except = fill ? Self.settled(library, diary, known: known, removals: removals) : []
            return (TraktComparison.compare(library, with: diary, oneWay: fill, except: except),
                    TraktWritePlan.make(library: library, workspace: diary, fillOnly: fill, except: except))
        }.value
    }
    /// Things already copied from the old server copy into Trakt (never offered twice, so
    /// something you later take off Trakt stays off).
    private var copied: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "trakt.copiedFromServer") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "trakt.copiedFromServer") }
    }
    /// Sends the plan to Trakt one request a second, marks Trakt-only favourites in the diary,
    /// then reads Trakt again so the comparison shows the result.
    func makeTraktMatch(store: DiaryStore) async {
        guard !writing, !running, let plan = matchPlan(store: store), !plan.isEmpty else { return }
        if store.isPreview { error = "Writing to Trakt needs a real Trakt connection."; return }
        writing = true; error = nil; writeResult = nil
        defer { writing = false; writeProgress = nil }
        var sent = 0, tally = ReplyTally(), notFound = Set<String>()
        let session = generation
        do {
            if token?.usable != true { token = try await store.traktToken() }
            guard session == generation, let token else { return }
            let client = TraktDirectClient(token: token)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                try await pace()
                guard session == generation else { return }
                let reply = try await client.post(request.path, body: request.body)
                sent += request.count
                tally.add(reply)
                notFound.formUnion(Self.notFoundKeys(reply))
            }
            guard session == generation else { return }
            // Straight to the server's record of each title: the usual edit path would send a
            // favourite to Trakt in the Trakt diary, and the comparison would never settle.
            for id in plan.diaryFavourites {
                if let title = store.serverDiary.titles.first(where: { $0.id == id }) {
                    let _: EmptyResponse? = try? await store.read("/api/titles/\(title.id)", method: "PATCH", body: ["favorite": true, "expectedVersion": title.version ?? 1])
                }
            }
            if !plan.diaryFavourites.isEmpty { try? await store.reload() }
            // Only what Trakt accepted counts as copied: a title it couldn't find stays listed.
            if store.traktHoldsDiary {
                copied.formUnion(plan.tokens.filter { token in
                    let parts = token.split(separator: "|")
                    return parts.count < 2 || !notFound.contains(String(parts[1]))
                })
            }
            writeResult = "Sent to Trakt: " + plan.summary.joined(separator: "; ") + ". " + tally.text(service: "Trakt")
                + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) diary watches have no date and were left out." : "")
        } catch {
            if !Task.isCancelled, session == generation { self.error = (sent > 0 ? "Sent \(sent) before stopping. " : "") + error.localizedDescription }
        }
        guard session == generation else { return }
        await check(store: store)
    }
    // MARK: Phase 4b: edits in the Trakt diary

    /// "Watching now" on Trakt: a movie, or one episode of a show. Trakt logs the play itself once
    /// its runtime ends (it shows on the next read). Returns what to tell you.
    func checkIn(_ title: MediaTitle, episode: Episode?, store: DiaryStore) async throws -> String {
        if store.isPreview || localOnly { throw APIError.message("Checking in needs a Trakt account.") }
        guard let tmdb = title.tmdbId else { throw APIError.message("“\(title.name)” has no TMDB id, so Trakt can’t find it.") }
        let client = try await self.client(store: store)
        var body: [String: Any] = ["app_version": "2.0.0"]
        if title.isSeries {
            guard let episode else { throw APIError.message("There’s no next episode to check in to.") }
            body["show"] = ["ids": ["tmdb": tmdb]]
            body["episode"] = ["season": episode.season, "number": episode.number]
        } else { body["movie"] = ["ids": ["tmdb": tmdb]] }
        try await pace()
        do { _ = try await client.send("POST", "/checkin", body: try JSONSerialization.data(withJSONObject: body)) }
        catch let error as TraktWriteError where error.status == 409 {
            throw APIError.message("You’re already checked in to something on Trakt. It ends on its own when that finishes.")
        }
        refreshSoon(store: store)
        return title.isSeries ? "Checked in to \(title.name) S\(episode?.season ?? 0) E\(episode?.number ?? 0) on Trakt. It’s logged when the episode ends." : "Checked in to \(title.name) on Trakt. It’s logged when the movie ends."
    }
    /// A title's note on Trakt: a new note, the changed text, or (empty) removed. Trakt keeps 500
    /// characters; the phone's copy is updated at once.
    func setNote(_ text: String, for title: TraktTitleRef, store: DiaryStore) async throws {
        if store.isPreview { throw APIError.message("Writing to Trakt needs a real Trakt connection.") }
        if localOnly {
            let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
            update(store: store) { library in
                library.notes.removeAll { $0.title?.diaryKey == title.diaryKey }
                if !kept.isEmpty { library.notes.append(TraktNote(id: -TrackerDecode.playID("note|" + (title.diaryKey ?? title.name)), title: title, text: kept, updatedAt: Date.now.formatted(.iso8601))) }
            }
            return
        }
        let client = try await self.client(store: store)
        let kept = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let existing = library?.notes.first { $0.title?.diaryKey == title.diaryKey }
        try await pace()
        var saved: TraktNote?
        if let existing {
            if kept.isEmpty { _ = try await client.send("DELETE", "/notes/\(existing.id)") }
            else {
                let reply = try await client.send("PUT", "/notes/\(existing.id)", body: try JSONSerialization.data(withJSONObject: ["notes": kept]))
                saved = TraktNote(id: existing.id, title: existing.title, text: kept, updatedAt: (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["updated_at"] as? String)
            }
        } else if !kept.isEmpty {
            let slot = title.kind == .movie ? "movie" : "show"
            let body: [String: Any] = [slot: ["ids": ["tmdb": title.tmdbId ?? 0]], "notes": kept, "privacy": "private", "spoiler": false]
            let reply = try await client.send("POST", "/notes", body: try JSONSerialization.data(withJSONObject: body))
            let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            if let id = (object?["id"] as? NSNumber)?.int64Value { saved = TraktNote(id: id, title: title, text: kept, updatedAt: object?["updated_at"] as? String) }
        }
        update(store: store) { library in
            library.notes.removeAll { $0.title?.diaryKey == title.diaryKey }
            if let saved { library.notes.append(saved) }
        }
    }

    /// One write to Trakt with the server's token (one a second at most, waiting out 429s).
    /// An edit that may still reach Trakt is kept and sent before the next read instead of failing
    /// (no connection, Trakt busy or down, sign-in to renew, or an answer lost on the way, which is
    /// checked against Trakt before anything is sent twice). Only a real refusal throws, and so
    /// does a title Trakt couldn't find: the caller then leaves the phone's copy unchanged.
    /// An edit, the way Cinopsys makes it: kept on the phone (in order) while the screen already
    /// shows it, and sent to Trakt at once in the background (with the next sync when Instant sync
    /// is off or you're offline). An edit Trakt refuses puts the screen back as Trakt has it, and
    /// says so. `resolve`: a removal of plays Trakt has no id for here yet (just added), looked up
    /// in Trakt's history at their time when its turn comes.
    func write(_ path: String, body: [String: Any], store: DiaryStore, resolve: Bool = false) throws {
        if store.isPreview { throw APIError.message("Writing to Trakt needs a real Trakt connection.") }
        if localOnly { return }  // On this phone: the copy is the diary.
        let data = try JSONSerialization.data(withJSONObject: body)
        pending.append(PendingWrite(path: path, body: data, owner: token?.username, resolve: resolve ? true : nil))
        if instantSync { flush(store: store) }
    }
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var sending = false
    /// The edit being sent right now (Undo leaves it alone: it may already be on Trakt).
    @ObservationIgnored private var inFlight: String?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    private func resetSender() {
        flushing = false; sending = false; inFlight = nil; retries = 0
        retry?.cancel(); retry = nil
    }
    /// Sends what's waiting now, in the background; a quiet read then gives new plays their Trakt ids.
    func flush(store: DiaryStore) {
        guard !flushing, !localOnly, !store.isPreview, !pending.isEmpty else { return }
        flushing = true
        let session = generation
        Task { [weak self] in
            guard let self else { return }
            var sent = false
            do {
                if self.token?.usable != true { self.token = try await store.traktToken() }
                if session == self.generation, let token = self.token {
                    sent = await self.sendPending(TraktDirectClient(token: token), owner: token.username, session: session, store: store)
                }
            } catch {}
            guard session == self.generation else { return }
            self.flushing = false
            if sent { self.refreshSoon(store: store) } else { self.retryLater(store: store) }
        }
    }
    /// Couldn't send yet (offline, Trakt busy): tries again in 30 seconds, ten times at most; after
    /// that the next sync sends it (opening the app, every ten minutes, Sync now).
    private func retryLater(store: DiaryStore) {
        guard retry == nil, !pending.isEmpty, retries < 10 else { return }
        retries += 1
        let session = generation
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, session == self.generation else { return }
            self.retry = nil
            self.flush(store: store)
        }
    }

    // MARK: Trakt page options

    /// Settings → Trakt → Instant sync. On, each edit goes to Trakt as you make it; off, edits
    /// wait on this iPhone (in order) and go with the next sync: Sync now, Force sync or a refresh.
    var instantSync: Bool = UserDefaults.standard.object(forKey: "trakt.instantSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(instantSync, forKey: "trakt.instantSync") }
    }
    /// Force sync: forget what was last read, so every list is read again from Trakt.
    func forceCheck(store: DiaryStore) async {
        guard !running else { return }
        library?.activities = nil
        await check(store: store)
        if plan?.isEmpty == false { await makeTraktMatch(store: store) }
    }
    /// What Trakt allows this account (list counts, items per list, watchlist and favourites).
    func accountLimits(store: DiaryStore) async throws -> [TraktAccountLimit] {
        let reply = try await client(store: store).get("/users/settings")
        let root = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
        let vip = ((root?["user"] as? [String: Any])?["vip"] as? Bool) == true
        guard let limits = root?["limits"] as? [String: Any] else { return [] }
        var rows: [TraktAccountLimit] = []
        for (group, value) in limits.sorted(by: { $0.key < $1.key }) {
            guard let values = value as? [String: Any] else { continue }
            for (name, amount) in values.sorted(by: { $0.key < $1.key }) {
                guard let number = amount as? Int else { continue }
                rows.append(TraktAccountLimit(group: group, name: name, value: number, vip: vip))
            }
        }
        return rows
    }

    // MARK: Edits waiting for a connection

    struct PendingWrite: Codable, Equatable {
        /// Names this edit while it waits (sending and Undo go by it).
        var id: String? = UUID().uuidString
        let path: String
        let body: Data
        /// The Trakt account it was made for; never sent under another one.
        var owner: String?
        /// The answer was lost: Trakt may already have it (checked before sending again).
        var uncertain: Bool?
        /// Plays to remove that Trakt has no id for here yet: found in its history at their time first.
        var resolve: Bool?
    }
    /// Kept on the phone (in order) until Trakt takes them.
    private(set) var pending: [PendingWrite] = TraktDirectStore.loadPending() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "trakt.pendingWrites") }
    }
    nonisolated private static func loadPending() -> [PendingWrite] {
        let saved = (UserDefaults.standard.data(forKey: "trakt.pendingWrites")).flatMap { try? JSONDecoder().decode([PendingWrite].self, from: $0) } ?? []
        return saved.map { write in
            var write = write
            if write.id == nil { write.id = UUID().uuidString }
            return write
        }
    }
    /// Sends what's waiting, oldest first; false while Trakt can't take them yet (then nothing is
    /// read either, so the phone keeps showing your edits). A watch whose answer was lost is first
    /// looked up in Trakt's history at its time, and only the plays missing there are sent, so a
    /// play is never doubled. An edit Trakt refuses, or one made for another Trakt account, is
    /// dropped and said: Trakt is the record, and the read that follows shows what it kept.
    private func sendPending(_ client: TraktDirectClient, owner: String, session: UUID, store: DiaryStore?) async -> Bool {
        // One sender at a time (an edit's send and a sync's), so nothing goes twice.
        guard !sending else { return false }
        sending = true
        defer { if session == generation { sending = false; inFlight = nil } }
        while let next = pending.first {
            guard session == generation, !Task.isCancelled else { return false }
            if let other = next.owner, other != owner {
                pending.removeAll { $0.id == next.id }
                self.error = "An edit kept for another Trakt account was discarded."
                continue
            }
            inFlight = next.id
            var body: Data? = next.body
            do {
                // Looking plays up first: a failed look-up keeps the edit for the next try.
                if next.resolve == true { body = try await resolvedRemoval(next.body, client: client) }
                else if next.uncertain == true, next.path == "/sync/history" { body = try await missingPlays(next.body, client: client) }
            } catch { return false }
            do {
                guard session == generation else { return false }
                if let body {
                    try await pace()
                    let reply = try await client.post(next.path, body: body)
                    guard session == generation else { return false }
                    if Self.notFoundCount(reply) > 0 { refused("Trakt couldn’t find a title by its TMDB id, so it wasn’t changed there.", store: store) }
                }
                pending.removeAll { $0.id == next.id }
            } catch {
                guard session == generation, !Task.isCancelled else { return false }
                switch TraktDelivery.of(error) {
                case .notSent, .retryLater:
                    return false
                case .uncertain:
                    if let index = pending.firstIndex(where: { $0.id == next.id }) { pending[index].uncertain = true }
                    return false
                case .authBlocked:
                    self.error = "Trakt needs you to reconnect. Your changes are kept and sent once it’s reconnected."
                    store?.error = self.error
                    return false
                case .rejected:
                    pending.removeAll { $0.id == next.id }
                    refused("Trakt refused a change: " + error.localizedDescription, store: store)
                }
            }
            inFlight = nil
        }
        retries = 0
        return true
    }
    /// A change Trakt refused or couldn't place: you're told, and the screen goes back to what
    /// Trakt has (each list an edit touched is read again).
    private func refused(_ message: String, store: DiaryStore?) {
        error = message
        store?.error = message
        if let store { refreshSoon(store: store, after: 1) }
    }
    /// A removal of plays Trakt has no id for here yet (just added): each is found in Trakt's
    /// history at its time (the same title, season and episode, the nearest within a minute),
    /// as Cinopsys does, and removed by its id. nil when none is there (nothing to remove).
    private func resolvedRemoval(_ body: Data, client: TraktDirectClient) async throws -> Data? {
        let wanted = Self.requestedPlays(body)
        let times = wanted.compactMap(\.when)
        guard let first = times.min(), let last = times.max() else { return nil }
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let window = ["start_at": format.format(first.addingTimeInterval(-60)), "end_at": format.format(last.addingTimeInterval(60)), "limit": "1000"]
        let found = try TraktDecode.history(from: try await client.get("/sync/history", query: window).data).items
        let ids = Self.historyIDs(for: wanted, in: found)
        guard !ids.isEmpty else { return nil }
        return try JSONSerialization.data(withJSONObject: ["ids": ids])
    }
    /// Each wanted play's Trakt history id: the same title, season and episode, the nearest within a minute.
    nonisolated static func historyIDs(for wanted: [(tmdb: Int?, movie: Bool, season: Int?, episode: Int?, when: Date?)], in found: [TraktPlay]) -> [Int64] {
        var ids: [Int64] = []
        for play in wanted {
            guard let when = play.when else { continue }
            var best: (id: Int64, gap: TimeInterval)?
            for candidate in found where candidate.historyId > 0 && !ids.contains(candidate.historyId)
                && candidate.title.tmdbId == play.tmdb && (candidate.title.kind == .movie) == play.movie
                && candidate.season == play.season && candidate.episode == play.episode {
                guard let at = candidate.watchedAt.flatMap(DiaryDate.parse) else { continue }
                let gap = abs(at.timeIntervalSince(when))
                if gap <= 60, gap < (best?.gap ?? .infinity) { best = (candidate.historyId, gap) }
            }
            if let best { ids.append(best.id) }
        }
        return ids
    }
    /// The plays a Trakt-shaped body names: the movie, or the show's episode, with its time.
    nonisolated static func requestedPlays(_ body: Data) -> [(tmdb: Int?, movie: Bool, season: Int?, episode: Int?, when: Date?)] {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return [] }
        func tmdb(_ item: [String: Any]) -> Int? { ((item["ids"] as? [String: Any])?["tmdb"] as? NSNumber)?.intValue }
        var plays: [(tmdb: Int?, movie: Bool, season: Int?, episode: Int?, when: Date?)] = []
        for movie in (root["movies"] as? [[String: Any]]) ?? [] {
            plays.append((tmdb(movie), true, nil, nil, DiaryDate.parse(movie["watched_at"] as? String)))
        }
        for show in (root["shows"] as? [[String: Any]]) ?? [] {
            for season in (show["seasons"] as? [[String: Any]]) ?? [] {
                for episode in (season["episodes"] as? [[String: Any]]) ?? [] {
                    plays.append((tmdb(show), false, (season["number"] as? NSNumber)?.intValue, (episode["number"] as? NSNumber)?.intValue,
                                  DiaryDate.parse(episode["watched_at"] as? String)))
                }
            }
        }
        return plays
    }
    /// Puts a backup back into Trakt while Trakt holds the diary: only what Trakt lacks (plays
    /// not there at their time, ratings Trakt has none for, Planned for titles never watched,
    /// favourites, dropped shows). Nothing on Trakt is changed or removed, so running it twice
    /// adds nothing twice; the answer counts what Trakt accepted, not what was asked.
    func restore(_ backup: Workspace, store: DiaryStore) async throws -> String {
        if localOnly {
            // On this phone: what the diary lacks from the backup goes straight into it.
            let plan = TraktWritePlan.make(library: library ?? TraktLibrary(), workspace: backup, fillOnly: true)
            guard !plan.isEmpty else { return "Your diary already has everything in this backup." }
            func ref(_ title: TraktWritePlan.Ref) -> TraktTitleRef { TraktTitleRef(kind: title.movie ? .movie : .show, traktId: nil, tmdbId: title.tmdbId, name: title.name) }
            update(store: store) { library in
                for play in plan.plays {
                    library.plays.append(TraktPlay(historyId: -TrackerDecode.playID("restore|\(play.title.tmdbId)|\(play.season ?? -1)|\(play.episode ?? -1)|\(play.watchedAt)"),
                                                   title: ref(play.title), season: play.season, episode: play.episode, watchedAt: play.watchedAt))
                }
                for rating in plan.ratings { library.ratings.append(TraktRating(title: ref(rating.title), rating: rating.rating, ratedAt: nil)) }
                library.watchlist += plan.watchlistAdd.map { TraktListed(title: ref($0), listedAt: nil) }
                library.favorites += plan.favouritesAdd.map { TraktListed(title: ref($0), listedAt: nil) }
                library.dropped += plan.dropped.map { TraktListed(title: ref($0), listedAt: nil) }
            }
            return "Restored to the diary on this phone: " + plan.summary.joined(separator: "; ") + "."
        }
        guard !writing, !running else { throw APIError.message("Trakt is busy right now. Try again in a moment.") }
        let session = generation, before = library?.fetchedAt
        await check(store: store)
        guard session == generation else { throw CancellationError() }
        // A fresh read is needed (a note left by sending queued edits isn't a failure).
        guard let library, library.fetchedAt != before || before == nil else {
            throw APIError.message("Trakt couldn’t be read, so nothing was restored. " + (error ?? "Check your connection and try again."))
        }
        let plan = TraktWritePlan.make(library: library, workspace: backup, fillOnly: true)
        guard !plan.isEmpty else { return "Trakt already has everything in this backup." }
        writing = true
        defer { if session == generation { writing = false; writeProgress = nil } }
        if token?.usable != true { token = try await store.traktToken() }
        guard session == generation, let token else { throw CancellationError() }
        let client = TraktDirectClient(token: token)
        var tally = ReplyTally(), sent = 0
        let requests = plan.requests()
        do {
            for (index, request) in requests.enumerated() {
                writeProgress = "Restoring \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                try await pace()
                guard session == generation else { throw CancellationError() }
                tally.add(try await client.post(request.path, body: request.body))
                sent += request.count
            }
        } catch {
            writing = false
            await check(store: store)
            throw APIError.message((sent > 0 ? "Restored \(sent) before stopping; run it again to finish (nothing is added twice). " : "") + error.localizedDescription)
        }
        writing = false
        await check(store: store)
        return "Restored to Trakt: " + plan.summary.joined(separator: "; ") + ". " + tally.text(service: "Trakt")
            + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) watches in the backup have no date and were left out." : "")
    }
    /// Takes queued history writes for plays at this time out of the queue (Undo before they
    /// reached Trakt); true when there were any.
    func cancelPending(watchedAt when: String) -> Bool {
        let before = pending.count
        // One whose answer was lost may already be on Trakt: that one is read and removed there instead.
        pending.removeAll { $0.id != inFlight && $0.uncertain != true && $0.path == "/sync/history" && String(decoding: $0.body, as: UTF8.self).contains(when) }
        return pending.count != before
    }
    /// For a history write whose answer was lost: Trakt's history at that time (a minute either
    /// side) is read, and only the plays not there are kept; nil when all of them already are.
    private func missingPlays(_ body: Data, client: TraktDirectClient) async throws -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        var times: [Date] = []
        for movie in (root["movies"] as? [[String: Any]]) ?? [] { if let when = DiaryDate.parse(movie["watched_at"] as? String) { times.append(when) } }
        for show in (root["shows"] as? [[String: Any]]) ?? [] {
            for season in (show["seasons"] as? [[String: Any]]) ?? [] {
                for episode in (season["episodes"] as? [[String: Any]]) ?? [] { if let when = DiaryDate.parse(episode["watched_at"] as? String) { times.append(when) } }
            }
        }
        guard let first = times.min(), let last = times.max() else { return body }
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let window = ["start_at": format.format(first.addingTimeInterval(-60)), "end_at": format.format(last.addingTimeInterval(60)), "limit": "1000"]
        let found = try TraktDecode.history(from: try await client.get("/sync/history", query: window).data).items
        func there(_ tmdb: Int?, movie: Bool, season: Int?, episode: Int?, at when: Date?) -> Bool {
            found.contains { play in
                play.title.tmdbId == tmdb && (play.title.kind == .movie) == movie && play.season == season && play.episode == episode
                    && (when == nil || play.watchedAt.flatMap(DiaryDate.parse).map { abs($0.timeIntervalSince(when!)) <= 60 } == true)
            }
        }
        func tmdb(_ item: [String: Any]) -> Int? { ((item["ids"] as? [String: Any])?["tmdb"] as? NSNumber)?.intValue }
        let movies = ((root["movies"] as? [[String: Any]]) ?? []).filter {
            !there(tmdb($0), movie: true, season: nil, episode: nil, at: DiaryDate.parse($0["watched_at"] as? String))
        }
        var shows: [[String: Any]] = []
        for var show in (root["shows"] as? [[String: Any]]) ?? [] {
            var seasons: [[String: Any]] = []
            for var season in (show["seasons"] as? [[String: Any]]) ?? [] {
                let number = (season["number"] as? NSNumber)?.intValue
                let episodes = ((season["episodes"] as? [[String: Any]]) ?? []).filter {
                    !there(tmdb(show), movie: false, season: number, episode: ($0["number"] as? NSNumber)?.intValue, at: DiaryDate.parse($0["watched_at"] as? String))
                }
                if !episodes.isEmpty { season["episodes"] = episodes; seasons.append(season) }
            }
            if !seasons.isEmpty { show["seasons"] = seasons; shows.append(show) }
        }
        guard !movies.isEmpty || !shows.isEmpty else { return nil }
        root["movies"] = movies; root["shows"] = shows
        return try JSONSerialization.data(withJSONObject: root)
    }
    /// A Trakt client with your server's token, for reads outside the library (community info).
    func client(store: DiaryStore) async throws -> TraktDirectClient {
        if store.isPreview { throw APIError.message("Trakt reads need a real Trakt connection.") }
        if token?.usable != true { token = try await store.traktToken() }
        guard let token else { throw APIError.message("Trakt isn’t connected.") }
        return TraktDirectClient(token: token)
    }
    /// Applies an edit to the phone's Trakt copy and redraws the Trakt diary at once.
    /// Counts edits applied to the phone's copy (a read that started before one is not saved).
    @ObservationIgnored private var edits = 0
    func update(store: DiaryStore, _ change: (inout TraktLibrary) -> Void) {
        guard var value = library else { return }
        edits += 1
        let before = value
        change(&value)
        // Trakt is the record: every list this edit touched is read again from Trakt on the next
        // check, even if Trakt's activity times didn't move (an edit Trakt quietly didn't apply,
        // such as a title it couldn't find, then disappears instead of showing forever).
        var touched: [TraktDomain] = []
        if value.plays != before.plays { touched.append(.history) }
        if value.ratings != before.ratings { touched.append(.ratings) }
        if value.watchlist != before.watchlist { touched.append(.watchlist) }
        if value.favorites != before.favorites { touched.append(.favorites) }
        if value.dropped != before.dropped { touched.append(.dropped) }
        if let activities = value.activities, !touched.isEmpty {
            let keys = Set(touched.flatMap(\.activityKeys))
            value.activities = TraktActivities(all: nil, stamps: activities.stamps.filter { !keys.contains($0.key) })
        }
        library = value
        save(value)
        store.applyDiarySource()
    }
    /// A quiet re-read ten seconds after the last edit (a run of edits makes one read), so new plays get their real Trakt ids
    /// (needed to remove exactly that play later).
    func refreshSoon(store: DiaryStore, after seconds: Double = 10) {
        if localOnly { return }
        refresh?.cancel()
        let session = generation
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, session == self.generation else { return }
            await self.check(store: store)
        }
    }

    /// What a service's write replies said: added, already there, not found.
    struct ReplyTally {
        var added = 0, existing = 0, notFound = 0
        mutating func add(_ data: Data) {
            notFound += TraktDirectStore.notFoundCount(data)
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            func total(_ value: Any?) -> Int {
                if let number = value as? Int { return number }
                guard let counts = value as? [String: Any] else { return 0 }
                return counts.values.reduce(0) { $0 + (($1 as? Int) ?? 0) }
            }
            added += total(root["added"]) + total(root["updated"])
            existing += total(root["existing"])
        }
        func text(service: String) -> String {
            var parts: [String] = []
            if added > 0 { parts.append("\(service) added \(added)") }
            if existing > 0 { parts.append("\(existing) already there") }
            if notFound > 0 { parts.append("\(notFound) not found by TMDB id") }
            return parts.isEmpty ? "" : parts.joined(separator: ", ") + "."
        }
    }

    /// The titles in a write reply's "not_found" lists, as "movie:603" / "tv:1399".
    nonisolated static func notFoundKeys(_ data: Data) -> Set<String> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let missing = root["not_found"] as? [String: Any] else { return [] }
        var keys = Set<String>()
        for (list, prefix) in [("movies", "movie:"), ("shows", "tv:")] {
            for case let item as [String: Any] in (missing[list] as? [Any]) ?? [] {
                if let tmdb = ((item["ids"] as? [String: Any])?["tmdb"] as? NSNumber)?.intValue { keys.insert(prefix + String(tmdb)) }
            }
        }
        return keys
    }
    /// Trakt's "not_found" lists in a write reply.
    nonisolated static func notFoundCount(_ data: Data) -> Int {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        if let list = root["not_found"] as? [Any] { return list.count }
        guard let missing = root["not_found"] as? [String: Any] else { return 0 }
        return missing.values.reduce(0) { $0 + (($1 as? [Any])?.count ?? 0) }
    }

    /// Sign-out: the Trakt copy is diary data, so it goes with the diary.
    /// Edits still waiting for Trakt go too (the sign-out warning counts them), and anything
    /// already running for this account can no longer save, show or send.
    /// The next read or send fetches a token again (after a new sign-in on this iPhone).
    func dropToken() { token = nil }
    func forget() {
        generation = UUID()
        refresh?.cancel(); refresh = nil
        // Work still running for the old account no longer resets these (it checks the session),
        // so they're cleared here; otherwise "busy" would stay on and stop the automatic reads.
        running = false; writing = false; writeProgress = nil
        library = nil; report = nil; token = nil; error = nil; writeResult = nil; plan = nil; pending = []
        resetSender()
        BackgroundFiles.cancel(file)
        seenOnTrakt = []; seenLoaded = true; autoTried = []
        // The on-this-phone diary is yours alone: leaving it never deletes it.
        if !localOnly { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: seenFile)
    }
}

/// The same read-and-compare preview for Simkl and MDBList as the main tracker. Trakt keeps its own
/// store above (its lists are fetched one by one); these two are read whole when anything changed.
@MainActor @Observable final class TrackerPreviewStore {
    static let shared = TrackerPreviewStore()
    private(set) var libraries: [MainTracker: TraktLibrary] = [:]
    private(set) var reports: [MainTracker: TraktDirectStore.Report] = [:]
    private(set) var running: MainTracker?
    var errors: [MainTracker: String] = [:]
    private(set) var writing: MainTracker?
    private(set) var writeProgress: String?
    private(set) var writeResults: [MainTracker: String] = [:]
    /// Each service's plan from its last read (see `TraktDirectStore.plan`).
    private(set) var plans: [MainTracker: TraktWritePlan] = [:]
    /// Changes on sign-out (see `TraktDirectStore.generation`).
    @ObservationIgnored private var generation = UUID()
    private let folder: URL
    init(folder: URL = URL.applicationSupportDirectory.appending(path: "Trackers")) {
        self.folder = folder
        for tracker in [MainTracker.simkl, .mdblist, .wetrakr] {
            libraries[tracker] = (try? Data(contentsOf: file(tracker))).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
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
            let activitiesData = try await client.read(config, path: tracker == .simkl ? "/sync/activities" : "/sync/last_activities")
            let activities = try (tracker == .simkl ? TraktDecode.activities(from: activitiesData)
                                  : tracker == .wetrakr ? WeTrakrDecode.activities(from: activitiesData) : TrackerDecode.flatActivities(from: activitiesData))
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
            } else if tracker == .simkl {
                // Simkl's sync rules: the whole library once, then only what changed.
                let fullQuery = ["extended": "full", "episode_watched_at": "yes", "memos": "yes", "include_all_episodes": "yes"]
                func fullPull() async throws {
                    library = try TrackerDecode.simklLibrary(from: try await client.read(config, path: "/sync/all-items/", query: fullQuery))
                    requests += 1
                    fetched = [.history, .ratings, .watchlist, .dropped, .notes]
                }
                switch SimklSync.step(previous: libraries[tracker], now: activities) {
                case .none:
                    break
                case .full:
                    try await fullPull()
                case .delta(let items, let ratings, let removals, let since):
                    if items {
                        var query = fullQuery; query["date_from"] = since
                        let data = try await client.read(config, path: "/sync/all-items/", query: query)
                        library = SimklSync.merge(try TrackerDecode.simklLibrary(from: data), touched: (try? TrackerDecode.simklIDs(from: data)) ?? [], into: library)
                        requests += 1
                        fetched += [.history, .watchlist, .dropped, .notes]
                    }
                    if ratings {
                        // Ratings aren't in item deltas; the rated lists are small, so they're read whole
                        // (that also catches a rating taken off).
                        var all: [TraktRating] = []
                        for type in ["movies", "shows", "anime"] {
                            all += try TrackerDecode.simklRatings(from: try await client.read(config, path: "/sync/ratings/" + type))
                            requests += 1
                        }
                        library.ratings = all
                        fetched.append(.ratings)
                    }
                    if removals {
                        requests += 1
                        if let ids = try? TrackerDecode.simklIDs(from: try await client.read(config, path: "/sync/all-items/", query: ["extended": "simkl_ids_only"])) {
                            library = SimklSync.removing(from: library, keeping: ids)
                        } else {
                            try await fullPull()
                        }
                    }
                }
                library.activities = activities
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
                            let result = try MDBListJournal.apply(try await client.read(config, path: "/sync/journal", query: query), to: &copy)
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
                    library.plays = watched.items.map { item in
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
            libraries[tracker] = library
            save(library, tracker)
            ServiceIDs.shared.learn(from: library)
            if store.diaryFromTracker == tracker { store.applyDiarySource() }
            // The comparison and the plan read the whole library: worked out in the background.
            let diary = store.diaryToMatch, planned = store.diaryService != tracker && store.serverRecord != tracker, read = library
            let (comparison, plan) = await Task.detached(priority: .utility) {
                (TraktComparison.compare(read, with: diary, tracker: tracker),
                 planned ? TraktWritePlan.make(library: read, workspace: diary, tracker: tracker) : nil)
            }.value
            guard session == generation else { return }
            reports[tracker] = .init(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: fetched, unavailable: [],
                                     skipped: library.skipped, comparison: comparison)
            plans[tracker] = plan
        } catch {
            if !Task.isCancelled, session == generation { errors[tracker] = error.localizedDescription }
        }
    }

    // MARK: Phase 5: edits in the Simkl / MDBList diary

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
    @ObservationIgnored private var refresh: Task<Void, Never>?
    // MARK: Edits waiting for the service (as Cinopsys keeps them)

    struct PendingWrite: Codable, Equatable {
        var id: String? = UUID().uuidString
        let path: String
        let body: Data
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
        pending[tracker, default: []].append(PendingWrite(path: path, body: data))
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
                if TraktDirectStore.notFoundCount(reply) > 0 {
                    refused(tracker, "\(tracker.name) couldn’t find a title by its TMDB id, so it wasn’t changed there.", store: store)
                }
            } catch {
                guard session == generation, !Task.isCancelled else { return false }
                switch Self.delivery(error) {
                case .rejected:
                    pending[tracker]?.removeAll { $0.id == next.id }
                    refused(tracker, "\(tracker.name) refused a change: " + error.localizedDescription, store: store)
                case .authBlocked:
                    errors[tracker] = error.localizedDescription
                    store.error = "\(tracker.name) needs you to reconnect. Your changes are kept and sent once it’s reconnected."
                    return false
                case .notSent, .retryLater, .uncertain:
                    return false
                }
            }
        }
        retries[tracker] = 0
        return true
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
    /// Check-in, the way Cinopsys does it on each service: Simkl's and WeTrakr's scrobble/checkin,
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
        refresh?.cancel()
        let session = generation
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, session == self.generation else { return }
            await self.check(tracker, store: store)
        }
    }

    // MARK: Phase 5: make Simkl / MDBList match the diary

    func matchPlan(_ tracker: MainTracker, store: DiaryStore) -> TraktWritePlan? {
        guard store.diaryService != tracker, store.serverRecord != tracker else { return nil }
        return libraries[tracker].map { TraktWritePlan.make(library: $0, workspace: store.diaryToMatch, tracker: tracker) }
    }
    /// A backup or an import into Simkl, MDBList or WeTrakr while it holds the diary: only what it
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
                tally.add(try await store.directClient.write(config, path: request.path, body: request.body))
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
        var sent = 0, tally = TraktDirectStore.ReplyTally()
        let session = generation
        defer { if session == generation { writing = nil; writeProgress = nil } }
        do {
            let config = await store.freshProviderConfig(tracker.provider)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                try await pace()
                guard session == generation else { return }
                let reply = try await store.directClient.write(config, path: request.path, body: request.body)
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
                let result = try WeTrakrDecode.applyJournal(data, to: &library, seen: &seen)
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
            for path in ["/sync/tracking/watched/history/movies", "/sync/tracking/watched/history/episodes"] {
                for page in try await all(path) { fresh.plays += try WeTrakrDecode.plays(from: page, skipped: &skipped) }
            }
            for target in ["movies", "shows"] {
                for page in try await all("/sync/tracking/planning/" + target) { fresh.watchlist += try WeTrakrDecode.listed(from: page, skipped: &skipped) }
                for page in try await all("/sync/tracking/dropped/" + target) { fresh.dropped += try WeTrakrDecode.listed(from: page, skipped: &skipped) }
                for page in try await all("/sync/favorites/" + target) { fresh.favorites += try WeTrakrDecode.listed(from: page, skipped: &skipped) }
            }
            for page in try await all("/sync/ratings/all") { fresh.ratings += try WeTrakrDecode.ratings(from: page, skipped: &skipped) }
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
            let page = try TrackerDecode.mdblistPage(from: try await client.read(config, path: path, query: query))
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
        refresh?.cancel(); refresh = nil
        running = nil; writing = nil; writeProgress = nil
        libraries = [:]; reports = [:]; errors = [:]; writeResults = [:]; plans = [:]; pending = [:]
        BackgroundFiles.cancel(folder: folder)
        flushing = []; sending = []; retries = [:]
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}

extension DiaryStore {
    /// Trakt holds the diary (your server says so, or the diary on screen comes from it).
    var traktHoldsDiary: Bool { diaryFromTrakt || serverRecord == .trakt }
    /// A service holds the diary but your old server copy is on screen: the server keeps it
    /// read-only for watches, ratings and watch status (notes, tags and files still change).
    var viewingFrozenServerCopy: Bool { serverRecord != nil && !diaryFromService }
    var frozenCopyMessage: String {
        "This is your old server copy, kept read-only for watches, ratings, statuses and favourites. Show your diary from \(serverRecord?.name ?? "your tracker") to change them."
    }
    /// Stops a watch, rating or status edit before it reaches the read-only server copy.
    func requireWatchEdits() throws {
        if viewingFrozenServerCopy { throw APIError.message(frozenCopyMessage) }
    }

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
    /// What the mirrors are compared with and made to match: the diary you see when it comes
    /// from a service, else your server's.
    var diaryToMatch: Workspace { diaryFromService ? workspace : serverDiary }
    /// Trakt-first phase 2: your edits go to Trakt as you make them (watches with their exact time,
    /// ratings, Planned), through the same delivery queue as Simkl and MDBList, with the token your
    /// server hands out. The diary on your server stays the record until the switch-over.
    var traktWriteThrough: Bool {
        let config = providerSettings.config(for: .trakt)
        return config.enabled && config.connection == .signIn && config.loggingMethod.includesDirectAPI && config.isAuthenticated
    }
    func setTraktWriteThrough(_ on: Bool) async throws {
        var config = providerSettings.config(for: .trakt)
        if on {
            let token: TraktDirectToken = try await read("/api/trakt/token")
            config.clientId = token.clientId; config.accessToken = token.accessToken
            config.tokenExpiresAt = Date(timeIntervalSince1970: token.expiresAt / 1000).ISO8601Format()
            config.username = token.username; config.connection = .signIn
            config.enabled = true; config.loggingMethod = .serverAndDirectAPI
        } else {
            config.enabled = false
        }
        guard updateProviderConfig(config) else { throw APIError.message(error ?? "The Trakt setting couldn’t be saved.") }
    }
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
