import SwiftUI
import TwilDiaryCore

struct ExploreView: View {
    @Environment(DiaryStore.self) private var store
    @State private var showSearch = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    ExploreContent(store: store)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 100)
            }
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { showSearch.toggle() } label: { DiaryIcon(name: "search", size: 22) }.accessibilityLabel("Search").accessibilityIdentifier("search-explore") }
            }
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
            DiscoveryBrowser(section: .genres, service: service, store: store, promptForGenre: true)
            Text("Discovery and artwork: TMDb · Personal recommendations: Trakt").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    @Environment(AppRouter.self) private var router
    private func openLibrary() { router.library("all") }
}

private struct ExploreHeading: View {
    let section: DiscoverySection
    var filters: DiscoveryFilters? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.label).font(.system(size: 20, weight: .semibold)).tracking(-0.5)
            Spacer(minLength: 0)
            NavigationLink(value: ExploreSectionRoute(section: section, filters: filters)) { Text("View more").font(.system(size: 13)).frame(minHeight: 44) }
                .accessibilityIdentifier("explore-more-" + section.id)
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
                    Text(title.name).font(.system(size: 26, weight: .bold)).tracking(-0.8).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.8)
                    HStack(spacing: 8) {
                        Text((title.year.map(String.init) ?? "Year unknown") + " · " + (title.isSeries ? "Show" : "Movie")).foregroundStyle(Color(webHex: "#d8d3e0"))
                        if let score = title.communityScore, score > 0 {
                            HStack(spacing: 4) { DiaryIcon(name: "star", size: 13); Text(String(format: "%.1f", score)); Text("TMDb").foregroundStyle(.white.opacity(0.6)) }.foregroundStyle(Color(webHex: "#e7ca90"))
                        }
                    }.font(.system(size: 14))
                }.frame(maxWidth: .infinity, alignment: .leading)
                DiaryIcon(name: "arrow-up-right", size: 20).foregroundStyle(theme.ink).frame(width: 44, height: 44).background(theme.accent, in: Circle()).accessibilityHidden(true)
            }.padding(18)
        }.frame(height: 225).clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12))).contentShape(Rectangle())
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
        }.task { if results.page == 0 { await load() } }
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
                        }.buttonStyle(.springPress).containerRelativeFrame(.horizontal, count: 3, spacing: 12).accessibilityIdentifier("catalog-" + item.displayKey)
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
            else if !results.loading && !results.connected { DiscoveryNotice(text: "Trakt not connected.") }
            else if !results.loading && results.items.isEmpty { DiscoveryNotice(text: "No recommendations yet.") }
        }.task(id: store.discoveryRevision) { await results.load(limit: section ? 24 : 8) }
    }
}

struct ExploreSectionView: View {
    let route: ExploreSectionRoute
    let store: DiaryStore
    @State private var showSearch = false
    @State private var service: LiveDiscoveryService
    init(route: ExploreSectionRoute, store: DiaryStore) { self.route = route; self.store = store; _service = State(initialValue: LiveDiscoveryService(store: store)) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    DiscoveryBrowser(section: route.section, service: service, store: store, initialFilters: route.filters)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 100)
            }
        }.diaryScreenBackground().navigationTitle("Explore").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showSearch.toggle() } label: { DiaryIcon(name: "search", size: 22) }.accessibilityLabel("Search").accessibilityIdentifier("search-explore-section") } }
    }
}

