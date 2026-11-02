import Foundation

/// Derived from current, non-revoked history. Importing, deleting or correcting
/// a watch updates progress; saved/planned titles never count as watches.
public struct ProfileMilestone: Identifiable, Equatable, Sendable {
    public let id: String, title: String, symbol: String, colour: String
    public let progress: Int, target: Int, unit: String
    public var earned: Bool { progress >= target }
    public var progressLabel: String { "\(min(progress, target).formatted()) / \(target.formatted())\(unit)" }

    public static func make(_ workspace: Workspace, now: Date, timeZone: TimeZone = .current) -> [Self] {
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let today = DiaryDate.day(now, timeZone: timeZone)
        let events = workspace.activeEvents.filter { event in
            guard titles[event.titleId] != nil else { return false }
            guard let date = DiaryDate.parse(event.watchedAt) else { return true }
            return DiaryDate.day(date, timeZone: timeZone) <= today
        }
        let watched = Set(events.map(\.titleId)).compactMap { titles[$0] }
        let films = watched.filter { !$0.isSeries }.count
        let anime = watched.filter { $0.category == "anime" || $0.category == "anime-movie" }.count
        let stats = StatsOverview(workspace: workspace, period: .all, now: now, timeZone: timeZone)
        let hours = stats.trend.minutes / 60
        let genres = Set(watched.flatMap(\.genres)).count
        return [
            Self(id: "first-watch", title: "First watch", symbol: "film", colour: "#b794f6", progress: events.count, target: 1, unit: ""),
            Self(id: "week-streak", title: "7-day streak", symbol: "flame", colour: "#efb769", progress: stats.streaks.longest, target: 7, unit: " days"),
            Self(id: "ten-movies", title: "10 movies", symbol: "film.stack", colour: "#70d5c7", progress: films, target: 10, unit: ""),
            Self(id: "first-anime", title: "First anime", symbol: "tv", colour: "#eda1c4", progress: anime, target: 1, unit: ""),
            Self(id: "hundred-titles", title: "100 titles", symbol: "rectangle.stack", colour: "#92baff", progress: watched.count, target: 100, unit: ""),
            Self(id: "hundred-hours", title: "100 hours", symbol: "clock", colour: "#a6b3d9", progress: hours, target: 100, unit: " h"),
            Self(id: "fifty-movies", title: "50 movies", symbol: "film.stack", colour: "#70d5c7", progress: films, target: 50, unit: ""),
            Self(id: "anime-explorer", title: "25 anime", symbol: "sparkles", colour: "#eda1c4", progress: anime, target: 25, unit: ""),
            Self(id: "month-streak", title: "30-day streak", symbol: "flame", colour: "#efb769", progress: stats.streaks.longest, target: 30, unit: " days"),
            Self(id: "genre-explorer", title: "Genre explorer", symbol: "safari", colour: "#70d5c7", progress: genres, target: 5, unit: " genres"),
            Self(id: "five-hundred-hours", title: "500 hours", symbol: "clock", colour: "#a6b3d9", progress: hours, target: 500, unit: " h")
        ]
    }
}
