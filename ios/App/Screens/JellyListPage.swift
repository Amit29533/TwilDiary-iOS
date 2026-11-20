import SwiftUI
import TwilDiaryCore

/// A list across the libraries: a person's films and shows, a genre, your favourites, or collections.
struct JellyListRoute: Hashable {
    enum Kind: String, Hashable { case person, genre, favourites, collections }
    let kind: Kind
    var id: String? = nil
    let name: String
}

/// One JellyListRoute as a poster grid, with Sort and Unwatched; a person's page starts with their
/// photo and biography.
struct JellyListPage: View {
    let route: JellyListRoute
    @AppStorage("jellyspace.sort") private var sortRaw = JellyfinClient.Sort.name.rawValue
    @State private var unwatched = false
    @State private var items: [JellyfinClient.Item] = []
    @State private var person: JellyfinClient.Detail?
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?
    @State private var fullBio = false

    private var symbol: String {
        switch route.kind { case .person: "person"; case .genre: "theatermasks"; case .favourites: "heart"; case .collections: "square.stack" }
    }

    var body: some View {
        ExploreBrowsePage(title: route.name, symbol: symbol,
                          subtitle: items.isEmpty ? nil : "\(items.count) " + (items.count == 1 ? "title" : "titles")) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if route.kind == .person, let person { personHeader(person, client: client) }
                    JellySortBar(sort: $sortRaw, unwatched: $unwatched)
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text("Nothing here.").font(.subheadline).foregroundStyle(.secondary) }
                    JellyGrid(items: items, client: client, playing: $playing)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .task(id: sortRaw + String(unwatched)) { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    private func personHeader(_ person: JellyfinClient.Detail, client: JellyfinClient) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Rectangle().fill(HomeStyle.card)
                Image(systemName: "person.fill").font(.system(size: 34)).foregroundStyle(HomeStyle.secondary)
                JellyImage(url: person.ImageTags?["Primary"].flatMap { JellyfinClient.imageURL(base: client.base, item: person.Id, type: "Primary", tag: $0, width: 400) })
            }.frame(width: 110, height: 150).clipShape(RoundedRectangle(cornerRadius: 14))
            if let bio = person.Overview.map(JellySpace.plainText), !bio.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(bio).font(.system(size: 14)).foregroundStyle(HomeStyle.primary.opacity(0.85)).lineLimit(fullBio ? nil : 6)
                    Button(fullBio ? "Show less" : "Show more") { withAnimation { fullBio.toggle() } }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(ThemeStore.accent)
                }
            }
        }
    }

    private func load() async {
        guard let client = JellySpace.client else { return }
        loading = true; failure = nil
        defer { loading = false }
        let user = await JellyfinUser.id(client)
        let sort = JellyfinClient.Sort(rawValue: sortRaw) ?? .name
        let titles = URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")
        var extra: [URLQueryItem] = []
        var filters = unwatched ? ["IsUnplayed"] : []
        switch route.kind {
        case .person:
            extra = [titles, URLQueryItem(name: "PersonIds", value: route.id)]
            if person == nil, let id = route.id { person = try? await client.detail(id, user: user) }
        case .genre: extra = [titles, URLQueryItem(name: "GenreIds", value: route.id)]
        case .favourites:
            extra = [URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode")]
            filters.append("IsFavorite")
        case .collections: extra = [URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")]
        }
        do {
            items = try await client.items(extra, filters: filters, user: user, sort: sort)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
