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
            if status == 420 { throw TraktWriteError(status: 420, message: "Trakt says your account is at its limit (HTTP 420) for \(path). A Trakt VIP account lifts it.") }
            if status == 401 || status == 403 { throw TraktWriteError(status: status, message: "Trakt didn’t accept the sign-in (HTTP \(status)). Reconnect Trakt, then try again.") }
            guard (200..<300).contains(status) else { throw TraktWriteError(status: status, message: "Trakt answered HTTP \(status) for \(path).") }
            return data
        }
        throw TraktWriteError(status: 429, message: "Trakt is busy right now. Try again in a minute.")
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
    private let file: URL
    init(file: URL = URL.applicationSupportDirectory.appending(path: "Trakt/library.json")) {
        self.file = file
        library = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TraktLibrary.self, from: $0) }
    }

    func check(store: DiaryStore) async {
        guard !running else { return }
        if store.isPreview { error = "Direct Trakt reads need a real Trakt connection."; return }
        running = true; error = nil
        let started = Date.now, session = generation
        defer { if session == generation { running = false } }
        do {
            if token?.usable != true { token = try await store.read("/api/trakt/token") }
            guard session == generation, let token else { return }
            let client = TraktDirectClient(token: token)
            // Edits made offline go first; still offline means there's nothing to read either.
            guard await sendPending(client, owner: token.username, session: session) else { return }
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
            self.library = library
            save(library)
            // Compare with the server's diary (the record until the switch-over), not the Trakt view;
            // after it, only what that old copy has and Trakt lacks altogether.
            report = Report(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: due, unavailable: unavailable,
                            skipped: skipped, comparison: comparison(library, store: store))
            plan = matchPlan(store: store)
            if store.diaryFromTrakt { store.applyDiarySource() }
            autoFillIfNeeded(store: store)
        } catch {
            if !Task.isCancelled, session == generation { self.error = error.localizedDescription }
        }
    }

    /// Like SeriesGuide's first sync: once Trakt holds the diary, what the old server copy has and
    /// Trakt lacks is copied in on its own, once. It runs after this read finishes (so `running`
    /// is clear) and is marked done before it starts, so a failure never makes it repeat; the
    /// button on the Trakt page stays for a retry.
    private func autoFillIfNeeded(store: DiaryStore) {
        guard store.traktHoldsDiary, !store.isPreview, !autoFilled, !writing,
              let plan, !plan.isEmpty else { return }
        autoFilled = true
        Task { await self.makeTraktMatch(store: store) }
    }
    private var autoFilled: Bool {
        get { UserDefaults.standard.bool(forKey: "trakt.autoFilledFromServer") }
        set { UserDefaults.standard.set(newValue, forKey: "trakt.autoFilledFromServer") }
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
    /// The plan from the last read, for the pages to show (worked out once per read, not on every
    /// redraw; sending always works it out afresh).
    private(set) var plan: TraktWritePlan?
    /// What "Make Trakt match" would send, from the last read (nil before a read). Once Trakt
    /// holds the diary: only what the old server copy has and Trakt lacks, each thing once.
    func matchPlan(store: DiaryStore) -> TraktWritePlan? {
        let fill = store.traktHoldsDiary
        return library.map { TraktWritePlan.make(library: $0, workspace: store.serverDiary, fillOnly: fill, except: fill ? copied : []) }
    }
    private func comparison(_ library: TraktLibrary, store: DiaryStore) -> TraktComparison {
        let fill = store.traktHoldsDiary
        return TraktComparison.compare(library, with: store.serverDiary, oneWay: fill, except: fill ? copied : [])
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
            if token?.usable != true { token = try await store.read("/api/trakt/token") }
            guard session == generation, let token else { return }
            let client = TraktDirectClient(token: token)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                if index > 0 { try await Task.sleep(for: .milliseconds(1100)) }
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

    /// One write to Trakt with the server's token (one a second at most, waiting out 429s).
    /// An edit that may still reach Trakt is kept and sent before the next read instead of failing
    /// (no connection, Trakt busy or down, sign-in to renew, or an answer lost on the way, which is
    /// checked against Trakt before anything is sent twice). Only a real refusal throws, and so
    /// does a title Trakt couldn't find: the caller then leaves the phone's copy unchanged.
    func write(_ path: String, body: [String: Any], store: DiaryStore) async throws {
        if store.isPreview { throw APIError.message("Writing to Trakt needs a real Trakt connection.") }
        let data = try JSONSerialization.data(withJSONObject: body)
        let session = generation
        do {
            if token?.usable != true { token = try await store.read("/api/trakt/token") }
        } catch {
            // Nothing has left the phone yet.
            guard session == generation else { throw CancellationError() }
            pending.append(PendingWrite(path: path, body: data, owner: token?.username)); return
        }
        guard session == generation, let token else { throw CancellationError() }
        if !pending.isEmpty { pending.append(PendingWrite(path: path, body: data, owner: token.username)); return }
        if let last = lastWrite, Date.now.timeIntervalSince(last) < 1.1 { try await Task.sleep(for: .milliseconds(1100)) }
        lastWrite = .now
        let reply: Data
        do {
            reply = try await TraktDirectClient(token: token).post(path, body: data)
        } catch {
            guard session == generation else { throw CancellationError() }
            switch TraktDelivery.of(error) {
            case .rejected: throw error
            case .authBlocked:
                pending.append(PendingWrite(path: path, body: data, owner: token.username))
                self.error = "Trakt needs you to reconnect. Your changes are kept and sent once it’s reconnected."
                return
            case .uncertain:
                pending.append(PendingWrite(path: path, body: data, owner: token.username, uncertain: true)); return
            case .notSent, .retryLater:
                pending.append(PendingWrite(path: path, body: data, owner: token.username)); return
            }
        }
        if Self.notFoundCount(reply) > 0 {
            refreshSoon(store: store)
            throw APIError.message("Trakt couldn’t find this title by its TMDB id, so it wasn’t changed there.")
        }
    }

    // MARK: Edits waiting for a connection

    struct PendingWrite: Codable, Equatable {
        let path: String
        let body: Data
        /// The Trakt account it was made for; never sent under another one.
        var owner: String?
        /// The answer was lost: Trakt may already have it (checked before sending again).
        var uncertain: Bool?
    }
    /// Kept on the phone (in order) until Trakt takes them.
    private(set) var pending: [PendingWrite] = TraktDirectStore.loadPending() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "trakt.pendingWrites") }
    }
    nonisolated private static func loadPending() -> [PendingWrite] {
        (UserDefaults.standard.data(forKey: "trakt.pendingWrites")).flatMap { try? JSONDecoder().decode([PendingWrite].self, from: $0) } ?? []
    }
    /// Sends what's waiting, oldest first; false while Trakt can't take them yet (then nothing is
    /// read either, so the phone keeps showing your edits). A watch whose answer was lost is first
    /// looked up in Trakt's history at its time, and only the plays missing there are sent, so a
    /// play is never doubled. An edit Trakt refuses, or one made for another Trakt account, is
    /// dropped and said: Trakt is the record, and the read that follows shows what it kept.
    private func sendPending(_ client: TraktDirectClient, owner: String, session: UUID) async -> Bool {
        while let next = pending.first {
            guard session == generation, !Task.isCancelled else { return false }
            if let other = next.owner, other != owner {
                pending.removeFirst()
                self.error = "An edit kept for another Trakt account was discarded."
                continue
            }
            do {
                var body: Data? = next.body
                if next.uncertain == true, next.path == "/sync/history" {
                    body = try await missingPlays(next.body, client: client)
                }
                guard session == generation else { return false }
                if let body {
                    if let last = lastWrite, Date.now.timeIntervalSince(last) < 1.1 { try await Task.sleep(for: .milliseconds(1100)) }
                    lastWrite = .now
                    let reply = try await client.post(next.path, body: body)
                    guard session == generation else { return false }
                    if Self.notFoundCount(reply) > 0 { self.error = "Trakt couldn’t find a title from an edit made offline, so it wasn’t changed there." }
                }
                pending.removeFirst()
            } catch {
                guard session == generation, !Task.isCancelled else { return false }
                switch TraktDelivery.of(error) {
                case .notSent, .retryLater:
                    return false
                case .uncertain:
                    pending[0].uncertain = true
                    return false
                case .authBlocked:
                    self.error = "Trakt needs you to reconnect. Your changes are kept and sent once it’s reconnected."
                    return false
                case .rejected:
                    pending.removeFirst()
                    self.error = "An edit made offline was refused by Trakt: " + error.localizedDescription
                }
            }
        }
        return true
    }
    /// Puts a backup back into Trakt while Trakt holds the diary: only what Trakt lacks (plays
    /// not there at their time, ratings Trakt has none for, Planned for titles never watched,
    /// favourites, dropped shows). Nothing on Trakt is changed or removed, so running it twice
    /// adds nothing twice; the answer counts what Trakt accepted, not what was asked.
    func restore(_ backup: Workspace, store: DiaryStore) async throws -> String {
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
        if token?.usable != true { token = try await store.read("/api/trakt/token") }
        guard session == generation, let token else { throw CancellationError() }
        let client = TraktDirectClient(token: token)
        var tally = ReplyTally(), sent = 0
        let requests = plan.requests()
        do {
            for (index, request) in requests.enumerated() {
                writeProgress = "Restoring \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                if index > 0 { try await Task.sleep(for: .milliseconds(1100)) }
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
        pending.removeAll { $0.uncertain != true && $0.path == "/sync/history" && String(decoding: $0.body, as: UTF8.self).contains(when) }
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
        if token?.usable != true { token = try await store.read("/api/trakt/token") }
        guard let token else { throw APIError.message("Trakt isn’t connected.") }
        return TraktDirectClient(token: token)
    }
    /// Applies an edit to the phone's Trakt copy and redraws the Trakt diary at once.
    func update(store: DiaryStore, _ change: (inout TraktLibrary) -> Void) {
        guard var value = library else { return }
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
    func refreshSoon(store: DiaryStore) {
        refresh?.cancel()
        let session = generation
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
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
    func forget() {
        generation = UUID()
        refresh?.cancel(); refresh = nil
        // Work still running for the old account no longer resets these (it checks the session),
        // so they're cleared here; otherwise "busy" would stay on and stop the automatic reads.
        running = false; writing = false; writeProgress = nil
        library = nil; report = nil; token = nil; error = nil; writeResult = nil; plan = nil; pending = []
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
    /// Each service's plan from its last read (see `TraktDirectStore.plan`).
    private(set) var plans: [MainTracker: TraktWritePlan] = [:]
    /// Changes on sign-out (see `TraktDirectStore.generation`).
    @ObservationIgnored private var generation = UUID()
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
        let started = Date.now, session = generation
        defer { if session == generation { running = nil } }
        do {
            let config = await store.freshProviderConfig(tracker == .simkl ? .simkl : .mdblist)
            let client = store.directClient
            var requests = 1
            let activitiesData = try await client.read(config, path: tracker == .simkl ? "/sync/activities" : "/sync/last_activities")
            let activities = try (tracker == .simkl ? TraktDecode.activities(from: activitiesData) : TrackerDecode.flatActivities(from: activitiesData))
            var library = libraries[tracker] ?? TraktLibrary()
            var fetched: [TraktDomain] = []
            if tracker == .simkl {
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
            } else if library.activities != activities || library.fetchedAt == nil {
                // MDBList: only the lists whose time moved (all of them on the first read).
                let lists = TrackerDecode.mdblistListsToRead(previous: library.fetchedAt == nil ? nil : library.activities, now: activities)
                    ?? [.history, .ratings, .dropped, .watchlist]
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
                library.activities = activities
            }
            library.fetchedAt = Date.now.formatted(.iso8601)
            // Signed out while reading: the previous account's lists are dropped, not saved.
            guard session == generation else { return }
            libraries[tracker] = library
            save(library, tracker)
            if store.diaryFromTracker == tracker { store.applyDiarySource() }
            reports[tracker] = .init(seconds: Date.now.timeIntervalSince(started), requests: requests, fetched: fetched, unavailable: [],
                                     skipped: library.skipped, comparison: TraktComparison.compare(library, with: store.diaryToMatch, tracker: tracker))
            plans[tracker] = matchPlan(tracker, store: store)
        } catch {
            if !Task.isCancelled, session == generation { errors[tracker] = error.localizedDescription }
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
        let reply = try await store.directClient.write(config, path: path, body: try JSONSerialization.data(withJSONObject: body))
        // A title the service couldn't find wasn't changed: the caller leaves the phone's copy as is.
        if TraktDirectStore.notFoundCount(reply) > 0 {
            refreshSoon(tracker, store: store)
            throw APIError.message("\(tracker.name) couldn’t find this title by its TMDB id, so it wasn’t changed there.")
        }
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
        let session = generation
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, session == self.generation else { return }
            await self.check(tracker, store: store)
        }
    }

    // MARK: Phase 5: make Simkl / MDBList match the diary

    func matchPlan(_ tracker: MainTracker, store: DiaryStore) -> TraktWritePlan? {
        guard store.diaryService != tracker, store.serverRecord != tracker else { return nil }
        return libraries[tracker].map { TraktWritePlan.make(library: $0, workspace: store.diaryToMatch, tracker: tracker) }
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
            let config = await store.freshProviderConfig(tracker == .simkl ? .simkl : .mdblist)
            let requests = plan.requests()
            for (index, request) in requests.enumerated() {
                writeProgress = "Sending \(index + 1) of \(requests.count): \(request.count) \(request.summary)…"
                if index > 0 { try await Task.sleep(for: .milliseconds(1100)) }
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
    /// Anything already running for this account can no longer save or show its results.
    func forget() {
        generation = UUID()
        refresh?.cancel(); refresh = nil
        running = nil; writing = nil; writeProgress = nil
        libraries = [:]; reports = [:]; errors = [:]; writeResults = [:]; plans = [:]
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
            guard others.running == nil, others.writing == nil, due(others.libraries[tracker]?.fetchedAt) else { return }
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

