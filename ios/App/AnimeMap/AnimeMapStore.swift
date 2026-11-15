import Foundation
import TwilDiaryCore

/// The anime map on this iPhone (`AnimeMap`): built once a week from the two public maps,
/// downloaded on Wi-Fi only (about 16 MB), then kept as one file of about 560 KB, every anime TMDB
/// knows; the downloads are thrown away. Simkl's and AniList's syncs ask it first and fall back to
/// their own matching where it's silent or its answer fails the air-date check.
@MainActor final class AnimeMapStore {
    static let shared = AnimeMapStore()
    static let mappingsURL = URL(string: "https://github.com/anibridge/anibridge-mappings/releases/download/v3/mappings.min.json")!
    static let animeApiURL = URL(string: "https://raw.githubusercontent.com/nattadasu/animeApi/v3/database/animeapi.tsv")!
    private static var file: URL { URL.applicationSupportDirectory.appending(path: "AnimeMap/anime-map.json") }
    private static let checkedKey = "animeMap.checkedAt"

    /// The map, once one has been built on this iPhone.
    private(set) var map: AnimeMap?
    private var building = false

    private init() {
        map = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(AnimeMap.self, from: $0) }
    }

    /// Builds the map when there is none or it's a week old, on Wi-Fi only. Quietly does nothing
    /// otherwise (cellular, Low Data Mode, offline): the syncs carry on with their own matching.
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
        do {
            async let mappings = Self.fetch(Self.mappingsURL, session)
            async let animeApi = Self.fetch(Self.animeApiURL, session)
            let (first, second) = try await (mappings, animeApi)
            let builtAt = now.formatted(.iso8601)
            // Reading 16 MB takes a moment: off the main thread.
            let built = try await Task.detached(priority: .utility) { try AnimeMap.build(mappings: first, animeApi: second, builtAt: builtAt) }.value
            guard built.shows.count > 1000, built.simklAniList.count > 1000 else { return }   // a broken download keeps the last map
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(built).write(to: Self.file, options: .atomic)
            map = built
            UserDefaults.standard.set(now, forKey: Self.checkedKey)
        } catch {
            // Not on Wi-Fi, or a map couldn't be read: tried again next time the app opens.
        }
    }
    private nonisolated static func fetch(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("TwilDiary", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
