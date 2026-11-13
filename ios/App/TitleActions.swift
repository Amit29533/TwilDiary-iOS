import Foundation
import TwilDiaryCore

extension DiaryStore {
    /// "Remove from watch history" (Cinopsys's remove-from-history): every watch of the title, on
    /// the service holding your diary (each play by its own id).
    func removeWatchHistory(_ title: MediaTitle) async {
        guard diaryFromService else { return }
        do { try await removeAllPlays(title); undoLabel = nil } catch { self.error = error.localizedDescription }
    }
    /// The status menu on a show detail belongs to the selected season.
    @discardableResult func setSeasonStatus(_ title: MediaTitle, season: Int, status: String, watchedAt: Date) async -> Bool {
        guard title.isSeries else { return await setStatus(title, status: status, watchedAt: watchedAt) }
        if status == "planned" { return await setSeasonProgress(title, season: season, count: 0, watchedAt: watchedAt) }
        if status == "completed" {
            return await perform(refreshing: [title.id]) {
                try await self.prepareSavedSeason(title, number: season)
                guard let current = self.title(title.id) else { throw CancellationError() }
                try await self.applySeasonProgress(current, season: season, count: self.seasonProgress(current, season: season).total, watchedAt: watchedAt)
            }
        }
        return await patch(title, values: ["status": status])
    }
    func seasonStatus(_ title: MediaTitle, season: Int) -> String {
        guard title.isSeries else { return title.status }
        if title.status == "dropped" { return "dropped" }
        let progress = seasonProgress(title, season: season)
        if progress.total > 0 && progress.watched >= progress.total { return "completed" }
        return progress.watched > 0 ? "watching" : "planned"
    }
    @discardableResult func setSeasonProgress(_ title: MediaTitle, season: Int, count: Int, watchedAt: Date) async -> Bool {
        await perform(refreshing: [title.id]) { try await self.applySeasonProgress(title, season: season, count: count, watchedAt: watchedAt) }
    }
    @discardableResult func completeCardSeason(_ titleID: String, season: Int) async -> Bool {
        await perform(cardID: titleID) {
            guard let title = self.title(titleID), title.isSeries else { throw APIError.message("Choose a show season.") }
            try await self.prepareSavedSeason(title, number: season)
            guard let refreshed = self.title(titleID) else { throw CancellationError() }
            let progress = SeasonProgress.calculate(title: refreshed, workspace: self.workspace, season: season)
            // This intentionally completes only this season.
            try await self.applySeasonProgress(refreshed, season: season, count: progress.total, watchedAt: self.now)
        }
    }
    private func applySeasonProgress(_ title: MediaTitle, season: Int, count: Int, watchedAt: Date) async throws {
        guard diaryFromService else { throw APIError.message(Self.needsDiary) }
        try await serviceSeasonProgress(title, season: season, count: count, watchedAt: watchedAt)
    }

    @discardableResult func recordViewing(_ title: MediaTitle, episode: Episode? = nil, rewatch: Bool = false, watchedAt: Date) async -> Bool {
        guard diaryFromService else { return false }
        return await perform(refreshing: [title.id]) {
            let numbers: [(season: Int, number: Int)] = episode.map { [(season: $0.season, number: $0.number)] } ?? []
            let when = try await self.serviceAddPlays(title, episodes: numbers, at: watchedAt)
            self.offerServiceUndo(title, at: when)
        }
    }

    @discardableResult func unwatchEpisode(_ episode: Episode) async -> Bool {
        guard diaryFromService else { return false }
        return await perform(refreshing: [episode.titleId]) {
            guard let event = self.latestServiceEvent(titleID: episode.titleId, episodeID: episode.id) else {
                throw APIError.message("There’s no watch of this episode to remove.")
            }
            try await self.serviceRemoveWatches([event])
        }
    }

    func revealedSeason(_ title: MediaTitle, number: Int) async throws -> [RevealedEpisode] {
        if isPreview { return workspace.episodes.filter { $0.titleId == title.id && $0.season == number }.map(RevealedEpisode.init) }
        // The season from TMDB, matched to the diary's episodes by number.
        guard let tmdb = title.tmdbId, title.isSeries else { return [] }
        let page = try await catalogEpisodes(CatalogRoute(kind: .tv, id: tmdb), season: number, reveal: true)
        let byNumber = Dictionary(page.items.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        return workspace.episodes.filter { $0.titleId == title.id && $0.season == number }.compactMap { episode in
            byNumber[episode.number].map { RevealedEpisode(id: episode.id, number: episode.number, name: $0.name, overview: $0.overview,
                                                           stillPath: $0.stillPath, communityScore: $0.communityScore) }
        }
    }
}

struct RevealedEpisode: Decodable, Identifiable, Sendable {
    let id: String
    let number: Int
    let name: String?
    let overview: String?
    let stillPath: String?
    let communityScore: Double?
    init(_ episode: Episode) {
        id = episode.id; number = episode.number; name = episode.name; overview = episode.overview
        stillPath = episode.still; communityScore = episode.communityScore
    }
    init(id: String, number: Int, name: String?, overview: String?, stillPath: String?, communityScore: Double?) {
        self.id = id; self.number = number; self.name = name; self.overview = overview
        self.stillPath = stillPath; self.communityScore = communityScore
    }
    var artwork: String? { stillPath.flatMap { $0.hasPrefix("/") ? CatalogTools.image($0) : $0 } }
}
