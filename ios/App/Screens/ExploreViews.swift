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
    }
}

/// An Explore filter pill: a dark outlined capsule, lilac-tinted for the order and any filter that's set.
struct ExplorePill: View {
    let label: String
    var icon: String? = nil
    var tinted = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
            Text(label).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).opacity(0.8)
        }.font(.system(size: 15, weight: .semibold)).fixedSize()
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
        VStack(alignment: .leading, spacing: 22) {
            if let title = DiscoveryTools.dailyPick(store.workspace, day: DiaryDate.day(store.now)) {
                DailyDiscoveryHero(title: title)
            } else {
                VStack(alignment: .leading, spacing: 12) {
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
            // Lazy: rows further down build (and load) as they come on screen.
            LazyVStack(alignment: .leading, spacing: 22) {
                // AI prompts and CineMind's picks, then Trakt's, then the rest of the new rows.
                ExploreAIArea()
                RecommendedDiscoveryView(service: service, section: false)
                ExploreMoreShelves()
                ForEach(DiscoverySection.shelves) { section in DiscoveryShelfView(section: section, service: service) }
            }
            .padding(.horizontal, 14)
        }
    }
    @Environment(AppRouter.self) private var router
    private func openLibrary() { router.library("all") }
}

private struct ExploreHeading: View {
    let section: DiscoverySection
    var filters: DiscoveryFilters? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(section.label).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            SectionMoreLink(label: "View more " + section.label, value: ExploreSectionRoute(section: section, filters: filters),
                            identifier: "explore-more-" + section.id)
        }
    }
}

private struct DailyDiscoveryHero: View {
    let title: MediaTitle
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var facts: String {
        [title.year.map(String.init), title.isSeries ? "Show" : "Movie"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: ExploreSectionRoute(section: .daily)) {
                HStack(spacing: 6) {
                    Text(DiscoverySection.daily.label)
                    Image(systemName: "chevron.right").font(.caption.bold())
                }
                .font(.subheadline.weight(.semibold))
                // The theme's accent (blue by default), as the app's other links.
                .foregroundStyle(ThemeStore.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("View more " + DiscoverySection.daily.label)
            .accessibilityIdentifier("explore-more-daily")

            NavigationLink(value: title.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.name)
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
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
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, minHeight: verticalSizeClass == .compact ? 240 : 340, alignment: .bottomLeading)
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
        VStack(alignment: .leading, spacing: 10) {
            ExploreHeading(section: section)
            DiscoveryTrack(items: results.items)
            if results.loading && results.items.isEmpty { DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterShelf) }
            if let error = results.error { DiscoveryNotice(text: error) { Task { await load() } } }
            else if !results.loading && results.items.isEmpty { DiscoveryNotice(text: "No titles available.") }
        }.smoothChange(of: results.items.isEmpty).task { if results.page == 0 { await load() } }
    }
    private func load() async { await results.load(DiscoveryFilters(section: section).query(section: section)) }
}

private struct DiscoveryTrack: View {
    let items: [CatalogItem]
    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.displayKey) { item in
                        Group {
                            if let id = item.inLibraryId { NavigationLink(value: id) { CatalogPoster(item: item).zoomSource(ZoomID.title(id)) } }
                            else { NavigationLink(value: item.route) { CatalogPoster(item: item).zoomSource(ZoomID.catalog(item.route)) } }
                        }.buttonStyle(.springPress).containerRelativeFrame(.horizontal, count: 3, spacing: 12).shelfTransition().accessibilityIdentifier("catalog-" + item.displayKey)
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
        HStack(spacing: 10) { Text(text).font(.system(size: 13)).foregroundStyle(.secondary).frame(minHeight: 21.5); Spacer(minLength: 0); if let retry { Button("Retry", action: retry).font(.system(size: 13)).frame(minHeight: 44) } }
            .padding(.horizontal, 14).padding(.vertical, 12).diarySectionBackground(radius: 11)
    }
}

private struct RecommendedDiscoveryView: View {
    @Environment(DiaryStore.self) private var store
    let section: Bool
    @State private var results: DiscoveryRecommendations
    init(service: any DiscoveryServing, section: Bool) { self.section = section; _results = State(initialValue: DiscoveryRecommendations(service: service)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExploreHeading(section: .recommended)
            DiscoveryTrack(items: results.items)
            if results.loading && results.items.isEmpty { DiaryLoadingPlaceholder(label: "Loading recommendations", layout: .posterShelf) }
            if let error = results.error { DiscoveryNotice(text: error) { Task { await results.load(refresh: true) } } }
            else if !results.loading && !results.connected {
                // A way in, not a dead end: Trakt's settings page connects it.
                NavigationLink(value: AppDestination.trakt) {
                    HStack(spacing: 10) {
                        BrandLogo(service: .trakt, size: 22)
                        Text("Connect Trakt for picks made for you").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).frame(minHeight: 48).diarySectionBackground(radius: 11).contentShape(Rectangle())
                }.buttonStyle(.springPress).accessibilityIdentifier("explore-connect-trakt")
            }
            else if !results.loading && results.items.isEmpty { DiscoveryNotice(text: "No recommendations yet.") }
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
    private var busy: Bool { section == .recommended ? recommendations.loading : results.loading }
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
                        Text("Reset filters").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText).lineLimit(1).fixedSize()
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
        else if promptForGenre && filters.genre.isEmpty { Text("Choose a genre to explore shows and movies.").font(.system(size: 13)).foregroundStyle(.secondary) }
        else {
            if !displayed.isEmpty {
                CatalogGrid(items: displayed, showsLayoutToggle: false)
            }
            if busy && displayed.isEmpty { DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterGrid(columns: 3, rows: 2)) }
            if let error = section == .recommended ? recommendations.error : results.error {
                DiscoveryNotice(text: error) { Task { if section == .recommended { await recommendations.load(limit: 24, refresh: true) } else { await results.load(filters.query(section: section), more: results.page > 0) } } }
            } else if !busy && displayed.isEmpty {
                if section == .recommended && !recommendations.connected { DiscoveryNotice(text: "Connect Trakt in More to load your recommendations.") }
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
