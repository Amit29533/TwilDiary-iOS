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

/// What a Glance progress card says. Every count names what it counts, the percentage says
/// whose it is (the season's), and nothing is shown when a value is unknown.
public struct GlanceCardText: Equatable, Sendable {
    /// "S1 · Watched 5 of 8 · Next E6", or "S1 · 35 watched · Next E36" for long-running seasons.
    public let subtitle: String
    /// "63% of season 1"; nil for long-running seasons, where a share of 1000+ means little.
    public let progressLabel: String?
    /// "1h 20m left"; nil when the runtime is unknown or nothing is left.
    public let timeLeft: String?
    /// The middle of the − / + control: the last watched episode ("E5"), or "–" before any.
    public let counter: String

    /// Seasons at least this long are shown as a running count instead of a share.
    public static let longRunning = 100

    public static func series(season: Int?, watched: Int, total: Int, next: Int?,
                              remainingMinutes: Int?) -> GlanceCardText {
        let prefix = season.map { $0 == 0 ? "Specials" : "S\($0)" }
        let nextText = next.map { " · Next E\($0)" } ?? ""
        let long = total >= longRunning
        let count = long ? "\(watched) watched" : "Watched \(watched) of \(total)"
        let percent = total > 0 ? Int((Double(min(watched, total)) / Double(total) * 100).rounded()) : 0
        let scope = season.map { $0 == 0 ? "specials" : "season \($0)" } ?? "this show"
        return GlanceCardText(
            subtitle: [prefix, count].compactMap { $0 }.joined(separator: " · ") + nextText,
            progressLabel: long || total == 0 ? nil : "\(percent)% of \(scope)",
            timeLeft: remainingMinutes.flatMap { $0 > 0 ? "\(DiaryDate.duration($0)) left" : nil },
            counter: watched > 0 ? "E\(watched)" : "–")
    }

    public static func movie(watched: Bool, runtimeMinutes: Int?) -> GlanceCardText {
        GlanceCardText(
            subtitle: "Movie",
            progressLabel: watched ? "Watched" : "Not watched yet",
            timeLeft: watched ? nil : runtimeMinutes.flatMap { $0 > 0 ? "\(DiaryDate.duration($0)) left" : nil },
            counter: watched ? "1" : "–")
    }
}
