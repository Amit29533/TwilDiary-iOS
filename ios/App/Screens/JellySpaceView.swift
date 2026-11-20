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
}

/// JellySpace: your Jellyfin server, played by AetherEngine straight from the file (Jellyfin's static
/// stream, nothing converted). Continue watching, Next up, your libraries and what's newest; a search
/// over every film and episode; any library or folder opens in JellyFolderPage. Opens from the
/// TwilDiary logo on Home. The player is JellyPlayerView.
struct JellySpaceView: View {
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    @AppStorage(JellyPrefs.rowsKey) private var rowsRaw = ""
    @AppStorage(JellyPrefs.hiddenRowsKey) private var hiddenRowsRaw = ""
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @State private var seerrResults: [JellySeerr.Result] = []
    @State private var requested: Set<Int> = []
    @State private var requestNotice: String?
    @State private var results: [JellyfinClient.Item] = []
    @State private var resume: [JellyfinClient.Item] = []
    @State private var libraries: [JellyfinLibrary] = []
    @State private var latest: [String: [JellyfinClient.Item]] = [:]
    @State private var favourites: [JellyfinClient.Item] = []
    @State private var collections: [JellyfinClient.Item] = []
    @State private var query = ""
    @State private var searching = false
    @State private var searchRunning = false
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var playing: JellyPlayback?

