import Foundation
import Observation

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

    func isLoading(_ season: Int) -> Bool { reads[season] != nil }
    func error(for season: Int) -> String? { errors[season] }
    func reset() {
        generation = UUID()
        for read in reads.values { read.task.cancel() }
        reads = [:]; loaded = []; errors = [:]; episodes = [:]
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
            for episode in rows { episodes[episode.id] = episode }
            loaded.insert(season); reads.removeValue(forKey: season)
        } catch {
            guard session == generation, reads[season]?.id == read.id else { return }
            reads.removeValue(forKey: season)
            if !(error is CancellationError) { errors[season] = error.localizedDescription }
        }
    }
}
