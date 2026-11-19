import Foundation

public struct SeasonAdjustment: Sendable {
    public let record: [Episode]
    public let revoke: [WatchEvent]

    public static func plan(workspace: Workspace, titleID: String, season: Int, count: Int, today: String) throws -> Self {
        let episodes = workspace.episodes.filter { $0.titleId == titleID && $0.season == season }.sorted { $0.number < $1.number }
        guard workspace.activeTitles.contains(where: { $0.id == titleID }), !episodes.isEmpty,
              count >= 0, count <= episodes.count, validDay(today) else { throw AdjustmentError.invalidProgress }
        let active = workspace.activeEvents.filter { $0.titleId == titleID }
        let watched = Set(active.compactMap(\.episodeId))
        let planned = change(episodes: episodes, watched: watched, count: count)
        let additions = planned.add, removed = Set(planned.remove.map(\.id))
        guard additions.allSatisfy({ episode in
            episode.airedOn.map { validDay($0) && $0 <= today } ?? false
        }) else { throw AdjustmentError.unreleasedEpisode }
        let revoked = active.filter { event in event.episodeId.map { removed.contains($0) } ?? false }
        return Self(record: additions, revoke: revoked)
    }
    /// What a season's "watched" count of `count` adds or takes away, keeping the history you have:
    /// raising it marks the earliest unwatched episodes, lowering it unmarks the latest watched ones,
    /// and the same count changes nothing. (Reading the count as "the first N episodes" recorded E1
    /// and revoked E4 when E2 and E4 were watched and the slider was let go at 2.)
    public static func change(episodes: [Episode], watched: Set<String>, count: Int) -> (add: [Episode], remove: [Episode]) {
        let ordered = episodes.sorted { $0.number < $1.number }
        let seen = ordered.filter { watched.contains($0.id) }
        let target = max(0, min(count, ordered.count))
        if target > seen.count { return (Array(ordered.filter { !watched.contains($0.id) }.prefix(target - seen.count)), []) }
        if target < seen.count { return ([], Array(seen.suffix(seen.count - target))) }
        return ([], [])
    }
    public static func validDay(_ day: String) -> Bool {
        guard day.utf8.enumerated().allSatisfy({ index, byte in index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte) }) else { return false }
        // The usual case by arithmetic: this runs once per episode in every progress card, and a
        // calendar and a date for each call showed up in the profile. Old dates (where the
        // calendar switches to the Julian rules) still go the long way below.
        let bytes = Array(day.utf8)
        if bytes.count == 10 {
            func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) } }
            let year = number(0..<4), month = number(5..<7), date = number(8..<10)
            if year >= 1600 {
                guard (1...12).contains(month), date >= 1 else { return false }
                let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
                return date <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            }
        }
        let fields = day.split(separator: "-", omittingEmptySubsequences: false)
        guard day.count == 10, fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let date = Int(fields[2]), year >= 1 else { return false }
        let calendar = DiaryDate.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        guard let instant = calendar.date(from: DateComponents(year: year, month: month, day: date)) else { return false }
        return calendar.component(.year, from: instant) == year && calendar.component(.month, from: instant) == month && calendar.component(.day, from: instant) == date
    }
    public enum AdjustmentError: LocalizedError {
        case invalidProgress, unreleasedEpisode
        public var errorDescription: String? {
            switch self { case .invalidProgress: "Choose a valid season progress"; case .unreleasedEpisode: "Unreleased episodes cannot be marked watched" }
        }
    }
}
