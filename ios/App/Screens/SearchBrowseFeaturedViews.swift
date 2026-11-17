import SwiftUI
import TwilDiaryCore

struct SearchTagsShelf: View {
    let shows: [CatalogItem]
    @Environment(DiaryStore.self) private var store
    @ScaledMetric(relativeTo: .subheadline) private var tagRowHeight: CGFloat = 44
    @State private var popular: [SearchBrowseTag] = []
    @State private var loadedKeys: [String] = []

    private var tags: [SearchBrowseTag] {
        let names = Set(popular.map(\.id))
        return popular + SearchBrowseTag.suggestions.filter { !names.contains($0.id) }
    }

    private var featured: [SearchBrowseTag] {
        let anime = SearchBrowseTag.animeSuggestions.filter { anime in
            !tags.prefix(16).contains { $0.name.caseInsensitiveCompare(anime.name) == .orderedSame }
        }
        return Array(tags.prefix(8)) + Array(anime.prefix(8)) + Array(tags.dropFirst(8).prefix(8))
    }

    var body: some View {
        let keys = shows.prefix(5).map(\.key)
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .tags, destination: .tags(tags))
            Text("Film, TV and anime tags")
                .font(.subheadline).foregroundStyle(HomeStyle.secondary)
            ScrollView(.horizontal) {
                let rows = Array(repeating: GridItem(.fixed(tagRowHeight), spacing: 4, alignment: .leading), count: 2)
                LazyHGrid(rows: rows, alignment: .top, spacing: 8) {
                    ForEach(featured) { SearchTagLink(tag: $0) }
                }.padding(.horizontal, 14)
            }.padding(.horizontal, -14).scrollIndicators(.hidden)
        }.task(id: keys) {
            guard !keys.isEmpty, keys != loadedKeys else { return }
            let found = await SearchBrowseTag.popular(from: shows, store: store)
            guard !Task.isCancelled else { return }
            popular = found
            loadedKeys = keys
        }
    }
}

struct SearchTagsPage: View {
    let tags: [SearchBrowseTag]
    @Environment(DiaryStore.self) private var store
    @State private var text = ""
    @State private var anime = false
    @State private var animeTags: [SearchBrowseTag] = SearchBrowseTag.animeSuggestions
    @State private var animeTagLimit = 60
    @State private var loadedAnime = false
    @State private var animeFailure: String?
    @State private var matches: [SearchBrowseTag] = []
    @State private var completed: String?
    @State private var failure: String?
    private var query: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
    private var animeMatches: [SearchBrowseTag] {
        query.isEmpty ? animeTags : animeTags.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                SearchField(placeholder: "Find tags", text: $text, label: "Find tags")
                SearchBrowseFilterStrip {
                    Menu {
                        Picker("Catalog", selection: $anime) {
                            Text("Film and TV · TMDB").tag(false)
                            Text("Anime · AniList").tag(true)
                        }
                    } label: {
                        ExplorePill(label: anime ? "Anime · AniList" : "Film and TV · TMDB", icon: "tag", tinted: anime)
                    }.accessibilityIdentifier("search-tag-catalog")
                }
                if anime {
                    InlineFlowLayout { ForEach(animeMatches.prefix(animeTagLimit)) { SearchTagLink(tag: $0) } }
                    if let animeFailure {
                        RetryNotice(message: animeFailure) { Task { await loadAnimeTags() } }
                    } else if loadedAnime, animeMatches.isEmpty {
                        Text("No anime tags match “\(query)”.").font(.subheadline).foregroundStyle(.secondary)
                    } else if animeMatches.count > animeTagLimit {
                        Button("Show more tags") { animeTagLimit += 60 }
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                            .cardSurface(14).foregroundStyle(ThemeStore.accent).buttonStyle(.springPress)
                    }
                } else if query.count < 2 {
                    InlineFlowLayout { ForEach(tags) { SearchTagLink(tag: $0) } }
                } else if completed != query {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Finding tags")
                } else if let failure {
                    RetryNotice(message: failure) { Task { await find(query) } }
                } else if matches.isEmpty {
                    Text("No tags match “\(query)”.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    InlineFlowLayout { ForEach(matches) { SearchTagLink(tag: $0) } }
                }
            }.padding(14)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground().navigationTitle("Find tags").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: anime ? "" : query) {
                guard !anime, query.count >= 2, completed != query else { return }
                let requested = query
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await find(requested)
            }
            .task(id: anime) {
                if anime && !loadedAnime { await loadAnimeTags() }
            }
    }

    private func loadAnimeTags() async {
        animeFailure = nil
        do {
            let names = store.isPreview ? SearchBrowseTag.animeSuggestions.map(\.name)
                : try await AniListClient.shared.searchBrowseTags()
            try Task.checkCancellation()
            animeTags = names.map { SearchBrowseTag(name: $0, anilist: true) }
            loadedAnime = true
        } catch is CancellationError { }
        catch { if !Task.isCancelled { animeFailure = error.localizedDescription } }
    }

    private func find(_ requested: String) async {
        guard requested == query else { return }
        completed = nil; failure = nil
        do {
            let found = try await SearchBrowseTag.find(requested, store: store)
            guard !Task.isCancelled, requested == query else { return }
            matches = found; completed = requested
        } catch {
            guard !Task.isCancelled, requested == query else { return }
            failure = error.localizedDescription; completed = requested
        }
    }
}

