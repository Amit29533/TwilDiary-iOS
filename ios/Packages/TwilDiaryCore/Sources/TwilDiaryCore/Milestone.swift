import Foundation

/// A moment worth a bigger celebration after a new watch is confirmed: finishing a season or a
/// whole show for the first time, or reaching a round number of watches. Everything else gets
/// only the small star burst at the button.
public enum Milestone: Equatable, Sendable {
    case seasonFinished(title: String, season: Int)
    case seriesFinished(title: String)
    case watchCount(Int)

    public static let rounds = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]

    /// `workspace` must already include `event`.
    public static func after(_ event: WatchEvent, title: MediaTitle, workspace: Workspace) -> Milestone? {
        if let episodeID = event.episodeId, let episode = workspace.episodes.first(where: { $0.id == episodeID }), episode.season > 0 {
            // A rewatch never finishes a season again.
            let firstTime = !workspace.activeEvents.contains { $0.episodeId == episodeID && $0.id != event.id }
            let progress = SeasonProgress.calculate(title: title, workspace: workspace, season: episode.season)
            if firstTime, progress.total > 0, progress.watched == progress.total {
                let listed = (title.seasons ?? []).map(\.number) + workspace.episodes.filter { $0.titleId == title.id }.map(\.season)
                let last = listed.filter { $0 > 0 }.max() ?? episode.season
                return episode.season >= last ? .seriesFinished(title: title.name) : .seasonFinished(title: title.name, season: episode.season)
            }
        }
        let count = workspace.activeEvents.count
        return rounds.contains(count) ? .watchCount(count) : nil
    }

    public var headline: String {
        switch self {
        case .seasonFinished(_, let season): "Season \(season) complete"
        case .seriesFinished: "Series finished"
        case .watchCount(let count): "\(count.formatted()) watches"
        }
    }
    public var detail: String {
        switch self {
        case .seasonFinished(let title, _), .seriesFinished(let title): title
        case .watchCount: "Your diary keeps growing"
        }
    }
}
