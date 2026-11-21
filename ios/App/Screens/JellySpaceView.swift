import SwiftUI
import TwilDiaryCore

/// A library, folder, show or season to open in JellySpace.
struct JellyFolderRoute: Hashable {
    let id: String
    let name: String
    let kind: String
    /// A library's type ("music" shows Albums, Artists and Folders).
    var type: String? = nil
}

/// The home's last load, kept while the app runs: JellySpace opens on it at once and refreshes
/// behind it (at most once a minute, and after watching something).
@MainActor enum JellyHomeCache {
    /// The server and user they were loaded for.
    static var server: String?
    static var at: Date?
    static var libraries: [JellyfinLibrary] = []
    static var resume: [JellyfinClient.Item] = []
    static var favourites: [JellyfinClient.Item] = []
    static var collections: [JellyfinClient.Item] = []
    static var latest: [String: [JellyfinClient.Item]] = [:]
    static var nextUp: [JellyfinClient.Item] = []
    static var forYou: JellyForYou?
    /// Discover's shelves, and the server, user and hidden libraries they were drawn for.
    static var discover: JellyDiscover?
    static var discoverKey: String?
}

/// JellySpace: your Jellyfin server, played by AetherEngine straight from the file (Jellyfin's static
/// stream, nothing converted). Continue watching, Next up, your libraries and what's newest; a search
/// over every film and episode; any library or folder opens in JellyFolderPage. Opens from the
/// TwilDiary logo on Home. The player is JellyPlayerView.
struct JellySpaceView: View {
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    /// Names under posters (Settings → JellySpace → Home → Posters → Titles); off is the Netflix look:
    /// bigger posters, close together, with small corners.
    @AppStorage(JellyPrefs.captionsKey) private var captions = true
    @AppStorage(JellyPrefs.rowsKey) private var rowsRaw = ""
    /// My Media's order (Settings → JellySpace → My Media).
    @AppStorage(JellyPrefs.mediaOrderKey) private var mediaOrderRaw = ""
    @AppStorage(JellyPrefs.hiddenRowsKey) private var hiddenRowsRaw = ""
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    /// Libraries switched off for recommendations (Settings → JellySpace → Home → My Media).
    @AppStorage(JellyRecommendOff.key) private var recommendOffRaw = ""
    @State private var seerrResults: [JellySeerr.Result] = []
    @State private var requested: Set<Int> = []
    @State private var requestNotice: String?
    @State private var results: [JellyfinClient.Item] = []
    @State private var resume: [JellyfinClient.Item] = []
    @State private var libraries: [JellyfinLibrary] = []
    @State private var latest: [String: [JellyfinClient.Item]] = [:]
    @State private var favourites: [JellyfinClient.Item] = []
    @State private var collections: [JellyfinClient.Item] = []
    /// The next episode of each show you're following (after Continue Watching's own).
    @State private var nextUp: [JellyfinClient.Item] = []
    /// Jellyfin's picks from what you've watched.
    @State private var forYou: JellyForYou?
    /// "Recommendations for Rain", "Random picks for Dance", "Must watch Parks" (JellyRecommender.themes).
    @State private var themes: [JellyTheme] = []
    /// How many of them (Settings → JellySpace → Home → Dynamic recommendations).
    @AppStorage(JellyPrefs.themeCountKey) private var themeCount = 3
    /// Discover: genres, the Top 10, hidden gems, tonight's genre, and every library's random shelf.
    @State private var discover: JellyDiscover?
    @State private var query = ""
    @State private var searching = false
    @State private var searchRunning = false
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    /// "JellySpace" in the top bar once the page has scrolled (the big poster gone under the bar).
    /// The status bar and top bar's height: the big title sits in the bar's row, My Media under it.
    @State private var topInset: CGFloat = 0
    /// The top card on show (its colours light the top of the page).
    @State private var hero = JellyHeroSelection()
    @Environment(AppRouter.self) private var router

