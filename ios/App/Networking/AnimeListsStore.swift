import Foundation
import TwilDiaryCore

/// The Anime-Lists mapping (see `AnimeListIndex`), downloaded the first time Simkl needs it and
/// kept in the app's caches, read again after a week. Public data from GitHub: the request
/// carries nothing about you. When it can't be had, Simkl works as before without it.
actor AnimeListsStore {
    static let shared = AnimeListsStore()
    static let source = URL(string: "https://raw.githubusercontent.com/Anime-Lists/anime-lists/master/anime-list-master.xml")!
    private let file = URL.cachesDirectory.appending(path: "AnimeLists/anime-list-master.xml")
    private var loaded: AnimeListIndex?
    private var loading: Task<AnimeListIndex?, Never>?
    private var failedAt: Date?

    /// The mapping, from memory, the cached file, or GitHub (nil when none of them has it).
    func index() async -> AnimeListIndex? {
        if let loaded { return loaded }
        if let loading { return await loading.value }
        let file = file
        let stale = failedAt.map { Date.now.timeIntervalSince($0) < 600 } ?? false
        let task = Task.detached(priority: .utility) { () -> AnimeListIndex? in
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date.now.timeIntervalSince($0) }
            let cached = (try? Data(contentsOf: file)).map(AnimeListIndex.parse).flatMap { $0.isEmpty ? nil : $0 }
            // A week-old copy is read again; while that fails, the old copy still serves.
            if let cached, let age, age < 7 * 86_400 { return cached }
            if stale { return cached }
            var request = URLRequest(url: AnimeListsStore.source, timeoutInterval: 30)
            request.setValue("TwilDiary/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100_000, data.count < 40_000_000 else { return cached }
            let fresh = AnimeListIndex.parse(data)
            guard !fresh.isEmpty else { return cached }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return fresh
        }
        loading = task
        let result = await task.value
        loading = nil
        if let result { loaded = result } else { failedAt = .now }
        return result
    }
}
