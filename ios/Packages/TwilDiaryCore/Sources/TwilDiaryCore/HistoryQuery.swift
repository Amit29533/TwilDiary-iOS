import Foundation

public enum HistoryPreset: String, CaseIterable, Identifiable, Sendable {
    case all, today, week, month
    public var id: Self { self }
    public var label: String { switch self { case .all: "Any date"; case .today: "Today"; case .week: "Last 7 days"; case .month: "This month" } }
}

public struct HistoryEntry: Identifiable, Sendable {
    public var id: String { event.id }
    public let event: WatchEvent
    public let title: MediaTitle
    public let episode: Episode?
    public let rewatched: Bool
}

/// Matches activity.ts against the active collection, as supplied by the web diary context.
public struct HistoryQuery: Equatable, Codable, Sendable {
    public var query: String
    public var from: String
    public var to: String
    public var unknownOnly: Bool
    public init(query: String = "", from: String = "", to: String = "", unknownOnly: Bool = false) {
        self.query = query; self.from = from; self.to = to; self.unknownOnly = unknownOnly
    }
    public var filtered: Bool { !query.isEmpty || !from.isEmpty || !to.isEmpty || unknownOnly }
    public var invalidRange: Bool { !from.isEmpty && !to.isEmpty && from > to }
    public func events(in workspace: Workspace, timeZone: TimeZone = .current) -> [WatchEvent] {
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let needle = query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dated = distinctRows(workspace.events).compactMap { event -> (event: WatchEvent, date: Date?, recorded: Date?)? in
            guard event.revokedAt == nil, let title = titles[event.titleId],
                  needle.isEmpty || title.name.precomposedStringWithCompatibilityMapping.lowercased().contains(needle) else { return nil }
            let date = DiaryDate.parse(event.watchedAt)
            if unknownOnly && date != nil { return nil }
            if !from.isEmpty || !to.isEmpty {
                guard let date else { return nil }
                let day = DiaryDate.day(date, timeZone: timeZone)
                guard (from.isEmpty || day >= from) && (to.isEmpty || day <= to) else { return nil }
            }
            return (event, date, DiaryDate.parse(event.recordedAt))
        }
        return dated.sorted { left, right in
            if let a = left.date ?? left.recorded, let b = right.date ?? right.recorded, a != b { return a > b }
            if let a = left.recorded, let b = right.recorded, a != b { return a > b }
            return left.event.id.localizedCompare(right.event.id) == .orderedAscending
        }.map { $0.event }
    }
    public func entries(in workspace: Workspace, timeZone: TimeZone = .current) -> [HistoryEntry] {
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for event in distinctRows(workspace.activeEvents) { counts[event.episodeId ?? event.titleId, default: 0] += 1 }
        return events(in: workspace, timeZone: timeZone).compactMap { event in
            guard let title = titles[event.titleId] else { return nil }
            return HistoryEntry(event: event, title: title, episode: event.episodeId.flatMap { episodes[$0] }, rewatched: (counts[event.episodeId ?? event.titleId] ?? 0) > 1)
        }
    }
    public mutating func select(_ preset: HistoryPreset, now: Date, timeZone: TimeZone = .current) {
        unknownOnly = false
        guard preset != .all else { from = ""; to = ""; return }
        let calendar = DiaryDate.calendar(timeZone: timeZone)
        let start: Date
        switch preset {
        case .week: start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        case .month: start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        default: start = now
        }
        from = DiaryDate.day(start, timeZone: timeZone); to = DiaryDate.day(now, timeZone: timeZone)
    }
    public func selects(_ preset: HistoryPreset, now: Date, timeZone: TimeZone = .current) -> Bool {
        var expected = HistoryQuery(); expected.select(preset, now: now, timeZone: timeZone)
        return !unknownOnly && from == expected.from && to == expected.to
    }
    public static func localDay(_ day: String, timeZone: TimeZone = .current) -> Date? {
        guard SeasonAdjustment.validDay(day) else { return nil }
        let fields = day.split(separator: "-").compactMap { Int($0) }
        return DiaryDate.calendar(timeZone: timeZone).date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2]))
    }
}
