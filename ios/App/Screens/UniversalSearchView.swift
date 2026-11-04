import SwiftUI
import TwilDiaryCore

struct UniversalSearchView: View {
    var body: some View {
        EdgeToEdgeScroll {
            VStack(spacing: 12) {
                PageHeader(name: "Search")
                CatalogSearchView(universal: true)
            }.padding(.bottom, 24)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground()
    }
}

struct SearchLandingView: View {
    let recent: [String]
    let choose: (String) -> Void
    let clear: () -> Void
    @Environment(DiaryStore.self) private var store
    @State private var items: [CatalogItem] = []
    @State private var anime: [AniAppearance] = []
    @State private var loading = false
    @State private var failure: String?
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    /// What people are looking up this week: the most trending titles across movies, shows and
    /// anime, as one-tap searches (TMDB and AniList publish trends, not raw search counts).
    private var trendingSearches: [String] {
        var seen = Set<String>(), result: [String] = []
        let names = items.map(\.name) + anime.map(\.title)
        let ordered = (0..<max(items.count, anime.count)).flatMap { index in
            [items.indices.contains(index) ? items[index].name : nil, anime.indices.contains(index) ? anime[index].title : nil].compactMap { $0 }
        }
        for name in ordered + names where result.count < 10 {
            let key = name.lowercased()
            if !name.isEmpty, name.count <= 40, seen.insert(key).inserted { result.append(name) }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !recent.isEmpty {
                VStack(spacing: 8) {
                    HStack { Text("Recent searches").font(.headline); Spacer(); Button("Clear", action: clear).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("search-clear-recents") }
                    ForEach(recent, id: \.self) { query in
                        Button { choose(query) } label: {
                            HStack(spacing: 12) { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary); Text(query).lineLimit(1); Spacer(); Image(systemName: "arrow.up.left").foregroundStyle(.secondary) }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.primary)
                    }
                }
            }
            if !trendingSearches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Trending searches").font(.title3.bold())
                    InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(Array(trendingSearches.enumerated()), id: \.element) { index, query in
                            Button { choose(query) } label: {
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(theme.accent)
                                    Text(query).font(.subheadline).lineLimit(1)
                                }.padding(.horizontal, 12).frame(minHeight: 36)
                                    .background(.white.opacity(0.08), in: Capsule())
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                            }.buttonStyle(.springPress).foregroundStyle(.primary)
                                .accessibilityLabel("Search " + query).accessibilityIdentifier("trending-search-\(index)")
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("search-trending-searches")
            }
            HStack { Text("Trending this week").font(.title3.bold()); Spacer(); Text("TMDB").font(.caption).foregroundStyle(.secondary) }
            if loading && items.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading trending titles") }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.key) { item in
                        NavigationLink(value: item.route) { CatalogPoster(item: item).frame(width: 124) }.buttonStyle(.plain).accessibilityIdentifier("trending-" + item.key)
                    }
                }
            }.scrollIndicators(.hidden).accessibilityIdentifier("search-trending")
            if !anime.isEmpty {
                HStack { Text("Trending anime").font(.title3.bold()); Spacer(); Text("AniList").font(.caption).foregroundStyle(.secondary) }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(anime) { item in
                            AnimeAppearanceButton(appearance: item) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Artwork(path: item.cover, title: item.title).frame(width: 124, height: 186)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .bottomLeading) { if let score = item.rating, score > 0 { RatingBadge(score: score, source: "AniList").padding(5) } }
                                    ProfileCardCaption(title: item.title)
                                }.frame(width: 124, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("trending-anime-\(item.id)")
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("search-trending-anime")
            }
            Text("Search your library, online titles, cast, characters and voice actors.").font(.footnote).foregroundStyle(.secondary)
        }.task(id: store.sessionRevision) { items = []; await load() }
            .task { await loadAnime() }
    }
    /// Best effort: AniList being down only hides its rows.
    private func loadAnime() async {
        #if DEBUG
        if store.isPreview { return }
        #endif
        guard anime.isEmpty, let found = try? await AniListClient.shared.trendingAnime(), !Task.isCancelled else { return }
        anime = found
    }
    private func load() async {
        guard !loading else { return }; loading = true; failure = nil
        let revision = store.sessionRevision
        defer { loading = false }
        do {
            let service = LiveDiscoveryService(store: store)
            let movies = try await service.page(["source": "tmdb", "type": "movie", "sort": "trending", "page": "1", "limit": "8"])
            let shows = try await service.page(["source": "tmdb", "type": "tv", "sort": "trending", "page": "1", "limit": "8"])
            guard !Task.isCancelled, revision == store.sessionRevision else { return }
            // Keep the provider order within each media type, interleaving the two lists.
            items = (0..<max(movies.items.count, shows.items.count)).flatMap { index in
                [movies.items.indices.contains(index) ? movies.items[index] : nil, shows.items.indices.contains(index) ? shows.items[index] : nil].compactMap { $0 }
            }
        } catch { if !Task.isCancelled && revision == store.sessionRevision { failure = error.localizedDescription } }
    }
}

