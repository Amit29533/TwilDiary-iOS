import Foundation
import Observation
import Security
import UIKit
import CryptoKit
import TwilDiaryCore

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
    /// Forgetting the server also drops the Jellyfin list and posters saved on this iPhone.
    static func forget() {
        SecItemDelete(query as CFDictionary)
        for key in [addressKey, excludedKey, summaryKey] { UserDefaults.standard.removeObject(forKey: key) }
        JellyfinShelf.shared.forget()
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

/// One movie or show on Jellyfin, for the Jellyfin page: its drive (from its folder) and the
/// diary title it is, when the diary has it (matched by TMDB id and type).
struct JellyfinEntry: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let year: Int?
    let movie: Bool
    let tmdb: Int?
    let path: String
    let drive: String
    let poster: URL?
    var diaryID: String?
    /// Jellyfin's genres (from TMDB), for Library's category and genre filters; absent in lists
    /// saved before they were read.
    var genres: [String]? = nil
    /// Anime by Jellyfin's genres, as Library's Anime category counts it.
    var anime: Bool { genres?.contains { ["anime", "animation"].contains($0.lowercased()) } == true }
}

/// The Jellyfin list last read at home, kept on this iPhone so the Jellyfin page and Library's
/// Jellyfin chip work away from the home network, and on the server so every device has it (a
/// new phone, a reinstall). Reading Jellyfin at home replaces both; away, a newer server copy
/// (another device read it since) replaces this one. It stays through sign-out (it is the owner's
/// media server, not the diary); Forget Jellyfin drops only this iPhone's copy.
@MainActor @Observable final class JellyfinShelf {
    static let shared = JellyfinShelf()
    /// `server`: the server's time for this list (to ask "unchanged?"); `uploaded`: a digest of the
    /// list last sent, so an unchanged list is never written to the server again.
    private struct Saved: Codable { let at: Date; let personal: Int; let entries: [JellyfinEntry]; var server: String?; var uploaded: String? }
    private(set) var entries: [JellyfinEntry] = []
    private(set) var personal = 0
    private(set) var savedAt: Date?
    private var server: String?
    private var uploaded: String?
    private var lastTry: Date?
    private let file: URL
    init(file: URL = URL.applicationSupportDirectory.appending(path: "Jellyfin/library.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) { apply(saved) }
    }
    private func apply(_ saved: Saved) {
        entries = saved.entries; personal = saved.personal; savedAt = saved.at; server = saved.server; uploaded = saved.uploaded
    }
    /// Preview data (UI tests) is shown but never written over the owner's saved list.
    func replace(_ entries: [JellyfinEntry], personal: Int, save: Bool = true, at date: Date = .now) {
        // What the server holds is unchanged by a new read until it is sent (and then only if it differs).
        apply(Saved(at: date, personal: personal, entries: entries, server: server, uploaded: uploaded))
        if save { write() }
    }
    private func write() {
        guard let savedAt else { return }
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let saved = Saved(at: savedAt, personal: personal, entries: entries, server: server, uploaded: uploaded)
            try JSONEncoder().encode(saved).write(to: file, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var url = folder; try url.setResourceValues(values)
        } catch {
            // The list still shows until the app closes; the next read saves it again.
        }
    }
    func forget() {
        entries = []; personal = 0; savedAt = nil; server = nil; uploaded = nil; lastTry = nil
        try? FileManager.default.removeItem(at: file)
        Task { await JellyfinPosterCache.shared.removeAll() }
    }
    /// At home: reads Jellyfin, keeps the list here and sends it to the server when it changed.
    /// Away (or Jellyfin not set up on this device): takes the server's copy when it is newer,
    /// then still throws Jellyfin's error, so the page can say the list is a saved one.
    func refresh(store: DiaryStore) async throws {
        let startedAt = Date.now
        do {
            let found = try await JellyfinSync(store: store).browse()
            replace(found.entries, personal: found.personal, save: !store.isPreview, at: startedAt)
            if !store.isPreview { await upload(store: store, startedAt: startedAt) }
        } catch {
            if !store.isPreview && !(error is CancellationError) { await download(store: store) }
            throw error
        }
    }
    /// The same, quietly and at most every 10 minutes (Library): the saved list simply stays when
    /// neither Jellyfin nor the server can be reached.
    func refreshQuietly(store: DiaryStore) async {
        guard !store.isPreview, lastTry.map({ Date.now.timeIntervalSince($0) > 600 }) ?? true else { return }
        lastTry = .now
        try? await refresh(store: store)
    }
    /// What the server keeps per title: no poster URL (it holds the home network address), only
    /// Jellyfin's image tag, from which each device builds the URL with its own Jellyfin address.
    static func uploadItem(_ entry: JellyfinEntry) -> [String: Any] {
        let tag = entry.poster.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tag" }?.value }
        return ["id": entry.id, "name": entry.name, "year": entry.year as Any? ?? NSNull(), "kind": entry.movie ? "movie" : "series",
                "tmdb": entry.tmdb as Any? ?? NSNull(), "path": entry.path, "drive": entry.drive, "imageTag": tag as Any? ?? NSNull(),
                "genres": entry.genres ?? []]
    }
    /// A fingerprint of the list as sent: same list, same digest, no upload.
    static func digest(_ entries: [JellyfinEntry], personal: Int) -> String {
        let items = entries.sorted { $0.id < $1.id }.map(uploadItem)
        let data = (try? JSONSerialization.data(withJSONObject: ["personal": personal, "items": items], options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func upload(store: DiaryStore, startedAt: Date) async {
        let digest = Self.digest(entries, personal: personal)
        guard digest != uploaded else { return }
        struct Receipt: Decodable { let savedAt: String?; let stale: Bool? }
        let items = entries.map(Self.uploadItem)
        let pages = stride(from: 0, to: max(items.count, 1), by: 100).map { Array(items[$0..<min($0 + 100, items.count)]) }
        do {
            for (index, page) in pages.enumerated() {
                let last = index == pages.count - 1
                let receipt: Receipt = try await store.read("/api/jellyfin/library", method: "POST",
                    body: ["startedAt": startedAt.formatted(.iso8601), "done": last, "personal": personal, "items": page])
                if last { server = receipt.savedAt }
            }
            uploaded = digest; write()
        } catch {
            // Offline or signed out: the next read at home sends it.
        }
    }
    private func download(store: DiaryStore) async {
        struct Item: Decodable { let id: String; let name: String; let year: Int?; let kind: String; let tmdb: Int?; let path: String; let drive: String; let imageTag: String?; let genres: [String] }
        struct Library: Decodable { let savedAt: String?; let personal: Int?; let items: [Item]?; let unchanged: Bool? }
        let path = CatalogTools.apiPath("/api/jellyfin/library", query: server.map { ["since": $0] } ?? [:])
        guard let library: Library = try? await store.read(path), library.unchanged != true,
              let at = library.savedAt, let items = library.items, at != server,
              // Only a copy newer than this one: a list this iPhone read later and couldn't send yet stays.
              let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(at), date > (savedAt ?? .distantPast) else { return }
        let base = JellyfinSettings.address
        let list = items.map { item in
            JellyfinEntry(id: item.id, name: item.name, year: item.year, movie: item.kind == "movie", tmdb: item.tmdb, path: item.path,
                          drive: item.drive, poster: base.flatMap { JellyfinClient.posterURL(base: $0, item: item.id, tag: item.imageTag) },
                          diaryID: nil, genres: item.genres)
        }
        apply(Saved(at: date, personal: library.personal ?? 0, entries: list, server: at, uploaded: Self.digest(list, personal: library.personal ?? 0)))
        write()
    }
    /// The diary title each entry is, matched again against the current diary (TMDB id and type),
    /// so titles added since the list was read count; otherwise the saved match while that title
    /// is still in the diary. Nothing points at a removed title or a signed-out diary.
    static func matched(_ entries: [JellyfinEntry], diary titles: [MediaTitle]) -> [JellyfinEntry] {
        var diary: [String: String] = [:], present = Set<String>()
        for title in titles {
            present.insert(title.id)
            guard let tmdb = title.tmdbId else { continue }
            let key = (title.isSeries ? "tv:" : "movie:") + String(tmdb)
            if diary[key] == nil { diary[key] = title.id }
        }
        return entries.map { entry in
            var copy = entry
            copy.diaryID = entry.tmdb.flatMap { diary[(entry.movie ? "movie:" : "tv:") + String($0)] }
                ?? entry.diaryID.flatMap { present.contains($0) ? $0 : nil }
            return copy
        }
    }
    /// The diary titles on Jellyfin, by the saved list (Library's Jellyfin chip).
    func titleIDs(diary titles: [MediaTitle]) -> Set<String> {
        Set(Self.matched(entries, diary: titles).compactMap(\.diaryID))
    }
    /// Jellyfin titles not in the diary, for Library's Jellyfin chip, through the filters that
    /// apply to them: category ("movie", "show", "anime" by Jellyfin's genres), genres, and disk
    /// (LibraryQuery's form). Favourites only leaves none: only diary titles can be favourites.
    func extras(diary titles: [MediaTitle], category: String, genres: Set<String>, disk: String, favorites: Bool, sort: LibraryQuery.Sort) -> [JellyfinEntry] {
        guard !favorites else { return [] }
        let found = Self.matched(entries, diary: titles).filter { entry in
            guard entry.diaryID == nil else { return false }
            let categoryMatches = switch category {
            case "movie": entry.movie
            case "show": !entry.movie && !entry.anime
            case "anime": entry.anime
            default: true
            }
            let diskMatches = LibraryQuery.jellyfinDriveMatches(entry.drive, disk: disk)
            return categoryMatches && diskMatches && (genres.isEmpty || entry.genres?.contains { genres.contains($0) } == true)
        }
        // No date added or rating outside the diary: newest year when asked, otherwise by name.
        return found.sorted { left, right in
            if sort == .year, (left.year ?? 0) != (right.year ?? 0) { return (left.year ?? 0) > (right.year ?? 0) }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }
}

/// Jellyfin's posters, kept on disk (outside the diary, so sign-out leaves them) and served from
/// there without asking Jellyfin again: a poster URL carries its image tag, so a changed poster is
/// a new URL. Away from home the saved copies still show.
private final class JellyfinPosterMemory: @unchecked Sendable {
    // NSCache is safe to use from any thread.
    let values = NSCache<NSURL, UIImage>()
}

actor JellyfinPosterCache {
    static let shared = JellyfinPosterCache()
    private let session: URLSession
    private nonisolated let memory = JellyfinPosterMemory()
    init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024,
                                   directory: URL.applicationSupportDirectory.appending(path: "Jellyfin/Posters"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.values.countLimit = 300
    }
    nonisolated func resident(_ url: URL) -> UIImage? { memory.values.object(forKey: url as NSURL) }
    func image(_ url: URL) async -> UIImage? {
        if let image = resident(url) { return image }
        guard let loaded = try? await session.data(from: url),
              (loaded.1 as? HTTPURLResponse)?.statusCode == 200, loaded.0.count <= 12 * 1024 * 1024,
              let image = UIImage(data: loaded.0) else { return nil }
        memory.values.setObject(image, forKey: url as NSURL)
        return image
    }
    func removeAll() {
        memory.values.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }
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
        let Name: String?
        let ProductionYear: Int?
        let ImageTags: [String: String]?
        let Genres: [String]?
        enum CodingKeys: String, CodingKey { case Id, kind = "Type", Path, ProviderIds, SeriesId, ParentIndexNumber, Name, ProductionYear, ImageTags, Genres }
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
    /// The item's poster from Jellyfin itself (image requests need no key, so none is put in the URL).
    func poster(_ item: Item) -> URL? { Self.posterURL(base: base, item: item.Id, tag: item.ImageTags?["Primary"]) }
    static func posterURL(base: URL, item: String, tag: String?) -> URL? {
        guard let tag else { return nil }
        var components = URLComponents(url: base.appending(path: "Items/\(item)/Images/Primary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "fillHeight", value: "450"), URLQueryItem(name: "quality", value: "90"), URLQueryItem(name: "tag", value: tag)]
        return components?.url
    }
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
                URLQueryItem(name: "IncludeItemTypes", value: types), URLQueryItem(name: "Fields", value: "Path,ProviderIds,Genres"),
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
        // Quiet when Jellyfin can't be reached (away from home): Sync now reports it if tried.
        if let found = try? await client.libraries() { libraries = found; error = nil }
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
            var items: [[String: Any]] = [], movieFiles: [(ids: [String: String], file: String)] = [], personal = 0
            for (index, library) in chosen.enumerated() {
                progress = "Reading \(library.name) (\(index + 1) of \(chosen.count))…"
                let found = try await client.items(in: library.id, types: "Movie,Series")
                var series: [String: (ids: [String: String], folder: String)] = [:]
                for item in found {
                    let ids = Self.ids(item.ProviderIds)
                    guard !ids.isEmpty, let path = item.Path else { personal += 1; continue }
                    if item.kind == "Series" { series[item.Id] = (ids, path) }
                    else { movieFiles.append((ids, path)) }
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
            // A movie's location is its folder, unless several movies share that folder (a flat
            // "Movies" directory): then each keeps its own file, so one doesn't take over another's.
            let shared = Dictionary(grouping: movieFiles, by: { Self.parent($0.file) }).filter { $0.value.count > 1 }
            for movie in movieFiles {
                let folder = Self.parent(movie.file)
                items.append(["kind": "movie", "ids": movie.ids, "folder": shared[folder] == nil ? folder : movie.file, "fileCount": 1])
            }
            struct Receipt: Decodable { let mapped: Int; let notInDiary: Int }
            var mapped = 0, notInDiary = 0
            // Small pages keep each request's database statements well inside the Worker's limits.
            let pages = stride(from: 0, to: max(items.count, 1), by: 50).map { Array(items[$0..<min($0 + 50, items.count)]) }
            for (index, page) in pages.enumerated() {
                progress = "Matching with your diary (\(index + 1) of \(pages.count))…"
                let receipt: Receipt = try await store.read("/api/files/jellyfin", method: "POST", body: ["startedAt": startedAt, "done": index == pages.count - 1, "items": page])
                mapped += receipt.mapped; notInDiary += receipt.notInDiary
            }
            remember(JellyfinSummary(at: .now, mapped: mapped, notInDiary: notInDiary, personal: personal, libraries: chosen.count))
            await store.refresh()
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    /// Everything the chosen Movies and Shows libraries hold, as Sync now reads them, for the
    /// Jellyfin page. Personal items (no TMDB, IMDb or TVDB id) stay out and are only counted.
    func browse() async throws -> (entries: [JellyfinEntry], personal: Int) {
        #if DEBUG
        if store.isPreview { return (Self.previewEntries, 3) }
        #endif
        guard let client else { throw APIError.message("Add your Jellyfin address and API key first.") }
        if libraries.isEmpty { libraries = try await client.libraries() }
        let chosen = libraries.filter(isOn)
        guard !chosen.isEmpty else { throw APIError.message("Turn on at least one Movies or Shows library.") }
        var diary: [String: String] = [:]
        for title in store.workspace.activeTitles {
            if let tmdb = title.tmdbId { diary[(title.isSeries ? "tv:" : "movie:") + String(tmdb)] = title.id }
        }
        var entries: [JellyfinEntry] = [], personal = 0, seen = Set<String>()
        for library in chosen {
            for item in try await client.items(in: library.id, types: "Movie,Series") where seen.insert(item.Id).inserted {
                let ids = Self.ids(item.ProviderIds)
                guard !ids.isEmpty, let path = item.Path else { personal += 1; continue }
                let movie = item.kind == "Movie", tmdb = ids["tmdb"].flatMap { Int($0) }
                entries.append(JellyfinEntry(id: item.Id, name: item.Name ?? "Untitled", year: item.ProductionYear, movie: movie, tmdb: tmdb,
                                             path: path, drive: Self.drive(path), poster: client.poster(item),
                                             diaryID: tmdb.flatMap { diary[(movie ? "movie:" : "tv:") + String($0)] }, genres: item.Genres))
            }
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (entries, personal)
    }
    /// The drive a path is on: "E:" for Windows, \\server\share for a network share, or the
    /// first two folders of a POSIX path (/mnt/media), as the Files & drives page groups them.
    static func drive(_ path: String) -> String {
        let characters = Array(path)
        if characters.count >= 2, characters[1] == ":", characters[0].isLetter { return String(characters[0]).uppercased() + ":" }
        if path.hasPrefix("\\\\") {
            let parts = path.split(separator: "\\").map(String.init)
            return parts.count >= 2 ? "\\\\" + parts[0] + "\\" + parts[1] : path
        }
        let parts = path.split(separator: "/").map(String.init)
        return parts.count >= 3 ? "/" + parts[0] + "/" + parts[1] : "/" + (parts.first ?? "")
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
    static let previewEntries = [
        JellyfinEntry(id: "j-arrival", name: "Arrival", year: 2016, movie: true, tmdb: 329865, path: "E:\\Movies\\Arrival (2016)", drive: "E:", poster: nil, diaryID: nil, genres: ["Science Fiction", "Drama"]),
        JellyfinEntry(id: "j-dune", name: "Dune", year: 2021, movie: true, tmdb: 438631, path: "E:\\Movies\\Dune (2021)", drive: "E:", poster: nil, diaryID: nil, genres: ["Science Fiction", "Adventure"]),
        JellyfinEntry(id: "j-bocchi", name: "Bocchi the Rock!", year: 2022, movie: false, tmdb: 119100, path: "E:\\Anime\\Bocchi the Rock!", drive: "E:", poster: nil, diaryID: nil, genres: ["Animation", "Comedy"]),
        JellyfinEntry(id: "j-frieren", name: "Frieren: Beyond Journey’s End", year: 2023, movie: false, tmdb: 209867, path: "/mnt/media/Anime/Frieren", drive: "/mnt/media", poster: nil, diaryID: "frieren"),
        JellyfinEntry(id: "j-severance", name: "Severance", year: 2022, movie: false, tmdb: 95396, path: "D:\\TV\\Severance", drive: "D:", poster: nil, diaryID: "severance")
    ]
    static let previewLibraries = [
        JellyfinLibrary(id: "movies", name: "Movies", type: "movies"),
        JellyfinLibrary(id: "shows", name: "Shows", type: "tvshows"),
        JellyfinLibrary(id: "photos", name: "Photos", type: "photos"),
        JellyfinLibrary(id: "home", name: "Home videos", type: "homevideos")
    ]
    #endif
}
