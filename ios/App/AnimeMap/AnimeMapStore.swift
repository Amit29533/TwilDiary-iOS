import Foundation
import TwilDiaryCore

/// The anime map on this iPhone (`AnimeMap`). Once a week, on Wi-Fi only, the two public maps are
/// downloaded (about 15 MB) and kept whole in the app's own folder, out of iCloud backups (they can
/// always be downloaded again); from them the lookup file is built (about 710 KB, every anime TMDB
/// knows), which the syncs read. Simkl's and AniList's syncs ask it first and fall back to their own
/// matching where it's silent or its answer fails the air-date check.
@MainActor final class AnimeMapStore {
    static let shared = AnimeMapStore()
    static let mappingsURL = URL(string: "https://github.com/anibridge/anibridge-mappings/releases/download/v3/mappings.min.json")!
    static let animeApiURL = URL(string: "https://raw.githubusercontent.com/nattadasu/animeApi/v3/database/animeapi.tsv")!
    private static var folder: URL { URL.applicationSupportDirectory.appending(path: "AnimeMap") }
    private static var file: URL { folder.appending(path: "anime-map.json") }
    /// The downloads, kept whole.
    static var mappingsFile: URL { folder.appending(path: "mappings.min.json") }
    static var animeApiFile: URL { folder.appending(path: "animeapi.tsv") }
    private static let checkedKey = "animeMap.checkedAt"

    /// The map, once one has been built on this iPhone.
    private(set) var map: AnimeMap?
    private var building = false

    private init() {
        map = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(AnimeMap.self, from: $0) }
    }

    /// Downloads the maps when there are none or they're a week old, on Wi-Fi only, keeps them, and
    /// builds the lookup file. Without Wi-Fi (cellular, Low Data Mode, offline) it builds from the
    /// downloads already kept, if the lookup file is missing; otherwise it quietly does nothing and
    /// the syncs carry on with their own matching.
    func refreshIfNeeded(now: Date = .now) async {
        guard !building else { return }
        if let checked = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date, map != nil, now.timeIntervalSince(checked) < 7 * 86_400 { return }
        building = true
        defer { building = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var downloaded = false
        do {
            async let mappings = Self.fetch(Self.mappingsURL, session)
            async let animeApi = Self.fetch(Self.animeApiURL, session)
            let (first, second) = try await (mappings, animeApi)
            // Checked before the kept ones are replaced: a broken download keeps the last good pair.
            let built = try await Self.build(first, second, now: now)
            try Self.keep(first, at: Self.mappingsFile)
            try Self.keep(second, at: Self.animeApiFile)
            try Self.keep(JSONEncoder().encode(built), at: Self.file)
            map = built
            downloaded = true
            UserDefaults.standard.set(now, forKey: Self.checkedKey)
        } catch {
            // Not on Wi-Fi, or a map couldn't be read: tried again next time the app opens.
        }
        // No new download, and no lookup file: built from the downloads kept on this iPhone.
        if !downloaded, map == nil, let first = try? Data(contentsOf: Self.mappingsFile), let second = try? Data(contentsOf: Self.animeApiFile),
           let built = try? await Self.build(first, second, now: now) {
            try? Self.keep(JSONEncoder().encode(built), at: Self.file)
            map = built
        }
    }
    /// The lookup file from the two downloads (off the main thread: 15 MB takes a moment). Throws
    /// when they're too small to be the real maps.
    private nonisolated static func build(_ mappings: Data, _ animeApi: Data, now: Date) async throws -> AnimeMap {
        let builtAt = now.formatted(.iso8601)
        let built = try await Task.detached(priority: .utility) { try AnimeMap.build(mappings: mappings, animeApi: animeApi, builtAt: builtAt) }.value
        guard built.shows.count > 1000, built.simklAniList.count > 1000 else { throw CocoaError(.fileReadCorruptFile) }
        return built
    }
    /// Written whole, out of iCloud backups.
    private static func keep(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
    private nonisolated static func fetch(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("TwilDiary", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