struct SearchPerson: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let image: String?
    var kind = "cast"
    var key: String { kind + ":" + String(id) }
    enum CodingKeys: String, CodingKey { case id, name, image }
}

struct SearchPeopleView: View {
    let query: String
    var kind: String? = nil
    var limit = 40
    let onChoose: () -> Void
    @Environment(DiaryStore.self) private var store
    @State private var results: [SearchPerson] = []
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == "cast" ? "Cast · TMDB" : kind == "character" ? "Characters · AniList" : kind == "voice" ? "Voice actors · AniList" : "People & characters").font(.headline)
            if loading && results.isEmpty { ProgressView("Finding people") }
            ForEach(Array(visible.prefix(limit)), id: \.key) { person in
                Button { onChoose(); open(person) } label: {
                    HStack(spacing: 12) {
                        Artwork(path: person.image, title: person.name).frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) { Text(person.name).font(.subheadline.weight(.semibold)); Text(person.kind == "cast" ? "Cast · TMDB" : person.kind == "character" ? "Character · AniList" : "Voice actor · AniList").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("search-person-" + person.key)
            }
            if visible.count > limit { Text("Choose Cast, Characters or Voice actors above for more results.").font(.caption).foregroundStyle(.secondary) }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
            if !loading && visible.isEmpty && failure == nil { Text("No people found").font(.footnote).foregroundStyle(.secondary) }
        }.task(id: query + (kind ?? "all") + String(describing: store.sessionRevision)) { await load() }
    }
    private var visible: [SearchPerson] { results.filter { kind == nil || $0.kind == kind } }
    @Environment(AppRouter.self) private var router
    private func open(_ person: SearchPerson) {
        switch person.kind {
        case "character": router.paths[.search, default: NavigationPath()].append(CharacterRoute(id: person.id))
        case "voice": router.paths[.search, default: NavigationPath()].append(VoiceActorRoute(id: person.id))
        default: router.paths[.search, default: NavigationPath()].append(PersonRoute(id: person.id))
        }
    }
    private func load() async {
        let requested = query, revision = store.sessionRevision
        results = []; failure = nil; loading = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            #if DEBUG
            if store.isPreview {
                results = [SearchPerson(id: 525, name: "Reference Actor", image: nil), SearchPerson(id: 2, name: "Fern", image: nil, kind: "character"), SearchPerson(id: 12, name: "Kana Ichinose", image: nil, kind: "voice")].filter { $0.name.localizedCaseInsensitiveContains(requested) }
                loading = false; return
            }
            #endif
            struct Reply: Decodable { let items: [SearchPerson] }
            if kind == nil || kind == "cast" { do {
                let page: Reply = try await store.read(CatalogTools.apiPath("/api/metadata/people", query: ["q": requested]))
                guard !Task.isCancelled, requested == query, revision == store.sessionRevision else { return }
                results = page.items
            } catch { if !Task.isCancelled { failure = "TMDB people could not be loaded. Try again." } } }
            if kind != "cast" {
                let anime = try await AniListClient.shared.searchPeople(requested)
                guard !Task.isCancelled, requested == query, revision == store.sessionRevision else { return }
                results += anime
            }
        } catch { if !Task.isCancelled && requested == query && revision == store.sessionRevision { failure = "Some people could not be loaded. Try again." } }
        if !Task.isCancelled && requested == query && revision == store.sessionRevision { loading = false }
    }
}

struct SearchJellyfinView: View {
    let query: String
    @Environment(DiaryStore.self) private var store
    private var shelf: JellyfinShelf { .shared }
    var body: some View {
        let items = JellyfinShelf.matched(shelf.entries, diary: store.workspace.activeTitles).filter { $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Jellyfin library").font(.headline)
            ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { ForEach(items.prefix(20)) { item in JellyfinEntryCard(entry: item).frame(width: 110) } } }.scrollIndicators(.hidden)
            if items.isEmpty { Text("No matches in the saved Jellyfin list.").font(.footnote).foregroundStyle(.secondary) }
            NavigationLink("Open Jellyfin library", value: AppDestination.jellyfin).font(.footnote).foregroundStyle(.primary)
        }
    }
}
