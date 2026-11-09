import Foundation

/// Everything the Statistics tabs show beyond `StatsOverview`: totals by kind, this month and
/// year, watch time per year, when you watch, hall of fame, marathons, most played, ratings,
/// decades and library facts. All time; minutes are estimated from title runtimes.
public struct StatsInsights: Equatable, Sendable {
    public struct TitleCount: Equatable, Sendable, Identifiable {
        public let title: MediaTitle
        public let count: Int
        public let minutes: Int
        public var id: String { title.id }
    }
    public struct Marathon: Equatable, Sendable, Identifiable {
        public let title: MediaTitle
        public let day: Date
        public let episodes: Int
        public var id: String { title.id + "@" + String(day.timeIntervalSince1970) }
    }
    public struct DayMinutes: Equatable, Sendable { public let day: Date; public let minutes: Int }
    public struct YearMinutes: Equatable, Sendable, Identifiable {
        public let year: Int
        public let minutes: Int
        public var id: Int { year }
    }
    public struct Moment: Equatable, Sendable { public let title: MediaTitle; public let date: Date }
    public struct Decade: Equatable, Sendable, Identifiable {
        public let decade: Int
        public let count: Int
        public var id: Int { decade }
    }

    public let episodes: Int, shows: Int, movies: Int
    public let showMinutes: Int, movieMinutes: Int
    public var totalMinutes: Int { showMinutes + movieMinutes }
    public let monthMinutes: Int, monthPlays: Int, yearMinutes: Int, yearPlays: Int
    public let perYear: [YearMinutes]
    /// Plays by local hour (0–23) and weekday (Monday first).
    public let hours: [Int], weekdays: [Int]
    public let biggestDay: DayMinutes?
    public let first: Moment?, latest: Moment?
    public let marathons: [Marathon]
    public let mostPlayedShows: [TitleCount], mostPlayedMovies: [TitleCount]
    public let topRatedShows: [MediaTitle], topRatedMovies: [MediaTitle]
    /// Your ratings 1…10 (index 0 is 1).
    public let ratingCounts: [Int]
    public let movieAverage: Double?, showAverage: Double?
    public let decades: [Decade]
    public let averageRuntime: Int?
    public let longestMovie: MediaTitle?
    public let rewatches: Int

    public var ratedCount: Int { ratingCounts.reduce(0, +) }
    /// The hour with the most plays, for "Peaks around 4 PM".
    public var peakHour: Int? { hours.max().flatMap { $0 > 0 ? hours.firstIndex(of: $0) : nil } }
    /// Monday = 0.
    public var peakWeekday: Int? { weekdays.max().flatMap { $0 > 0 ? weekdays.firstIndex(of: $0) : nil } }

