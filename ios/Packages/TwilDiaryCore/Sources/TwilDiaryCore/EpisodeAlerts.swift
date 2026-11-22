import Foundation

/// New-episode alerts, worked out on the phone: the next episodes to air for the shows on your
/// calendar (any you haven't dropped), from the diary's episode air dates. One alert per show per day
/// ("Frieren: S2 E3", or "S2 E3–E4" when two air together), soonest first.
public enum EpisodeAlerts {
    public struct Alert: Equatable, Sendable {
        /// Stable per show and day, so rescheduling replaces rather than duplicates.
        public let id: String
        public let titleId: String
        public let title: String
        public let day: String
        public let body: String
    }
    public static func upcoming(_ workspace: Workspace, today: String, days: Int = 14, limit: Int = 40, calendar: Calendar = DiaryDate.calendar()) -> [Alert] {
        let parts = today.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        let last = DiaryDate.day(end, timeZone: calendar.timeZone)
        // The same shows as the calendar: any you haven't dropped (planned, finished and paused too).
        let seen = Set(workspace.events.filter { $0.revokedAt == nil }.compactMap(\.episodeId))
        let shows = Dictionary(workspace.titles.filter { title in
            title.isSeries && title.deletedAt == nil && title.status != "dropped"
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: [Episode]] = [:]
        for episode in workspace.episodes where shows[episode.titleId] != nil && episode.skipped != true && !seen.contains(episode.id) {
            guard let aired = episode.airedOn?.prefix(10).description, aired >= today, aired <= last, episode.season > 0 else { continue }
            grouped[episode.titleId + "|" + aired, default: []].append(episode)
        }
        return grouped.compactMap { key, episodes -> Alert? in
            let sorted = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            guard let first = sorted.first, let last = sorted.last, let show = shows[first.titleId] else { return nil }
            let day = String(key.split(separator: "|").last ?? "")
            let span = first.season == last.season && first.number != last.number ? "S\(first.season) E\(first.number)–E\(last.number)" : "S\(first.season) E\(first.number)"
            return Alert(id: "episode|" + key, titleId: show.id, title: show.name, day: day,
                         body: sorted.count > 1 ? "\(span) are out today." : "\(span) is out today.")
        }.sorted { ($0.day, $0.title) < ($1.day, $1.title) }.prefix(limit).map { $0 }
    }
}
