import SwiftUI

/// JellySpace: your Jellyfin films and episodes, newest first or by search, each played by
/// AetherEngine straight from the file (Jellyfin's static stream, nothing converted). Opens from
/// the TwilDiary logo on Home. The player is JellyPlayerView.
struct JellySpaceView: View {
    @State private var items: [JellyfinClient.Item] = []
    @State private var query = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    private var client: JellyfinClient? {
        guard let base = JellyfinSettings.address, let key = JellyfinSettings.apiKey else { return nil }
        return JellyfinClient(base: base, key: key)
    }

    var body: some View {
        ExploreBrowsePage(title: "JellySpace", symbol: "play.rectangle.on.rectangle", subtitle: query.isEmpty ? "Recently added" : "Search") {
            VStack(alignment: .leading, spacing: 14) {
                if client == nil {
                    NavigationLink(value: AppDestination.jellyfin) {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack").font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            Text("Connect Jellyfin").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14).frame(minHeight: 50).diaryPanel(padding: 0, radius: 14).contentShape(Rectangle())
                    }.buttonStyle(.springPress).accessibilityIdentifier("jellyspace-connect")
                } else {
                    SearchField(placeholder: "Search Jellyfin", text: $query, label: "Search Jellyfin")
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading Jellyfin", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text(query.isEmpty ? "Nothing in Jellyfin yet." : "Nothing matches “\(query)”.").font(.subheadline).foregroundStyle(.secondary) }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(items, id: \.Id) { item in tile(item) }
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .task(id: query) {
            // A pause after typing, so a search goes once per word, not once per letter.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .fullScreenCover(item: $playing) { JellyPlayerView(playback: $0) }
    }

    private func tile(_ item: JellyfinClient.Item) -> some View {
        Button {
            guard let client, let url = client.streamURL(item.Id) else { return }
            playing = JellyPlayback(id: item.Id, url: url, title: Self.name(item), item: item, client: client)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Jellyfin's own posters come from its home-network address, which the public artwork
                // loader refuses (it takes TMDB's and AniList's only): JellyfinPoster loads and keeps them.
                Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        let fallback = Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
                        if let url = client.flatMap({ Self.poster(item, base: $0.base) }) { JellyfinPoster(url: url) { fallback } } else { fallback }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(item.SeriesName ?? item.Name ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(Self.detail(item)).font(.system(size: 11)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityLabel("Play " + Self.name(item)).accessibilityIdentifier("jellyspace-item-" + item.Id)
    }

    private func load() async {
        guard let client else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let found = try await client.videos(search: query.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !Task.isCancelled else { return }
            items = found
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    /// An episode by its show's poster; a film by its own.
    static func poster(_ item: JellyfinClient.Item, base: URL) -> URL? {
        if let series = item.SeriesId, let tag = item.SeriesPrimaryImageTag { return JellyfinClient.posterURL(base: base, item: series, tag: tag) }
        return JellyfinClient.posterURL(base: base, item: item.Id, tag: item.ImageTags?["Primary"])
    }
    /// "S1 E4 · Name" for an episode, "2019" for a film.
    static func detail(_ item: JellyfinClient.Item) -> String {
        guard item.kind == "Episode" else { return item.ProductionYear.map(String.init) ?? "Movie" }
        let place = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
        return [place.isEmpty ? nil : place, item.Name].compactMap { $0 }.joined(separator: " · ")
    }
    static func name(_ item: JellyfinClient.Item) -> String {
        guard item.kind == "Episode", let show = item.SeriesName else { return item.Name ?? "Video" }
        return show + " · " + detail(item)
    }
}
