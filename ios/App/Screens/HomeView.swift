import SwiftUI
import TwilDiaryCore

/// Owner's Home design: a full-bleed Continue watching backdrop behind the header, a wide
/// Explore button, This week, Up next posters, New episodes and Recently watched.
struct HomeView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = Date.now
    @State private var showSearch = false
    @State private var upcomingLimit = 3
    /// Changes only when vertical scrolling starts or settles, never per frame.
    @State private var scrolling = false
    @SceneStorage("home.continue.title") private var continueSelection = ""
    @AppStorage("homeHistoryGrid") private var historyGrid = false
    @AppStorage("upcomingGrid") private var upcomingGrid = false
    var body: some View {
        let now = store.isPreview ? store.now : clock
        let projection = store.homeProjection(at: now)
        let overview = projection.overview
        let watching = projection.watching
        let recent = projection.recent
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // While searching, the plain header keeps the field and its results at the top.
                if watching.isEmpty || showSearch { header(overArtwork: false) } else { continueSection(watching) }
                VStack(alignment: .leading, spacing: 28) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    // Explore is systematic discovery; Canvas is for browsing artwork at random.
                    HStack(spacing: 10) {
                        NavigationLink(value: AppDestination.explore) { discoverButton("Explore", icon: "compass") }.buttonStyle(.plain).accessibilityIdentifier("explore-shortcut")
                        NavigationLink(value: AppDestination.canvas) { discoverButton("Canvas", icon: "layout-grid") }.buttonStyle(.plain).accessibilityIdentifier("canvas-shortcut")
                    }
                    VStack(spacing: 12) {
                        heading("This week") { Button("Stats →") { router.statsToday() }.accessibilityIdentifier("home-stats") }
                        weekPanel(overview, now: now)
                    }
                    if !overview.planned.isEmpty { VStack(spacing: 12) {
                        heading("Up next") { Button("Planned →") { router.library("planned") } }
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(overview.planned.prefix(12)) { title in
                                    NavigationLink(value: title.id) { plannedTile(title).zoomSource(ZoomID.title(title.id)) }.buttonStyle(.springPress).accessibilityIdentifier("home-planned-" + title.id)
                                }
                            }
                        }.scrollIndicators(.hidden).scrollClipDisabled()
                    } }
                    VStack(spacing: 12) {
                        heading("New episodes") { CollectionLayoutToggle(grid: $upcomingGrid, collection: "upcoming"); Button("Glance →") { router.selectedTab = .glance } }
                        CollectionLayout(grid: upcomingGrid) { ForEach(overview.upcoming.prefix(upcomingLimit)) { item in
                            NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) { upcomingRow(item) }.buttonStyle(.plain).accessibilityIdentifier("home-upcoming-" + item.title.id)
                        } }
                        if overview.upcoming.isEmpty {
                            HStack(spacing: 16) {
                                DiaryIcon(name: "calendar-days", size: 22).foregroundStyle(theme.accent)
                                Text("No upcoming air dates in your library for the next 30 days.").font(.system(size: 15)).foregroundStyle(Color(webHex: "#c5c0cf")).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 6).diaryPanel(radius: 18)
                        }
                        if overview.upcoming.count > upcomingLimit { Button("Show more episodes") { upcomingLimit += 5 } }
                        Text("Based on your saved episode dates. Air dates may change.").font(.system(size: 13)).foregroundStyle(Color(webHex: "#a09aa9")).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !recent.isEmpty { VStack(spacing: 12) {
                        heading("Recently watched") { CollectionLayoutToggle(grid: $historyGrid, collection: "home-history"); NavigationLink("All history →", value: AppDestination.history) }
                        CollectionLayout(grid: historyGrid) { ForEach(recent) { entry in
                            NavigationLink(value: entry.title.id) {
                                Group { if historyGrid { HistoryRow(entry: entry, grid: true) } else { recentRow(entry) } }.zoomSource(ZoomID.title(entry.title.id))
                            }.buttonStyle(.springPress)
                        } }
                    } }
                }.padding(.horizontal, 16).padding(.top, watching.isEmpty ? 8 : 20).padding(.bottom, 24)
            }
        }.overlay(alignment: .top) { PageHeader(name: "TwilDiary", onSearch: { showSearch.toggle() }, overArtwork: true, part: .buttons) }
        .onScrollPhaseChange { _, phase in
            // The automatic carousel step must not animate mid-fling under the finger.
            let active = phase != .idle
            if scrolling != active { scrolling = active }
        }
        .refreshable { clock = store.now; await store.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { clock = store.now } }
        .task {
            clock = store.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                clock = store.now
            }
        }
    }
    /// The scrolling title row; the logo and search stay pinned above it (see body).
    private func header(overArtwork: Bool) -> some View { PageHeader(name: "TwilDiary", onSearch: { showSearch.toggle() }, overArtwork: overArtwork, part: .title) }
    /// The selected title's backdrop fills the top of the page, under the status bar and header,
    /// and fades into the page so the text below it stays readable.
    private func continueSection(_ titles: [MediaTitle]) -> some View {
        let current = titles.first { $0.id == continueSelection } ?? titles[0]
        return VStack(alignment: .leading, spacing: 0) {
            header(overArtwork: true)
            Spacer(minLength: 72)
            // "CONTINUE WATCHING" sits inside each page, right above its title.
            ContinueWatchingCarousel(titles: titles, selection: $continueSelection, automaticAllowed: !showSearch && !scrolling).padding(.horizontal, 8)
        }.background(alignment: .top) {
            Artwork(path: current.backdrop ?? current.poster, title: current.name)
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.05), location: 0.28),
                                           .init(color: .black.opacity(0.35), location: 0.62), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .overlay { LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .center) }
                .id(current.id).transition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: current.id)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    private func discoverButton(_ name: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            DiaryIcon(name: icon, size: 16).foregroundStyle(theme.ink).frame(width: 30, height: 30).background(theme.accent, in: Circle())
            Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
            Spacer(minLength: 0)
        }.frame(height: 54).frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { DiaryIcon(name: "chevron-right", size: 15).foregroundStyle(theme.accent).padding(.trailing, 16) }
            .background(theme.accent.opacity(0.1), in: Capsule()).overlay(Capsule().strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.5))
            .contentShape(Capsule())
    }
    private func heading<Trailing: View>(_ name: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 22, weight: .bold)).tracking(-0.6)
            Spacer(minLength: 4)
            trailing().font(.system(size: 15, weight: .semibold)).tint(theme.accent)
        }.frame(minHeight: 32)
    }
    /// A planned title: poster with its status badge, name, and "Movie · 1h 54m" or "Show".
    private func plannedTile(_ title: MediaTitle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(path: title.poster, title: title.name, initialsOnly: false).frame(width: 88, height: 104).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    DiaryIcon(name: title.statusIconName, size: 15).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(.black.opacity(0.72), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35))).padding(5)
                }
            Text(title.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(title.isSeries ? "Show" : (["Movie"] + [title.runtimeMinutes.map(DiaryDate.duration)].compactMap { $0 }).joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Color(webHex: "#a09aa9")).lineLimit(1)
        }.frame(width: 88, alignment: .leading).accessibilityElement(children: .combine)
    }
    /// Recently watched: artwork, title, "S1 E7" or "Movie", the season's progress and the date.
    private func recentRow(_ entry: HistoryEntry) -> some View {
        let progress = entry.episode.map { store.seasonProgress(entry.title, season: $0.season).fraction }
        return HStack(spacing: 14) {
            Artwork(path: entry.title.backdrop ?? entry.title.poster, title: entry.title.name, initialsOnly: false).frame(width: 84, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7")).lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.episode.map { "S\($0.season) E\($0.number)" } ?? "Movie")
                    if entry.rewatched { DiaryIcon(name: "rotate-ccw", size: 12).foregroundStyle(.tint).accessibilityLabel("Rewatched") }
                }.font(.system(size: 14)).foregroundStyle(Color(webHex: "#a09aa9"))
                if let progress {
                    Capsule().fill(.white.opacity(0.14)).frame(width: 170, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(theme.accent).frame(width: 170 * progress) }.padding(.vertical, 2)
                }
                if let date = DiaryDate.parse(entry.event.watchedAt) {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year())).font(.system(size: 14)).foregroundStyle(Color(webHex: "#a09aa9"))
                }
            }
            Spacer(minLength: 0)
            DiaryIcon(name: "chevron-right", size: 17).foregroundStyle(Color(webHex: "#a09aa9"))
        }.padding(10).background(Color(webHex: "#111115"), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12))).contentShape(Rectangle())
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
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 0) {
                metric(DiaryDate.duration(overview.minutes), "Watch time", accent: true)
                divider
                metric(String(overview.watches), "Watches")
                divider
                metric("\(overview.streak) \(overview.streak == 1 ? "day" : "days")", "Current streak")
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) { ForEach(overview.days) { day in
                NavigationLink(value: HistoryRoute(day: day.date)) {
                    VStack(spacing: 6) {
                        Text(day.date, format: .dateTime.weekday(.narrow)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(day.date, format: .dateTime.day()).font(.system(size: 16, weight: .semibold)).foregroundStyle(DiaryDate.calendar().isDate(day.date, inSameDayAs: now) ? theme.accent : .primary)
                        // Days without watches keep a dim full-height slot, as in the design.
                        VStack { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 4).fill(day.minutes > 0 ? theme.accent : .white.opacity(0.08)).frame(width: 13, height: day.minutes > 0 ? max(8, 30 * CGFloat(day.minutes) / CGFloat(maximum)) : 24) }.frame(height: 30)
                    }.frame(maxWidth: .infinity).foregroundStyle(.primary).opacity(day.future ? 0.45 : 1)
                }.buttonStyle(.plain).disabled(day.future).accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)), \(day.count) watches")
            } }
        }.diaryPanel(radius: 18)
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 44).padding(.horizontal, 14) }
    private func metric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 24, weight: .bold)).tracking(-0.7).foregroundStyle(accent ? theme.accent : .primary).lineLimit(1).minimumScaleFactor(0.7); Text(label).font(.system(size: 13)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QueueView: View {
    @Environment(DiaryStore.self) private var store
    var planned = false
    var body: some View {
        ScrollView { LazyVStack { ForEach(store.workspace.activeTitles.filter { planned ? $0.status == "planned" : $0.queued == true }) { title in NavigationLink(value: title.id) { titleRow(title) }.buttonStyle(.plain) } }.padding(14) }.navigationTitle(planned ? "Planned" : "Queue").toolbar(.visible, for: .navigationBar)
    }
}
