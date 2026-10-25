import Foundation

public struct SeasonAdjustment: Sendable {
    public let record: [Episode]
    public let revoke: [WatchEvent]

    public static func plan(workspace: Workspace, titleID: String, season: Int, count: Int, today: String) throws -> Self {
        let episodes = workspace.episodes.filter { $0.titleId == titleID && $0.season == season }.sorted { $0.number < $1.number }
        guard workspace.activeTitles.contains(where: { $0.id == titleID }), !episodes.isEmpty,
              count >= 0, count <= episodes.count, validDay(today) else { throw AdjustmentError.invalidProgress }
        let desired = Set(episodes.prefix(count).map(\.id))
        let active = workspace.activeEvents.filter { $0.titleId == titleID }
        let watched = Set(active.compactMap(\.episodeId))
        let additions = episodes.filter { desired.contains($0.id) && !watched.contains($0.id) }
        guard additions.allSatisfy({ episode in
            episode.airedOn.map { validDay($0) && $0 <= today } ?? false
        }) else { throw AdjustmentError.unreleasedEpisode }
        let ids = Set(episodes.map(\.id))
        let revoked = active.filter { event in event.episodeId.map { ids.contains($0) && !desired.contains($0) } ?? false }
        return Self(record: additions, revoke: revoked)
    }
    public static func validDay(_ day: String) -> Bool {
        guard day.utf8.enumerated().allSatisfy({ index, byte in index == 4 || index == 7 ? byte == 45 : (48...57).contains(byte) }) else { return false }
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
