import Foundation
import Observation
import TwilDiaryCore

@MainActor @Observable final class CatalogEpisodeController {
    private let fetch: (Int, Bool) async throws -> CatalogEpisodesPage
    private var cache: [Int: (items: [CatalogEpisode], revealed: Bool)] = [:]
    private var generation = UUID()
    private(set) var season: Int?
    private(set) var items: [CatalogEpisode] = []
    private(set) var revealed = false
    private(set) var loading = false
    private(set) var error: String?
    init(fetch: @escaping (Int, Bool) async throws -> CatalogEpisodesPage) { self.fetch = fetch }
    func load(_ number: Int, reveal: Bool = false, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let request = UUID(); generation = request; season = number; error = nil
        if let saved = cache[number] { items = saved.items; revealed = saved.revealed }
        else { items = []; revealed = false }
        if !force, let saved = cache[number], !reveal || saved.revealed { loading = false; return }
        loading = true; defer { if generation == request { loading = false } }
        do {
            let result = try await fetch(number, reveal)
            guard generation == request, !Task.isCancelled else { return }
            items = result.items.sorted { $0.number < $1.number }; revealed = reveal
            cache[number] = (items, reveal)
        } catch is CancellationError { }
        catch { if generation == request, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
