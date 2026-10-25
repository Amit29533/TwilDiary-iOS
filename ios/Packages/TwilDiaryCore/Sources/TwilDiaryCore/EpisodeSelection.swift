import Foundation

/// Source nextEpisode: regular aired episodes, in season/episode order, excluding skips.
public enum EpisodeSelection {
    public static func next(in workspace: Workspace, titleID: String, today: String, season: Int? = nil) -> Episode? {
        guard SeasonAdjustment.validDay(today) else { return nil }
        let watched = Set(workspace.events.filter { $0.revokedAt == nil && $0.titleId == titleID }.compactMap(\.episodeId))
        return workspace.episodes.filter { episode in
            guard episode.titleId == titleID, season == nil || episode.season == season,
                  episode.season > 0 || season == 0, episode.skipped != true, !watched.contains(episode.id),
                  let aired = episode.airedOn, SeasonAdjustment.validDay(aired), aired <= today else { return false }
            return true
        }.min { ($0.season, $0.number) < ($1.season, $1.number) }
    }
    public static func window(_ episodes: [Episode], season: Int, all: Bool = false, nextID: String?, size: Int = 4) -> [Episode] {
        let ordered = episodes.filter { $0.season == season }.sorted { $0.number < $1.number }
        if all { return ordered }
        let anchor = ordered.firstIndex { $0.id == nextID }
        let start = anchor.map { max(0, $0 - 1) } ?? max(0, ordered.count - max(0, size))
        return Array(ordered.dropFirst(start).prefix(max(0, size)))
    }
    public static func seasons(in workspace: Workspace, titleID: String) -> [Int] {
        let manifest = workspace.titles.first { $0.id == titleID }?.seasons?.map(\.number) ?? []
        let loaded = workspace.episodes.filter { $0.titleId == titleID }.map(\.season)
        return Set(manifest + loaded).sorted()
    }
    public static func preferredSeason(in workspace: Workspace, titleID: String, today: String, linkedSeason: Int? = nil) -> Int {
        let available = seasons(in: workspace, titleID: titleID)
        // TitleScreen accepts a linked season only when it exists for this title, including Specials.
        if let linkedSeason, linkedSeason >= 0, available.contains(linkedSeason) { return linkedSeason }
        if let episode = next(in: workspace, titleID: titleID, today: today) { return episode.season }
        return available.first { $0 > 0 } ?? 1
    }
}
