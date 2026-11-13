import Foundation
import Observation
import BackgroundTasks
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

    /// Our own pause after the service asked for one (see `ProviderCooldowns`): nothing was sent, and
    /// nothing is wrong with the edit, so it never counts against the edit's tries.
    static func paused(_ error: Error) -> Bool {
        if let error = error as? APIError, case .message(let text) = error { return text.contains("slow down") }
        return false
    }
    /// A failure that says nothing about the edit itself: never sent (offline), a pause the service
    /// asked for, or a sign-in to renew. The edit waits; it isn't used up and set aside.
    static func keepsWaiting(_ error: Error) -> Bool {
        if paused(error) { return true }
        if let error = error as? APIError {
            switch error {
            case .rejected(let status, _): return status == 401 || status == 403
            case .signIn: return true
            case .message(let text): return text.contains("Reconnect") || text.contains("sign-in")
            default: return false
            }
        }
        if let error = error as? TraktWriteError { return error.status == 401 || error.status == 403 }
        return of(error) == .notSent
    }
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

/// Cinopsys merges unsent edits that set the same thing on the same title (a rating, the watchlist,
/// a favourite, dropped, WeTrakr's planning or dropped): only the last choice is sent.
/// Plays are events, never merged. nil: not a mergeable state change.
enum PendingMerge {
    static func key(_ path: String, _ body: [String: Any]) -> String? {
        let family: String
        switch path {
        case "/sync/ratings", "/sync/ratings/remove": family = "rating"
        case "/sync/watchlist", "/sync/watchlist/remove", "/watchlist/items/add", "/watchlist/items/remove": family = "watchlist"
        case "/sync/favorites", "/sync/favorites/remove": family = "favourite"
        case "/users/hidden/dropped", "/users/hidden/dropped/remove", "/sync/dropped", "/sync/dropped/remove": family = "dropped"
        case "/sync/add-to-list": family = "list"
        case "/sync/tracking", "/sync/tracking/remove":
            // WeTrakr's planning and dropped are states; its watched entries are plays.
            let items = ["movies", "shows"].flatMap { (body[$0] as? [[String: Any]]) ?? [] }
            guard !items.isEmpty, items.allSatisfy({ ["planning", "dropped"].contains($0["status"] as? String ?? "") }) else { return nil }
            family = "tracking"
        default: return nil
        }
        var titles: [String] = []
        for slot in ["movies", "shows"] {
            for item in (body[slot] as? [[String: Any]]) ?? [] {
                guard let tmdb = ((item["ids"] as? [String: Any])?["tmdb"] as? NSNumber)?.intValue else { return nil }
                titles.append(slot + ":" + String(tmdb))
            }
        }
        guard titles.count == 1 else { return nil }
        return family + "|" + titles[0]
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
    /// Goes up each time a read of Trakt comes back and replaces the copy here. A `check` can end
    /// without one (another read under way, edits still waiting, an edit made meanwhile); Force
    /// Match plans only from a copy it knows was just read.
    @ObservationIgnored private(set) var readCount = 0
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
            // Every list was read (one Trakt wouldn't give keeps its old copy, which isn't fresh).
            if unavailable.allSatisfy({ $0 == .notes }) { readCount += 1 }
            save(library)
            ServiceIDs.shared.learn(from: library)
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
        } catch {
            if !Task.isCancelled, session == generation { self.error = error.localizedDescription }
        }
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
    /// What "Make Trakt match" would send, from the last read (nil before a read, and when Trakt
    /// holds the diary: there's nothing to make it match).
    func matchPlan(store: DiaryStore) -> TraktWritePlan? {
        guard !store.traktHoldsDiary else { return nil }
        return library.map { TraktWritePlan.make(library: $0, workspace: store.diaryToMatch, except: MatchLedger.tokens(.trakt)) }
    }
    /// The comparison with the diary and the plan for "Make Trakt match", away from the main thread.
    private func analysis(_ library: TraktLibrary, store: DiaryStore) async -> (comparison: TraktComparison, plan: TraktWritePlan) {
        let diary = store.diaryToMatch, except = MatchLedger.tokens(.trakt)
        return await Task.detached(priority: .utility) {
            (TraktComparison.compare(library, with: diary, except: except), TraktWritePlan.make(library: library, workspace: diary, except: except))
        }.value
    }
    /// Sends the plan to Trakt one request a second, marks Trakt-only favourites in the diary,
    /// then reads Trakt again so the comparison shows the result.
    func makeTraktMatch(store: DiaryStore) async {
        guard !writing, !running, let plan = matchPlan(store: store), !plan.isEmpty else { return }
        if store.isPreview { error = "Writing to Trakt needs a real Trakt connection."; return }
        writing = true; error = nil; writeResult = nil
        defer { writing = false; writeProgress = nil }
        var sent = 0, tally = ReplyTally()
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
            }
            guard session == generation else { return }
            // Favourites only on Trakt join the diary.
            for id in plan.diaryFavourites {
                if let title = store.workspace.activeTitles.first(where: { $0.id == id }) { await store.patch(title, values: ["favorite": true]) }
            }
            writeResult = "Sent to Trakt: " + plan.summary.joined(separator: "; ") + ". " + tally.text(service: "Trakt")
                + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) diary watches have no date and were left out." : "")
        } catch {
            if !Task.isCancelled, session == generation { self.error = (sent > 0 ? "Sent \(sent) before stopping. " : "") + error.localizedDescription }
        }
        guard session == generation else { return }
        await check(store: store)
        // Trakt as a mirror: what was sent and still isn't there goes to the ledger (see MatchLedger).
        guard session == generation, error == nil, let stillMissing = matchPlan(store: store) else { return }
        let stuck = plan.tokens.intersection(stillMissing.tokens)
        guard !stuck.isEmpty else { return }
        MatchLedger.add(.trakt, stuck)
        writeResult = (writeResult ?? "") + " \(stuck.count) didn’t stick on Trakt, so they won’t be sent again on their own."
        let refreshed = await analysis(library ?? TraktLibrary(), store: store)
        if let report { self.report = Report(seconds: report.seconds, requests: report.requests, fetched: report.fetched, unavailable: report.unavailable, skipped: report.skipped, comparison: refreshed.comparison) }
        self.plan = refreshed.plan
    }
    /// One Force Match call to Trakt (your diary's service, from another service as the source),
    /// paced like every Trakt write.
    func forcePost(_ path: String, body: Data, store: DiaryStore) async throws -> Data {
        if token?.usable != true { token = try await store.traktToken() }
        guard let token else { throw APIError.message("Trakt isn’t signed in. Reconnect it in Connections.") }
        try await pace()
        return try await TraktDirectClient(token: token).post(path, body: body)
    }
    /// Trakt read again in full after a Force Match (its change stamps can lag its writes).
    func rereadAfterForce(store: DiaryStore) async {
        library?.activities = nil
        await check(store: store)
    }
    /// "Try them again" for Trakt as a mirror.
    func retryLedger(store: DiaryStore) async {
        MatchLedger.clear(.trakt)
        guard let library else { return }
        let refreshed = await analysis(library, store: store)
        if let report { self.report = Report(seconds: report.seconds, requests: report.requests, fetched: report.fetched, unavailable: report.unavailable, skipped: report.skipped, comparison: refreshed.comparison) }
        plan = refreshed.plan
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
        let kept = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let existing = library?.notes.first { $0.title?.diaryKey == title.diaryKey }
        do { try await sendNote(kept, existing: existing, title: title, store: store) }
        catch {
            // No connection (or Trakt busy): the note waits on the phone, in order with your other
            // edits, and goes with the next send (Cinopsys keeps note_text in its queue).
            guard [TraktDelivery.notSent, .retryLater, .uncertain].contains(TraktDelivery.of(error)) else { throw error }
            if let existing, existing.id > 0 {
                pending.append(PendingWrite(path: "/notes/\(existing.id)", body: try JSONSerialization.data(withJSONObject: ["notes": kept]),
                                            owner: token?.username, method: kept.isEmpty ? "DELETE" : "PUT"))
            } else if !kept.isEmpty {
                let slot = title.kind == .movie ? "movie" : "show"
                let body: [String: Any] = [slot: ["ids": ["tmdb": title.tmdbId ?? 0]], "notes": kept, "privacy": "private", "spoiler": false]
                // An answer lost on the way: Trakt may have the note already (checked before it's sent again).
                pending.append(PendingWrite(path: "/notes", body: try JSONSerialization.data(withJSONObject: body), owner: token?.username,
                                            uncertain: TraktDelivery.of(error) == .uncertain ? true : nil))
            }
            update(store: store) { library in
                library.notes.removeAll { $0.title?.diaryKey == title.diaryKey }
                if !kept.isEmpty {
                    library.notes.append(TraktNote(id: existing?.id ?? -TrackerDecode.playID("note|" + (title.diaryKey ?? title.name)), title: title, text: kept, updatedAt: Date.now.formatted(.iso8601)))
                }
            }
            retryLater(store: store)
        }
    }
    private func sendNote(_ kept: String, existing: TraktNote?, title: TraktTitleRef, store: DiaryStore) async throws {
        let client = try await self.client(store: store)
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
        let merge = PendingMerge.key(path, body)
        // A newer choice for the same setting replaces one still waiting (never the one on its way).
        if let merge { pending.removeAll { $0.merge == merge && $0.id != inFlight } }
        pending.append(PendingWrite(path: path, body: data, owner: token?.username, resolve: resolve ? true : nil, merge: merge))
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
        /// Tries so far, and the last reason (Cinopsys's retry_count and last_error).
        var attempts: Int?
        var lastError: String?
        /// POST unless set (a note's change is PUT, its removal DELETE).
        var method: String?
        /// The setting it assigns, for merging (see `PendingMerge`).
        var merge: String?
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
                if next.resolve == true {
                    body = try await resolvedRemoval(next.body, client: client)
                    // Not in Trakt's history yet (it was only just added): asked again shortly,
                    // three times, before deciding there's nothing to remove.
                    if body == nil, (next.attempts ?? 0) < 3, let index = pending.firstIndex(where: { $0.id == next.id }) {
                        pending[index].attempts = (next.attempts ?? 0) + 1
                        return false
                    }
                }
                else if next.uncertain == true, next.path == "/sync/history" { body = try await missingPlays(next.body, client: client) }
                // A new note whose answer was lost: sent again only when Trakt doesn't have it.
                else if next.uncertain == true, next.path == "/notes", next.method == nil {
                    if try await noteAlreadySaved(next.body, client: client) { body = nil }
                }
            } catch { return false }
            do {
                guard session == generation else { return false }
                if let body {
                    try await pace()
                    let reply: Data
                    if let method = next.method { reply = try await client.send(method, next.path, body: method == "DELETE" ? nil : body) }
                    else { reply = try await client.post(next.path, body: body) }
                    guard session == generation else { return false }
                    if Self.notFoundCount(reply) > 0 { refused("Trakt couldn’t find a title by its TMDB id, so it wasn’t changed there.", store: store) }
                }
                pending.removeAll { $0.id == next.id }
            } catch {
                guard session == generation, !Task.isCancelled else { return false }
                let kind = TraktDelivery.of(error)
                if kind == .retryLater || kind == .uncertain, !TraktDelivery.paused(error), let index = pending.firstIndex(where: { $0.id == next.id }) {
                    // A finite budget: one Trakt keeps failing on is set aside so the rest go on.
                    let tries = (pending[index].attempts ?? 0) + 1
                    pending[index].attempts = tries; pending[index].lastError = error.localizedDescription
                    if tries >= TrackerPreviewStore.retryBudget {
                        pending.removeAll { $0.id == next.id }
                        if let store { DeadLetters.add(.trakt, title: TrackerPreviewStore.describe(next.body, store: store), reason: error.localizedDescription) }
                        refused("Trakt kept failing on a change, so it was set aside: " + error.localizedDescription, store: store)
                        continue
                    }
                }
                switch kind {
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
                    if let store { DeadLetters.add(.trakt, title: TrackerPreviewStore.describe(next.body, store: store), reason: error.localizedDescription) }
                    refused("Trakt refused a change: " + error.localizedDescription, store: store)
                }
            }
            inFlight = nil
        }
        retries = 0
        return true
    }
    /// Whether Trakt already has the note a queued "new note" would add (the same title and text).
    private func noteAlreadySaved(_ body: Data, client: TraktDirectClient) async throws -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let text = root["notes"] as? String else { return false }
        let movie = root["movie"] != nil
        guard let media = (root[movie ? "movie" : "show"] as? [String: Any])?["ids"] as? [String: Any],
              let tmdb = (media["tmdb"] as? NSNumber)?.intValue else { return false }
        let notes = try await pages(client, "/users/me/notes", decode: TraktDecode.notes).0
        return notes.contains { $0.title?.tmdbId == tmdb && ($0.title?.kind == .movie) == movie && $0.text == text }
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
        MatchLedger.clear(.trakt)
        generation = UUID()
        refresh?.cancel(); refresh = nil
        // Work still running for the old account no longer resets these (it checks the session),
        // so they're cleared here; otherwise "busy" would stay on and stop the automatic reads.
        running = false; writing = false; writeProgress = nil
        library = nil; report = nil; token = nil; error = nil; writeResult = nil; plan = nil; pending = []
        resetSender()
        BackgroundFiles.cancel(file)
        // The on-this-phone diary is yours alone: leaving it never deletes it.
        if !localOnly { try? FileManager.default.removeItem(at: file) }
    }
}
