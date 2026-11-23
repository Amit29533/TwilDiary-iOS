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
        catch { throw Failure.unavailable(FriendlyError.message(error)) }
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
        let titles = node["title"] as? [String: Any]
        return AniListPlan.Media(id: id, format: node["format"] as? String, episodes: node["episodes"] as? Int, start: day(node["startDate"]), end: day(node["endDate"]),
                                 title: titles.flatMap { ($0["english"] as? String) ?? ($0["romaji"] as? String) })
    }
}

/// AniList's sign-in and the "Also save my activity to AniList" switch. Signing in opens AniList's
/// page in Apple's sheet for TwilDiary's AniList app and comes back with a token valid for a year.
@MainActor @Observable final class AniListSyncAccount {
    static let shared = AniListSyncAccount()
    static let redirect = ProviderWebSignIn.callbackScheme + "://auth/anilist"
    /// TwilDiary's AniList app (redirect twildiary://auth/anilist). A client ID is public; the
    /// implicit grant has no secret.
    nonisolated static let clientId = "57066"
    private static let nameKey = AniListSyncStorage.prefix + "username"
    private static let savingKey = AniListSyncStorage.prefix + "saving"
    private static let expiresKey = AniListSyncStorage.prefix + "expires"
    private static let idKey = AniListSyncStorage.prefix + "userId"
    /// The account last signed in to, kept through a sign-out.
    private static let lastIDKey = AniListSyncStorage.prefix + "lastUserId"
    private static let avatarKey = AniListSyncStorage.prefix + "avatar"
    /// Your AniList picture (Connections shows it, as the other services' rows do).
    private(set) var avatar: String? = UserDefaults.standard.string(forKey: AniListSyncAccount.avatarKey)
    /// The signed-in account's AniList id (its list is read by it).
    private(set) var userId: Int? = {
        let value = UserDefaults.standard.integer(forKey: AniListSyncAccount.idKey)
        return value > 0 ? value : nil
    }()

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
    private static let truthKey = AniListSyncStorage.prefix + "truth"
    private var truthValue = UserDefaults.standard.bool(forKey: AniListSyncAccount.truthKey)
    /// Source of truth: your diary (off) or AniList (on: Force Match brings AniList into the diary).
    var aniListWins: Bool {
        get { truthValue }
        set { truthValue = newValue; UserDefaults.standard.set(newValue, forKey: Self.truthKey) }
    }
    private static let notesKey = AniListSyncStorage.prefix + "notes"
    private static let privateKey = AniListSyncStorage.prefix + "private"
    private var notesValue = UserDefaults.standard.object(forKey: AniListSyncAccount.notesKey) as? Bool ?? true
    /// Your diary notes go to each entry's notes (on unless you turn it off).
    var sendNotes: Bool {
        get { notesValue }
        set { notesValue = newValue; UserDefaults.standard.set(newValue, forKey: Self.notesKey); AniListSync.shared.resendAll() }
    }
    private var privateValue = UserDefaults.standard.bool(forKey: AniListSyncAccount.privateKey)
    /// Entries saved as private on AniList (off unless you turn it on).
    var keepPrivate: Bool {
        get { privateValue }
        set { privateValue = newValue; UserDefaults.standard.set(newValue, forKey: Self.privateKey); AniListSync.shared.resendAll() }
    }
    /// The token while it's valid.
    func token() -> String? { signedIn ? AniListSyncStorage.secret("token") : nil }

