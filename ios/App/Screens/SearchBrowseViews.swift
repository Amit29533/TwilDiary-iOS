import SwiftUI
import TwilDiaryCore

enum SearchBrowseRoute: Hashable {
    case shelf(SearchBrowseShelf)
    case titles(SearchBrowseCategory)
    case topics(SearchBrowseTopic)
    case tags([SearchBrowseTag], artwork: String?)
    case animeTopic(SearchBrowseTag)
    case tag(SearchBrowseTag)
    case theme(SearchBrowseTheme)
    case people(SearchBrowseShelf, [SearchBrowsePerson])
    case tvdbFranchise(TVDBDirect.Franchise)
    case ceremony(SearchAwardCeremony)
    case awardNominee(SearchAwardNominee)
}

struct SearchBrowseShelves: View {
    let shows: [CatalogItem]
    let kind: CatalogSearchView.Kind

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if kind == .people {
                SearchPeopleShelf(shelf: .actors)
                SearchPeopleShelf(shelf: .directors)
            }
            if kind == .anime { SearchTopicShelf(topic: .anime) }
            SearchTagsShelf(shows: shows, animeFirst: kind == .anime, movies: kind == .movies)
            shelf(.genres, categories: SearchBrowseCatalog.genres)
            SearchThemesShelf()
            ForEach(SearchBrowseTopic.allCases.filter { kind != .anime || $0 != .anime }) { SearchTopicShelf(topic: $0) }
            SearchAwardsShelf()
            SearchTVDBListShelf(shelf: .officialLists)
            shelf(.studios, categories: SearchBrowseCatalog.studios)
            if kind != .people {
                SearchPeopleShelf(shelf: .directors)
                SearchPeopleShelf(shelf: .actors)
            }
            shelf(.decades, categories: SearchBrowseCatalog.decades)
            SearchTVDBListShelf(shelf: .franchises)
            shelf(.worldCinema, categories: SearchBrowseCatalog.worldCinema)
            shelf(.internationalTV, categories: SearchBrowseCatalog.internationalTV)
            // Search Lab opens from the flask beside the search field.
        }.accessibilityIdentifier("search-browse")
    }

    private func shelf(_ shelf: SearchBrowseShelf, categories: [SearchBrowseCategory]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: shelf)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(categories.prefix(8)) { category in
                        SearchCategoryLink(category: category)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                min(shelf == .genres ? 210 : 164, width * (shelf == .genres ? 0.44 : 0.36))
                            }
                    }
                }.padding(.horizontal, 14)
            }.scrollIndicators(.hidden).padding(.horizontal, -14)
        }.accessibilityIdentifier("search-browse-" + shelf.rawValue)
    }
}

struct SearchBrowseHeading: View {
    let shelf: SearchBrowseShelf
    var destination: SearchBrowseRoute?
    var icon: String?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.headline).accessibilityHidden(true)
                }
                Text(shelf.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            }.foregroundStyle(HomeStyle.primary)
            Spacer(minLength: 0)
            if shelf == .tags, let destination {
                NavigationLink("Find tags", value: destination)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ThemeStore.accent)
                    .frame(minHeight: 44).buttonStyle(.springPress).accessibilityIdentifier("search-browse-more-tags")
            } else {
                SectionMoreLink(label: "See all " + shelf.title, value: destination ?? .shelf(shelf),
                                identifier: "search-browse-more-" + shelf.rawValue)
            }
        }
    }
}

struct SearchBrowseDestination: View {
    let route: SearchBrowseRoute
    @Environment(DiaryStore.self) private var store

    var body: some View {
        switch route {
        case .shelf(.themes):
            SearchThemesGrid()
        case .shelf(.awards):
            SearchAwardsPage()
        case .shelf(.franchises):
            SearchTVDBListsPage(shelf: .franchises)
        case .shelf(.officialLists):
            SearchTVDBListsPage(shelf: .officialLists)
        case .shelf(let shelf):
            SearchBrowseCategoryGrid(shelf: shelf, categories: categories(for: shelf))
        case .titles(let category):
            SearchBrowseTitlesPage(category: category, store: store)
        case .topics(let topic):
            SearchTopicGrid(topic: topic)
        case .animeTopic(let topic):
            SearchAnimeTagTitlesPage(tag: topic, fromTopic: true)
        case .tag(let tag):
            if tag.anilist { SearchAnimeTagTitlesPage(tag: tag).id(tag.id) }
            else { SearchTagTitlesPage(tag: tag).id(tag.id) }
        case .theme(let theme):
            SearchBrowseTitlesPage(category: theme.category, store: store, subtitle: "Theme")
        case .tags(let tags, let artwork):
            SearchTagsPage(tags: tags, artwork: artwork)
        case .people(let shelf, let people):
            SearchPeopleGrid(shelf: shelf, people: people)
        case .tvdbFranchise(let franchise):
            SearchTVDBFranchisePage(franchise: franchise)
        case .ceremony(let ceremony):
            SearchAwardCeremonyPage(ceremony: ceremony)
        case .awardNominee(let nominee):
            SearchAwardNomineePage(nominee: nominee)
        }
    }

