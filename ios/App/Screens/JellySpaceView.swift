import SwiftUI
import TwilDiaryCore

/// A library, folder, show or season to open in JellySpace.
struct JellyFolderRoute: Hashable {
    let id: String
    let name: String
    let kind: String
}

/// JellySpace: your Jellyfin server, played by AetherEngine straight from the file (Jellyfin's static
/// stream, nothing converted). Continue watching, Next up, your libraries and what's newest; a search
/// over every film and episode; any library or folder opens in JellyFolderPage. Opens from the
/// TwilDiary logo on Home. The player is JellyPlayerView.
struct JellySpaceView: View {
    @State private var results: [JellyfinClient.Item] = []
    @State private var resume: [JellyfinClient.Item] = []
    @State private var libraries: [JellyfinLibrary] = []
    @State private var latest: [String: [JellyfinClient.Item]] = [:]
    @State private var favourites: [JellyfinClient.Item] = []
    @State private var collections: [JellyfinClient.Item] = []
    @State private var query = ""
    @State private var searching = false
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var playing: JellyPlayback?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 28) {
                if let client = JellySpace.client {
                    if searching { SearchField(placeholder: "Search Jellyfin", text: $query, label: "Search Jellyfin") }
                    if let failure { RetryNotice(message: failure) { Task { await loadHome() } } }
                    if searching && !query.isEmpty {
                        if results.isEmpty && !loading { Text("Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary) }
                        JellyGrid(items: results, client: client, playing: $playing)
                    } else if loading && !loaded {
                        DiaryLoadingPlaceholder(label: "Loading Jellyfin", layout: .posterShelf)
                    } else {
                        if !libraries.isEmpty { myMedia(client) }
                        if !resume.isEmpty { wideRow("Continue Watching", items: resume, client: client) }
                        if !favourites.isEmpty {
                            tileRow("Favourites", items: favourites, client: client, more: JellyListRoute(kind: .favourites, name: "Favourites"))
                        }
                        ForEach(libraries) { library in
                            if let items = latest[library.id], !items.isEmpty {
                                tileRow(library.name, items: items, client: client, more: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder"))
                            }
                        }
                        if !collections.isEmpty {
                            tileRow("Collections", items: collections, client: client, more: JellyListRoute(kind: .collections, name: "Collections"))
                        }
                    }
                } else {
                    NavigationLink(value: AppDestination.jellyfin) {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack").font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            Text("Connect Jellyfin").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14).frame(minHeight: 50).diaryPanel(padding: 0, radius: 14).contentShape(Rectangle())
                    }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-connect")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .navigationTitle("JellySpace").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
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
        .task { await loadHome() }
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            // A pause after typing, so a search goes once per word, not once per letter.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let client = JellySpace.client else { return }
            results = (try? await client.videos(search: query.trimmingCharacters(in: .whitespacesAndNewlines))) ?? []
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await loadRows() } }) { JellyPlayerView(playback: $0) }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .bold)).tracking(-0.2).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
    }

    /// Your libraries: Jellyfin's own picture for each (it carries the name), the name under it.
    private func myMedia(_ client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("My Media")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(libraries) { library in
                        NavigationLink(value: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder")) {
                            VStack(spacing: 8) {
                                ZStack {
                                    Rectangle().fill(HomeStyle.card)
                                    Image(systemName: JellySpace.symbol(library.type)).font(.system(size: 24)).foregroundStyle(HomeStyle.secondary)
                                    JellyImage(url: JellyfinClient.imageURL(base: client.base, item: library.id, type: "Primary", tag: nil))
                                }
                                .frame(width: 150, height: 84).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(library.name).font(.system(size: 15)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            }.frame(width: 150).contentShape(Rectangle())
                        }.buttonStyle(.springPress).accessibilityLabel(library.name).accessibilityIdentifier("jellyspace-library-" + library.id)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    /// Continue Watching: wide cards (the episode's still or the film's backdrop) that play at once.
    private func wideRow(_ title: String, items: [JellyfinClient.Item], client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.Id) { JellyWideCard(item: $0, client: client, playing: $playing) }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    /// A row of posters (a library's newest, your favourites, collections), with More opening all of them.
    private func tileRow<Route: Hashable>(_ title: String, items: [JellyfinClient.Item], client: JellyfinClient, more: Route) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                heading(title)
                Spacer(minLength: 8)
                NavigationLink(value: more) {
                    Text("More").font(.system(size: 17)).foregroundStyle(ThemeStore.accent).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.Id) { item in
                        JellyTile(item: item, client: client, playing: $playing).frame(width: 118)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    private func loadHome() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
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
        var newest: [String: [JellyfinClient.Item]] = [:]
        for library in libraries {
            newest[library.id] = (try? await client.latest(in: library.id, user: user)) ?? []
        }
        latest = newest
    }
}

/// A library, folder, show or season: folders and shows open deeper, a show lists its seasons, a
/// season its episodes, and films, episodes and videos play. Sort and Unwatched sit in the ••• menu.
struct JellyFolderPage: View {
    let route: JellyFolderRoute
    @AppStorage("jellyspace.sort") private var sortRaw = JellyfinClient.Sort.name.rawValue
    @State private var unwatched = false
    @State private var items: [JellyfinClient.Item] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text("Nothing in here.").font(.subheadline).foregroundStyle(.secondary) }
                    if route.kind == "Season" {
                        LazyVStack(spacing: 8) { ForEach(items, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing) } }
                    } else {
                        // Albums, videos and the rest as posters; photos as a grid of squares after them.
                        let photos = items.filter { $0.kind == "Photo" }
                        JellyGrid(items: photos.isEmpty ? items : items.filter { $0.kind != "Photo" }, client: client, playing: $playing)
                        if !photos.isEmpty { JellyPhotoGrid(photos: photos, client: client) }
                    }
                }
            }.padding(.horizontal, route.kind == "Season" ? 16 : 10).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar { if sortable { ToolbarItem(placement: .topBarTrailing) { JellySortMenu(sort: $sortRaw, unwatched: $unwatched) } } }
        .task(id: sortRaw + String(unwatched)) { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    /// Seasons and a show's season list keep their own order.
    private var sortable: Bool { route.kind != "Season" && route.kind != "Series" }

    private func load() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let user = await JellyfinUser.id(client)
            let found = try await client.children(of: route.id, user: user, sort: sortable ? JellyfinClient.Sort(rawValue: sortRaw) ?? .name : nil,
                                                  unwatched: sortable && unwatched)
            items = found.filter { JellySpace.opens($0) } + found.filter { !JellySpace.opens($0) }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

/// Posters three across.
struct JellyGrid: View {
    let items: [JellyfinClient.Item]
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items, id: \.Id) { JellyTile(item: $0, client: client, playing: $playing) }
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
    var body: some View {
        link.modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite,
                                    play: item.kind == "Movie" ? { playing = JellySpace.playback(item, client: client) } : nil))
            .fullScreenCover(item: $photo) { _ in JellyPhotoViewer(photos: [item], client: client, start: 0) }
    }
    @ViewBuilder private var link: some View {
        if item.kind == "Photo" {
            Button { photo = JellyPhotoSelection(index: 0) } label: { face }
                .buttonStyle(.springPress).accessibilityLabel(item.Name ?? "Photo").accessibilityIdentifier("jellyspace-photo-" + item.Id)
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
            Color.clear.aspectRatio(2 / 3, contentMode: .fit)
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
                    if item.kind == "Series", played != true, let left = item.UserData?.UnplayedItemCount, left > 0 {
                        Text("\(left)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 22, minHeight: 22).background(ThemeStore.accent, in: Capsule()).padding(5)
                    } else { JellyWatchedMark(item: item, played: played) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? "")).font(.system(size: 16))
                .foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, 6)
            Text(JellySpace.detail(item)).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
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
    @State private var played: Bool?
    @State private var favourite: Bool?
    var body: some View {
        Button { playing = JellySpace.playback(item, client: client) } label: {
            VStack(alignment: .leading, spacing: 2) {
                ZStack {
                    Rectangle().fill(HomeStyle.card)
                    JellyImage(url: JellySpace.wideImage(item, base: client.base))
                }
                .frame(width: 248, height: 140)
                .overlay(alignment: .bottom) { JellyProgress(item: item, played: played) }
                .overlay(alignment: .topTrailing) { JellyWatchedMark(item: item, played: played) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? ""))
                    .font(.system(size: 16)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.top, 4)
                Text(JellySpace.detail(item)).font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            }.frame(width: 248, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.springPress).accessibilityLabel("Play " + JellySpace.name(item))
        .modifier(JellyItemMenu(item: item, played: $played, favourite: $favourite, play: nil))
    }
}

