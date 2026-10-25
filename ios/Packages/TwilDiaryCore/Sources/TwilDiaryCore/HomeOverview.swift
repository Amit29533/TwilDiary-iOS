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