    private func categories(for shelf: SearchBrowseShelf) -> [SearchBrowseCategory] {
        switch shelf {
        case .genres: SearchBrowseCatalog.genres
        case .decades: SearchBrowseCatalog.decades
        case .studios: SearchBrowseCatalog.studios
        case .worldCinema: SearchBrowseCatalog.worldCinema
        case .internationalTV: SearchBrowseCatalog.internationalTV
        default: []
        }
    }
}

private struct SearchBrowseCategoryGrid: View {
    let shelf: SearchBrowseShelf
    let categories: [SearchBrowseCategory]
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var region: SearchBrowseRegion?
    @State private var text = ""

    private var isCountryShelf: Bool { shelf == .worldCinema || shelf == .internationalTV }
    private var matching: [SearchBrowseCategory] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.filter {
            (region?.contains($0) ?? true) && (query.isEmpty || $0.title.localizedStandardContains(query))
        }
    }

    var body: some View {
        ExploreBrowsePage(title: shelf.title, symbol: shelf.browseSymbol) {
            VStack(alignment: .leading, spacing: 12) {
                if isCountryShelf || shelf == .studios {
                    let prompt = isCountryShelf ? "Find a country" : "Find a studio"
                    SearchField(placeholder: prompt, text: $text, label: prompt)
                }
                if isCountryShelf {
                    SearchBrowseFilterStrip {
                        Menu {
                            Picker("Region", selection: $region) {
                                Text("All regions").tag(nil as SearchBrowseRegion?)
                                ForEach(SearchBrowseRegion.allCases) { Text($0.rawValue).tag(Optional($0)) }
                            }
                        } label: {
                            ExplorePill(label: region?.rawValue ?? "Region", icon: "globe", tinted: region != nil)
                        }.accessibilityIdentifier("search-browse-region")
                    }
                }
                if matching.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                              count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(matching) { SearchCategoryLink(category: $0) }
                    }
                }
            }.padding(14).padding(.bottom, 32)
        }.scrollDismissesKeyboard(.interactively)

    }
}

struct SearchBrowseFilterStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) { content }.padding(.horizontal, 14)
        }.scrollIndicators(.hidden).padding(.horizontal, -14)
    }
}

struct SearchCategoryLink: View {
    let category: SearchBrowseCategory
    var destination: SearchBrowseRoute?
    var identifier: String?
    @Environment(DiaryStore.self) private var store
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 100
    private static var artworkCache: [SearchBrowseCategory.Filter: (url: String, date: Date)] = [:]
    @State private var studioLogo: String?
    @State private var preview: String?

    var body: some View {
        // The remembered picture straight away, so coming back to Search doesn't flash empty tiles.
        let remembered = Self.artworkCache[category.filter]?.url
        let owned = store.memoized("browse.art|\(category.filter)") { category.artwork(in: store.activeTitles) }
        let tileArt = owned ?? preview ?? (isStudio ? nil : remembered)
        let logo = studioLogo ?? (isStudio ? remembered : nil)
        NavigationLink(value: destination ?? .titles(category)) {
            if case .studio = category.filter {
                TitleStudioPlate(name: category.title, logo: logo)
                    .frame(height: height * 0.82)
            } else {
                SearchBrowseArtworkTile(title: category.title, symbol: category.symbol, tint: category.tint,
                                        artwork: tileArt)
            }
        }.buttonStyle(.springPress)
            .preference(key: BrowseCoverPreference.self, value: tileArt ?? logo)
            .accessibilityLabel(category.title)
            .accessibilityIdentifier(identifier ?? "search-category-" + category.title)
            .task { await loadArtwork() }
    }

    private var isStudio: Bool { if case .studio = category.filter { true } else { false } }