/// A long press on a poster or row: play (a film), watched or unwatched, favourite, and an episode's show.
struct JellyItemMenu: ViewModifier {
    let item: JellyfinClient.Item
    @Binding var played: Bool?
    @Binding var favourite: Bool?
    let play: (() -> Void)?
    @Environment(AppRouter.self) private var router
    @ViewBuilder func body(content: Content) -> some View {
        if item.kind == "CollectionFolder" {
            content
        } else {
            content.contextMenu {
                if let play { Button("Play", systemImage: "play.fill", action: play) }
                let isPlayed = played ?? (item.UserData?.Played == true)
                Button(isPlayed ? "Mark as unwatched" : "Mark as watched", systemImage: isPlayed ? "eye.slash" : "checkmark.circle") {
                    played = !isPlayed
                    let id = item.Id, now = !isPlayed
                    send { client, user in try await client.setPlayed(id, user: user, now) }
                }
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
        guard let base = JellyfinSettings.address, let key = JellyfinSettings.apiKey else { return nil }
        return JellyfinClient(base: base, key: key)
    }
    /// Folders, shows and seasons open; films, episodes and videos play.
    static func opens(_ item: JellyfinClient.Item) -> Bool { item.IsFolder == true || ["Folder", "CollectionFolder", "Series", "Season", "BoxSet"].contains(item.kind) }
    static func playback(_ item: JellyfinClient.Item, client: JellyfinClient) -> JellyPlayback? {
        guard let url = client.streamURL(item.Id) else { return nil }
        return JellyPlayback(id: item.Id, url: url, title: name(item), item: item, client: client)
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