    /// Explore's layout: the big poster at the top (the newest films and shows), then the shelves
    /// at Explore's sizes.
    var body: some View {
        // Searching: the search page under the top bar and the search field (Recommended for you until
        // something's typed, then the results).
        let showsResults = searching
        EdgeToEdgeScroll(artworkUnderBar: !showsResults) {
            VStack(alignment: .leading, spacing: 22) {
                if let client = JellySpace.client {
                    let picks = showsResults || JellyHomeRow.hidden(hiddenRowsRaw).contains(.hero) ? [] : heroPicks
                    // The first load: the page's own shape (the top poster, its title and Play, the first
                    // rows) under the bar, instead of a shelf of blanks behind the top buttons.
                    let firstLoad = loading && !loaded && !showsResults && failure == nil
                    if !showsResults {
                        // Netflix's top: the title and your libraries on the page, under the back button's
                        // row; then the poster as a card; the poster's colours glowing behind them.
                        VStack(alignment: .leading, spacing: 14) {
                            homeHeader()
                            if firstLoad { JellyHomeSkeleton() }
                            else if !picks.isEmpty { JellyHeroCarousel(items: picks, client: client, playing: $playing, selection: hero) }
                        }
                        .background(alignment: .top) { JellyHeroGlow(picks: picks, client: client, selection: hero, topInset: topInset) }
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        if let failure { RetryNotice(message: failure) { Task { await loadHome() } } }
                        if showsResults && query.isEmpty {
                            suggestionsSection(client)
                        } else if showsResults {
                            if results.isEmpty && !searchRunning { Text("Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary) }
                            JellyGrid(items: shown(results), client: client, playing: $playing)
                            if !seerrResults.isEmpty { requestSection }
                        } else if firstLoad {
                            EmptyView()
                        } else {
                            // Your order and choice of rows (Settings → JellySpace).
                            // Each section in your order (Settings → JellySpace), each library's rows on their own.
                            let off = JellyHomeRow.hiddenSections(hiddenRowsRaw, libraries: visibleLibraries)
                            ForEach(JellyHomeRow.sections(rowsRaw, libraries: visibleLibraries).filter { !off.contains($0.id) }) { section in
                                homeSection(section, client: client)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, showsResults ? 64 : 0)
                } else {
                    NavigationLink(value: AppDestination.jellyfin) {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack").font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            Text("Connect Jellyfin").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14).frame(minHeight: 50).diaryPanel(padding: 0, radius: 14).contentShape(Rectangle())
                    }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-connect").padding(.horizontal, 14).padding(.top, 72)
                }
            }.padding(.bottom, 110)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .diaryScreenBackground()
        // The search field floats on glass just under the top bar's buttons, over the page (which
        // stays as it is until something's typed).
        .overlay(alignment: .top) {
            if searching {
                SearchField(placeholder: "Search Jellyfin", text: $query, label: "Search Jellyfin", autoFocus: true, glass: true)
                    .padding(.horizontal, 14).padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { JellySpaceBarTitle() }
            if JellySpace.client != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(searching ? "Close search" : "Search", systemImage: searching ? "xmark" : "magnifyingglass") {
                        withAnimation(.easeInOut(duration: 0.2)) { searching.toggle() }
                        if !searching { query = "" }
                    }.accessibilityIdentifier("jellyspace-search")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { JellyMiniPlayer().padding(.bottom, 4) }
        .task { await appear() }
        .task(id: hiddenRaw + "|" + hiddenRowsRaw + "|" + recommendOffRaw) { await loadDiscover() }
        // A library switched on or off for recommending: For you and the dynamic rows again.
        .onChange(of: recommendOffRaw) { _, _ in Task { await loadRows() } }
        // A new number of Dynamic recommendations rows: made again from the kept index (no network).
        .onChange(of: themeCount) { _, _ in Task { await loadThemes() } }
        .refreshable {
            await loadHome()
            await loadDiscover(force: true)
        }
        .task(id: query) {
            guard !query.isEmpty else { results = []; seerrResults = []; searchRunning = false; return }
            searchRunning = true
            // A pause after typing, so a search goes once per word, not once per letter.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let client = JellySpace.client else { return }
            let found = (try? await client.videos(search: query.trimmingCharacters(in: .whitespacesAndNewlines))) ?? []
            guard !Task.isCancelled else { return }
            results = found
            searchRunning = false
            // What isn't on the server, from Jellyseerr when it's set up.
            if let seerr = JellySpace.seerr { seerrResults = (try? await seerr.search(query.trimmingCharacters(in: .whitespacesAndNewlines))) ?? [] }
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await loadRows() } }) { JellyPlayerView(playback: $0) }
    }

    private var hidden: [String: String] { JellyHidden.decode(hiddenRaw) }
    private var visibleLibraries: [JellyfinLibrary] { libraries.filter { hidden[$0.id] == nil } }
    /// The libraries recommendations come from: shown, and not switched off for recommending.
    private var recommendLibraries: [JellyfinLibrary] {
        let off = JellyRecommendOff.ids(recommendOffRaw)
        return visibleLibraries.filter { !off.contains($0.id) }
    }
    /// Without what you hid (a film, a show, or an episode of a hidden show).
    private func shown(_ items: [JellyfinClient.Item]) -> [JellyfinClient.Item] {
        let hidden = hidden
        return items.filter { hidden[$0.Id] == nil && ($0.SeriesId.map { hidden[$0] == nil } ?? true) }
    }

    /// One section: a fixed row, a library's Recently added row, or its Random row.
    @ViewBuilder private func homeSection(_ section: JellyHomeSection, client: JellyfinClient) -> some View {
        switch section.kind {
        case .fixed(let row):
            homeRow(row, client: client)
        case .latest(let id):
            if let library = visibleLibraries.first(where: { $0.id == id }) {
                let items = shown(latest[id] ?? [])
                if !items.isEmpty {
                    tileRow("Recently added · " + library.name, items: items, client: client,
                            more: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder", type: library.type))
                }
            }
        case .random(let id):
            if let shelf = discover?.random.first(where: { $0.library?.id == id }), !shown(shelf.items).isEmpty {
                shuffledRow(shelf, client: client, wide: shelf.wide)
            }
        }
    }
    @ViewBuilder private func homeRow(_ row: JellyHomeRow, client: JellyfinClient) -> some View {
        switch row {
        // The poster and My Media's chips are at the top, not among the rows.
        case .hero, .media: EmptyView()
        case .resume: if !continueItems.isEmpty { continueRow(client) }
        case .favourites:
            let items = shown(favourites)
            if !items.isEmpty { tileRow("Favourites", items: items, client: client, more: JellyListRoute(kind: .favourites, name: "Favourites")) }
        case .libraries:
            ForEach(visibleLibraries) { library in
                let items = shown(latest[library.id] ?? [])
                if !items.isEmpty {
                    tileRow("Recently added · " + library.name, items: items, client: client,
                            more: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder", type: library.type))
                }
            }
        case .forYou:
            if let forYou, !shown(forYou.items).isEmpty { forYouRow(forYou, client: client) }
        case .themes:
            ForEach(themes) { theme in
                let items = shown(theme.items)
                if items.count >= 3 {
                    VStack(alignment: .leading, spacing: 10) {
                        headingWithAll(theme.title, ids: (theme.all.isEmpty ? theme.items : theme.all).map(\.Id), identifier: "theme-" + theme.id)
                        posterShelf(items, client: client)
                    }
                }
            }
        case .genres:
            if let genres = discover?.genres, !genres.isEmpty { genreChips(genres) }
        case .top10:
            if let top = discover?.top, !shown(top.items).isEmpty { topTenRow(top, client: client) }
        case .gems:
            let gems = gemItems
            if !gems.isEmpty { gemsRow(gems, client: client) }
        case .tonight:
            if let tonight = discover?.tonight, !shown(tonight.items).isEmpty { tonightRow(tonight, client: client) }
        case .random:
            ForEach(discover?.random ?? []) { shelf in
                if !shown(shelf.items).isEmpty { shuffledRow(shelf, client: client, wide: shelf.wide) }
            }
        case .collections:
            let items = shown(collections)
            if !items.isEmpty { tileRow("Collections", items: items, client: client, more: JellyListRoute(kind: .collections, name: "Collections")) }
        }
    }

    /// Search before anything's typed: Recommended for you, as Netflix's search page has it.
    @ViewBuilder private func suggestionsSection(_ client: JellyfinClient) -> some View {
        let items = suggestions
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                heading("Recommended for you")
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.Id) { item in JellySuggestionRow(item: item, client: client, playing: $playing) }
                }
            }
        }
    }
    /// About twenty titles from your recommendations (Because you watched, the Dynamic rows, Hidden
    /// gems, Recently added), taking turns so each has a say: films and shows, unwatched, no repeats,
    /// none from a library switched off for recommendations or hidden.
    private var suggestions: [JellyfinClient.Item] {
        let recent = recommendLibraries.flatMap { latest[$0.id] ?? [] }
        let pools: [[JellyfinClient.Item]] = [forYou?.items ?? [], themes.flatMap(\.items), gemItems, recent].map(shown)
        var seen = Set<String>(), out: [JellyfinClient.Item] = []
        var index = 0
        while out.count < 20, pools.contains(where: { $0.count > index }) {
            for pool in pools where pool.count > index && out.count < 20 {
                let item = pool[index]
                guard item.kind == "Movie" || item.kind == "Series", item.UserData?.Played != true,
                      !JellyServerEdits.shared.isDeleted(item), seen.insert(item.Id).inserted else { continue }
                out.append(item)
            }
            index += 1
        }
        return out
    }
    /// Search results that aren't on the server: request them through Jellyseerr.
    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Request")
            ForEach(seerrResults.prefix(12)) { result in
                HStack(spacing: 12) {
                    Artwork(path: result.posterPath, title: result.label, initialsOnly: false)
                        .frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                        Text([result.year, result.mediaType == "tv" ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    }
                    Spacer(minLength: 8)
                    requestButton(result)
                }
            }
            if let requestNotice { Text(requestNotice).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private func requestButton(_ result: JellySeerr.Result) -> some View {
        let status = requested.contains(result.id) ? 2 : result.status
        if status >= 2 {
            Text(status == 5 ? "Available" : status == 4 ? "Partly there" : "Requested")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
        } else {
            Button {
                guard let seerr = JellySpace.seerr else { return }
                Task {
                    do {
                        try await seerr.request(result)
                        requested.insert(result.id)
                        requestNotice = nil
                    } catch {
                        requestNotice = error.localizedDescription
                    }
                }
            } label: {
                Text("Request").font(.system(size: 13, weight: .bold)).foregroundStyle(ThemeStore.current.accentInk)
                    .padding(.horizontal, 14).frame(height: 32).background(ThemeStore.accent, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-request-\(result.id)")
        }
    }

    /// Up to eight of the newest films and shows with a backdrop, taking turns between libraries.
    private var heroPicks: [JellyfinClient.Item] {
        let newest = newestPicks
        let spotlight = shown(discover?.gems ?? []).filter { !($0.BackdropImageTags ?? []).isEmpty }
        var picks: [JellyfinClient.Item] = [], seen = Set<String>()
        for index in 0..<max(newest.count, spotlight.count) where picks.count < 8 {
            for item in [index < newest.count ? newest[index] : nil, index < spotlight.count ? spotlight[index] : nil].compactMap({ $0 })
            where picks.count < 8 && seen.insert(item.Id).inserted {
                picks.append(item)
            }
        }
        return picks
    }
    /// The newest films and shows with a backdrop, taking turns between libraries.
    private var newestPicks: [JellyfinClient.Item] {
        let rows = recommendLibraries.compactMap { latest[$0.id].map(shown) }
        var picks: [JellyfinClient.Item] = []
        var index = 0
        while picks.count < 8, rows.contains(where: { $0.count > index }) {
            for row in rows where row.count > index && picks.count < 8 {
                let item = row[index]
                if item.kind == "Movie" || item.kind == "Series", item.BackdropImageTags?.isEmpty == false { picks.append(item) }
            }
            index += 1
        }
        return picks
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold)).tracking(-0.2).foregroundStyle(HomeStyle.primary).lineLimit(1).accessibilityAddTraits(.isHeader)
    }

    /// Your libraries as small pills (each library's newest have a row of their own further down).
    /// The top of the home: "JellySpace" with Jellyfin's logo, large, in the top bar's row (the search
    /// button beside it), and My Media's libraries under it as text on glass, in your order (Settings →
    /// JellySpace → My Media). White over the poster; the page's own colour without one.
    private func homeHeader() -> some View {
        let ink = HomeStyle.primary
        let chips = JellyHomeRow.hidden(hiddenRowsRaw).contains(.media) ? [] : JellyMediaOrder.sorted(visibleLibraries, mediaOrderRaw)
        return VStack(alignment: .leading, spacing: 8) {
            if !chips.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(chips) { library in
                            NavigationLink(value: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder", type: library.type)) {
                                chip(Text(library.name), ink: ink)
                            }
                            .buttonStyle(.springPress).accessibilityIdentifier("jellyspace-library-" + library.id)
                            .contextMenu { Button("Hide library", systemImage: "eye.slash") { JellyHidden.hide(library.id, name: library.name) } }
                        }
                        // Categories: every genre, each opening its list.
                        if let genres = discover?.genres, !genres.isEmpty {
                            Menu {
                                ForEach(genres, id: \.Id) { genre in
                                    Button(genre.Name ?? "Genre") {
                                        router.paths[router.selectedTab, default: NavigationPath()]
                                            .append(JellyListRoute(kind: .genre, id: genre.Id, name: genre.Name ?? "Genre"))
                                    }
                                }
                            } label: {
                                chip(Text("Categories \(Image(systemName: "chevron.down"))"), ink: ink)
                            }
                            .buttonStyle(.springPress).accessibilityLabel("Categories").accessibilityIdentifier("jellyspace-categories")
                        }
                    }
                }
                .scrollIndicators(.hidden).scrollClipDisabled()
                .contentMargins(.horizontal, 16, for: .scrollContent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Just under the back and search buttons (with "JellySpace" between them).
        .padding(.top, topInset + 6)
    }

    /// One of the chips under the title, as Netflix has them: the name on glass with a fine edge
    /// (readable over any picture).
    private func chip(_ label: Text, ink: Color) -> some View {
        label.font(.system(size: 14, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 36)
            .glassEffect(.regular.interactive(), in: Capsule())
            .overlay { Capsule().strokeBorder(ink.opacity(0.18), lineWidth: 0.5) }
            .contentShape(Capsule())
    }

    /// Continue Watching: what you stopped partway through, then the next episode of each show you're
    /// following (marked Next up); wide cards that play at once.
    private func continueRow(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headingWithAll("Continue Watching", ids: continueItems.map(\.item.Id), identifier: "continue")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: shelfGap) {
                    ForEach(continueItems, id: \.id) { entry in
                        JellyWideCard(item: entry.item, client: client, playing: $playing, nextUp: entry.nextUp, large: true,
                                      pictureOnly: !captions, onRemove: entry.nextUp ? nil : { removeFromResume(entry.item) })
                            .containerRelativeFrame(.horizontal, count: captions ? 4 : 2, span: captions ? 3 : 1, spacing: shelfGap)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
    /// Started first; then next episodes, leaving out any show already there.
    private var continueItems: [JellyContinueEntry] {
        let started = shown(resume)
        let following = shown(nextUp).filter { next in
            !started.contains { $0.Id == next.Id || ($0.SeriesId != nil && $0.SeriesId == next.SeriesId) }
        }
        return started.map { JellyContinueEntry(item: $0, nextUp: false) } + following.map { JellyContinueEntry(item: $0, nextUp: true) }
    }

    /// A row's heading with the round › to its whole list on a page of its own.
    private func headingWithAll(_ title: String, ids: [String], identifier: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            heading(title)
            Spacer(minLength: 8)
            SectionMoreLink(label: "View more " + title, value: JellyShelfRoute(title: title, ids: ids), identifier: "jellyspace-more-" + identifier)
        }
    }
    /// A row of posters (a library's newest, your favourites, collections), with the app's round ›
    /// to the whole list.
    private func tileRow<Route: Hashable>(_ title: String, items: [JellyfinClient.Item], client: JellyfinClient, more: Route) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                heading(title)
                Spacer(minLength: 8)
                SectionMoreLink(label: "View more " + title, value: more, identifier: "jellyspace-more-" + title)
            }
            posterShelf(items, client: client)
        }
    }
    /// "Because you watched Your Name": Jellyfin's own picks from what you've watched or liked.
    private func forYouRow(_ picks: JellyForYou, client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headingWithAll(picks.title, ids: shown(picks.items).map(\.Id), identifier: "for-you")
            posterShelf(shown(picks.items), client: client)
        }
    }
    private func posterShelf(_ items: [JellyfinClient.Item], client: JellyfinClient) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: shelfGap) {
                ForEach(items, id: \.Id) { item in
                    JellyTile(item: item, client: client, playing: $playing, home: true).frame(width: shelfWidth)
                }
            }
        }.scrollIndicators(.hidden).scrollClipDisabled()
    }
    /// The gap between a row's cards: close together without names (the Netflix look).
    private var shelfGap: CGFloat { captions ? 12 : 6 }
    /// A row's poster width: a fifth bigger without names.
    private var shelfWidth: CGFloat { posterSize.homeWidth * (captions ? 1 : 1.2) }

    // MARK: Discover rows

