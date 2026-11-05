import Foundation
import Observation
import TwilDiaryCore

// Trakt-first plan, phase 1 (ios/docs/TRAKT-CLIENT-PLAN.md): the app reads Trakt directly
// (api.trakt.tv) with the access token the Worker hands out, keeps the last read on this
// iPhone, and compares it with the current diary. Read-only: nothing is written anywhere.

/// From `GET /api/trakt/token`; the refresh token stays on the Worker.
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
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
            // 429 means Trakt refused before writing anything, so asking again is safe.
            if status == 429 && attempt < 2 {
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(max(wait, 1), 30)))
                continue
            }
            if status == 420 { throw APIError.message("Trakt says your account is at its limit (HTTP 420) for \(path). A Trakt VIP account lifts it.") }
            if status == 401 || status == 403 { throw APIError.message("Trakt didn’t accept the sign-in (HTTP \(status)). Reconnect Trakt, then try again.") }
            guard (200..<300).contains(status) else { throw APIError.message("Trakt answered HTTP \(status) for \(path).") }
            return data
        }
        throw APIError.message("Trakt is busy right now. Try again in a minute.")
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
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
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
    private let file: URL
    init(file: URL = URL.applicationSupportDirectory.appending(path: "Trakt/library.json")) {
        self.file = file
        library = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
    }

    func check(store: DiaryStore) async {
        guard !running else { return }
        if store.isPreview { error = "Direct Trakt reads need a real Trakt connection."; return }
        running = true; error = nil
        defer { running = false }
        let started = Date.now
        do {
            if token?.usable != true { token = try await store.read("/api/trakt/token") }
            let client = TraktDirectClient(token: token!)
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
            self.library = library
            save(library)
            // Compare with the server's diary (the record until the switch-over), not the Trakt view.
            report = Report(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: due, unavailable: unavailable,
                            skipped: skipped, comparison: TraktComparison.compare(library, with: store.serverDiary))
            if store.diaryFromTrakt { store.applyDiarySource() }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
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
    /// A list Trakt splits into movies and shows (`…/movies`, `…/shows`), each in one call.
    private func both<Item>(_ client: TraktDirectClient, _ path: String,
                            decode: (Data) throws -> (items: [Item], skipped: Int)) async throws -> ([Item], Int, Int) {
        let movies = try decode(try await client.get(path + "/movies").data)
        let shows = try decode(try await client.get(path + "/shows").data)
        return (movies.items + shows.items, movies.skipped + shows.skipped, 2)
    }

    private func save(_ library: TraktLibrary) {
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(library).write(to: file, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = folder; try url.setResourceValues(values)
        } catch {
            // The read still shows until the app closes; the next check saves it again.
        }
    }
    // MARK: Phase 2: make Trakt match the diary

    private(set) var writing = false
    @ObservationIgnored private var lastWrite: Date?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    private(set) var writeProgress: String?
    private(set) var writeResult: String?
    /// What "Make Trakt match" would send, from the last read (nil before a read).
    func matchPlan(store: DiaryStore) -> TraktWritePlan? {
        library.map { TraktWritePlan.make(library: $0, workspace: store.serverDiary) }
    }
    /// Sends the plan to Trakt one request a second, marks Trakt-only favourites in the diary,
    /// then reads Trakt again so the comparison shows the result.
    func makeTraktMatch(store: DiaryStore) async {
        guard !writing, !running, let plan = matchPlan(store: store), !plan.isEmpty else { return }
        if store.isPreview { error = "Writing to Trakt needs a real Trakt connection."; return }
        writing = true; error = nil; writeResult = nil
        defer { writing = false; writeProgress = nil }
        var sent = 0, notFound = 0
        do {
            if token?.usable != true { token = try await store.read("/api/trakt/token") }
            let client = TraktDirectClient(token: token!)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                if index > 0 { try await Task.sleep(for: .milliseconds(1100)) }
                let reply = try await client.post(request.path, body: request.body)
                sent += request.count
                notFound += Self.notFoundCount(reply)
            }
            for id in plan.diaryFavourites {
                if let title = store.title(id) { _ = await store.patch(title, values: ["favorite": true]) }
            }
            writeResult = "Sent to Trakt: " + plan.summary.joined(separator: "; ") + "."
                + (notFound > 0 ? " Trakt couldn’t find \(notFound) of them by their TMDB id." : "")
                + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) diary watches have no date and were left out." : "")
        } catch {
            if !Task.isCancelled { self.error = (sent > 0 ? "Sent \(sent) before stopping. " : "") + error.localizedDescription }
        }
        await check(store: store)
    }
    // MARK: Phase 4b: edits in the Trakt diary

    /// One write to Trakt with the server's token (one a second at most, waiting out 429s).
    func write(_ path: String, body: [String: Any], store: DiaryStore) async throws {
        if store.isPreview { throw APIError.message("Writing to Trakt needs a real Trakt connection.") }
        if token?.usable != true { token = try await store.read("/api/trakt/token") }
        if let last = lastWrite, Date.now.timeIntervalSince(last) < 1.1 { try await Task.sleep(for: .milliseconds(1100)) }
        lastWrite = .now
        _ = try await TraktDirectClient(token: token!).post(path, body: try JSONSerialization.data(withJSONObject: body))
    }
    /// Applies an edit to the phone's Trakt copy and redraws the Trakt diary at once.
    func update(store: DiaryStore, _ change: (inout TraktLibrary) -> Void) {
        guard var value = library else { return }
        change(&value)
        library = value
        save(value)
        store.applyDiarySource()
    }
    /// A quiet re-read a few seconds after an edit, so new plays get their real Trakt ids
    /// (needed to remove exactly that play later).
    func refreshSoon(store: DiaryStore) {
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            await self.check(store: store)
        }
    }

    /// Trakt's "not_found" lists in a write reply.
    static func notFoundCount(_ data: Data) -> Int {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        if let list = root["not_found"] as? [Any] { return list.count }
        guard let missing = root["not_found"] as? [String: Any] else { return 0 }
        return missing.values.reduce(0) { $0 + (($1 as? [Any])?.count ?? 0) }
    }

    /// Sign-out: the Trakt copy is diary data, so it goes with the diary.
    func forget() {
        library = nil; report = nil; token = nil; error = nil; writeResult = nil
        try? FileManager.default.removeItem(at: file)
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
    private let folder: URL
    init(folder: URL = URL.applicationSupportDirectory.appending(path: "Trackers")) {
        self.folder = folder
        for tracker in [MainTracker.simkl, .mdblist] {
            libraries[tracker] = (try? Data(contentsOf: file(tracker))).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
        }
    }
    private func file(_ tracker: MainTracker) -> URL { folder.appending(path: tracker.rawValue + ".json") }

    func check(_ tracker: MainTracker, store: DiaryStore) async {
        guard tracker == .simkl || tracker == .mdblist, running == nil else { return }
        if store.isPreview { errors[tracker] = "Direct reads need a real \(tracker.name) connection."; return }
        running = tracker; errors[tracker] = nil
        defer { running = nil }
        let started = Date.now
        do {
            let config = await store.freshProviderConfig(tracker == .simkl ? .simkl : .mdblist)
            let client = store.directClient
            var requests = 1
            let activitiesData = try await client.read(config, path: tracker == .simkl ? "/sync/activities" : "/sync/last_activities")
            let activities = try (tracker == .simkl ? TraktDecode.activities(from: activitiesData) : TrackerDecode.flatActivities(from: activitiesData))
            var library = libraries[tracker] ?? TraktLibrary()
            var fetched: [TraktDomain] = []
            if library.activities != activities || library.fetchedAt == nil {
                if tracker == .simkl {
                    library = try TrackerDecode.simklLibrary(from: try await client.read(config, path: "/sync/all-items/", query: [
                        "extended": "full", "episode_watched_at": "yes", "memos": "yes", "include_all_episodes": "yes"]))
                    requests += 1
                    fetched = [.history, .ratings, .watchlist, .dropped, .notes]
                } else {
                    var fresh = TraktLibrary()
                    let watched = try await mdblistPages(client, config, "/sync/watched")
                    fresh.plays = watched.items.map { item in
                        TraktPlay(historyId: TrackerDecode.playID("mdblist|\(item.title.kind.rawValue)|\(item.title.tmdbId ?? 0)|\(item.title.name)|\(item.season ?? -1)|\(item.episode ?? -1)"),
                                  title: item.title, season: item.season, episode: item.episode, watchedAt: item.date)
                    }
                    let ratings = try await mdblistPages(client, config, "/sync/ratings")
                    fresh.ratings = ratings.items.compactMap { item in item.rating.map { TraktRating(title: item.title, rating: $0, ratedAt: item.date) } }
                    let dropped = try await mdblistPages(client, config, "/sync/dropped")
                    fresh.dropped = dropped.items.map { TraktListed(title: $0.title, listedAt: $0.date) }
                    let watchlist = try await mdblistPages(client, config, "/watchlist/items")
                    fresh.watchlist = watchlist.items.map { TraktListed(title: $0.title, listedAt: $0.date) }
                    fresh.skipped = watched.skipped + ratings.skipped + dropped.skipped + watchlist.skipped
                    requests += watched.calls + ratings.calls + dropped.calls + watchlist.calls
                    library = fresh
                    fetched = [.history, .ratings, .dropped, .watchlist]
                }
                library.activities = activities
            }
            library.fetchedAt = Date.now.formatted(.iso8601)
            libraries[tracker] = library
            save(library, tracker)
            if store.diaryFromTracker == tracker { store.applyDiarySource() }
            reports[tracker] = .init(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: fetched, unavailable: [],
                                     skipped: library.skipped, comparison: TraktComparison.compare(library, with: store.serverDiary, tracker: tracker))
        } catch {
            if !Task.isCancelled { errors[tracker] = error.localizedDescription }
        }
    }

    // MARK: Phase 5: edits in the Simkl / MDBList diary

    @ObservationIgnored private var lastWrite: Date?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    /// One write with the service's own sign-in (one a second at most).
    func write(_ tracker: MainTracker, _ path: String, body: [String: Any], store: DiaryStore) async throws {
        if store.isPreview { throw APIError.message("Writing to \(tracker.name) needs a real \(tracker.name) connection.") }
        if let last = lastWrite, Date.now.timeIntervalSince(last) < 1.1 { try await Task.sleep(for: .milliseconds(1100)) }
        lastWrite = .now
        let config = await store.freshProviderConfig(tracker == .simkl ? .simkl : .mdblist)
        _ = try await store.directClient.write(config, path: path, body: try JSONSerialization.data(withJSONObject: body))
    }
    /// Applies an edit to the phone's copy and redraws the diary at once.
    func update(_ tracker: MainTracker, store: DiaryStore, _ change: (inout TraktLibrary) -> Void) {
        guard var value = libraries[tracker] else { return }
        change(&value)
        libraries[tracker] = value
        save(value, tracker)
        store.applyDiarySource()
    }
    /// A quiet re-read a few seconds after an edit.
    func refreshSoon(_ tracker: MainTracker, store: DiaryStore) {
        refresh?.cancel()
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            await self.check(tracker, store: store)
        }
    }

    // MARK: Phase 5: make Simkl / MDBList match the diary

    func matchPlan(_ tracker: MainTracker, store: DiaryStore) -> TraktWritePlan? {
        libraries[tracker].map { TraktWritePlan.make(library: $0, workspace: store.serverDiary, tracker: tracker) }
    }
    /// Sends the plan one request a second (each service's own endpoints, within what it keeps),
    /// then reads the service again so the comparison shows the result.
    func makeMatch(_ tracker: MainTracker, store: DiaryStore) async {
        guard writing == nil, running == nil, let plan = matchPlan(tracker, store: store), !plan.isEmpty else { return }
        if store.isPreview { errors[tracker] = "Writing to \(tracker.name) needs a real \(tracker.name) connection."; return }
        writing = tracker; errors[tracker] = nil; writeResults[tracker] = nil
        var sent = 0, notFound = 0
        do {
            let config = await store.freshProviderConfig(tracker == .simkl ? .simkl : .mdblist)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                if index > 0 { try await Task.sleep(for: .milliseconds(1100)) }
                let reply = try await store.directClient.write(config, path: request.path, body: request.body)
                sent += request.count
                notFound += TraktDirectStore.notFoundCount(reply)
            }
            writeResults[tracker] = "Sent to \(tracker.name): " + plan.summary.joined(separator: "; ") + "."
                + (notFound > 0 ? " \(tracker.name) couldn’t find \(notFound) of them by their TMDB id." : "")
                + (plan.skippedPlays > 0 ? " \(plan.skippedPlays) diary watches have no date and were left out." : "")
        } catch {
            if !Task.isCancelled { errors[tracker] = (sent > 0 ? "Sent \(sent) before stopping. " : "") + error.localizedDescription }
        }
        writing = nil; writeProgress = nil
        await check(tracker, store: store)
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
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(library).write(to: file(tracker), options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = folder; try url.setResourceValues(values)
        } catch { }
    }
    /// Sign-out: these copies are diary data, so they go with the diary.
    func forget() {
        libraries = [:]; reports = [:]; errors = [:]; writeResults = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}

extension DiaryStore {
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

