import Foundation

public enum LibraryProgress {
    /// A partially loaded season must not appear complete; manifest counts are authoritative.
    public static func fraction(title: MediaTitle, workspace: Workspace) -> Double {
        fraction(title: title, episodes: workspace.episodes, activeEvents: workspace.activeEvents)
    }
    /// Callers may group a complete workspace once instead of scanning it for each visible card.
    public static func fraction(title: MediaTitle, episodes: [Episode], activeEvents: [WatchEvent]) -> Double {
        let events = activeEvents.filter { $0.titleId == title.id }
        if !title.isSeries { return events.contains { $0.episodeId == nil } ? 1 : 0 }
        let watched = Set(events.compactMap(\.episodeId))
        let regular = episodes.filter { $0.titleId == title.id && $0.season > 0 }
        let grouped = Dictionary(grouping: regular, by: \.season)
        var counts = grouped.mapValues { Set($0.map(\.id)).count }
        for season in title.seasons ?? [] where season.number > 0 { counts[season.number] = max(counts[season.number] ?? 0, season.expectedEpisodes ?? 0) }
        let total = counts.values.reduce(0, +)
        let count = Set(regular.map(\.id)).intersection(watched).count
        return total == 0 ? 0 : min(1, Double(count) / Double(total))
    }
}