    /// The genres as pills; each opens its list.
    private func genreChips(_ genres: [JellyfinClient.Item]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.Id) { genre in
                    NavigationLink(value: JellyListRoute(kind: .genre, id: genre.Id, name: genre.Name ?? "Genre")) {
                        Text(genre.Name ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            .padding(.horizontal, 14).frame(height: 34).background(Color.primary.opacity(0.09), in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-genre-" + genre.Id)
                }
            }
        }.scrollIndicators(.hidden).scrollClipDisabled()
    }
    /// "Top 10 in Movies": the posters with their place in big numbers behind them.
    private func topTenRow(_ shelf: JellyShelf, client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(shelf.title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(shown(shelf.items).prefix(10).enumerated()), id: \.element.Id) { index, item in
                        NavigationLink(value: JellyDetailRoute(id: item.Id, name: item.Name ?? "")) {
                            HStack(alignment: .bottom, spacing: -20) {
                                Text("\(index + 1)").font(.system(size: 104, weight: .black)).tracking(-6)
                                    .foregroundStyle(HomeStyle.primary.opacity(0.18)).fixedSize().offset(y: 16)
                                JellyPosterImage(item: item, client: client)
                                    .frame(width: posterSize.homeWidth, height: posterSize.homeWidth * 1.5)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.outline(0.08), lineWidth: HomeStyle.hairline))
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.springPress).accessibilityLabel("Number \(index + 1): " + (item.Name ?? ""))
                        .accessibilityIdentifier("jellyspace-top-\(index + 1)")
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
    /// Hidden gems: big posters with their rating, unwatched and rated 7.5 or more.
    private func gemsRow(_ items: [JellyfinClient.Item], client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                heading("Hidden gems")
                Spacer(minLength: 8)
                Text("Unwatched · 7.5+").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1).fixedSize()
                SectionMoreLink(label: "View more Hidden gems", value: JellyShelfRoute(title: "Hidden gems", ids: items.map(\.Id)),
                                identifier: "jellyspace-more-gems")
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: shelfGap) {
                    ForEach(items, id: \.Id) { item in
                        JellyTile(item: item, client: client, playing: $playing, home: true)
                            .overlay(alignment: .topLeading) { if let score = item.CommunityRating, score > 0 { PosterScoreBadge(score: score) } }
                            .frame(width: posterSize.homeWidth * 1.4)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
    /// "Tonight: Romance": wide cards from one genre, with the app's round › to the whole genre.
    private func tonightRow(_ shelf: JellyShelf, client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                heading(shelf.title)
                Spacer(minLength: 8)
                if let genre = shelf.genre {
                    SectionMoreLink(label: "View more " + genre, value: JellyListRoute(kind: .genre, id: String(shelf.id.dropFirst("tonight-".count)), name: genre),
                                    identifier: "jellyspace-tonight-all")
                }
            }
            wideShelf(shown(shelf.items), client: client, width: posterSize.homeWidth * 2.1)
        }
    }
    /// A shelf with its own shuffle button: a library's random posters, or (a plain library) its
    /// videos as wide frames.
    private func shuffledRow(_ shelf: JellyShelf, client: JellyfinClient, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                heading(shelf.title)
                Spacer(minLength: 8)
                Button { reshuffle(shelf) } label: {
                    Image(systemName: "shuffle").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Shuffle " + shelf.title).accessibilityIdentifier("jellyspace-shuffle-" + shelf.id)
                if let library = shelf.library {
                    SectionMoreLink(label: "Open " + library.name, value: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder", type: library.type),
                                    identifier: "jellyspace-more-" + shelf.id)
                }
            }
            if wide { wideShelf(shown(shelf.items), client: client, width: posterSize.homeWidth * 1.6) } else { posterShelf(shown(shelf.items), client: client) }
        }
    }
    private func wideShelf(_ items: [JellyfinClient.Item], client: JellyfinClient, width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: shelfGap) {
                ForEach(items, id: \.Id) { item in
                    JellyTile(item: item, client: client, playing: $playing, wide: true, home: true).frame(width: width)
                }
            }
        }.scrollIndicators(.hidden).scrollClipDisabled()
    }
    /// Hidden gems not already on the top poster.
    private var gemItems: [JellyfinClient.Item] {
        let onPoster = JellyHomeRow.hidden(hiddenRowsRaw).contains(.hero) ? [] : Set(heroPicks.map(\.Id))
        return shown(discover?.gems ?? []).filter { !onPoster.contains($0.Id) }
    }
    /// One shelf drawn again from its library.
    private func reshuffle(_ shelf: JellyShelf) {
        guard let client = JellySpace.client, let library = shelf.library else { return }
        Task {
            let user = await JellyfinUser.id(client)
            let items = await JellyDiscover.random(client: client, user: user, library: library)
            guard !items.isEmpty, var current = discover else { return }
            if let index = current.random.firstIndex(where: { $0.id == shelf.id }) { current.random[index].items = items }
            withAnimation(.smooth(duration: 0.3)) { discover = current }
            JellyHomeCache.discover = current
        }
    }
    /// Discover's shelves: kept for the session (the same server, user and hidden libraries), drawn
    /// afresh on a pull to refresh. Skipped while none of them, nor the top poster, is shown.
    private func loadDiscover(force: Bool = false) async {
        let off = JellyHomeRow.hidden(hiddenRowsRaw)
        guard !off.contains(.hero) || !JellyHomeRow.discoverRows.isSubset(of: off) else { return }
        guard let client = JellySpace.client, let user = await JellyfinUser.id(client) else { return }
        let key = client.base.absoluteString + "|" + user + "|" + hiddenRaw + "|" + recommendOffRaw
        if !force, JellyHomeCache.discoverKey == key, let cached = JellyHomeCache.discover {
            discover = cached
            return
        }
        let all = libraries.isEmpty ? ((try? await client.libraries()) ?? []) : libraries
        let hiddenIDs = self.hidden
        let defaults = UserDefaults.standard, turn = defaults.integer(forKey: "jellyspace.discover.turn")
        defaults.set(turn + 1, forKey: "jellyspace.discover.turn")
        let off = JellyRecommendOff.ids(recommendOffRaw)
        let found = await JellyDiscover.load(client: client, user: user, libraries: all.filter { hiddenIDs[$0.id] == nil && !off.contains($0.id) }, turn: turn)
        guard !Task.isCancelled else { return }
        withAnimation(.smooth(duration: 0.3)) { discover = found }
        JellyHomeCache.discover = found
        JellyHomeCache.discoverKey = key
    }

    /// Off Continue Watching: its place is cleared in Jellyfin (it starts from the beginning next time).
    private func removeFromResume(_ item: JellyfinClient.Item) {
        withAnimation { resume.removeAll { $0.Id == item.Id } }
        JellyHomeCache.resume = resume
        guard let client = JellySpace.client else { return }
        let id = item.Id
        Task {
            guard let user = await JellyfinUser.id(client) else { return }
            try? await client.savePosition(id, user: user, seconds: 0)
        }
    }

    /// What was loaded last time shows at once; it's fetched again when it's over a minute old.
    private func appear() async {
        guard let client = JellySpace.client else { return }
        // The rows were loaded for a server and a user: another user (or server) loads afresh.
        let server = client.base.absoluteString + "|" + (await JellyfinUser.id(client) ?? "")
        if libraries.isEmpty, JellyHomeCache.server == server, JellyHomeCache.at != nil {
            libraries = JellyHomeCache.libraries; resume = JellyHomeCache.resume; favourites = JellyHomeCache.favourites
            collections = JellyHomeCache.collections; latest = JellyHomeCache.latest
            nextUp = JellyHomeCache.nextUp; forYou = JellyHomeCache.forYou; loaded = true
        }
        if JellyHomeCache.server == server, let at = JellyHomeCache.at, Date.now.timeIntervalSince(at) < 60, !libraries.isEmpty { return }
        await loadHome()
    }
    private func loadHome() async {
        guard let client = JellySpace.client else { return }
        loading = libraries.isEmpty; failure = nil
        defer { loading = false; loaded = true }
        do {
            libraries = try await client.libraries()
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
        await loadRows()
    }
    /// Continue Watching, favourites, each library's newest and collections (they change after each watch).
    private func loadRows() async {
        guard let client = JellySpace.client, let user = await JellyfinUser.id(client) else { return }
        // The library index for recommending, built beside the rows (More like this then finds it ready).
        JellyIndexStore.warm(client: client, user: user)
        // Whether Delete from server is offered (asked once a session).
        Task { await JellyServerEdits.shared.check(client: client) }
        async let started = client.resume(user: user)
        async let liked = client.items([URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode")], filters: ["IsFavorite"], user: user, sort: .added, limit: 20)
        async let sets = client.items([URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")], user: user, limit: 20)
        async let following = client.nextUp(user: user)
        // Only the film libraries shown on the home (a hidden library's titles mustn't turn up here).
        let filmLibraries = recommendLibraries.filter { $0.type == "movies" }.map(\.id)
        async let picks = JellyForYou.load(client: client, user: user, libraries: filmLibraries)
        resume = (try? await started) ?? []
        nextUp = (try? await following) ?? []
        forYou = await picks
        favourites = (try? await liked) ?? []
        collections = (try? await sets) ?? []
        // Every library's newest at once.
        latest = await withTaskGroup(of: (String, [JellyfinClient.Item]).self) { group in
            for id in libraries.map(\.id) {
                group.addTask { (id, (try? await client.latest(in: id, user: user)) ?? []) }
            }
            var newest: [String: [JellyfinClient.Item]] = [:]
            for await (id, items) in group { newest[id] = items }
            return newest
        }
        // Each show's unwatched count, for "3 new" on its poster.
        JellyNewEpisodes.note(latest.values.flatMap { $0 } + favourites)
        JellyHomeCache.server = client.base.absoluteString + "|" + user; JellyHomeCache.at = .now
        JellyHomeCache.libraries = libraries; JellyHomeCache.resume = resume; JellyHomeCache.favourites = favourites
        JellyHomeCache.collections = collections; JellyHomeCache.latest = latest
        JellyHomeCache.nextUp = nextUp; JellyHomeCache.forYou = forYou
        await loadThemes()
    }
    /// The Dynamic recommendations rows across the whole server, from the library index (built once in
    /// the background), as many as the setting says.
    private func loadThemes() async {
        guard let client = JellySpace.client, let user = await JellyfinUser.id(client),
              let index = await JellyIndexStore.index(client: client, user: user) else { return }
        let count = min(5, max(1, themeCount)), excluded = JellyRecommendOff.ids(recommendOffRaw)
        let found = await Task.detached(priority: .utility) { JellyRecommender.themes(in: index, count: count, excluded: excluded) }.value
        withAnimation(.smooth) { themes = found }
    }
}

/// Which top poster is on show. Only the poster row and the glow behind it read it, so the poster
/// changing every five seconds doesn't redraw the whole home (which sent an open Categories menu,
/// or a long-press menu, back to its top).
@MainActor @Observable final class JellyHeroSelection {
    var id: String?
}

/// The top card's picture, blurred and faded, behind the title, the chips and the card (as Netflix
/// tints its home with the poster's colours); it changes with the card.
private struct JellyHeroGlow: View {
    let picks: [JellyfinClient.Item]
    let client: JellyfinClient
    let selection: JellyHeroSelection
    let topInset: CGFloat

    var body: some View {
        if let item = picks.first(where: { $0.Id == selection.id }) ?? picks.first, let url = JellyHero.cardImage(item, base: client.base) {
            JellyImage(url: url)
                .frame(maxWidth: .infinity).frame(height: 780).clipped()
                .blur(radius: 60).opacity(0.55)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.top, -topInset)
                .id(item.Id).transition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: item.Id)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// JellySpace's top poster, as Explore's: the newest films and shows, a new one every five seconds
/// while it's on screen, swipeable; a tap opens its page.
private struct JellyHeroCarousel: View {
    let items: [JellyfinClient.Item]
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    @Bindable var selection: JellyHeroSelection
    @State private var shown = false
    @State private var scrolledInto = true
    @State private var swiping = false
    private var selected: String? {
        get { selection.id }
        nonmutating set { selection.id = newValue }
    }

    var body: some View {
        let current = items.firstIndex { $0.Id == selected } ?? 0
        VStack(spacing: 12) {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items, id: \.Id) { item in
                    JellyHero(item: item, client: client, playing: $playing)
                        .padding(.horizontal, 16)
                        .containerRelativeFrame(.horizontal).id(item.Id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $selection.id)
        .onScrollPhaseChange { _, phase in swiping = phase == .interacting || phase == .decelerating }
        .haptic(.selection, trigger: selected) { _, _ in swiping }
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { position in
                        Capsule().fill(HomeStyle.primary.opacity(position == current ? 0.9 : 0.3))
                            .frame(width: position == current ? 14 : 5, height: 5)
                    }
                }
                .animation(.snappy(duration: 0.25), value: current)
                .accessibilityHidden(true)
            }
        }
        .onAppear { shown = true; if selected == nil { selected = items.first?.Id } }
        .onDisappear { shown = false }
        .onScrollVisibilityChange(threshold: 0.25) { scrolledInto = $0 }
        .task(id: "\(shown && scrolledInto)|\(selected ?? "")") {
            guard shown, scrolledInto, items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let next = items[(current + 1) % items.count].Id
            withAnimation(.smooth(duration: 0.6)) { selected = next }
        }
    }
}

/// One top poster: the backdrop fading into the page, the title's logo (or its name) centred on the
/// fade with its year, genres and rating, then Play (Resume, or a show's next episode) and Favourite,
/// side by side. A tap anywhere else on the poster opens its page.
private struct JellyHero: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 470
    @State private var starting = false
    /// Set once you've tapped Favourite here (until then, what the server said).
    @State private var favourite: Bool?
    /// Whether the poster has the title written on it (read once on the phone; nil until then).
    @State private var posterTitled: Bool?
    private var isFavourite: Bool { favourite ?? item.UserData?.IsFavorite ?? false }

    private var route: JellyDetailRoute { JellyDetailRoute(id: item.Id, name: item.Name ?? "") }
    /// "Film" or "Series", first on the facts line (as Netflix's "Series · …").
    private var kindName: String? {
        switch item.kind {
        case "Movie": "Film"
        case "Series": "Series"
        default: nil
        }
    }
    /// "2023 · Anime · Drama".
    private var facts: String {
        ([item.ProductionYear.map(String.init)].compactMap { $0 } + (item.Genres ?? []).prefix(2)).joined(separator: " · ")
    }
    /// Resume for a film you've started; Play Film, Play Show; else Play.
    private var playLabel: String {
        switch item.kind {
        case "Movie": (item.UserData?.PlayedPercentage ?? 0) > 0 ? "Resume" : "Play Film"
        case "Series": "Play Show"
        default: "Play"
        }
    }
    /// Upright the card shows the poster whole; sideways, the backdrop.
    private var showsPoster: Bool { verticalSizeClass != .compact && item.ImageTags?["Primary"] != nil }
    /// The logo (or name) over the picture: always on the backdrop; on a poster only when its title
    /// isn't written on it already (so it never shows twice).
    private var showsTitle: Bool { !showsPoster || (posterTitled ?? JellyPosterText.known(item)) == false }

    var body: some View {
        VStack(spacing: 9) {
            if showsTitle { NavigationLink(value: route) { titleMark }.buttonStyle(.plain).transition(.opacity) }
            HStack(spacing: 5) {
                if let kindName {
                    Text(kindName).fontWeight(.bold)
                    if !facts.isEmpty { Text("·") }
                }
                if !facts.isEmpty { Text(facts) }
                if let score = item.CommunityRating, score > 0 {
                    if !facts.isEmpty { Text("·") }
                    Image(systemName: "star.fill").foregroundStyle(Color(themed: "#f5c451")).accessibilityLabel("Rating")
                    Text(String(format: "%.1f", score))
                }
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            HStack(spacing: 10) {
                playButton
                favouriteButton
            }.padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // The poster's own shape upright, so it fits whole; a wide card sideways.
        .aspectRatio(verticalSizeClass == .compact ? 16 / 9 : 2 / 3, contentMode: .fit)
        .background {
            // The picture itself opens the title's page.
            NavigationLink(value: route) { cardArt }
                .buttonStyle(.plain)
                .accessibilityLabel("About " + (item.Name ?? "this title")).accessibilityIdentifier("jellyspace-hero-" + item.Id)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        // Read the poster once for its written title (kept, so only a new poster is read again).
        .task(id: item.Id) {
            guard posterTitled == nil, JellyPosterText.known(item) == nil, let poster = Self.posterImage(item, base: client.base) else { return }
            let titled = await JellyPosterText.hasTitle(item, poster: poster)
            withAnimation(.smooth(duration: 0.3)) { posterTitled = titled }
        }
    }

    /// Play: white with black writing, as Netflix's.
    private var playButton: some View {
        Button { Task { await play() } } label: {
            HStack(spacing: 7) {
                if starting { ProgressView().controlSize(.small).tint(.black) } else { Image(systemName: "play.fill") }
                Text(playLabel).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
            .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 42)
            .background(.white, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.springPress).disabled(starting)
        .accessibilityLabel(playLabel + " " + (item.Name ?? "")).accessibilityIdentifier("jellyspace-hero-play-" + item.Id)
    }
    /// Favourite, on glass beside Play.
    private var favouriteButton: some View {
        let symbol = isFavourite ? "heart.fill" : "heart"
        return Button { toggleFavourite() } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
                Text("Favourite").lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 12).frame(maxWidth: .infinity).frame(height: 42)
            .background(.ultraThinMaterial, in: Capsule())
            .background(.white.opacity(0.12), in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.springPress)
        .sensoryFeedback(.selection, trigger: isFavourite)
        .accessibilityLabel(favouriteLabel)
        .accessibilityIdentifier("jellyspace-hero-favourite-" + item.Id)
    }
    private var favouriteLabel: String {
        let name = item.Name ?? "this title"
        return isFavourite ? "Remove \(name) from favourites" : "Add \(name) to favourites"
    }

    private func toggleFavourite() {
        let now = !isFavourite
        withAnimation(.snappy(duration: 0.2)) { favourite = now }
        let id = item.Id
        Task {
            guard let user = await JellyfinUser.id(client) else { return }
            do { try await client.setFavourite(id, user: user, now) } catch { favourite = !now }
        }
    }

    @ViewBuilder private var titleMark: some View {
        if let logo = item.ImageTags?["Logo"] {
            JellyImage(url: JellyfinClient.imageURL(base: client.base, item: item.Id, type: "Logo", tag: logo, width: 700), mode: .fit)
                .frame(maxWidth: 260, maxHeight: 96).shadow(color: .black.opacity(0.4), radius: 10)
                .accessibilityElement().accessibilityLabel(item.Name ?? "").accessibilityAddTraits(.isHeader)
        } else {
            Text(item.Name ?? "").font(.system(size: 30, weight: .bold)).tracking(-0.4).foregroundStyle(.white)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7).accessibilityAddTraits(.isHeader)
        }
    }

    /// The card's picture: the poster upright, the backdrop sideways, darkening toward the foot where
    /// the buttons sit.
    private var cardArt: some View {
        Color.clear
            .overlay { JellyImage(url: showsPoster ? Self.posterImage(item, base: client.base) : Self.cardImage(item, base: client.base)) }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.55), location: 0.7),
                                       .init(color: .black.opacity(0.88), location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
    }
    /// The poster at card size.
    static func posterImage(_ item: JellyfinClient.Item, base: URL) -> URL? {
        item.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: base, item: item.Id, type: "Primary", tag: $0, width: 900) }
    }
    /// The backdrop at card size; the poster when there's none.
    static func cardImage(_ item: JellyfinClient.Item, base: URL) -> URL? {
        if let tag = item.BackdropImageTags?.first { return JellyfinClient.imageURL(base: base, item: item.Id, type: "Backdrop", tag: tag, width: 1280) }
        return item.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: base, item: item.Id, type: "Primary", tag: $0, width: 900) }
    }

    /// A film plays at once (from where you stopped); a show plays its next episode (its first when
    /// you haven't started it).
    private func play() async {
        if item.kind != "Series" {
            playing = JellySpace.playback(item, client: client)
            return
        }
        starting = true
        defer { starting = false }
        guard let user = await JellyfinUser.id(client), let next = try? await client.nextUp(series: item.Id, user: user) else { return }
        playing = JellySpace.playback(next, client: client)
    }
}

