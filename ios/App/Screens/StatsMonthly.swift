import SwiftUI
import Charts
import TwilDiaryCore

// MARK: Monthly statistics (owner's design, Profile and Statistics board 3)

/// One month of your diary: watch time split into TV and movies, each day's watching, the last
/// twelve months, the month's biggest day, best streak, first and latest watch, and most played.
struct StatsMonth {
    struct Day: Identifiable {
        let date: Date
        let minutes: Int
        let shows: Bool
        let movies: Bool
        var id: Date { date }
        var watched: Bool { shows || movies }
    }
    struct Played: Identifiable {
        let title: MediaTitle
        let count: Int
        let minutes: Int
        var id: String { title.id }
    }
    struct Moment { let title: MediaTitle; let date: Date }
    let start: Date
    let days: [Day]
    let tvMinutes: Int, movieMinutes: Int
    let episodes: Int, shows: Int, movies: Int
    let months: [(start: Date, minutes: Int)]
    let biggest: Day?
    let bestStreak: Int
    let first: Moment?, latest: Moment?
    let mostPlayedShows: [Played], mostPlayedMovies: [Played]
    /// Days so far this month (every day for a past month).
    let elapsed: Int

    /// The whole year (Statistics → Yearly) rather than one month.
    let wholeYear: Bool
    init(workspace: Workspace, month: Date, now: Date, wholeYear: Bool = false) {
        let calendar = DiaryDate.calendar()
        let begin = calendar.date(from: calendar.dateComponents(wholeYear ? [.year] : [.year, .month], from: month)) ?? month
        start = begin
        self.wholeYear = wholeYear
        let end = calendar.date(byAdding: wholeYear ? .year : .month, value: 1, to: begin) ?? begin
        let titles = Dictionary(workspace.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        struct Dated { let title: MediaTitle; let date: Date; let episode: Bool }
        let all = workspace.activeEvents.compactMap { event -> Dated? in
            guard let title = titles[event.titleId], let date = DiaryDate.parse(event.watchedAt) else { return nil }
            return Dated(title: title, date: date, episode: event.episodeId != nil)
        }
        let minutes: (Dated) -> Int = { max(0, $0.title.runtimeMinutes ?? 0) }
        let inMonth = all.filter { $0.date >= begin && $0.date < end }.sorted { $0.date < $1.date }
        var tv = 0, film = 0, episodes = 0
        var showIDs = Set<String>(), movieIDs = Set<String>()
        var byDay: [Date: (minutes: Int, shows: Bool, movies: Bool)] = [:]
        var plays: [String: (count: Int, minutes: Int)] = [:]
        for item in inMonth {
            let day = calendar.startOfDay(for: item.date)
            var entry = byDay[day] ?? (0, false, false)
            entry.minutes += minutes(item)
            if item.title.isSeries { tv += minutes(item); episodes += item.episode ? 1 : 0; showIDs.insert(item.title.id); entry.shows = true }
            else { film += minutes(item); movieIDs.insert(item.title.id); entry.movies = true }
            byDay[day] = entry
            let played = plays[item.title.id] ?? (0, 0)
            plays[item.title.id] = (played.count + 1, played.minutes + minutes(item))
        }
        tvMinutes = tv; movieMinutes = film; self.episodes = episodes; shows = showIDs.count; movies = movieIDs.count
        let count = calendar.dateComponents([.day], from: begin, to: end).day ?? 30
        let monthDays: [Day] = (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: begin) else { return nil }
            let entry = byDay[date]
            return Day(date: date, minutes: entry?.minutes ?? 0, shows: entry?.shows ?? false, movies: entry?.movies ?? false)
        }
        days = monthDays
        let today = calendar.startOfDay(for: now)
        elapsed = end <= today ? count : max(0, (calendar.dateComponents([.day], from: begin, to: today).day ?? 0) + 1)
        biggest = monthDays.filter { $0.minutes > 0 }.max { $0.minutes < $1.minutes }
        var best = 0, run = 0
        for day in monthDays { run = day.watched ? run + 1 : 0; best = max(best, run) }
        bestStreak = best
        first = inMonth.first.map { Moment(title: $0.title, date: $0.date) }
        latest = inMonth.last.map { Moment(title: $0.title, date: $0.date) }
        let played = plays.compactMap { id, value in titles[id].map { Played(title: $0, count: value.count, minutes: value.minutes) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.minutes > $1.minutes }
        mostPlayedShows = played.filter { $0.title.isSeries }
        mostPlayedMovies = played.filter { !$0.title.isSeries }
        // The twelve months ending with this one; for a year, its own January to December.
        let firstMonth = wholeYear ? begin : (calendar.date(byAdding: .month, value: -11, to: begin) ?? begin)
        months = (0..<12).compactMap { step in
            // Months still to come aren't plotted as zero.
            guard let monthStart = calendar.date(byAdding: .month, value: step, to: firstMonth), monthStart <= now,
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            return (monthStart, all.filter { $0.date >= monthStart && $0.date < monthEnd }.reduce(0) { $0 + minutes($1) })
        }
    }
    var totalMinutes: Int { tvMinutes + movieMinutes }
    var watchedDays: Int { days.filter(\.watched).count }
}

/// "‹ November 2026 ›": the month shown, between the earliest month with a watch and this month.
struct StatsMonthNavigator: View {
    @Binding var month: Date
    let earliest: Date
    let now: Date
    /// "‹ 2026 ›": steps a year at a time.
    var byYear = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        let calendar = DiaryDate.calendar()
        let parts: Set<Calendar.Component> = byYear ? [.year] : [.year, .month]
        let unit: Calendar.Component = byYear ? .year : .month
        let shown = calendar.date(from: calendar.dateComponents(parts, from: month)) ?? month
        let current = calendar.date(from: calendar.dateComponents(parts, from: now)) ?? now
        let first = calendar.date(from: calendar.dateComponents(parts, from: earliest)) ?? earliest
        HStack {
            step("chevron.left", enabled: shown > first) { month = calendar.date(byAdding: unit, value: -1, to: month) ?? month }
                .accessibilityLabel(byYear ? "Previous year" : "Previous month")
            Spacer()
            Text(byYear ? String(calendar.component(.year, from: month)) : month.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 19, weight: .bold)).foregroundStyle(theme.accent).contentTransition(.numericText())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            step("chevron.right", enabled: shown < current) { month = calendar.date(byAdding: unit, value: 1, to: month) ?? month }
                .accessibilityLabel(byYear ? "Next year" : "Next month")
        }
    }
    private func step(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(enabled ? HomeStyle.primary : HomeStyle.secondary.opacity(0.5))
                .frame(width: 44, height: 44).background(HomeStyle.round, in: Circle())
                .overlay(Circle().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
        }.buttonStyle(.plain).disabled(!enabled)
    }
}

