import Foundation

/// What the Stats screen highlights for the chosen period, on top of `StatsOverview`
/// (which stays identical to the web's calculation):
/// - the most-watched titles, whose backdrop becomes the Journey card's art;
/// - the busiest day and the daily average without days that hold more than 24 hours
///   of watching. Such days come from bulk imports that gave many plays one date;
/// - fun facts: biggest binge, night-owl share, favourite weekday, rewatches, new starts.
public struct StatsHighlights: Equatable, Sendable {
    public struct Day: Equatable, Sendable { public let date: String, minutes: Int }
    public struct Binge: Equatable, Sendable { public let titleID: String, episodes: Int, date: String }
    public struct Weekday: Equatable, Sendable { public let name: String, share: Int }
    /// Title IDs by minutes watched in the period, then by plays.
    public let topTitleIDs: [String]
    public let topMinutes: Int, topPlays: Int
    public let busiest: Day?
    public let averageMinutes: Double
    /// Days left out of the busiest day and the average.
    public let bulkDays: Int
    /// Most episodes of one show on one day (two or more).
    public let binge: Binge?
    /// Share of timed watches between 22:00 and 03:59, when at least five have a time.
    public let nightOwl: Int?
    public let weekday: Weekday?
    /// Plays of an episode or movie already watched before.
    public let rewatches: Int
    /// Titles whose first watch ever falls in the period.
    public let newStarts: Int
    public let episodes: Int, movies: Int
    public let minutes: Int

    public static let dayLimit = 24 * 60

    public init(workspace: Workspace, trend: StatsOverview.Trend, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        struct Play { let event: WatchEvent; let instant: Date; let day: String; let minutes: Int }
        let all = workspace.activeEvents.compactMap { event -> Play? in
            guard let instant = DiaryDate.parse(event.watchedAt), let title = titles[event.titleId] else { return nil }
            return Play(event: event, instant: instant, day: DiaryDate.day(instant, timeZone: timeZone), minutes: max(0, title.runtimeMinutes ?? 0))
        }.sorted { ($0.instant, $0.event.id) < ($1.instant, $1.event.id) }
        let inPeriod = all.filter { $0.day >= trend.start && $0.day <= trend.end }

        var minutesByTitle: [String: Int] = [:], playsByTitle: [String: Int] = [:], minutesByDay: [String: Int] = [:]
        for play in inPeriod {
            minutesByTitle[play.event.titleId, default: 0] += play.minutes; playsByTitle[play.event.titleId, default: 0] += 1
            minutesByDay[play.day, default: 0] += play.minutes
        }
        topTitleIDs = playsByTitle.keys.sorted { a, b in
            let left = (minutesByTitle[a] ?? 0, playsByTitle[a] ?? 0), right = (minutesByTitle[b] ?? 0, playsByTitle[b] ?? 0)
            return left == right ? a < b : left > right
        }
        topMinutes = topTitleIDs.first.map { minutesByTitle[$0] ?? 0 } ?? 0
        topPlays = topTitleIDs.first.map { playsByTitle[$0] ?? 0 } ?? 0
        let plausible = minutesByDay.filter { $0.value <= Self.dayLimit }
        bulkDays = minutesByDay.count - plausible.count
        busiest = plausible.filter { $0.value > 0 }.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }
            .map { Day(date: $0.key, minutes: $0.value) }
        averageMinutes = Double(plausible.values.reduce(0, +)) / Double(max(1, trend.days))
        minutes = inPeriod.reduce(0) { $0 + $1.minutes }
        episodes = inPeriod.filter { $0.event.episodeId != nil }.count
        movies = inPeriod.count - episodes

        // Biggest binge: episodes of one title on one plausible day.
        var bingeCounts: [String: Int] = [:]
        for play in inPeriod where play.event.episodeId != nil && plausible[play.day] != nil { bingeCounts[play.event.titleId + "|" + play.day, default: 0] += 1 }
        binge = bingeCounts.filter { $0.value >= 2 }.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }.map { key, count in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return Binge(titleID: parts[0], episodes: count, date: parts[1])
        }

        // Night owl: imports often carry midnight with no real time, so 00:00:00 is not counted.
        let timed = inPeriod.filter { play in
            let parts = calendar.dateComponents([.hour, .minute, .second], from: play.instant)
            return !(parts.hour == 0 && parts.minute == 0 && parts.second == 0)
        }
        let late = timed.filter { play in let hour = calendar.component(.hour, from: play.instant); return hour >= 22 || hour < 4 }.count
        nightOwl = timed.count >= 5 ? Int((Double(late) / Double(timed.count) * 100).rounded()) : nil

        var byWeekday: [Int: Int] = [:]
        for play in inPeriod where plausible[play.day] != nil { byWeekday[calendar.component(.weekday, from: play.instant), default: 0] += 1 }
        let counted = byWeekday.values.reduce(0, +)
        let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
        weekday = counted >= 5 ? byWeekday.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }.map { day, count in
            Weekday(name: names[day - 1], share: Int((Double(count) / Double(counted) * 100).rounded()))
        } : nil

        // Rewatches and new starts look at every earlier play, not only this period's.
        var seen = Set<String>(), started = Set<String>(), rewatched = 0, firsts = 0
        for play in all {
            let key = play.event.titleId + "|" + (play.event.episodeId ?? "movie")
            let inside = play.day >= trend.start && play.day <= trend.end
            if seen.contains(key) { if inside { rewatched += 1 } } else { seen.insert(key) }
            if !started.contains(play.event.titleId) { started.insert(play.event.titleId); if inside { firsts += 1 } }
        }
        rewatches = rewatched; newStarts = firsts
    }

    /// "27 May" from a "2026-05-27" day.
    public static func shortDate(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"]
        return "\(parts[2]) \(months[parts[1] - 1])"
    }
}
