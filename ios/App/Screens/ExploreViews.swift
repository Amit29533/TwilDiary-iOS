import SwiftUI
import TwilDiaryCore

struct ExploreView: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        EdgeToEdgeScroll(artworkUnderBar: true) {
            ExploreContent(store: store)
                .padding(.bottom, 100)
        }
        .diaryScreenBackground()
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .background(EdgeSwipeBack().frame(width: 0, height: 0))
    }
}

/// A page without a back button (Explore hides its bar, Canvas its back button) loses UIKit's
/// back swipes: the one from the left edge, and the one across the page. While such a page is on
/// screen this lets both go back again, and gives UIKit its own handling back as soon as another
/// page covers it.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var navigation: UINavigationController?
        private weak var originalEdge: UIGestureRecognizerDelegate?
        private weak var originalContent: UIGestureRecognizerDelegate?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = navigationController ?? owner() else { return }
            self.navigation = navigation
            if let edge = navigation.interactivePopGestureRecognizer {
                if edge.delegate !== self { originalEdge = edge.delegate; edge.delegate = self }
                edge.isEnabled = true
            }
            if let content = navigation.interactiveContentPopGestureRecognizer {
                if content.delegate !== self { originalContent = content.delegate; content.delegate = self }
                content.isEnabled = true
            }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let edge = navigation?.interactivePopGestureRecognizer, edge.delegate === self { edge.delegate = originalEdge }
            if let content = navigation?.interactiveContentPopGestureRecognizer, content.delegate === self { content.delegate = originalContent }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigation, navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil else { return false }
            guard gestureRecognizer === navigation.interactiveContentPopGestureRecognizer, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            // Across the page: only a swipe to the right, and not over a row that can still scroll
            // back (that row scrolls instead), as UIKit's own handling does.
            let velocity = pan.velocity(in: pan.view)
            guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) else { return false }
            var hit = pan.view?.hitTest(pan.location(in: pan.view), with: nil)
            while let view = hit {
                if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1,
                   scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 { return false }
                hit = view.superview
            }
            return true
        }
        private func owner() -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController, let navigation = controller.navigationController { return navigation }
                responder = current.next
            }
            return nil
        }
    }
}

/// An Explore filter pill: a dark outlined capsule, lilac-tinted for the order and any filter that's set.
struct ExplorePill: View {
    let label: String
    var icon: String? = nil
    var tinted = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.app(size: 13, weight: .bold)) }
            Text(label).lineLimit(1)
            Image(systemName: "chevron.down").font(.app(size: 11, weight: .bold)).opacity(0.8)
        }.font(.app(size: 15, weight: .semibold)).fixedSize()
            .foregroundStyle(tinted ? HomeStyle.chipText : Color(themed: "#e6e1ee"))
            .padding(.horizontal, 14).frame(height: 38)
            .background(tinted ? HomeStyle.chip : HomeStyle.card, in: Capsule())
            .overlay(Capsule().strokeBorder(tinted ? Color.clear : HomeStyle.dateChipBorder, lineWidth: 1))
            .frame(minHeight: 44).contentShape(Capsule())
    }
}


