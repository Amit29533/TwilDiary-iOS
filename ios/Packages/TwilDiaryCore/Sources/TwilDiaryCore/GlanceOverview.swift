import Foundation

/// Orders Glance can show. "Recently updated" is the default: the title you logged last
/// comes first and gets the large card.
public enum GlanceSort: String, CaseIterable, Identifiable, Sendable {
    case recentlyUpdated = "recent", title, almostDone = "almost-done"
    public var id: Self { self }
    public var label: String {
        switch self {
        case .recentlyUpdated: "Recently updated"
        case .title: "Title A–Z"
        case .almostDone: "Almost done"
        }
    }
}

/// When a title was last logged, then when that watch happened. Imports log many plays at
/// the same moment, so the watch date decides between them.
public struct GlanceActivity: Comparable, Sendable {
    public var recorded: Date, watched: Date
    public init(recorded: Date, watched: Date? = nil) { self.recorded = recorded; self.watched = watched ?? .distantPast }
    public static func < (left: Self, right: Self) -> Bool {
        left.recorded == right.recorded ? left.watched < right.watched : left.recorded < right.recorded
    }
}

public enum GlanceOverview {
    /// Each title's newest active watch, by recordedAt and then watchedAt.
    public static func lastActivity(events: [WatchEvent]) -> [String: GlanceActivity] {
        var latest: [String: GlanceActivity] = [:]
        for event in events where event.revokedAt == nil {
            guard let recorded = DiaryDate.parse(event.recordedAt) else { continue }
            let activity = GlanceActivity(recorded: recorded, watched: DiaryDate.parse(event.watchedAt))
            if latest[event.titleId].map({ activity > $0 }) ?? true { latest[event.titleId] = activity }
        }
        return latest
    }
    /// Stable order: ties (and titles never logged) fall back to the name, then the ID.
    public static func order(_ titles: [MediaTitle], sort: GlanceSort, lastActivity: [String: GlanceActivity],
                             progress: [String: Double]) -> [MediaTitle] {
        let byName: (MediaTitle, MediaTitle) -> Bool = {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        switch sort {
        case .title:
            return titles.sorted(by: byName)
        case .recentlyUpdated:
            return titles.sorted {
                switch (lastActivity[$0.id], lastActivity[$1.id]) {
                case let (left?, right?): return left == right ? byName($0, $1) : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return byName($0, $1)
                }
            }
        case .almostDone:
            return titles.sorted {
                let left = progress[$0.id] ?? 0, right = progress[$1.id] ?? 0
                return left == right ? byName($0, $1) : left > right
            }
        }
    }
}

/// What a Glance progress card says, in the owner's wording: "S1 · E5 of 8", "63% complete",
/// "4h 12m left" or "Time unknown", and "5 / 8" between − and +.
public struct GlanceCardText: Equatable, Sendable {
    /// "S1 · E5 of 8"; very long seasons show their size as "1000+".
    public let subtitle: String
    /// "63% complete".
    public let progressLabel: String?
    /// "1h 20m left", "Time unknown" without a runtime, nil once nothing is left.
    public let timeLeft: String?
    /// The middle of the − / + control: "5 / 8".
    public let counter: String

    /// Season sizes from this one up are shown as "1000+".
    public static let cappedTotal = 1000

    public static func series(season: Int?, watched: Int, total: Int, next: Int?,
                              remainingMinutes: Int?) -> GlanceCardText {
        let prefix = season.map { $0 == 0 ? "Specials" : "S\($0)" }
        let size = total >= cappedTotal ? "\(cappedTotal)+" : String(total)
        let percent = total > 0 ? Int((Double(min(watched, total)) / Double(total) * 100).rounded()) : 0
        return GlanceCardText(
            subtitle: [prefix, "E\(watched) of \(size)"].compactMap { $0 }.joined(separator: " · "),
            progressLabel: "\(percent)% complete",
            timeLeft: timeLeft(remainingMinutes, done: watched >= total && total > 0),
            counter: "\(watched) / \(size)")
    }

    public static func movie(watched: Bool, runtimeMinutes: Int?) -> GlanceCardText {
        GlanceCardText(
            subtitle: "Movie",
            progressLabel: watched ? "100% complete" : "0% complete",
            timeLeft: timeLeft(runtimeMinutes, done: watched),
            counter: watched ? "1 / 1" : "0 / 1")
    }

    private static func timeLeft(_ minutes: Int?, done: Bool) -> String? {
        if done { return nil }
        guard let minutes else { return "Time unknown" }
        return minutes > 0 ? "\(DiaryDate.duration(minutes)) left" : nil
    }
}
