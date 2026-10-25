import Foundation

/// Matches the title page's ordered episode slots, including unloaded manifest slots.
public enum EpisodeSegment: Equatable, Sendable {
    case unwatched, next, watched

    public static func make(episodes: [Episode], total: Int, watched: Set<String>, nextID: String?) -> [Self] {
        let ordered = episodes.sorted { $0.number < $1.number }
        return (0..<max(0, total)).map { index in
            guard index < ordered.count else { return .unwatched }
            let id = ordered[index].id
            if watched.contains(id) { return .watched }
            return id == nextID ? .next : .unwatched
        }
    }
}
