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
    @State private var recent: [JellyfinClient.Item] = []
    @State private var results: [JellyfinClient.Item] = []
    @State private var resume: [JellyfinClient.Item] = []
    @State private var nextUp: [JellyfinClient.Item] = []
    @State private var libraries: [JellyfinLibrary] = []
    @State private var query = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var playing: JellyPlayback?

    var body: some View {
        ExploreBrowsePage(title: "JellySpace", symbol: "play.rectangle.on.rectangle", subtitle: "Your Jellyfin") {
            VStack(alignment: .leading, spacing: 22) {
                if let client = JellySpace.client {
                    SearchField(placeholder: "Search Jellyfin", text: $query, label: "Search Jellyfin")
                    if let failure { RetryNotice(message: failure) { Task { await loadHome() } } }
                    if !query.isEmpty {
                        if results.isEmpty && !loading { Text("Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary) }
                        JellyGrid(items: results, client: client, playing: $playing)
                    } else if loading && recent.isEmpty {
                        DiaryLoadingPlaceholder(label: "Loading Jellyfin", layout: .posterGrid(columns: 3, rows: 3))
                    } else {
                        if !resume.isEmpty { row("Continue watching", items: resume, client: client) }
                        if !nextUp.isEmpty { row("Next up", items: nextUp, client: client) }
                        if !libraries.isEmpty { librariesRow }
                        if !recent.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                heading("Recently added")
                                JellyGrid(items: recent, client: client, playing: $playing)
                            }
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
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
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
        Text(text).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, items: [JellyfinClient.Item], client: JellyfinClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.Id) { item in
                        JellyTile(item: item, client: client, playing: $playing).frame(width: 112)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    private var librariesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Libraries")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(libraries) { library in
                        NavigationLink(value: JellyFolderRoute(id: library.id, name: library.name, kind: "CollectionFolder")) {
                            HStack(spacing: 10) {
                                Image(systemName: JellySpace.symbol(library.type)).font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                Text(library.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            }.padding(.horizontal, 16).frame(height: 52).diaryPanel(padding: 0, radius: 14)
                        }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-library-" + library.id)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    private func loadHome() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        async let found = client.videos(search: "")
        async let shelves = client.libraries()
        do {
            recent = try await found
            libraries = (try? await shelves) ?? []
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
        await loadRows()
    }
    /// Continue watching and Next up (they change after each watch).
    private func loadRows() async {
        guard let client = JellySpace.client, let user = await JellyfinUser.id(client) else { return }
        async let started = client.resume(user: user)
        async let upcoming = client.nextUp(user: user)
        resume = (try? await started) ?? []
        nextUp = (try? await upcoming) ?? []
    }
}

/// A library, folder, show or season: folders and shows open deeper, a show lists its seasons, a
/// season its episodes, and films, episodes and videos play.
struct JellyFolderPage: View {
    let route: JellyFolderRoute
    @State private var items: [JellyfinClient.Item] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?

    var body: some View {
        ExploreBrowsePage(title: route.name, symbol: route.kind == "Season" || route.kind == "Series" ? "tv" : "folder",
                          subtitle: items.isEmpty ? nil : "\(items.count) " + (items.count == 1 ? "item" : "items")) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text("Nothing in here.").font(.subheadline).foregroundStyle(.secondary) }
                    if route.kind == "Season" {
                        LazyVStack(spacing: 8) { ForEach(items, id: \.Id) { JellyEpisodeRow(item: $0, client: client, playing: $playing) } }
                    } else {
                        JellyGrid(items: items, client: client, playing: $playing)
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .task { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    private func load() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let user = await JellyfinUser.id(client)
            let found = try await client.children(of: route.id, user: user)
            items = found.filter { JellySpace.opens($0) } + found.filter { !JellySpace.opens($0) }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

/// Posters three across.
private struct JellyGrid: View {
    let items: [JellyfinClient.Item]
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items, id: \.Id) { JellyTile(item: $0, client: client, playing: $playing) }
        }
    }
}

/// One item: a folder, show or season opens; anything playable plays. Its poster, name and line,
/// with your progress as a thin bar and a tick once watched.
private struct JellyTile: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    var body: some View {
        if JellySpace.opens(item) {
            NavigationLink(value: JellyFolderRoute(id: item.Id, name: item.Name ?? "Folder", kind: item.kind)) { face }
                .buttonStyle(.springPress).accessibilityIdentifier("jellyspace-folder-" + item.Id)
        } else {
            Button { playing = JellySpace.playback(item, client: client) } label: { face }
                .buttonStyle(.springPress).accessibilityLabel("Play " + JellySpace.name(item)).accessibilityIdentifier("jellyspace-item-" + item.Id)
        }
    }
    private var face: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .overlay(alignment: .bottom) { JellyProgress(item: item) }
                .overlay(alignment: .topTrailing) {
                    if item.kind == "Series", let left = item.UserData?.UnplayedItemCount, left > 0 {
                        Text("\(left)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24).background(ThemeStore.accent, in: Capsule()).padding(6)
                    } else { JellyWatchedMark(item: item) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.kind == "Episode" ? (item.SeriesName ?? item.Name ?? "") : (item.Name ?? "")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HomeStyle.primary).lineLimit(1)
            Text(JellySpace.detail(item)).font(.system(size: 11)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
        }.contentShape(Rectangle())
    }
}

/// A season's episode: its still (or the show's poster), "3 · Name", the length, and your progress.
private struct JellyEpisodeRow: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    @Binding var playing: JellyPlayback?
    var body: some View {
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
                    .overlay(alignment: .bottom) { JellyProgress(item: item) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text([item.IndexNumber.map(String.init), item.Name].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading)
                    if let minutes = item.RunTimeTicks.map({ Int($0 / 600_000_000) }), minutes > 0 {
                        Text(DiaryDate.duration(minutes)).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                    }
                }
                Spacer(minLength: 0)
                if item.UserData?.Played == true {
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
private struct JellyProgress: View {
    let item: JellyfinClient.Item
    var body: some View {
        if let percent = item.UserData?.PlayedPercentage, percent > 0, item.UserData?.Played != true {
            GeometryReader { proxy in
                Rectangle().fill(.black.opacity(0.55))
                    .overlay(alignment: .leading) { Rectangle().fill(ThemeStore.accent).frame(width: proxy.size.width * min(1, percent / 100)) }
            }.frame(height: 4)
        }
    }
}

private struct JellyWatchedMark: View {
    let item: JellyfinClient.Item
    var body: some View {
        if item.UserData?.Played == true, item.IsFolder != true {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(.black.opacity(0.65), in: Circle()).padding(6)
        }
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
    /// "S1 E4 · Name" for an episode, the year for a film, what a folder is.
    static func detail(_ item: JellyfinClient.Item) -> String {
        if item.IsFolder != true, item.kind != "Episode", let path = item.Path, !path.isEmpty {
            return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        }
        switch item.kind {
        case "Episode":
            let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
            return [place.isEmpty ? nil : place, item.Name].compactMap { $0 }.joined(separator: " · ")
        case "Series": return item.ProductionYear.map { "Show · \($0)" } ?? "Show"
        case "Season": return "Season"
        case "Movie": return item.ProductionYear.map(String.init) ?? "Movie"
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
        case "music": "music.note"
        case "musicvideos": "music.note.tv"
        default: "folder"
        }
    }
}
