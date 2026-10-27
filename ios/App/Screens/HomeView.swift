import SwiftUI
import TwilDiaryCore

struct HomeView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = Date.now
    @State private var showSearch = false
    @State private var upcomingLimit = 3
    /// Changes only when vertical scrolling starts or settles, never per frame.
    @State private var scrolling = false
    @AppStorage("homeHistoryGrid") private var historyGrid = false
    @AppStorage("upcomingGrid") private var upcomingGrid = false
    var body: some View {
        let now = store.isPreview ? store.now : clock
        let projection = store.homeProjection(at: now)
        let overview = projection.overview
        let watching = projection.watching
        let recent = projection.recent
        VStack(spacing: 0) {
            PageHeader(name: "TwilDiary", onSearch: { showSearch.toggle() })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    if !watching.isEmpty { VStack(spacing: 10) {
                        SectionHeading(name: "Pick up where you left off") { Button("Glance →") { router.selectedTab = .glance } }
                        ContinueWatchingCarousel(titles: watching, automaticAllowed: !showSearch && !scrolling)
                    } }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            NavigationLink(value: AppDestination.explore) { shortcut("Explore", "compass") }.accessibilityIdentifier("explore-shortcut")
                            Button { router.library("queue") } label: { shortcut("Queue", "download") }.accessibilityIdentifier("queue-shortcut")
                            Button { router.library("disk") } label: { shortcut("Disk Map", "hard-drive") }
                            Button { router.files() } label: { shortcut("Locations", "folder") }
                            NavigationLink(value: AppDestination.scanner) { shortcut("Fix mismatches", "scan-search") }.accessibilityIdentifier("scanner-shortcut")
                        }.buttonStyle(.plain)
                    }.scrollIndicators(.hidden)
                    VStack(spacing: 10) {
                        SectionHeading(name: "This week") { Button("Stats →") { router.statsToday() }.accessibilityIdentifier("home-stats") }
                        weekPanel(overview, now: now)
                    }
                    VStack(spacing: 10) {
                        SectionHeading(name: "Up next") { Button("Planned →") { router.library("planned") } }
                        Button { router.presentRandomPick(overview.planned.map(\.id)) } label: {
                            HStack(spacing: 12) {
                                DiaryIcon(name: "shuffle", size: 23)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Pick for me").font(.system(size: 15, weight: .semibold))
                                    Text(overview.planned.isEmpty ? "Add a planned movie or show to get a pick" : "Choose from \(overview.planned.count) unwatched planned titles").font(.system(size: 12)).foregroundStyle(.secondary)
                                }; Spacer(minLength: 0)
                            }.padding(14).background(theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent.opacity(0.28)))
                        }.buttonStyle(.plain).disabled(overview.planned.isEmpty).accessibilityIdentifier("home-pick-planned")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(overview.planned.prefix(3)) { title in
                                VStack(alignment: .leading, spacing: 4) {
                                    NavigationLink(value: title.id) { PosterCard(title: title, personalRating: true) }.buttonStyle(.plain)
                                    Text(title.categoryName + (title.runtimeMinutes.map { " · " + DiaryDate.duration($0) + (title.isSeries ? " / ep" : "") } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 8)
                    }
                    VStack(spacing: 10) {
                        SectionHeading(name: "New episodes") { CollectionLayoutToggle(grid: $upcomingGrid, collection: "upcoming"); Button("Glance →") { router.selectedTab = .glance } }
                        CollectionLayout(grid: upcomingGrid) { ForEach(overview.upcoming.prefix(upcomingLimit)) { item in
                            NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) { upcomingRow(item) }.buttonStyle(.plain).accessibilityIdentifier("home-upcoming-" + item.title.id)
                        } }
                        if overview.upcoming.isEmpty { Text("No upcoming air dates in your library for the next 30 days.").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).diaryPanel() }
                        if overview.upcoming.count > upcomingLimit { Button("Show more episodes") { upcomingLimit += 5 } }
                        Text("Based on your saved episode dates. Air dates may change.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !recent.isEmpty { VStack(spacing: 10) {
                        SectionHeading(name: "Recently watched") { CollectionLayoutToggle(grid: $historyGrid, collection: "home-history"); NavigationLink("All history →", value: AppDestination.history) }
                        CollectionLayout(grid: historyGrid) { ForEach(recent) { entry in
                            NavigationLink(value: entry.title.id) { HistoryRow(entry: entry, grid: historyGrid) }.buttonStyle(.plain)
                        } }
                    } }
                }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 24)
            }.onScrollPhaseChange { _, phase in
                // The automatic carousel step must not animate mid-fling under the finger.
                let active = phase != .idle
                if scrolling != active { scrolling = active }
            }
            .refreshable { clock = store.now; await store.refresh() }
        }.onChange(of: scenePhase) { _, phase in if phase == .active { clock = store.now } }
            .task {
                clock = store.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    clock = store.now
                }
            }
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    private func shortcut(_ name: String, _ icon: String) -> some View {
        HStack(spacing: 6) { DiaryIcon(name: icon, size: 17); Text(name).font(.system(size: 12, weight: .semibold)) }.foregroundStyle(Color(webHex: "#c5c0cf")).padding(.horizontal, 14).frame(height: 42).background { DiaryControlSurface(shape: Capsule()) }
    }
    private func upcomingRow(_ item: HomeOverview.Upcoming) -> some View {
        let layout = upcomingGrid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Artwork(path: item.title.poster, title: item.title.name, initialsOnly: false).frame(width: upcomingGrid ? nil : 42, height: upcomingGrid ? 150 : 62).frame(maxWidth: upcomingGrid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) { Text(item.title.name).font(.system(size: 14, weight: .semibold)).lineLimit(2); Text("S\(item.episode.season) E\(item.episode.number)").font(.system(size: 12)).foregroundStyle(.secondary) }
            if !upcomingGrid { Spacer(minLength: 4) }
            VStack(alignment: upcomingGrid ? .leading : .trailing, spacing: 5) { Text(item.daysAway == 0 ? "Today" : item.daysAway == 1 ? "Tomorrow" : "In \(item.daysAway) days").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint); Text(item.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.foregroundStyle(.primary).diaryPanel()
    }
    private func weekPanel(_ overview: HomeOverview, now: Date) -> some View {
        let maximum = max(1, overview.days.map(\.minutes).max() ?? 0)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) { metric(DiaryDate.duration(overview.minutes), "Watch time", accent: true); metric(String(overview.watches), "Watches"); metric("\(overview.streak) \(overview.streak == 1 ? "day" : "days")", "Current streak") }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) { ForEach(overview.days) { day in
                NavigationLink(value: HistoryRoute(day: day.date)) {
                    VStack(spacing: 6) {
                        Text(day.date, format: .dateTime.weekday(.narrow)).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(day.date, format: .dateTime.day()).font(.system(size: 16, weight: .semibold)).foregroundStyle(DiaryDate.calendar().isDate(day.date, inSameDayAs: now) ? theme.accent : .primary)
                        VStack { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 3).fill(day.minutes > 0 ? theme.accent : .white.opacity(0.12)).frame(width: 10, height: day.minutes > 0 ? max(4, 30 * CGFloat(day.minutes) / CGFloat(maximum)) : 2) }.frame(height: 30)
                    }.frame(maxWidth: .infinity).foregroundStyle(.primary).opacity(day.future ? 0.4 : 1)
                }.buttonStyle(.plain).disabled(day.future).accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(day.count) watches")
            } }
            if overview.unknownDates > 0 || overview.missingRuntime > 0 { Text("Dated watches only. Missing runtimes are excluded from watch time.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3) }
        }.diaryPanel()
    }
    private func metric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.system(size: 22, weight: .bold)).tracking(-0.7).foregroundStyle(accent ? theme.accent : .primary).lineLimit(1).minimumScaleFactor(0.7); Text(label).font(.system(size: 11)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QueueView: View {
    @Environment(DiaryStore.self) private var store
    var planned = false
    var body: some View {
        ScrollView { LazyVStack { ForEach(store.workspace.activeTitles.filter { planned ? $0.status == "planned" : $0.queued == true }) { title in NavigationLink(value: title.id) { titleRow(title) }.buttonStyle(.plain) } }.padding(14) }.navigationTitle(planned ? "Planned" : "Queue").toolbar(.visible, for: .navigationBar)
    }
}
