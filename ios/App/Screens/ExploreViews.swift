import SwiftUI
import TwilDiaryCore

struct ExploreView: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            // "Explore" sits in the frosted top bar; the page scrolls underneath it.
            EdgeToEdgeScroll(frosted: true) {
                VStack(alignment: .leading, spacing: 22) {
                    ExploreContent(store: store)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 100)
            }
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ExploreLabButton() } }
    }
}

/// An Explore filter pill: a dark outlined capsule, lilac-tinted for the order and any filter that's set.
private struct ExplorePill: View {
    let label: String
    var icon: String? = nil
    var tinted = false
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
            Text(label).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).opacity(0.8)
        }.font(.system(size: 15, weight: .semibold)).fixedSize()
            .foregroundStyle(tinted ? HomeStyle.chipText : Color(webHex: "#e6e1ee"))
            .padding(.horizontal, 14).frame(height: 38)
            .background(tinted ? HomeStyle.chip : HomeStyle.card, in: Capsule())
            .overlay(Capsule().strokeBorder(tinted ? Color.clear : HomeStyle.dateChipBorder, lineWidth: 1))
            .frame(minHeight: 44).contentShape(Capsule())
    }
}

/// Search Lab's way in: a flask in a Liquid Glass circle (a toolbar button, like Back), top right
/// on every Explore page.
struct ExploreLabButton: View {
    var body: some View {
        NavigationLink(value: SearchLabRoute()) {
            Image(systemName: "flask").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
        }.accessibilityLabel("Search Lab").accessibilityIdentifier("explore-search-lab")
    }
}

private struct ExploreContent: View {
    let store: DiaryStore
    @State private var service: LiveDiscoveryService
    init(store: DiaryStore) { self.store = store; _service = State(initialValue: LiveDiscoveryService(store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 10) {
                ExploreHeading(section: .daily)
                if let title = DiscoveryTools.dailyPick(store.workspace, day: DiaryDate.day(store.now)) {
                    NavigationLink(value: title.id) { DailyDiscoveryCard(title: title).zoomSource(ZoomID.title(title.id)) }.buttonStyle(.springPress).accessibilityIdentifier("explore-daily-pick")
                } else {
                    VStack(spacing: 10) { Text("No unwatched titles in your library."); Button("Open library") { openLibrary() } }
                        .font(.system(size: 14)).diaryPanel().frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            RecommendedDiscoveryView(service: service, section: false)
            ForEach(DiscoverySection.shelves) { section in DiscoveryShelfView(section: section, service: service) }
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

/// The day's pick as a large artwork card, like Home's Continue watching: full-bleed backdrop,
/// the title large over a soft scrim, and its year, type and score underneath.
private struct DailyDiscoveryCard: View {
    let title: MediaTitle
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(path: title.backdrop ?? title.poster, title: title.name)
            LinearGradient(stops: [.init(color: .black.opacity(0.05), location: 0), .init(color: .black.opacity(0.2), location: 0.45), .init(color: .black.opacity(0.88), location: 1)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.name).font(.system(size: 26, weight: .bold)).tracking(-0.6).foregroundStyle(.white).lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                    HStack(spacing: 6) {
                        Text((title.year.map(String.init) ?? "Year unknown") + " · " + (title.isSeries ? "Show" : "Movie")).lineLimit(1)
                        if let score = title.communityScore, score > 0 {
                            Text("·")
                            HStack(spacing: 4) { Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Color(webHex: "#f5c451")); Text(String(format: "%.1f", score)) }
                        }
                    }.font(.system(size: 15, weight: .medium)).foregroundStyle(Color(webHex: "#d8d3e0"))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 20).padding(.bottom, 18)
        }.aspectRatio(1.89, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12))).contentShape(Rectangle())
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
            if results.loading && results.items.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading titles") }
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
            if results.loading && results.items.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading recommendations") }
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
        VStack(spacing: 0) {
            EdgeToEdgeScroll(frosted: true) {
                VStack(alignment: .leading, spacing: 16) {

                    DiscoveryBrowser(section: route.section, service: service, store: store, initialFilters: route.filters)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 100)
            }
        }.diaryScreenBackground().navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ExploreLabButton() } }
    }
}

private extension DiscoverySection {
    /// The header's name for the list once its big heading has scrolled away, when the full one won't fit.
    var shortLabel: String {
        switch self {
        case .ratedShows, .ratedMovies: "Highest rated"
        case .popularShows, .popularMovies: "Popular"
        case .recommended: "Recommended"
        case .daily: "Today's pick"
        case .genres: "Search Lab"
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
    /// The big heading has scrolled under the top bar: the bar then names the list.
    @State private var headingHidden = false
    @State private var headerState = CompactHeaderState()
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(filters.label ?? section.label).font(.system(size: promptForGenre ? 22 : 30, weight: .bold)).tracking(-0.6)
                    .foregroundStyle(HomeStyle.primary).lineLimit(2).minimumScaleFactor(0.8)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                        let progress = ScrollLinkedBarTitle.progress(headingBottom: bottom)
                        headerState.update(progress)
                        if (progress >= 0.5) != headingHidden { headingHidden = progress >= 0.5 }
                    }
                Spacer(minLength: 0)
                if promptForGenre { SectionMoreLink(label: "View more " + section.label, value: ExploreSectionRoute(section: section, filters: filters), identifier: "explore-more-genres") }
            }
            if promptForGenre { genreToolbar }
            // Always visible, as on Canvas: the filters are a row of pills, not a hidden panel.
            if !promptForGenre { filterForm }
            content.smoothChange(of: displayed.isEmpty)
        }
        .navigationTitle(headingHidden ? (filters.label ?? section.label) : "Explore")
        .toolbar {
            ToolbarItem(placement: .principal) {
                ScrollLinkedBarTitle(resting: "Explore", scrolled: filters.label ?? section.label, state: headerState)
            }
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
        section = next; filters = value
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
            if busy && displayed.isEmpty { DiaryLoadingPlaceholder(height: 240, label: "Loading titles") }
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