/// THIS MONTH: the month's watch time, then TV time and movie time (each opens its part of the library).
struct StatsMonthCard: View {
    let month: StatsMonth
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) { DiaryIcon(name: "sparkles", size: 14); Text(month.wholeYear ? "THIS YEAR" : "THIS MONTH").font(.system(size: 13, weight: .semibold)).tracking(2) }.foregroundStyle(theme.accent.opacity(0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text(longDuration(month.totalMinutes)).font(.system(size: 52, weight: .heavy)).tracking(-1.5).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                Text("of watch time in " + (month.wholeYear ? String(DiaryDate.calendar().component(.year, from: month.start)) : month.start.formatted(.dateTime.month(.wide)))).font(.system(size: 16)).foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 10) {
                Button { router.library("all") } label: {
                    tile("TV time", longDuration(month.tvMinutes), month.episodes == 0 ? "no episodes yet" : month.episodes.counted("episode", "episodes") + " · " + month.shows.counted("show", "shows"))
                }.buttonStyle(.plain)
                Button { router.library("all") } label: {
                    tile("Movie time", longDuration(month.movieMinutes), month.movies == 0 ? "no movies yet" : month.movies.counted("movie", "movies"))
                }.buttonStyle(.plain)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color(webHex: "#2a1f45")
                    RadialGradient(colors: [theme.accent.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 320)
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.14)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("stats-month")
    }
    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
            Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14))).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// Over time: watch time per month for the last twelve; tap a month to show it.