private struct ExploreContent: View {
    let store: DiaryStore
    @State private var service: LiveDiscoveryService
    init(store: DiaryStore) { self.store = store; _service = State(initialValue: LiveDiscoveryService(store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.section) {
            let picks = Self.heroPicks(store, day: DiaryDate.day(store.now))
            if !picks.isEmpty {
                // Closer to the row below than the page's usual 28 pt (owner's note, 25 Nov 2026: the gap
                // under the cover to Ask CineMind was too big): 12 pt.
                ExploreHeroCarousel(titles: picks).padding(.bottom, 12 - Gap.section)
            } else {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    ExploreHeading(section: .daily)
                    VStack(spacing: 10) {
                        Text("No unwatched titles in your library.")
                        Button("Open library") { openLibrary() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .diaryPanel()
                }
                .padding(.horizontal, 14)
                .padding(.top, 72)
            }
            // Lazy: rows further down build (and load) as they come on screen. Your order and
            // choice of rows (Settings → Customise); by default Ask CineMind, popular, CineMind's picks,
            // Trakt's, the newer rows and the highest rated.
            LazyVStack(alignment: .leading, spacing: Gap.section) {
                ForEach(ExploreRow.layout(exploreLayout).visible.compactMap(ExploreRow.init(rawValue:))) { row in
                    exploreRow(row)
                }
            }
            .padding(.horizontal, 14)
        }
    }
    @Environment(AppRouter.self) private var router
    @AppStorage(ExploreRow.key) private var exploreLayout = ""
    private func openLibrary() { router.library("all") }

    /// One of Explore's rows (the extra ones need a real diary; none show in the UI-test fixture).
    @ViewBuilder private func exploreRow(_ row: ExploreRow) -> some View {
        switch row {
        case .popularMovies: DiscoveryShelfView(section: .popularMovies, service: service)
        case .popularShows: DiscoveryShelfView(section: .popularShows, service: service)
        case .recommended: RecommendedDiscoveryView(service: service, section: false)
        case .ratedShows: DiscoveryShelfView(section: .ratedShows, service: service)
        case .ratedMovies: DiscoveryShelfView(section: .ratedMovies, service: service)
        default:
            if !store.isPreview {
                switch row {
                case .askCineMind: ExploreAIPrompts()
                case .cineMovies: CineMindRow(movies: true)
                case .cineShows: CineMindRow(movies: false)
                case .loved: BecauseYouLovedRow()
                case .trending: TrendingPlannedRow()
                case .seasonal: SeasonalAnimeRow()
                case .coming: ComingSoonRow()
                default: EmptyView()
                }
            }
        }
    }

    /// The top poster's titles, worked out once per day and diary change (not on every redraw).
    private static var keptPicks: (key: String, picks: [MediaTitle])?
    static func heroPicks(_ store: DiaryStore, day: String) -> [MediaTitle] {
        let key = day + "|" + store.homeWorkspaceRevision.uuidString
        if let keptPicks, keptPicks.key == key { return keptPicks.picks }
        let picks = heroPicks(store.workspace, day: day)
        keptPicks = (key, picks)
        return picks
    }
    /// Today's pick first (as `DiscoveryTools.dailyPick`), then up to seven more unwatched planned
    /// titles with a picture, in an order that changes each day. One pass over your history.
    static func heroPicks(_ workspace: Workspace, day: String) -> [MediaTitle] {
        let unwatched = DiscoveryTools.unwatched(workspace)
        guard !unwatched.isEmpty else { return [] }
        let dayHash = day.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
        let first = unwatched[Int(UInt32(bitPattern: dayHash)) % unwatched.count]
        func hash(_ text: String) -> UInt64 { text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } }
        let others = unwatched.filter { $0.id != first.id && ($0.backdrop ?? $0.poster) != nil }
            .map { ($0, hash($0.id + day)) }.sorted { $0.1 < $1.1 }.map { $0.0 }
        return [first] + others.prefix(7)
    }
}

/// Explore's top poster: one of your planned titles, changing to the next every five seconds
/// while Explore is on screen.
private struct ExploreHeroCarousel: View {
    let titles: [MediaTitle]
    /// The title on screen: swiped to by hand (paging), or moved on every five seconds.
    @State private var selected: String?
    /// On screen: shown (not under another page) and not scrolled away.
    @State private var shown = false
    @State private var scrolledInto = true
    /// Your finger is on it (or it's settling after a swipe): a tick per page.
    @State private var swiping = false

