import SwiftUI
import TwilDiaryCore

enum SearchBrowseRoute: Hashable {
    case shelf(SearchBrowseShelf)
    case titles(SearchBrowseCategory)
    case tags([SearchBrowseTag])
    case tag(SearchBrowseTag)
    case theme(SearchBrowseTheme)
    case people(SearchBrowseShelf, [SearchBrowsePerson])
    case franchise(SearchBrowseFranchise)
    case ceremony(SearchAwardEdition)
    case awardTitle(String, MediaKind, ceremonyYear: Int)
}

struct SearchBrowseShelves: View {
    let shows: [CatalogItem]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            SearchTagsShelf(shows: shows)
            shelf(.genres, categories: SearchBrowseCatalog.genres)
            SearchThemesShelf()
            NavigationLink(value: SearchLabRoute()) {
                HStack {
                    Label("Search Lab", systemImage: "slider.horizontal.3").font(.headline)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        .foregroundStyle(HomeStyle.secondary).accessibilityHidden(true)
                }.foregroundStyle(HomeStyle.primary).padding(.horizontal, 14)
                    .frame(minHeight: 48).cardSurface(14).contentShape(Rectangle())
            }.buttonStyle(.springPress).accessibilityIdentifier("search-browse-lab")
            SearchAwardsShelf()
            shelf(.studios, categories: SearchBrowseCatalog.studios)
            SearchPeopleShelf(shelf: .directors)
            SearchPeopleShelf(shelf: .actors)
            shelf(.decades, categories: SearchBrowseCatalog.decades)
            SearchFranchisesShelf()
            shelf(.worldCinema, categories: SearchBrowseCatalog.worldCinema)
            shelf(.internationalTV, categories: SearchBrowseCatalog.internationalTV)
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
            SearchFranchiseGrid()
        case .shelf(let shelf):
            SearchBrowseCategoryGrid(shelf: shelf, categories: categories(for: shelf))
        case .titles(let category):
            SearchBrowseTitlesPage(category: category, store: store)
        case .tag(let tag):
            SearchTagTitlesPage(tag: tag)
        case .theme(let theme):
            switch theme.content {
            case .keyword(let name):
                SearchTagTitlesPage(tag: SearchBrowseTag(name: name), title: theme.style.title, types: theme.types)
            case .category(let filter):
                SearchBrowseTitlesPage(
                    category: SearchBrowseCategory(title: theme.style.title, symbol: theme.style.icon,
                                                   tint: theme.style.start, filter: filter, types: theme.types),
                    store: store
                )
            }
        case .tags(let tags):
            SearchTagsPage(tags: tags)
        case .people(let shelf, let people):
            SearchPeopleGrid(shelf: shelf, people: people)
        case .franchise(let franchise):
            SearchFranchisePage(franchise: franchise)
        case .ceremony(let edition):
            SearchAwardEditionPage(edition: edition)
        case .awardTitle(let name, let kind, let ceremonyYear):
            SearchAwardTitlePage(title: name, kind: kind, ceremonyYear: ceremonyYear)
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

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(categories) { SearchCategoryLink(category: $0) }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(shelf.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SearchCategoryLink: View {
    let category: SearchBrowseCategory
    @Environment(DiaryStore.self) private var store
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 100
    @State private var studioLogo: String?
    @State private var preview: String?

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.titles(category)) {
            if case .studio = category.filter {
                TitleStudioPlate(name: category.title, logo: studioLogo)
                    .frame(height: height * 0.82)
            } else {
                landscape
            }
        }.buttonStyle(.springPress)
            .accessibilityLabel(category.title)
            .accessibilityIdentifier("search-category-" + category.title)
            .task { await loadArtwork() }
    }

    private var landscape: some View {
        ZStack(alignment: .bottomLeading) {
            let accent = Color(webHex: category.tint)
            Color.clear
                .overlay {
                    if let path = category.artwork(in: store.workspace.activeTitles) ?? preview {
                        Artwork(path: path, title: category.title, initialsOnly: false)
                    } else {
                        LinearGradient(colors: [accent.opacity(0.84), accent.opacity(0.24)], startPoint: .topTrailing, endPoint: .bottomLeading)
                        Image(systemName: category.symbol)
                            .font(.system(size: 43, weight: .light)).foregroundStyle(.white.opacity(0.24))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom)
                }
            Text(category.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .lineLimit(3).padding(12)
        }.frame(height: height)
            .frame(maxWidth: .infinity).background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func loadArtwork() async {
        guard !store.isPreview else { return }
        if case .studio(let id) = category.filter {
            guard studioLogo == nil, let token = TMDBDirect.token(store),
                  let company = try? await TMDBDirect.object("company/\(id)", query: [:], token: token),
                  !Task.isCancelled else { return }
            studioLogo = CatalogTools.image(company["logo_path"] as? String, size: "w185")
        } else {
            guard preview == nil, category.artwork(in: store.workspace.activeTitles) == nil,
                  let type = category.types.first else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
                let page = try await LiveDiscoveryService(store: store).page(category.query(type: type))
                try Task.checkCancellation()
                preview = page.items.lazy.compactMap { $0.backdrop ?? CatalogTools.image($0.backdropPath, size: "w500") }.first
            } catch { /* Keep the readable category card when no art is available. */ }
        }
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
    @State private var type: MediaKind
    @State private var results: DiscoveryResults
    @State private var requestedType: MediaKind?

    init(category: SearchBrowseCategory, store: DiaryStore) {
        self.category = category
        _type = State(initialValue: category.types.first ?? .movie)
        _results = State(initialValue: DiscoveryResults(service: LiveDiscoveryService(store: store)))
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if category.filter == .hiddenGems {
                    Text("TMDB score of 7.0 or higher with 50–500 votes.")
                        .font(.footnote).foregroundStyle(HomeStyle.secondary)
                }
                if category.types.count > 1 {
                    Picker("Title type", selection: $type) {
                        ForEach(category.types, id: \.self) { value in
                            Text(value == .movie ? "Movies" : "Shows").tag(value)
                        }
                    }.pickerStyle(.segmented)
                }
                if requestedType != type || results.loading && results.items.isEmpty {
                    DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterGrid(columns: 3, rows: 2))
                } else {
                    if !results.items.isEmpty { CatalogGrid(items: results.items, showsLayoutToggle: false, forceGrid: true) }
                    if let error = results.error {
                        RetryNotice(message: error) { Task { await load(more: results.page > 0) } }
                    } else if results.hasMore {
                        ScrollLoadTrigger(token: results.page, loading: results.loading) { Task { await load(more: true) } }
                    } else if results.items.isEmpty {
                        ContentUnavailableView("No titles found", systemImage: "film")
                    }
                }
            }.padding(14).padding(.bottom, 40)
        }.diaryScreenBackground().navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: type) { await load() }
    }

    private func load(more: Bool = false) async {
        requestedType = type
        await results.load(category.query(type: type), more: more)
    }
}