struct StatsMonthOverTimeCard: View {
    let month: StatsMonth
    @Binding var selected: Date
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        StatsCard(title: "Over time", subtitle: month.wholeYear ? "Watch time per month · tap one to open it" : "Watch time per month") {
            let points = Array(month.months.enumerated())
            let peak = month.months.max { $0.minutes < $1.minutes }
            Chart(points, id: \.offset) { index, item in
                AreaMark(x: .value("Month", index), y: .value("Minutes", item.minutes)).interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Month", index), y: .value("Minutes", item.minutes)).interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5)).foregroundStyle(theme.accent)
                if item.minutes > 0, item.start == peak?.start || index == points.count - 1 {
                    PointMark(x: .value("Month", index), y: .value("Minutes", item.minutes)).symbolSize(60).foregroundStyle(theme.accent)
                        .annotation(position: .top) { Text(longDuration(item.minutes).components(separatedBy: " ").first ?? "").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                }
            }.chartYAxis(.hidden).chartXAxis(.hidden).frame(height: 150)
                .chartOverlay { _ in
                    HStack(spacing: 0) {
                        ForEach(points, id: \.offset) { _, item in
                            Button { selected = item.start } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain)
                                .accessibilityLabel(item.start.formatted(.dateTime.month(.wide).year()) + ", " + longDuration(item.minutes))
                        }
                    }
                }
            // "Oct", "Dec", "Feb"… on every other month (single letters like O N D J read as code), always
            // the last month, which is highlighted.
            HStack(spacing: 0) {
                ForEach(points, id: \.offset) { index, item in
                    let last = index == points.count - 1
                    let labelled = last || (points.count - 1 - index).isMultiple(of: 2)
                    Text(labelled ? item.start.formatted(.dateTime.month(.abbreviated)) : "")
                        .font(.system(size: 11, weight: last ? .bold : .regular)).lineLimit(1).fixedSize()
                        .foregroundStyle(last ? theme.accent : .secondary).frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
        }
    }
}

/// Your days: the month as a calendar, each watched day filled (shows, movies or both); the
/// biggest day ringed. A day opens its watches.
struct StatsYourDaysCard: View {
    let month: StatsMonth
    let now: Date
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private let movie = Color(webHex: "#f2b45a")
    var body: some View {
        let calendar = DiaryDate.calendar()
        let lead = (calendar.component(.weekday, from: month.start) + 5) % 7
        StatsCard(title: "Your days") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
                    Text(["M", "T", "W", "T", "F", "S", "S"][index]).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(month.days) { day in cell(day, calendar: calendar) }
            }
            // One line (owner's request); it shrinks a little on narrow phones rather than wrapping.
            HStack(spacing: 10) {
                legend(Circle().fill(theme.accent), "Shows"); legend(Circle().fill(movie), "Movies")
                legend(Circle().fill(.white), "Both"); legend(Circle().fill(.white.opacity(0.1)), "None")
                legend(Circle().strokeBorder(.white, lineWidth: 1.5), "Binge day")
            }.lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(month.watchedDays) of \(month.elapsed)").font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
                Text("Days you watched").font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
        }
    }
    private func cell(_ day: StatsMonth.Day, calendar: Calendar) -> some View {
        let fill: Color = day.shows && day.movies ? .white : day.shows ? theme.accent : day.movies ? movie : .white.opacity(0.07)
        let biggest = day.date == month.biggest?.date
        let future = day.date > calendar.startOfDay(for: now)
        return NavigationLink(value: HistoryRoute(day: day.date)) {
            Text(day.date.formatted(.dateTime.day())).font(.system(size: 14, weight: day.watched ? .bold : .regular))
                .foregroundStyle(day.watched ? (day.shows && day.movies ? Color.black : Color(webHex: "#1a1030")) : HomeStyle.secondary)
                .frame(width: 40, height: 40).background(fill, in: Circle())
                .overlay { if biggest { Circle().strokeBorder(.white, lineWidth: 2).padding(-3) } }
                .opacity(future ? 0.35 : 1)
        }.buttonStyle(.plain).disabled(!day.watched)
            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted) + (day.watched ? ", " + DiaryDate.duration(day.minutes) : ", no watch"))
    }
    private func legend<S: View>(_ swatch: S, _ label: String) -> some View {
        HStack(spacing: 4) { swatch.frame(width: 9, height: 9); Text(label).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize() }
    }
}

