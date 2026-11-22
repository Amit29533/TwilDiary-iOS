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
        return orderedEvents(in: workspace, titles: titles, timeZone: timeZone, limit: nil)
    }
    private struct DatedEvent {
        let event: WatchEvent
        let date: Date?
        let recorded: Date?

        func precedes(_ other: Self) -> Bool {
            if let a = date ?? recorded, let b = other.date ?? other.recorded, a != b { return a > b }
            if let a = recorded, let b = other.recorded, a != b { return a > b }
            return event.id.localizedCompare(other.event.id) == .orderedAscending
        }
    }
    private func orderedEvents(in workspace: Workspace, titles: [String: MediaTitle], timeZone: TimeZone, limit: Int?) -> [WatchEvent] {
        let needle = query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dated = distinctRows(workspace.events).compactMap { event -> DatedEvent? in
            guard event.revokedAt == nil, let title = titles[event.titleId],
                  needle.isEmpty || title.name.precomposedStringWithCompatibilityMapping.lowercased().contains(needle) else { return nil }
            let date = DiaryDate.parse(event.watchedAt)
            if unknownOnly && date != nil { return nil }
            if !from.isEmpty || !to.isEmpty {
                guard let date else { return nil }
                let day = DiaryDate.day(date, timeZone: timeZone)
                guard (from.isEmpty || day >= from) && (to.isEmpty || day <= to) else { return nil }
            }
            return DatedEvent(event: event, date: date, recorded: DiaryDate.parse(event.recordedAt))
        }
        // For a short preview, retain only the leading rows as we compare them.
        // Missing recorded dates can make the legacy ordering depend on the full sort.
        if let limit, limit <= 16, dated.count > limit, dated.allSatisfy({ $0.recorded != nil }) {
            var newest: [DatedEvent] = []
            newest.reserveCapacity(limit)
            for row in dated {
                if newest.count == limit && !row.precedes(newest[limit - 1]) { continue }
                let position = newest.firstIndex(where: { row.precedes($0) }) ?? newest.endIndex
                newest.insert(row, at: position)
                if newest.count > limit { newest.removeLast() }
            }
            return newest.map(\.event)
        }
        let sorted = dated.sorted { $0.precedes($1) }
        return sorted.prefix(limit ?? sorted.count).map(\.event)
    }
    public func entries(in workspace: Workspace, timeZone: TimeZone = .current, limit: Int? = nil) -> [HistoryEntry] {
        if let limit, limit <= 0 { return [] }
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for event in distinctRows(workspace.activeEvents) { counts[event.episodeId ?? event.titleId, default: 0] += 1 }
        return orderedEvents(in: workspace, titles: titles, timeZone: timeZone, limit: limit).compactMap { event in
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

/// Home's Recently watched: back-to-back watches of the same show and season become one row
/// ("S1 · E2 to E5", 4 episodes). Entries come newest first.
public struct RecentWatchGroup: Identifiable, Sendable {
    public let entries: [HistoryEntry]
    public var id: String { entries.first?.id ?? "" }
    public var title: MediaTitle { entries[0].title }
    /// The newest watch's date.
    public var date: Date? { entries.lazy.compactMap { DiaryDate.parse($0.event.watchedAt) }.first }
    public var count: Int { entries.count }
    public var episodeText: String {
        let episodes = entries.compactMap(\.episode)
        guard let season = episodes.first?.season else { return "Movie" }
        let numbers = episodes.map(\.number)
        let low = numbers.min() ?? 0, high = numbers.max() ?? 0
        return low == high ? "S\(season) · E\(low)" : "S\(season) · E\(low) to E\(high)"
    }
    public static func make(_ entries: [HistoryEntry], limit: Int) -> [RecentWatchGroup] {
        var groups: [[HistoryEntry]] = []
        for entry in entries {
            if let last = groups.last?.last, last.title.id == entry.title.id, let a = last.episode, let b = entry.episode, a.season == b.season {
                groups[groups.count - 1].append(entry)
            } else {
                if groups.count == limit { break }
                groups.append([entry])
            }
        }
        return groups.map(RecentWatchGroup.init(entries:))
    }
}
