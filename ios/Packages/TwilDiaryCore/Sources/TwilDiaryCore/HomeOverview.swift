import Foundation

public struct HomeOverview: Sendable {
    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let minutes: Int
        public let count: Int
        public let future: Bool
    }
    public struct Upcoming: Identifiable, Sendable {
        public var id: String { title.id }
        public let title: MediaTitle
        public let episode: Episode
        public let date: Date
        public let daysAway: Int
    }
    public let days: [Day]
    public let minutes: Int
    public let watches: Int
    public let streak: Int
    public let unknownDates: Int
    public let missingRuntime: Int
    public let planned: [MediaTitle]
    public let upcoming: [Upcoming]

    public init(workspace: Workspace, now: Date, calendar: Calendar = DiaryDate.calendar()) {
        var calendar = calendar
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: now)
        let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let active = distinctRows(workspace.activeEvents)
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        unknownDates = active.filter { DiaryDate.parse($0.watchedAt) == nil }.count
        missingRuntime = active.filter { DiaryDate.parse($0.watchedAt) != nil && (titles[$0.titleId]?.runtimeMinutes ?? 0) <= 0 }.count
        var counts: [Date: Int] = [:], runtimes: [Date: Int] = [:]
        for event in active {
            guard let date = DiaryDate.parse(event.watchedAt), calendar.startOfDay(for: date) <= today else { continue }
            let day = calendar.startOfDay(for: date)
            counts[day, default: 0] += 1
            runtimes[day, default: 0] += max(0, titles[event.titleId]?.runtimeMinutes ?? 0)
        }
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return Day(date: date, minutes: runtimes[date] ?? 0, count: counts[date] ?? 0, future: date > today)
        }
        minutes = days.reduce(0) { $0 + $1.minutes }
        watches = days.reduce(0) { $0 + $1.count }
        var cursor = counts[today] == nil ? calendar.date(byAdding: .day, value: -1, to: today)! : today
        var current = 0
        while counts[cursor] != nil { current += 1; cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        streak = current
        planned = DiscoveryTools.unwatched(workspace)
        let watchedEpisodes = Set(active.compactMap(\.episodeId))
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        var seen = Set<String>()
        upcoming = workspace.episodes.compactMap { episode -> Upcoming? in
            guard let title = titles[episode.titleId], title.isSeries, title.status != "dropped", episode.season > 0,
                  episode.skipped != true, !watchedEpisodes.contains(episode.id), let raw = episode.airedOn,
                  let date = formatter.date(from: raw), formatter.string(from: date) == raw,
                  let distance = calendar.dateComponents([.day], from: today, to: date).day, (0...30).contains(distance) else { return nil }
            return Upcoming(title: title, episode: episode, date: date, daysAway: distance)
        }.sorted {
            if $0.daysAway != $1.daysAway { return $0.daysAway < $1.daysAway }
            if $0.episode.season != $1.episode.season { return $0.episode.season < $1.episode.season }
            if $0.episode.number != $1.episode.number { return $0.episode.number < $1.episode.number }
            return $0.title.name.localizedCompare($1.title.name) == .orderedAscending
        }.filter { seen.insert($0.title.id).inserted }
    }
}