/// The month's Hall of fame: biggest day, best streak (as dots), first and latest watch.
struct StatsMonthHallOfFame: View {
    let month: StatsMonth
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if month.biggest != nil || month.first != nil {
            StatsCard(title: "Hall of fame") {
                if let day = month.biggest {
                    NavigationLink(value: HistoryRoute(day: day.date)) {
                        row("calendar-days", "Binge day", day.date.formatted(.dateTime.day().month(.abbreviated).year()), longDuration(day.minutes))
                    }.buttonStyle(.plain)
                }
                if month.bestStreak > 0 { StatsStreakRow(days: month.bestStreak) }
                if let first = month.first, let latest = month.latest {
                    HStack(spacing: 10) {
                        moment(first)
                        VStack(spacing: 6) {
                            let days = max(0, DiaryDate.calendar().dateComponents([.day], from: first.date, to: latest.date).day ?? 0)
                            Text(days.counted("day", "days")).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                            HStack(spacing: 0) { Circle().fill(theme.accent).frame(width: 8, height: 8); Rectangle().fill(theme.accent.opacity(0.5)).frame(height: 2); Circle().fill(theme.accent).frame(width: 8, height: 8) }
                        }.frame(maxWidth: .infinity)
                        moment(latest)
                    }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
    private func row(_ icon: String, _ label: String, _ detail: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            DiaryIcon(name: icon, size: 17).foregroundStyle(theme.accent).frame(width: 40, height: 40).background(theme.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            }
            Spacer()
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
        }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    private func moment(_ value: StatsMonth.Moment) -> some View {
        NavigationLink(value: value.title.id) {
            VStack(spacing: 6) {
                Artwork(path: value.title.poster, title: value.title.name, initialsOnly: false).frame(width: 54, height: 76).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(value.date.formatted(.dateTime.day().month(.abbreviated))).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }
}

/// "Best streak · ••• · 3 days": the streak with one dot per day (at most 14).
struct StatsStreakRow: View {
    let days: Int
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 12) {
            DiaryIcon(name: "activity", size: 17).foregroundStyle(theme.accent).frame(width: 40, height: 40).background(theme.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text("Best streak").font(.system(size: 14)).foregroundStyle(.secondary)
                HStack(spacing: 3) { ForEach(0..<min(days, 14), id: \.self) { _ in Circle().fill(theme.accent).frame(width: 6, height: 6) } }
            }
            Spacer()
            Text(days.counted("day", "days")).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
        }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .combine)
    }
}

// MARK: Library tab additions (board 6)

/// Faces of all time: the people in the most titles you've watched (Cast or Voice), from the
/// same ranking Favourites uses; each opens their page.
struct StatsFacesCard: View {
    @State private var voice = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        StatsCard {
            HStack {
                Text("Faces of all time").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 14) {
                    Button("Cast") { voice = false }.foregroundStyle(voice ? Color.secondary : theme.accent)
                    Button("Voice") { voice = true }.foregroundStyle(voice ? theme.accent : Color.secondary)
                }.font(.system(size: 15, weight: .semibold)).buttonStyle(.plain)
            }
            MostWatchedCast(kind: voice ? .voice : .cast, heading: nil, round: true).id(voice)
        }
    }
}

/// Studios: the production companies behind the most titles you've watched (from TMDB's
/// details for each title, read on this iPhone). Each opens the company's titles.
struct StatsStudiosCard: View {
    @Environment(DiaryStore.self) private var store
    @State private var rows: [(company: TitleCompany, count: Int, movie: Bool)] = []
    @State private var loaded = false
    @State private var all = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        StatsCard(title: "Studios") {
            if !loaded { DiaryLoadingPlaceholder(height: 120, label: "Counting studios") }
            else if rows.isEmpty { Text("No studios yet.").font(.subheadline).foregroundStyle(.secondary) }
            let most = max(1, rows.first?.count ?? 1)
            ForEach(Array((all ? rows : Array(rows.prefix(5))).enumerated()), id: \.offset) { _, row in
                NavigationLink(value: CompanyRoutes.explore(row.company, kind: row.movie ? .movie : .tv)) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.company.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text("\(row.count)").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Capsule().fill(.white.opacity(0.08)).frame(height: 8)
                            .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * CGFloat(row.count) / CGFloat(most)) } }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityElement(children: .combine)
            }
            if rows.count > 5 {
                Button { withAnimation(.smooth(duration: 0.25)) { all.toggle() } } label: {
                    HStack(spacing: 4) { Text(all ? "Show fewer" : "+\(rows.count - 5) more"); Image(systemName: all ? "chevron.up" : "chevron.right").font(.system(size: 11, weight: .bold)) }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent).frame(minHeight: 36)
                }.buttonStyle(.plain)
            }
        }.task(id: store.workspace.activeTitles.count) { await load() }
    }
    private func load() async {
        // The 40 titles you've watched most, so a large diary stays a handful of cached reads.
        var plays: [String: Int] = [:]
        for event in store.workspace.activeEvents { plays[event.titleId, default: 0] += 1 }
        let titles = store.workspace.activeTitles.filter { $0.tmdbId != nil && plays[$0.id] != nil }
            .sorted { (plays[$0.id] ?? 0) > (plays[$1.id] ?? 0) }.prefix(40)
        var counts: [String: (company: TitleCompany, count: Int, movie: Bool)] = [:]
        for title in titles {
            guard let id = title.tmdbId, !Task.isCancelled else { continue }
            let route = CatalogRoute(kind: title.isSeries ? .tv : .movie, id: id)
            guard let extras = try? await TitleExtrasCache.load(store: store, route: route) else { continue }
            for company in extras.companies where !company.isNetwork {
                let entry = counts[company.key] ?? (company, 0, !title.isSeries)
                counts[company.key] = (company, entry.count + 1, entry.movie)
            }
        }
        rows = counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.company.name < $1.company.name }
        loaded = true
    }
}
