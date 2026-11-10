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
    @State private var upcomingLimit = 3
    /// Changes only when vertical scrolling starts or settles, never per frame.
    @State private var scrolling = false
    @SceneStorage("home.continue.title") private var continueSelection = ""
    @AppStorage("homeHistoryGrid") private var historyGrid = false
    @AppStorage("upcomingGrid") private var upcomingGrid = true
    var body: some View {
        let now = store.isPreview ? store.now : clock
        let request = store.homeProjectionRequest(at: now)
        ZStack {
            // A missing projection is still loading. Only a loaded diary with no
            // watching titles should show the shorter Home header.
            if let projection = store.homeProjection {
                dashboard(projection, now: now)
            } else {
                ProgressView().accessibilityLabel("Opening your diary")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: request) { await store.prepareHomeProjection(request) }
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
    private func dashboard(_ projection: DiaryStore.HomeProjection, now: Date) -> some View {
        let overview = projection.overview
        let watching = projection.watching
        let recent = projection.recent
        return EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 0) {
                if watching.isEmpty { header(overArtwork: false) } else { continueSection(watching) }
                VStack(alignment: .leading, spacing: 32) {
                    // Explore is systematic discovery; Canvas is for browsing artwork at random.
                    HStack(spacing: 10) {
                        NavigationLink(value: AppDestination.explore) { HomeShortcut(name: "Explore", icon: "compass") }.buttonStyle(.springPress).accessibilityIdentifier("explore-shortcut")
                        NavigationLink(value: AppDestination.canvas) { HomeShortcut(name: "Canvas", icon: "layout-grid") }.buttonStyle(.springPress).accessibilityIdentifier("canvas-shortcut")
                    }.padding(.bottom, -0)
                    VStack(alignment: .leading, spacing: 16) {
                        HomeSectionHeader(title: "This week") {
                            Button { router.statsToday() } label: { HomeRoundIcon() }.buttonStyle(.plain).accessibilityLabel("Stats").accessibilityIdentifier("home-stats")
                        }
                        HomeWeekCard(overview: overview, now: now)
                    }
                    if !overview.planned.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HomeSectionHeader(title: "Up next") {
                                Button { router.library("planned") } label: { HomeRoundIcon() }.buttonStyle(.plain).accessibilityLabel("Planned").accessibilityIdentifier("home-upnext-more")
                            }
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(overview.planned.prefix(12)) { title in
                                        NavigationLink(value: title.id) {
                                            HomePoster(artwork: title.poster, name: title.name,
                                                       subtitle: title.isSeries ? title.categoryName : (["Movie"] + [title.runtimeMinutes.map(DiaryDate.duration)].compactMap { $0 }).joined(separator: " · "))
                                                .zoomSource(ZoomID.title(title.id))
                                        }.buttonStyle(.springPress).accessibilityIdentifier("home-planned-" + title.id).shelfTransition()
                                    }
                                }.scrollTargetLayout()
                            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                        }
                    }
                    let seeds = Self.recommendationSeeds(recent)
                    if !seeds.isEmpty { HomeRecommendedShelf(seeds: seeds) }
                    // Recently hearted cast and characters together, right under Up next; › opens them by kind.
                    let favourites = FavouritesStore.shared.items
                    if !favourites.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HomeSectionHeader(title: "Favourites", icon: "heart.fill") {
                                NavigationLink(value: AppDestination.favourites) { HomeRoundIcon() }.buttonStyle(.plain).accessibilityLabel("All favourites").accessibilityIdentifier("home-favourites")
                            }
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(favourites.prefix(12)) { item in FavouriteLink(item: item, homeCard: true).shelfTransition() }
                                }.scrollTargetLayout()
                            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HomeSectionHeader(title: "New episodes") {
                            Button { upcomingGrid.toggle() } label: { HomeRoundIcon(system: upcomingGrid ? "list.bullet" : "square.grid.2x2", selected: upcomingGrid) }
                                .buttonStyle(.plain).accessibilityLabel(upcomingGrid ? "Show as list" : "Show as cards").accessibilityValue(upcomingGrid ? "Cards" : "List").accessibilityIdentifier("upcoming-layout")
                            NavigationLink(value: AppDestination.calendar) { HomeRoundIcon() }.buttonStyle(.plain).accessibilityLabel("Airing calendar").accessibilityIdentifier("home-calendar-more")
                        }
                        if overview.upcoming.isEmpty {
                            Text("No upcoming air dates in your library for the next 30 days.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary)
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20))
                                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                        } else if upcomingGrid {
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(overview.upcoming.prefix(12)) { item in
                                        NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) { HomeNewEpisodeCard(item: item) }
                                            .buttonStyle(.springPress).accessibilityIdentifier("home-upcoming-" + item.title.id)
                                    }
                                }.scrollTargetLayout()
                            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                        } else {
                            VStack(spacing: 10) {
                                ForEach(overview.upcoming.prefix(upcomingLimit)) { item in
                                    NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season)) { HomeNewEpisodeRow(item: item) }
                                        .buttonStyle(.plain).accessibilityIdentifier("home-upcoming-" + item.title.id)
                                }
                                if overview.upcoming.count > upcomingLimit { Button("Show more episodes") { upcomingLimit += 5 }.font(.system(size: 14, weight: .semibold)) }
                            }
                        }
                    }
                    let groups = RecentWatchGroup.make(recent, limit: 3)
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HomeSectionHeader(title: "Recently watched") {
                                Button { historyGrid.toggle() } label: { HomeRoundIcon(system: historyGrid ? "list.bullet" : "square.grid.2x2", selected: historyGrid) }
                                    .buttonStyle(.plain).accessibilityLabel(historyGrid ? "Show as list" : "Show as cards").accessibilityValue(historyGrid ? "Cards" : "List").accessibilityIdentifier("home-history-layout")
                                NavigationLink(value: AppDestination.history) { HomeRoundIcon() }.buttonStyle(.plain).accessibilityLabel("All history").accessibilityIdentifier("home-history-more")
                            }
                            if historyGrid {
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(groups) { group in
                                            NavigationLink(value: group.title.id) { HomeRecentCard(group: group) }.buttonStyle(.springPress).accessibilityIdentifier("home-history-event-" + group.id)
                                        }
                                    }
                                }.scrollIndicators(.hidden).scrollClipDisabled()
                            } else {
                                VStack(spacing: 10) {
                                    ForEach(groups) { group in
                                        NavigationLink(value: group.title.id) {
                                            HomeRow(artwork: group.title.backdrop ?? group.title.poster, name: group.title.name, chip: group.episodeText,
                                                    detail: group.count > 1 ? group.count.counted("episode", "episodes") : nil,
                                                    date: group.date?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                        }.buttonStyle(.plain).accessibilityIdentifier("home-history-event-" + group.id)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.top, watching.isEmpty ? 8 : 30).padding(.bottom, 24)
            }
        }
        .contentMargins(.bottom, 90, for: .scrollContent)
        .onScrollPhaseChange { _, phase in
            // The automatic carousel step must not animate mid-fling under the finger.
            let active = phase != .idle
            if scrolling != active { scrolling = active }
        }
        .refreshable { clock = store.now; await store.refresh(); await FavouritesStore.shared.sync(store: store) }
    }
    /// True full screen: the whole header scrolls away with the artwork.
    private func header(overArtwork: Bool) -> some View { PageHeader(name: "TwilDiary", overArtwork: overArtwork) }
    /// The selected title's backdrop fills the top of the page, under the status bar and header,
    /// and fades into the page so the text below it stays readable.
    private func continueSection(_ titles: [MediaTitle]) -> some View {
        let current = titles.first { $0.id == continueSelection } ?? titles[0]
        return VStack(alignment: .leading, spacing: 0) {
            header(overArtwork: true)
            Spacer(minLength: 72)
            // "CONTINUE WATCHING" sits inside each page, right above its title.
            ContinueWatchingCarousel(titles: titles, selection: $continueSelection, automaticAllowed: !scrolling).padding(.horizontal, 8)
        }.background(alignment: .top) {
            // The art fills the section and reaches just under the status bar. It used to reach 140 pt
            // higher, which enlarged a 16:9 backdrop about 2x and cut off half of it; with only the
            // status bar's height it is enlarged about 1.7x, so more of the picture shows.
            GeometryReader { proxy in
            Artwork(path: current.backdrop ?? current.poster, title: current.name)
                .frame(width: proxy.size.width, height: proxy.size.height + Self.artLift)
                .overlay {
                    // Design scrim: 45 % black at the top, clear by 38 %, 50 % at 70 %, solid black at the bottom.
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .black.opacity(0), location: 0.38),
                                           .init(color: .black.opacity(0.5), location: 0.7), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .offset(y: -Self.artLift).modifier(StretchOnPull()).id(current.id).transition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: current.id)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    /// Recently watched titles that TMDB knows, newest first, each once.
    private static func recommendationSeeds(_ recent: [HistoryEntry]) -> [MediaTitle] {
        var seen = Set<String>(), seeds: [MediaTitle] = []
        for entry in recent where entry.title.tmdbId != nil && seen.insert(entry.title.id).inserted { seeds.append(entry.title) }
        return seeds
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