    var body: some View {
        let current = titles.firstIndex { $0.id == selected } ?? 0
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(titles) { title in
                    DailyDiscoveryHero(title: title).containerRelativeFrame(.horizontal).id(title.id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $selected)
        .onScrollPhaseChange { _, phase in swiping = phase == .interacting || phase == .decelerating }
        .haptic(.selection, trigger: selected) { _, _ in swiping }
        .overlay(alignment: .bottomTrailing) {
            if titles.count > 1 {
                HStack(spacing: 5) {
                    ForEach(titles.indices, id: \.self) { position in
                        Capsule().fill(.white.opacity(position == current ? 0.95 : 0.35))
                            .frame(width: position == current ? 14 : 5, height: 5)
                    }
                }
                .animation(.snappy(duration: 0.25), value: current)
                .padding(.trailing, 18).padding(.bottom, 16)
                .accessibilityHidden(true)
            }
        }
        .onAppear { shown = true; if selected == nil { selected = titles.first?.id } }
        .onDisappear { shown = false }
        .onScrollVisibilityChange(threshold: 0.25) { scrolledInto = $0 }
        // Five seconds on each title; a swipe by hand starts the five seconds again.
        .task(id: "\(shown && scrolledInto)|\(selected ?? "")") {
            guard shown, scrolledInto, titles.count > 1 else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let next = titles[(current + 1) % titles.count].id
            withAnimation(.smooth(duration: 0.6)) { selected = next }
        }
    }
}

private struct ExploreHeading: View {
    let section: DiscoverySection
    var filters: DiscoveryFilters? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(section.label).font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            SectionMoreLink(label: "View more " + section.label, value: ExploreSectionRoute(section: section, filters: filters),
                            identifier: "explore-more-" + section.id)
        }.frame(minHeight: Gap.headingRow)
    }
}

private struct DailyDiscoveryHero: View {
    let title: MediaTitle
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// One height for every title (bigger with larger text), so the page doesn't move as it changes.
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 340

    private var facts: String {
        [title.year.map(String.init), title.isSeries ? "Show" : "Movie"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            NavigationLink(value: title.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.name)
                        .font(.largeTitle.bold())
                        .lineLimit(2).minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        Text(facts)
                        if let score = title.communityScore, score > 0 {
                            Text("·")
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                                .accessibilityLabel("Rating")
                            Text(String(format: "%.1f", score))
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("explore-daily-pick")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 70)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(height: verticalSizeClass == .compact ? 240 : min(height, 520), alignment: .bottomLeading)
        .background {
            NavigationLink(value: title.id) {
                Artwork(path: title.backdrop ?? title.poster, initialsOnly: false)
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .clear, location: 0.28),
                            .init(color: .black.opacity(0.70), location: 0.65),
                            .init(color: .black.opacity(0.94), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0.92),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .contentShape(Rectangle())
                    .zoomSource(ZoomID.title(title.id))
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }
}

private struct DiscoveryShelfView: View {
    let section: DiscoverySection
    @State private var results: DiscoveryResults
    init(section: DiscoverySection, service: any DiscoveryServing) { self.section = section; _results = State(initialValue: DiscoveryResults(service: service)) }
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.heading) {
            ExploreHeading(section: section)
            // The titles and their stand-in share one place and cross-fade (one under the other, the fade
            // stacked both: the page grew by a row, then snapped back).
            ZStack(alignment: .topLeading) {
                DiscoveryTrack(items: results.items)
                if (results.loading || results.page == 0) && results.items.isEmpty && results.error == nil { DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterShelf).padding(.bottom, 10) }
            }
            if let error = results.error { DiscoveryNotice(text: error) { Task { await load() } } }
            else if !results.loading && results.page > 0 && results.items.isEmpty { DiscoveryNotice(text: "No titles available.") }
        }.smoothChange(of: results.items.isEmpty).task { if results.page == 0 { await load() } }
    }
    private func load() async { await results.load(DiscoveryFilters(section: section).query(section: section)) }
}

private struct DiscoveryTrack: View {
    @PosterSizing private var posterSize
    let items: [CatalogItem]
    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.displayKey) { item in
                        Group {
                            if let id = item.inLibraryId { NavigationLink(value: id) { CatalogPoster(item: item).zoomSource(ZoomID.title(id)) } }
                            else { NavigationLink(value: item.route) { CatalogPoster(item: item).zoomSource(ZoomID.catalog(item.route)) } }
                        }.buttonStyle(.springPress).containerRelativeFrame(.horizontal, count: posterSize.columns, spacing: 12).shelfTransition().accessibilityIdentifier("catalog-" + item.displayKey)
                    }
                }
            }.scrollIndicators(.hidden).padding(.bottom, 10)
                .preference(key: BrowseCoverPreference.self, value: ExploreBrowseHeader.artwork(in: items))
        }
    }
}

