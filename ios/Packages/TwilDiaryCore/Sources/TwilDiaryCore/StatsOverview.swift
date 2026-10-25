import Foundation

/// Mirrors src/lib/domain/stats.ts. Days are UTC surrogates of the diary's local
/// dates, so DST never changes an inclusive day count or a comparison interval.
public struct StatsOverview: Codable, Equatable, Sendable {
    public struct Coverage: Codable, Equatable, Sendable {
        public let total: Int, dated: Int, unknown: Int, percent: Int, missingRuntime: Int, future: Int
    }
    public struct Bucket: Codable, Equatable, Identifiable, Sendable {
        public var id: Int { key }
        public let key: Int, label: String, description: String
        public var minutes: Int
        public var events: [WatchEvent]
    }
    public struct Busiest: Codable, Equatable, Sendable { public let date: String, minutes: Int }
    public struct Trend: Codable, Equatable, Sendable {
        public let period: Period
        public let minutes: Int, average: Double, difference: Int?, watches: Int, titles: Int
        public let start: String, end: String, days: Int, comparison: String, previousStart: String, previousEnd: String
        public let buckets: [Bucket], busiest: Busiest?
    }
    public struct Day: Codable, Equatable, Identifiable, Sendable {
        public var id: Int { key }
        public let key: Int, date: String, count: Int, minutes: Int, future: Bool
    }
    public struct Streaks: Codable, Equatable, Sendable {
        public let current: Int, longest: Int, heatmap: [Day], activeDays: Int, elapsedDays: Int
    }
    public struct Progress: Codable, Equatable, Identifiable, Sendable {
        public var id: String { title.id }
        public let title: MediaTitle, remaining: Int, remainingMinutes: Int?, catalogueKnown: Bool
        public let watched: Int, total: Int, percent: Double, daysSince: Int?, hasUndatedWatches: Bool
    }
    public struct Backlog: Codable, Equatable, Sendable {
        public let counts: [String: Int], total: Int, plannedMinutes: Int, unknownPlanned: Int
        public let inProgress: [Progress], stale: [Progress]
    }
    public struct Genre: Codable, Equatable, Identifiable, Sendable {
        public var id: String { genre }
        public let genre: String, count: Int, percent: Double, coverage: Double, share: Double
    }
    public struct Genres: Codable, Equatable, Sendable {
        public let total: Int, items: [Genre], otherCount: Int, otherShare: Double
    }
    public let coverage: Coverage, trend: Trend, streaks: Streaks, backlog: Backlog, genres: Genres
    public let years: [Int], currentYear: Int, selectedYear: Int