    public init(workspace: Workspace, now: Date = .now, timeZone: TimeZone = .current) {
        let calendar = DiaryDate.calendar(timeZone: timeZone)
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let events = workspace.activeEvents.filter { titles[$0.titleId] != nil }
        func runtime(_ title: MediaTitle) -> Int { max(0, title.runtimeMinutes ?? 0) }

        var episodes = 0, showMinutes = 0, movieMinutes = 0
        var showIDs = Set<String>(), movieIDs = Set<String>()
        var plays: [String: (count: Int, minutes: Int)] = [:]
        var keys = Set<String>()
        var rewatches = 0
        for event in events {
            guard let title = titles[event.titleId] else { continue }
            if title.isSeries { showIDs.insert(title.id); showMinutes += runtime(title); if event.episodeId != nil { episodes += 1 } }
            else { movieIDs.insert(title.id); movieMinutes += runtime(title) }
            let entry = plays[title.id] ?? (0, 0)
            plays[title.id] = (entry.count + 1, entry.minutes + runtime(title))
            if !keys.insert(title.id + "|" + (event.episodeId ?? "movie")).inserted { rewatches += 1 }
        }
        self.episodes = episodes; self.shows = showIDs.count; self.movies = movieIDs.count
        self.showMinutes = showMinutes; self.movieMinutes = movieMinutes; self.rewatches = rewatches

        struct Dated { let title: MediaTitle; let date: Date; let event: WatchEvent }
        let dated = events.compactMap { event -> Dated? in
            guard let date = DiaryDate.parse(event.watchedAt), date <= now, let title = titles[event.titleId] else { return nil }
            return Dated(title: title, date: date, event: event)
        }
        let thisMonth = calendar.dateComponents([.year, .month], from: now)
        var monthMinutes = 0, monthPlays = 0, yearMinutes = 0, yearPlays = 0
        var years: [Int: Int] = [:], hours = Array(repeating: 0, count: 24), weekdays = Array(repeating: 0, count: 7)
        var days: [Date: Int] = [:], marathonCounts: [String: Int] = [:]
        for item in dated {
            let parts = calendar.dateComponents([.year, .month, .hour, .weekday], from: item.date)
            let minutes = runtime(item.title)
            if parts.year == thisMonth.year { yearMinutes += minutes; yearPlays += 1 }
            if parts.year == thisMonth.year && parts.month == thisMonth.month { monthMinutes += minutes; monthPlays += 1 }
            if let year = parts.year { years[year, default: 0] += minutes }
            if let hour = parts.hour { hours[hour] += 1 }
            if let weekday = parts.weekday { weekdays[(weekday + 5) % 7] += 1 }
            let day = calendar.startOfDay(for: item.date)
            days[day, default: 0] += minutes
            if item.title.isSeries && item.event.episodeId != nil { marathonCounts[item.title.id + "|" + String(day.timeIntervalSince1970), default: 0] += 1 }
        }
        self.monthMinutes = monthMinutes; self.monthPlays = monthPlays; self.yearMinutes = yearMinutes; self.yearPlays = yearPlays
        if let low = years.keys.min(), let high = years.keys.max() {
            perYear = (low...high).map { YearMinutes(year: $0, minutes: years[$0] ?? 0) }
        } else { perYear = [] }
        self.hours = hours; self.weekdays = weekdays
        biggestDay = days.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }.flatMap { $0.value > 0 ? DayMinutes(day: $0.key, minutes: $0.value) : nil }
        let ordered = dated.sorted { $0.date < $1.date }
        first = ordered.first.map { Moment(title: $0.title, date: $0.date) }
        latest = ordered.last.map { Moment(title: $0.title, date: $0.date) }
        marathons = marathonCounts.compactMap { key, count -> Marathon? in
            let parts = key.split(separator: "|")
            guard count >= 2, parts.count == 2, let title = titles[String(parts[0])], let stamp = Double(parts[1]) else { return nil }
            return Marathon(title: title, day: Date(timeIntervalSince1970: stamp), episodes: count)
        }.sorted { $0.episodes != $1.episodes ? $0.episodes > $1.episodes : $0.day < $1.day }.prefix(5).map { $0 }

        let counted = plays.compactMap { id, value in titles[id].map { TitleCount(title: $0, count: value.count, minutes: value.minutes) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title.name < $1.title.name }
        mostPlayedShows = Array(counted.filter { $0.title.isSeries }.prefix(10))
        mostPlayedMovies = Array(counted.filter { !$0.title.isSeries }.prefix(10))
        let rated = workspace.activeTitles.filter { ($0.score ?? 0) > 0 }
        let byScore = rated.sorted { ($0.score ?? 0) != ($1.score ?? 0) ? ($0.score ?? 0) > ($1.score ?? 0) : $0.name < $1.name }
        topRatedShows = Array(byScore.filter(\.isSeries).prefix(10))
        topRatedMovies = Array(byScore.filter { !$0.isSeries }.prefix(10))
        var counts = Array(repeating: 0, count: 10)
        for title in rated { counts[min(9, max(0, Int((title.score ?? 1).rounded()) - 1))] += 1 }
        ratingCounts = counts
        func average(_ values: [MediaTitle]) -> Double? { values.isEmpty ? nil : values.reduce(0) { $0 + ($1.score ?? 0) } / Double(values.count) }
        movieAverage = average(rated.filter { !$0.isSeries }); showAverage = average(rated.filter(\.isSeries))
        let watchedTitles = (showIDs.union(movieIDs)).compactMap { titles[$0] }
        decades = Dictionary(grouping: watchedTitles.compactMap(\.year), by: { $0 / 10 * 10 })
            .map { Decade(decade: $0.key, count: $0.value.count) }.sorted { $0.decade < $1.decade }
        let runtimes = watchedTitles.compactMap { $0.runtimeMinutes.flatMap { $0 > 0 ? $0 : nil } }
        averageRuntime = runtimes.isEmpty ? nil : Int((Double(runtimes.reduce(0, +)) / Double(runtimes.count)).rounded())
        longestMovie = watchedTitles.filter { !$0.isSeries && ($0.runtimeMinutes ?? 0) > 0 }.max { ($0.runtimeMinutes ?? 0) < ($1.runtimeMinutes ?? 0) }
    }
}