private struct DiscoveryNotice: View {
    let text: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) { Text(text).font(.app(size: 13)).foregroundStyle(.secondary).frame(minHeight: 21.5); Spacer(minLength: 0); if let retry { Button("Retry", action: retry).font(.app(size: 13)).frame(minHeight: 44) } }
            .padding(.horizontal, 14).padding(.vertical, 12).diarySectionBackground(radius: 11)
    }
}

private struct RecommendedDiscoveryView: View {
    @Environment(DiaryStore.self) private var store
    let section: Bool
    @State private var results: DiscoveryRecommendations
    init(service: any DiscoveryServing, section: Bool) { self.section = section; _results = State(initialValue: DiscoveryRecommendations(service: service)) }
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.heading) {
            ExploreHeading(section: .recommended)
            ZStack(alignment: .topLeading) {
                DiscoveryTrack(items: results.items)
                if (results.loading || !results.checked) && results.items.isEmpty && results.error == nil { DiaryLoadingPlaceholder(label: "Loading recommendations", layout: .posterShelf).padding(.bottom, 10) }
            }
            if let error = results.error { DiscoveryNotice(text: error) { Task { await results.load(refresh: true) } } }
            else if !results.loading && results.checked && !results.connected {
                // A way in, not a dead end: Trakt's settings page connects it.
                NavigationLink(value: AppDestination.trakt) {
                    HStack(spacing: 10) {
                        BrandLogo(service: .trakt, size: 22)
                        Text("Connect Trakt for picks made for you").font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).frame(minHeight: 48).diarySectionBackground(radius: 11).contentShape(Rectangle())
                }.buttonStyle(.springPress).accessibilityIdentifier("explore-connect-trakt")
            }
            else if !results.loading && results.checked && results.items.isEmpty { DiscoveryNotice(text: "No recommendations yet.") }
        }.smoothChange(of: results.items.isEmpty).task(id: store.discoveryRevision) { await results.load(limit: section ? 24 : 8) }
    }
}

struct ExploreSectionView: View {
    let route: ExploreSectionRoute
    let store: DiaryStore
    @State private var service: LiveDiscoveryService
    init(route: ExploreSectionRoute, store: DiaryStore) { self.route = route; self.store = store; _service = State(initialValue: LiveDiscoveryService(store: store)) }
    var body: some View {
        DiscoveryBrowser(section: route.section, service: service, store: store, initialFilters: route.filters)
    }
}

private extension DiscoverySection {
    var browseSymbol: String {
        switch self {
        case .ratedShows, .ratedMovies: "star.fill"
        case .popularShows, .popularMovies: "chart.line.uptrend.xyaxis"
        case .recommended: "sparkles"
        case .daily: "sun.max"
        case .genres: "film.stack"
        }
    }
    /// The same list for the other type ("Highest rated shows" and "Highest rated movies").
    var swapped: DiscoverySection? {
        switch self {
        case .ratedShows: .ratedMovies
        case .ratedMovies: .ratedShows
        case .popularShows: .popularMovies
        case .popularMovies: .popularShows
        default: nil
        }
    }
}

