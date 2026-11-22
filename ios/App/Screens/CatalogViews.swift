import SwiftUI
import UIKit
import TwilDiaryCore

struct CatalogGrid: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("catalogGrid") private var grid = true
    let items: [CatalogItem]
    var showsLayoutToggle = true
    var forceGrid = false
    private var useGrid: Bool { forceGrid || grid }
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    private var columns: Int { useGrid ? (forceGrid && typeSize.isAccessibilitySize ? 2 : posterSize.columns) : 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLayoutToggle { HStack { Spacer(); CollectionLayoutToggle(grid: $grid, collection: "catalog") } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: useGrid ? 20 : 10) {
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
        if useGrid { CatalogPoster(item: item, profileTypography: forceGrid && typeSize.isAccessibilitySize) }
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
    @AppStorage(PosterSize.captionKey) private var showsCaption = true
    var body: some View {
        let score = PosterScores.score(for: item, store: store)
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false)
                .posterAspect()
                .overlay(alignment: .bottomLeading) { if let score { PosterScoreBadge(score: score) } }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .wantsPosterScore(item, known: score, store: store)
            if !showsCaption {
                EmptyView()
            } else if profileTypography {
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var addControlHeight: CGFloat = 44
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
    @State private var failedPage: Int?
    @State private var dismissKeyboard = 0
    @AppStorage("searchGrid") private var grid = false
    @State private var page = 1
    @State private var totalPages = 0
    @State private var libraryLimit = 20
    @State private var generation = UUID()
    private struct SearchScope: Hashable { let query: String; let session: UUID }
    @State private var activeScope: SearchScope?
    @State private var completedScope: SearchScope?
    @State private var pageTask: Task<Void, Never>?
    /// Search's kind chips (design): All, Movies, Shows, Anime, People.
    enum Kind: String, CaseIterable {
        case all = "All", movies = "Movies", shows = "Shows", anime = "Anime", people = "People"

        static func title(_ type: MediaKind, anime: Bool) -> Self {
            if anime { return .anime }
            return type == .movie ? .movies : .shows
        }

        func includes(_ type: MediaKind, anime: Bool) -> Bool {
            self == .all || self == Self.title(type, anime: anime)
        }
    }
    @State private var kind = Kind.all
    @State private var mixedPeople: [SearchPerson]?
    @State private var peopleMatch: (scope: SearchScope, count: Int)?
    @State private var adding = Set<String>()
    @State private var addFailures: [String: String] = [:]
    /// A Planned result whose removal is being asked about (its library id).
    @State private var removingPlanned: String?
    @AppStorage("confirmDeletions") private var confirmDeletions = true
    var body: some View {
        let scope = searchScope
        let ranked = universal && ready ? allResults : []
        let counts = Dictionary(grouping: ranked, by: \.kind).mapValues { $0.count }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                SearchField(placeholder: universal ? "Movies, shows, anime, people" : "Title or IMDb ID…", text: $query, label: "Search library and online", autoFocus: !universal, focusRevision: universal ? router.searchFocusRevision : 0, dismissRevision: dismissKeyboard,
                            ai: universal ? $aiSearch : nil, onSearch: {
                                if aiSearch && ready { aiQuery = normalized }
                            })
                if universal {
                    NavigationLink(value: SearchLabRoute()) {
                        Image(systemName: "flask").frame(minWidth: 28, minHeight: 32)
                    }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Advanced filters").accessibilityIdentifier("search-browse-lab")
                }
                if let onClose { Button(action: onClose) { RoundTool(icon: "x") }.buttonStyle(.plain).accessibilityLabel("Close search") }
            }
            if universal { kindChips(counts: counts, total: ranked.count) }
            if !ready {
                if universal { SearchLandingView(kind: kind, recent: recent, choose: { query = $0 }, clear: { recentJSON = "[]" }, remove: { forget($0) }).id(kind) }
                else { Text("Find a title, or paste an IMDb ID.").font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            // Nothing found: the closest spelling ("breking bad" → Breaking Bad).
            if universal && ready && !aiSearch && !isIMDbLookup && kind != .people && completedScope == scope && failure == nil && !loading && ranked.isEmpty
                && (kind != .all || (peopleMatch?.scope == scope && peopleMatch?.count == 0)) {
                DidYouMeanView(query: scope.query) { query = $0 }
            }
            if universal && ready { universalResults(ranked) }
            // Studios and franchises named like the search, under the titles.
            if universal && ready && !isIMDbLookup && kind != .people {
                SearchStudiosAndFranchises(query: scope.query, kind: kind, onChoose: { rememberQuery(); dismissKeyboard += 1 })
            }
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
                if loading && results.isEmpty { DiaryLoadingPlaceholder(label: "Searching online", layout: .list(rows: 5)) }
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
            if universal && ready && !isIMDbLookup && ((kind == .all && !aiSearch) || kind == .people) {
                SearchPeopleView(query: scope.query, limit: kind == .people ? 40 : 6,
                                 mixed: kind == .all && activeScope == scope ? mixedPeople : nil,
                                 usePreview: kind == .all && !store.isPreview && TMDBDirect.token(store) != nil
                                     && !(activeScope == scope && mixedPeople == nil && (failure != nil || completedScope == scope)),
                                 onChoose: {
                    rememberQuery()
                    dismissKeyboard += 1
                },
                                 onCount: { count in
                    if scope == searchScope { peopleMatch = (scope, count) }
                }).id(scope).id(kind == .people)
            }
            if universal && ready && kind != .people { SearchJellyfinView(query: normalized, kind: kind) }
            // Watch history: when a library title matches (its watches are the ones to find).
            if universal && ready && kind != .people && localMatches.contains(where: { includesCategory($0.category) }) {
                NavigationLink(value: HistoryRoute(query: normalized)) {
                    Label("Watch history matches", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.simultaneousGesture(TapGesture().onEnded { rememberQuery() }).foregroundStyle(.primary).accessibilityIdentifier("search-history-matches")
            }
        }.padding(.horizontal, 14).padding(.bottom, 12)
            .task(id: kind == .people ? nil : Optional(scope)) { if kind != .people && completedScope != scope { await search(number: 1, reset: true) } }
            .onChange(of: aiSearch) { _, on in aiQuery = on && ready ? normalized : "" }
            .onChange(of: normalized) { _, value in if value != aiQuery { aiQuery = "" } }
            .onDisappear { pageTask?.cancel(); generation = UUID(); loading = false }
    }
    // MARK: Universal results (owner's design): kind chips, SHOWS & MOVIES as cards, PEOPLE

    @ViewBuilder private func kindChips(counts: [Kind: Int], total: Int) -> some View {
        if ThemeStore.current.native && !typeSize.isAccessibilitySize {
            NativeSegmentedControl(segments: Kind.allCases.map { item in
                NativeSegment(value: item, title: item.rawValue + (ready ? count(item, counts: counts, total: total).map { " \($0)" } ?? "" : ""), id: "search-kind-" + item.rawValue.lowercased())
            }, selection: $kind)
        } else {
            classicKindChips(counts: counts, total: total)
        }
    }
    private func classicKindChips(counts: [Kind: Int], total: Int) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Kind.allCases, id: \.self) { item in
                    let on = kind == item
                    Button { kind = item } label: {
                        HStack(spacing: 6) {
                            Text(item.rawValue)
                            if ready, let count = count(item, counts: counts, total: total) {
                                Text(count.formatted()).foregroundStyle(on ? ThemeStore.current.chipInk.opacity(0.7) : HomeStyle.secondary).monospacedDigit()
                            }
                        }.font(typeSize.isAccessibilitySize ? .subheadline.weight(.semibold) : .system(size: 15, weight: .semibold))
                            .foregroundStyle(on ? ThemeStore.current.chipInk : HomeStyle.primary)
                            .padding(.horizontal, 15).padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0).frame(minHeight: 40)
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
        var alias: String? = nil
    }
    private static func key(_ route: CatalogRoute) -> String { route.kind.rawValue + ":" + String(route.id) }
    private var allResults: [Result] {
        let local = localMatches
        let library = local.map { title in
            Result(id: "library:" + title.id, name: title.name, poster: title.artwork,
                   detail: [title.category == "movie" ? "Movie" : title.category == "anime-movie" ? "Anime · Movie" : title.category == "anime" ? "Anime · Series" : "Show",
                            title.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                   kind: title.category.hasPrefix("anime") ? .anime : title.category == "movie" ? .movies : .shows, libraryID: title.id, route: nil, alias: title.matchedName.flatMap { $0.localizedCaseInsensitiveCompare(title.name) == .orderedSame ? nil : $0 })
        }
        let saved = Set(local.map(\.id))
        let jellyfin = Set(JellyfinShelf.shared.entries.compactMap { entry in
            entry.tmdb.map { CatalogRoute(kind: entry.movie ? .movie : .tv, id: $0) }
        })
        let online = visibleOnline.compactMap { item -> Result? in
            let owned = store.libraryIdentity(item)
            if let owned, saved.contains(owned) { return nil }
            let anime = item.isAnime == true
            let type = item.mediaType == .tv ? "Series" : "Movie"
            return Result(id: "online:" + item.key, name: item.name, poster: item.artwork,
                          detail: [anime ? "Anime · " + type : item.mediaType == .tv ? "Show" : "Movie", item.year.map(String.init), jellyfin.contains(item.route) ? "On Jellyfin" : nil].compactMap { $0 }.joined(separator: " · "),
                          kind: Kind.title(item.mediaType, anime: anime), libraryID: owned, route: item.route)
        }
        let needle = normalized.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var exact: [Result] = [], prefix: [Result] = [], other: [Result] = []
        for row in library + online {
            let names = [row.name, row.alias].compactMap { $0?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
            if names.contains(needle) { exact.append(row) }
            else if names.contains(where: { $0.hasPrefix(needle) }) { prefix.append(row) }
            else { other.append(row) }
        }
        return exact + prefix + other
    }
    private func count(_ item: Kind, counts: [Kind: Int], total: Int) -> Int? {
        guard !aiSearch else { return nil }
        let peopleCount = peopleMatch.flatMap { $0.scope == searchScope ? $0.count : nil }
        return switch item {
        case .all: total + (peopleCount ?? 0)
        case .people: peopleCount
        default: counts[item, default: 0]
        }
    }
    @ViewBuilder private func universalResults(_ ranked: [Result]) -> some View {
        let shown = ranked.filter { kind == .all || $0.kind == kind }
        // AI on: Gemini's matches for the description first, then the usual results.
        if aiSearch && kind != .people { SemanticSearchSection(query: aiQuery, kind: kind) }
        if kind != .people {
            if !shown.isEmpty || loading || failure != nil {
                Text("Shows & movies").font(.headline).foregroundStyle(.primary).padding(.top, 6)
            }
            if loading && shown.isEmpty { DiaryLoadingPlaceholder(label: "Searching online", layout: .list(rows: 5)) }
            if let failure, activeScope == searchScope {
                if let failedPage { RetryNotice(message: failure) { requestPage(failedPage) } }
                else { Text(failure).font(.subheadline).foregroundStyle(.secondary) }
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(onlineExpanded && activeScope == searchScope ? shown : Array(shown.prefix(8))) { result in resultCard(result) }
            }
            if !loading && failure == nil && (hasMore || (!onlineExpanded && shown.count > 8)) {
                Button {
                    if onlineExpanded || shown.count <= 8 { requestPage(page + 1) }
                    onlineExpanded = true
                } label: {
                    Text(onlineExpanded || shown.count <= 8 ? "Load more titles" : hasMore ? "Show more titles" : "Show all \(shown.count)")
                        .font(.headline).foregroundStyle(HomeStyle.chipText)
                        .frame(maxWidth: .infinity, minHeight: 50).background(HomeStyle.card, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
                }.buttonStyle(.springPress).accessibilityIdentifier("search-show-all")
            }
            if loading && !shown.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Searching online") }
            if !aiSearch && !loading && shown.isEmpty && failure == nil && completedScope == searchScope && !hasMore {
                Text("No \(kind == .all ? "titles" : kind.rawValue.lowercased()) match “\(normalized)”.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }
    /// The design's result card: poster, name, "Anime · Series", then In library or + Add.
    private func resultCard(_ result: Result) -> some View {
        let addRoute = result.libraryID == nil ? result.route : nil
        let plannedID = result.libraryID.flatMap { id in store.title(id)?.status == "planned" ? id : nil }
        let posterWidth: CGFloat = 78
        let spacing: CGFloat = 16
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Button {
                    if let id = result.libraryID { chooseLibrary(id) } else if let route = result.route { chooseCatalog(route) }
                } label: {
                    HStack(spacing: spacing) {
                        Artwork(path: result.poster, title: result.name, initialsOnly: false)
                            .frame(width: posterWidth, height: 117).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.name).font(.headline).foregroundStyle(HomeStyle.primary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2).fixedSize(horizontal: false, vertical: true)
                            Text(result.detail).font(.subheadline).foregroundStyle(HomeStyle.secondary)
                            if let alias = result.alias { Text("Also known as " + alias).font(.caption).foregroundStyle(.secondary) }
                            if let libraryID = result.libraryID, plannedID == nil {
                                Text(store.title(libraryID).map { $0.status == "completed" ? "Watched" : $0.status == "planned" ? "Planned" : "In library" } ?? "In library").font(.subheadline.bold()).foregroundStyle(HomeStyle.chipText)
                                    .padding(.horizontal, 16).padding(.vertical, 8).background(HomeStyle.chip, in: Capsule())
                            } else if addRoute != nil || plannedID != nil {
                                Color.clear.frame(height: addControlHeight).accessibilityHidden(true)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 117, alignment: addRoute == nil && plannedID == nil ? .leading : .bottomLeading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier(result.libraryID.map { "search-library-" + $0 } ?? "search-" + (result.route.map(Self.key) ?? result.id))
                if let route = addRoute { addButton(route, title: result.name).padding(.leading, posterWidth + spacing) }
                else if let id = plannedID { plannedButton(id, title: result.name).padding(.leading, posterWidth + spacing) }
            }
            if let route = addRoute, let message = addFailures[Self.key(route)] {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
    }

    private func addButton(_ route: CatalogRoute, title: String) -> some View {
        let key = Self.key(route)
        let busy = adding.contains(key)
        let retry = addFailures[key] != nil
        return Button { Task { await add(route) } } label: {
            Label(retry ? "Retry add" : "Add", systemImage: "plus").lineLimit(1)
                .font(.subheadline.bold()).foregroundStyle(HomeStyle.chipText)
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small) } }
                .padding(.horizontal, 16).frame(height: addControlHeight)
                .background(HomeStyle.chip, in: Capsule())
        }.buttonStyle(.springPress).disabled(busy || !store.canMutate)
            .accessibilityLabel((retry ? "Retry adding " : "Add ") + title)
            .accessibilityIdentifier("search-add-" + key)
    }
    /// "✓ Planned": tapping it asks, then takes the title back out of Planned (into Trash).
    private func plannedButton(_ id: String, title: String) -> some View {
        let busy = adding.contains(id)
        return Button { if confirmDeletions { removingPlanned = id } else { Task { await removePlanned(id) } } } label: {
            Label("Planned", systemImage: "checkmark").lineLimit(1)
                .font(.subheadline.bold()).foregroundStyle(HomeStyle.chipText)
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small) } }
                .padding(.horizontal, 16).frame(height: addControlHeight)
                .background(HomeStyle.chip, in: Capsule())
        }.buttonStyle(.springPress).disabled(busy || !store.canMutate)
            .confirmationDialog("Remove \(title) from Planned?", isPresented: Binding(get: { removingPlanned == id }, set: { if !$0 { removingPlanned = nil } }),
                                titleVisibility: .visible) {
                Button("Remove from Planned", role: .destructive) { Task { await removePlanned(id) } }
            } message: { Text("It moves to Trash.") }
            .accessibilityLabel("Planned. Remove " + title + " from Planned")
            .accessibilityIdentifier("search-planned-" + id)
    }
    private func removePlanned(_ id: String) async {
        guard let title = store.title(id), title.status == "planned", adding.insert(id).inserted else { return }
        defer { adding.remove(id) }
        if await store.trash(title) { Haptics.play(.light) }
    }
    /// + Add: the title joins your library as Planned (its full details are read first).
    private func add(_ route: CatalogRoute) async {
        rememberQuery()
        let key = Self.key(route)
        guard adding.insert(key).inserted else { return }
        defer { adding.remove(key) }
        addFailures[key] = nil
        do {
            let browse = try await store.browse(route)
            if await store.importTitle(browse.details, category: browse.details.suggestedCategory) == nil {
                addFailures[key] = store.error ?? "This title couldn’t be added."
            }
        } catch {
            addFailures[key] = error.localizedDescription
        }
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
    private var searchScope: SearchScope { SearchScope(query: normalized, session: store.sessionRevision) }
    private var ready: Bool { DiarySearchTools.ready(normalized) }
    private var isIMDbLookup: Bool { normalized.range(of: #"^tt[0-9]{7,10}$"#, options: .regularExpression) != nil }
    private var hasMore: Bool { activeScope == searchScope && completedScope == searchScope && page < min(500, totalPages) }
    private func includesCategory(_ category: String) -> Bool {
        kind.includes(category == "movie" || category == "anime-movie" ? .movie : .tv, anime: category.hasPrefix("anime"))
    }
    private var localMatches: [SearchLibraryTitle] {
        DiarySearchTools.merging(DiarySearchTools.matches(store.workspace, query: normalized), activeScope == searchScope ? identified : [])
    }
    private var visibleOnline: [CatalogItem] { activeScope == searchScope ? results : [] }
    /// The universal search starts with a few of each; "More" expands in place.
    private var libraryShown: Int { universal && !libraryExpanded ? 4 : libraryLimit }
    private var onlineShown: Int { universal && !onlineExpanded ? 4 : 100 }
    private var recent: [String] { recentJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
    private func forget(_ value: String) {
        let values = recent.filter { $0 != value }
        if let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) { recentJSON = json }
    }
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
        // Not kept as a recent search: the title shows in Recently viewed (once, not twice).
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
        // Not kept as a recent search: the title shows in Recently viewed (once, not twice).
        dismissKeyboard += 1
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if let onCatalogChoose { onCatalogChoose(route) }
        else { router.paths[router.selectedTab, default: NavigationPath()].append(route) }
    }
    private func requestPage(_ number: Int) { pageTask?.cancel(); pageTask = Task { await search(number: number) } }
    private func search(number: Int, reset: Bool = false) async {
        let scope = searchScope
        let request = UUID(); generation = request
        if reset {
            pageTask?.cancel()
            mixedPeople = nil
            activeScope = scope; completedScope = nil; results = []; identified = []
            page = 1; totalPages = 0; libraryLimit = 20; libraryExpanded = false; onlineExpanded = false
        }
        failure = nil
        failedPage = nil
        guard ready else { loading = false; return }
        let value = normalized; loading = true
        defer { if generation == request { loading = false } }
        do {
            if reset { try await Task.sleep(for: .milliseconds(300)) }
            let response = try await store.searchDiary(value, page: number) { people in
                if !Task.isCancelled, request == generation, scope == searchScope { mixedPeople = people }
            }
            guard !Task.isCancelled, request == generation, scope == searchScope else { return }
            if !response.onlineError.isEmpty { throw APIError.message(response.onlineError) }
            guard response.page == number else { throw APIError.message("Search returned an unexpected page. Please retry.") }
            completedScope = scope
            identified = DiarySearchTools.merging(identified, response.library)
            results = universal && number > 1 ? CatalogTools.merging(results, response.online) : response.online
            page = response.page; totalPages = response.totalPages
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, request == generation, scope == searchScope {
                failure = error.localizedDescription; failedPage = number
            }
        }
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
    @State private var showAddToList = false
    @State private var showCineMind = false
    @State private var showFiles = false
    @State private var headerState = CompactHeaderState()
    @State private var criticScores: [MDBListSyncEngine.SourceScore] = []
    /// Tags, companies, status and network from TMDB, as on a saved title's page.
    @State private var extras: TitleExtras?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                // The same page as a saved title (owner's Show page design), minus your own progress.
                VStack(alignment: .leading, spacing: 32) {
                    if let details {
                        let anime = details.details.suggestedCategory.hasPrefix("anime")
                        let animated = anime || details.details.genres.contains("Animation") || extras?.genres.contains(where: { $0.id == 16 }) == true
                        VStack(alignment: .leading, spacing: 22) {
                            TitleHero(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), backdrop: CatalogTools.image(details.details.backdropPath, size: "w780"), genres: details.details.genres, year: details.details.year, category: details.details.suggestedCategory == "anime-movie" ? "Anime movie" : details.details.suggestedCategory.capitalized, runtime: details.details.runtimeMinutes, series: route.kind == .tv, summary: details.details.overview, expanded: $showOverview, extras: extras, ratingsBelow: true, coverStrip: TitleCover.strip(width: geometry.size.width, safeTop: geometry.safeAreaInsets.top), onNameScrolled: { headerState.update($0) }) {
                                RatingBoxes(scores: criticScores, tmdbFallback: details.details.communityScore)
                            }
                            if details.libraryTitle?.trashed == true, let trashed = store.phoneTrashed(route) {
                                // In the phone's Trash (opened from Trash, say): restored here, with its rating.
                                Button { Task { if await store.restore(trashed) { await store.waitForTitle(trashed.id); await load() } } } label: {
                                    primaryLabel(store.busy ? "Restoring…" : "Restore", icon: "arrow.uturn.backward")
                                }.buttonStyle(.springPress).disabled(store.busy || store.writesBlocked).accessibilityIdentifier("catalog-restore")
                            } else if details.libraryTitle?.trashed == true {
                                NavigationLink(value: AppDestination.trash) { primaryLabel("Restore from Trash", icon: "arrow.uturn.backward") }.buttonStyle(.springPress)
                            } else if let saved = details.libraryTitle {
                                Button { accepted(saved.id) } label: { primaryLabel("Open in Library", icon: "books.vertical") }.buttonStyle(.springPress)
                            } else {
                                HStack(spacing: 10) {
                                    RatingCircles(mine: nil, community: communityAverage(details.details), onRate: {}, onCommunity: { showInformation = true }, showsMine: false)
                                    Button { Task { if let id = await store.importTitle(details.details, category: details.details.suggestedCategory) { Haptics.play(.success); await store.waitForTitle(id); accepted(id) } } } label: {
                                        primaryLabel(store.busy ? "Adding…" : "Add to Planned", icon: "plus")
                                    }.buttonStyle(.springPress).disabled(store.busy || !store.canMutate).accessibilityIdentifier("catalog-add")
                                }
                            }
                        }
                        if let extras, !extras.keywords.isEmpty { TitleTagsSection(keywords: extras.keywords, kind: route.kind) }
                        if route.kind == .tv { CatalogSeasonPreview(route: route, details: details.details, imdbID: details.details.imdbId ?? extras?.imdbId, store: store) }
                        CastAndRelated(route: route, sourceTitle: details.details.name, awardsIMDbID: details.details.imdbId ?? extras?.imdbId,
                                       characters: animated ? (details.details.year, route.kind == .movie) : nil,
                                       originalLanguage: extras?.originalLanguage,
                                       relatedAnime: anime ? (details.details.year, route.kind == .movie) : nil,
                                       seeAll: .cast(route, title: details.details.name, anime: animated, year: details.details.year, originalLanguage: extras?.originalLanguage))
                        if let extras { CompaniesSection(route: route, title: details.details.name, extras: extras, animated: anime || details.details.genres.contains("Animation")) }
                        InListsSection(route: route, title: details.details.name)
                        RelatedCollectionsSection(route: route, title: details.details.name, anime: anime, genres: details.details.genres)
                        ParentalGuideSection(extras: extras)
                    } else if loading { DiaryLoadingPlaceholder(height: 320, label: "Loading title").padding(16) }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                }.padding(.horizontal, 16).padding(.bottom, 32)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: extras == nil)
                    .background(alignment: .top) {
                        if let details { TitleArtworkBackdrop(path: CatalogTools.image(details.details.backdropPath, size: "w780"), name: details.details.name, topExtension: geometry.safeAreaInsets.top) }
                    }
            }.scrollClipDisabled().diaryScreenBackground(path: details.flatMap { CatalogTools.image($0.details.backdropPath, size: "w780") }, name: details?.details.name ?? "").navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .top) { CompactHeaderBackdrop(state: headerState, topInset: geometry.safeAreaInsets.top) }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        if let details { CompactTitleNavigation(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), state: headerState, pageWidth: geometry.size.width) }
                    }
                    // The same ••• button as a saved title (owner's design), replacing ⓘ.
                    ToolbarItem(placement: .topBarTrailing) {
                        let saved = savedTitle
                        Menu {
                            Button("Sentiments", systemImage: "info.circle") { showInformation = true }.accessibilityIdentifier("catalog-information")
                            Button("Ask CineMind", systemImage: "sparkle") { showCineMind = true }.disabled(details == nil).accessibilityIdentifier("catalog-cinemind")
                            // Sentiments, File location and Share only read; the library edits need write access.
                            let canEdit = store.canMutate && !store.busy && details?.libraryTitle?.trashed != true
                            Button("Favourite", systemImage: saved?.favorite == true ? "heart.fill" : "heart") {
                                Task { await libraryAction(["favorite": saved?.favorite != true]) }
                            }.disabled(!canEdit).accessibilityIdentifier("catalog-favorite")
                            Button(saved?.queued == true ? "Remove from Queue" : "Add to Queue", systemImage: "text.badge.plus") {
                                Task { await libraryAction(["queued": saved?.queued != true]) }
                            }.disabled(!canEdit).accessibilityIdentifier("catalog-queue")
                            Button("Add to list", systemImage: "text.badge.plus") { showAddToList = true }.accessibilityIdentifier("catalog-add-to-list")
                            Button("File location", systemImage: "folder") { showFiles = true }.accessibilityIdentifier("catalog-files")
                            TitleShareItem(name: details?.details.name ?? "Title", kind: route.kind, id: route.id)
                        } label: { TitleMoreButtonLabel() }
                            .disabled(details == nil)
                            .accessibilityLabel("More options for " + (details?.details.name ?? "this title")).accessibilityIdentifier("catalog-more")
                    }
                }
                // Native: the whole page, header and toolbar included, is the dark artwork page (sheets aren't).
                .nativeArtworkPage()
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
                .sheet(isPresented: $showAddToList) {
                    if let details { AddToListSheet(item: CatalogItem(id: route.id, mediaType: route.kind, name: details.details.name, year: details.details.year, posterPath: details.details.posterPath)) }
                }
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
        guard let id = await store.importTitle(details.details, category: details.details.suggestedCategory) else { return }
        Haptics.play(.success)
        await store.waitForTitle(id)
        guard let title = store.title(id) else { return }
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
            if !store.isPreview {
                RecentlyViewed.record(RecentlyViewedTitle(name: response.details.name, poster: CatalogTools.image(response.details.posterPath),
                                                          libraryID: nil, movie: route.kind == .movie, tmdb: route.id))
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct CatalogSeasonPreview: View {
    let route: CatalogRoute
    let imdbID: String?
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
    init(route: CatalogRoute, details: CatalogDetails, imdbID: String?, store: DiaryStore) {
        self.route = route; self.details = details; self.imdbID = imdbID
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
            // Seasons, as on a diary show's page; a tile picks the season shown below.
            SeasonCardsSection(preview: details, selected: $selected)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Episodes").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    if !controller.items.isEmpty {
                        Text(controller.items.count.formatted()).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                            .padding(.horizontal, 10).frame(height: 28).pillSurface(border: nil)
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
                            .pillSurface(border: HomeStyle.dateChipBorder)
                    }.disabled((details.seasons ?? []).count < 2).accessibilityLabel("Season").accessibilityValue(selected == 0 ? "Specials" : "Season \(selected)").accessibilityIdentifier("catalog-season")
                }
                HStack(spacing: 8) {
                    filter("All episodes", on: !unwatchedOnly) { unwatchedOnly = false }
                    filter("Unwatched", on: unwatchedOnly) { unwatchedOnly = true }
                    Spacer(minLength: 0)
                    layoutSwitch
                }
                if controller.loading && controller.items.isEmpty { DiaryLoadingPlaceholder(label: "Loading season", layout: .list(rows: 6)) }
                if let error = controller.error { RetryNotice(message: error) { Task { await controller.load(selected, reveal: !hideSpoilers || controller.revealed, force: true) } } }
                if controller.items.isEmpty && !controller.loading && controller.error == nil { Text("No episode metadata yet").font(.subheadline).foregroundStyle(HomeStyle.secondary) }
                if episodesGrid {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(shown) { episode in
                                EpisodeGridCard(number: episode.number, name: name(episode), artwork: artwork(episode), hidden: hidden(episode),
                                                state: state(episode), airedOn: episode.airedOn, runtime: episode.runtimeMinutes,
                                                score: episode.communityScore, onOpen: { open(episode) }, onToggle: {}, showsTick: false)
                                    .accessibilityIdentifier("catalog-episode-\(episode.number)")
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                } else {
                    VStack(spacing: 9) {
                        ForEach(shown) { episode in
                            EpisodeCardRow(number: episode.number, name: name(episode), artwork: artwork(episode), hidden: hidden(episode),
                                           state: state(episode), runtime: episode.runtimeMinutes, score: episode.communityScore, canToggle: false,
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
                            .pillSurface(border: HomeStyle.shortcutBorder)
                    }.buttonStyle(.springPress).accessibilityIdentifier("catalog-all-episodes")
                }
            }
            if route.kind == .tv {
                SeriesRatingCard(show: route.id, imdbID: imdbID).id(route.id)
            }
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
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? ThemeStore.current.accentInk : HomeStyle.soft)
                .padding(.horizontal, 20).frame(height: 44)
                .pillSurface(chosen: on ? ThemeStore.accent : nil)
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
    private var layoutSwitch: some View {
        Button { episodesGrid.toggle() } label: {
            HStack(spacing: 0) {
                DiaryIcon(name: "layout-grid", size: 17).foregroundStyle(episodesGrid ? HomeStyle.chipText : HomeStyle.secondary)
                    .frame(width: 40, height: 36).background(episodesGrid ? HomeStyle.chip : .clear, in: Capsule())
                DiaryIcon(name: "list", size: 17).foregroundStyle(episodesGrid ? HomeStyle.secondary : HomeStyle.chipText)
                    .frame(width: 40, height: 36).background(episodesGrid ? .clear : HomeStyle.chip, in: Capsule())
            }.padding(3).pillSurface(border: nil)
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
    var awardsIMDbID: String? = nil
    /// Anime show their characters (AniList) above the cast.
    var characters: (year: Int?, movie: Bool)? = nil
    var originalLanguage: String? = nil
    /// Anime show Related (AniList) above More like this.
    var relatedAnime: (year: Int?, movie: Bool)? = nil
    /// The show page's "See all" (its Cast and crew page).
    var seeAll: ShowPageRoute? = nil
    @Environment(AppRouter.self) private var router
    @Environment(DiaryStore.self) private var store
    @State private var awardHistoryRoute: CatalogRoute?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cast: [CastPerson] = []
    @State private var related: [CatalogItem] = []
    @State private var failure: String?
    var body: some View {
        // Design: sections 42 pt apart, 22 pt headings, 111 pt tiles (radius 18) 12 pt apart.
        VStack(alignment: .leading, spacing: 42) {
            if let characters, let sourceTitle { AnimeCharactersRow(title: sourceTitle, year: characters.year, movie: characters.movie, tmdbID: route.id, originalLanguage: originalLanguage, seeAll: seeAll) }
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
            if awardHistoryRoute == route, let sourceTitle {
                TitleAwardsSection(route: route, title: sourceTitle, imdbID: awardsIMDbID)
            }
            // Anime: its sequels, side stories and the like (AniList), just above More like this.
            if let info = relatedAnime, let sourceTitle { AnimeRelatedRow(title: sourceTitle, year: info.year, movie: info.movie) }
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
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: cast.isEmpty)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: related.isEmpty)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: awardHistoryRoute)
        .task(id: route) { await load() }
        .task(id: "\(route.kind.rawValue):\(route.id):\(awardsIMDbID ?? "")") {
            guard sourceTitle != nil, awardHistoryRoute != route else { return }
            let history = TitleAwardHistory.shared
            let local = try? await history.titleRecords(route)
            guard !Task.isCancelled else { return }
            if local?.isEmpty == false {
                awardHistoryRoute = route
                if !store.isPreview { _ = try? await history.peopleRecords(route, imdbID: awardsIMDbID) }
            } else if !store.isPreview {
                let credits = try? await history.peopleRecords(route, imdbID: awardsIMDbID)
                if !Task.isCancelled, credits?.isEmpty == false { awardHistoryRoute = route }
            }
        }
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
        let score = PosterScores.score(for: item, store: store)
        return VStack(alignment: .leading, spacing: 0) {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 111, height: 167)
                .overlay(alignment: .bottomLeading) { if let score { PosterScoreBadge(score: score) } }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .wantsPosterScore(item, known: score, store: store)
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