    private func loadArtwork() async {
        guard !store.isPreview else { return }
        if let cached = Self.artworkCache[category.filter] {
            if case .studio = category.filter { studioLogo = cached.url } else { preview = cached.url }
            if Date.now.timeIntervalSince(cached.date) < 86_400 { return }
        }
        if case .studio(let id) = category.filter {
            guard let token = TMDBDirect.token(store),
                  let company = try? await TMDBDirect.object("company/\(id)", query: [:], token: token),
                  !Task.isCancelled else { return }
            if let logo = CatalogTools.image(company["logo_path"] as? String, size: "w185") {
                studioLogo = logo
                Self.artworkCache[category.filter] = (logo, .now)
            }
        } else {
            guard category.artwork(in: store.workspace.activeTitles) == nil,
                  let type = category.types.first else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
                let page = try await LiveDiscoveryService(store: store).page(category.query(type: type))
                try Task.checkCancellation()
                if let image = page.items.lazy.compactMap({ $0.backdrop ?? CatalogTools.image($0.backdropPath, size: "w500") }).first {
                    preview = image
                    Self.artworkCache[category.filter] = (image, .now)
                }
            } catch { /* Keep the readable category card when no art is available. */ }
        }
    }
}

struct SearchBrowseArtworkTile: View {
    let title: String
    let symbol: String
    let tint: String
    let artwork: String?
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            let accent = Color(webHex: tint)
            Color.clear
                .overlay {
                    if let artwork {
                        Artwork(path: artwork, title: title, initialsOnly: false)
                    } else {
                        LinearGradient(colors: [accent.opacity(0.84), accent.opacity(0.24)], startPoint: .topTrailing, endPoint: .bottomLeading)
                        Image(systemName: symbol)
                            .font(.system(size: 43, weight: .light)).foregroundStyle(.white.opacity(0.24))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom)
                }
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .lineLimit(3).padding(12)
        }.frame(height: height)
            .frame(maxWidth: .infinity).background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }

}

private struct TitleStudioPlate: View {
    let name: String
    let logo: String?