    /// Explore's layout: the big poster at the top (the newest films and shows), then the shelves
    /// at Explore's sizes.
    var body: some View {
        // Searching with something typed: the results start under the top bar and the search field.
        let showsResults = searching && !query.isEmpty
        EdgeToEdgeScroll(artworkUnderBar: !showsResults) {
            VStack(alignment: .leading, spacing: 22) {
                if let client = JellySpace.client {
                    let picks = showsResults || JellyHomeRow.hidden(hiddenRowsRaw).contains(.hero) ? [] : heroPicks
                    if !picks.isEmpty { JellyHeroCarousel(items: picks, client: client) }
                    VStack(alignment: .leading, spacing: 22) {
                        if let failure { RetryNotice(message: failure) { Task { await loadHome() } } }
                        if showsResults {
                            if results.isEmpty && !searchRunning { Text("Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary) }
                            JellyGrid(items: shown(results), client: client, playing: $playing)
                            if !seerrResults.isEmpty { requestSection }
                        } else if loading && !loaded {
                            DiaryLoadingPlaceholder(label: "Loading Jellyfin", layout: .posterShelf)
                        } else {
                            // Your order and choice of rows (Settings → JellySpace).
                            let off = JellyHomeRow.hidden(hiddenRowsRaw)
                            ForEach(JellyHomeRow.order(rowsRaw).filter { !off.contains($0) }) { row in homeRow(row, client: client) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, showsResults ? 64 : picks.isEmpty ? 72 : 0)
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
    /// Without what you hid (a film, a show, or an episode of a hidden show).
    private func shown(_ items: [JellyfinClient.Item]) -> [JellyfinClient.Item] {
        let hidden = hidden
        return items.filter { hidden[$0.Id] == nil && ($0.SeriesId.map { hidden[$0] == nil } ?? true) }
    }

    @ViewBuilder private func homeRow(_ row: JellyHomeRow, client: JellyfinClient) -> some View {
        switch row {
        case .hero: EmptyView()
        case .media: if !visibleLibraries.isEmpty { myMedia(client) }
        case .resume:
            let items = shown(resume)
            if !items.isEmpty { wideRow("Continue Watching", items: items, client: client) }
        case .favourites:
            let items = shown(favourites)
            if !items.isEmpty { tileRow("Favourites", items: items, client: client, more: JellyListRoute(kind: .favourites, name: "Favourites")) }
        case .libraries:
            ForEach(visibleLibraries) { library in
                let items = shown(latest[library.id] ?? [])
                if !items.isEmpty {
                    tileRow(library.name, items: items, client: client, more: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder", type: library.type))
                }
            }
        case .collections:
            let items = shown(collections)
            if !items.isEmpty { tileRow("Collections", items: items, client: client, more: JellyListRoute(kind: .collections, name: "Collections")) }
        }
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
        let rows = visibleLibraries.compactMap { latest[$0.id].map(shown) }
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
        Text(text).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1).accessibilityAddTraits(.isHeader)
    }

    /// Your libraries: Jellyfin's own picture for each (it carries the name), the name under it.
    private func myMedia(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("My Media")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(visibleLibraries) { library in
                        NavigationLink(value: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder", type: library.type)) {
                            VStack(spacing: 6) {
                                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                                    .overlay {
                                        ZStack {
                                            Rectangle().fill(HomeStyle.card)
                                            Image(systemName: JellySpace.symbol(library.type)).font(.system(size: 20)).foregroundStyle(HomeStyle.secondary)
                                            JellyImage(url: JellyfinClient.imageURL(base: client.base, item: library.id, type: "Primary", tag: nil))
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(library.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.springPress).accessibilityLabel(library.name).accessibilityIdentifier("jellyspace-library-" + library.id)
                        .contextMenu { Button("Hide library", systemImage: "eye.slash") { JellyHidden.hide(library.id, name: library.name) } }
                        // Two and a half across, so the next one peeks in.
                        .containerRelativeFrame(.horizontal, count: 5, span: 2, spacing: 12)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    /// Continue Watching: wide cards (the episode's still or the film's backdrop) that play at once.
    private func wideRow(_ title: String, items: [JellyfinClient.Item], client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.Id) { item in
                        JellyWideCard(item: item, client: client, playing: $playing, onRemove: title == "Continue Watching" ? { removeFromResume(item) } : nil)
                            .containerRelativeFrame(.horizontal, count: max(2, posterSize.columns - 1), spacing: 12)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    /// A row of posters (a library's newest, your favourites, collections), as Explore's shelves.
    private func tileRow<Route: Hashable>(_ title: String, items: [JellyfinClient.Item], client: JellyfinClient, more: Route) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                heading(title)
                Spacer(minLength: 0)
                SectionMoreLink(label: "View more " + title, value: more, identifier: "jellyspace-more-" + title)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.Id) { item in
                        JellyTile(item: item, client: client, playing: $playing)
                            .containerRelativeFrame(.horizontal, count: posterSize.columns, spacing: 12)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
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
            collections = JellyHomeCache.collections; latest = JellyHomeCache.latest; loaded = true
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
        async let started = client.resume(user: user)
        async let liked = client.items([URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode")], filters: ["IsFavorite"], user: user, sort: .added, limit: 20)
        async let sets = client.items([URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")], user: user, limit: 20)
        resume = (try? await started) ?? []
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
        JellyHomeCache.server = client.base.absoluteString + "|" + user; JellyHomeCache.at = .now
        JellyHomeCache.libraries = libraries; JellyHomeCache.resume = resume; JellyHomeCache.favourites = favourites
        JellyHomeCache.collections = collections; JellyHomeCache.latest = latest
    }
}

/// JellySpace's top poster, as Explore's: the newest films and shows, a new one every five seconds
/// while it's on screen, swipeable; a tap opens its page.
private struct JellyHeroCarousel: View {
    let items: [JellyfinClient.Item]
    let client: JellyfinClient
    @State private var selected: String?
    @State private var shown = false
    @State private var scrolledInto = true
    @State private var swiping = false

    var body: some View {
        let current = items.firstIndex { $0.Id == selected } ?? 0
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items, id: \.Id) { item in
                    JellyHero(item: item, client: client).containerRelativeFrame(.horizontal).id(item.Id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $selected)
        .onScrollPhaseChange { _, phase in swiping = phase == .interacting || phase == .decelerating }
        .haptic(.selection, trigger: selected) { _, _ in swiping }
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { position in
                        Capsule().fill(.white.opacity(position == current ? 0.95 : 0.35))
                            .frame(width: position == current ? 14 : 5, height: 5)
                    }
                }
                .animation(.snappy(duration: 0.25), value: current)
                .padding(.trailing, 18).padding(.bottom, 16)
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

/// One top poster: the backdrop, the title's logo (or its name), the year, film or show, and rating.
private struct JellyHero: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var height: CGFloat = 340

    private var facts: String {
        [item.ProductionYear.map(String.init), item.kind == "Series" ? "Show" : "Movie"].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        NavigationLink(value: JellyDetailRoute(id: item.Id, name: item.Name ?? "")) {
            VStack(alignment: .leading, spacing: 8) {
                if let logo = item.ImageTags?["Logo"] {
                    JellyImage(url: JellyfinClient.imageURL(base: client.base, item: item.Id, type: "Logo", tag: logo, width: 700), mode: .fit)
                        .frame(maxWidth: 240, maxHeight: 90, alignment: .bottomLeading)
                        .accessibilityLabel(item.Name ?? "")
                } else {
                    Text(item.Name ?? "").font(.largeTitle.bold()).lineLimit(2).minimumScaleFactor(0.6)
                }
                HStack(spacing: 6) {
                    Text(facts)
                    if let score = item.CommunityRating, score > 0 {
                        Text("·")
                        Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Rating")
                        Text(String(format: "%.1f", score))
                    }
                }.font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 70).padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .frame(height: verticalSizeClass == .compact ? 240 : min(height, 520), alignment: .bottomLeading)
            .background {
                Color.clear
                    .overlay { JellyImage(url: item.BackdropImageTags?.first.flatMap { JellyfinClient.imageURL(base: client.base, item: item.Id, type: "Backdrop", tag: $0, width: 1280) }) }
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .clear, location: 0.28),
                            .init(color: .black.opacity(0.70), location: 0.65),
                            .init(color: .black.opacity(0.94), location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .clipped()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityIdentifier("jellyspace-hero-" + item.Id)
    }
}

/// A library, folder, show or season: folders and shows open deeper, a show lists its seasons, a
/// season its episodes, and films, episodes and videos play. Sort and Unwatched sit in the ••• menu.
struct JellyFolderPage: View {
    let route: JellyFolderRoute
    @AppStorage("jellyspace.sort") private var sortRaw = JellyfinClient.Sort.name.rawValue
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @AppStorage("jellyspace.music.view") private var musicView = "Albums"
    @State private var unwatched = false
    @State private var items: [JellyfinClient.Item] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    /// How many the server has, and how many came so far (a big folder loads 200 at a time).
    @State private var total = 0
    @State private var fetched = 0
    @State private var loadingMore = false
    private let pageSize = 200
    private var music: Bool { route.type == "music" }

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
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text("Nothing in here.").font(.subheadline).foregroundStyle(.secondary) }
                    if route.kind == "Season" {
                        LazyVStack(spacing: 8) { ForEach(items, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing) } }
                    } else {
                        // Albums, videos and the rest as posters; photos as a grid of squares, songs as a
                        // list, after them.
                        let photos = items.filter { $0.kind == "Photo" }, songs = items.filter { $0.kind == "Audio" }
                        let rest = items.filter { $0.kind != "Photo" && $0.kind != "Audio" }
                        if !rest.isEmpty { JellyGrid(items: rest, client: client, playing: $playing) { Task { await loadMore() } } }
                        if !photos.isEmpty { JellyPhotoGrid(photos: photos, client: client) { Task { await loadMore() } } }
                        if loadingMore { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8) }
                        if !songs.isEmpty { JellyTrackList(tracks: songs) }
                    }
                }
            }.padding(.horizontal, route.kind == "Season" ? 16 : 10).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar { if sortable { ToolbarItem(placement: .topBarTrailing) { JellySortMenu(sort: $sortRaw, unwatched: $unwatched) } } }
        .safeAreaInset(edge: .bottom) { JellyMiniPlayer().padding(.bottom, 4) }
        .task(id: sortRaw + String(unwatched) + hiddenRaw + musicView) { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    /// Seasons, a show's season list and an album keep their own order.
    private var sortable: Bool { !["Season", "Series", "MusicAlbum"].contains(route.kind) }

    private func load() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let user = await JellyfinUser.id(client)
            let sort = sortable ? JellyfinClient.Sort(rawValue: sortRaw) ?? .name : nil
            if music, musicView != "Folders" {
                // A music library by album or by artist (the whole library, not its folders).
                let found: [JellyfinClient.Item]
                if musicView == "Artists" {
                    found = try await client.artists(in: route.id, user: user)
                } else {
                    found = try await client.items([URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"), URLQueryItem(name: "ParentId", value: route.id)],
                                                   filters: unwatched ? ["IsUnplayed"] : [], user: user, sort: sort ?? .name, limit: 2000)
                }
                total = found.count; fetched = found.count
                items = arrange(found)
                return
            }
            let page = try await client.childrenPage(of: route.id, user: user, sort: sort, unwatched: sortable && unwatched, start: 0, limit: pageSize)
            total = page.TotalRecordCount; fetched = page.Items.count
            items = arrange(page.Items)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
    /// The next 200, when you near the end.
    private func loadMore() async {
        guard !loadingMore, fetched < total, !(music && musicView != "Folders"), let client = JellySpace.client else { return }
        loadingMore = true
        defer { loadingMore = false }
        let user = await JellyfinUser.id(client)
        let sort = sortable ? JellyfinClient.Sort(rawValue: sortRaw) ?? .name : nil
        guard let page = try? await client.childrenPage(of: route.id, user: user, sort: sort, unwatched: sortable && unwatched, start: fetched, limit: pageSize) else { return }
        fetched += page.Items.count
        total = page.TotalRecordCount
        let known = Set(items.map(\.Id))
        items = arrange(items + page.Items.filter { !known.contains($0.Id) })
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
    /// Called as the last poster comes on screen (to load more).
    var reachedEnd: (() -> Void)? = nil
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items, id: \.Id) { item in
                JellyTile(item: item, client: client, playing: $playing)
                    .onAppear { if item.Id == items.last?.Id { reachedEnd?() } }
            }
        }
    }
}

/// One item: a folder, show or season opens; anything playable plays. Its poster, name and line,
/// with your progress as a thin bar and a tick once watched.
struct JellyTile: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    @State private var played: Bool?
    @State private var favourite: Bool?
    @State private var photo: JellyPhotoSelection?
    @AppStorage(JellyPrefs.countsKey) private var counts = true
    @AppStorage(JellyPrefs.ticksKey) private var ticks = true
    @AppStorage(JellyPrefs.captionsKey) private var captions = true
    private var square: Bool { ["MusicAlbum", "MusicArtist", "Audio", "Playlist"].contains(item.kind) }
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
    private var face: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Jellyfin's own posters come from its home-network address, which the public artwork
            // loader refuses (it takes TMDB's and AniList's only): JellyfinPoster loads and keeps them.
            Color.clear.aspectRatio(square ? 1 : 2 / 3, contentMode: .fit)
                .overlay {
                    let fallback = ZStack {
                        Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
                        if item.IsFolder == true && item.kind != "Series" && item.kind != "Season" {
                            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(HomeStyle.chipText)
                        }
                    }
                    if let url = JellySpace.poster(item, base: client.base) { JellyfinPoster(url: url) { fallback } } else { fallback }
                }
                .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
                .overlay(alignment: .topTrailing) {
                    if counts, item.kind == "Series", played != true, let left = item.UserData?.UnplayedItemCount, left > 0 {
                        Text("\(left)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 22, minHeight: 22).background(ThemeStore.accent, in: Capsule()).padding(5)
                    } else if ticks { JellyWatchedMark(item: item, played: played) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if captions {
                Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? "")).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, 8)
                Text(JellySpace.detail(item)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 2)
            }
        }.contentShape(Rectangle())
    }
}

/// A season's episode: its still (or the show's poster), "3 · Name", the length, and your progress.
struct JellyEpisodeRow: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    @State private var played: Bool?
    @State private var favourite: Bool?
    var body: some View {
        row.modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite, play: nil))
    }
    private var row: some View {
        Button { playing = JellySpace.playback(item, client: client) } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 120, height: 68)
                    .overlay {
                        let fallback = Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
                        if let url = JellyfinClient.posterURL(base: client.base, item: item.Id, tag: item.ImageTags?["Primary"]) ?? JellySpace.poster(item, base: client.base) {
                            JellyfinPoster(url: url) { fallback }
                        } else { fallback }
                    }
                    .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text([item.IndexNumber.map(String.init), item.Name].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading)
                    if let minutes = item.RunTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 {
                        Text(DiaryDate.duration(minutes)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    }
                }
                Spacer(minLength: 0)
                if played ?? (item.UserData?.Played == true) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(HomeStyle.chipText)
                } else {
                    Image(systemName: "play.circle").font(.system(size: 22)).foregroundStyle(HomeStyle.secondary)
                }
            }
            if let overview = item.Overview.map(JellySpace.plainText), !overview.isEmpty {
                Text(overview).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(3).multilineTextAlignment(.leading)
            }
          }.padding(10).diaryPanel(padding: 0, radius: 14).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityLabel("Play " + JellySpace.name(item)).accessibilityIdentifier("jellyspace-episode-" + item.Id)
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? ""))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, 8)
                Text(JellySpace.detail(item)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1).padding(.top, 2)
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
    @ViewBuilder func body(content: Content) -> some View {
        if ["CollectionFolder", "Photo", "PhotoAlbum"].contains(item.kind) {
            content
        } else {
            content.contextMenu {
                if let play { Button("Play", systemImage: "play.fill", action: play) }
                let isPlayed = played ?? (item.UserData?.Played == true)
                Button(isPlayed ? "Mark as unwatched" : "Mark as watched", systemImage: isPlayed ? "eye.slash" : "checkmark.circle") {
                    played = !isPlayed
                    let id = item.Id, now = !isPlayed
                    send { client, user in try await client.setPlayed(id, user: user, now) }
                    // Watched: in the diary too (as finishing it in the player does).
                    if now, diaryOn, ["Movie", "Episode"].contains(item.kind), let client = JellySpace.client {
                        let watched = item
                        Task { _ = await JellyDiary.mark(watched, client: client, store: store) }
                    }
                }
                if let remove { Button("Remove from Continue Watching", systemImage: "minus.circle", action: remove) }
                let isFavourite = favourite ?? (item.UserData?.IsFavorite == true)
                Button(isFavourite ? "Remove from favourites" : "Add to favourites", systemImage: isFavourite ? "heart.slash" : "heart") {
                    favourite = !isFavourite
                    let id = item.Id, now = !isFavourite
                    send { client, user in try await client.setFavourite(id, user: user, now) }
                }
                if item.kind == "Episode", let series = item.SeriesId {
                    Button("Go to show", systemImage: "tv") {
                        router.paths[router.selectedTab, default: NavigationPath()].append(JellyDetailRoute(id: series, name: item.SeriesName ?? ""))
                    }
                }
                if ["Movie", "Episode", "Video"].contains(item.kind), let url = JellySpace.client?.streamURL(item.Id) {
                    Menu("Open in", systemImage: "arrow.up.forward.app") {
                        ForEach(JellySpace.otherPlayers, id: \.self) { app in Button(app) { JellySpace.open(url, in: app) } }
                    }
                }
                Button("Hide", systemImage: "eye.slash") { JellyHidden.hide(item.Id, name: item.Name ?? "Item") }
            }
        }
    }
    private func send(_ change: @escaping @Sendable (JellyfinClient, String) async throws -> Void) {
        Task {
            guard let client = JellySpace.client, let user = await JellyfinUser.id(client) else { return }
            try? await change(client, user)
        }
    }
}

/// The ••• menu over a folder or list: Sort (name, date added, year, rating) and Unwatched only.
struct JellySortMenu: View {
    @Binding var sort: String
    @Binding var unwatched: Bool
    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(JellyfinClient.Sort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Toggle("Unwatched only", isOn: $unwatched)
        } label: { TitleMoreButtonLabel() }
            .accessibilityLabel("Sort and filter").accessibilityIdentifier("jellyspace-sort")
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
    /// Players a video can be handed to (each opens the stream by its own link).
    static let otherPlayers = ["Infuse", "VLC", "Outplayer"]
    static func open(_ url: URL, in app: String) {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let link: String
        switch app {
        case "VLC": link = "vlc-x-callback://x-callback-url/stream?url=" + encoded
        case "Outplayer": link = "outplayer://x-callback-url/play?url=" + encoded
        default: link = "infuse://x-callback-url/play?url=" + encoded
        }
        if let target = URL(string: link) { UIApplication.shared.open(target) }
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
        guard item.kind == "Episode", let show = item.SeriesName else { return item.Name ?? "Video" }
        return show + " · " + detail(item)
    }
    /// Jellyfin's overviews carry HTML (<br>, <i>): shown as plain text.
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
