import SwiftUI
import UIKit
import TwilDiaryCore

/// Owner's Home design: a full-bleed Continue watching backdrop behind the header, a wide
/// Explore button, This week, Up next posters, New episodes and Recently watched.
struct HomeView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
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
                    // Your saved Library filters, each a shelf.
                    if !SavedFilters.shared.all.isEmpty { HomeSavedShelves() }
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
                                .cardSurface(20)
                                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                        } else if upcomingGrid {
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(overview.upcoming.prefix(12)) { item in
                                        NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season, focusEpisodes: false)) { HomeNewEpisodeCard(item: item) }
                                            .buttonStyle(.springPress).accessibilityIdentifier("home-upcoming-" + item.title.id)
                                    }
                                }.scrollTargetLayout()
                            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                        } else {
                            VStack(spacing: 10) {
                                ForEach(overview.upcoming.prefix(upcomingLimit)) { item in
                                    NavigationLink(value: SavedTitleRoute(id: item.title.id, season: item.episode.season, focusEpisodes: false)) { HomeNewEpisodeRow(item: item) }
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
        .refreshable { clock = store.now; await store.refresh() }
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
            PullStretchArt(content: Artwork(path: heroArtwork(current), title: current.name).overlay {
                    // Design scrim: 45 % black at the top, clear by 38 %, 50 % at 70 %, solid black at the bottom.
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .black.opacity(0), location: 0.38),
                                           .init(color: .black.opacity(0.5), location: 0.7), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                })
                .task(id: titles.map { heroArtwork($0) ?? "" } + [String(Int(proxy.size.width))]) {
                    // The same size Artwork asks for (its frame here), so each is already decoded.
                    let pixels = Double(max(proxy.size.width, proxy.size.height + Self.artLift) * displayScale)
                    for title in titles where title.id != current.id {
                        guard !Task.isCancelled else { return }
                        if let request = PublicArtworkRequest(path: heroArtwork(title), pixels: pixels) {
                            _ = await PublicArtworkCache.shared.image(request)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height + Self.artLift)
                .offset(y: -Self.artLift).id(current.id).transition(.opacity)
            }
            // On the container (outside the art's identity), so switching titles cross-fades
            // instead of cutting from one picture to the next.
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: current.id)
            .allowsHitTesting(false).accessibilityHidden(true)
        }.nativeHero()
    }
    /// Recently watched titles that TMDB knows, newest first, each once.
    private static func recommendationSeeds(_ recent: [HistoryEntry]) -> [MediaTitle] {
        var seen = Set<String>(), seeds: [MediaTitle] = []
        for entry in recent where entry.title.tmdbId != nil && seen.insert(entry.title.id).inserted { seeds.append(entry.title) }
        return seeds
    }
    /// The picture Home's hero shows for a title: the first backdrop it showed this session.
    /// Each refresh rebuilds the diary, and a title could come back for a moment without its
    /// backdrop (the poster then filled in) or with another copy of it: the hero flashed.
    private func heroArtwork(_ title: MediaTitle) -> String? {
        // Kept per TMDB entry too: a title fixed to another entry shows its new backdrop at once.
        let key = title.id + "|" + (title.tmdbId.map(String.init) ?? "")
        if let kept = Self.heroArt[key] { return kept }
        guard let backdrop = title.backdrop else { return title.poster }
        Self.heroArt[key] = backdrop
        return backdrop
    }
    @MainActor private static var heroArt: [String: String] = [:]
    /// Just enough to reach under the status bar; pulling down stretches the art instead of revealing a gap.
    private static let artLift: CGFloat = 64
}

/// Home's hero art. Pulling the page down to refresh zooms it from its bottom edge by exactly the
/// gap that opens above it, so its top stays at the top of the screen.
///
/// The zoom is set by UIKit, from the scroll view itself, in the same moment the scroll view moves:
/// SwiftUI-side versions (a remembered resting position, the scroll geometry, the drawn position)
/// could be a frame early or late when a refresh starts (the haptic, as the spinner's room is added),
/// and the poster flashed at the wrong zoom for that frame.
private struct PullStretchArt<Content: View>: UIViewRepresentable {
    let content: Content
    func makeUIView(context: Context) -> PullStretchHost<Content> { PullStretchHost(content) }
    func updateUIView(_ view: PullStretchHost<Content>, context: Context) { view.host.rootView = content }
}

/// The host, weakly, for UIKit's observation callback (which Swift sees as able to run anywhere;
/// UIKit calls it on the main thread, and the host is only touched there).
private final class WeakHost<Host: AnyObject>: @unchecked Sendable {
    weak var value: Host?
    init(_ value: Host) { self.value = value }
}

private final class PullStretchHost<Content: View>: UIView {
    let host: UIHostingController<Content>
    private var observation: NSKeyValueObservation?
    private weak var scrollView: UIScrollView?
    init(_ content: Content) {
        host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        observation = nil; scrollView = nil
        var view = superview
        while let current = view, !(current is UIScrollView) { view = current.superview }
        guard window != nil, let scroll = view as? UIScrollView else { return }
        scrollView = scroll
        // Called by UIKit on the main thread, inside the same change that moves the page.
        let target = WeakHost(self)
        observation = scroll.observe(\.contentOffset, options: [.new]) { _, _ in
            MainActor.assumeIsolated { target.value?.stretch() }
        }
        stretch()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.bounds = CGRect(origin: .zero, size: bounds.size)
        host.view.center = CGPoint(x: bounds.midX, y: bounds.midY)
        stretch()
    }
    private func stretch() {
        guard let window, let scrollView, bounds.height > 0 else { return }
        let top = convert(CGPoint.zero, to: window).y
        let edge = scrollView.superview?.convert(scrollView.frame, to: window).minY ?? 0
        let gap = max(0, top - edge)
        let scale = 1 + gap / bounds.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Scaled about the middle, then raised by half the growth: the bottom edge stays put.
        host.view.transform = CGAffineTransform(translationX: 0, y: -gap / 2).scaledBy(x: scale, y: scale)
        CATransaction.commit()
    }
}