    var body: some View {
        Group {
            if let logo {
                Artwork(path: logo, title: name, contentMode: .fit)
                    .padding(6)
                    .background(Color(webHex: "#79767e"), in: RoundedRectangle(cornerRadius: 6))
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(name).font(.headline.weight(.heavy)).multilineTextAlignment(.center).lineLimit(2)
                    .minimumScaleFactor(0.75).foregroundStyle(HomeStyle.primary)
                    .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SearchBrowseTitlesPage: View {
    let category: SearchBrowseCategory
    let tag: SearchBrowseTag?
    let subtitle: String?
    @State private var type: MediaKind
    @State private var refinements = DiscoveryFilters(section: .genres)
    @State private var results: DiscoveryResults
    @State private var requested: [String: String]?

    private var query: [String: String] { category.query(type: type, refinements: refinements) }
    private var studios: [SearchBrowseCategory] {
        SearchBrowseCatalog.studios.filter { $0.types.contains(type) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var decades: [Int] {
        SearchBrowseCatalog.decades.compactMap { if case .decade(let year) = $0.filter { return year }; return nil }
    }
    private var sortLabel: String {
        switch refinements.sort {
        case "rating": "Highest rated"
        case "newest": "Newest"
        default: "Popular"
        }
    }

    init(category: SearchBrowseCategory, store: DiaryStore, tag: SearchBrowseTag? = nil, subtitle: String? = nil) {
        self.subtitle = subtitle
        self.tag = tag
        self.category = category
        _type = State(initialValue: category.types.first ?? .movie)
        _results = State(initialValue: DiscoveryResults(service: LiveDiscoveryService(store: store, recoverBrowseReads: true)))
    }

    var body: some View {
        ExploreBrowsePage(title: tag.map { $0.displayName ?? $0.name.capitalizedTag } ?? category.title,
                          symbol: category.symbol, emoji: tag?.emoji, subtitle: tag == nil ? subtitle : "Tag",
                          artwork: ExploreBrowseHeader.artwork(in: results.items)) {
            VStack(alignment: .leading, spacing: 14) {
                if case .country(let code, _) = category.filter {
                    let country = Locale.current.localizedString(forRegionCode: code) ?? code
                    Text("Production country · " + country).font(.subheadline).foregroundStyle(.secondary)
                }
                if category.filter == .hiddenGems {
                    Text("TMDB score of 7.0 or higher with 50–500 votes.")
                        .font(.footnote).foregroundStyle(HomeStyle.secondary)
                }
                filters
                if requested != query || results.loading && results.items.isEmpty {
                    DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterGrid(columns: 3, rows: 2))
                } else {
                    if !results.items.isEmpty { CatalogGrid(items: results.items, showsLayoutToggle: false, forceGrid: true) }
                    if let error = results.error {
                        RetryNotice(message: error) { Task { await load(more: results.page > 0) } }
                    } else if results.hasMore {
                        ScrollLoadTrigger(token: results.page, loading: results.loading) { Task { await load(more: true) } }
                    } else if results.items.isEmpty {
                        ContentUnavailableView("No titles found", systemImage: "film",
                                               description: Text("Try changing a filter."))
                    }
                }
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 54)
        }
            .task(id: query) { await load(query) }
    }

    private var filters: some View {
        SearchBrowseFilterStrip {
            if category.types.count > 1 {
                Menu {
                    ForEach(category.types, id: \.self) { kind in
                        Button(kind == .movie ? "Movies" : "Shows") {
                            if !DiscoveryGenre.names(type: kind.rawValue).contains(refinements.genre) { refinements.genre = "" }
                            if let company = refinements.company, !SearchBrowseCatalog.studios.contains(where: {
                                $0.filter == .studio(company) && $0.types.contains(kind)
                            }) {
                                refinements.company = nil
                            }
                            type = kind
                        }
                    }
                } label: { ExplorePill(label: type == .movie ? "Movies" : "Shows", icon: "film") }
                    .accessibilityIdentifier("search-browse-type")
            }
            Menu {
                Picker("Sort", selection: $refinements.sort) {
                    Text("Popular").tag("popular")
                    Text("Highest rated").tag("rating")
                    Text("Newest").tag("newest")
                }
            } label: { ExplorePill(label: sortLabel, icon: "arrow.up.arrow.down", tinted: refinements.sort != "popular") }
                .accessibilityIdentifier("search-browse-sort")
            Menu {
                Picker("Rating", selection: $refinements.minimum) {
                    Text("Any rating").tag("0")
                    ForEach(["5", "6", "7", "8", "9"], id: \.self) { Text($0 + "+").tag($0) }
                }
            } label: {
                ExplorePill(label: refinements.minimum == "0" ? "Rating" : refinements.minimum + "+",
                            icon: "star", tinted: refinements.minimum != "0")
            }.accessibilityIdentifier("search-browse-rating")
            if category.allowsStudioFilter {
                Menu {
                    Picker("Studio", selection: $refinements.company) {
                        Text("Any studio").tag(nil as Int?)
                        ForEach(studios) { studio in
                            if case .studio(let id) = studio.filter { Text(studio.title).tag(Optional(id)) }
                        }
                    }
                } label: {
                    let selected = refinements.company.flatMap { id in studios.first { $0.filter == .studio(id) }?.title }
                    ExplorePill(label: selected ?? "Studio", icon: "building.2", tinted: selected != nil)
                }.accessibilityIdentifier("search-browse-studio")
            }
            if category.allowsPeriodFilter {
                Menu {
                    Picker("Period", selection: period) {
                        Text("Any period").tag(nil as Int?)
                        ForEach(decades, id: \.self) { Text("\($0)s").tag(Optional($0)) }
                    }
                } label: {
                    ExplorePill(label: refinements.yearFrom.map { "\($0)s" } ?? "Period",
                                icon: "calendar", tinted: refinements.yearFrom != nil)
                }.accessibilityIdentifier("search-browse-period")
            }
            if category.allowsGenreFilter {
                Menu {
                    Picker("Genre", selection: $refinements.genre) {
                        Text("Any genre").tag("")
                        ForEach(DiscoveryGenre.all.filter { type == .tv ? $0.tv != nil : $0.movie != nil }.map(\.name), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } label: {
                    ExplorePill(label: refinements.genre.isEmpty ? "Genre" : refinements.genre,
                                icon: "square.grid.2x2", tinted: !refinements.genre.isEmpty)
                }.accessibilityIdentifier("search-browse-genre")
            }
            if refinements != DiscoveryFilters(section: .genres) || type != category.types.first {
                Button("Reset") {
                    refinements = DiscoveryFilters(section: .genres)
                    type = category.types.first ?? .movie
                }.font(.subheadline.weight(.semibold)).tint(ThemeStore.accent).frame(minHeight: 44)
                    .accessibilityIdentifier("search-browse-reset")
            }
        }
    }

    private var period: Binding<Int?> {
        Binding(get: { refinements.yearFrom }, set: { year in
            refinements.yearFrom = year
            refinements.yearTo = year.map { $0 + 9 }
        })
    }

    private func load(_ filters: [String: String]? = nil, more: Bool = false) async {
        let filters = filters ?? query
        guard filters == query else { return }
        requested = filters
        await results.load(filters, more: more)
    }
}
