import SwiftUI
import TwilDiaryCore

/// A list across the libraries: a person's films and shows, a genre or studio, your favourites, or
/// collections. A genre or studio opened from a library's Genres or Studios keeps to that library.
struct JellyListRoute: Hashable {
    enum Kind: String, Hashable { case person, genre, favourites, collections, artist, studio }
    let kind: Kind
    var id: String? = nil
    let name: String
    var library: String? = nil
}

/// One JellyListRoute as a poster grid, with Sort and Unwatched; a person's page starts with their
/// photo and biography.
struct JellyListPage: View {
    let route: JellyListRoute
    /// Posters, landscape cards or Canvas, remembered for this list (a genre, a person, favourites).
    @AppStorage private var layout: JellyGridLayout
    /// Sort, order and the watched filter, remembered for this list.
    @AppStorage private var optionsRaw: String
    init(route: JellyListRoute) {
        self.route = route
        let section = "list." + route.kind.rawValue + "." + (route.id ?? "") + (route.library.map { "." + $0 } ?? "")
        _layout = JellyLayout.storage(section)
        _optionsRaw = AppStorage(wrappedValue: "", JellyBrowseOptions.key(section))
    }
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    private var optionsBinding: Binding<JellyBrowseOptions> {
        Binding(get: { JellyBrowseOptions.decode(optionsRaw) }, set: { optionsRaw = $0.encoded })
    }
    @State private var items: [JellyfinClient.Item] = []
    @State private var person: JellyfinClient.Detail?
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    @State private var fullBio = false

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if route.kind == .person, let person { personHeader(person, client: client).padding(.horizontal, 6) }
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty {
                        Text(JellyBrowseOptions.decode(optionsRaw).filtering ? "Nothing matches these filters." : "Nothing here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    JellyGrid(items: items, client: client, playing: $playing, layout: layout)
                }
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .jellyFaceLock()
        .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { JellyBrowseMenu(options: optionsBinding, layout: $layout) } }
        .safeAreaInset(edge: .bottom) { JellyMiniPlayer().padding(.bottom, 4) }
        .task(id: optionsRaw + hiddenRaw) { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    /// The person's photo and biography from Jellyfin, and (when Jellyfin knows their TMDB id) a link
    /// to the diary's profile of them: their whole career, awards, photos and what you've watched.
    private func personHeader(_ person: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        let profile = person.ProviderIds?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) }.map { PersonRoute(id: $0) }
        let photo = ZStack {
            Rectangle().fill(HomeStyle.card)
            Image(systemName: "person.fill").font(.system(size: 34)).foregroundStyle(HomeStyle.secondary)
            JellyImage(url: person.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: person.Id, type: "Primary", tag: $0, width: 400) })
        }.frame(width: 110, height: 150).clipShape(RoundedRectangle(cornerRadius: 14))
        return HStack(alignment: .top, spacing: 14) {
            if let profile {
                NavigationLink(value: profile) { photo }.buttonStyle(.springPress)
                    .accessibilityLabel("Open " + (person.Name ?? "this person") + "'s profile")
            } else {
                photo
            }
            VStack(alignment: .leading, spacing: 6) {
                if let bio = person.Overview.map(JellySpace.plainText), !bio.isEmpty {
                    Text(bio).font(.system(size: 14)).foregroundStyle(HomeStyle.primary.opacity(0.85)).lineLimit(fullBio ? nil : 6)
                    Button(fullBio ? "Show less" : "Show more") { withAnimation { fullBio.toggle() } }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(ThemeStore.accent)
                }
                if let profile {
                    NavigationLink(value: profile) {
                        Label("Full profile", systemImage: "person.text.rectangle")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            .padding(.horizontal, 14).frame(height: 36).background(HomeStyle.chip, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.springPress).padding(.top, 4)
                    .accessibilityIdentifier("jellyspace-person-profile")
                }
            }
        }
    }

    private func load() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        let user = await JellyfinUser.id(client)
        let options = JellyBrowseOptions.decode(optionsRaw)
        let titles = URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")
        var extra: [URLQueryItem] = []
        var filters = options.showFilter.map { [$0] } ?? []
        switch route.kind {
        case .person:
            extra = [titles, URLQueryItem(name: "PersonIds", value: route.id)]
            if person == nil, let id = route.id { person = try? await client.detail(id, user: user) }
        case .genre: extra = [titles, URLQueryItem(name: "GenreIds", value: route.id)]
        case .studio: extra = [titles, URLQueryItem(name: "StudioIds", value: route.id)]
        case .favourites:
            extra = [URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode")]
            filters.append("IsFavorite")
        case .collections: extra = [URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")]
        case .artist: extra = [URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"), URLQueryItem(name: "AlbumArtistIds", value: route.id)]
        }
        // From a library's Genres or Studios: that library only.
        if let library = route.library { extra.append(URLQueryItem(name: "ParentId", value: library)) }
        do {
            let hidden = JellyHidden.decode(hiddenRaw)
            items = try await client.items(extra, filters: Array(Set(filters)), user: user, sort: options.sort, ascending: options.isAscending)
                .filter { hidden[$0.Id] == nil }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