private struct SearchTagLink: View {
    let tag: SearchBrowseTag

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.tag(tag)) {
            HStack(spacing: 6) {
                Text(tag.emoji).accessibilityHidden(true)
                Text(tag.name.prefix(1).uppercased() + tag.name.dropFirst()).lineLimit(1)
                if tag.anilist {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(ThemeStore.accent)
                        .accessibilityLabel("Anime")
                }
            }.font(.subheadline.weight(.medium)).foregroundStyle(HomeStyle.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(HomeStyle.round, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityIdentifier("search-tag-" + tag.id)
    }
}

struct SearchTagTitlesPage: View {
    let tag: SearchBrowseTag
    @Environment(DiaryStore.self) private var store
    @State private var category: SearchBrowseCategory?
    @State private var failure: String?

    var body: some View {
        if let category {
            SearchBrowseTitlesPage(category: category, store: store)
        } else {
            EdgeToEdgeScroll(frosted: true) {
                if let failure {
                    RetryNotice(message: failure) { Task { await load() } }.padding(14)
                } else {
                    DiaryLoadingPlaceholder(label: "Finding tag", layout: .posterGrid(columns: 3, rows: 2)).padding(14)
                }
            }.diaryScreenBackground().navigationTitle(tag.name.capitalized).navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .task { await load() }
        }
    }

    private func load() async {
        failure = nil
        do { category = try await tag.resolve(store: store) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct SearchAnimeTagTitlesPage: View {
    let tag: SearchBrowseTag
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    private enum Order: String, CaseIterable, Identifiable {
        case popular = "POPULARITY_DESC", rating = "SCORE_DESC", newest = "START_DATE_DESC"
        var id: Self { self }
        var label: String {
            switch self { case .popular: "Popular"; case .rating: "Highest rated"; case .newest: "Newest" }
        }
    }
    private struct Filters: Hashable {
        var order = Order.popular
        var minimum: Int?
        var period: Int?
    }
    @State private var filters = Filters()
    @State private var requested: Filters?
    @State private var items: [AniAppearance] = []
    @State private var page = 0
    @State private var hasNext = false
    @State private var requestID: UUID?
    @State private var failure: String?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                filterStrip
                if requested != filters || requestID != nil && items.isEmpty {
                    DiaryLoadingPlaceholder(label: "Loading anime", layout: .posterGrid(columns: 3, rows: 2))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                              count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 16) {
                        ForEach(items) { item in
                            AnimeAppearanceButton(appearance: item) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                                        .overlay { Artwork(path: item.cover, title: item.title) }
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .bottomLeading) {
                                            if let rating = item.rating { RatingBadge(score: rating, source: "AniList").padding(5) }
                                        }
                                    ProfileCardCaption(title: item.title)
                                    if let year = item.year {
                                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.springPress)
                        }
                    }
                    if let failure {
                        RetryNotice(message: failure) { Task { await load(filters, page: page + 1) } }
                    } else if hasNext {
                        ScrollLoadTrigger(token: page, loading: requestID != nil) {
                            Task { await load(filters, page: page + 1) }
                        }
                    } else if items.isEmpty {
                        ContentUnavailableView("No anime found", systemImage: "film")
                    }
                }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(tag.name).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: filters) {
                if requested != filters || page == 0 && failure == nil { await load(filters, page: 1) }
            }
    }

    private var filterStrip: some View {
        SearchBrowseFilterStrip {
            Menu {
                Picker("Sort", selection: $filters.order) {
                    ForEach(Order.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                ExplorePill(label: filters.order.label, icon: "arrow.up.arrow.down", tinted: filters.order != .popular)
            }
            Menu {
                Picker("Rating", selection: $filters.minimum) {
                    Text("Any rating").tag(nil as Int?)
                    ForEach(5...9, id: \.self) { Text("\($0)+").tag(Optional($0)) }
                }
            } label: {
                ExplorePill(label: filters.minimum.map { "\($0)+" } ?? "Rating", icon: "star", tinted: filters.minimum != nil)
            }
            Menu {
                Picker("Period", selection: $filters.period) {
                    Text("Any period").tag(nil as Int?)
                    ForEach(Array(stride(from: Calendar.current.component(.year, from: .now) / 10 * 10,
                                         through: 1960, by: -10)), id: \.self) { Text("\($0)s").tag(Optional($0)) }
                }
            } label: {
                ExplorePill(label: filters.period.map { "\($0)s" } ?? "Period", icon: "calendar", tinted: filters.period != nil)
            }
            if filters != Filters() {
                Button("Reset") { filters = Filters() }
                    .font(.subheadline.weight(.semibold)).tint(ThemeStore.accent).frame(minHeight: 44)
            }
        }
    }

    private func load(_ selection: Filters, page number: Int) async {
        guard selection == filters, number == 1 || requestID == nil && page + 1 == number && requested == selection else { return }
        let id = UUID()
        requestID = id
        if number == 1 { items = []; page = 0; hasNext = false; requested = selection }
        failure = nil
        defer { if id == requestID { requestID = nil } }
        do {
            #if DEBUG
            if store.isPreview {
                items = AniListPreview.detail(2).appearances
                page = number
                hasNext = false
                return
            }
            #endif
            let result = try await AniListClient.shared.browseTag(tag.name, page: number, sort: selection.order.rawValue,
                                                                 minimum: selection.minimum, period: selection.period)
            guard !Task.isCancelled, id == requestID, selection == filters else { return }
            var ids = Set(items.map(\.id))
            items += result.items.filter { ids.insert($0.id).inserted }
            page = number
            hasNext = result.hasNext
        } catch {
            if !Task.isCancelled, id == requestID, selection == filters { failure = error.localizedDescription }
        }
    }
}

struct SearchThemesShelf: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let largeType = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .themes, icon: "square.grid.2x2")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(SearchBrowseTheme.allCases) { theme in
                        SearchThemeCard(theme: theme)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                largeType ? min(280, width * 0.8) : min(194, width * 0.39)
                            }
                    }
                }.padding(.horizontal, 14)
            }.scrollIndicators(.hidden).padding(.horizontal, -14)
        }
    }
}