/// "JellySpace" in the top bar once the page has scrolled: Jellyfin's own logo (the app's
/// jellyfin-mark, as BrandLogo shows it) and the name, fading in and lifting slightly as a title
/// page's name does.
private struct JellySpaceBarTitle: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("jellyfin-mark").resizable().scaledToFit().frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("JellySpace").font(.system(size: 19, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// The home while it first loads, in the shape it's about to take: the top poster fading into the
/// page with the title, details, Play and Favourite placed where they'll be, then Continue Watching's
/// cards. It breathes gently (still with Reduce Motion).
private struct JellyHomeSkeleton: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 470
    @State private var dim = false

    var body: some View {
        let fill = Color.primary.opacity(dim ? 0.06 : 0.1)
        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(dim ? 0.05 : 0.08))
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                VStack(spacing: 10) {
                    Capsule().fill(fill).frame(width: 210, height: 30)
                    Capsule().fill(fill).frame(width: 150, height: 12)
                    HStack(spacing: 10) {
                        Capsule().fill(fill).frame(height: 44)
                        Capsule().fill(fill).frame(height: 44)
                    }.padding(.top, 5).padding(.horizontal, 24)
                }.padding(.bottom, 36)
            }
            .frame(height: verticalSizeClass == .compact ? 280 : min(height, 600))
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(fill).frame(width: 170, height: 18)
                HStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 8).fill(fill).aspectRatio(16 / 9, contentMode: .fit)
                            Capsule().fill(fill).frame(width: 110, height: 12)
                            Capsule().fill(fill).frame(width: 70, height: 10)
                        }
                    }
                }
            }.padding(.horizontal, 14)
        }
        .onAppear { withAnimation(.easeInOut(duration: reduceMotion ? 1.6 : 0.9).repeatForever(autoreverses: true)) { dim = true } }
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading Jellyfin")
    }
}

/// One card in Continue Watching: the item, and whether it's a show's next episode rather than one
/// you've started.
struct JellyContinueEntry {
    let item: JellyfinClient.Item
    let nextUp: Bool
    var id: String { item.Id }
}

