import Foundation
import Observation
import Security

/// The owner's Jellyfin server: its address (app settings) and API key (Keychain, this device only).
/// The phone reads Jellyfin over the home network, so the key never goes to the TwilDiary server.
@MainActor enum JellyfinSettings {
    static let addressKey = "jellyfinAddress", excludedKey = "jellyfinExcludedLibraries", summaryKey = "jellyfinLastSync"
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.amit29533.TwilDiary.jellyfin",
        kSecAttrAccount as String: "api-key"
    ]
    static var address: URL? {
        guard let text = UserDefaults.standard.string(forKey: addressKey) else { return nil }
        return normalized(text)
    }
    /// "192.168.1.20:8096" → http://192.168.1.20:8096; a trailing slash or /web is dropped.
    static func normalized(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/web") { value.removeLast(4) }
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
    static var apiKey: String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(address: URL, apiKey: String?) throws {
        UserDefaults.standard.set(address.absoluteString, forKey: addressKey)
        guard let apiKey, !apiKey.isEmpty else { return }
        let data = Data(apiKey.utf8)
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return }
        var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw APIError.message("Could not save the Jellyfin key securely.") }
    }
    static func forget() {
        SecItemDelete(query as CFDictionary)
        for key in [addressKey, excludedKey, summaryKey] { UserDefaults.standard.removeObject(forKey: key) }
    }
    static var configured: Bool { address != nil && apiKey != nil }
    static var keyHint: String? { apiKey.map { String($0.suffix(4)) } }
}

/// A Jellyfin library. Only Movies and Shows are read; the rest (photos, home videos, music)
/// are never opened, and a mixed library only when the owner turns it on.
struct JellyfinLibrary: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let type: String?
    var readable: Bool { type == "movies" || type == "tvshows" || type == nil || type == "mixed" }
    var onByDefault: Bool { type == "movies" || type == "tvshows" }
    var label: String { switch type { case "movies": "Movies"; case "tvshows": "Shows"; case nil, "mixed"?: "Mixed"; default: type!.capitalized } }
}

struct JellyfinSummary: Codable, Sendable, Equatable {
    let at: Date
    let mapped: Int
    let notInDiary: Int
    let personal: Int
    let libraries: Int
}

/// Jellyfin's REST API: PascalCase JSON, the key in a MediaBrowser authorization header.
struct JellyfinClient: Sendable {
    let base: URL
    let key: String
    struct Folder: Decodable { let Name: String; let CollectionType: String?; let ItemId: String? }
    struct Item: Decodable {
        let Id: String
        let kind: String
        let Path: String?
        let ProviderIds: [String: String]?
        let SeriesId: String?
        let ParentIndexNumber: Int?
        enum CodingKeys: String, CodingKey { case Id, kind = "Type", Path, ProviderIds, SeriesId, ParentIndexNumber }
    }
    struct Page: Decodable { let Items: [Item]; let TotalRecordCount: Int }
    struct Server: Decodable { let ServerName: String?; let Version: String? }

    private func get<T: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("MediaBrowser Client=\"TwilDiary\", Device=\"iPhone\", DeviceId=\"twildiary-ios\", Version=\"2.0\", Token=\"\(key)\"", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw APIError.message("Couldn’t reach Jellyfin. Check the address and that you’re on your home network.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw APIError.message("Jellyfin rejected the API key.") }
        guard (200..<300).contains(status) else { throw APIError.message("Jellyfin answered \(status).") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.message("That address doesn’t look like a Jellyfin server.") }
    }
    func server() async throws -> Server { try await get("System/Info") }
    func libraries() async throws -> [JellyfinLibrary] {
        let folders: [Folder] = try await get("Library/VirtualFolders")
        return folders.compactMap { folder in folder.ItemId.map { JellyfinLibrary(id: $0, name: folder.Name, type: folder.CollectionType?.lowercased()) } }
    }
    /// Every item of the given types under a library, a page at a time.
    func items(in library: String, types: String) async throws -> [Item] {
        var all: [Item] = [], start = 0
        while true {
            let page: Page = try await get("Items", [
                URLQueryItem(name: "ParentId", value: library), URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: types), URLQueryItem(name: "Fields", value: "Path,ProviderIds"),
                URLQueryItem(name: "StartIndex", value: String(start)), URLQueryItem(name: "Limit", value: "500")
            ])
            all += page.Items; start += page.Items.count
            if page.Items.isEmpty || start >= page.TotalRecordCount { return all }
        }
    }
}

