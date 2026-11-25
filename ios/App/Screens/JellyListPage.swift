import SwiftUI
import TwilDiaryCore

/// A list across the libraries: a person's films and shows, a genre or studio, your favourites, or
/// collections. A genre or studio opened from a library's Genres or Studios keeps to that library.
struct JellyListRoute: Hashable {
    enum Kind: String, Hashable { case person, genre, favourites, collections, artist, studio, tag }
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
    /// What the list asks the server for, and how far it has read: the rest comes as you scroll.
    @State private var request: JellyListRequest?
    @State private var fetched = 0
    @State private var total = 0
    @State private var loadingMore = false

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if route.kind == .person, let person { personHeader(person, client: client).padding(.horizontal, 6) }
                    if let failure { RetryNotice(message: failure) { Task { await load(fresh: true) } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty {
                        Text(JellyBrowseOptions.decode(optionsRaw).filtering ? "Nothing matches these filters." : "Nothing here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    JellyGrid(items: items, client: client, playing: $playing, layout: layout) { Task { await loadMore() } }
                    if loadingMore { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8) }
                }
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .jellyFaceLock()
        .jellyPage()
        .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { JellyBrowseMenu(options: optionsBinding, layout: $layout) } }
        .safeAreaInset(edge: .bottom) { JellyMiniPlayer().padding(.bottom, 4) }
        .task(id: optionsRaw + hiddenRaw) { await load(fresh: true) }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load(fresh: false) } }) { JellyPlayerView(playback: $0) }
    }

    /// The person's photo and biography from Jellyfin, and (when Jellyfin knows their TMDB id) a link
    /// to the diary's profile of them: their whole career, awards, photos and what you've watched.
    private func personHeader(_ person: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        let profile = person.ProviderIds?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) }.map { PersonRoute(id: $0) }
        let photo = ZStack {
            Rectangle().fill(HomeStyle.card)
            Image(systemName: "person.fill").font(.app(size: 34)).foregroundStyle(HomeStyle.secondary)
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
                    Text(bio).font(.app(size: 14)).foregroundStyle(HomeStyle.primary.opacity(0.85)).lineLimit(fullBio ? nil : 6)
                    Button(fullBio ? "Show less" : "Show more") { withAnimation { fullBio.toggle() } }
                        .font(.app(size: 14, weight: .semibold)).foregroundStyle(ThemeStore.accent)
                }
                if let profile {
                    NavigationLink(value: profile) {
                        Label("Full profile", systemImage: "person.text.rectangle")
                            .font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            .padding(.horizontal, 14).frame(height: 36).background(HomeStyle.chip, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.springPress).padding(.top, 4)
                    .accessibilityIdentifier("jellyspace-person-profile")
                }
            }
        }
    }

    /// `fresh`: another order or filter, shown as it comes. Else (a video closed) the list on the page is
    /// brought up to date where it is.
    private func load(fresh: Bool) async {
        guard let client = JellySpace.client else { return }
        let options = JellyBrowseOptions.decode(optionsRaw)
        // A random list read again is another list: it stays as it was drawn.
        if !fresh, options.sort == .random { return }
        loading = true; failure = nil
        defer { if !Task.isCancelled { loading = false } }
        let user = await JellyfinUser.id(client)
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
        // A tag: its films, shows and videos (as the Tags row counts them).
        case .tag: extra = [URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Video"), URLQueryItem(name: "Tags", value: route.name)]
        }
        // From a library's Genres or Studios: that library only.
        if let library = route.library { extra.append(URLQueryItem(name: "ParentId", value: library)) }
        do {
            let hidden = JellyHidden.decode(hiddenRaw)
            // A tag's titles come from every library: those in a library you hid are left out, as in the row.
            var inHiddenLibraries = Set<String>()
            if route.kind == .tag, let index = await JellyIndexStore.index(client: client, user: user) {
                inHiddenLibraries = Set(index.entries.filter { hidden[$0.library] != nil }.map(\.item.Id))
            }
            // The first page now, the rest as you scroll to them (every page used to be fetched in a row,
            // and again after each film played). Read again after playing, it asks once for as many as
            // were shown. A random order is one page: every request shuffles again.
            let next = JellyListRequest(extra: extra, filters: Array(Set(filters)), hiddenLibraries: inHiddenLibraries)
            let page = try await client.itemsPage(next.extra, filters: next.filters, user: user, sort: options.sort,
                                                  ascending: options.isAscending, start: 0, limit: fresh ? 300 : max(300, fetched))
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            items = page.Items.filter { hidden[$0.Id] == nil && !next.hiddenLibraries.contains($0.Id) && seen.insert($0.Id).inserted }
            request = next
            fetched = page.Items.count
            total = options.sort == .random ? fetched : page.TotalRecordCount
        } catch {
            if !Task.isCancelled { failure = FriendlyError.message(error) }
        }
    }

    /// The next page, as the last poster comes on screen.
    private func loadMore() async {
        guard !loadingMore, !loading, fetched < total, let request, let client = JellySpace.client else { return }
        loadingMore = true
        defer { loadingMore = false }
        let options = JellyBrowseOptions.decode(optionsRaw)
        let user = await JellyfinUser.id(client)
        guard let page = try? await client.itemsPage(request.extra, filters: request.filters, user: user, sort: options.sort,
                                                     ascending: options.isAscending, start: fetched), !Task.isCancelled else { return }
        fetched += page.Items.count
        total = page.Items.isEmpty ? fetched : page.TotalRecordCount
        let hidden = JellyHidden.decode(hiddenRaw), known = Set(items.map(\.Id))
        items += page.Items.filter { hidden[$0.Id] == nil && !request.hiddenLibraries.contains($0.Id) && !known.contains($0.Id) }
    }
}

/// What a JellySpace list asks the server for (kept for its next pages).
private struct JellyListRequest {
    let extra: [URLQueryItem]
    let filters: [String]
    let hiddenLibraries: Set<String>
}