/// The For you row: its heading ("Because you watched Your Name") and Jellyfin's picks.
struct JellyForYou: Sendable {
    let title: String
    let items: [JellyfinClient.Item]

    /// From each library in turn until one has picks "because you watched" something; else the first
    /// library with any picks at all.
    static func load(client: JellyfinClient, user: String, libraries: [String]) async -> JellyForYou? {
        var fallback: JellyForYou?
        for library in libraries {
            let groups = (try? await client.recommendations(user: user, library: library)) ?? []
            if groups.contains(where: { ($0.RecommendationType ?? "").hasPrefix("SimilarTo") && !($0.Items ?? []).isEmpty }) { return pick(groups) }
            if fallback == nil { fallback = pick(groups) }
        }
        return fallback
    }
    /// The first of Jellyfin's recommendation groups that has anything, with a heading for its kind.
    static func pick(_ groups: [JellyfinClient.Recommendation]) -> JellyForYou? {
        let usable = groups.filter { !($0.Items ?? []).isEmpty }
        guard let group = usable.first(where: { ($0.RecommendationType ?? "").hasPrefix("SimilarTo") }) ?? usable.first else { return nil }
        let name = group.BaselineItemName ?? ""
        let title: String = switch group.RecommendationType ?? "" {
        case "SimilarToRecentlyPlayed" where !name.isEmpty: "Because you watched " + name
        case "SimilarToLikedItem" where !name.isEmpty: "Because you liked " + name
        case let kind where kind.hasPrefix("Has") && !name.isEmpty: "More with " + name
        default: "For you"
        }
        return JellyForYou(title: title, items: group.Items ?? [])
    }
}

/// "3 new" on a show's poster: how many more unwatched episodes it has than when you last saw it in
/// JellySpace (its page opened, or first seen on the home). Watching some lowers the mark with it.
@MainActor enum JellyNewEpisodes {
    private static let key = "jellyspace.seenUnwatched"
    private static var marks: [String: Int] = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]

    static func count(_ item: JellyfinClient.Item) -> Int? {
        guard item.kind == "Series", let left = item.UserData?.UnplayedItemCount, let mark = marks[item.Id], left > mark else { return nil }
        return left - mark
    }
    /// After the home loads: a show seen for the first time sets its mark; one with fewer unwatched
    /// than its mark (you watched some) lowers it.
    static func note(_ items: [JellyfinClient.Item]) {
        var changed = false
        for item in items where item.kind == "Series" {
            guard let left = item.UserData?.UnplayedItemCount else { continue }
            if let mark = marks[item.Id], mark <= left { continue }
            marks[item.Id] = left
            changed = true
        }
        if changed { save() }
    }
    /// A show's page opened: what's new there now has been seen.
    static func seen(_ id: String, unwatched: Int) {
        guard marks[id] != unwatched else { return }
        marks[id] = unwatched
        save()
    }
    private static func save() { UserDefaults.standard.set(marks, forKey: key) }
}