struct SearchThemesGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2),
                      spacing: 12) {
                ForEach(SearchBrowseTheme.allCases) { SearchThemeCard(theme: $0) }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(SearchBrowseShelf.themes.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SearchThemeCard: View {
    let theme: SearchBrowseTheme
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 92

    var body: some View {
        let style = theme.style
        NavigationLink(value: SearchBrowseRoute.theme(theme)) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: style.icon).font(.title3.weight(.semibold))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(style.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(.white).padding(12).frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [Color(webHex: style.start), Color(webHex: style.end)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.springPress).accessibilityIdentifier("search-theme-" + theme.rawValue)
    }
}

struct SearchPeopleShelf: View {
    let shelf: SearchBrowseShelf
    @Environment(DiaryStore.self) private var store
    @State private var popular: [SearchBrowsePerson] = []
    @State private var loadedRevision: UUID?

    private var people: [SearchBrowsePerson] {
        let ids = Set(popular.map(\.id))
        let selections = SearchBrowsePerson.selections(for: shelf)
        return popular + selections.filter { !ids.contains($0.id) }.prefix(max(0, 12 - popular.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: shelf, destination: .people(shelf, people))
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(people.prefix(12)) { person in
                        SearchBrowsePersonLink(person: person)
                            .containerRelativeFrame(.horizontal) { width, _ in min(130, width * 0.27) }
                    }
                }.padding(.horizontal, 14)
            }.padding(.horizontal, -14).scrollIndicators(.hidden)
        }.task(id: store.discoveryRevision) {
            let revision = store.discoveryRevision
            guard revision != loadedRevision else { return }
            popular = []
            if let result = try? await SearchBrowsePerson.popular(for: shelf, store: store),
               !Task.isCancelled, revision == store.discoveryRevision {
                var seen = Set<Int>()
                popular = result.people.filter { seen.insert($0.id).inserted }
                loadedRevision = revision
            }
        }
    }
}

