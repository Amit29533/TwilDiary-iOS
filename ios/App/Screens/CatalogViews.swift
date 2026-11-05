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
                    Text((item.year.map(String.init) ?? "Year unknown") + (item.inLibraryId == nil ? "" : " · In your library")).font(.system(size: 12)).foregroundStyle(.secondary)
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
                Text((item.year.map(String.init) ?? "Year unknown") + (item.inLibraryId == nil ? "" : " · In your library")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(height: 18).padding(.top, 4)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct CatalogSearchView: View {
    var universal = false
    @State private var libraryExpanded = false
    @State private var onlineExpanded = false
    @AppStorage("recentSearches.v1") private var recentJSON = "[]"
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                SearchField(placeholder: universal ? "Search everything…" : "Title or IMDb ID…", text: $query, label: "Search library and online", autoFocus: !universal, focusRevision: universal ? router.searchFocusRevision : 0, dismissRevision: dismissKeyboard)
                if let onClose { Button(action: onClose) { RoundTool(icon: "x") }.buttonStyle(.plain).accessibilityLabel("Close search") }
            }
            if !ready {
                if universal { SearchLandingView(recent: recent, choose: { query = $0 }, clear: { recentJSON = "[]" }) }
                else { Text("Find a title, or paste an IMDb ID.").font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            if ready {
                // In your library (only when something matches).
                if !localMatches.isEmpty {
                    HStack { Text("In Library · \(localMatches.count)").font(.system(size: 15, weight: .semibold)); Spacer(); CollectionLayoutToggle(grid: $grid, collection: "search") }
                    CollectionLayout(grid: grid) { ForEach(localMatches.prefix(libraryShown)) { title in
                        Button { chooseLibrary(title.id) } label: { searchRow(title) }.buttonStyle(.plain)
                            .accessibilityIdentifier((onLibraryChoose == nil ? "search-library-" : "match-title-") + title.id)
                    } }
                    if localMatches.count > libraryShown { Button("More library matches") { if universal && !libraryExpanded { libraryExpanded = true } else { libraryLimit += 20 } }.font(.system(size: 13)).frame(minHeight: 44) }
                }
                // Online (TMDB): only while it's loading, has results, or failed.
                if (loading && results.isEmpty) || !visibleOnline.isEmpty || failure != nil {
                if !universal || !visibleOnline.isEmpty || failure != nil { Text(universal ? "Movies & shows · TMDB" : "Not In Library · TMDB").font(.system(size: 15, weight: .semibold)) }
                if loading && results.isEmpty { DiaryLoadingPlaceholder(label: "Searching online") }
                if let failure { HStack { Text(failure).font(.system(size: 13)).foregroundStyle(.secondary); Spacer(minLength: 0); Button("Retry") { requestPage(page) }.font(.system(size: 13)) } }
                CollectionLayout(grid: grid) { ForEach(Array(visibleOnline.prefix(onlineShown)), id: \.key) { item in
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
            if universal && ready {
                SearchPeopleView(query: normalized, kind: nil, limit: 12, onChoose: rememberQuery)
            }
            if universal && ready { SearchJellyfinView(query: normalized) }
            // Watch history: when a library title matches (its watches are the ones to find).
            if universal && ready && !localMatches.isEmpty {
                NavigationLink(value: HistoryRoute(query: normalized)) {
                    Label("Watch history matches", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.simultaneousGesture(TapGesture().onEnded { rememberQuery() }).foregroundStyle(.primary).accessibilityIdentifier("search-history-matches")
            }
        }.padding(.horizontal, 14).padding(.bottom, 12)
            .task(id: normalized) { if completedQuery != normalized || failure != nil { await search(number: 1, reset: true) } }
            .onDisappear { pageTask?.cancel(); generation = UUID(); loading = false }
    }
    private func onlineRow(_ item: CatalogItem) -> some View {
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: grid ? nil : 72, height: grid ? 170 : 108).frame(maxWidth: grid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.system(size: 15, weight: .semibold)); Text([item.year.map(String.init), item.mediaType == .tv ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary) }
            if !grid { Spacer(minLength: 0); DiaryIcon(name: "arrow-up-right", size: 18).foregroundStyle(.tint) }
        }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).foregroundStyle(.primary)
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
        let layout = grid ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Artwork(path: title.artwork, title: title.name).frame(width: grid ? nil : 72, height: grid ? 170 : 108).frame(maxWidth: grid ? .infinity : nil).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) { Text(title.name).font(.system(size: 15, weight: .semibold)); Text([title.year.map(String.init), title.category == "anime-movie" ? "Anime movie" : title.category.capitalized].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary) }
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
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var details: CatalogBrowse?
    @State private var failure: String?
    @State private var loading = false
    @State private var showOverview = false
    @State private var showInformation = false
    @State private var headerState = CompactHeaderState()
    @State private var criticScores: [MDBListSyncEngine.SourceScore] = []
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let details {
                        TitleHero(name: details.details.name, poster: CatalogTools.image(details.details.posterPath), genres: details.details.genres, year: details.details.year, category: details.details.suggestedCategory == "anime-movie" ? "Anime movie" : details.details.suggestedCategory.capitalized, runtime: details.details.runtimeMinutes, series: route.kind == .tv, summary: details.details.overview, expanded: $showOverview, onNameScrolled: { headerState.update($0) }) {
                            RatingsStrip(scores: criticScores, tmdbFallback: details.details.communityScore)
                        }
                        if details.libraryTitle?.trashed == true {
                            NavigationLink(value: AppDestination.trash) { Text("Restore from Trash") }.buttonStyle(.glassProminent).controlSize(.large)
                        } else if let saved = details.libraryTitle {
                            Button("Open in Library") { accepted(saved.id) }.buttonStyle(.glassProminent).controlSize(.large)
                        } else {
                            Button { Task { if let id = await store.importTitle(details.details, category: details.details.suggestedCategory) { accepted(id) } } } label: {
                                Text(store.busy ? "Adding…" : "Add to Planned").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink).frame(maxWidth: .infinity).frame(minHeight: 48)
                            }.buttonStyle(.glassProminent).disabled(store.busy || !store.canMutate).accessibilityIdentifier("catalog-add")
                        }
                        if route.kind == .tv { CatalogSeasonPreview(route: route, details: details.details, store: store) }
                        CastAndRelated(route: route, sourceTitle: details.details.name,
                                       anime: details.details.suggestedCategory.hasPrefix("anime") ? (details.details.year, route.kind == .movie) : nil)
                    } else if loading { DiaryLoadingPlaceholder(height: 320, label: "Loading title").padding(16) }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                }.padding(.horizontal, 14).padding(.bottom, 32)
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
                    ToolbarItem(placement: .topBarTrailing) {
                        TitleHeaderAction(name: details?.details.name ?? "Title", kind: route.kind, id: route.id,
                            state: headerState, informationPresented: $showInformation, informationIdentifier: "catalog-information")
                    }
                }
                .sheet(isPresented: $showInformation) {
                    CommunityInformationSheet(name: details?.details.name ?? "Title", artwork: details.flatMap { CatalogTools.image($0.details.backdropPath, size: "w780") ?? CatalogTools.image($0.details.posterPath) }, identity: CommunityIdentity(kind: route.kind, id: route.id))
                }
                .task(id: route) { await load() }
                .task(id: route) {
                    // MDBList's ratings, when it's connected; otherwise TMDB's score stands alone.
                    criticScores = await CriticScores.load(store: store, tmdbId: route.id, isSeries: route.kind == .tv)
                }
        }
    }
    private func accepted(_ id: String) { if let onImported { onImported(id) } else { router.replaceTitle(id, tab: router.selectedTab) } }
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
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @State private var controller: CatalogEpisodeController
    @State private var selected: Int
    @State private var showAll = false
    @AppStorage("episodesGrid") private var episodesGrid = false
    @State private var revealed = Set<Int>()
    /// The episode whose details sheet is open (the same sheet as a saved title's episodes).
    @State private var selectedEpisode: Int?
    @State private var swipeForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheetHeight: CGFloat = 360
    @State private var sheetEpisode: Int?
    init(route: CatalogRoute, details: CatalogDetails, store: DiaryStore) {
        self.route = route; self.details = details
        _selected = State(initialValue: details.seasons?.first(where: { $0.number > 0 })?.number ?? details.seasons?.first?.number ?? 1)
        _controller = State(initialValue: CatalogEpisodeController { season, reveal in try await store.catalogEpisodes(route, season: season, reveal: reveal) })
    }
    private var total: Int { max(controller.items.count, details.seasons?.first(where: { $0.number == selected })?.expectedEpisodes ?? 0) }
    private var visible: [CatalogEpisode] { showAll ? controller.items : Array(controller.items.prefix(4)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Episode 0").font(.system(size: 20, weight: .bold)); Text("of \(total)").font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer(); Text("0%").font(.system(size: 20, weight: .bold)).foregroundStyle(.tint)
                }
                EpisodeProgressTrack(segments: Array(repeating: .unwatched, count: total), season: selected)
            }.padding(.top, 20).padding(.bottom, 8).diaryPanel(padding: 15, radius: 24, accentBorder: true)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Episodes").font(.system(size: 22, weight: .bold))
                        Text(controller.items.count.counted("episode", "episodes")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Season", selection: $selected) {
                            ForEach(details.seasons ?? [], id: \.number) { season in Text(season.number == 0 ? "Specials" : "Season \(season.number)").tag(season.number) }
                        }
                    } label: { FilterPill(label: selected == 0 ? "Specials" : "Season \(selected)") }
                        .disabled((details.seasons ?? []).count < 2).accessibilityLabel("Season").accessibilityValue(selected == 0 ? "Specials" : "Season \(selected)").accessibilityIdentifier("catalog-season")
                    CollectionLayoutToggle(grid: $episodesGrid, collection: "catalog-episodes")
                }
                if controller.loading && controller.items.isEmpty { DiaryLoadingPlaceholder(label: "Loading season") }
                if let error = controller.error { RetryNotice(message: error) { Task { await controller.load(selected, reveal: !hideSpoilers || controller.revealed, force: true) } } }
                if controller.items.isEmpty && !controller.loading && controller.error == nil { ContentUnavailableView("No episode metadata yet", systemImage: "film", description: Text("No episodes are available for this season yet.")) }
                CollectionLayout(grid: episodesGrid) { ForEach(visible) { episode in episodeRow(episode) } }
                if controller.items.count > 4 {
                    Button(showAll ? "Show fewer episodes" : "Show all \(controller.items.count) episodes") { showAll.toggle() }.font(.system(size: 14)).frame(maxWidth: .infinity).frame(minHeight: 44)
                }
            }
        }.task(id: selected) { await controller.load(selected, reveal: !hideSpoilers) }
            .onChange(of: selected) { _, _ in showAll = false; revealed = []; selectedEpisode = nil }
            .sheet(isPresented: Binding(get: { selectedEpisode != nil }, set: { if !$0 { selectedEpisode = nil } })) {
                // The last episode stays while the sheet slides away, instead of an empty sheet.
                if let number = selectedEpisode ?? sheetEpisode, let episode = controller.items.first(where: { $0.number == number }) { episodeSheet(episode) }
            }
            .onChange(of: selectedEpisode) { _, number in if let number { sheetEpisode = number } }
            .onChange(of: hideSpoilers) { _, hidden in if !hidden { Task { await controller.load(selected, reveal: true) } } }
    }
    /// The same tiles as a saved title's episodes: a 16:10 thumbnail with a one-line caption in the
    /// grid, a 132 × 74 thumbnail with two lines in the list. Details open in a sheet, never inline.
    private func episodeRow(_ episode: CatalogEpisode) -> some View {
        let hidden = hideSpoilers && !revealed.contains(episode.number)
        return Button { open(episode) } label: {
            if episodesGrid {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.aspectRatio(16 / 10, contentMode: .fit).overlay { episodeArtwork(episode, hidden: hidden) }.clipShape(RoundedRectangle(cornerRadius: 14))
                    episodeCaption(episode, hidden: hidden)
                }.contentShape(Rectangle())
            } else {
                HStack(spacing: 12) {
                    episodeArtwork(episode, hidden: hidden).frame(width: 132, height: 74).clipShape(RoundedRectangle(cornerRadius: 12))
                    episodeCaption(episode, hidden: hidden)
                }.padding(.vertical, 10).padding(.horizontal, 4).frame(minHeight: 92).contentShape(Rectangle())
            }
        }.buttonStyle(.springPress).accessibilityLabel("Episode \(episode.number) details").accessibilityIdentifier("catalog-episode-\(episode.number)")
    }
    private func open(_ episode: CatalogEpisode) {
        revealed.insert(episode.number); selectedEpisode = episode.number
        Task { await controller.load(selected, reveal: true) }
    }
    @ViewBuilder private func episodeArtwork(_ episode: CatalogEpisode, hidden: Bool) -> some View {
        if hidden { Color(webHex: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 23).foregroundStyle(.secondary) } }
        else { Artwork(path: CatalogTools.image(episode.stillPath) ?? CatalogTools.image(details.backdropPath), title: details.name) }
    }
    private func episodeCaption(_ episode: CatalogEpisode, hidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hidden ? "A story for later" : episode.name.isEmpty ? "Episode \(episode.number)" : "\(episode.number). \(episode.name)")
                .font(.system(size: 17, weight: .semibold)).lineLimit(episodesGrid ? 1 : 2).foregroundStyle(.white).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(episode.airedOn.map { SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day() } == true ? "Not watched" : "Not aired yet").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let score = episode.communityScore, score > 0 {
                    HStack(spacing: 4) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text(score.formatted(.number.precision(.fractionLength(1)))) }
                        .accessibilityElement(children: .ignore).accessibilityLabel("TMDb " + score.formatted(.number.precision(.fractionLength(1))))
                }
            }.font(.system(size: 14)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func episodeSheet(_ episode: CatalogEpisode) -> some View {
        NavigationStack {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 16) {
                    episodeArtwork(episode, hidden: false).frame(height: 200).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(episode.name.isEmpty ? "Episode \(episode.number)" : episode.name).font(.title2.bold()).foregroundStyle(Color(webHex: "#f3f0f7"))
                    Text(episode.overview.isEmpty ? (controller.loading ? "Loading episode…" : "No synopsis available yet.") : episode.overview)
                        .font(.system(size: 16)).lineSpacing(4).foregroundStyle(Color(webHex: "#c5c0cf")).fixedSize(horizontal: false, vertical: true)
                }.padding(20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
                    .id(episode.number)
                    .transition(.asymmetric(insertion: .move(edge: swipeForward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: swipeForward ? .leading : .trailing).combined(with: .opacity)))
            }.scrollContentBackground(.hidden).containerBackground(Color.clear, for: .navigation)
                // Swipe left for the next episode, right for the previous one, as on a saved title.
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > 60, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                    showNeighbour(of: episode, forward: dx < 0)
                })
                .accessibilityAction(named: "Next episode") { showNeighbour(of: episode, forward: true) }
                .accessibilityAction(named: "Previous episode") { showNeighbour(of: episode, forward: false) }
                .navigationTitle("Episode \(episode.number)").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedEpisode = nil } } }
        // As tall as the synopsis needs, on glass, like a saved title's episode sheet; pull up for more.
        }.presentationDetents([SheetFit.detent(sheetHeight, chrome: 96), .large])
            .presentationContentInteraction(.resizes).presentationDragIndicator(.visible)
    }
    /// The next or previous episode of this season in the open sheet (a deliberate choice, so a
    /// spoiler-hidden one is revealed, as tapping it would).
    private func showNeighbour(of episode: CatalogEpisode, forward: Bool) {
        let items = controller.items
        guard let index = items.firstIndex(where: { $0.number == episode.number }), items.indices.contains(index + (forward ? 1 : -1)) else { return }
        let next = items[index + (forward ? 1 : -1)]
        revealed.insert(next.number)
        swipeForward = forward
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { selectedEpisode = next.number }
    }
}