/// A library, folder, show or season: folders and shows open deeper, a show lists its seasons, a
/// season its episodes, and films, episodes and videos play. Sort and Unwatched sit in the ••• menu.
struct JellyFolderPage: View {
    let route: JellyFolderRoute
    /// Posters, landscape cards or Canvas, remembered for this library or folder.
    @AppStorage private var layout: JellyGridLayout
    /// Library, Folder, Genres or Studios, remembered for this one.
    @AppStorage private var browse: JellyBrowse
    /// Sort, order and filters (JellyBrowseOptions as JSON), remembered for this one.
    @AppStorage private var optionsRaw: String
    init(route: JellyFolderRoute) {
        self.route = route
        _layout = JellyLayout.storage(route.id)
        _browse = AppStorage(wrappedValue: .library, JellyLayout.browseKey(route.id))
        _optionsRaw = AppStorage(wrappedValue: "", JellyBrowseOptions.key(route.id))
    }
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @AppStorage("jellyspace.music.view") private var musicView = "Albums"
    @State private var items: [JellyfinClient.Item] = []
    /// Genres or Studios: their tiles.
    @State private var tiles: [JellyfinClient.Item] = []
    /// The genres in here, for the Filter menu.
    @State private var genreNames: [String] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    /// How many the server has, and how many came so far (a big folder loads 200 at a time).
    @State private var total = 0
    @State private var fetched = 0
    @State private var loadingMore = false
    private let pageSize = 200
    private var music: Bool { route.type == "music" }
    private var options: JellyBrowseOptions { JellyBrowseOptions.decode(optionsRaw) }
    private var optionsBinding: Binding<JellyBrowseOptions> {
        Binding(get: { JellyBrowseOptions.decode(optionsRaw) }, set: { optionsRaw = $0.encoded })
    }
    /// Genres or Studios shown as tiles (in a library or folder that can be browsed so).
    private var showsTiles: Bool { browsable && !browse.listsTitles }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if music {
                        Picker("View", selection: $musicView) {
                            ForEach(["Albums", "Artists", "Folders"], id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented).padding(.horizontal, 6).accessibilityIdentifier("jellyspace-music-view")
                    }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty && tiles.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if showsTiles ? tiles.isEmpty : items.isEmpty {
                        Text(options.filtering && !showsTiles ? "Nothing matches these filters." : "Nothing in here.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if showsTiles {
                        // Each genre or studio of this library, opening its titles here.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                            ForEach(tiles, id: \.Id) { tile in
                                NavigationLink(value: JellyListRoute(kind: browse == .studios ? .studio : .genre, id: tile.Id, name: tile.Name ?? "", library: route.id)) {
                                    JellyNameTile(item: tile, client: client)
                                }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-tile-" + tile.Id)
                            }
                        }
                    } else if route.kind == "Season" {
                        LazyVStack(spacing: 8) { ForEach(items, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing) } }
                    } else {
                        // Albums, videos and the rest as posters; photos as a grid of squares, songs as a
                        // list, after them.
                        let photos = items.filter { $0.kind == "Photo" }, songs = items.filter { $0.kind == "Audio" }
                        let rest = items.filter { $0.kind != "Photo" && $0.kind != "Audio" }
                        if !rest.isEmpty { JellyGrid(items: rest, client: client, playing: $playing, layout: layout) { Task { await loadMore() } } }
                        if !photos.isEmpty { JellyPhotoGrid(photos: photos, client: client) { Task { await loadMore() } } }
                        if loadingMore { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8) }
                        if !songs.isEmpty { JellyTrackList(tracks: songs) }
                    }
                }
            }.padding(.horizontal, route.kind == "Season" ? 16 : 10).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar {
            if sortable {
                ToolbarItem(placement: .topBarTrailing) {
                    JellyBrowseMenu(options: optionsBinding, layout: $layout, content: browsable ? $browse : nil,
                                    genres: browsable && browse == .library ? genreNames : nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { JellyMiniPlayer().padding(.bottom, 4) }
        .task(id: optionsRaw + hiddenRaw + musicView + browse.rawValue) { await load() }
        .task(id: browse.rawValue) { await loadGenreNames() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    /// Seasons, a show's season list and an album keep their own order.
    private var sortable: Bool { !["Season", "Series", "MusicAlbum"].contains(route.kind) }
    /// A library or a folder in one (not music, which has its own Albums, Artists and Folders, nor a
    /// collection): it can be browsed as a whole, folder by folder, or by genre or studio.
    private var browsable: Bool { sortable && !music && route.kind != "BoxSet" }
    /// One page: everything under it (Library, with every filter) or its own level (Folder, with the
    /// sort and the watched filter: genres and the like would hide its folders).
    private func page(_ client: JellyfinClient, user: String?, start: Int) async throws -> JellyfinClient.Page {
        if browsable, browse == .library {
            return try await client.libraryPage(of: route.id, libraryType: route.type, user: user, order: options.query(attributes: true),
                                                start: start, limit: pageSize)
        }
        if sortable {
            return try await client.folderPage(of: route.id, user: user, order: options.query(attributes: false), start: start, limit: pageSize)
        }
        return try await client.childrenPage(of: route.id, user: user, sort: nil, unwatched: false, start: start, limit: pageSize)
    }

    private func load() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let user = await JellyfinUser.id(client)
            if showsTiles {
                let found = browse == .studios ? try await client.studios(in: route.id, user: user) : try await client.genres(in: route.id, user: user)
                tiles = found.filter { !($0.Name ?? "").isEmpty }
                items = []; total = 0; fetched = 0
                return
            }
            tiles = []
            if music, musicView != "Folders" {
                // A music library by album or by artist (the whole library, not its folders).
                let found: [JellyfinClient.Item]
                if musicView == "Artists" {
                    found = try await client.artists(in: route.id, user: user)
                } else {
                    let options = options
                    found = try await client.items([URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"), URLQueryItem(name: "ParentId", value: route.id)],
                                                   filters: options.showFilter.map { [$0] } ?? [], user: user, sort: options.sort,
                                                   ascending: options.isAscending, limit: 2000)
                }
                total = found.count; fetched = found.count
                items = arrange(found)
                return
            }
            let first = try await page(client, user: user, start: 0)
            total = first.TotalRecordCount; fetched = first.Items.count
            items = arrange(first.Items)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
    /// The genres in here, for the Filter menu (the Library view only).
    private func loadGenreNames() async {
        guard browsable, browse == .library, genreNames.isEmpty, let client = JellySpace.client else { return }
        let user = await JellyfinUser.id(client)
        genreNames = ((try? await client.genres(in: route.id, user: user)) ?? []).compactMap(\.Name)
    }
    /// The next 200, when you near the end.
    private func loadMore() async {
        guard !loadingMore, !showsTiles, fetched < total, !(music && musicView != "Folders"), let client = JellySpace.client else { return }
        loadingMore = true
        defer { loadingMore = false }
        let user = await JellyfinUser.id(client)
        guard let next = try? await page(client, user: user, start: fetched) else { return }
        fetched += next.Items.count
        total = next.TotalRecordCount
        let known = Set(items.map(\.Id))
        items = arrange(items + next.Items.filter { !known.contains($0.Id) })
    }
    /// Without what you hid; folders first.
    private func arrange(_ found: [JellyfinClient.Item]) -> [JellyfinClient.Item] {
        let hidden = JellyHidden.decode(hiddenRaw)
        let kept = found.filter { hidden[$0.Id] == nil }
        return kept.filter { JellySpace.opens($0) } + kept.filter { !JellySpace.opens($0) }
    }
}

/// Posters three across.
struct JellyGrid: View {
    let items: [JellyfinClient.Item]
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    var layout = JellyGridLayout.posters
    /// Called as the last poster comes on screen (to load more).
    var reachedEnd: (() -> Void)? = nil
    /// A short line under a poster, by item id (why More like this picked it).
    var notes: [String: String] = [:]
    @State private var width: CGFloat = 0
    /// Without names under the posters, the grid closes up (the Netflix look).
    @AppStorage(JellyPrefs.captionsKey) private var captions = true
    var body: some View {
        if layout == .canvas {
            canvas
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: captions ? 12 : 6, alignment: .top), count: layout == .landscape ? 2 : 3)
            LazyVGrid(columns: columns, alignment: .leading, spacing: captions ? 18 : 6) {
                ForEach(items, id: \.Id) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        JellyTile(item: item, client: client, playing: $playing, wide: layout == .landscape)
                        if let note = notes[item.Id], !note.isEmpty {
                            Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(ThemeStore.accent).lineLimit(1)
                                .accessibilityLabel("Why: " + note)
                        }
                    }
                    .onAppear { if item.Id == items.last?.Id { reachedEnd?() } }
                }
            }
        }
    }
    /// Canvas: rows of three across, as posters, a wide card beside a poster, or one card the full
    /// width, in the titles' own order.
    private var canvas: some View {
        let column = max(0, (width - 24) / 3), tall = column * 1.5
        let rows = JellyCanvas.rows(items)
        return LazyVStack(spacing: 12) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    ForEach(row.cells) { cell in
                        JellyTile(item: cell.item, client: client, playing: $playing, canvas: cell.shape)
                            .frame(width: cell.shape == .poster ? column : cell.shape == .wide ? column * 2 + 12 : width,
                                   height: cell.shape == .full ? width * 9 / 16 : tall)
                    }
                    Spacer(minLength: 0)
                }
                .onAppear { if row.id == rows.last?.id { reachedEnd?() } }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A title's shape on the Canvas.
enum JellyCanvasShape: Hashable { case poster, wide, full }

/// The Canvas's rows. A rhythm of row shapes (three posters; a wide card and a poster; three
/// posters; a poster and a wide card; three posters; one full-width card) is followed in the titles'
/// own order: a title goes wide only when it has a landscape picture (a backdrop, Jellyfin's "Thumb"
/// art, or an episode's or video's own frame), and a row that doesn't fit falls back to three posters.
enum JellyCanvas {
    struct Cell: Identifiable {
        let item: JellyfinClient.Item
        let shape: JellyCanvasShape
        var id: String { item.Id }
    }
    struct Row: Identifiable {
        let id: Int
        let cells: [Cell]
    }
    private enum Pattern { case three, wideLeft, wideRight, full }
    private static let rhythm: [Pattern] = [.three, .wideLeft, .three, .wideRight, .three, .full]

    static func rows(_ items: [JellyfinClient.Item]) -> [Row] {
        var rows: [Row] = [], index = 0, beat = 0
        while index < items.count {
            let here = items[index], next = index + 1 < items.count ? items[index + 1] : nil
            var cells: [Cell]
            switch rhythm[beat % rhythm.count] {
            case .full where landscape(here):
                cells = [Cell(item: here, shape: .full)]
            case .wideLeft where landscape(here) && next != nil:
                cells = [Cell(item: here, shape: .wide), Cell(item: next!, shape: .poster)]
            case .wideRight where next.map(landscape) == true:
                cells = [Cell(item: here, shape: .poster), Cell(item: next!, shape: .wide)]
            case .wideRight where landscape(here) && next != nil:
                cells = [Cell(item: here, shape: .wide), Cell(item: next!, shape: .poster)]
            default:
                cells = items[index..<min(items.count, index + 3)].map { Cell(item: $0, shape: .poster) }
            }
            rows.append(Row(id: rows.count, cells: cells))
            index += cells.count
            beat += 1
        }
        return rows
    }
    /// Whether a title has a picture that suits a wide card.
    static func landscape(_ item: JellyfinClient.Item) -> Bool {
        !(item.BackdropImageTags ?? []).isEmpty || item.ImageTags?["Thumb"] != nil || ["Episode", "Video", "MusicVideo"].contains(item.kind)
    }
}

/// One item: a folder, show or season opens; anything playable plays. Its poster, name and line,
/// with your progress as a thin bar and a tick once watched.
struct JellyTile: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    /// How many lines the name may take under the poster (two where names get cut short).
    var titleLines = 1
    /// A landscape card (16:9: the backdrop, an episode's still or a video's frame) instead of a poster.
    var wide = false
    /// The app's own home poster (as the diary's rows draw it): rounder corners, a 14-point name on
    /// two lines kept for every card so a row's cards line up.
    var home = false
    /// On the Canvas: just the picture, filling the frame it's given (a poster, or a wide or
    /// full-width card with the title's logo or name on it).
    var canvas: JellyCanvasShape? = nil
    @State private var played: Bool?
    @State private var favourite: Bool?
    @State private var photo: JellyPhotoSelection?
    @AppStorage(JellyPrefs.countsKey) private var counts = true
    @AppStorage(JellyPrefs.ticksKey) private var ticks = true
    @AppStorage(JellyPrefs.captionsKey) private var captions = true
    private var square: Bool { ["MusicAlbum", "MusicArtist", "Audio", "Playlist"].contains(item.kind) }
    /// Small corners without names (the Netflix look); the app's own otherwise.
    private var corner: CGFloat { captions ? (home ? 16 : 8) : 5 }
    var body: some View {
        link.modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite,
                                    play: item.kind == "Movie" ? { playing = JellySpace.playback(item, client: client) } : nil))
            .fullScreenCover(item: $photo) { _ in JellyPhotoViewer(photos: [item], client: client, start: 0) }
    }
    @ViewBuilder private var link: some View {
        if item.kind == "Audio" {
            Button { JellyMusic.shared.play([item], from: 0) } label: { face }
                .buttonStyle(.springPress).accessibilityLabel("Play " + (item.Name ?? "song")).accessibilityIdentifier("jellyspace-song-" + item.Id)
        } else if item.kind == "Photo" {
            Button { photo = JellyPhotoSelection(index: 0) } label: { face }
                .buttonStyle(.springPress).accessibilityLabel(item.Name ?? "Photo").accessibilityIdentifier("jellyspace-photo-" + item.Id)
        } else if item.kind == "MusicArtist" {
            NavigationLink(value: JellyListRoute(kind: .artist, id: item.Id, name: item.Name ?? "Artist")) { face }
                .buttonStyle(.springPress).accessibilityIdentifier("jellyspace-artist-" + item.Id)
        } else if item.kind == "Movie" || item.kind == "Series" {
            NavigationLink(value: JellyDetailRoute(id: item.Id, name: item.Name ?? "")) { face }
                .buttonStyle(.springPress).accessibilityIdentifier("jellyspace-title-" + item.Id)
        } else if JellySpace.opens(item) {
            NavigationLink(value: JellyFolderRoute(id: item.Id, name: item.Name ?? "Folder", kind: item.kind)) { face }
                .buttonStyle(.springPress).accessibilityIdentifier("jellyspace-folder-" + item.Id)
        } else {
            Button { playing = JellySpace.playback(item, client: client) } label: { face }
                .buttonStyle(.springPress).accessibilityLabel("Play " + JellySpace.name(item)).accessibilityIdentifier("jellyspace-item-" + item.Id)
        }
    }
    @ViewBuilder private var face: some View {
        if let canvas { canvasFace(canvas) } else { cardFace }
    }
    private func canvasFace(_ shape: JellyCanvasShape) -> some View {
        Color.clear
            .overlay {
                let fallback = Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
                if let url = shape == .poster ? JellySpace.poster(item, base: client.base) : JellySpace.canvasImage(item, base: client.base) {
                    JellyfinPoster(url: url) { fallback }
                } else { fallback }
            }
            .overlay(alignment: .bottomLeading) {
                if shape != .poster {
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.7), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                        if let logo = item.ImageTags?["Logo"] {
                            JellyImage(url: JellyfinClient.imageURL(base: client.base, item: item.Id, type: "Logo", tag: logo, width: 600), mode: .fit)
                                .frame(maxWidth: shape == .full ? 240 : 160, maxHeight: shape == .full ? 84 : 60, alignment: .bottomLeading)
                                .padding(16)
                        } else {
                            Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : JellyNames.title(item))
                                .font(.system(size: shape == .full ? 28 : 22, weight: .bold)).tracking(-0.3).foregroundStyle(.white)
                                .lineLimit(2).multilineTextAlignment(.leading).shadow(color: .black.opacity(0.4), radius: 6).padding(16)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
            .overlay(alignment: .topTrailing) { cornerBadge }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomeStyle.outline(0.08), lineWidth: HomeStyle.hairline))
            .contentShape(Rectangle())
            .accessibilityLabel(JellySpace.name(item))
    }
    /// New episodes, the unwatched count, or the watched tick, on the top corner.
    @ViewBuilder private var cornerBadge: some View {
        if played != true, let fresh = JellyNewEpisodes.count(item) {
            Text("\(fresh) new").font(.system(size: 11, weight: .bold)).foregroundStyle(ThemeStore.current.accentInk)
                .padding(.horizontal, 7).frame(minHeight: 22).background(ThemeStore.accent, in: Capsule()).padding(5)
                .accessibilityLabel("\(fresh) new episodes")
        } else if counts, item.kind == "Series", played != true, let left = item.UserData?.UnplayedItemCount, left > 0 {
            Text("\(left)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 5).frame(minWidth: 22, minHeight: 22).background(ThemeStore.accent, in: Capsule()).padding(5)
        } else if ticks { JellyWatchedMark(item: item, played: played) }
    }
    private var cardFace: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Jellyfin's own posters come from its home-network address, which the public artwork
            // loader refuses (it takes TMDB's and AniList's only): JellyfinPoster loads and keeps them.
            Color.clear.aspectRatio(square ? 1 : wide ? 16 / 9 : 2 / 3, contentMode: .fit)
                .overlay {
                    let fallback = ZStack {
                        Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
                        if item.IsFolder == true && item.kind != "Series" && item.kind != "Season" {
                            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(HomeStyle.chipText)
                        }
                    }
                    if let url = wide && !square ? JellySpace.wideImage(item, base: client.base) : JellySpace.poster(item, base: client.base) {
                        JellyfinPoster(url: url) { fallback }
                    } else { fallback }
                }
                .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
                .overlay(alignment: .topTrailing) { cornerBadge }
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .overlay { if home { RoundedRectangle(cornerRadius: corner).strokeBorder(HomeStyle.outline(0.08), lineWidth: HomeStyle.hairline) } }
            if captions {
                Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? ""))
                    .font(.system(size: home ? 14 : 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    .lineLimit(home ? 2 : titleLines, reservesSpace: home).multilineTextAlignment(.leading).padding(.top, home ? 9 : 8)
                Text(JellySpace.detail(item)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, home ? 4 : 2)
            }
        }.contentShape(Rectangle())
    }
}

