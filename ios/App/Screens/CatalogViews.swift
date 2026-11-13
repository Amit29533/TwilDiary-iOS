import SwiftUI
import UIKit
import TwilDiaryCore

struct CatalogGrid: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("catalogGrid") private var grid = true
    let items: [CatalogItem]
    var showsLayoutToggle = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLayoutToggle { HStack { Spacer(); CollectionLayoutToggle(grid: $grid, collection: "catalog") } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: grid ? 3 : 1), alignment: .leading, spacing: grid ? 20 : 10) {
                ForEach(items, id: \.displayKey) { item in
                    Group {
                        if let saved = store.libraryIdentity(item) { NavigationLink(value: saved) { card(item).zoomSource(ZoomID.title(saved)) } }
                        else { NavigationLink(value: item.route) { card(item).zoomSource(ZoomID.catalog(item.route)) } }
                    }.buttonStyle(.springPress).accessibilityIdentifier("catalog-" + item.displayKey)
                }
            }
        }
    }
    @ViewBuilder private func card(_ item: CatalogItem) -> some View {
        if grid { CatalogPoster(item: item) }
        else {
            HStack(spacing: 12) {
                Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 68, height: 102).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text((item.year.map(String.init) ?? "Year unknown") + (item.inLibraryId == nil ? "" : " · In library")).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let score = item.rating, score > 0 { Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill").font(.system(size: 12)).foregroundStyle(.yellow) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                DiaryIcon(name: "chevron-right", size: 16).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
    }
}

struct CatalogPoster: View {
    let item: CatalogItem
    var profileTypography = false
    @Environment(DiaryStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false)
                .posterAspect()
                .overlay(alignment: .bottomLeading) {
                    if let score = item.rating ?? store.libraryIdentity(item).flatMap({ store.title($0)?.communityScore }), score > 0 {
                        HStack(spacing: 5) { Image(systemName: "star.fill").font(.system(size: 13)); Text(String(format: "%.1f", score)).frame(height: 18) }
                            .font(.system(size: 12)).foregroundStyle(Color(webHex: "#e7ca90"))
                            .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6)).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if profileTypography {
                ProfileCardCaption(title: item.name).padding(.top, 8)
                if let year = item.year { ProfileCardCaption(title: String(year), secondary: true).padding(.top, 4) }
            } else {
                Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).frame(minHeight: 20.25).padding(.top, 8)
                Text((item.year.map(String.init) ?? "Year unknown") + (item.inLibraryId == nil ? "" : " · In library")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(height: 18).padding(.top, 4)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct CatalogSearchView: View {
    var universal = false
    @State private var libraryExpanded = false
    @State private var onlineExpanded = false
    @AppStorage("recentSearches.v1") private var recentJSON = "[]"
    /// The search bar's AI pill: search by description with Gemini. Off again each time the app
    /// opens, so searches don't keep going to Gemini unnoticed.
    @State private var aiSearch = false
    /// What AI search asks Gemini: set when you press Search (or turn AI on with text typed),
    /// never while you type, so each description is one request.
    @State private var aiQuery = ""
    var onLibraryChoose: ((String) -> Void)? = nil
    var onCatalogChoose: ((CatalogRoute) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var identified: [SearchLibraryTitle] = []
    @State private var results: [CatalogItem] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var dismissKeyboard = 0
    @AppStorage("searchGrid") private var grid = false
    @State private var page = 1
    @State private var totalPages = 0
    @State private var libraryLimit = 20
    @State private var generation = UUID()
    @State private var completedQuery: String?
    @State private var pageTask: Task<Void, Never>?
    /// Search's kind chips (design): All, Movies, Shows, Anime, People.
    enum Kind: String, CaseIterable { case all = "All", movies = "Movies", shows = "Shows", anime = "Anime", people = "People" }
    @State private var kind = Kind.all
    @State private var peopleCount = 0
    @State private var adding = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                SearchField(placeholder: universal ? "Movies, shows, anime, people" : "Title or IMDb ID…", text: $query, label: "Search library and online", autoFocus: !universal, focusRevision: universal ? router.searchFocusRevision : 0, dismissRevision: dismissKeyboard,
                            ai: universal ? $aiSearch : nil, onSearch: { if aiSearch { aiQuery = normalized } })
                if let onClose { Button(action: onClose) { RoundTool(icon: "x") }.buttonStyle(.plain).accessibilityLabel("Close search") }
            }
            if universal { kindChips }
            if !ready {
                if universal { SearchLandingView(recent: recent, choose: { query = $0 }, clear: { recentJSON = "[]" }) }
                else { Text("Find a title, or paste an IMDb ID.").font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            if universal && ready { universalResults }
            if ready && !universal {
                // In your library (only when something matches).
                if !localMatches.isEmpty {
                    HStack { Text("In Library · \(localMatches.count)").font(.system(size: 15, weight: .semibold)); Spacer(); CollectionLayoutToggle(grid: $grid, collection: "search") }
                    CollectionLayout(grid: grid, columns: 3) { ForEach(localMatches.prefix(libraryShown)) { title in
                        Button { chooseLibrary(title.id) } label: { searchRow(title) }.buttonStyle(.plain)
                            .accessibilityIdentifier((onLibraryChoose == nil ? "search-library-" : "match-title-") + title.id)
                    } }
                    if localMatches.count > libraryShown { Button("More library matches") { if universal && !libraryExpanded { libraryExpanded = true } else { libraryLimit += 20 } }.font(.system(size: 13)).frame(minHeight: 44) }
                }
                // Online (TMDB): only while it's loading, has results, or failed.
                if (loading && results.isEmpty) || !visibleOnline.isEmpty || failure != nil {
                if !universal || !visibleOnline.isEmpty || failure != nil { Text(universal ? "Movies & shows" : "Not in library").font(.system(size: 15, weight: .semibold)) }
                if loading && results.isEmpty { DiaryLoadingPlaceholder(label: "Searching online") }
                if let failure { HStack { Text(failure).font(.system(size: 13)).foregroundStyle(.secondary); Spacer(minLength: 0); Button("Retry") { requestPage(page) }.font(.system(size: 13)) } }
                CollectionLayout(grid: grid, columns: 3) { ForEach(Array(visibleOnline.prefix(onlineShown)), id: \.key) { item in
                    Button { chooseCatalog(item.route) } label: { onlineRow(item) }
                        .buttonStyle(.plain).accessibilityIdentifier("search-" + item.key)
                } }
                if visibleOnline.count > onlineShown {
                    Button("More movies and shows") { onlineExpanded = true }.font(.footnote).foregroundStyle(.primary).frame(minHeight: 44)
                }
                }
                if totalPages > 1 && (!universal || onlineExpanded) {
                    HStack { Button("Previous") { requestPage(page - 1) }.disabled(page <= 1 || loading); Spacer(); Text("Page \(page) of \(totalPages)").font(.system(size: 13)).foregroundStyle(.secondary); Spacer(); Button("Next") { requestPage(page + 1) }.disabled(page >= min(500, totalPages) || loading) }.font(.system(size: 13))
                }
            }
            if universal && ready && (kind == .all || kind == .people) {
                SearchPeopleView(query: normalized, kind: nil, limit: kind == .people ? 40 : 6, onChoose: rememberQuery, onCount: { peopleCount = $0 })
            }
            if universal && ready && kind != .people { SearchJellyfinView(query: normalized) }
            // Watch history: when a library title matches (its watches are the ones to find).
            if universal && ready && !localMatches.isEmpty {
                NavigationLink(value: HistoryRoute(query: normalized)) {
                    Label("Watch history matches", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.simultaneousGesture(TapGesture().onEnded { rememberQuery() }).foregroundStyle(.primary).accessibilityIdentifier("search-history-matches")
            }
        }.padding(.horizontal, 14).padding(.bottom, 12)
            .task(id: normalized) { if completedQuery != normalized || failure != nil { await search(number: 1, reset: true) } }
            // AI turned on again starts from what's typed now, not the last description sent.
            .onChange(of: aiSearch) { _, on in if on { aiQuery = "" } }
            .onDisappear { pageTask?.cancel(); generation = UUID(); loading = false }
    }
    // MARK: Universal results (owner's design): kind chips, SHOWS & MOVIES as cards, PEOPLE

    private var kindChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Kind.allCases, id: \.self) { item in
                    let on = kind == item
                    Button { kind = item } label: {
                        HStack(spacing: 6) {
                            Text(item.rawValue)
                            if ready, let count = count(item) {
                                Text(count.formatted()).foregroundStyle(on ? Color(webHex: "#1a1030").opacity(0.7) : HomeStyle.secondary).monospacedDigit()
                            }
                        }.font(.system(size: 15, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#1a1030") : HomeStyle.primary)
                            .padding(.horizontal, 15).frame(height: 40)
                            .background(on ? HomeStyle.chipText : HomeStyle.round, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? .clear : HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier("search-kind-" + item.rawValue.lowercased())
                }
            }
        }.scrollIndicators(.hidden)
    }
    /// One result: a library match or an online title, with its kind.
    private struct Result: Identifiable {
        let id: String
        let name: String
        let poster: String?
        let detail: String
        let kind: Kind
        let libraryID: String?
        let route: CatalogRoute?
    }
    private static func key(_ route: CatalogRoute) -> String { route.kind.rawValue + ":" + String(route.id) }
    private var allResults: [Result] {
        let library = localMatches.map { title in
            Result(id: "library:" + title.id, name: title.name, poster: title.artwork,
                   detail: [title.category == "movie" ? "Movie" : title.category == "anime-movie" ? "Anime · Movie" : title.category == "anime" ? "Anime · Series" : "Show",
                            title.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                   kind: title.category.hasPrefix("anime") ? .anime : title.category == "movie" ? .movies : .shows, libraryID: title.id, route: nil)
        }
        let saved = Set(localMatches.map(\.id))
        let online = visibleOnline.compactMap { item -> Result? in
            let owned = CatalogTools.libraryIdentity(item, in: store.workspace)
            if let owned, saved.contains(owned) { return nil }
            let anime = (item.genres ?? []).contains { $0 == "Animation" || $0 == "16" } && item.mediaType == .tv
            return Result(id: "online:" + item.key, name: item.name, poster: item.artwork,
                          detail: [anime ? "Anime · Series" : item.mediaType == .tv ? "Show" : "Movie", item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                          kind: anime ? .anime : item.mediaType == .tv ? .shows : .movies, libraryID: owned, route: item.route)
        }
        return library + online
    }
    private func count(_ item: Kind) -> Int? {
        switch item {
        case .all: allResults.count + peopleCount
        case .people: peopleCount
        default: allResults.filter { $0.kind == item }.count
        }
    }
    @ViewBuilder private var universalResults: some View {
        let shown = allResults.filter { kind == .all || $0.kind == kind }
        // AI on: Gemini's matches for the description first, then the usual results.
        if aiSearch && kind != .people { SemanticSearchSection(query: aiQuery, typed: normalized) }
        if kind != .people {
            if !shown.isEmpty || loading || failure != nil {
                Text("SHOWS & MOVIES").font(.system(size: 13, weight: .bold)).tracking(1.2).foregroundStyle(HomeStyle.secondary).padding(.top, 6)
            }
            if loading && shown.isEmpty { DiaryLoadingPlaceholder(label: "Searching online") }
            if let failure { HStack { Text(failure).font(.system(size: 13)).foregroundStyle(.secondary); Spacer(minLength: 0); Button("Retry") { requestPage(page) }.font(.system(size: 13)) } }
            ForEach(shown.prefix(onlineExpanded ? 100 : 8)) { result in resultCard(result) }
            if shown.count > 8 && !onlineExpanded {
                Button { onlineExpanded = true; libraryExpanded = true } label: {
                    Text("Show all \(shown.count)").font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                        .frame(maxWidth: .infinity, minHeight: 50).background(HomeStyle.card, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                }.buttonStyle(.springPress).accessibilityIdentifier("search-show-all")
            }
            if !loading && shown.isEmpty && failure == nil && completedQuery == normalized {
                Text("No \(kind == .all ? "titles" : kind.rawValue.lowercased()) match “\(normalized)”.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }
    /// The design's result card: poster, name, "Anime · Series", then In library or + Add.
    private func resultCard(_ result: Result) -> some View {
        Button {
            if let id = result.libraryID { chooseLibrary(id) } else if let route = result.route { chooseCatalog(route) }
        } label: {
            HStack(spacing: 16) {
                Artwork(path: result.poster, title: result.name, initialsOnly: false).frame(width: 78, height: 117).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.name).font(.system(size: 19, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(2).truncationMode(.tail)
                    Text(result.detail).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    Group {
                        if result.libraryID != nil {
                            Text("In library").font(.system(size: 14, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                                .padding(.horizontal, 16).frame(height: 38).background(HomeStyle.chip, in: Capsule())
                        } else if let route = result.route {
                            let busy = adding.contains(Self.key(route))
                            Button { Task { await add(route) } } label: {
                                HStack(spacing: 5) {
                                    if busy { ProgressView().controlSize(.small).tint(Color(webHex: "#1a1030")) } else { Image(systemName: "plus").font(.system(size: 13, weight: .bold)) }
                                    Text("Add")
                                }.font(.system(size: 15, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                                    .padding(.horizontal, 16).frame(height: 38)
                                    .background(HomeStyle.chip, in: Capsule())
                            }.buttonStyle(.springPress).disabled(busy || !store.canMutate)
                                .accessibilityLabel("Add " + result.name).accessibilityIdentifier("search-add-" + Self.key(route))
                        }
                    }.padding(.top, 4)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard()).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(result.libraryID.map { "search-library-" + $0 } ?? "search-" + (result.route.map(Self.key) ?? result.id))
    }
    /// + Add: the title joins your library as Planned (its full details are read first).
    private func add(_ route: CatalogRoute) async {
        rememberQuery()
        adding.insert(Self.key(route)); defer { adding.remove(Self.key(route)) }
        guard let browse = try? await store.browse(route) else { failure = "This title couldn’t be added. Try again."; return }
        _ = await store.importTitle(browse.details, category: browse.details.suggestedCategory)
    }

    private func onlineRow(_ item: CatalogItem) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            resultPoster(Artwork(path: item.artwork, title: item.name, initialsOnly: false))
            resultCaption(item.name, detail: [item.year.map(String.init), item.mediaType == .tv ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · "))
            if !grid { Spacer(minLength: 0); DiaryIcon(name: "arrow-up-right", size: 18).foregroundStyle(.tint) }
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).foregroundStyle(.primary)
    }
    /// A true 2:3 poster in both layouts: the column's width in the grid (not a fixed height,
    /// which squashed posters to squares), 72 by 108 in the list.
    @ViewBuilder private func resultPoster(_ artwork: Artwork) -> some View {
        if grid { artwork.posterAspect().clipShape(RoundedRectangle(cornerRadius: 8)) }
        else { artwork.frame(width: 72, height: 108).clipShape(RoundedRectangle(cornerRadius: 8)) }
    }
    /// Grid captions keep two lines of room, so a row of posters stays level whatever the names.
    private func resultCaption(_ name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: grid ? 2 : 4) {
            Text(name).font(.system(size: grid ? 14 : 15, weight: .semibold)).lineLimit(grid ? 2 : 4, reservesSpace: grid)
            Text(detail).font(.system(size: grid ? 12 : 13)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var normalized: String { DiarySearchTools.normalize(query) }
    private var ready: Bool { DiarySearchTools.ready(normalized) }
    private var localMatches: [SearchLibraryTitle] {
        DiarySearchTools.merging(DiarySearchTools.matches(store.workspace, query: normalized), identified)
    }
    private var visibleOnline: [CatalogItem] { results }
    /// The universal search starts with a few of each; "More" expands in place.
    private var libraryShown: Int { universal && !libraryExpanded ? 4 : libraryLimit }
    private var onlineShown: Int { universal && !onlineExpanded ? 4 : 100 }
    private var recent: [String] { recentJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
    private func rememberQuery() {
        guard universal, ready else { return }
        let value = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let values = [value] + recent.filter { $0.localizedCaseInsensitiveCompare(value) != .orderedSame }
        if let data = try? JSONEncoder().encode(Array(values.prefix(6))), let json = String(data: data, encoding: .utf8) { recentJSON = json }
    }
    private func searchRow(_ title: SearchLibraryTitle) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            resultPoster(Artwork(path: title.artwork, title: title.name))
            resultCaption(title.name, detail: [title.year.map(String.init), title.category == "anime-movie" ? "Anime movie" : title.category.capitalized].compactMap { $0 }.joined(separator: " · "))
            if !grid { Spacer(minLength: 0); DiaryIcon(name: "arrow-up-right", size: 18).foregroundStyle(.tint) }
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).foregroundStyle(.primary)
    }
    private func chooseLibrary(_ id: String) {
        rememberQuery()
        dismissKeyboard += 1
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            if store.title(id) == nil { await store.refresh() }
            guard store.title(id) != nil else { failure = "This title is no longer available. Refresh your library and try again."; return }
            if let onLibraryChoose { onLibraryChoose(id) }
            else { router.openTitle(id, tab: router.selectedTab) }
        }
    }
    private func chooseCatalog(_ route: CatalogRoute) {
        rememberQuery()
        dismissKeyboard += 1
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if let onCatalogChoose { onCatalogChoose(route) }
        else { router.paths[router.selectedTab, default: NavigationPath()].append(route) }
    }
    private func requestPage(_ number: Int) { pageTask?.cancel(); pageTask = Task { await search(number: number) } }
    private func search(number: Int, reset: Bool = false) async {
        let request = UUID(); generation = request
        if reset { completedQuery = nil; results = []; identified = []; page = 1; totalPages = 0; libraryLimit = 20; libraryExpanded = false; onlineExpanded = false }
        failure = nil
        guard ready else { loading = false; return }
        let value = normalized; loading = true
        defer { if generation == request { loading = false } }
        do {
            if reset { try await Task.sleep(for: .milliseconds(300)) }
            let response = try await store.searchDiary(value, page: number)
            guard !Task.isCancelled, request == generation, normalized == value else { return }
            guard response.page == number else { throw APIError.message("Search returned an unexpected page. Please retry.") }
            completedQuery = value
            identified = DiarySearchTools.merging(identified, response.library)
            results = response.online; page = response.page; totalPages = response.totalPages
            failure = response.onlineError.isEmpty ? nil : response.onlineError
        } catch is CancellationError { }
        catch { if !Task.isCancelled, request == generation { failure = error.localizedDescription } }
    }
}

struct CatalogDetailView: View {
    let route: CatalogRoute
    var onImported: ((String) -> Void)? = nil
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var details: CatalogBrowse?
    @State private var failure: String?
    @State private var loading = false
    @State private var showOverview = false
    @State private var showInformation = false
    @State private var showCineMind = false
    @State private var showFiles = false
    @State private var headerState = CompactHeaderState()
    @State private var criticScores: [MDBListSyncEngine.SourceScore] = []
    /// Tags, companies, status and network from TMDB, as on a saved title's page.
    @State private var extras: TitleExtras?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                // The same page as a saved title (owner's Show page design), minus your own progress.
                VStack(alignment: .leading, spacing: 32) {
                    if let details {
                        let anime = details.details.suggestedCategory.hasPrefix("anime")
                        VStack(alignment: .leading, spacing: 22) {
                            TitleHero(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), backdrop: CatalogTools.image(details.details.backdropPath, size: "w780"), genres: details.details.genres, year: details.details.year, category: details.details.suggestedCategory == "anime-movie" ? "Anime movie" : details.details.suggestedCategory.capitalized, runtime: details.details.runtimeMinutes, series: route.kind == .tv, summary: details.details.overview, expanded: $showOverview, extras: extras, ratingsBelow: true, coverStrip: TitleCover.strip(width: geometry.size.width, safeTop: geometry.safeAreaInsets.top), onNameScrolled: { headerState.update($0) }) {
                                RatingBoxes(scores: criticScores, tmdbFallback: details.details.communityScore)
                            }
                            if details.libraryTitle?.trashed == true {
                                NavigationLink(value: AppDestination.trash) { primaryLabel("Restore from Trash", icon: "arrow.uturn.backward") }.buttonStyle(.springPress)
                            } else if let saved = details.libraryTitle {
                                Button { accepted(saved.id) } label: { primaryLabel("Open in Library", icon: "books.vertical") }.buttonStyle(.springPress)
                            } else {
                                HStack(spacing: 10) {
                                    RatingCircles(mine: nil, community: communityAverage(details.details), onRate: {}, onCommunity: { showInformation = true }, showsMine: false)
                                    Button { Task { if let id = await store.importTitle(details.details, category: details.details.suggestedCategory) { accepted(id) } } } label: {
                                        primaryLabel(store.busy ? "Adding…" : "Add to Planned", icon: "plus")
                                    }.buttonStyle(.springPress).disabled(store.busy || !store.canMutate).accessibilityIdentifier("catalog-add")
                                }
                            }
                        }
                        if let extras, !extras.keywords.isEmpty { TitleTagsSection(keywords: extras.keywords, kind: route.kind) }
                        if route.kind == .tv { CatalogSeasonPreview(route: route, details: details.details, store: store) }
                        CastAndRelated(route: route, sourceTitle: details.details.name,
                                       anime: anime ? (details.details.year, route.kind == .movie) : nil,
                                       seeAll: .cast(route, title: details.details.name, anime: anime, year: details.details.year))
                        if let extras { CompaniesSection(route: route, title: details.details.name, extras: extras, animated: anime || details.details.genres.contains("Animation")) }
                        InListsSection(route: route, title: details.details.name)
                        RelatedCollectionsSection(route: route, title: details.details.name, anime: anime, genres: details.details.genres)
                    } else if loading { DiaryLoadingPlaceholder(height: 320, label: "Loading title").padding(16) }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                }.padding(.horizontal, 16).padding(.bottom, 32)
                    .background(alignment: .top) {
                        if let details { TitleArtworkBackdrop(path: CatalogTools.image(details.details.backdropPath, size: "w780"), name: details.details.name, topExtension: geometry.safeAreaInsets.top) }
                    }
            }.scrollClipDisabled().diaryScreenBackground(path: details.flatMap { CatalogTools.image($0.details.backdropPath, size: "w780") }, name: details?.details.name ?? "").navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) { CompactHeaderBackdrop(state: headerState, topInset: geometry.safeAreaInsets.top) }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        if let details { CompactTitleNavigation(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), state: headerState) }
                    }
                    // The same ••• button as a saved title (owner's design), replacing ⓘ.
                    ToolbarItem(placement: .topBarTrailing) {
                        let saved = savedTitle
                        Menu {
                            Button("Sentiments", systemImage: "info.circle") { showInformation = true }.accessibilityIdentifier("catalog-information")
                            Button("Ask CineMind", systemImage: "sparkle") { showCineMind = true }.disabled(details == nil).accessibilityIdentifier("catalog-cinemind")
                            // Sentiments, File location and Share only read; the library edits need write access.
                            let canEdit = store.canMutate && !store.busy && details?.libraryTitle?.trashed != true
                            Button(saved?.favorite == true ? "Remove from Favourites" : "Add to Favourites", systemImage: saved?.favorite == true ? "heart.slash" : "heart") {
                                Task { await libraryAction(["favorite": saved?.favorite != true]) }
                            }.disabled(!canEdit).accessibilityIdentifier("catalog-favorite")
                            Button(saved?.queued == true ? "Remove from Queue" : "Add to Queue", systemImage: "text.badge.plus") {
                                Task { await libraryAction(["queued": saved?.queued != true]) }
                            }.disabled(!canEdit).accessibilityIdentifier("catalog-queue")
                            Button("File location", systemImage: "folder") { showFiles = true }.accessibilityIdentifier("catalog-files")
                            TitleShareItem(name: details?.details.name ?? "Title", kind: route.kind, id: route.id)
                        } label: { TitleMoreButtonLabel() }
                            .disabled(details == nil)
                            .accessibilityLabel("More options for " + (details?.details.name ?? "this title")).accessibilityIdentifier("catalog-more")
                    }
                }
                .sheet(isPresented: $showFiles) {
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 12) {
                            if JellyfinShelf.shared.entries.contains(where: { $0.tmdb == route.id && $0.movie == (route.kind == .movie) }) {
                                JellyfinPresenceRow(tmdb: route.id, movie: route.kind == .movie)
                            } else {
                                Text("Not in your Jellyfin library.").font(.system(size: 15)).foregroundStyle(HomeStyle.secondary)
                                    .task { await JellyfinShelf.shared.refreshQuietly(store: store) }
                            }
                            Spacer(minLength: 0)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .navigationTitle("File location").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFiles = false } } }
                    }.presentationDetents([.medium]).presentationDragIndicator(.visible)
                }
                .cineMind(isPresented: $showCineMind, title: savedTitle ?? details.map { TraktDiary.catalogTitle($0.details) })
                .sheet(isPresented: $showInformation) {
                    CommunityInformationSheet(name: details?.details.name ?? "Title", artwork: details.flatMap { CatalogTools.image($0.details.backdropPath, size: "w780") ?? CatalogTools.image($0.details.posterPath) }, identity: CommunityIdentity(kind: route.kind, id: route.id))
                }
                .task(id: route) { await load() }
                .task(id: route) { extras = try? await TitleExtrasCache.load(store: store, route: route) }
                .task(id: route) {
                    // MDBList's ratings, when it's connected; otherwise TMDB's score stands alone.
                    criticScores = await CriticScores.load(store: store, tmdbId: route.id, isSeries: route.kind == .tv)
                }
        }
    }
    private func accepted(_ id: String) { if let onImported { onImported(id) } else { router.replaceTitle(id, tab: router.selectedTab) } }
    /// This title in your library, when it's there.
    private var savedTitle: MediaTitle? { details?.libraryTitle.flatMap { saved in store.workspace.titles.first { $0.id == saved.id } } }
    /// Favourite and Queue belong to library titles: a title not there yet is added (as Planned)
    /// first, then changed, and its saved page opens.
    private func libraryAction(_ values: [String: Any]) async {
        guard let details else { return }
        if let saved = savedTitle { await store.patch(saved, values: values); return }
        guard let id = await store.importTitle(details.details, category: details.details.suggestedCategory),
              let title = store.workspace.titles.first(where: { $0.id == id }) else { return }
        await store.patch(title, values: values)
        accepted(id)
    }
    /// Trakt's average when MDBList has it, otherwise TMDB's (as on a saved title's page).
    private func communityAverage(_ details: CatalogDetails) -> Double? {
        if let trakt = criticScores.first(where: { RatingsStrip<EmptyView>.canonical($0.source) == "trakt" }), let value = trakt.value ?? trakt.score, value > 0 {
            return value > 10 ? value / 10 : value
        }
        return details.communityScore.flatMap { $0 > 0 ? $0 : nil }
    }
    /// The page's main action, in the same colours as a saved title's "Watching" pill (#cdbbff on #2a2440).
    private func primaryLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) { Image(systemName: icon).font(.system(size: 14, weight: .bold)); Text(text).font(.system(size: 15, weight: .bold)) }
            .foregroundStyle(HomeStyle.chipText).frame(maxWidth: .infinity).frame(height: 48)
            .background(HomeStyle.chip, in: Capsule())
            .contentShape(Capsule())
    }
    private func load() async {
        guard details == nil else { return }
        loading = true; failure = nil; defer { loading = false }
        do {
            let response = try await store.browse(route); try Task.checkCancellation()
            if let saved = response.libraryTitle, !saved.trashed {
                if store.title(saved.id) == nil { await store.refresh() }
                try Task.checkCancellation()
                if store.title(saved.id) != nil { accepted(saved.id); return }
            }
            details = response
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct CatalogSeasonPreview: View {
    let route: CatalogRoute
    let details: CatalogDetails
    @Environment(AppRouter.self) private var router
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var controller: CatalogEpisodeController
    @State private var selected: Int
    @State private var showAll = false
    @AppStorage("episodesGrid") private var episodesGrid = false
    @State private var revealed = Set<Int>()
    /// The episode whose details sheet is open (the same sheet as a saved title's episodes).
    @State private var selectedEpisode: Int?
    @State private var swipeForward = true
    @State private var sheetEpisode: Int?
    init(route: CatalogRoute, details: CatalogDetails, store: DiaryStore) {
        self.route = route; self.details = details
        _selected = State(initialValue: details.seasons?.first(where: { $0.number > 0 })?.number ?? details.seasons?.first?.number ?? 1)
        _controller = State(initialValue: CatalogEpisodeController { season, reveal in try await store.catalogEpisodes(route, season: season, reveal: reveal) })
    }
    @State private var unwatchedOnly = false
    private func aired(_ episode: CatalogEpisode) -> Bool { episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day() } == true }
    /// As on the title page: three rows (a sideways row of nine cards in grid), all of them on "Show all".
    private var shown: [CatalogEpisode] {
        let pool = unwatchedOnly ? controller.items.filter(aired) : controller.items
        return Array(pool.prefix(episodesGrid ? 9 : 3))
    }
    private func hidden(_ episode: CatalogEpisode) -> Bool { hideSpoilers && !revealed.contains(episode.number) }
    private func state(_ episode: CatalogEpisode) -> EpisodeRowState { aired(episode) ? .notWatched : .notAired }
    private func artwork(_ episode: CatalogEpisode) -> String? { CatalogTools.image(episode.stillPath) ?? CatalogTools.image(details.backdropPath, size: "w780") }
    private func name(_ episode: CatalogEpisode) -> String { hidden(episode) ? "A story for later" : episode.name.isEmpty ? "Episode \(episode.number)" : episode.name }
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Episodes").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    if !controller.items.isEmpty {
                        Text(controller.items.count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                            .padding(.horizontal, 10).frame(height: 28).background(HomeStyle.round, in: Capsule())
                            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Season", selection: $selected) {
                            ForEach(details.seasons ?? [], id: \.number) { season in Text(season.number == 0 ? "Specials" : "Season \(season.number)").tag(season.number) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selected == 0 ? "Specials" : "Season \(selected)").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            if (details.seasons ?? []).count > 1 { DiaryIcon(name: "chevron-down", size: 13).foregroundStyle(HomeStyle.secondary) }
                        }.padding(.horizontal, 18).frame(height: 44)
                            .background(HomeStyle.round, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                    }.disabled((details.seasons ?? []).count < 2).accessibilityLabel("Season").accessibilityValue(selected == 0 ? "Specials" : "Season \(selected)").accessibilityIdentifier("catalog-season")
                }
                HStack(spacing: 8) {
                    filter("All episodes", on: !unwatchedOnly) { unwatchedOnly = false }
                    filter("Unwatched", on: unwatchedOnly) { unwatchedOnly = true }
                    Spacer(minLength: 0)
                    layoutSwitch
                }
                if controller.loading && controller.items.isEmpty { DiaryLoadingPlaceholder(label: "Loading season") }
                if let error = controller.error { RetryNotice(message: error) { Task { await controller.load(selected, reveal: !hideSpoilers || controller.revealed, force: true) } } }
                if controller.items.isEmpty && !controller.loading && controller.error == nil { Text("No episode metadata yet").font(.subheadline).foregroundStyle(HomeStyle.secondary) }
                if episodesGrid {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(shown) { episode in
                                EpisodeGridCard(number: episode.number, name: name(episode), artwork: artwork(episode), hidden: hidden(episode),
                                                state: state(episode), airedOn: episode.airedOn, runtime: details.runtimeMinutes,
                                                score: episode.communityScore, onOpen: { open(episode) }, onToggle: {}, showsTick: false)
                                    .accessibilityIdentifier("catalog-episode-\(episode.number)")
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                } else {
                    VStack(spacing: 9) {
                        ForEach(shown) { episode in
                            EpisodeCardRow(number: episode.number, name: name(episode), artwork: artwork(episode), hidden: hidden(episode),
                                           state: state(episode), score: episode.communityScore, canToggle: false,
                                           onOpen: { open(episode) }, onToggle: {}, showsTick: false)
                                .accessibilityIdentifier("catalog-episode-\(episode.number)")
                        }
                    }
                }
                if !controller.items.isEmpty {
                    // As on the title page: the season's own Episodes page.
                    Button { router.paths[router.selectedTab, default: NavigationPath()].append(ShowPageRoute.catalogEpisodes(route, season: selected)) } label: {
                        HStack(spacing: 6) { Text("Show all \(controller.items.count) episodes"); DiaryIcon(name: "chevron-right", size: 14) }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(HomeStyle.round, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.shortcutBorder, lineWidth: HomeStyle.hairline))
                    }.buttonStyle(.springPress).accessibilityIdentifier("catalog-all-episodes")
                }
            }
            let points = controller.items.compactMap { episode in episode.communityScore.map { EpisodeRatingPoint(episode: episode.number, score: $0) } }
            if route.kind == .tv { RatingTrendCard(show: route.id, season: selected, tmdb: points, current: nil) }
        }.task(id: selected) { await controller.load(selected, reveal: !hideSpoilers) }
            .onChange(of: selected) { _, _ in showAll = false; revealed = []; selectedEpisode = nil }
            .sheet(isPresented: Binding(get: { selectedEpisode != nil }, set: { if !$0 { selectedEpisode = nil } })) {
                // The title page's episode sheet; the last episode stays while it slides away.
                if let number = selectedEpisode ?? sheetEpisode { episodeSheet(number) }
            }
            .onChange(of: selectedEpisode) { _, number in if let number { sheetEpisode = number } }
            .onChange(of: hideSpoilers) { _, hidden in if !hidden { Task { await controller.load(selected, reveal: true) } } }
    }
    /// As on the title page: a spoiler-hidden episode is revealed by the first tap, then opens.
    private func open(_ episode: CatalogEpisode) {
        if hidden(episode) {
            revealed.insert(episode.number)
            Task { await controller.load(selected, reveal: true) }
        } else { selectedEpisode = episode.number }
    }
    private func filter(_ name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? Color(webHex: "#0b0b10") : HomeStyle.soft)
                .padding(.horizontal, 20).frame(height: 44)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(HomeStyle.round), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    private var layoutSwitch: some View {
        Button { episodesGrid.toggle() } label: {
            HStack(spacing: 0) {
                DiaryIcon(name: "layout-grid", size: 17).foregroundStyle(episodesGrid ? HomeStyle.chipText : HomeStyle.secondary)
                    .frame(width: 40, height: 36).background(episodesGrid ? HomeStyle.chip : .clear, in: Capsule())
                DiaryIcon(name: "list", size: 17).foregroundStyle(episodesGrid ? HomeStyle.secondary : HomeStyle.chipText)
                    .frame(width: 40, height: 36).background(episodesGrid ? .clear : HomeStyle.chip, in: Capsule())
            }.padding(3).background(HomeStyle.round, in: Capsule())
                .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Show episodes as " + (episodesGrid ? "list" : "grid")).accessibilityIdentifier("catalog-episodes-layout")
    }

    // MARK: The title page's episode sheet

    private var sheetTitle: MediaTitle? { PreviewDiaryModels.title(route, details: details) }
    private var sheetEpisodes: [Episode] { PreviewDiaryModels.episodes(controller.items, route: route, season: selected, artwork: artwork) }
    @ViewBuilder private func episodeSheet(_ number: Int) -> some View {
        if let title = sheetTitle, let source = controller.items.first(where: { $0.number == number }),
           let episode = sheetEpisodes.first(where: { $0.number == number }) {
            EpisodeInfoSheet(title: title, season: selected, episodes: sheetEpisodes, episode: episode,
                             page: { item in
                                 let source = controller.items.first { $0.number == item.number } ?? source
                                 return .init(name: source.name.isEmpty ? "Episode \(item.number)" : source.name, summary: source.overview,
                                              artwork: artwork(source), hidden: false, tmdbScore: source.communityScore,
                                              traktScore: TraktTitleReads.cachedRatings(show: route.id, season: selected)[item.number], watched: false)
                             },
                             onToggleWatched: { _ in }, onNeighbour: { showNeighbour(of: number, forward: $0) },
                             onNote: {}, onClose: { selectedEpisode = nil }, inDiary: false)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }
    /// The next or previous episode in the open sheet (a deliberate choice, so a hidden one is revealed).
    private func showNeighbour(of number: Int, forward: Bool) {
        let items = controller.items
        guard let index = items.firstIndex(where: { $0.number == number }), items.indices.contains(index + (forward ? 1 : -1)) else { return }
        let next = items[index + (forward ? 1 : -1)]
        revealed.insert(next.number)
        swipeForward = forward
        Task { await controller.load(selected, reveal: true) }
        // The sheet has already slid to it; animating this too re-animated the whole page behind.
        selectedEpisode = next.number
    }
}

struct CastAndRelated: View {
    let route: CatalogRoute
    var sourceTitle: String? = nil
    /// Anime show their characters (AniList) above the cast.
    var anime: (year: Int?, movie: Bool)? = nil
    /// The show page's "See all" (its Cast and crew page).
    var seeAll: ShowPageRoute? = nil
    @Environment(AppRouter.self) private var router
    @Environment(DiaryStore.self) private var store
    @State private var cast: [CastPerson] = []
    @State private var related: [CatalogItem] = []
    @State private var failure: String?
    var body: some View {
        // Design: sections 42 pt apart, 22 pt headings, 111 pt tiles (radius 18) 12 pt apart.
        VStack(alignment: .leading, spacing: 42) {
            if let anime, let sourceTitle { AnimeCharactersRow(title: sourceTitle, year: anime.year, movie: anime.movie, tmdbID: route.id, seeAll: seeAll) }
            if !cast.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cast").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    Spacer(minLength: 8)
                    if let seeAll { SeeAllLink(value: seeAll, identifier: "title-cast-all") }
                }.frame(minHeight: 44)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(cast) { person in
                            NavigationLink(value: PersonRoute(id: person.id, sourceTitle: sourceTitle, sourceRole: person.character)) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Artwork(path: CatalogTools.image(person.profilePath, size: "w185"), title: person.name).frame(width: 111, height: 148).clipShape(RoundedRectangle(cornerRadius: 18))
                                        // Press and hold to peek at the photo; a tap still opens the person.
                                        .fullScreenArtwork(CatalogTools.image(person.profilePath, size: "w185"), title: person.name) {
                                            router.paths[router.selectedTab, default: NavigationPath()].append(PersonRoute(id: person.id, sourceTitle: sourceTitle, sourceRole: person.character))
                                        }
                                    Text(person.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).padding(.top, 11)
                                    Text(person.character).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2).padding(.top, 3)
                                }.frame(width: 111, alignment: .leading).multilineTextAlignment(.leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("cast-person-" + String(person.id))
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
              }
            }
            if !related.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("More like this").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                        Spacer(minLength: 8)
                        SeeAllLink(value: ShowPageRoute.related(route, title: sourceTitle ?? ""), identifier: "title-related-all")
                    }.frame(minHeight: 44)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(related.prefix(12), id: \.key) { item in relatedLink(item) }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled().accessibilityIdentifier("related-titles-shelf")
                }
            }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
        }.task(id: route) { await load() }
    }
    @ViewBuilder private func relatedLink(_ item: CatalogItem) -> some View {
        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) {
            NavigationLink(value: saved) { relatedPoster(item) }.buttonStyle(.springPress)
        } else {
            NavigationLink(value: item.route) { relatedPoster(item) }.buttonStyle(.springPress)
        }
    }
    /// Design: a 111 x 167 poster (radius 18), the name in 14 pt semibold and the year under it.
    private func relatedPoster(_ item: CatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 111, height: 167).clipShape(RoundedRectangle(cornerRadius: 18))
            Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 10)
            Text(item.year.map(String.init) ?? "").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).padding(.top, 3)
        }.frame(width: 111, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func load() async {
        failure = nil
        do { cast = try await store.cast(route).cast } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        // Never suggest the title you're looking at.
        do { related = try await store.related(route).items.filter { $0.route != route } } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct RetryNotice: View {
    let message: String
    let retry: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text(message).font(.subheadline).foregroundStyle(.secondary); Button("Retry", action: retry).buttonStyle(.glass) }.frame(maxWidth: .infinity, alignment: .leading).diaryPanel() }
}