/// Reads Movies and Shows libraries, keeps only items Jellyfin matched to TMDB, IMDb or TVDB
/// (anything without one is personal and only counted), and sends their folders to the server,
/// which maps them onto titles already in the diary.
@MainActor @Observable final class JellyfinSync {
    private let store: DiaryStore
    private(set) var libraries: [JellyfinLibrary] = []
    private(set) var excluded: Set<String>
    private(set) var summary: JellyfinSummary?
    private(set) var progress: String?
    private(set) var running = false
    var error: String?
    init(store: DiaryStore) {
        self.store = store
        excluded = Set(UserDefaults.standard.stringArray(forKey: JellyfinSettings.excludedKey) ?? [])
        summary = UserDefaults.standard.data(forKey: JellyfinSettings.summaryKey).flatMap { try? JSONDecoder().decode(JellyfinSummary.self, from: $0) }
    }
    var configured: Bool { store.isPreview || JellyfinSettings.configured }
    func isOn(_ library: JellyfinLibrary) -> Bool {
        library.readable && (library.onByDefault ? !excluded.contains(library.id) : excluded.contains("+" + library.id))
    }
    func toggle(_ library: JellyfinLibrary) {
        // Movies and Shows are on unless turned off ("id"); a mixed library is off unless turned on ("+id").
        let mark = library.onByDefault ? library.id : "+" + library.id
        if excluded.contains(mark) { excluded.remove(mark) } else { excluded.insert(mark) }
        UserDefaults.standard.set(Array(excluded), forKey: JellyfinSettings.excludedKey)
    }
    private var client: JellyfinClient? {
        guard let base = JellyfinSettings.address, let key = JellyfinSettings.apiKey else { return nil }
        return JellyfinClient(base: base, key: key)
    }
    func loadLibraries() async {
        #if DEBUG
        if store.isPreview { libraries = Self.previewLibraries; return }
        #endif
        guard let client else { return }
        do { libraries = try await client.libraries(); error = nil } catch { self.error = error.localizedDescription }
    }
    func run() async {
        guard !running else { return }
        running = true; error = nil; defer { running = false; progress = nil }
        #if DEBUG
        if store.isPreview {
            remember(JellyfinSummary(at: store.now, mapped: 42, notInDiary: 118, personal: 12, libraries: 2)); return
        }
        #endif
        guard let client else { error = "Add your Jellyfin address and API key first."; return }
        do {
            if libraries.isEmpty { libraries = try await client.libraries() }
            let chosen = libraries.filter(isOn)
            guard !chosen.isEmpty else { error = "Turn on at least one Movies or Shows library."; return }
            let startedAt = Date.now.formatted(.iso8601)
            var items: [[String: Any]] = [], personal = 0
            for (index, library) in chosen.enumerated() {
                progress = "Reading \(library.name) (\(index + 1) of \(chosen.count))…"
                let found = try await client.items(in: library.id, types: "Movie,Series")
                var series: [String: (ids: [String: String], folder: String)] = [:]
                for item in found {
                    let ids = Self.ids(item.ProviderIds)
                    guard !ids.isEmpty, let path = item.Path else { personal += 1; continue }
                    if item.kind == "Series" { series[item.Id] = (ids, path) }
                    else { items.append(["kind": "movie", "ids": ids, "folder": Self.parent(path), "fileCount": 1]) }
                }
                guard !series.isEmpty else { continue }
                // Season folders and their file counts, from the episodes themselves.
                var seasons: [String: [Int: (folder: String, count: Int)]] = [:]
                for episode in try await client.items(in: library.id, types: "Episode") {
                    guard let show = episode.SeriesId, series[show] != nil, let path = episode.Path else { continue }
                    let number = episode.ParentIndexNumber ?? 1
                    let entry = seasons[show]?[number]
                    seasons[show, default: [:]][number] = (entry?.folder ?? Self.parent(path), (entry?.count ?? 0) + 1)
                }
                for (id, show) in series {
                    let present = (seasons[id] ?? [:]).sorted { $0.key < $1.key }
                    items.append(["kind": "series", "ids": show.ids, "folder": show.folder, "fileCount": present.reduce(0) { $0 + $1.value.count },
                                  "seasons": present.map { ["number": $0.key, "folder": $0.value.folder, "fileCount": $0.value.count] }])
                }
            }
            struct Receipt: Decodable { let mapped: Int; let notInDiary: Int }
            var mapped = 0, notInDiary = 0
            let pages = stride(from: 0, to: max(items.count, 1), by: 200).map { Array(items[$0..<min($0 + 200, items.count)]) }
            for (index, page) in pages.enumerated() {
                progress = "Matching with your diary (\(index + 1) of \(pages.count))…"
                let receipt: Receipt = try await store.read("/api/files/jellyfin", method: "POST", body: ["startedAt": startedAt, "done": index == pages.count - 1, "items": page])
                mapped += receipt.mapped; notInDiary += receipt.notInDiary
            }
            remember(JellyfinSummary(at: .now, mapped: mapped, notInDiary: notInDiary, personal: personal, libraries: chosen.count))
            await store.refresh()
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func remember(_ value: JellyfinSummary) {
        summary = value
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: JellyfinSettings.summaryKey)
    }
    /// Jellyfin's provider IDs, as the server expects them; empty means a personal item.
    static func ids(_ provider: [String: String]?) -> [String: String] {
        var ids: [String: String] = [:]
        for (key, value) in provider ?? [:] where !value.isEmpty {
            switch key.lowercased() { case "tmdb": ids["tmdb"] = value; case "imdb": ids["imdb"] = value; case "tvdb": ids["tvdb"] = value; default: break }
        }
        return ids
    }
    /// The folder holding a file, for Windows or POSIX paths.
    static func parent(_ path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return path }
        return String(path[..<index])
    }
    #if DEBUG
    static let previewLibraries = [
        JellyfinLibrary(id: "movies", name: "Movies", type: "movies"),
        JellyfinLibrary(id: "shows", name: "Shows", type: "tvshows"),
        JellyfinLibrary(id: "photos", name: "Photos", type: "photos"),
        JellyfinLibrary(id: "home", name: "Home videos", type: "homevideos")
    ]
    #endif
}