/// One of search's Recommended for you: the wide picture (your progress along its foot), the name,
/// "Film · 2022", and a play circle (a film from where you stopped, a show's next episode). The rest
/// of the row opens the title's page.
private struct JellySuggestionRow: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    @State private var played: Bool?
    @State private var favourite: Bool?
    @State private var starting = false

    private var line: String {
        let kind = item.kind == "Movie" ? "Film" : "Series"
        let started = item.kind == "Movie" && (item.UserData?.PlayedPercentage ?? 0) > 0
        return ([kind, item.ProductionYear.map(String.init)].compactMap { $0 } + (started ? ["Resume"] : [])).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: JellyDetailRoute(id: item.Id, name: item.Name ?? "")) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 128, height: 72)
                        .overlay {
                            ZStack {
                                Rectangle().fill(HomeStyle.card)
                                JellyImage(url: JellySpace.wideImage(item, base: client.base))
                            }
                        }
                        .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.Name ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                        Text(line).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.springPress).accessibilityIdentifier("jellyspace-suggestion-" + item.Id)
            Button { Task { await play() } } label: {
                ZStack {
                    Circle().strokeBorder(HomeStyle.primary, lineWidth: 2)
                    if starting { ProgressView().controlSize(.small) } else {
                        Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(HomeStyle.primary).offset(x: 1)
                    }
                }.frame(width: 38, height: 38).contentShape(Circle())
            }
            .buttonStyle(.springPress).disabled(starting)
            .accessibilityLabel("Play " + (item.Name ?? "")).accessibilityIdentifier("jellyspace-suggestion-play-" + item.Id)
        }
        .modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite, play: nil))
    }

    /// A film plays from where you stopped; a show plays its next episode (its first if not started).
    private func play() async {
        if item.kind != "Series" {
            playing = JellySpace.playback(item, client: client)
            return
        }
        starting = true
        defer { starting = false }
        guard let user = await JellyfinUser.id(client), let next = try? await client.nextUp(series: item.Id, user: user) else { return }
        playing = JellySpace.playback(next, client: client)
    }
}