struct SearchPeopleGrid: View {
    let shelf: SearchBrowseShelf
    let people: [SearchBrowsePerson]
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DiaryStore.self) private var store
    @State private var online: [SearchBrowsePerson] = []
    @State private var nextPage: Int? = 1
    @State private var loading = false
    @State private var failure: String?
    @State private var useTrakt = false
    @State private var traktPeople: [SearchBrowsePerson]?
    @State private var traktRequest: UUID?
    @State private var traktFailure: String?
    @State private var alphabetical = false
    @State private var text = ""

    private var matching: [SearchBrowsePerson] {
        var seen = Set<Int>()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = useTrakt ? traktPeople ?? [] : people + online + SearchBrowsePerson.selections(for: shelf)
        let entries = source.filter {
            seen.insert($0.id).inserted && (query.isEmpty || $0.name.localizedStandardContains(query))
        }
        return alphabetical ? entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : entries
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                SearchField(placeholder: "Filter by name", text: $text, label: "Filter by name")
                SearchBrowseFilterStrip {
                    Menu {
                        Picker("Source", selection: $useTrakt) {
                            Text("Popular on TMDB").tag(false)
                            Text("From Trakt’s trend charts").tag(true)
                        }
                    } label: {
                        ExplorePill(label: useTrakt ? "Trakt charts" : "TMDB", icon: "person.2", tinted: useTrakt)
                    }.accessibilityIdentifier("search-people-source")
                    Menu {
                        Picker("Order", selection: $alphabetical) {
                            Text(useTrakt ? "Chart order" : "Popular").tag(false)
                            Text("Name A–Z").tag(true)
                        }
                    } label: {
                        ExplorePill(label: alphabetical ? "Name A–Z" : useTrakt ? "Chart order" : "Popular",
                                    icon: "arrow.up.arrow.down", tinted: alphabetical)
                    }
                }
                if useTrakt && (traktRequest != nil || traktPeople == nil && traktFailure == nil) {
                    DiaryLoadingPlaceholder(label: "Loading current Trakt credits")
                } else if useTrakt, let traktFailure {
                    RetryNotice(message: traktFailure) { Task { await loadTrakt() } }
                } else if matching.isEmpty {
                    ContentUnavailableView("No matching names", systemImage: "person")
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                              count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 18) {
                        ForEach(matching) { SearchBrowsePersonLink(person: $0) }
                    }
                }
                if !useTrakt && loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Loading more people")
                } else if !useTrakt, let failure {
                    RetryNotice(message: failure) { Task { await loadMore() } }
                } else if !useTrakt && nextPage != nil {
                    Button("Load more") { Task { await loadMore() } }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        .cardSurface(14).foregroundStyle(ThemeStore.accent).buttonStyle(.springPress)
                        .accessibilityIdentifier("search-browse-more-people")
                }
            }.padding(14).padding(.bottom, 32)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground().navigationTitle(shelf.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { if nextPage == 1 && failure == nil { await loadMore(initial: true) } }
            .task(id: useTrakt) {
                if useTrakt && traktPeople == nil { await loadTrakt() }
            }
    }

    private func loadTrakt() async {
        let request = UUID()
        traktRequest = request
        traktFailure = nil
        defer { if traktRequest == request { traktRequest = nil } }
        do {
            let result = try await SearchBrowseTrakt.people(for: shelf, store: store)
            guard !Task.isCancelled, traktRequest == request else { return }
            traktPeople = result
        }
        catch is CancellationError { }
        catch { if !Task.isCancelled, traktRequest == request { traktFailure = error.localizedDescription } }
    }

    private func loadMore(initial: Bool = false) async {
        guard nextPage != nil, !loading else { return }
        loading = true
        failure = nil
        defer { loading = false }
        // A few pages often contain only actors. Bound each request from the Directors screen.
        let limit = initial || shelf == .actors ? 1 : 4
        do {
            var seen = Set(online.map(\.id))
            for _ in 0..<limit {
                guard let page = nextPage else { break }
                let reply = try await SearchBrowsePerson.popular(for: shelf, page: page, store: store)
                try Task.checkCancellation()
                let new = reply.people.filter { seen.insert($0.id).inserted }
                online += new
                nextPage = reply.next
                if !new.isEmpty { break }
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct SearchBrowsePersonLink: View {
    let person: SearchBrowsePerson
    @Environment(DiaryStore.self) private var store
    @State private var image: String?

    var body: some View {
        NavigationLink(value: PersonRoute(id: person.id)) {
            VStack(spacing: 6) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { Artwork(path: person.image ?? image, title: person.name, alignment: .top) }
                    .clipShape(Circle())
                ProfileCardCaption(title: person.name).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.springPress)
            .task {
                guard person.image == nil, image == nil, !store.isPreview, let token = TMDBDirect.token(store) else { return }
                if let reply = try? await TMDBDirect.object("person/\(person.id)", query: [:], token: token), !Task.isCancelled {
                    image = CatalogTools.image(reply["profile_path"] as? String, size: "w185")
                }
            }
    }
}

struct SearchFranchisesShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: .franchises)
            Text("Curated collections").font(.subheadline).foregroundStyle(HomeStyle.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(SearchBrowseFranchise.featured) { franchise in
                        SearchFranchiseLink(franchise: franchise)
                            .containerRelativeFrame(.horizontal) { width, _ in min(215, width * 0.44) }
                    }
                }.padding(.horizontal, 14)
            }.padding(.horizontal, -14).scrollIndicators(.hidden)
        }
    }
}