private struct DiscoveryBrowser: View {
    @State private var section: DiscoverySection
    let service: any DiscoveryServing
    let store: DiaryStore
    var promptForGenre: Bool
    @State private var filters: DiscoveryFilters
    @State private var localLimit = 40
    /// The filters the list was last shown with: coming back from a title keeps its length.
    @State private var shownFilters: DiscoveryFilters?
    @State private var results: DiscoveryResults
    @State private var recommendations: DiscoveryRecommendations
    init(section: DiscoverySection, service: any DiscoveryServing, store: DiaryStore, initialFilters: DiscoveryFilters? = nil, promptForGenre: Bool = false) {
        _section = State(initialValue: section); self.service = service; self.store = store; self.promptForGenre = promptForGenre
        _filters = State(initialValue: initialFilters ?? DiscoveryFilters(section: section))
        _results = State(initialValue: DiscoveryResults(service: service)); _recommendations = State(initialValue: DiscoveryRecommendations(service: service))
    }
    private var local: [CatalogItem] { filters.applying(section == .daily ? DiscoveryTools.unwatched(store.workspace).map(DiscoveryTools.item) : recommendations.items) }
    private var displayed: [CatalogItem] { section.source == "tmdb" ? results.items : Array(local.prefix(localLimit)) }
    private var genres: [String] {
        if section != .daily { return DiscoveryGenre.names(type: filters.type) }
        return Set(DiscoveryTools.unwatched(store.workspace).filter { filters.type == "all" || ($0.isSeries ? "tv" : "movie") == filters.type }.flatMap(\.genres)).sorted()
    }
    private var busy: Bool { section == .recommended ? (recommendations.loading || !recommendations.checked) : results.loading }
    var body: some View {
        let title = filters.label ?? section.label
        let tag = filters.keyword != nil
        let symbol = filters.network != nil ? "tv" : filters.company != nil ? "building.2" : section.browseSymbol
        let subtitle = tag ? "Tag" : filters.network != nil ? "Network" : filters.company != nil ? "Production company" : nil
        ExploreBrowsePage(title: title, symbol: symbol, emoji: tag ? TagEmoji.symbol(for: title) : nil,
                          subtitle: subtitle, artwork: ExploreBrowseHeader.artwork(in: displayed)) {
            VStack(alignment: .leading, spacing: 16) {
                if promptForGenre { genreToolbar } else { filterForm }
                content.smoothChange(of: displayed.isEmpty)
            }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 100)
        }
        .task(id: filters) {
            if shownFilters != filters { localLimit = 40; shownFilters = filters }
            guard section.source == "tmdb" else { return }
            guard filters.error(section: section) == nil, !promptForGenre || !filters.genre.isEmpty else { results.clear(); return }
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); await results.load(filters.query(section: section)) } catch { }
        }.task(id: store.discoveryRevision) { if section == .recommended { await recommendations.load(limit: 24) } }
    }
    private var genreToolbar: some View {
        HStack(spacing: 8) {
            Menu { Picker("Explore genre", selection: $filters.genre) { Text("Choose a genre").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } } }
                label: { FilterPill(label: filters.genre.isEmpty ? "Choose a genre" : filters.genre, active: !filters.genre.isEmpty) }.accessibilityLabel("Explore genre").accessibilityIdentifier("explore-genre")
            Menu { Picker("Explore media type", selection: $filters.type) { Text("Shows").tag("tv"); Text("Movies").tag("movie") } }
                label: { FilterPill(label: filters.type == "movie" ? "Movies" : "Shows") }.accessibilityLabel("Explore media type").accessibilityIdentifier("explore-type")
            Spacer(minLength: 0)
        }.onChange(of: filters.type) { _, _ in if promptForGenre { filters.genre = "" } }
    }
    /// Filters as pill menus in one row that scrolls edge to edge, like Canvas: the order first,
    /// then type, genre, rating and year, and Reset at the end once something is changed.
    private var filterForm: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort discoveries", selection: $filters.sort) { Text(section.source == "library" ? "Library order" : "Recommended").tag("popular"); Text("Highest rated").tag("rating"); Text("Newest").tag("newest"); if section.source != "tmdb" { Text("Title A–Z").tag("title") } }
                } label: { ExplorePill(label: sortLabel, icon: "arrow.up.arrow.down", tinted: true) }
                    .accessibilityLabel("Order, " + sortLabel).accessibilityIdentifier("explore-sort")
                if !promptForGenre && section.fixedType == nil {
                    Menu { Picker("Content type", selection: $filters.type) { if section.source != "tmdb" { Text("All titles").tag("all") }; Text("Shows").tag("tv"); Text("Movies").tag("movie") } }
                        label: { ExplorePill(label: filters.type == "tv" ? "Shows" : filters.type == "movie" ? "Movies" : "All titles") }
                } else if !promptForGenre, let kind = section.fixedType, section.swapped != nil {
                    // A shows-only list switches to its movies twin (and back).
                    Menu {
                        Picker("Content type", selection: Binding(get: { kind == .movie ? "movie" : "tv" }, set: { value in if value != (kind == .movie ? "movie" : "tv") { swapType() } })) {
                            Text("Shows").tag("tv"); Text("Movies").tag("movie")
                        }
                    } label: { ExplorePill(label: kind == .movie ? "Movies" : "Shows") }.accessibilityIdentifier("explore-type")
                }
                if !promptForGenre {
                    Menu { Picker("Section genre", selection: $filters.genre) { Text("All genres").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } } }
                        label: { ExplorePill(label: filters.genre.isEmpty ? "All genres" : filters.genre, tinted: !filters.genre.isEmpty) }
                }
                Menu { Picker("Explore minimum rating", selection: $filters.minimum) { Text("Any rating").tag("0"); ForEach([6, 7, 8, 9], id: \.self) { Text("\($0)+").tag(String($0)) } } }
                    label: { ExplorePill(label: filters.minimum == "0" ? "Any rating" : filters.minimum + "+", tinted: filters.minimum != "0") }.accessibilityIdentifier("explore-minimum")
                Menu { yearPicker } label: { ExplorePill(label: filters.year.isEmpty ? "Any year" : filters.year, tinted: !filters.year.isEmpty) }
                    .accessibilityLabel("Explore release year")
                if filters != filters.resettingFilters(section: section) {
                    Button { withAnimation(.snappy) { filters = filters.resettingFilters(section: section) } } label: {
                        Text("Reset filters").font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText).lineLimit(1).fixedSize()
                            .padding(.horizontal, 14).frame(height: 38)
                            .overlay(Capsule().strokeBorder(HomeStyle.chipText.opacity(0.4), lineWidth: 1))
                            .frame(minHeight: 44).contentShape(Capsule())
                    }.buttonStyle(.plain).transition(.opacity)
                }
            }.padding(.horizontal, 14).padding(.vertical, 2)
        }.scrollIndicators(.hidden).padding(.horizontal, -14)
            .onChange(of: filters.type) { _, _ in if !promptForGenre { filters.genre = "" } }
    }
    private var yearPicker: some View {
        Picker("Released year", selection: $filters.year) { Text("Any year").tag(""); ForEach(Self.years, id: \.self) { Text(String($0)).tag(String($0)) } }
    }
    private func swapType() {
        guard let next = section.swapped else { return }
        var value = DiscoveryFilters(section: next)
        value.minimum = filters.minimum; value.year = filters.year; value.sort = filters.sort
        results.clear(); section = next; filters = value
    }
    private static let years = Array((1950...Calendar.current.component(.year, from: .now)).reversed())
    private var sortLabel: String {
        switch filters.sort { case "rating": "Highest rated"; case "newest": "Newest"; case "title": "Title A–Z"; default: section.source == "library" ? "Library order" : "Recommended" }
    }
    @ViewBuilder private var content: some View {
        if let error = filters.error(section: section) { DiscoveryNotice(text: error) }
        else if promptForGenre && filters.genre.isEmpty { Text("Choose a genre to explore shows and movies.").font(.app(size: 13)).foregroundStyle(.secondary) }
        else {
            ZStack(alignment: .topLeading) {
                if !displayed.isEmpty {
                    CatalogGrid(items: displayed, showsLayoutToggle: false)
                }
                if busy && displayed.isEmpty { DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterGrid(columns: 3, rows: 2)) }
            }
            if let error = section == .recommended ? recommendations.error : results.error {
                DiscoveryNotice(text: error) { Task { if section == .recommended { await recommendations.load(limit: 24, refresh: true) } else { await results.load(filters.query(section: section), more: results.page > 0) } } }
            } else if !busy && displayed.isEmpty {
                if section == .recommended && !recommendations.connected {
                    if recommendations.checked {
                        NavigationLink(value: AppDestination.trakt) {
                            HStack(spacing: 10) {
                                BrandLogo(service: .trakt, size: 22)
                                Text("Connect Trakt for picks made for you").font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            }.padding(.horizontal, 14).frame(minHeight: 48).diarySectionBackground(radius: 11).contentShape(Rectangle())
                        }.buttonStyle(.springPress)
                    }
                }
                else { ContentUnavailableView(section == .daily ? "No unwatched titles in this mix" : "No titles in this mix", systemImage: "sparkles", description: Text("Try another genre, year or rating.")) }
            }
            if !displayed.isEmpty, section.source == "tmdb" ? results.hasMore || busy : localLimit < local.count {
                ScrollLoadTrigger(token: displayed.count, loading: busy) {
                    if section.source == "tmdb" { Task { await results.load(filters.query(section: section), more: true) } } else { localLimit += 40 }
                }
            }
        }
    }
}