public struct UpcomingSchedule: Sendable {
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case upcoming = "Upcoming"
        case catchup = "Catch-up"
        public var id: String { rawValue }
    }
    public enum CategoryFilter: String, CaseIterable, Sendable, Identifiable {
        case all = "All"
        case anime = "Anime"
        case show = "Shows"
        public var id: String { rawValue }
    }
    public struct Item: Identifiable, Sendable {
        public var id: String { "\(title.id)::\(episode.id)" }
        public let title: MediaTitle
        public let episode: Episode
        public let date: Date
        public let daysAway: Int
        public var isAnime: Bool { title.category == "anime" }
    }
    public struct DayBucket: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let daysAway: Int
        public let items: [Item]
        public let animeCount: Int
        public let showCount: Int
    }
    public struct StripCell: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let daysAway: Int
        public let total: Int
        public let animeCount: Int
        public let showCount: Int
    }

    public let items: [Item]
    public let days: [DayBucket]
    public let strip: [StripCell]
    public let totalCount: Int
    public let animeCount: Int
    public let showCount: Int
    public let thisWeekCount: Int

    public init(
        workspace: Workspace,
        now: Date,
        category: CategoryFilter = .all,
        horizonDays: Int = 30,
        dedupeByTitle: Bool = false,
        mode: Mode = .upcoming,
        calendar: Calendar = DiaryDate.calendar()
    ) {
        let today = calendar.startOfDay(for: now)
        let active = distinctRows(workspace.activeEvents)
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let watchedEpisodes = Set(active.compactMap(\.episodeId))
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        let maxHorizon = max(1, min(365, horizonDays))

        let allSorted = workspace.episodes.compactMap { episode -> Item? in
            guard let title = titles[episode.titleId], title.isSeries, title.status != "dropped", episode.season > 0,
                  episode.skipped != true, !watchedEpisodes.contains(episode.id), let raw = episode.airedOn,
                  let date = formatter.date(from: raw), formatter.string(from: date) == raw,
                  let distance = calendar.dateComponents([.day], from: today, to: date).day else { return nil }
            if mode == .catchup {
                guard (-maxHorizon..<0).contains(distance) else { return nil }
            } else {
                guard (0...maxHorizon).contains(distance) else { return nil }
            }
            return Item(title: title, episode: episode, date: date, daysAway: distance)
        }.sorted {
            if $0.daysAway != $1.daysAway { return mode == .catchup ? $0.daysAway > $1.daysAway : $0.daysAway < $1.daysAway }
            if $0.episode.season != $1.episode.season { return $0.episode.season < $1.episode.season }
            if $0.episode.number != $1.episode.number { return $0.episode.number < $1.episode.number }
            return $0.title.name.localizedCompare($1.title.name) == .orderedAscending
        }

        var seen = Set<String>()
        let deduped = dedupeByTitle ? allSorted.filter { seen.insert($0.title.id).inserted } : allSorted
        self.animeCount = deduped.filter(\.isAnime).count
        self.showCount = deduped.filter { !$0.isAnime }.count

        let filtered: [Item]
        switch category {
        case .all: filtered = deduped
        case .anime: filtered = deduped.filter(\.isAnime)
        case .show: filtered = deduped.filter { !$0.isAnime }
        }
        self.items = filtered
        self.totalCount = filtered.count
        self.thisWeekCount = filtered.filter {
            mode == .catchup ? (-7..<0).contains($0.daysAway) : (0..<7).contains($0.daysAway)
        }.count

        var grouped: [Date: [Item]] = [:]
        for item in filtered {
            grouped[calendar.startOfDay(for: item.date), default: []].append(item)
        }
        let sortedDays = mode == .catchup ? grouped.keys.sorted(by: >) : grouped.keys.sorted(by: <)
        self.days = sortedDays.map { day in
            let list = grouped[day] ?? []
            let distance = list.first?.daysAway ?? (calendar.dateComponents([.day], from: today, to: day).day ?? 0)
            return DayBucket(
                date: day,
                daysAway: distance,
                items: list,
                animeCount: list.filter(\.isAnime).count,
                showCount: list.filter { !$0.isAnime }.count
            )
        }

        let byDay = Dictionary(uniqueKeysWithValues: self.days.map { ($0.date, $0) })
        self.strip = (0..<14).compactMap { index -> StripCell? in
            let offset = mode == .catchup ? -(index + 1) : index
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let bucket = byDay[day]
            return StripCell(
                date: day,
                daysAway: offset,
                total: bucket?.items.count ?? 0,
                animeCount: bucket?.animeCount ?? 0,
                showCount: bucket?.showCount ?? 0
            )
        }
    }

    public func icsString(hideSpoilers: Bool = true, calendar: Calendar = DiaryDate.calendar()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//TwilDiary//Airing Calendar//EN",
            "CALSCALE:GREGORIAN",
            "X-WR-CALNAME:TwilDiary Airing Schedule"
        ]
        for item in items {
            let start = formatter.string(from: item.date)
            let end = formatter.string(from: calendar.date(byAdding: .day, value: 1, to: item.date) ?? item.date)
            let code = String(format: "S%02dE%02d", item.episode.season, item.episode.number)
            let summary = "\(item.title.name) · \(code)"
            let epTitle = (!hideSpoilers && !item.episode.name.isEmpty) ? item.episode.name : "Episode \(item.episode.number)"
            lines.append(contentsOf: [
                "BEGIN:VEVENT",
                "UID:twildiary-\(item.title.id)-\(item.episode.id)@twildiary.local",
                "DTSTART;VALUE=DATE:\(start)",
                "DTEND;VALUE=DATE:\(end)",
                "SUMMARY:\(summary)",
                "DESCRIPTION:\(item.title.categoryName) — \(epTitle)",
                "END:VEVENT"
            ])
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
