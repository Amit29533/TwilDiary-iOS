import SwiftUI
import Charts
import TwilDiaryCore

/// Stats (owner's design): the Journey card over the period's most-watched backdrop, Watch
/// time with its chart and one range control, Streaks, Backlog, Gone quiet,
/// Genre mix and a link to the full history.
struct StatsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var period = Period.today
    @State private var year: Int?
    @State private var appliedShortcutRevision = 0
    @State private var selectedBucket: Int?
    @State private var expandedGenres = false
    @State private var staleLimit = 3
    @State private var clock = Date.now
    enum Tab: String, CaseIterable { case overview = "Overview", habits = "Habits", taste = "Taste", library = "Library" }
    /// Shared with Profile, whose cards open the tab they summarise.
    @AppStorage("stats.tab") private var tab = Tab.overview
    /// Owner's design: All time, or one month at a time (‹ November 2026 ›).
    @State private var monthly = false
    @State private var month = Date.now
    /// Owner's request: a Yearly view next to All time and Monthly (‹ 2026 ›).
    @State private var yearly = false
    @State private var yearDate = Date.now
    @State private var genreKind = 0
    @State private var mostPlayedShows = true
    @State private var highestRatedShows = true
    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(tab == item ? theme.ink : Color(webHex: "#c5c0cf"))
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background { if tab == item { Capsule().fill(theme.accent) } }.contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : []).accessibilityIdentifier("stats-tab-" + item.rawValue.lowercased())
            }
        }.padding(4).background(.white.opacity(0.06), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
    var body: some View {
        let data = store.statsProjection(period: period, year: year, at: clock)
        let highlights = store.statsHighlights(data, period: period, year: year, at: clock)
        let insights = StatsInsights(workspace: store.workspace, now: clock)
        VStack(spacing: 0) {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 14) {
                    tabPicker
                    switch tab {
                    case .overview where yearly:
                        let summary = StatsMonth(workspace: store.workspace, month: yearDate, now: clock, wholeYear: true)
                        StatsMonthNavigator(month: $yearDate, earliest: earliestMonth, now: clock, byYear: true)
                        StatsMonthCard(month: summary)
                        StatsMonthOverTimeCard(month: summary, selected: Binding(get: { yearDate }, set: { chosen in month = chosen; yearly = false; monthly = true }))
                        StatsMonthHallOfFame(month: summary)
                        StatsPosterRow(title: "Most played", items: (mostPlayedShows ? summary.mostPlayedShows : summary.mostPlayedMovies).map {
                            StatsPosterItem(title: $0.title, badge: "×\($0.count)", detail: $0.minutes > 0 ? longDuration($0.minutes) : nil)
                        }, shows: $mostPlayedShows)
                    case .overview where monthly:
                        let summary = StatsMonth(workspace: store.workspace, month: month, now: clock)
                        StatsMonthNavigator(month: $month, earliest: earliestMonth, now: clock)
                        StatsMonthCard(month: summary)
                        StatsMonthOverTimeCard(month: summary, selected: $month)
                        StatsYourDaysCard(month: summary, now: clock)
                        StatsMonthHallOfFame(month: summary)
                        StatsPosterRow(title: "Most played", items: (mostPlayedShows ? summary.mostPlayedShows : summary.mostPlayedMovies).map {
                            StatsPosterItem(title: $0.title, badge: "×\($0.count)", detail: $0.minutes > 0 ? longDuration($0.minutes) : nil)
                        }, shows: $mostPlayedShows)
                    case .overview:
                        StatsJourneyCard(insights: insights, coverage: data.coverage)
                        StatsPeriodTiles(insights: insights, onMonth: { monthly = true; month = clock }, onYear: { period = .year; year = nil })
                        trend(data, highlights: highlights)
                        StatsOverTimeCard(years: insights.perYear)
                        StatsSplitCard(insights: insights)
                    case .habits:
                        streaks(data.streaks)
                        StatsWhenCard(insights: insights)
                        StatsHallOfFameCard(insights: insights, longestStreak: data.streaks.longest)
                        StatsMarathonsCard(marathons: insights.marathons)
                    case .taste:
                        StatsPosterRow(title: "Most played", items: (mostPlayedShows ? insights.mostPlayedShows : insights.mostPlayedMovies).map {
                            StatsPosterItem(title: $0.title, badge: "×\($0.count)", detail: $0.minutes > 0 ? longDuration($0.minutes) : nil)
                        }, shows: $mostPlayedShows)
                        StatsPosterRow(title: "Highest rated", items: (highestRatedShows ? insights.topRatedShows : insights.topRatedMovies).map {
                            StatsPosterItem(title: $0, badge: "★ " + ($0.score ?? 0).formatted(.number.precision(.fractionLength(0...1))))
                        }, shows: $highestRatedShows)
                        StatsRatingsCard(insights: insights)
                        genres(data.genres)
                        StatsDecadesCard(decades: insights.decades)
                    case .library:
                        StatsFacesCard()
                        StatsStudiosCard()
                        StatsGlanceCard(insights: insights)
                        backlog(data.backlog)
                        goneQuiet(data.backlog.stale)
                    }
                    NavigationLink(value: AppDestination.history) {
                        HStack(spacing: 12) {
                            DiaryIcon(name: "history", size: 18).foregroundStyle(theme.accent).frame(width: 36, height: 36).background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) { Text("Watch history").font(.system(size: 16, weight: .semibold)); caption("Every watch, by date", size: 12) }
                            Spacer(); DiaryIcon(name: "chevron-right", size: 15).foregroundStyle(.secondary)
                        }.foregroundStyle(.white).statsPanel()
                    }.buttonStyle(.plain).accessibilityIdentifier("stats-history")
                }.padding(.horizontal, 16).padding(.bottom, 24)
            }.refreshable { await store.refresh(); clock = store.now }
        }.navigationTitle("Statistics").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: Binding(get: { yearly ? 2 : monthly ? 1 : 0 }, set: { value in monthly = value == 1; yearly = value == 2 })) {
                            Text("All time").tag(0); Text("Monthly").tag(1); Text("Yearly").tag(2)
                        }
                    } label: {
                        HStack(spacing: 5) { Text(scopeLabel); Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)) }
                            .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 4)
                    }.accessibilityLabel("Statistics period").accessibilityValue(scopeLabel).accessibilityIdentifier("stats-scope")
                }
            }
            .onChange(of: monthly) { _, on in if on && !yearly && month > clock { month = clock } ; if on { tab = .overview } }
            .onChange(of: yearly) { _, on in if on { tab = .overview; yearDate = clock } }
        .onChange(of: router.statsRevision) { _, _ in applyShortcut() }
            .onAppear { clock = store.now; applyShortcut() }
            .onChange(of: period) { _, _ in selectedBucket = nil }
            .onChange(of: year) { _, _ in selectedBucket = nil }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if DiaryDate.day(clock) != DiaryDate.day(store.now) { selectedBucket = nil }
                    clock = store.now
                }
            }
    }
    private var scopeLabel: String { yearly ? "Yearly" : monthly ? "Monthly" : "All time" }
    private func applyShortcut() {
        guard router.statsRevision > appliedShortcutRevision else { return }
        appliedShortcutRevision = router.statsRevision; period = .today; selectedBucket = nil
    }

    // MARK: Watch time

    private func trend(_ data: StatsOverview, highlights: StatsHighlights) -> some View {
        let value = data.trend
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                heading("Watch time"); Spacer(minLength: 0)
                if period == .year {
                    Menu {
                        Picker("Watch time year", selection: Binding(get: { data.selectedYear }, set: { year = $0 })) { ForEach(data.years, id: \.self) { Text(String($0)).tag($0) } }
                    } label: {
                        HStack(spacing: 6) { Text(String(data.selectedYear)); Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)) }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent).padding(.horizontal, 14).frame(height: 36)
                            .background(.white.opacity(0.06), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }.accessibilityLabel("Year").accessibilityValue(String(data.selectedYear)).accessibilityIdentifier("stats-year")
                }
            }
            // One layout for every range (figures above a full-width chart, the busiest-day row always
            // present), so switching ranges never resizes the card or shifts the page.
            trendFigures(value, highlights: highlights)
            chart(value.buckets)
            StatsRangeSelector(selection: $period)
            NavigationLink(value: HistoryRoute(day: highlights.busiest.map { localDay($0.date) })) { HStack(spacing: 12) {
                DiaryIcon(name: "calendar-days", size: 18).foregroundStyle(theme.accent).frame(width: 36, height: 36).background(theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    caption("Busiest day", size: 12)
                    Text(highlights.busiest.map { StatsHighlights.shortDate($0.date) + " · " + DiaryDate.duration($0.minutes) } ?? "None in this period")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(highlights.busiest == nil ? Color.secondary : theme.accent)
                }
                Spacer(minLength: 0)
                if highlights.busiest != nil { DiaryIcon(name: "chevron-right", size: 13).foregroundStyle(.secondary) }
            }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(highlights.busiest == nil)
                .accessibilityElement(children: .combine).accessibilityIdentifier("stats-busiest")
            if let index = selectedBucket, let active = value.buckets.first(where: { $0.key == index }) { bucketDetails(active) }
        }.statsPanel()
    }
    private func trendFigures(_ value: StatsOverview.Trend, highlights: StatsHighlights) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DiaryDate.duration(value.minutes)).font(.system(size: 34, weight: .bold)).foregroundStyle(theme.accent).tracking(-1.4).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text("avg \(DiaryDate.duration(Int(highlights.averageMinutes.rounded()))) / day").font(.system(size: 16)).foregroundStyle(.secondary)
            // Always one line (invisible when there is nothing to compare), so the card keeps its height.
            let difference = value.difference ?? 0
            // Nothing watched in either period: no "— 0m" line.
            let comparable = value.difference != nil && (value.minutes > 0 || difference != 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(difference > 0 ? "↑" : difference < 0 ? "↓" : "—") \(DiaryDate.duration(abs(difference)))").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(difference > 0 ? Color(webHex: "#5fe0b0") : difference < 0 ? Color(webHex: "#ff6b6b") : Color(webHex: "#c5c0cf"))
                Text(value.period == .today ? "vs yesterday" : value.comparison).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.top, 4).opacity(comparable ? 1 : 0).accessibilityHidden(!comparable)
        }
    }
    /// "0", "45m", "2h", "1h 30m".
    private func axisLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "0" }
        if minutes < 60 { return "\(minutes)m" }
        return minutes.isMultiple(of: 60) ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
    private func chart(_ buckets: [StatsOverview.Bucket]) -> some View {
        // The axis tops out at a tidy step above the busiest bar (15 min under an hour, then 30), so its
        // labels read exactly ("1h 30m") instead of rounding a 1h 14m peak down to "1h".
        let busiest = max(1, buckets.map(\.minutes).max() ?? 1), step = busiest <= 60 ? 15 : 30
        let peak = Int((Double(busiest) / Double(step)).rounded(.up)) * step
        // Every label for a week; otherwise about five, evenly spaced and always the last, so dates never crowd.
        let shown: [Int] = {
            guard buckets.count > 7 else { return buckets.map(\.key) }
            let step = Int((Double(buckets.count) / 5).rounded(.up))
            var indices = Array(stride(from: 0, to: buckets.count, by: step))
            if let last = indices.last, last != buckets.count - 1 {
                if buckets.count - 1 - last < max(1, step / 2) { indices.removeLast() }
                indices.append(buckets.count - 1)
            }
            return indices.map { buckets[$0].key }
        }()
        // Watch time on top of the bars: every bar in a week, the tallest otherwise.
        let labelled: (StatsOverview.Bucket) -> Bool = { bucket in bucket.minutes > 0 && (buckets.count <= 7 || bucket.minutes == busiest) }
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                Chart(buckets) { bucket in
                    BarMark(x: .value("Period", Double(bucket.key)), y: .value("Minutes", bucket.minutes), width: .fixed(min(20, max(2, geometry.size.width / CGFloat(max(1, buckets.count)) - 3))))
                        .foregroundStyle(theme.accent.opacity(selectedBucket == nil || selectedBucket == bucket.key ? 1 : 0.45)).cornerRadius(3)
                        .annotation(position: .top, spacing: 3) {
                            if labelled(bucket) { Text(DiaryDate.duration(bucket.minutes)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).fixedSize() }
                        }
                }.chartXAxis(.hidden).chartYAxis {
                    AxisMarks(position: .trailing, values: [0, Double(peak) / 2, Double(peak)]) { mark in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { if let minutes = mark.as(Double.self) { Text(axisLabel(Int(minutes.rounded()))).font(.system(size: 10)).foregroundStyle(.secondary) } }
                    }
                }.chartXScale(domain: -0.5...(Double(max(1, buckets.count)) - 0.5), range: .plotDimension(padding: 0)).chartYScale(domain: 0...Double(peak) * 1.18).accessibilityHidden(true)
                    .chartOverlay { _ in
                        HStack(spacing: 0) { ForEach(buckets) { bucket in
                            Button { selectedBucket = selectedBucket == bucket.key ? nil : bucket.key } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain)
                                .accessibilityLabel("\(bucket.description): \(DiaryDate.duration(bucket.minutes)), \(bucket.events.count) watches").accessibilityAddTraits(selectedBucket == bucket.key ? .isSelected : []).accessibilityIdentifier("stats-bucket-\(bucket.key)")
                        } }.padding(.trailing, 28)
                    }
                    .overlay(alignment: .top) {
                        if let key = selectedBucket, let bucket = buckets.first(where: { $0.key == key }) {
                            VStack(spacing: 1) { Text(bucket.label).font(.system(size: 11)); Text(DiaryDate.duration(bucket.minutes)).font(.system(size: 13, weight: .semibold)) }
                                .padding(.horizontal, 8).padding(.vertical, 4).background(Color(webHex: "#2a2638"), in: RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false)
                        }
                    }
            }.frame(height: 130)
            HStack(spacing: 0) {
                ForEach(buckets) { bucket in
                    Text(shown.contains(bucket.key) ? bucket.label : "").font(.system(size: 10, weight: selectedBucket == bucket.key ? .semibold : .regular))
                        .foregroundStyle(selectedBucket == bucket.key ? Color.white : Color.secondary).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                }
            }.padding(.trailing, 28).accessibilityHidden(true)
        }.frame(maxWidth: .infinity)
    }
    private func bucketDetails(_ bucket: StatsOverview.Bucket) -> some View {
        let grouped = Dictionary(grouping: bucket.events, by: \.titleId)
        // Parse each watch date once, not inside every sort comparison.
        let latest = grouped.mapValues { $0.compactMap { DiaryDate.parse($0.watchedAt) }.max() ?? .distantPast }
        let ids = grouped.keys.sorted { a, b in (latest[a] ?? .distantPast) > (latest[b] ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text(bucket.description).font(.system(size: 15, weight: .bold)); Spacer(); Button("Close") { selectedBucket = nil }.font(.system(size: 13)) }
            if ids.isEmpty { caption("No watches logged in this period.") }
            ScrollView(.horizontal) { HStack(alignment: .top, spacing: 12) { ForEach(ids, id: \.self) { id in if let title = store.title(id) {
                VStack(alignment: .leading, spacing: 6) { NavigationLink(value: id) { PosterCard(title: title) }.buttonStyle(.plain); caption("\(grouped[id]?.count ?? 0) \(grouped[id]?.count == 1 ? "watch" : "watches")", size: 12) }.frame(width: 112)
            } } } }.scrollIndicators(.hidden)
        }
    }

    // MARK: Streaks

    private func streaks(_ value: StatsOverview.Streaks) -> some View {
        let maxCount = max(1, value.heatmap.map(\.count).max() ?? 1)
        let days = activeDays
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    heading("Your days"); Spacer()
                    NavigationLink(value: AppDestination.history) {
                        HStack(spacing: 3) { Text("Calendar"); DiaryIcon(name: "chevron-right", size: 12) }.font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).frame(minHeight: 36)
                    }.buttonStyle(.plain).accessibilityIdentifier("stats-calendar")
                }
                caption("\(days.all.formatted()) of \(days.elapsed.formatted()) days watched", size: 13)
            }
            HStack(spacing: 10) {
                NavigationLink(value: HistoryRoute(day: clock)) { streakTile("flame", "\(value.current) \(value.current == 1 ? "day" : "days")", "Current") }.buttonStyle(.plain)
                streakTile("rosette", "\(value.longest) \(value.longest == 1 ? "day" : "days")", "Longest")
                streakTile("calendar", days.year.formatted(), "Active in " + String(DiaryDate.calendar().component(.year, from: clock)))
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) { ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { Text($0).font(.system(size: 11)).frame(height: 14) } }.foregroundStyle(.secondary)
                HStack(spacing: 4) { ForEach(0..<12, id: \.self) { column in
                    VStack(spacing: 4) { ForEach(0..<7, id: \.self) { row in
                        let day = value.heatmap[column * 7 + row]
                        NavigationLink(value: HistoryRoute(day: localDay(day.date))) { RoundedRectangle(cornerRadius: 3).fill(heatColor(day.count, maxCount)).frame(height: 14).opacity(day.future ? 0.25 : 1) }.buttonStyle(.plain).disabled(day.future).accessibilityLabel("\(day.date): \(day.count) watches")
                    } }.frame(maxWidth: .infinity)
                } }
            }
            HStack(spacing: 4) { Text("Last 12 weeks"); Spacer(); Text("Less"); ForEach(0..<5, id: \.self) { level in RoundedRectangle(cornerRadius: 2).fill(heatColor(level, 4)).frame(width: 11, height: 11) }; Text("More") }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.statsPanel()
    }
    /// The owner's second design: icon on top, the figure, then its label.
    private func streakTile(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(theme.accent)
            Text(value).font(.system(size: 18, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08))).accessibilityElement(children: .combine)
    }

    /// Days with a dated watch: all of them, since the first, and this year.
    private var activeDays: (all: Int, elapsed: Int, year: Int) {
        let calendar = DiaryDate.calendar()
        let days = Set(store.workspace.activeEvents.compactMap { DiaryDate.parse($0.watchedAt).map { calendar.startOfDay(for: $0) } })
        guard let first = days.min() else { return (0, 0, 0) }
        let elapsed = (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: clock)).day ?? 0) + 1
        let year = calendar.component(.year, from: clock)
        return (days.count, max(days.count, elapsed), days.filter { calendar.component(.year, from: $0) == year }.count)
    }
    /// The first month with a dated watch (where Monthly can go back to).
    private var earliestMonth: Date {
        let calendar = DiaryDate.calendar()
        let first = store.workspace.activeEvents.compactMap { DiaryDate.parse($0.watchedAt) }.min() ?? clock
        return calendar.date(from: calendar.dateComponents([.year, .month], from: first)) ?? first
    }

    // MARK: Backlog and Gone quiet

    private func backlog(_ value: StatsOverview.Backlog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { router.library("all") } label: {
                HStack(spacing: 12) { Image(systemName: "archivebox").font(.system(size: 20)); heading("Backlog"); Spacer(); DiaryIcon(name: "chevron-right", size: 16).foregroundStyle(theme.accent) }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            GeometryReader { geometry in HStack(spacing: 0) { ForEach(statuses, id: \.self) { status in statusColor(status).frame(width: geometry.size.width * CGFloat(value.counts[status] ?? 0) / CGFloat(max(1, value.total))) } } }
                .frame(height: 10).clipShape(Capsule()).accessibilityLabel(statuses.map { "\($0.capitalized): \(value.counts[$0] ?? 0)" }.joined(separator: ", "))
            // Two by two: dot, count, then its name on the same line (owner's reference).
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(statuses, id: \.self) { status in
                    Button { router.library(status) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(statusColor(status)).frame(width: 9, height: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text("\(value.counts[status] ?? 0)").font(.system(size: 18, weight: .bold)).monospacedDigit()
                            Text(status.capitalized).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 40, height: 40).background(theme.accent.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        caption("Planned runtime", size: 12)
                        Text(DiaryDate.duration(value.plannedMinutes)).font(.system(size: 24, weight: .bold)).foregroundStyle(theme.accent).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
                if value.unknownPlanned > 0 { caption(value.unknownPlanned.counted("title lacks", "titles lack") + " runtime or complete episode data", size: 12) }
                Button { router.library("planned") } label: {
                    HStack(spacing: 6) { Text("Open planned"); Image(systemName: "arrow.right") }.font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                        .frame(maxWidth: .infinity).frame(height: 46).background(HomeStyle.chip, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.springPress).accessibilityIdentifier("stats-open-planned")
            }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        }.statsPanel()
    }
    /// Shows you were watching that have had no progress for 30+ days.
    private func goneQuiet(_ stale: [StatsOverview.Progress]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz").font(.system(size: 20)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) { heading("Gone quiet"); caption("Pick them back up or mark them dropped", size: 12) }
            }
            if stale.isEmpty { caption("Nothing has stalled. Everything you're watching moved in the last 30 days.") }
            ForEach(Array(stale.prefix(staleLimit))) { item in
                HStack(spacing: 12) {
                    NavigationLink(value: item.id) {
                        HStack(spacing: 12) {
                            Artwork(path: item.title.poster, title: item.title.name, initialsOnly: false).frame(width: 46, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                caption("Last watched \(item.daysSince ?? 0) days ago", size: 12)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.white)
                    Button("Drop") { Task { await store.setStatus(item.title, status: "dropped") } }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent).padding(.horizontal, 14).frame(height: 36)
                        .background(theme.accent.opacity(0.12), in: Capsule()).buttonStyle(.plain).disabled(store.busy)
                }.padding(8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            }
            if staleLimit < stale.count { Button("Show more") { staleLimit += 5 }.font(.system(size: 13, weight: .semibold)) }
        }.statsPanel().accessibilityIdentifier("stats-gone-quiet")
    }

    // MARK: Genre mix

    private func genres(_ value: StatsOverview.Genres) -> some View {
        let mix = genreMix(value)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) { heading("Genre mix"); caption("Share of your \(mix.total) watched " + (genreKind == 1 ? "movies" : genreKind == 2 ? "shows" : "titles"), size: 13) }
            Picker("Genre mix", selection: $genreKind) { Text("All").tag(0); Text("Movies").tag(1); Text("Shows").tag(2) }
                .pickerStyle(.segmented).accessibilityIdentifier("stats-genre-kind")
            ForEach(Array(mix.items.prefix(expandedGenres ? mix.items.count : 5).enumerated()), id: \.offset) { _, item in
                Button { router.libraryGenre(item.genre) } label: { genreRow(item.genre, count: item.count, share: item.share) }.buttonStyle(.plain)
            }
            if mix.items.count > 5 { Button { expandedGenres.toggle() } label: { genreRow(expandedGenres ? "Show top 5" : "All other genres", count: mix.otherCount, share: mix.otherShare) }.buttonStyle(.plain).accessibilityValue(expandedGenres ? "Expanded" : "Collapsed") }
            caption("Titles can have several genres, so these shares can add up to more than 100%.", size: 12)
            if value.items.isEmpty { caption("No watched genres yet.") }
        }.statsPanel()
    }
    /// The genre shares for All (from the stats) or for movies or shows only (counted here).
    private func genreMix(_ value: StatsOverview.Genres) -> (total: Int, items: [(genre: String, count: Int, share: Double)], otherCount: Int, otherShare: Double) {
        if genreKind == 0 { return (value.total, value.items.map { ($0.genre, $0.count, $0.share) }, value.otherCount, value.otherShare) }
        let watched = Set(store.workspace.activeEvents.map(\.titleId))
        let titles = store.workspace.activeTitles.filter { watched.contains($0.id) && $0.isSeries == (genreKind == 2) }
        var counts: [String: Int] = [:]
        for title in titles { for genre in Set(title.genres) { counts[genre, default: 0] += 1 } }
        let total = max(1, titles.count)
        let items = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value, Double($0.value) * 100 / Double(total)) }
        let others = Set(titles.filter { title in !title.genres.contains { genre in items.prefix(5).contains { $0.0 == genre } } }.map(\.id)).count
        return (titles.count, items, others, Double(others) * 100 / Double(total))
    }
    private func genreRow(_ name: String, count: Int, share: Double) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1).frame(width: 118, alignment: .leading)
            Capsule().fill(.white.opacity(0.08)).frame(height: 10).overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * min(1, share / 100)) } }
            Text("\(Int(share.rounded()))% · \(count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().frame(width: 62, alignment: .trailing)
        }.foregroundStyle(.white).frame(minHeight: 28).contentShape(Rectangle())
    }

    // MARK: Helpers

    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 20, weight: .bold)) }
    private func caption(_ text: String, size: CGFloat = 13) -> some View { Text(text).font(.system(size: size)).foregroundStyle(.secondary) }
    private func heatColor(_ count: Int, _ maxCount: Int) -> Color { count == 0 ? Color.white.opacity(0.06) : theme.accent.opacity(Double(max(1, Int(ceil(Double(count) / Double(maxCount) * 4)))) / 4) }
    private func localDay(_ value: String) -> Date { let fields = value.split(separator: "-").compactMap { Int($0) }; return fields.count == 3 ? DiaryDate.calendar().date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2], hour: 12)) ?? store.now : store.now }
    private var statuses: [String] { ["planned", "watching", "completed", "dropped"] }
    private func statusColor(_ status: String) -> Color { status == "dropped" ? Color(webHex: "#646075") : theme.accent.opacity(status == "planned" ? 0.65 : status == "watching" ? 0.85 : 1) }
}

