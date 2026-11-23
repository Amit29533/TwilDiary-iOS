import Foundation
import TwilDiaryCore

extension DiaryStore {
    /// "Remove from watch history" (Cinopsys's remove-from-history): every watch of the title, on
    /// the service holding your diary (each play by its own id).
    func removeWatchHistory(_ title: MediaTitle) async {
        guard diaryFromService else { return }
        do { try await removeAllPlays(title); undoLabel = nil } catch { self.error = FriendlyError.message(error) }
    }
    /// The status menu on a show detail belongs to the selected season.
    @discardableResult func setSeasonStatus(_ title: MediaTitle, season: Int, status: String, watchedAt: Date) async -> Bool {
        guard title.isSeries else { return await setStatus(title, status: status, watchedAt: watchedAt) }
        if status == "planned" {
            let done = await setSeasonProgress(title, season: season, count: 0, watchedAt: watchedAt)
            // Nothing watched anywhere: a Watching chosen by hand goes back to Planned too.
            if done, self.title(title.id)?.status == "watching", watchedEpisodeIDs(title.id).isEmpty { return await patch(title, values: ["status": "planned"]) }
            return done
        }
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
        if progress.watched > 0 { return "watching" }
        // Watching chosen before anything's watched: the title is Watching (Glance shows it), so say so.
        return title.status == "watching" && watchedEpisodeIDs(title.id).isEmpty ? "watching" : "planned"
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

    /// Waits for a change being saved or read back to finish. False when the diary isn't ready within
    /// half a minute (or isn't kept on a service at all).
    func readyToRecord() async -> Bool {
        guard !isPreview, !needsSignIn else { return false }
        for _ in 0..<60 {
            if hasLoadedWorkspace, !needsSignIn, !busy, canMutate { return diaryFromService }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
        }
        return false
    }
    /// A watch from JellySpace (a video finished there, or marked): logged once the diary is free, rather
    /// than lost when it happened to be saving something. Its time, which takes it back (undoViewing);
    /// nil when it couldn't be logged.
    func logViewing(_ title: MediaTitle, episodes: [Episode], watchedAt: Date) async -> String? {
        for _ in 0..<3 {
            guard await readyToRecord() else { return nil }
            var asked = false, logged: String?
            let done = await perform(refreshing: [title.id]) {
                asked = true
                let when = try await self.serviceAddPlays(title, episodes: episodes.map { (season: $0.season, number: $0.number) }, at: watchedAt)
                self.offerServiceUndo(title, at: when)
                logged = when
            }
            // Not asked: another change got in first, so it waits its turn again.
            if done || asked { return logged }
        }
        return nil
    }
    /// Takes back the watch logViewing logged, on every service it went to.
    @discardableResult func undoViewing(titleID: String, at when: String) async -> Bool {
        guard await readyToRecord() else { return false }
        // It may still be on its way onto the screen's diary, which is rebuilt in the background.
        for _ in 0..<20 where undoablePlays(titleID: titleID, at: when).isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !undoablePlays(titleID: titleID, at: when).isEmpty else { return false }
        let done = await perform(refreshing: [titleID]) { try await self.serviceUndoPlays(titleID: titleID, at: when) }
        // The notice's own Undo is for that watch: it has nothing left to undo.
        if done, undoTitles == [titleID] { dismissUndo() }
        return done
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
                                                           stillPath: $0.stillPath, communityScore: $0.communityScore, runtimeMinutes: $0.runtimeMinutes) }
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
    let runtimeMinutes: Int?
    init(_ episode: Episode) {
        runtimeMinutes = episode.runtimeMinutes
        id = episode.id; number = episode.number; name = episode.name; overview = episode.overview
        stillPath = episode.still; communityScore = episode.communityScore
    }
    init(id: String, number: Int, name: String?, overview: String?, stillPath: String?, communityScore: Double?, runtimeMinutes: Int? = nil) {
        self.runtimeMinutes = runtimeMinutes
        self.id = id; self.number = number; self.name = name; self.overview = overview
        self.stillPath = stillPath; self.communityScore = communityScore
    }
    var artwork: String? { stillPath.flatMap { $0.hasPrefix("/") ? CatalogTools.image($0) : $0 } }
}
