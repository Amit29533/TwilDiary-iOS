import SwiftUI
import Charts
import TwilDiaryCore

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
    @State private var progressLimit = 5
    @State private var staleLimit = 2
    @AppStorage("backlogGrid") private var grid = false
    @State private var clock = Date.now
    var body: some View {
        let data = store.statsProjection(period: period, year: year, at: clock)
        VStack(spacing: 0) {
            PageHeader(name: "Stats", onSearch: { showSearch.toggle() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    coverage(data.coverage)
                    trend(data)
                    streaks(data.streaks)
                    backlog(data.backlog)
                    genres(data.genres)
                }.padding(.horizontal, 16).padding(.bottom, 24)
            }.refreshable { await store.refresh(); clock = store.now }
        }.onChange(of: router.statsRevision) { _, _ in applyShortcut() }
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
    private func coverage(_ value: StatsOverview.Coverage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) { Text("\(value.dated) of \(value.total) watches have dates").font(.system(size: 15, weight: .bold)); Spacer(minLength: 4); Text("\(value.percent)%").font(.system(size: 14, weight: .bold)).foregroundStyle(.tint) }
            ProgressView(value: Double(value.percent), total: 100).accessibilityLabel("Watches with dates")
            caption(coverageCopy(value))
            if value.unknown > 0 { NavigationLink(value: HistoryRoute(unknown: true)) { Text("Review dates").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14))) }.buttonStyle(.plain) }
        }.statsPanel()
    }
    private func coverageCopy(_ value: StatsOverview.Coverage) -> String {
        var text = value.unknown > 0 ? "\(value.unknown) undated watches are left out of periods and trends." : value.total == 0 ? "Log a movie or episode to start your stats." : "All your watches have dates."
        if value.missingRuntime > 0 { text += " \(value.missingRuntime) dated watches have no runtime and are left out of watch time." }
        if value.future > 0 { text += " \(value.future) future-dated watches are left out until their watch day." }
        return text
    }
    private func trend(_ data: StatsOverview) -> some View {
        let value = data.trend
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                heading("Watch time").lineLimit(1).minimumScaleFactor(0.85); Spacer(minLength: 0)
                Menu {
                    Picker("Watch time period", selection: $period) { ForEach([Period.today, .week, .month, .year]) { Text($0.label).tag($0) } }
                } label: { HStack(spacing: 5) { Text(period == .all || period == .ninetyDays ? "Calendar" : period.label); DiaryIcon(name: "chevron-down", size: 12) }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 44).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.13))) }.buttonStyle(.plain).accessibilityIdentifier("stats-calendar")
                if period == .year { Picker("Watch time year", selection: Binding(get: { data.selectedYear }, set: { year = $0 })) { ForEach(data.years, id: \.self) { Text(String($0)).tag($0) } }.pickerStyle(.menu).font(.system(size: 12)).fixedSize() }
            }
            StatsRangeSelector(selection: $period).padding(.top, 12).padding(.bottom, 18)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { total(value.minutes); caption("avg \(DiaryDate.duration(Int(value.average.rounded()))) / day", size: 12) }
                VStack(alignment: .leading, spacing: 4) { total(value.minutes); caption("avg \(DiaryDate.duration(Int(value.average.rounded()))) / day", size: 12) }
            }
            if let difference = value.difference { HStack(alignment: .firstTextBaseline, spacing: 4) { Text("\(difference > 0 ? "↑" : difference < 0 ? "↓" : "—") \(DiaryDate.duration(abs(difference)))").bold().foregroundStyle(difference > 0 ? Color(webHex: "#87d9aa") : Color(webHex: "#c5c0cf")); Text(value.comparison).foregroundStyle(.secondary) }.font(.system(size: 12)).padding(.top, 6) }
            caption("\(value.watches) watches · \(value.titles) movies & shows", size: 12).padding(.top, 4)
            chart(value.buckets).padding(.top, 16)
            HStack { Text(value.start); Spacer(); Text(value.end) }.font(.system(size: 11)).foregroundStyle(.secondary)
            if let busiest = value.busiest { caption("Busiest: \(busiest.date) · \(DiaryDate.duration(busiest.minutes))").padding(.top, 8) }
            if let index = selectedBucket, let active = value.buckets.first(where: { $0.key == index }) { bucketDetails(active).padding(.top, 14) }
            caption("Dated watches only. Estimated from title runtimes. Includes rewatches.", size: 12).padding(.top, 12)
        }.statsPanel()
    }
    private func chart(_ buckets: [StatsOverview.Bucket]) -> some View {
        GeometryReader { geometry in
            Chart(buckets) { bucket in
                BarMark(x: .value("Period", Double(bucket.key)), y: .value("Minutes", bucket.minutes), width: .fixed(min(20, max(2, geometry.size.width / CGFloat(max(1, buckets.count)) - 2))))
                    .foregroundStyle(theme.accent.opacity(selectedBucket == nil || selectedBucket == bucket.key ? 1 : 0.5)).cornerRadius(3)
            }.chartXAxis(.hidden).chartYAxis(.hidden).chartXScale(domain: -0.5...(Double(max(1, buckets.count)) - 0.5), range: .plotDimension(padding: 0)).chartYScale(domain: 0...max(1, buckets.map(\.minutes).max() ?? 1)).accessibilityHidden(true)
                .overlay { HStack(spacing: 0) { ForEach(buckets) { bucket in
                    Button { selectedBucket = selectedBucket == bucket.key ? nil : bucket.key } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain)
                        .accessibilityLabel("\(bucket.description): \(DiaryDate.duration(bucket.minutes)), \(bucket.events.count) watches").accessibilityAddTraits(selectedBucket == bucket.key ? .isSelected : []).accessibilityIdentifier("stats-bucket-\(bucket.key)")
                } } }
        }.frame(height: 144).padding(.bottom, 10)
    }
    private func bucketDetails(_ bucket: StatsOverview.Bucket) -> some View {
        let grouped = Dictionary(grouping: bucket.events, by: \.titleId)
        let ids = grouped.keys.sorted { a, b in (grouped[a]?.compactMap { DiaryDate.parse($0.watchedAt) }.max() ?? .distantPast) > (grouped[b]?.compactMap { DiaryDate.parse($0.watchedAt) }.max() ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Text(bucket.description).font(.system(size: 15, weight: .bold)); Spacer(); Button("Close") { selectedBucket = nil }.font(.system(size: 13)) }
            if ids.isEmpty { caption("No watches logged in this period.") }
            ScrollView(.horizontal) { HStack(alignment: .top, spacing: 12) { ForEach(ids, id: \.self) { id in if let title = store.title(id) {
                VStack(alignment: .leading, spacing: 6) { NavigationLink(value: id) { PosterCard(title: title) }.buttonStyle(.plain); caption("\(grouped[id]?.count ?? 0) \(grouped[id]?.count == 1 ? "watch" : "watches")", size: 12) }.frame(width: 112)
            } } } }.scrollIndicators(.hidden)
        }
    }
    private func streaks(_ value: StatsOverview.Streaks) -> some View {
        let maxCount = max(1, value.heatmap.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            heading("Streaks")
            HStack(alignment: .top, spacing: 8) { metric("\(value.current) \(value.current == 1 ? "day" : "days")", "Current streak"); metric("\(value.longest) \(value.longest == 1 ? "day" : "days")", "Longest streak"); metric("\(value.activeDays) of \(value.elapsedDays)", "Active days") }
            HStack(spacing: 4) { ForEach(0..<12, id: \.self) { column in
                VStack(spacing: 4) { ForEach(0..<7, id: \.self) { row in
                    let day = value.heatmap[column * 7 + row]
                    NavigationLink(value: HistoryRoute(day: localDay(day.date))) { RoundedRectangle(cornerRadius: 3).fill(heatColor(day.count, maxCount)).frame(height: 14).opacity(day.future ? 0.25 : 1) }.buttonStyle(.plain).disabled(day.future).accessibilityLabel("\(day.date): \(day.count) watches")
                } }.frame(maxWidth: .infinity)
            } }
            HStack { Text("Last 12 weeks"); Spacer(); Text("Less"); ForEach(0..<5, id: \.self) { level in RoundedRectangle(cornerRadius: 2).fill(heatColor(level, 4)).frame(width: 10, height: 10) }; Text("More") }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.statsPanel()
    }
    private func backlog(_ value: StatsOverview.Backlog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { heading("Backlog"); Spacer(); CollectionLayoutToggle(grid: $grid, collection: "backlog") }
            GeometryReader { geometry in HStack(spacing: 0) { ForEach(statuses, id: \.self) { status in statusColor(status).frame(width: geometry.size.width * CGFloat(value.counts[status] ?? 0) / CGFloat(max(1, value.total))) } } }.frame(height: 10).clipShape(Capsule()).accessibilityLabel(statuses.map { "\($0.capitalized): \(value.counts[$0] ?? 0)" }.joined(separator: ", "))
            ForEach(statuses, id: \.self) { status in Button { router.library(status) } label: { HStack { Circle().fill(statusColor(status)).frame(width: 8, height: 8); Text(status.capitalized); Spacer(); Text("\(value.counts[status] ?? 0)").bold() }.font(.system(size: 13)).foregroundStyle(.white) }.buttonStyle(.plain) }
            HStack(alignment: .top) { VStack(alignment: .leading, spacing: 5) { caption("Planned runtime", size: 12); Text(DiaryDate.duration(value.plannedMinutes)).font(.system(size: 24, weight: .bold)).foregroundStyle(.tint); caption(value.unknownPlanned > 0 ? "\(value.unknownPlanned) titles lack runtime or complete episode data" : "Estimated from known, aired content", size: 11) }; Spacer(minLength: 4); Button("Open planned") { router.library("planned") }.font(.system(size: 12, weight: .semibold)).padding(.vertical, 10) }.padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 4) { Text("In progress").font(.system(size: 15, weight: .bold)); caption("Shortest to finish first") }
            if value.inProgress.isEmpty { caption("No movies or shows in progress.") }
            CollectionLayout(grid: grid) { ForEach(Array(value.inProgress.prefix(progressLimit))) { item in NavigationLink(value: item.id) { progressRow(item) }.buttonStyle(.plain) } }
            if progressLimit < value.inProgress.count { Button("Show more in progress") { progressLimit += 5 }.font(.system(size: 13, weight: .semibold)) }
            VStack(alignment: .leading, spacing: 5) { Text("No progress in 30+ days").font(.system(size: 15, weight: .bold)); caption("Pick them back up or mark them dropped") }.padding(.top, 10)
            CollectionLayout(grid: grid) { ForEach(Array(value.stale.prefix(staleLimit))) { item in VStack(alignment: .leading, spacing: 8) { NavigationLink(value: item.id) { VStack(alignment: .leading, spacing: 4) { Text(item.title.name).font(.system(size: 13, weight: .bold)); caption("Last watched \(item.daysSince ?? 0) days ago", size: 11) } }.buttonStyle(.plain); Spacer(); Button("Drop") { Task { await store.setStatus(item.title, status: "dropped") } }.font(.system(size: 12, weight: .semibold)).disabled(store.busy) } } }
            if value.stale.isEmpty { caption("No stalled titles with a known watch date.") }
            if staleLimit < value.stale.count { Button("Show more") { staleLimit += 5 }.font(.system(size: 13, weight: .semibold)) }
        }.statsPanel()
    }
    private func progressRow(_ item: StatsOverview.Progress) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Artwork(path: item.title.poster, title: item.title.name).frame(width: grid ? nil : 40, height: grid ? 150 : 60).frame(maxWidth: grid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                InlineFlowLayout { Text(item.title.name).font(.system(size: 13, weight: .bold)); Spacer(minLength: 4); caption(item.remainingMinutes.map { DiaryDate.duration($0) + " left" } ?? "Time unknown", size: 11) }
                caption(item.title.isSeries ? item.catalogueKnown ? "\(item.watched) of \(item.total) aired episodes · \(item.remaining) to go" : "Episode data incomplete · open to load details" : "Movie", size: 11)
                ProgressView(value: item.percent, total: 100)
            }
        }
    }
    private func genres(_ value: StatsOverview.Genres) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Genre mix"); caption("Share of your \(value.total) watched movies & shows with each genre")
            ForEach(Array(value.items.prefix(expandedGenres ? value.items.count : 5))) { item in Button { router.libraryGenre(item.genre) } label: { genreRow(item.genre, count: item.count, share: item.share) }.buttonStyle(.plain) }
            if value.items.count > 5 { Button { expandedGenres.toggle() } label: { genreRow(expandedGenres ? "Show top 5" : "All other genres", count: value.otherCount, share: value.otherShare) }.buttonStyle(.plain).accessibilityValue(expandedGenres ? "Expanded" : "Collapsed") }
            caption("Titles can have several genres, so these shares can add up to more than 100%.", size: 12)
            if value.items.isEmpty { caption("No watched genres yet.") }
        }.statsPanel()
    }
    private func genreRow(_ name: String, count: Int, share: Double) -> some View { VStack(spacing: 6) { HStack { Text(name).font(.system(size: 13, weight: .bold)); Spacer(); caption("\(Int(share.rounded()))% · \(count) \(count == 1 ? "title" : "titles")", size: 12) }; ProgressView(value: share, total: 100) }.foregroundStyle(.white) }
    private func heading(_ text: String) -> some View { Text(text).font(.system(size: 18, weight: .bold)) }
    private func caption(_ text: String, size: CGFloat = 13) -> some View { Text(text).font(.system(size: size)).foregroundStyle(.secondary) }
    private func total(_ minutes: Int) -> some View { Text(DiaryDate.duration(minutes)).font(.system(size: 32, weight: .bold)).foregroundStyle(.tint).tracking(-1.6).monospacedDigit() }
    private func metric(_ value: String, _ label: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 19, weight: .bold)).minimumScaleFactor(0.7).lineLimit(1); caption(label, size: 11) }.frame(maxWidth: .infinity, alignment: .leading) }
    private func heatColor(_ count: Int, _ maxCount: Int) -> Color { count == 0 ? Color.white.opacity(0.06) : theme.accent.opacity(Double(max(1, Int(ceil(Double(count) / Double(maxCount) * 4)))) / 4) }
    private func localDay(_ value: String) -> Date { let fields = value.split(separator: "-").compactMap { Int($0) }; return fields.count == 3 ? DiaryDate.calendar().date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2], hour: 12)) ?? store.now : store.now }
    private var statuses: [String] { ["planned", "watching", "completed", "dropped"] }
    private func statusColor(_ status: String) -> Color { status == "dropped" ? Color(webHex: "#646075") : theme.accent.opacity(status == "planned" ? 0.65 : status == "watching" ? 0.85 : 1) }
}

private extension View {
    func statsPanel() -> some View { diaryPanel(padding: 20, radius: 22) }
}

private struct StatsRangeSelector: View {
    @Binding var selection: Period
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ranges: [Period] = [.week, .month, .ninetyDays, .year, .all]
    var body: some View {
        HStack(spacing: 3) { ForEach(ranges) { range in
            Button { selection = range } label: { Text(label(range)).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 38) }.buttonStyle(DiaryPressStyle()).foregroundStyle(selection == range ? theme.ink : Color(webHex: "#c5c0cf")).accessibilityAddTraits(selection == range ? .isSelected : [])
        } }.frame(height: 38).background(alignment: .leading) {
            GeometryReader { geometry in
                if let index = ranges.firstIndex(of: selection) {
                    let width = max(0, (geometry.size.width - 12) / 5)
                    Capsule().fill(theme.accent).frame(width: width, height: 38).offset(x: CGFloat(index) * (width + 3))
                }
            }
        }.padding(3).background { DiaryControlSurface(shape: Capsule(), field: true) }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: selection)
    }
    private func label(_ value: Period) -> String { switch value { case .week: "7D"; case .month: "30D"; case .ninetyDays: "90D"; case .year: "1Y"; case .all: "All"; case .today: "Today" } }
}