struct SearchFranchiseGrid: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case all = "All franchises", movies = "Movies", shows = "TV"
        var id: Self { self }
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DiaryStore.self) private var store
    @State private var useTVDB = false
    @State private var kind = Kind.all
    @State private var text = ""
    @State private var completed: String?
    @State private var online: [SearchBrowseFranchise] = []
    @State private var nextPage: Int?
    @State private var failure: String?
    @State private var requestID: UUID?
    private var query: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
    private var remoteQuery: String { useTVDB || kind == .shows || query.count < 2 ? "" : query }
    private var matching: [SearchBrowseFranchise] {
        let films = kind == .shows ? [] : SearchBrowseFranchise.collections
        let shows = kind == .movies ? [] : SearchBrowseFranchise.television
        let entries = Array(films.prefix(4)) + shows + films.dropFirst(4)
        let local = entries.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.shows.contains { $0.name.localizedStandardContains(query) }
        }
        guard !remoteQuery.isEmpty, completed == remoteQuery else { return local }
        var seen = Set<Int>()
        return (local + online).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                SearchField(placeholder: "Find a franchise", text: $text, label: "Find a franchise")
                SearchBrowseFilterStrip {
                    Menu {
                        Picker("Catalog", selection: $useTVDB) {
                            Text("Featured and TMDB").tag(false)
                            Text("TheTVDB lists").tag(true)
                        }
                    } label: {
                        ExplorePill(label: useTVDB ? "TheTVDB" : "Featured and TMDB", icon: "square.stack", tinted: useTVDB)
                    }.accessibilityIdentifier("search-franchise-catalog")
                    if !useTVDB {
                        Menu {
                            Picker("Type", selection: $kind) {
                                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            ExplorePill(label: kind.rawValue, icon: "film", tinted: kind != .all)
                        }.accessibilityIdentifier("search-franchise-type")
                    }
                }
                if useTVDB { SearchTVDBFranchises(query: query).id(query) }
                else { featuredResults }
            }.padding(14).padding(.bottom, 32)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground().navigationTitle(SearchBrowseShelf.franchises.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: remoteQuery) {
                let requested = remoteQuery
                guard !requested.isEmpty, requested != completed else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await find(requested, page: 1)
            }
    }

    private var featuredResults: some View {
        Group {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                      count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(matching) { SearchFranchiseLink(franchise: $0) }
            }
            if !remoteQuery.isEmpty {
                if completed != remoteQuery || requestID != nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Finding collections")
                } else if let failure {
                    RetryNotice(message: failure) { Task { await find(remoteQuery, page: nextPage ?? 1) } }
                } else if let nextPage {
                    Button("Load more") { Task { await find(remoteQuery, page: nextPage) } }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        .cardSurface(14).foregroundStyle(ThemeStore.accent).buttonStyle(.springPress)
                } else if matching.isEmpty {
                    ContentUnavailableView("No franchises found", systemImage: "film")
                }
            } else if !query.isEmpty && matching.isEmpty {
                ContentUnavailableView("No franchises found", systemImage: "film")
            }
        }
    }

    private func find(_ requested: String, page: Int) async {
        guard !requested.isEmpty, requested == remoteQuery,
              page == 1 || requestID == nil && nextPage == page else { return }
        let id = UUID()
        requestID = id
        failure = nil
        if page == 1 { online = []; nextPage = nil; completed = nil }
        defer { if id == requestID { requestID = nil } }
        do {
            let found = try await SearchBrowseFranchise.find(requested, page: page, store: store)
            guard !Task.isCancelled, id == requestID, requested == remoteQuery else { return }
            online += found.collections
            nextPage = found.next
            completed = requested
        } catch {
            guard !Task.isCancelled, id == requestID, requested == remoteQuery else { return }
            failure = error.localizedDescription
            completed = requested
        }
    }
}