/// A season's episode: its still (a ✓ on it once watched, your progress along its foot), "3. Name"
/// on up to two lines, and the length with "Watched" or when it aired. The next one to watch sits on
/// a light card with Up next, a play sign and two lines of its story.
struct JellyEpisodeRow: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    var upNext = false
    @State private var played: Bool?
    @State private var favourite: Bool?
    @Environment(DiaryStore.self) private var store
    @AppStorage(JellyPrefs.diaryKey) private var diaryOn = true
    var body: some View {
        row.modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite, play: nil))
    }
    private var watched: Bool { played ?? (item.UserData?.Played == true) }
    /// Netflix's way: the still with a play sign (the red line as far as you've watched), the name and
    /// length beside it, the watched tick at the right, and the story under it all.
    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button { playing = JellySpace.playback(item, client: client) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        still
                        VStack(alignment: .leading, spacing: 3) {
                            Text([item.IndexNumber.map { "\($0)." }, item.Name].compactMap { $0 }.joined(separator: " "))
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            if !meta.isEmpty { Text(meta).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.springPress).accessibilityLabel("Play " + JellySpace.name(item))
                .accessibilityIdentifier("jellyspace-episode-" + item.Id)
                // Watched: a tap marks it watched or not, in Jellyfin.
                Button { toggleWatched() } label: {
                    Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(watched ? Color(themed: "#3fbf6f") : HomeStyle.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.springPress).sensoryFeedback(.selection, trigger: watched)
                .accessibilityLabel(watched ? "Mark unwatched" : "Mark watched")
                .accessibilityIdentifier("jellyspace-episode-watched-" + item.Id)
            }
            if let overview = item.Overview.map(JellySpace.plainText), !overview.isEmpty {
                Text(overview).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }
    private func toggleWatched() {
        let now = !watched
        withAnimation(.snappy(duration: 0.2)) { played = now }
        let id = item.Id
        Task {
            guard let user = await JellyfinUser.id(client) else { return }
            do { try await client.setPlayed(id, user: user, now) } catch { played = !now }
        }
        // Watched: in the diary too, as the long-press menu and finishing it in the player do.
        if now, diaryOn {
            let episode = item
            Task { _ = await JellyDiary.mark(episode, client: client, store: store) }
        }
    }
    private var still: some View {
        Color.clear.frame(width: 130, height: 73)
            .overlay {
                let fallback = Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
                if let url = JellyfinClient.posterURL(base: client.base, item: item.Id, tag: item.ImageTags?["Primary"]) ?? JellySpace.poster(item, base: client.base) {
                    JellyfinPoster(url: url) { fallback }
                } else { fallback }
            }
            .overlay {
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            }
            .overlay(alignment: .bottomLeading) {
                // Red as far as you've watched (all the way once it's watched).
                let done = watched ? 1 : (item.UserData?.PlayedPercentage ?? 0) / 100
                if done > 0 {
                    GeometryReader { proxy in
                        Rectangle().fill(Color(red: 0.9, green: 0.04, blue: 0.08)).frame(width: proxy.size.width * min(1, done), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    /// "52m", "52m · 31m left" once started, "49m · 28 Nov 2026" for one you haven't.
    private var meta: String {
        var parts: [String] = []
        let minutes = item.RunTimeTicks.map { Int($0 / 600_000_000) } ?? 0
        if minutes > 0 { parts.append(DiaryDate.duration(minutes)) }
        if !watched, let percent = item.UserData?.PlayedPercentage, percent > 0, minutes > 0 {
            parts.append(DiaryDate.duration(max(1, Int(Double(minutes) * (1 - percent / 100)))) + " left")
        } else if !watched, let aired = Self.aired(item.PremiereDate) {
            parts.append(aired)
        }
        return parts.joined(separator: " · ")
    }
    /// "11 Oct 2024". Jellyfin keeps an air date as the server's local midnight in UTC
    /// ("2024-10-10T18:30:00Z" for 11 October in India), so it's read as a moment and shown in the
    /// phone's own time zone, not cut to its first ten characters.
    static func aired(_ text: String?) -> String? {
        guard let text, text.count >= 19 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: String(text.prefix(19))) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// How far into it you are, as a thin bar along the bottom (nothing when unstarted or watched).
struct JellyProgress: View {
    let item: JellyfinClient.Item
    var played: Bool? = nil
    var body: some View {
        if let percent = item.UserData?.PlayedPercentage, percent > 0, !(played ?? (item.UserData?.Played == true)) {
            GeometryReader { proxy in
                Rectangle().fill(.black.opacity(0.55))
                    .overlay(alignment: .leading) { Rectangle().fill(ThemeStore.accent).frame(width: proxy.size.width * min(1, percent / 100)) }
            }.frame(height: 4)
        }
    }
}

struct JellyWatchedMark: View {
    let item: JellyfinClient.Item
    var played: Bool? = nil
    var body: some View {
        if played ?? (item.UserData?.Played == true), item.IsFolder != true {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(.black.opacity(0.65), in: Circle()).padding(6)
        }
    }
}

/// Continue watching and Next up: a wide card (the episode's still or the film's backdrop) that plays at once.
struct JellyWideCard: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    /// A show's next episode (not one you've started): tagged Next up.
    var nextUp = false
    /// Continue Watching's big card: a play circle on the picture, rounder corners, a larger title.
    var large = false
    /// Just the picture and the progress bar, smaller corners (Continue Watching with Titles off).
    var pictureOnly = false
    var onRemove: (() -> Void)? = nil
    @State private var played: Bool?
    @State private var favourite: Bool?
    var body: some View {
        Button { playing = JellySpace.playback(item, client: client) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        ZStack {
                            Rectangle().fill(HomeStyle.card)
                            JellyImage(url: JellySpace.wideImage(item, base: client.base))
                        }
                    }
                    .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
                    .overlay(alignment: .topTrailing) { JellyWatchedMark(item: item, played: played) }
                    .overlay(alignment: .topLeading) {
                        if nextUp {
                            Text("NEXT UP").font(.system(size: 10, weight: .bold)).tracking(0.3).foregroundStyle(.white)
                                .padding(.horizontal, 7).frame(height: 20).background(.black.opacity(0.6), in: Capsule()).padding(large ? 10 : 7)
                        }
                    }
                    .overlay {
                        if large {
                            let circle: CGFloat = pictureOnly ? 40 : 58
                            Image(systemName: "play.fill").font(.system(size: pictureOnly ? 16 : 22, weight: .bold)).foregroundStyle(.white).offset(x: 2)
                                .frame(width: circle, height: circle).background(.black.opacity(0.28), in: Circle())
                                .overlay(Circle().strokeBorder(.white, lineWidth: pictureOnly ? 2 : 3)).shadow(color: .black.opacity(0.3), radius: 8)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: pictureOnly ? 5 : large ? 16 : 8))
                if !pictureOnly {
                    Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? ""))
                        .font(.system(size: large ? 16 : 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, large ? 10 : 8)
                    Text(large ? JellySpace.cardLine(item) : nextUp || (item.UserData?.PlayedPercentage ?? 0) > 0 ? JellySpace.continueLine(item) : JellySpace.detail(item))
                        .font(.system(size: large ? 13 : 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, large ? 3 : 2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.springPress).accessibilityLabel("Play " + JellySpace.name(item))
        .modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite, play: nil, remove: onRemove))
    }
}

/// A long press on a poster or row: play (a film), watched or unwatched, favourite, and an episode's show.
struct JellyItemMenu: ViewModifier {
    let item: JellyfinClient.Item
    @Binding var played: Bool?
    @Binding var favourite: Bool?
    let play: (() -> Void)?
    var remove: (() -> Void)? = nil
    @Environment(AppRouter.self) private var router
    @Environment(DiaryStore.self) private var store
    @AppStorage(JellyPrefs.diaryKey) private var diaryOn = true
    @State private var confirmDelete = false
    @State private var deleteFailure: String?
    @ViewBuilder func body(content: Content) -> some View {
        if JellyServerEdits.shared.isDeleted(item) {
            // Deleted from the server here: gone from every row at once.
            EmptyView()
        } else if ["CollectionFolder", "Photo", "PhotoAlbum"].contains(item.kind) {
            content
        } else {
            content.contextMenu {
                if let play { Button("Play", systemImage: "play.fill", action: play) }
                let isPlayed = played ?? (item.UserData?.Played == true)
                Button(isPlayed ? "Mark as unwatched" : "Mark as watched", systemImage: isPlayed ? "eye.slash" : "checkmark.circle") {
                    played = !isPlayed
                    let id = item.Id, now = !isPlayed, watched = item
                    let toDiary = now && diaryOn && ["Movie", "Episode"].contains(item.kind)
                    send({ client, user in try await client.setPlayed(id, user: user, now) }, done: {
                        // Watched: in the diary too (as finishing it in the player does), once Jellyfin has it.
                        if toDiary, let client = JellySpace.client { Task { _ = await JellyDiary.mark(watched, client: client, store: store) } }
                    }, undo: { played = isPlayed })
                }
                if let remove { Button("Remove from Continue Watching", systemImage: "minus.circle", action: remove) }
                let isFavourite = favourite ?? (item.UserData?.IsFavorite == true)
                Button(isFavourite ? "Remove from favourites" : "Add to favourites", systemImage: isFavourite ? "heart.slash" : "heart") {
                    favourite = !isFavourite
                    let id = item.Id, now = !isFavourite
                    send({ client, user in try await client.setFavourite(id, user: user, now) }, undo: { favourite = isFavourite })
                }
                if item.kind == "Episode", let series = item.SeriesId {
                    Button("Go to show", systemImage: "tv") {
                        router.paths[router.selectedTab, default: NavigationPath()].append(JellyDetailRoute(id: series, name: item.SeriesName ?? ""))
                    }
                }
                if JellyDiaryLink.offers(item) {
                    Button("View in Diary", systemImage: "book") { openDiary() }
                }
                if ["Movie", "Episode", "Video"].contains(item.kind), let url = JellySpace.client?.streamURL(item.Id) {
                    Button("Open in Infuse", systemImage: "arrow.up.forward.app") { JellySpace.open(url, in: "Infuse") }
                }
                Button("Hide", systemImage: "eye.slash") { JellyHidden.hide(item.Id, name: item.Name ?? "Item") }
                if JellyServerEdits.shared.canDelete, JellyServerEdits.deletable(item) {
                    Divider()
                    Button("Delete from server", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            .alert("Delete “\(JellySpace.name(item))”?", isPresented: $confirmDelete) {
                Button("Delete from server", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(JellyServerEdits.warning(kind: item.kind)) }
            .alert("Couldn't delete", isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(deleteFailure ?? "") }
        }
    }
    /// View in Diary: the film's or show's page in the diary (an episode's or season's show's).
    private func openDiary() {
        let item = item, tab = router.selectedTab
        Task {
            guard let client = JellySpace.client, let route = await JellyDiaryLink.route(for: item, client: client) else { return }
            router.paths[tab, default: NavigationPath()].append(route)
        }
    }
    /// Deletes it from the server; it leaves the rows once the server says it's done.
    private func delete() {
        let id = item.Id
        Task {
            guard let client = JellySpace.client else { return }
            do {
                try await client.delete(id)
                withAnimation(.smooth) { _ = JellyServerEdits.shared.deleted.insert(id) }
            } catch {
                deleteFailure = error.localizedDescription
            }
        }
    }
    /// Sends a change to Jellyfin; if it's refused (or there's no server or user), the tick or heart
    /// shown goes back, so it never looks saved when it isn't.
    private func send(_ change: @escaping @Sendable (JellyfinClient, String) async throws -> Void,
                      done: @escaping @MainActor () -> Void = {}, undo: @escaping @MainActor () -> Void) {
        Task {
            guard let client = JellySpace.client, let user = await JellyfinUser.id(client) else { undo(); return }
            do {
                try await change(client, user)
                done()
            } catch {
                withAnimation(.snappy(duration: 0.2)) { undo() }
            }
        }
    }
}

/// The ••• menu over a folder or list: Sort (name, date added, year, rating) and Unwatched only.
/// How a library or folder is browsed: Library, everything in it on one page however deep its
/// folders go (the default); Folder, one level at a time as the folders are on disk; or its Genres
/// or Studios as tiles, each opening its titles in this library.
enum JellyBrowse: String, CaseIterable {
    case library, folder, genres, studios
    var title: String {
        switch self {
        case .library: "Library"
        case .folder: "Folder"
        case .genres: "Genres"
        case .studios: "Studios"
        }
    }
    var symbol: String {
        switch self {
        case .library: "square.stack"
        case .folder: "folder"
        case .genres: "theatermasks"
        case .studios: "building.2"
        }
    }
    /// Library and Folder list titles (so they sort and filter); Genres and Studios list tiles.
    var listsTitles: Bool { self == .library || self == .folder }
}

/// How a library, folder or list lays its titles out: posters three across, landscape cards two
/// across, or Canvas (a mosaic of posters, wide and full-width cards, each title in the shape its
/// pictures suit). Remembered for each one.
enum JellyGridLayout: String, CaseIterable {
    case posters, landscape, canvas
    var title: String {
        switch self {
        case .posters: "Posters"
        case .landscape: "Landscape"
        case .canvas: "Canvas"
        }
    }
    var symbol: String {
        switch self {
        case .posters: "rectangle.portrait"
        case .landscape: "rectangle"
        case .canvas: "square.grid.3x3.square"
        }
    }
}

@MainActor enum JellyLayout {
    /// The first version kept only Landscape on or off, under this key.
    static func key(_ section: String) -> String { "jellyspace.layout." + section }
    static func modeKey(_ section: String) -> String { "jellyspace.layoutMode." + section }
    static func browseKey(_ section: String) -> String { "jellyspace.browse." + section }
    /// A section's layout setting, starting from its old Landscape switch.
    static func storage(_ section: String) -> AppStorage<JellyGridLayout> {
        AppStorage(wrappedValue: UserDefaults.standard.bool(forKey: key(section)) ? .landscape : .posters, modeKey(section))
    }
}

/// What JellySpace's pages share: the client, posters, names and which items open or play.
@MainActor enum JellySpace {
    static var client: JellyfinClient? {
        // A user you signed in as (Settings → JellySpace) stands in for the server's API key. Both
        // are read from the Keychain once and kept (pages ask for the client on every redraw).
        guard let base = JellyfinSettings.address else { return nil }
        if keyCache == nil { keyCache = .some(JellyAccount.token ?? JellyfinSettings.apiKey) }
        guard let key = keyCache ?? nil else { return nil }
        return JellyfinClient(base: base, key: key)
    }
    private static var keyCache: String??
    /// After the key changes: a new server key, a sign-in, a sign-out.
    static func resetKey() { keyCache = nil }
    /// Jellyseerr, when its address and key are set (Settings → JellySpace).
    static var seerr: JellySeerr? {
        guard let text = UserDefaults.standard.string(forKey: JellyPrefs.seerrAddressKey), let base = JellyfinSettings.normalized(text),
              let key = JellySecrets.read("seerr-key"), !key.isEmpty else { return nil }
        return JellySeerr(base: base, key: key)
    }
    /// The player a video can be handed to: Infuse, which opens the stream by its link.
    static let otherPlayers = ["Infuse"]
    static func open(_ url: URL, in app: String) {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let target = URL(string: "infuse://x-callback-url/play?url=" + encoded) { UIApplication.shared.open(target) }
    }
    /// Folders, shows and seasons open; films, episodes and videos play.
    static func opens(_ item: JellyfinClient.Item) -> Bool { item.IsFolder == true || ["Folder", "CollectionFolder", "Series", "Season", "BoxSet"].contains(item.kind) }
    static func playback(_ item: JellyfinClient.Item, client: JellyfinClient, source: String? = nil) -> JellyPlayback? {
        guard let url = client.streamURL(item.Id, source: source) else { return nil }
        return JellyPlayback(id: item.Id, url: url, title: name(item), item: item, client: client, source: source)
    }
    /// An episode by its show's poster; anything else by its own.
    static func poster(_ item: JellyfinClient.Item, base: URL) -> URL? {
        if item.kind == "Episode", let series = item.SeriesId, let tag = item.SeriesPrimaryImageTag { return JellyfinClient.posterURL(base: base, item: series, tag: tag) }
        return JellyfinClient.posterURL(base: base, item: item.Id, tag: item.ImageTags?["Primary"])
    }
    static func wideImage(_ item: JellyfinClient.Item, base: URL) -> URL? {
        if item.kind == "Episode", let still = item.ImageTags?["Primary"] {
            return JellyfinClient.imageURL(base: base, item: item.Id, type: "Primary", tag: still)
        }
        if let tag = item.BackdropImageTags?.first { return JellyfinClient.imageURL(base: base, item: item.Id, type: "Backdrop", tag: tag) }
        if let parent = item.ParentBackdropItemId, let tag = item.ParentBackdropImageTags?.first {
            return JellyfinClient.imageURL(base: base, item: parent, type: "Backdrop", tag: tag)
        }
        return poster(item, base: base)
    }
    /// "S1 E4 · Name" for an episode, the year for a film, what a folder is.
    static func detail(_ item: JellyfinClient.Item) -> String {
        if item.kind == "Video", let path = item.Path, !path.isEmpty {
            return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        }
        switch item.kind {
        case "Episode":
            let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: ":")
            return [place.isEmpty ? nil : place, item.Name].compactMap { $0 }.joined(separator: " - ")
        case "Series": return item.ProductionYear.map(String.init) ?? "Show"
        case "Season": return "Season"
        case "Movie": return item.ProductionYear.map(String.init) ?? "Movie"
        case "PhotoAlbum": return "Album"
        case "MusicAlbum": return item.AlbumArtist ?? item.ProductionYear.map(String.init) ?? "Album"
        case "MusicArtist": return "Artist"
        case "Audio": return JellyMusic.artist(item) ?? "Song"
        default: return item.IsFolder == true ? "Folder" : (item.ProductionYear.map(String.init) ?? "Video")
        }
    }
    static func name(_ item: JellyfinClient.Item) -> String {
        guard item.kind == "Episode", let show = item.SeriesName else { return JellyNames.title(item) }
        return show + " · " + detail(item)
    }
    /// Jellyfin's overviews carry HTML (<br>, <i>): shown as plain text.
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Continue Watching's big card: an episode's "S1 · E2 - Name", a film's "2023 · 1h 2m left".
    static func cardLine(_ item: JellyfinClient.Item) -> String {
        if item.kind == "Episode" {
            let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " · ")
            return [place.isEmpty ? nil : place, item.Name].compactMap { $0 }.joined(separator: " - ")
        }
        return continueLine(item)
    }
    /// "S2:E5 · 14m left", a film's "2023 · 1h 2m left": a Continue Watching card's line.
    static func continueLine(_ item: JellyfinClient.Item) -> String {
        var parts: [String] = []
        if item.kind == "Episode" {
            let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: ":")
            if !place.isEmpty { parts.append(place) }
        } else if let year = item.ProductionYear {
            parts.append(String(year))
        }
        if let percent = item.UserData?.PlayedPercentage, percent > 0, let ticks = item.RunTimeTicks, ticks > 0 {
            parts.append(DiaryDate.duration(max(1, Int(Double(ticks) / 600_000_000 * (1 - percent / 100)))) + " left")
        }
        return parts.joined(separator: " · ")
    }
    /// A wide card's picture: the backdrop, else Jellyfin's landscape "Thumb" art, else a wide frame.
    static func canvasImage(_ item: JellyfinClient.Item, base: URL) -> URL? {
        if let tag = item.BackdropImageTags?.first { return JellyfinClient.imageURL(base: base, item: item.Id, type: "Backdrop", tag: tag) }
        if let thumb = item.ImageTags?["Thumb"] { return JellyfinClient.imageURL(base: base, item: item.Id, type: "Thumb", tag: thumb) }
        return wideImage(item, base: base)
    }
    static func symbol(_ libraryType: String?) -> String {
        switch libraryType {
        case "movies": "film"
        case "tvshows": "tv"
        case "homevideos": "video"
        case "photos": "photo.on.rectangle"
        case "music": "music.note"
        case "musicvideos": "music.note.tv"
        default: "folder"
        }
    }
}