    /// Signs in on AniList's page. Returns false if cancelled.
    func signIn(using session: WebAuthenticationSession) async throws -> Bool {
        var page = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        page.queryItems = [URLQueryItem(name: "client_id", value: Self.clientId), URLQueryItem(name: "response_type", value: "token")]
        let callback: URL
        do { callback = try await session.authenticate(using: page.url!, callbackURLScheme: ProviderWebSignIn.callbackScheme) }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { return false }
        let (token, expires) = try Self.token(from: callback)
        AniListSyncStorage.setSecret(token, "token")
        UserDefaults.standard.set(expires.timeIntervalSince1970, forKey: Self.expiresKey)
        hasToken = true; expiresAt = expires
        _ = try? await viewerId(AniListSyncAPI(token: token))
        Task { await AniListSync.shared.resume() }
        return true
    }
    /// Your name and picture, asked again if the picture isn't known (signed in before it was asked).
    func refreshProfile() async {
        guard avatar == nil, let token = token() else { return }
        userId = nil
        _ = try? await viewerId(AniListSyncAPI(token: token))
    }
    /// The signed-in account's id (and name and picture), asked once.
    func viewerId(_ api: AniListSyncAPI) async throws -> Int {
        if let userId { return userId }
        let reply = try await api.call("{ Viewer { id name avatar { large medium } } }")
        guard let viewer = AniListSyncAPI.data(reply)["Viewer"] as? [String: Any], let id = viewer["id"] as? Int else {
            throw AniListSyncAPI.Failure.refused("AniList didn’t say who’s signed in.")
        }
        userId = id; UserDefaults.standard.set(id, forKey: Self.idKey)
        // Another account than the one signed in before: what was saved to that one isn't on this one.
        let before = UserDefaults.standard.integer(forKey: Self.lastIDKey)
        if before > 0, before != id { AniListSync.shared.accountChanged() }
        UserDefaults.standard.set(id, forKey: Self.lastIDKey)
        if let picture = viewer["avatar"] as? [String: Any], let url = (picture["large"] as? String) ?? (picture["medium"] as? String) {
            avatar = url; UserDefaults.standard.set(url, forKey: Self.avatarKey)
        }
        if let name = viewer["name"] as? String {
            username = name; UserDefaults.standard.set(name, forKey: Self.nameKey)
            // Favourites → Characters ranks from this profile; filled in if you haven't set one.
            if (UserDefaults.standard.string(forKey: AniListMostWatched.userKey) ?? "").isEmpty { UserDefaults.standard.set(name, forKey: AniListMostWatched.userKey) }
        }
        return id
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
        // (Signed in before the account was kept through a sign-out.)
        if let userId { UserDefaults.standard.set(userId, forKey: Self.lastIDKey) }
        UserDefaults.standard.removeObject(forKey: Self.expiresKey); UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.idKey); UserDefaults.standard.removeObject(forKey: Self.avatarKey)
        hasToken = false; expiresAt = nil; username = nil; userId = nil; avatar = nil
    }
    /// Signs out and removes everything the AniList sync kept here. Nothing on AniList changes.
    func removeEverything() {
        AniListSyncStorage.removeEverything()
        hasToken = false; expiresAt = nil; username = nil; userId = nil; avatar = nil; saving = false
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
    /// When AniList last took a change (Connections shows it).
    private(set) var lastSentAt: Date? = UserDefaults.standard.object(forKey: AniListSyncStorage.prefix + "lastSent") as? Date
    /// Your AniList list against the diary (phase 2), as last checked.
    private(set) var comparison: AniListPlan.Comparison?
    private(set) var checkedAt: Date?
    private(set) var checking = false
    private(set) var checkProblem: String?
    /// While Check looks titles up: how many of how many.
    private(set) var lookupProgress: (done: Int, total: Int)?
    /// What the last Check read, as Simkl's card says it.
    struct ReadStats: Equatable { let seconds: Double; let requests: Int; let entries: Int; let byStatus: [String: Int] }
    private(set) var readStats: ReadStats?
    /// What each diary title would take from AniList (Source of truth: AniList), from the last Check.
    private(set) var adoptions: [String: (name: String, adoption: AniListPlan.Adoption)] = [:]
    /// The last Make match, Force Match or bring-in, said under the comparison.
    private(set) var lastResult: String?
    /// What Make AniList match sent that AniList still doesn't match (RetryStop): three sends, and
    /// it's ignored from then on, quietly: not sent, not shown, counted as in sync. The key is the
    /// title with the state it should have ("key|mediaId:status:progress:score,…"), so a later
    /// watch or rating is a new state, sent and checked as usual.
    @ObservationIgnored private var retry = AniListSyncStorage.load(RetryStop.self, "retry.json") ?? RetryStop()
    /// Each title's expected-state key, from the last check.
    @ObservationIgnored private var stateKeys: [String: String] = [:]
    /// AniList's list-entry ids from the last check (Force Match takes entries off by them).
    @ObservationIgnored private var listIds: [Int: Int] = [:]
    @ObservationIgnored private var chains: [String: Chain] = AniListSyncStorage.load([String: Chain].self, AniListSync.chainsFile) ?? [:]
    @ObservationIgnored private var sent: [Int: Sent] = AniListSyncStorage.load([Int: Sent].self, "sent.json") ?? [:]
    @ObservationIgnored private var days: [String: [Int: String]] = AniListSyncStorage.load([String: [Int: String]].self, "days.json") ?? [:]
    @ObservationIgnored private weak var store: DiaryStore?
    @ObservationIgnored private var lastCall = Date.distantPast
    @ObservationIgnored private var notReadyTries: [String: Int] = [:]

    nonisolated static func key(_ title: MediaTitle) -> String? {
        title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) }
    }
    /// Anime, anime films and other animation (Chinese and Korean animation the diary keeps as shows).
    nonisolated static func counts(_ title: MediaTitle) -> Bool { CastRanking.animated(title) }

    // MARK: Taking edits

    /// A diary edit (from `DiaryStore.mirror`): its title waits to be sent.
    func capture(_ mutations: [OptimisticMutation], store: DiaryStore) {
        guard !store.isPreview, AniListSyncAccount.shared.canSend else { return }
        self.store = store
        let keys = Set(mutations.map(\.titleId)).compactMap { id -> String? in
            guard let title = store.title(id) ?? PhoneCatalog.shared.titles[id], Self.counts(title) else { return nil }
            return Self.key(title)
        }
        guard !keys.isEmpty else { return }
        mark(keys)
        // A moment's wait: adding a title rebuilds the diary in the background.
        Task { try? await Task.sleep(for: .seconds(2)); await resume() }
    }
    private func mark(_ keys: [String]) {
        for key in keys where !waiting.contains(key) { waiting.append(key) }
        AniListSyncStorage.save(waiting, "waiting.json")
    }
    func clearNotKept() { notKept = []; AniListSyncStorage.save(notKept, "not-kept.json") }
    /// Signed in to another AniList account: every title waits to be sent to it, and nothing read from or
    /// saved to the last one counts here (its entries passed for this account's, so they never went).
    func accountChanged() {
        sent = [:]; AniListSyncStorage.save(sent, "sent.json")
        listIds = [:]; comparison = nil; checkedAt = nil; readStats = nil; adoptions = [:]; lastResult = nil
        retry = RetryStop(); AniListSyncStorage.save(retry, "retry.json")
        guard let diary = store?.workspace else { return }
        mark(diary.activeTitles.filter(Self.counts).compactMap(Self.key))
    }
    func forget() {
        waiting = []; notKept = []; chains = [:]; sent = [:]; days = [:]; lastProblem = nil; progress = nil; comparison = nil; checkedAt = nil
        readStats = nil; adoptions = [:]; lastResult = nil
    }

    // MARK: Sending

    /// Sends what's waiting, a title at a time, paced to AniList's limit (30 a minute for now).
    func resume(store: DiaryStore? = nil) async {
        if let store, !store.isPreview { self.store = store }
        // Every anime not sent yet goes on its own: the first full sync, and titles added since.
        if !sending, AniListSyncAccount.shared.canSend, let diary = self.store?.workspace {
            mark(diary.activeTitles.filter(Self.counts).compactMap(Self.key).filter { chains[$0] == nil })
        }
        guard !sending, AniListSyncAccount.shared.canSend, self.store != nil, !waiting.isEmpty else { return }
        sending = true
        defer { sending = false; progress = nil }
        var done = 0
        while let key = waiting.first, AniListSyncAccount.shared.canSend {
            guard let token = AniListSyncAccount.shared.token() else { break }
            progress = (done, done + waiting.count)
            do {
                try await send(key, api: AniListSyncAPI(token: token))
                waiting.removeAll { $0 == key }; done += 1; lastProblem = nil
            } catch is NotReady {
                // Tried again in a few seconds (it stays waiting).
                Task { try? await Task.sleep(for: .seconds(5)); await resume() }
                break
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
                    waiting.removeAll { $0 == key }; done += 1
                    continue
                }
                break
            } catch {
                lastProblem = FriendlyError.message(error)
                break
            }
            AniListSyncStorage.save(waiting, "waiting.json")
        }
        AniListSyncStorage.save(waiting, "waiting.json")
        AniListSyncStorage.save(sent, "sent.json")
    }

    /// A title added a moment ago that the diary doesn't have yet: tried again shortly.
    private struct NotReady: Error {}
    /// One title: its entries worked out from the diary, then saved (only what changed), and any
    /// it no longer has taken off AniList.
    private func send(_ key: String, api: AniListSyncAPI) async throws {
        guard let store else { return }
        let found = store.workspace.titles.first { Self.key($0) == key && $0.deletedAt == nil } ?? store.workspace.titles.first { Self.key($0) == key }
        guard let title = found, title.deletedAt == nil else {
            // Just added on this phone, the diary not rebuilt yet: not "gone".
            // At most three tries (a trashed title may linger in the phone's catalog).
            if found == nil, PhoneCatalog.shared.titles.values.contains(where: { Self.key($0) == key }), notReadyTries[key, default: 0] < 3 {
                notReadyTries[key, default: 0] += 1
                throw NotReady()
            }
            notReadyTries[key] = nil
            // Trashed (or gone): its entries come off AniList.
            for (mediaId, record) in sent where record.key == key { try await delete(mediaId, record, api: api) }
            return
        }
        let chain = try await chain(for: title, key: key, api: api)
        guard !chain.isEmpty else { record(key, title.name, "AniList has no entry for it (searched by its name and year)."); return }
        let (entries, unplaced) = await plan(for: title, chain: chain)
        for entry in entries where sent[entry.mediaId]?.entry != entry { try await save(entry, key: key, api: api) }
        let kept = Set(entries.map(\.mediaId))
        for media in chain where !kept.contains(media.id) {
            if let record = sent[media.id] { try await delete(media.id, record, api: api) }
        }
        // Entries saved for this title before that aren't its entries now (a wrong match, such as
        // the commercial "Your Name." was first matched to): taken off AniList.
        let current = Set(chain.map(\.id))
        for (mediaId, record) in sent where record.key == key && !current.contains(mediaId) { try await delete(mediaId, record, api: api) }
        if unplaced > 0 {
            record(key, title.name, "\(unplaced) \(unplaced == 1 ? "watch has" : "watches have") no air date to tell which AniList season it belongs to; left out.")
        } else {
            notKept.removeAll { $0.key == key }; AniListSyncStorage.save(notKept, "not-kept.json")
        }
    }

    /// The title's entries as the diary has them (its watches, each episode's air day).
    private func plan(for title: MediaTitle, chain: [AniListPlan.Media]) async -> (entries: [AniListPlan.Entry], unplaced: Int) {
        guard let store else { return ([], 0) }
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
        return AniListPlan.entries(status: title.status, score: title.score, film: film, watches: watches, chain: chain,
                                   notes: AniListSyncAccount.shared.sendNotes ? title.notes : nil, placed: placed(title, watches, chain))
    }
    /// The anime map's entry for each watched episode, where it's one of the title's entries and
    /// the episode aired within 30 days of that entry's run ("1x26" → AniList id).
    private func placed(_ title: MediaTitle, _ watches: [AniListPlan.Watch], _ chain: [AniListPlan.Media]) -> [String: Int] {
        guard title.isSeries, let tmdb = title.tmdbId, let map = AnimeMapStore.shared.map else { return [:] }
        var result: [String: Int] = [:]
        for watch in watches {
            guard let season = watch.season, let number = watch.number, let mapped = map.anilist(tmdb: tmdb, season: season, episode: number),
                  let media = chain.first(where: { $0.id == mapped.id }), AnimeMap.plausible(day: watch.aired, start: media.start, end: media.end) else { continue }
            result["\(season)x\(number)"] = media.id
        }
        return result
    }

    // MARK: Reading AniList back (phase 2)

    /// Reads your AniList list (one request) and compares it with what the diary expects, for the
    /// titles whose entries are looked up. What AniList holds is remembered as what was last sent,
    /// so only real changes go afterwards and a trashed title's entries can be taken off.
    func check(store: DiaryStore) async {
        guard !checking, let token = AniListSyncAccount.shared.token() else { return }
        self.store = store
        checking = true; checkProblem = nil
        defer { checking = false; lookupProgress = nil }
        let api = AniListSyncAPI(token: token), started = Date.now
        var requests = 0
        do {
            // Titles not looked up yet are looked up first (reading AniList only): the comparison
            // needs every title's entries, whether or not saving is on.
            let titles = store.workspace.activeTitles.filter(Self.counts)
            let missing = titles.filter { Self.key($0).map { chains[$0] == nil } ?? false }
            for (index, title) in missing.enumerated() {
                lookupProgress = (index, missing.count)
                guard let key = Self.key(title) else { continue }
                do { _ = try await chain(for: title, key: key, api: api); requests += 2 }
                catch AniListSyncAPI.Failure.busy(let seconds) { try? await Task.sleep(for: .seconds(min(max(seconds, 5), 90))) }
            }
            lookupProgress = nil
            let userId = try await AniListSyncAccount.shared.viewerId(api)
            try await pace(); requests += 1
            let reply = try await api.call("""
                query($id: Int) { MediaListCollection(userId: $id, type: ANIME) { lists { entries {
                  id mediaId status progress repeat notes updatedAt score(format: POINT_100) startedAt { year month day } completedAt { year month day } media { title { romaji english } } } } } }
                """, ["id": userId])
            let lists = (AniListSyncAPI.data(reply)["MediaListCollection"] as? [String: Any])?["lists"] as? [[String: Any]] ?? []
            listIds = [:]
            var listed: [AniListPlan.Listed] = [], actual: [Int: (listId: Int, entry: AniListPlan.Entry)] = [:], details: [AniListPlan.ListedDetail] = []
            for row in lists.flatMap({ $0["entries"] as? [[String: Any]] ?? [] }) {
                guard let mediaId = row["mediaId"] as? Int, let listId = row["id"] as? Int, actual[mediaId] == nil else { continue }
                let status = row["status"] as? String ?? "CURRENT", progress = row["progress"] as? Int ?? 0
                let score = (row["score"] as? NSNumber).map { Int($0.doubleValue.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
                let titles = (row["media"] as? [String: Any])?["title"] as? [String: Any]
                let name = (titles?["english"] as? String) ?? (titles?["romaji"] as? String) ?? "AniList \(mediaId)"
                let notes = (row["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let updated = (row["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue).ISO8601Format() }
                listed.append(AniListPlan.Listed(mediaId: mediaId, listId: listId, status: status, progress: progress, score: score, title: name))
                details.append(AniListPlan.ListedDetail(mediaId: mediaId, status: status, progress: progress, score: score, notes: notes, updatedAt: updated))
                actual[mediaId] = (listId, AniListPlan.Entry(mediaId: mediaId, status: status, progress: progress, score: score,
                                                              startedAt: AniListSyncAPI.day(row["startedAt"]), completedAt: AniListSyncAPI.day(row["completedAt"]),
                                                              repeatCount: row["repeat"] as? Int ?? 0, notes: notes))
                listIds[mediaId] = listId
            }
            var expected: [AniListPlan.Expected] = [], notLookedUp = 0, keyOf: [Int: String] = [:], found: [String: (name: String, adoption: AniListPlan.Adoption)] = [:]
            for title in titles {
                guard let key = Self.key(title) else { continue }
                guard let chain = chains[key]?.media else { notLookedUp += 1; continue }
                for media in chain { keyOf[media.id] = key }
                guard !chain.isEmpty else { continue }
                for entry in await plan(for: title, chain: chain).entries {
                    let part = chain.count > 1 ? ((chain.first { $0.id == entry.mediaId }?.title).map { " · " + $0 } ?? "") : ""
                    expected.append(AniListPlan.Expected(key: key, label: title.name + part, entry: entry))
                }
                // What AniList would bring into the diary (Source of truth: AniList).
                if let adoption = await adoption(for: title, chain: chain, details: details), !adoption.isEmpty { found[key] = (title.name, adoption) }
            }
            for (mediaId, key) in keyOf {
                if let there = actual[mediaId] { sent[mediaId] = Sent(listId: there.listId, entry: there.entry, key: key) }
                else { sent[mediaId] = nil }
            }
            AniListSyncStorage.save(sent, "sent.json")
            var compared = AniListPlan.compare(expected: expected, listed: listed, notLookedUp: notLookedUp)
            stateKeys = Dictionary(grouping: expected, by: \.key).mapValues { group in
                (group.first?.key ?? "") + "|" + group.map { "\($0.entry.mediaId):\($0.entry.status):\($0.entry.progress):\($0.entry.score ?? 0)" }.sorted().joined(separator: ",")
            }
            // Sent three times and still different (nothing waiting to go): ignored from now on.
            if waiting.isEmpty, !sending {
                retry.observe(missing: Set(compared.keysToSend.compactMap { stateKeys[$0] }))
                AniListSyncStorage.save(retry, "retry.json")
            }
            let ignored = { (difference: AniListPlan.Difference) in difference.key.flatMap { self.stateKeys[$0] }.map { self.retry.isParked($0) } ?? false }
            compared.missing.removeAll(where: ignored)
            compared.different.removeAll(where: ignored)
            comparison = compared
            adoptions = found
            readStats = ReadStats(seconds: Date.now.timeIntervalSince(started), requests: requests, entries: listed.count,
                                  byStatus: Dictionary(grouping: listed, by: \.status).mapValues(\.count))
            checkedAt = .now
        } catch let failure as AniListSyncAPI.Failure {
            switch failure {
            case .signIn: AniListSyncAccount.shared.signOut(); checkProblem = "AniList signed TwilDiary out. Sign in again."
            case .busy(let seconds): checkProblem = "AniList asked to slow down. Try again in \(seconds) s."
            case .unavailable(let message), .refused(let message): checkProblem = message
            }
        } catch { checkProblem = FriendlyError.message(error) }
    }

    /// What one title would take from AniList, with TMDB's air days fetched for its seasons when
    /// AniList has episodes the diary hasn't.
    private func adoption(for title: MediaTitle, chain: [AniListPlan.Media], details: [AniListPlan.ListedDetail]) async -> AniListPlan.Adoption? {
        guard let store else { return nil }
        let ids = Set(chain.map(\.id))
        guard details.contains(where: { ids.contains($0.mediaId) }) else { return nil }
        let film = !title.isSeries
        let episodes = Dictionary(store.workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let watches: [AniListPlan.Watch] = store.workspace.activeEvents.filter { $0.titleId == title.id }.map { event in
            let episode = event.episodeId.flatMap { episodes[$0] }
            return AniListPlan.Watch(season: episode?.season, number: episode?.number, aired: episode?.airedOn, watchedAt: event.watchedAt)
        }
        func plan(_ seasons: [Int: [Int: String]]) -> AniListPlan.Adoption {
            AniListPlan.adoption(diaryStatus: title.status, diaryScore: title.score, diaryNotes: title.notes, film: film, watches: watches,
                                 chain: chain, listed: details, seasons: seasons, map: AnimeMapStore.shared.map, tmdb: title.tmdbId)
        }
        var result = plan([:])
        guard !film, result.unplaced > 0, let tmdb = title.tmdbId else { return result }
        // AniList has episodes the diary hasn't: TMDB's seasons name them (the diary's, and one more).
        let known = Set(watches.compactMap(\.season)).filter { $0 > 0 }
        var seasons: [Int: [Int: String]] = [:]
        for season in 0...min(10, (known.max() ?? 0) + 1) {
            _ = await airDay(tmdb, season, 1)
            if let list = days["\(tmdb)/\(season)"], !list.isEmpty { seasons[season] = list }
        }
        result = plan(seasons)
        return result
    }

    /// Source of truth: AniList. Each title takes AniList's status, score and note (where the diary
    /// has none), and the episodes AniList has watched that the diary hasn't, logged at the time
    /// AniList last changed that entry. Nothing is taken off the diary. Then AniList is read again.
    func bringIntoDiary(store: DiaryStore) {
        self.store = store
        let work = adoptions.sorted { $0.key < $1.key }
        guard !work.isEmpty else { return }
        Task {
            var titlesDone = 0, watches = 0, failed: [String] = []
            for (key, item) in work {
                guard let title = store.workspace.activeTitles.first(where: { Self.key($0) == key }) else { continue }
                let adoption = item.adoption
                var values: [String: Any] = [:]
                if let status = adoption.status { values["status"] = status }
                if let score = adoption.score { values["score"] = score }
                if let notes = adoption.notes { values["notes"] = notes }
                do {
                    if !values.isEmpty { _ = await store.patch(title, values: values) }
                    if let at = adoption.filmWatch {
                        try await store.serviceAddPlays(title, episodes: [], at: Self.date(at)); watches += 1
                    }
                    for (at, group) in Dictionary(grouping: adoption.episodes, by: { $0.at ?? "" }) {
                        try await store.serviceAddPlays(title, episodes: group.map { (season: $0.season, number: $0.number) }, at: Self.date(at.isEmpty ? nil : at))
                        watches += group.count
                    }
                    titlesDone += 1
                } catch { failed.append(item.name) }
            }
            lastResult = "From AniList: " + titlesDone.counted("title", "titles") + " updated, " + watches.counted("watch", "watches") + " added to your diary."
                + (failed.isEmpty ? "" : " Not brought in: " + failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? " and \(failed.count - 3) more." : "."))
            await check(store: store)
        }
    }
    /// Force Match from the chosen side: your diary onto AniList (entries only on AniList taken
    /// off), or AniList into your diary.
    func forceMatch(store: DiaryStore) {
        if AniListSyncAccount.shared.aniListWins { bringIntoDiary(store: store) }
        else {
            let count = (comparison?.keysToSend.count ?? 0) + (comparison?.onlyOnAniList.count ?? 0)
            lastResult = "Force Match: " + count.counted("change", "changes") + " on the way to AniList. AniList is checked again after."
            makeMatch(store: store, force: true)
        }
    }
    private static func date(_ text: String?) -> Date {
        text.flatMap { try? Date($0, strategy: .iso8601) } ?? .now
    }

    /// "Make AniList match": every title with a difference is sent again (what AniList holds isn't
    /// trusted as sent), then AniList is read again. `force`: entries only on AniList come off too,
    /// so AniList is exactly your diary.
    func makeMatch(store: DiaryStore, force: Bool = false) {
        guard let comparison else { return }
        self.store = store
        for difference in comparison.missing + comparison.different { sent[difference.mediaId] = nil }
        AniListSyncStorage.save(sent, "sent.json")
        mark(comparison.keysToSend)
        retry.sent(comparison.keysToSend.compactMap { stateKeys[$0] }); AniListSyncStorage.save(retry, "retry.json")
        if !force { lastResult = comparison.keysToSend.count.counted("title", "titles") + " on the way to AniList. They go in the background; AniList is checked again after." }
        let extra = force ? comparison.onlyOnAniList.compactMap { listIds[$0.mediaId] } : []
        Task {
            if !extra.isEmpty, let token = AniListSyncAccount.shared.token() {
                let api = AniListSyncAPI(token: token)
                for listId in extra {
                    do { try await pace(); _ = try await api.call("mutation($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }", ["id": listId]) }
                    catch { lastProblem = "Force Match stopped taking entries off AniList: " + FriendlyError.message(error); break }
                }
            }
            await resume(); await check(store: store)
        }
    }
    /// The notes or private setting changed: every entry sent so far goes again.
    func resendAll() {
        let keys = Array(Set(sent.values.map(\.key))).sorted()
        sent = [:]; AniListSyncStorage.save(sent, "sent.json")
        mark(keys)
        Task { await resume() }
    }

    private func save(_ entry: AniListPlan.Entry, key: String, api: AniListSyncAPI) async throws {
        var variables: [String: any Sendable] = ["mediaId": entry.mediaId, "status": entry.status, "progress": entry.progress,
                                                 "repeat": entry.repeatCount, "scoreRaw": entry.score ?? 0]
        // Both dates always: an entry no longer complete has its finish date cleared.
        let empty: [String: any Sendable] = ["year": AniListSyncAPI.Null(), "month": AniListSyncAPI.Null(), "day": AniListSyncAPI.Null()]
        variables["startedAt"] = AniListSyncAPI.fuzzy(entry.startedAt).map { $0 as [String: any Sendable] } ?? empty
        variables["completedAt"] = AniListSyncAPI.fuzzy(entry.completedAt).map { $0 as [String: any Sendable] } ?? empty
        variables["notes"] = entry.notes ?? ""
        variables["private"] = AniListSyncAccount.shared.keepPrivate
        try await pace()
        let reply = try await api.call("""
            mutation($mediaId: Int, $status: MediaListStatus, $progress: Int, $scoreRaw: Int, $repeat: Int, $startedAt: FuzzyDateInput, $completedAt: FuzzyDateInput, $notes: String, $private: Boolean) {
              SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, scoreRaw: $scoreRaw, repeat: $repeat, startedAt: $startedAt, completedAt: $completedAt, notes: $notes, private: $private) { id }
            }
            """, variables)
        let listId = (AniListSyncAPI.data(reply)["SaveMediaListEntry"] as? [String: Any])?["id"] as? Int
        sent[entry.mediaId] = Sent(listId: listId, entry: entry, key: key)
        lastSentAt = .now; UserDefaults.standard.set(lastSentAt, forKey: AniListSyncStorage.prefix + "lastSent")
    }
    private func delete(_ mediaId: Int, _ record: Sent, api: AniListSyncAPI) async throws {
        if let listId = record.listId {
            try await pace()
            do { _ = try await api.call("mutation($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }", ["id": listId]) }
            catch AniListSyncAPI.Failure.refused(let message) where message.localizedCaseInsensitiveContains("not found") {
                // Taken off on AniList already (it was refused again at every later edit of the title).
            }
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
        let film = !title.isSeries
        // The anime map's entries for the title (its specials and OVAs too). A kept chain without
        // all of them is looked up again.
        let map = AnimeMapStore.shared.map
        let mapped: [Int] = title.tmdbId.map { tmdb in film ? (map?.anilistFilm(tmdb: tmdb).map { [$0] } ?? []) : (map?.anilistEntries(tmdb: tmdb) ?? []) } ?? []
        if let known = chains[key], Date.now.timeIntervalSince(known.at) < 7 * 86_400, Set(mapped).isSubset(of: Set(known.media.map(\.id))) { return known.media }
        // 0. The anime map's entries, in one request. They're added to the look-up below, never
        // instead of it: the map can be wrong for a whole title (it gives Bisque Doll only its
        // second season's entry, so the first season's watches would have gone there).
        var fromMap: [AniListPlan.Media] = []
        if !mapped.isEmpty {
            try await pace()
            let reply = try await api.call("""
                query($ids: [Int]) { Page(perPage: 50) { media(id_in: $ids, type: ANIME) { id format episodes startDate { year month day } endDate { year month day } title { romaji english } } } }
                """, ["ids": mapped])
            let rows = ((AniListSyncAPI.data(reply)["Page"] as? [String: Any])?["media"] as? [[String: Any]] ?? []).compactMap(AniListSyncAPI.media)
            fromMap = mapped.compactMap { id in rows.first { $0.id == id } }
        }
        var root: AniListPlan.Media?
        // 1. The TMDB-to-AniList id map (the community anime lists; TMDB ids only are sent).
        if let tmdb = title.tmdbId, let id = await Self.mappedID(tmdb: tmdb, film: film) {
            if let known = fromMap.first(where: { $0.id == id }) { root = known } else {
                try await pace()
                let reply = try await api.call("""
                    query($id: Int) { Media(id: $id, type: ANIME) { id format episodes startDate { year month day } endDate { year month day } title { romaji english } } }
                    """, ["id": id])
                root = (AniListSyncAPI.data(reply)["Media"] as? [String: Any]).flatMap(AniListSyncAPI.media)
            }
        }
        // 2. AniList's search, under simpler names when the full one finds nothing (and the map
        // has nothing either).
        if root == nil, fromMap.isEmpty {
            let names = AniListPlan.searchNames(title.name)
            let strict = !(title.category == "anime" || title.category == "anime-movie")
            for name in names.prefix(4) {
                try await pace()
                let reply = try await api.call("""
                    query($search: String) { Page(perPage: 10) { media(search: $search, type: ANIME, sort: SEARCH_MATCH) {
                      id format episodes startDate { year month day } endDate { year month day } title { romaji english native } synonyms } } }
                    """, ["search": name])
                let rows = (AniListSyncAPI.data(reply)["Page"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
                let candidates: [AniListPlan.Candidate] = rows.compactMap { row in
                    guard let media = AniListSyncAPI.media(row) else { return nil }
                    let titles = row["title"] as? [String: Any] ?? [:]
                    let names = ["romaji", "english", "native"].compactMap { titles[$0] as? String } + (row["synonyms"] as? [String] ?? [])
                    return AniListPlan.Candidate(media: media, names: names)
                }
                root = AniListPlan.pick(candidates, names: names, year: title.year, film: film, strict: strict)
                if root != nil { break }
            }
        }
        guard let root = root ?? fromMap.first else {
            chains[key] = Chain(media: [], at: .now); AniListSyncStorage.save(chains, Self.chainsFile)
            return []
        }
        var chain = [root]
        if !film {
            try await sequels(&chain, api: api)
            // The map's entries the look-up didn't reach: specials, OVAs, a season it missed.
            for media in fromMap where !chain.contains(where: { $0.id == media.id }) { chain.append(media) }
        }
        chains[key] = Chain(media: chain, at: .now)
        AniListSyncStorage.save(chains, Self.chainsFile)
        return chain
    }
    /// Each sequel season or cour after the chain's last season (TV, TV short or ONA), in order.
    private func sequels(_ chain: inout [AniListPlan.Media], api: AniListSyncAPI) async throws {
        guard var current = chain.last(where: { ["TV", "TV_SHORT", "ONA"].contains($0.format ?? "TV") })?.id else { return }
        for _ in 0..<12 {
            try await pace()
            let reply = try await api.call("""
                query($id: Int) { Media(id: $id) { relations { edges { relationType node { id type format episodes startDate { year month day } endDate { year month day } title { romaji english } } } } } }
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
    /// The looked-up entries. "-v2": found by the id map (the first look-ups searched by name only,
    /// and matched "Your Name." to a commercial), so every title is looked up again once.
    static let chainsFile = "chains-v2.json"
    /// The AniList id for a TMDB id from the community anime lists (arm.haglund.dev, as CrossWatch
    /// uses them): a film's entry, or a show's first season. Nil when it isn't listed.
    static func mappedID(tmdb: Int, film: Bool) async -> Int? {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/themoviedb?id=\(tmdb)"),
              let reply = try? await URLSession.shared.data(from: url), (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return mappedID(from: reply.0, film: film)
    }
    /// From the id map's reply: entries of the right kind (TMDB's movie and TV ids overlap) with an
    /// AniList id; a show's first season (or its lowest), a film's first.
    nonisolated static func mappedID(from data: Data, film: Bool) -> Int? {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        let fitting = rows.filter { row in
            guard row["anilist"] as? Int != nil else { return false }
            let media = row["media"] as? String ?? ""
            return film ? media == "MOVIE" : media != "MOVIE"
        }
        if film { return fitting.first?["anilist"] as? Int }
        let seasons = fitting.sorted { (($0["themoviedb-season"] as? Int) ?? 999) < (($1["themoviedb-season"] as? Int) ?? 999) }
        return seasons.first?["anilist"] as? Int
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