struct CastAndRelated: View {
    let route: CatalogRoute
    var sourceTitle: String? = nil
    /// Anime show their characters (AniList) above the cast.
    var anime: (year: Int?, movie: Bool)? = nil
    @Environment(DiaryStore.self) private var store
    @State private var cast: [CastPerson] = []
    @State private var related: [CatalogItem] = []
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let anime, let sourceTitle { AnimeCharactersRow(title: sourceTitle, year: anime.year, movie: anime.movie, tmdbID: route.id).padding(.bottom, 8) }
            if !cast.isEmpty {
                Text("Cast").font(.system(size: 20, weight: .semibold))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(cast) { person in
                            NavigationLink(value: PersonRoute(id: person.id, sourceTitle: sourceTitle, sourceRole: person.character)) {
                                VStack(spacing: 8) {
                                    Artwork(path: CatalogTools.image(person.profilePath, size: "w185"), title: person.name).frame(width: 96, height: 136).clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(person.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    Text(person.character).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(width: 96, alignment: .leading).multilineTextAlignment(.leading).foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("cast-person-" + String(person.id))
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if !related.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("You might like").font(.system(size: 20, weight: .semibold))
                        Spacer(minLength: 8)
                    }
                    PersonCreditShelf(items: Array(related.prefix(12)), identifier: "related-titles-shelf")
                }
            }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
        }.task(id: route) { await load() }
    }
    private func load() async {
        failure = nil
        do { cast = try await store.cast(route).cast } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        do { related = try await store.related(route).items } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

struct RetryNotice: View {
    let message: String
    let retry: () -> Void
    var body: some View { VStack(alignment: .leading, spacing: 10) { Text(message).font(.subheadline).foregroundStyle(.secondary); Button("Retry", action: retry).buttonStyle(.glass) }.frame(maxWidth: .infinity, alignment: .leading).diaryPanel() }
}
