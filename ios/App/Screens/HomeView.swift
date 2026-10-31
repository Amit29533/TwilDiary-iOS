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
    @State private var mediaHeader = CompactHeaderState()
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
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(overview.planned.prefix(12)) { title in
                                    NavigationLink(value: title.id) { HomePlannedCard(title: title).zoomSource(ZoomID.title(title.id)) }
                                        .buttonStyle(.plain).accessibilityIdentifier("home-planned-" + title.id)
                                        .containerRelativeFrame(.horizontal) { width, _ in min(144, max(96, (width - 24) / 3.15)) }
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                    }.padding(.horizontal, -4)
                        .modifier(HomeMediaBoundary(state: mediaHeader, enabled: true))
                    }
                    // Recently hearted cast and characters together, right under Up next; › opens them by kind.
                    let favourites = FavouritesStore.shared.items
                    if !favourites.isEmpty { VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill").foregroundStyle(theme.accent).accessibilityHidden(true)
                            Text("Favourites").font(.system(size: 22, weight: .bold)).tracking(-0.6)
                            Spacer(minLength: 4)
                            NavigationLink(value: AppDestination.favourites) { RoundTool(icon: "chevron-right", size: 36) }
                                .buttonStyle(.springPress).accessibilityLabel("All favourites").accessibilityIdentifier("home-favourites")
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(favourites.prefix(12)) { item in
                                    FavouriteLink(item: item, homeCard: true)
                                        .containerRelativeFrame(.horizontal) { width, _ in min(144, max(96, (width - 24) / 3.15)) }
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                    }.padding(.horizontal, -4).modifier(HomeMediaBoundary(state: mediaHeader, enabled: overview.planned.isEmpty)) }
                    VStack(spacing: 12) {
                        heading("New episodes") { CollectionLayoutToggle(grid: $upcomingGrid, collection: "upcoming", gridName: "cards"); Button("Glance →") { router.selectedTab = .glance } }
                        HomeActivityLayout(cards: upcomingGrid) { ForEach(overview.upcoming.prefix(upcomingLimit)) { item in
                            NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) {
                                HomeEpisodeCard(model: HomeEpisodeCardModel(upcoming: item), cards: upcomingGrid)
                            }.buttonStyle(.plain).accessibilityIdentifier("home-upcoming-" + item.title.id)
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
                    }.padding(.horizontal, -4).modifier(HomeMediaBoundary(state: mediaHeader, enabled: overview.planned.isEmpty && favourites.isEmpty))
                    if !recent.isEmpty { VStack(spacing: 12) {
                        heading("Recently watched") { CollectionLayoutToggle(grid: $historyGrid, collection: "home-history", gridName: "cards"); NavigationLink("All history →", value: AppDestination.history) }
                        HomeActivityLayout(cards: historyGrid) { ForEach(recent) { entry in
                            NavigationLink(value: entry.title.id) {
                                HomeEpisodeCard(model: HomeEpisodeCardModel(history: entry), cards: historyGrid)
                            }.buttonStyle(.plain).accessibilityIdentifier("home-history-event-" + entry.id)
                        } }
                    }.padding(.horizontal, -4) }
                }.padding(.horizontal, 16).padding(.top, watching.isEmpty ? 8 : 20).padding(.bottom, 24)
            }
        }.coordinateSpace(name: "home-scroll")
        .contentMargins(.bottom, 90, for: .scrollContent)
        .overlay(alignment: .top) { HomeMediaHeader(state: mediaHeader, onSearch: { showSearch.toggle() }) }
        .onScrollPhaseChange { _, phase in
            // The automatic carousel step must not animate mid-fling under the finger.
            let active = phase != .idle
            if scrolling != active { scrolling = active }
        }
        .refreshable { clock = store.now; await store.refresh(); await FavouritesStore.shared.sync(store: store) }
        // Favourites are kept on the server; one small read per session brings them up to date.
        .task(id: store.sessionRevision) { await FavouritesStore.shared.sync(store: store) }
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
            // The art fills the section and reaches just under the status bar. It used to reach 140 pt
            // higher, which enlarged a 16:9 backdrop about 2x and cut off half of it; with only the
            // status bar's height it is enlarged about 1.7x, so more of the picture shows.
            GeometryReader { proxy in
            Artwork(path: current.backdrop ?? current.poster, title: current.name)
                .frame(width: proxy.size.width, height: proxy.size.height + Self.artLift)
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.05), location: 0.28),
                                           .init(color: .black.opacity(0.35), location: 0.62), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .overlay { LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .center) }
                .offset(y: -Self.artLift).modifier(StretchOnPull()).id(current.id).transition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: current.id)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    /// Just enough to reach under the status bar; pulling down stretches the art instead of revealing a gap.
    private static let artLift: CGFloat = 64
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

/// Pulling the page down to refresh zooms the artwork from its bottom edge: it grows by exactly the
/// pull, so its top stays at the top of the screen instead of sliding down and leaving a gap.
private struct StretchOnPull: ViewModifier {
    @State private var restingY: CGFloat?
    func body(content: Content) -> some View {
        let rest = restingY
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView(axis: .vertical)).minY } action: { y in if restingY == nil { restingY = y } }
            .visualEffect { view, proxy in
                let height = proxy.size.height
                guard let rest, height > 0 else { return view.scaleEffect(1, anchor: .bottom) }
                let pull = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY - rest)
                return view.scaleEffect(1 + pull / height, anchor: .bottom)
            }
    }
}

struct QueueView: View {
    @Environment(DiaryStore.self) private var store
    var planned = false
    var body: some View {
        ScrollView { LazyVStack { ForEach(store.workspace.activeTitles.filter { planned ? $0.status == "planned" : $0.queued == true }) { title in NavigationLink(value: title.id) { titleRow(title) }.buttonStyle(.plain) } }.padding(14) }.navigationTitle(planned ? "Planned" : "Queue").toolbar(.visible, for: .navigationBar)
    }
}
