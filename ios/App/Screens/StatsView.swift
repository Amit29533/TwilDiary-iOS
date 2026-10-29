import SwiftUI
import Charts
import TwilDiaryCore

/// Stats (owner's design): the Journey card over the period's most-watched backdrop, Watch
/// time with its chart and one range control, Streaks, Fun facts, Backlog, Gone quiet,
/// Genre mix and a link to the full history.
struct StatsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var showSearch = false
    @State private var period = Period.today
    @State private var year: Int?
    @State private var appliedShortcutRevision = 0
    @State private var selectedBucket: Int?
    @State private var expandedGenres = false
    @State private var staleLimit = 3
    @State private var clock = Date.now
    var body: some View {
        let data = store.statsProjection(period: period, year: year, at: clock)
        let highlights = StatsHighlights(workspace: store.workspace, trend: data.trend, timeZone: DiaryDate.calendar().timeZone)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader(name: "Stats", onSearch: { showSearch.toggle() }, part: .title).padding(.horizontal, -16).padding(.bottom, -6)
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    journey(data.coverage)
                    trend(data, highlights: highlights)
                    streaks(data.streaks)
                    funFacts(highlights)
                    backlog(data.backlog)
                    goneQuiet(data.backlog.stale)
                    genres(data.genres)
                    NavigationLink(value: AppDestination.history) {
                        HStack(spacing: 12) {
                            DiaryIcon(name: "history", size: 18).foregroundStyle(theme.accent).frame(width: 36, height: 36).background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) { Text("Watch history").font(.system(size: 16, weight: .semibold)); caption("Every watch, by date", size: 12) }
                            Spacer(); DiaryIcon(name: "chevron-right", size: 15).foregroundStyle(.secondary)
                        }.foregroundStyle(.white).statsPanel()
                    }.buttonStyle(.plain).accessibilityIdentifier("stats-history")
                }.padding(.horizontal, 16).padding(.bottom, 24)
            }.refreshable { await store.refresh(); clock = store.now }
        }.overlay(alignment: .top) { PageHeader(name: "Stats", onSearch: { showSearch.toggle() }, part: .buttons) }
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
    private func applyShortcut() {
        guard router.statsRevision > appliedShortcutRevision else { return }
        appliedShortcutRevision = router.statsRevision; period = .today; selectedBucket = nil
    }

    // MARK: Journey

    /// "Your journey" (owner's design): the dated count large, its share as a glowing bar, and
    /// what is left out (undated, no runtime) as two chips with the way to review dates.
    private func journey(_ value: StatsOverview.Coverage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().fill(theme.accent).frame(width: 16, height: 16).accessibilityHidden(true)
                Text("YOUR JOURNEY").font(.system(size: 12, weight: .semibold)).tracking(2.4).foregroundStyle(theme.accent)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(value.dated.formatted()).font(.system(size: 52, weight: .heavy)).tracking(-1.5).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(LinearGradient(colors: [.white, theme.accent], startPoint: .leading, endPoint: .trailing))
                HStack(spacing: 6) { Image(systemName: "calendar").accessibilityHidden(true); Text("Dated") }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent).padding(.horizontal, 12).frame(height: 34)
                    .background(theme.accent.opacity(0.12), in: Capsule()).overlay(Capsule().strokeBorder(theme.accent.opacity(0.35)))
            }.padding(.top, 12)
            Text("of \(value.total.formatted())").font(.system(size: 18, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            Text("\(value.percent)%").font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 4).accessibilityHidden(true)
            // A glowing bar, so the share reads at a glance.
            Capsule().fill(.white.opacity(0.1)).frame(height: 8)
                .overlay(alignment: .leading) { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * Double(value.percent) / 100).shadow(color: theme.accent.opacity(0.8), radius: 7) } }
                .padding(.top, 6).accessibilityLabel("Watches with dates").accessibilityValue("\(value.percent)%")
            if value.total == 0 {
                Text("Log a movie or episode to start your stats.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.82)).padding(.top, 14)
            } else {
                HStack(spacing: 10) {
                    journeyChip("calendar.badge.minus", value.unknown, "Undated")
                    Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 28).accessibilityHidden(true)
                    journeyChip("clock.badge.xmark", value.missingRuntime, "No runtime")
                    if value.unknown > 0 {
                        NavigationLink(value: HistoryRoute(unknown: true)) {
                            Image(systemName: "arrow.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).overlay(Circle().strokeBorder(.white.opacity(0.45))).contentShape(Circle())
                        }.buttonStyle(.springPress).accessibilityLabel("Review dates")
                    }
                }.padding(.top, 18)
                if value.future > 0 {
                    Text(value.future.counted("future-dated watch waits for its", "future-dated watches wait for their") + " watch day").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
                }
            }
        }.foregroundStyle(.white).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color(webHex: "#16141f")
                    RadialGradient(colors: [theme.accent.opacity(0.2), .clear], center: .topLeading, startRadius: 0, endRadius: 280)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("stats-journey")
    }
    private func journeyChip(_ symbol: String, _ count: Int, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(theme.accent)
                .frame(width: 36, height: 36).background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(count.formatted()).font(.system(size: 18, weight: .bold)).monospacedDigit()
                Text(label).font(.system(size: 11, weight: .medium)).tracking(0.6).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
            .accessibilityElement(children: .combine)
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
            HStack(spacing: 12) {
                DiaryIcon(name: "calendar-days", size: 18).foregroundStyle(theme.accent).frame(width: 36, height: 36).background(theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    caption("Busiest day", size: 12)
                    Text(highlights.busiest.map { StatsHighlights.shortDate($0.date) + " · " + DiaryDate.duration($0.minutes) } ?? "None in this period")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(highlights.busiest == nil ? Color.secondary : theme.accent)
                }
                Spacer(minLength: 0)
            }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)).accessibilityElement(children: .combine).accessibilityIdentifier("stats-busiest")
            if let index = selectedBucket, let active = value.buckets.first(where: { $0.key == index }) { bucketDetails(active) }
            caption(highlights.bulkDays > 0
                ? "Dated watches only, estimated from runtimes. \(highlights.bulkDays) bulk-imported \(highlights.bulkDays == 1 ? "day" : "days") with over 24 hours stay out of the average and busiest day."
                : "Dated watches only. Estimated from title runtimes. Includes rewatches.", size: 12)
        }.statsPanel()
    }
    private func trendFigures(_ value: StatsOverview.Trend, highlights: StatsHighlights) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DiaryDate.duration(value.minutes)).font(.system(size: 34, weight: .bold)).foregroundStyle(theme.accent).tracking(-1.4).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text("avg \(DiaryDate.duration(Int(highlights.averageMinutes.rounded()))) / day").font(.system(size: 16)).foregroundStyle(.secondary)
            // Always one line (invisible when there is nothing to compare), so the card keeps its height.
            let difference = value.difference ?? 0
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(difference > 0 ? "↑" : difference < 0 ? "↓" : "—") \(DiaryDate.duration(abs(difference)))").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(difference > 0 ? Color(webHex: "#5fe0b0") : difference < 0 ? Color(webHex: "#ff6b6b") : Color(webHex: "#c5c0cf"))
                Text(value.comparison).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.top, 4).opacity(value.difference == nil ? 0 : 1).accessibilityHidden(value.difference == nil)
            caption(value.watches.counted("watch", "watches") + " · " + value.titles.counted("title", "movies & shows"), size: 12).padding(.top, 2)
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
        let shown = buckets.count <= 12 ? buckets.map(\.key) : stride(from: 0, to: buckets.count, by: max(1, buckets.count / 6)).map { $0 }
        return VStack(spacing: 6) {
            GeometryReader { geometry in
                Chart(buckets) { bucket in
                    BarMark(x: .value("Period", Double(bucket.key)), y: .value("Minutes", bucket.minutes), width: .fixed(min(20, max(2, geometry.size.width / CGFloat(max(1, buckets.count)) - 3))))
                        .foregroundStyle(theme.accent.opacity(selectedBucket == nil || selectedBucket == bucket.key ? 1 : 0.45)).cornerRadius(3)
                }.chartXAxis(.hidden).chartYAxis {
                    AxisMarks(position: .trailing, values: [0, Double(peak) / 2, Double(peak)]) { mark in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { if let minutes = mark.as(Double.self) { Text(axisLabel(Int(minutes.rounded()))).font(.system(size: 10)).foregroundStyle(.secondary) } }
                    }
                }.chartXScale(domain: -0.5...(Double(max(1, buckets.count)) - 0.5), range: .plotDimension(padding: 0)).chartYScale(domain: 0...Double(peak)).accessibilityHidden(true)
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
        return VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: AppDestination.history) { HStack { heading("Streaks"); Spacer(); DiaryIcon(name: "chevron-right", size: 16).foregroundStyle(theme.accent) }.contentShape(Rectangle()) }.buttonStyle(.plain)
            HStack(spacing: 10) {
                streakTile("flame", "\(value.current) \(value.current == 1 ? "day" : "days")", "Current")
                streakTile("rosette", "\(value.longest) \(value.longest == 1 ? "day" : "days")", "Longest")
                streakTile("calendar", "\(value.activeDays) of \(value.elapsedDays)", "Active days")
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

    // MARK: Fun facts

    private func funFacts(_ value: StatsHighlights) -> some View {
        let top = value.topTitleIDs.first.flatMap { store.title($0) }
        // Built step by step: one long literal of optional tuples is slow to type-check.
        var facts: [(String, String, String)] = []
        if let top { facts.append(("crown", top.name, "Top title · \(DiaryDate.duration(value.topMinutes)) over \(value.topPlays) \(value.topPlays == 1 ? "play" : "plays")")) }
        if let binge = value.binge, let show = store.title(binge.titleID) {
            facts.append(("bolt", "\(binge.episodes) episodes in a day", "Biggest binge · \(show.name) · \(StatsHighlights.shortDate(binge.date))"))
        }
        if value.minutes >= 24 * 60 { facts.append(("hourglass", String(format: "%.1f full days", Double(value.minutes) / 1440), "of watching in this period")) }
        if let night = value.nightOwl { facts.append(("moon.stars", "\(night)% after 10 pm", night >= 40 ? "Certified night owl" : "Late-night watches")) }
        if let day = value.weekday { facts.append(("calendar.badge.clock", day.name, "Your favourite day · \(day.share)% of watches")) }
        facts.append(("arrow.counterclockwise", "\(value.rewatches) \(value.rewatches == 1 ? "rewatch" : "rewatches")", "Things you went back to"))
        facts.append(("sparkles", "\(value.newStarts) new \(value.newStarts == 1 ? "start" : "starts")", "Titles you began · \(value.episodes.counted("episode", "episodes")) · \(value.movies) \(value.movies == 1 ? "movie" : "movies")"))
        return VStack(alignment: .leading, spacing: 14) {
            heading("Fun facts")
            if value.episodes + value.movies == 0 { caption("Watch something in this period to unlock its fun facts.") }
            else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: fact.0).font(.system(size: 17)).foregroundStyle(theme.accent)
                            Text(fact.1).font(.system(size: 15, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                            Text(fact.2).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).padding(12)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }.statsPanel().accessibilityIdentifier("stats-fun-facts")
    }

    // MARK: Backlog and Gone quiet

    private func backlog(_ value: StatsOverview.Backlog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { router.library("all") } label: {
                HStack(spacing: 12) { Image(systemName: "archivebox").font(.system(size: 20)); heading("Backlog"); Spacer(); DiaryIcon(name: "chevron-right", size: 16).foregroundStyle(theme.accent) }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            GeometryReader { geometry in HStack(spacing: 0) { ForEach(statuses, id: \.self) { status in statusColor(status).frame(width: geometry.size.width * CGFloat(value.counts[status] ?? 0) / CGFloat(max(1, value.total))) } } }
                .frame(height: 10).clipShape(Capsule()).accessibilityLabel(statuses.map { "\($0.capitalized): \(value.counts[$0] ?? 0)" }.joined(separator: ", "))
            HStack(alignment: .top, spacing: 6) {
                ForEach(statuses, id: \.self) { status in
                    Button { router.library(status) } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(statusColor(status)).frame(width: 10, height: 10).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 1) { Text("\(value.counts[status] ?? 0)").font(.system(size: 16, weight: .semibold)); Text(status.capitalized).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.foregroundStyle(.white)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 12) {
                Image(systemName: "clock").font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 40, height: 40).background(theme.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    caption("Planned runtime", size: 12)
                    Text(DiaryDate.duration(value.plannedMinutes)).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.accent)
                    if value.unknownPlanned > 0 { caption(value.unknownPlanned.counted("title lacks", "titles lack") + " runtime or complete episode data", size: 11) }
                }
                Spacer(minLength: 4)
                Button { router.library("planned") } label: {
                    HStack(spacing: 5) { Text("Open planned"); Image(systemName: "arrow.right") }.font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 12).frame(height: 36).background(theme.accent.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain)
            }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 20)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) { heading("Genre mix"); caption("Share of your \(value.total) watched movies & shows", size: 12) }
            }
            ForEach(Array(value.items.prefix(expandedGenres ? value.items.count : 5))) { item in Button { router.libraryGenre(item.genre) } label: { genreRow(item.genre, count: item.count, share: item.share) }.buttonStyle(.plain) }
            if value.items.count > 5 { Button { expandedGenres.toggle() } label: { genreRow(expandedGenres ? "Show top 5" : "All other genres", count: value.otherCount, share: value.otherShare) }.buttonStyle(.plain).accessibilityValue(expandedGenres ? "Expanded" : "Collapsed") }
            caption("Titles can have several genres, so these shares can add up to more than 100%.", size: 12)
            if value.items.isEmpty { caption("No watched genres yet.") }
        }.statsPanel()
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