private struct SearchFranchiseLink: View {
    let franchise: SearchBrowseFranchise
    @Environment(DiaryStore.self) private var store
    @State private var posters: [String] = []

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.franchise(franchise)) {
            CanvasListCard(title: franchise.title, posters: cardPosters)
        }.buttonStyle(.springPress)
            .accessibilityIdentifier("search-franchise-\(franchise.id)")
            .task {
                guard franchise.shows.isEmpty, franchise.poster == nil, posters.isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let collection = try? await franchise.load(store: store), !Task.isCancelled else { return }
                posters = Array(collection.parts.compactMap(\.posterPath).prefix(3))
            }
    }

    private var cardPosters: [String] {
        if !franchise.shows.isEmpty { return Array(franchise.shows.map(\.poster).prefix(3)) }
        if let poster = franchise.poster { return [poster] }
        return posters
    }
}

struct SearchFranchisePage: View {
    let franchise: SearchBrowseFranchise
    @Environment(DiaryStore.self) private var store
    @State private var collection: TitleCollection?
    @State private var failure: String?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            Group {
                if let collection {
                    if collection.parts.isEmpty {
                        ContentUnavailableView("No titles in this collection", systemImage: "film")
                    } else {
                        CatalogGrid(items: collection.parts, showsLayoutToggle: false, forceGrid: true)
                    }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else {
                    DiaryLoadingPlaceholder(label: "Loading collection", layout: .posterGrid(columns: 3, rows: 2))
                }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(franchise.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { if collection == nil { await load() } }
    }

    private func load() async {
        failure = nil
        do { collection = try await franchise.load(store: store) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