private struct DiscoveryBrowser: View {
    let section: DiscoverySection
    let service: any DiscoveryServing
    let store: DiaryStore
    var promptForGenre: Bool
    @State private var filters: DiscoveryFilters
    @State private var localLimit = 40
    @State private var results: DiscoveryResults
    @State private var recommendations: DiscoveryRecommendations
    init(section: DiscoverySection, service: any DiscoveryServing, store: DiaryStore, initialFilters: DiscoveryFilters? = nil, promptForGenre: Bool = false) {
        self.section = section; self.service = service; self.store = store; self.promptForGenre = promptForGenre
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
                Text(section.label).font(.system(size: promptForGenre ? 20 : 26, weight: .semibold)).tracking(-0.5)
                Spacer(minLength: 0)
                if promptForGenre { NavigationLink(value: ExploreSectionRoute(section: section, filters: filters)) { Text("View more").font(.system(size: 13)) }.accessibilityIdentifier("explore-more-genres") }
            }
            if promptForGenre { genreToolbar }
            // Always visible, as on Canvas: the filters are a row of pills, not a hidden panel.
            if !promptForGenre { filterForm }
            content
        }.task(id: filters) {
            localLimit = 40
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
    /// Filters as pill menus in one scrolling row, like Canvas.
    private var filterForm: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if filters != DiscoveryFilters(section: section) {
                    Button("Reset filters") { filters = DiscoveryFilters(section: section) }.font(.system(size: 14, weight: .medium)).padding(.horizontal, 6).frame(minHeight: 44)
                }
                if !promptForGenre && section.fixedType == nil {
                    Menu { Picker("Content type", selection: $filters.type) { if section.source != "tmdb" { Text("All titles").tag("all") }; Text("Shows").tag("tv"); Text("Movies").tag("movie") } }
                        label: { FilterPill(label: filters.type == "tv" ? "Shows" : filters.type == "movie" ? "Movies" : "All titles") }
                }
                if !promptForGenre {
                    Menu { Picker("Section genre", selection: $filters.genre) { Text("All genres").tag(""); ForEach(genres, id: \.self) { Text($0).tag($0) } } }
                        label: { FilterPill(label: filters.genre.isEmpty ? "All genres" : filters.genre, active: !filters.genre.isEmpty) }
                }
                Menu { Picker("Explore minimum rating", selection: $filters.minimum) { Text("Any rating").tag("0"); ForEach([6, 7, 8, 9], id: \.self) { Text("\($0)+").tag(String($0)) } } }
                    label: { FilterPill(label: filters.minimum == "0" ? "Any rating" : filters.minimum + "+", active: filters.minimum != "0") }.accessibilityIdentifier("explore-minimum")
                Menu { Picker("Released year", selection: $filters.year) { Text("Any year").tag(""); ForEach(Self.years, id: \.self) { Text(String($0)).tag(String($0)) } } }
                    label: { FilterPill(label: filters.year.isEmpty ? "Any year" : filters.year, active: !filters.year.isEmpty) }.accessibilityLabel("Explore release year")
                Menu { Picker("Sort discoveries", selection: $filters.sort) { Text(section.source == "library" ? "Library order" : "Recommended order").tag("popular"); Text("Highest rated").tag("rating"); Text("Newest releases").tag("newest"); if section.source != "tmdb" { Text("Title A–Z").tag("title") } } }
                    label: { FilterPill(label: sortLabel, icon: "arrow-down-up") }
            }.padding(.vertical, 2)
        }.scrollIndicators(.hidden).onChange(of: filters.type) { _, _ in if !promptForGenre { filters.genre = "" } }
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
                Text((section.source == "tmdb" ? displayed.count : local.count).counted("title", "titles")).font(.system(size: 12)).foregroundStyle(.secondary)
                CatalogGrid(items: displayed, showsLayoutToggle: false)
            }
            if busy && displayed.isEmpty { DiaryLoadingPlaceholder(height: 240, label: "Loading titles") }
            if let error = section == .recommended ? recommendations.error : results.error {
                DiscoveryNotice(text: error) { Task { if section == .recommended { await recommendations.load(limit: 24, refresh: true) } else { await results.load(filters.query(section: section), more: results.page > 0) } } }
            } else if !busy && displayed.isEmpty {
                if section == .recommended && !recommendations.connected { DiscoveryNotice(text: "Connect Trakt in More to load your recommendations.") }
                else { ContentUnavailableView(section == .daily ? "No unwatched titles in this mix" : "No titles in this mix", systemImage: "sparkles", description: Text("Try another genre, year or rating.")) }
            }
            if section.source == "tmdb" ? results.hasMore : localLimit < local.count {
                Button("Load more") { if section.source == "tmdb" { Task { await results.load(filters.query(section: section), more: true) } } else { localLimit += 40 } }.buttonStyle(.glass).disabled(busy).frame(maxWidth: .infinity)
            }
        }
    }
}