private extension View {
    func statsPanel() -> some View { diaryPanel(padding: 18, radius: 22) }
}

/// The one range control: Today · 7D · 30D · 90D · 1Y · All.
private struct StatsRangeSelector: View {
    @Binding var selection: Period
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ranges: [Period] = [.today, .week, .month, .ninetyDays, .year, .all]
    var body: some View {
        // Segments are plain: a glass capsule per segment washed out the sliding accent
        // selection (native segmented controls keep one surface and one selection).
        HStack(spacing: 3) { ForEach(ranges) { range in
            Button { selection = range } label: { Text(label(range)).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity).frame(height: 38).contentShape(Capsule()) }.buttonStyle(.plain).foregroundStyle(selection == range ? theme.ink : Color(webHex: "#c5c0cf")).accessibilityAddTraits(selection == range ? .isSelected : [])
        } }.frame(height: 38).background(alignment: .leading) {
            GeometryReader { geometry in
                if let index = ranges.firstIndex(of: selection) {
                    let width = max(0, (geometry.size.width - CGFloat(ranges.count - 1) * 3) / CGFloat(ranges.count))
                    Capsule().fill(theme.accent).frame(width: width, height: 38).offset(x: CGFloat(index) * (width + 3))
                }
            }
        }.padding(3).background { DiaryControlSurface(shape: Capsule(), field: true) }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: selection)
            .accessibilityElement(children: .contain).accessibilityIdentifier("stats-range")
    }
    private func label(_ value: Period) -> String { switch value { case .week: "7D"; case .month: "30D"; case .ninetyDays: "90D"; case .year: "1Y"; case .all: "All"; case .today: "Today" } }
}
