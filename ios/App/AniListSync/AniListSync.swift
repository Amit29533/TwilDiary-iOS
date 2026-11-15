import Foundation
import Security
import SwiftUI
import AuthenticationServices
import Observation
import TwilDiaryCore

// AniList as an add-on (phase 1, 2026-11-15): signed in on this iPhone (AniList's implicit grant:
// a token for a year, no refresh), kept in step with the diary by its own sync, never the main
// tracker. Each diary change marks its title; the title's AniList entries (one per season or cour)
// are worked out from the diary (AniListPlan) and saved. AniList keeps no watch history.

/// What the AniList sync keeps on this iPhone: the token in the Keychain, settings under `prefix`,
/// its waiting list and look-ups in `folder`.
enum AniListSyncStorage {
    static let service = "twildiary.anilist.sync"
    static let prefix = "anilist.sync."
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "AniListSync") }
    static func secret(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func setSecret(_ value: String?, _ name: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(match as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func save<Value: Encodable>(_ value: Value, _ name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: folder.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    static func load<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    /// Everything the AniList sync kept on this iPhone. Nothing on AniList changes.
    static func removeEverything(defaults: UserDefaults = .standard) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// AniList's GraphQL API with your token. Replies come back as data, read by the caller.
struct AniListSyncAPI: Sendable {
    let token: String?
    enum Failure: Error, Equatable, Sendable {
        /// The token was refused (expired or revoked): sign in again.
        case signIn
        /// AniList's limit: wait this many seconds.
        case busy(Int)
        /// No answer (offline, AniList down): tried again later.
        case unavailable(String)
        /// AniList refused this change (its message).
        case refused(String)
    }
    func call(_ text: String, _ variables: [String: any Sendable] = [:]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try Self.body(text, variables)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure.unavailable(error.localizedDescription) }
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
        if status == 429 { throw Failure.busy(Int(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60) }
        if status >= 500 || status == 0 { throw Failure.unavailable("AniList didn’t answer (HTTP \(status)).") }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = ((root["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? ""
        if status == 401 || message.localizedCaseInsensitiveContains("invalid token") || message.localizedCaseInsensitiveContains("unauthorized") { throw Failure.signIn }
        if !(200..<300).contains(status) || root["data"] == nil || root["data"] is NSNull {
            throw Failure.refused(message.isEmpty ? "AniList refused it (HTTP \(status))." : message)
        }
        return data
    }
    /// A null for AniList (a date it should clear: left out, it keeps the old one; checked 2026-11-15).
    struct Null: Sendable {}
    /// The request body, with `Null` as JSON's null.
    static func body(_ text: String, _ variables: [String: any Sendable]) throws -> Data {
        func json(_ value: any Sendable) -> Any {
            if value is Null { return NSNull() }
            if let object = value as? [String: any Sendable] { return object.mapValues(json) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["query": text, "variables": variables.mapValues(json)] as [String: Any])
    }
    /// The `data` object of a reply.
    static func data(_ reply: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["data"] as? [String: Any] ?? [:]
    }
    /// "2016-04-04" from AniList's {year, month, day}; nil without a full day.
    static func day(_ value: Any?) -> String? {
        guard let date = value as? [String: Any], let year = date["year"] as? Int, let month = date["month"] as? Int, let day = date["day"] as? Int else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
    /// AniList's {year, month, day} for "2021-04-07".
    static func fuzzy(_ day: String?) -> [String: Int]? {
        guard let parts = day?.prefix(10).split(separator: "-").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        return ["year": parts[0], "month": parts[1], "day": parts[2]]
    }
    static func media(_ node: [String: Any]) -> AniListPlan.Media? {
        guard let id = node["id"] as? Int else { return nil }
        return AniListPlan.Media(id: id, format: node["format"] as? String, episodes: node["episodes"] as? Int, start: day(node["startDate"]), end: day(node["endDate"]))
    }
}

/// AniList's sign-in and the "Also save my activity to AniList" switch. You add TwilDiary's AniList
/// app once (its client ID, made on AniList's developer page with the redirect below); signing in
/// opens AniList's page in Apple's sheet and comes back with a token valid for a year.
@MainActor @Observable final class AniListSyncAccount {
    static let shared = AniListSyncAccount()
    static let redirect = ProviderWebSignIn.callbackScheme + "://auth/anilist"
    private static let clientKey = AniListSyncStorage.prefix + "clientId"
    private static let nameKey = AniListSyncStorage.prefix + "username"
    private static let savingKey = AniListSyncStorage.prefix + "saving"
    private static let expiresKey = AniListSyncStorage.prefix + "expires"

    private var clientValue: String? = UserDefaults.standard.string(forKey: AniListSyncAccount.clientKey)
    /// TwilDiary's AniList app (a client ID is public; the implicit grant has no secret).
    var clientId: String? {
        get { clientValue }
        set { clientValue = newValue; UserDefaults.standard.set(newValue, forKey: Self.clientKey) }
    }
    private(set) var username: String? = UserDefaults.standard.string(forKey: AniListSyncAccount.nameKey)
    private(set) var expiresAt: Date? = {
        let seconds = UserDefaults.standard.double(forKey: AniListSyncAccount.expiresKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }()
    private var hasToken = AniListSyncStorage.secret("token") != nil
    var signedIn: Bool { hasToken && (expiresAt.map { $0 > .now } ?? true) }
    /// Copy what you do to AniList (off until you turn it on).
    private var savingValue = UserDefaults.standard.bool(forKey: AniListSyncAccount.savingKey)
    var saving: Bool {
        get { savingValue }
        set {
            savingValue = newValue
            UserDefaults.standard.set(newValue, forKey: Self.savingKey)
            if newValue { Task { await AniListSync.shared.resume() } }
        }
    }
    var canSend: Bool { signedIn && saving }
    /// The token while it's valid.
    func token() -> String? { signedIn ? AniListSyncStorage.secret("token") : nil }

    /// Signs in on AniList's page. Returns false if cancelled.
    func signIn(using session: WebAuthenticationSession) async throws -> Bool {
        guard let clientId = clientId?.trimmingCharacters(in: .whitespacesAndNewlines), !clientId.isEmpty else {
            throw APIError.message("First add TwilDiary’s AniList app: paste its client ID below (one-time setup).")
        }
        var page = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        page.queryItems = [URLQueryItem(name: "client_id", value: clientId), URLQueryItem(name: "response_type", value: "token")]
        let callback: URL
        do { callback = try await session.authenticate(using: page.url!, callbackURLScheme: ProviderWebSignIn.callbackScheme) }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { return false }
        let (token, expires) = try Self.token(from: callback)
        AniListSyncStorage.setSecret(token, "token")
        UserDefaults.standard.set(expires.timeIntervalSince1970, forKey: Self.expiresKey)
        hasToken = true; expiresAt = expires
        if let reply = try? await AniListSyncAPI(token: token).call("{ Viewer { id name } }"),
           let name = (AniListSyncAPI.data(reply)["Viewer"] as? [String: Any])?["name"] as? String {
            username = name; UserDefaults.standard.set(name, forKey: Self.nameKey)
        }
        Task { await AniListSync.shared.resume() }
        return true
    }
    /// The token from AniList's redirect: twildiary://auth/anilist#access_token=…&expires_in=31536000.
    nonisolated static func token(from callback: URL, now: Date = .now) throws -> (String, Date) {
        let fragment = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.fragment ?? ""
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = values["error"] ?? query.first(where: { $0.name == "error" })?.value {
            throw APIError.message("AniList didn’t finish the sign-in (\(values["error_description"] ?? error)).")
        }
        guard let token = values["access_token"], !token.isEmpty else { throw APIError.message("AniList didn’t send a sign-in back. Try again.") }
        let seconds = values["expires_in"].flatMap(Double.init) ?? 31_536_000
        return (token, now.addingTimeInterval(seconds))
    }
    /// Signs out on this iPhone: the token goes; what's waiting stays until you sign in again.
    func signOut() {
        AniListSyncStorage.setSecret(nil, "token")
        UserDefaults.standard.removeObject(forKey: Self.expiresKey); UserDefaults.standard.removeObject(forKey: Self.nameKey)
        hasToken = false; expiresAt = nil; username = nil
    }
    /// Signs out and removes everything the AniList sync kept here (the client ID too). Nothing on AniList changes.
    func removeEverything() {
        AniListSyncStorage.removeEverything()
        hasToken = false; expiresAt = nil; username = nil; clientId = nil; saving = false
        AniListSync.shared.forget()
    }
}

/// The AniList sync: titles waiting to be sent, their AniList entries and what was last saved.
@MainActor @Observable final class AniListSync {
    static let shared = AniListSync()
    struct NotKept: Codable, Equatable, Identifiable, Sendable {
        var id = UUID().uuidString
        let key: String
        let label: String
        let reason: String
        let at: Date
    }
    /// A title's AniList entries in order (a film: its one; empty: AniList has none), as looked up.
    struct Chain: Codable, Sendable { let media: [AniListPlan.Media]; let at: Date }
    /// What an AniList entry was last saved as, with AniList's id for the list entry.
    struct Sent: Codable, Equatable, Sendable { let listId: Int?; let entry: AniListPlan.Entry; let key: String }

    /// Title keys ("tv:98123", "movie:37910") waiting to be sent, in order.
    private(set) var waiting: [String] = AniListSyncStorage.load([String].self, "waiting.json") ?? []
    private(set) var notKept: [NotKept] = AniListSyncStorage.load([NotKept].self, "not-kept.json") ?? []
    private(set) var sending = false
    private(set) var lastProblem: String?
    /// While sending: how many titles are done of how many.
    private(set) var progress: (done: Int, total: Int)?
    @ObservationIgnored private var chains: [String: Chain] = AniListSyncStorage.load([String: Chain].self, "chains.json") ?? [:]
    @ObservationIgnored private var sent: [Int: Sent] = AniListSyncStorage.load([Int: Sent].self, "sent.json") ?? [:]
    @ObservationIgnored private var days: [String: [Int: String]] = AniListSyncStorage.load([String: [Int: String]].self, "days.json") ?? [:]
    @ObservationIgnored private weak var store: DiaryStore?
    @ObservationIgnored private var lastCall = Date.distantPast

    nonisolated static func key(_ title: MediaTitle) -> String? {
        title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) }
    }
    /// Anime, anime films and other animation (Chinese and Korean animation the diary keeps as shows).
    nonisolated static func counts(_ title: MediaTitle) -> Bool { CastRanking.animated(title) }

    // MARK: Taking edits

    /// A diary edit (from `DiaryStore.mirror`): its title waits to be sent.
    func capture(_ mutation: OptimisticMutation, store: DiaryStore) {
        guard !store.isPreview, AniListSyncAccount.shared.canSend else { return }
        self.store = store
        let id = mutation.titleId
        guard let title = store.title(id) ?? PhoneCatalog.shared.titles[id], Self.counts(title), let key = Self.key(title) else { return }
        mark([key])
        Task { await resume() }
    }
    /// "Send everything": every animated title in the diary waits to be sent (the first full sync).
    func sendEverything(store: DiaryStore) {
        self.store = store
        mark(store.workspace.activeTitles.filter(Self.counts).compactMap(Self.key))
        Task { await resume() }
    }
    private func mark(_ keys: [String]) {
        for key in keys where !waiting.contains(key) { waiting.append(key) }
        AniListSyncStorage.save(waiting, "waiting.json")
    }
    func clearNotKept() { notKept = []; AniListSyncStorage.save(notKept, "not-kept.json") }
    func forget() { waiting = []; notKept = []; chains = [:]; sent = [:]; days = [:]; lastProblem = nil; progress = nil }

    // MARK: Sending

    /// Sends what's waiting, a title at a time, paced to AniList's limit (30 a minute for now).
    func resume(store: DiaryStore? = nil) async {
        if let store, !store.isPreview { self.store = store }
        guard !sending, AniListSyncAccount.shared.canSend, self.store != nil, !waiting.isEmpty else { return }
        sending = true
        defer { sending = false; progress = nil }
        var done = 0
        while let key = waiting.first, AniListSyncAccount.shared.canSend {
            guard let token = AniListSyncAccount.shared.token() else { break }
            progress = (done, done + waiting.count)
            do {
                try await send(key, api: AniListSyncAPI(token: token))
                waiting.removeFirst(); done += 1; lastProblem = nil
            } catch let failure as AniListSyncAPI.Failure {
                switch failure {
                case .busy(let seconds):
                    lastProblem = "AniList asked to slow down; carrying on in \(seconds) s."
                    try? await Task.sleep(for: .seconds(min(max(seconds, 5), 90)))
                    continue
                case .signIn:
                    AniListSyncAccount.shared.signOut()
                    lastProblem = "AniList signed TwilDiary out. Sign in again to send what’s waiting."
                case .unavailable(let message):
                    lastProblem = message + " What’s waiting goes when AniList answers."
                case .refused(let message):
                    record(key, "AniList refused it: " + message)
                    waiting.removeFirst(); done += 1
                    continue
                }
                break
            } catch {
                lastProblem = error.localizedDescription
                break
            }
            AniListSyncStorage.save(waiting, "waiting.json")
        }
        AniListSyncStorage.save(waiting, "waiting.json")
        AniListSyncStorage.save(sent, "sent.json")
    }

    /// One title: its entries worked out from the diary, then saved (only what changed), and any
    /// it no longer has taken off AniList.
    private func send(_ key: String, api: AniListSyncAPI) async throws {
        guard let store else { return }
        let title = store.workspace.activeTitles.first { Self.key($0) == key }
        guard let title else {
            // Trashed (or gone): its entries come off AniList.
            for (mediaId, record) in sent where record.key == key { try await delete(mediaId, record, api: api) }
            return
        }
        let chain = try await chain(for: title, key: key, api: api)
        guard !chain.isEmpty else { record(key, title.name, "AniList has no entry for it (searched by its name and year)."); return }
        let film = !title.isSeries
        let episodes = Dictionary(store.workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var watches: [AniListPlan.Watch] = []
        for event in store.workspace.activeEvents where event.titleId == title.id {
            let episode = event.episodeId.flatMap { episodes[$0] }
            if !film, episode == nil { continue }
            var aired = episode?.airedOn
            if aired == nil, chain.count > 1, let episode, let tmdb = title.tmdbId { aired = await airDay(tmdb, episode.season, episode.number) }
            watches.append(AniListPlan.Watch(season: episode?.season, number: episode?.number, aired: aired, watchedAt: event.watchedAt))
        }
        let (entries, unplaced) = AniListPlan.entries(status: title.status, score: title.score, film: film, watches: watches, chain: chain)
        for entry in entries where sent[entry.mediaId]?.entry != entry { try await save(entry, key: key, api: api) }
        let kept = Set(entries.map(\.mediaId))
        for media in chain where !kept.contains(media.id) {
            if let record = sent[media.id] { try await delete(media.id, record, api: api) }
        }
        if unplaced > 0 {
            record(key, title.name, "\(unplaced) \(unplaced == 1 ? "watch has" : "watches have") no air date to tell which AniList season it belongs to; left out.")
        } else {
            notKept.removeAll { $0.key == key }; AniListSyncStorage.save(notKept, "not-kept.json")
        }
    }

    private func save(_ entry: AniListPlan.Entry, key: String, api: AniListSyncAPI) async throws {
        var variables: [String: any Sendable] = ["mediaId": entry.mediaId, "status": entry.status, "progress": entry.progress,
                                                 "repeat": entry.repeatCount, "scoreRaw": entry.score ?? 0]
        // Both dates always: an entry no longer complete has its finish date cleared.
        let empty: [String: any Sendable] = ["year": AniListSyncAPI.Null(), "month": AniListSyncAPI.Null(), "day": AniListSyncAPI.Null()]
        variables["startedAt"] = AniListSyncAPI.fuzzy(entry.startedAt).map { $0 as [String: any Sendable] } ?? empty
        variables["completedAt"] = AniListSyncAPI.fuzzy(entry.completedAt).map { $0 as [String: any Sendable] } ?? empty
        try await pace()
        let reply = try await api.call("""
            mutation($mediaId: Int, $status: MediaListStatus, $progress: Int, $scoreRaw: Int, $repeat: Int, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput) {
              SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, scoreRaw: $scoreRaw, repeat: $repeat, startedAt: $startedAt, completedAt: $completedAt) { id }
            }
            """, variables)
        let listId = (AniListSyncAPI.data(reply)["SaveMediaListEntry"] as? [String: Any])?["id"] as? Int
        sent[entry.mediaId] = Sent(listId: listId, entry: entry, key: key)
    }
    private func delete(_ mediaId: Int, _ record: Sent, api: AniListSyncAPI) async throws {
        if let listId = record.listId {
            try await pace()
            _ = try await api.call("mutation($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }", ["id": listId])
        }
        sent[mediaId] = nil
    }

    /// AniList's burst limit: a request every two seconds at most (30 a minute).
    private func pace() async throws {
        let wait = 2.1 - Date.now.timeIntervalSince(lastCall)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastCall = .now
    }

    private func record(_ key: String, _ label: String, _ reason: String) {
        notKept.removeAll { $0.key == key }
        notKept.insert(NotKept(key: key, label: label, reason: reason, at: .now), at: 0)
        if notKept.count > 100 { notKept = Array(notKept.prefix(100)) }
        AniListSyncStorage.save(notKept, "not-kept.json")
    }
    private func record(_ key: String, _ reason: String) {
        let label = store?.workspace.activeTitles.first { Self.key($0) == key }?.name ?? key
        record(key, label, reason)
    }

    // MARK: Finding a title's AniList entries

    /// The title's AniList entries: found by its name and year, then (a show) each sequel season
    /// or cour in order. Kept for a week (the chain grows while a show airs).
    private func chain(for title: MediaTitle, key: String, api: AniListSyncAPI) async throws -> [AniListPlan.Media] {
        if let known = chains[key], Date.now.timeIntervalSince(known.at) < 7 * 86_400 { return known.media }
        let film = !title.isSeries
        try await pace()
        let reply = try await api.call("""
            query($search: String) { Page(perPage: 10) { media(search: $search, type: ANIME, sort: SEARCH_MATCH) {
              id format episodes startDate { year month day } endDate { year month day } title { romaji english native } synonyms } } }
            """, ["search": title.name])
        let rows = (AniListSyncAPI.data(reply)["Page"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
        let candidates: [AniListPlan.Candidate] = rows.compactMap { row in
            guard let media = AniListSyncAPI.media(row) else { return nil }
            let titles = row["title"] as? [String: Any] ?? [:]
            let names = ["romaji", "english", "native"].compactMap { titles[$0] as? String } + (row["synonyms"] as? [String] ?? [])
            return AniListPlan.Candidate(media: media, names: names)
        }
        let strict = !(title.category == "anime" || title.category == "anime-movie")
        guard let root = AniListPlan.pick(candidates, names: [title.name], year: title.year, film: film, strict: strict) else {
            chains[key] = Chain(media: [], at: .now); AniListSyncStorage.save(chains, "chains.json")
            return []
        }
        var chain = [root]
        if !film {
            var current = root.id
            for _ in 0..<12 {
                try await pace()
                let reply = try await api.call("""
                    query($id: Int) { Media(id: $id) { relations { edges { relationType node { id type format episodes startDate { year month day } endDate { year month day } } } } } }
                    """, ["id": current])
                let edges = ((AniListSyncAPI.data(reply)["Media"] as? [String: Any])?["relations"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
                let next = edges.first { edge in
                    guard edge["relationType"] as? String == "SEQUEL", let node = edge["node"] as? [String: Any] else { return false }
                    return node["type"] as? String == "ANIME" && ["TV", "TV_SHORT", "ONA"].contains(node["format"] as? String ?? "")
                }.flatMap { ($0["node"] as? [String: Any]).flatMap(AniListSyncAPI.media) }
                guard let next, !chain.contains(where: { $0.id == next.id }) else { break }
                chain.append(next); current = next.id
            }
        }
        chains[key] = Chain(media: chain, at: .now)
        AniListSyncStorage.save(chains, "chains.json")
        return chain
    }

    /// An episode's air day from TMDB's season (your server's without TMDB), kept.
    private func airDay(_ tmdb: Int, _ season: Int, _ number: Int) async -> String? {
        let key = "\(tmdb)/\(season)"
        if days[key] == nil, let store, let page = try? await store.catalogEpisodes(CatalogRoute(kind: .tv, id: tmdb), season: season, reveal: false) {
            var list: [Int: String] = [:]
            for episode in page.items { if let aired = episode.airedOn.map({ String($0.prefix(10)) }), aired.count == 10 { list[episode.number] = aired } }
            days[key] = list
            AniListSyncStorage.save(days, "days.json")
        }
        return days[key]?[number]
    }
}
