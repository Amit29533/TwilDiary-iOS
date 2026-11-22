import Foundation
import Observation
import TwilDiaryCore

/// Reveals each saved season independently. A slow season must not block a newly selected one.
@MainActor @Observable final class SavedEpisodeDetailsController {
    private struct Read {
        let id: UUID
        let task: Task<[RevealedEpisode], Error>
    }
    private var reads: [Int: Read] = [:]
    private var loaded = Set<Int>()
    private var errors: [Int: String] = [:]
    private var generation = UUID()
    private(set) var episodes: [String: RevealedEpisode] = [:]

    // Older diary snapshots have episode numbers but no runtimes. A redacted season
    // response supplies those facts even when the user keeps spoilers hidden.
    private var seasonMinutes: [Int: [Int: Int]] = [:]
    func runtime(_ episode: Episode) -> Int? {
        episodes[episode.id]?.runtimeMinutes ?? seasonMinutes[episode.season]?[episode.number] ?? episode.runtimeMinutes
    }
    func loadMissingRuntimes(_ title: MediaTitle, season: Int, store: DiaryStore) async {
        guard let tmdb = title.tmdbId, title.isSeries, seasonMinutes[season] == nil,
              store.episodesForSeason(title.id, season: season).contains(where: { $0.runtimeMinutes == nil }) else { return }
        let session = generation
        guard let page = try? await store.catalogEpisodes(CatalogRoute(kind: .tv, id: tmdb), season: season, reveal: false),
              !Task.isCancelled, session == generation else { return }
        var minutes: [Int: Int] = [:]
        for item in page.items { minutes[item.number] = item.runtimeMinutes }
        seasonMinutes[season] = minutes
    }

    func isLoading(_ season: Int) -> Bool { reads[season] != nil }
    func error(for season: Int) -> String? { errors[season] }
    func reset() {
        generation = UUID()
        for read in reads.values { read.task.cancel() }
        reads = [:]; loaded = []; errors = [:]; episodes = [:]; seasonMinutes = [:]
    }
    func load(_ season: Int, fetch: @escaping @MainActor () async throws -> [RevealedEpisode]) async {
        guard !Task.isCancelled, !loaded.contains(season) else { return }
        let session = generation
        let read: Read
        if let existing = reads[season] { read = existing }
        else {
            read = Read(id: UUID(), task: Task { try await fetch() })
            reads[season] = read; errors.removeValue(forKey: season)
        }
        do {
            let rows = try await read.task.value
            guard session == generation, reads[season]?.id == read.id else { return }
            // These valid results can be reused after the caller switches away and returns.
            // One update for the whole season, not one per episode (each redrew the episode list).
            var next = episodes
            for episode in rows { next[episode.id] = episode }
            episodes = next
            loaded.insert(season); reads.removeValue(forKey: season)
        } catch {
            guard session == generation, reads[season]?.id == read.id else { return }
            reads.removeValue(forKey: season)
            if !(error is CancellationError) { errors[season] = error.localizedDescription }
        }
    }
}