    public init(workspace: Workspace, period: Period = .month, year: Int? = nil, now: Date = .now, timeZone: TimeZone = .current) {
        let utc = DiaryDate.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let local = DiaryDate.calendar(timeZone: timeZone)
        func dayOf(_ date: Date) -> Date { utc.date(from: local.dateComponents([.year, .month, .day], from: date))! }
        func day(_ date: Date) -> String { DiaryDate.day(date, timeZone: utc.timeZone) }
        func add(_ days: Int, to date: Date) -> Date { date.addingTimeInterval(Double(days) * 86_400) }
        func first(_ year: Int, _ month: Int) -> Date { utc.date(from: DateComponents(year: year, month: month, day: 1))! }
        func runtime(_ title: MediaTitle) -> Int? { title.runtimeMinutes.flatMap { $0 > 0 ? $0 : nil } }
        func formatter(_ format: String) -> DateFormatter {
            let value = DateFormatter(); value.locale = Locale(identifier: "en_GB"); value.calendar = utc
            // ICU abbreviates September differently across the web and Apple runtimes.
            // Pin the web's en-GB short names; long month names remain localized en-GB.
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]
            value.shortMonthSymbols = months; value.shortStandaloneMonthSymbols = months
            value.timeZone = utc.timeZone; value.dateFormat = format; return value
        }
        let short = formatter("d MMM"), full = formatter("d MMM yyyy"), monthShort = formatter("MMM"), monthFull = formatter("MMMM yyyy")
        let today = dayOf(now), titles = workspace.activeTitles, events = workspace.activeEvents
        let titleMap = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        struct Dated { let event: WatchEvent, day: Date, minutes: Int? }
        let dated = events.compactMap { event -> Dated? in
            guard let instant = DiaryDate.parse(event.watchedAt), let title = titleMap[event.titleId] else { return nil }
            return Dated(event: event, day: dayOf(instant), minutes: runtime(title))
        }
        let usable = dated.filter { $0.day <= today }
        let datedIDs = Set(dated.map { $0.event.id }), futureIDs = Set(dated.filter { $0.day > today }.map { $0.event.id })
        let current = utc.component(.year, from: today)
        currentYear = current
        let selected = year.flatMap { $0 >= 1900 && $0 <= current ? $0 : nil } ?? current
        selectedYear = selected
        years = Set([current] + usable.map { utc.component(.year, from: $0.day) }).sorted(by: >)
        let month = utc.component(.month, from: today)
        var start = today, end = today
        switch period {
        case .today: break
        case .week: start = add(-((utc.component(.weekday, from: today) + 5) % 7), to: today)
        case .month: start = first(current, month)
        case .ninetyDays: start = add(-89, to: today)
        case .year: start = first(selected, 1); end = min(today, add(-1, to: first(selected + 1, 1)))
        case .all: start = usable.map(\.day).min().map { min($0, today) } ?? today
        }
        let days = max(1, Int((end.timeIntervalSince(start) / 86_400).rounded()) + 1)
        var previousStart = add(-days, to: start), previousEnd = add(-1, to: start)
        var comparison = "vs previous \(days) \(days == 1 ? "day" : "days")"
        if period == .week {
            previousStart = add(-7, to: start); previousEnd = add(-7, to: end); comparison = "vs previous week to date"
        } else if period == .month {
            previousStart = utc.date(byAdding: .month, value: -1, to: start)!
            let lastDay = utc.component(.day, from: add(-1, to: start))
            previousEnd = add(min(utc.component(.day, from: today), lastDay) - 1, to: previousStart)
            comparison = "vs previous month to date"
        } else if period == .year {
            previousStart = first(selected - 1, 1)
            let endMonth = utc.component(.month, from: end), monthStart = first(selected - 1, endMonth)
            let lastDay = utc.range(of: .day, in: .month, for: monthStart)!.count
            previousEnd = add(min(utc.component(.day, from: end), lastDay) - 1, to: monthStart)
            comparison = selected == current ? "vs previous year to date" : "vs previous year"
        }
        let inPeriod = usable.filter { $0.day >= start && $0.day <= end }
        var daily: [Date: (count: Int, minutes: Int)] = [:]
        for item in usable { let old = daily[item.day] ?? (0, 0); daily[item.day] = (old.count + 1, old.minutes + (item.minutes ?? 0)) }
        let span = days <= 31 ? 1 : Int(ceil(Double(days) / 30))
        let bucketCount = period == .year ? utc.component(.month, from: end) : Int(ceil(Double(days) / Double(span)))
        var buckets = (0..<bucketCount).map { index -> Bucket in
            if period == .year {
                let date = first(selected, index + 1)
                return Bucket(key: index, label: monthShort.string(from: date), description: monthFull.string(from: date), minutes: 0, events: [])
            }
            let a = add(index * span, to: start), b = min(end, add(span - 1, to: a))
            return Bucket(key: index, label: short.string(from: a), description: a == b ? full.string(from: a) : "\(full.string(from: a)) – \(full.string(from: b))", minutes: 0, events: [])
        }
        for item in inPeriod {
            let index = period == .year ? utc.component(.month, from: item.day) - 1 : Int(item.day.timeIntervalSince(start) / 86_400) / span
            buckets[index].minutes += item.minutes ?? 0; buckets[index].events.append(item.event)
        }
        let minutes = inPeriod.reduce(0) { $0 + ($1.minutes ?? 0) }
        let previousMinutes = usable.filter { $0.day >= previousStart && $0.day <= previousEnd }.reduce(0) { $0 + ($1.minutes ?? 0) }
        let busiest = daily.filter { $0.key >= start && $0.key <= end }.sorted {
            $0.value.minutes == $1.value.minutes ? $0.key > $1.key : $0.value.minutes > $1.value.minutes
        }.first
        trend = Trend(period: period, minutes: minutes, average: Double(minutes) / Double(days), difference: period == .all ? nil : minutes - previousMinutes, watches: inPeriod.count, titles: Set(inPeriod.map { $0.event.titleId }).count, start: day(start), end: day(end), days: days, comparison: comparison, previousStart: day(previousStart), previousEnd: day(previousEnd), buckets: buckets, busiest: busiest.flatMap { $0.value.minutes > 0 ? Busiest(date: short.string(from: $0.key), minutes: $0.value.minutes) : nil })
        coverage = Coverage(total: events.count, dated: dated.count, unknown: events.count - dated.count, percent: events.isEmpty ? 0 : Int((Double(dated.count) / Double(events.count) * 100).rounded()), missingRuntime: dated.filter { $0.minutes == nil }.count, future: dated.count - usable.count)
        var longest = 0, run = 0, previous: Date?
        for date in daily.keys.sorted() { run = previous.map { date.timeIntervalSince($0) == 86_400 } == true ? run + 1 : 1; longest = max(longest, run); previous = date }
        var currentStreak = 0, cursor = daily[today] == nil ? add(-1, to: today) : today
        while daily[cursor] != nil { currentStreak += 1; cursor = add(-1, to: cursor) }
        let gridStart = add(-((utc.component(.weekday, from: today) + 5) % 7) - 77, to: today)
        let heatmap = (0..<84).map { key -> Day in
            let date = add(key, to: gridStart)
            return Day(key: key, date: day(date), count: daily[date]?.count ?? 0, minutes: daily[date]?.minutes ?? 0, future: date > today)
        }
        streaks = Streaks(current: currentStreak, longest: longest, heatmap: heatmap, activeDays: heatmap.filter { !$0.future && $0.count > 0 }.count, elapsedDays: heatmap.filter { !$0.future }.count)
        var counts = ["planned": 0, "watching": 0, "completed": 0, "dropped": 0]
        for title in titles { counts[title.status, default: 0] += 1 }
        let eventsByTitle = Dictionary(grouping: events.filter { !futureIDs.contains($0.id) }, by: \.titleId)
        let episodesByTitle = Dictionary(grouping: workspace.episodes.filter { $0.season > 0 }, by: \.titleId)
        var lastByTitle: [String: Date] = [:]
        for item in usable { lastByTitle[item.event.titleId] = max(lastByTitle[item.event.titleId] ?? item.day, item.day) }
        let undatedTitles = Set(events.filter { !datedIDs.contains($0.id) }.map(\.titleId)), todayISO = day(today)
        let progress = titles.map { title -> Progress in
            let regular = episodesByTitle[title.id] ?? [], titleEvents = eventsByTitle[title.id] ?? []
            let watchedIDs = Set(titleEvents.compactMap(\.episodeId))
            let eligible = regular.filter { episode in episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= todayISO } ?? false }
            let watched = eligible.filter { watchedIDs.contains($0.id) }.count
            let seasons = (title.seasons ?? []).filter { $0.number > 0 }
            let complete = seasons.isEmpty ? title.tmdbId == nil && !regular.isEmpty : seasons.allSatisfy { season in
                season.expectedEpisodes.map { expected in regular.filter { $0.season == season.number }.count == expected } ?? false
            }
            let remaining = title.isSeries ? eligible.count - watched : titleEvents.isEmpty ? 1 : 0
            let known = !title.isSeries || (complete && regular.allSatisfy { $0.airedOn.map(SeasonAdjustment.validDay) ?? false })
            let remainingMinutes = known ? runtime(title).map { remaining * $0 } : nil
            return Progress(title: title, remaining: remaining, remainingMinutes: remainingMinutes, catalogueKnown: known, watched: watched, total: eligible.count, percent: title.isSeries ? (eligible.isEmpty ? 0 : Double(watched) / Double(eligible.count) * 100) : remaining == 0 ? 100 : 0, daysSince: lastByTitle[title.id].map { Int(today.timeIntervalSince($0) / 86_400) }, hasUndatedWatches: undatedTitles.contains(title.id))
        }
        let planned = progress.filter { $0.title.status == "planned" }
        let inProgress = progress.filter { $0.title.status == "watching" && ($0.remaining > 0 || $0.remainingMinutes == nil) }.sorted {
            let a = $0.remainingMinutes ?? Int.max, b = $1.remainingMinutes ?? Int.max
            return a == b ? Self.nameBefore($0.title.name, $1.title.name) : a < b
        }
        let stale = inProgress.filter { !$0.hasUndatedWatches && ($0.daysSince ?? -1) >= 30 }.sorted { ($0.daysSince ?? 0) > ($1.daysSince ?? 0) }
        backlog = Backlog(counts: counts, total: titles.count, plannedMinutes: planned.reduce(0) { $0 + ($1.remainingMinutes ?? 0) }, unknownPlanned: planned.filter { $0.remainingMinutes == nil }.count, inProgress: inProgress, stale: stale)
        let watchedIDs = Set(events.map(\.titleId)), watchedTitles = titles.filter { watchedIDs.contains($0.id) }
        func names(_ title: MediaTitle) -> Set<String> {
            let values = Set(title.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            return values.isEmpty ? ["Uncategorized"] : values
        }
        var genreCounts: [String: Int] = [:]
        for title in watchedTitles { for name in names(title) { genreCounts[name, default: 0] += 1 } }
        let contributions = genreCounts.values.reduce(0, +), total = watchedTitles.count
        var items: [Genre] = []
        for (name, count) in genreCounts {
            let share: Double = total == 0 ? 0 : Double(count) / Double(total) * 100
            let percent: Double = contributions == 0 ? 0 : Double(count) / Double(contributions) * 100
            items.append(Genre(genre: name, count: count, percent: percent, coverage: share, share: share))
        }
        items.sort { left, right in left.count == right.count ? Self.nameBefore(left.genre, right.genre) : left.count > right.count }
        let otherNames: Set<String> = Set(items.dropFirst(5).map { $0.genre })
        let otherCount = watchedTitles.filter { !names($0).isDisjoint(with: otherNames) }.count
        genres = Genres(total: total, items: items, otherCount: otherCount, otherShare: total == 0 ? 0 : Double(otherCount) / Double(total) * 100)
    }
    private static func nameBefore(_ left: String, _ right: String) -> Bool {
        left.compare(right, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")) == .orderedAscending
    }
}
