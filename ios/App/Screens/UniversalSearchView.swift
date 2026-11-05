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
    @State private var shows: [CatalogItem] = []
    @State private var anime: [AniAppearance] = []
    @State private var loading = false
    @State private var failure: String?
    @AppStorage("theme") private var theme = DiaryTheme.twilight
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
            if !shows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accent)
                        Text("Top 10 shows this week").font(.title3.bold())
                    }.padding(.bottom, 6)
                    ForEach(Array(shows.prefix(10).enumerated()), id: \.element.key) { index, item in
                        NavigationLink(value: item.route) {
                            HStack(spacing: 14) {
                                Text("\(index + 1)").font(.system(size: 20, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(index < 3 ? theme.accent : .secondary).frame(width: 28)
                                Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 46, height: 69)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                    Text([item.year.map(String.init), "Show"].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if let score = item.rating, score > 0 {
                                    Text(score.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.springPress).foregroundStyle(.primary).accessibilityIdentifier("trending-show-\(index + 1)")
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("search-top-shows")
            }
            if loading && items.isEmpty && shows.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading trending titles") }
            if !items.isEmpty { HStack { Text("Trending movies").font(.title3.bold()); Spacer(); Text("TMDB").font(.caption).foregroundStyle(.secondary) } }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.key) { item in
                        NavigationLink(value: item.route) { CatalogPoster(item: item).frame(width: 124) }.buttonStyle(.springPress).shelfTransition().accessibilityIdentifier("trending-" + item.key)
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
                            }.buttonStyle(.springPress).shelfTransition().accessibilityIdentifier("trending-anime-\(item.id)")
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("search-trending-anime")
            }
            Text("Search your library, online titles, cast, characters and voice actors.").font(.footnote).foregroundStyle(.secondary)
        }.smoothChange(of: [items.isEmpty, shows.isEmpty, anime.isEmpty])
            .task(id: store.sessionRevision) { items = []; shows = []; await load() }
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
            let trendingShows = try await service.page(["source": "tmdb", "type": "tv", "sort": "trending", "page": "1", "limit": "10"])
            guard !Task.isCancelled, revision == store.sessionRevision else { return }
            shows = Array(trendingShows.items.prefix(10))
            let movies = try await service.page(["source": "tmdb", "type": "movie", "sort": "trending", "page": "1", "limit": "10"])
            guard !Task.isCancelled, revision == store.sessionRevision else { return }
            items = movies.items
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
    @State private var shown = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !visible.isEmpty { Text(kind == "cast" ? "Cast · TMDB" : kind == "character" ? "Characters · AniList" : kind == "voice" ? "Voice actors · AniList" : "People & characters").font(.headline) }
            ForEach(Array(visible.prefix(limit + shown)), id: \.key) { person in
                Button { onChoose(); open(person) } label: {
                    HStack(spacing: 12) {
                        Artwork(path: person.image, title: person.name).frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) { Text(person.name).font(.subheadline.weight(.semibold)); Text(person.kind == "cast" ? "Cast · TMDB" : person.kind == "character" ? "Character · AniList" : "Voice actor · AniList").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("search-person-" + person.key)
            }
            if visible.count > limit { Button("More people") { shown += 12 }.font(.footnote).foregroundStyle(.primary).frame(minHeight: 44) }
            if let failure, visible.isEmpty == false { Text(failure).font(.caption).foregroundStyle(.secondary) }
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
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("On Jellyfin").font(.headline)
                ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { ForEach(items.prefix(20)) { item in JellyfinEntryCard(entry: item).frame(width: 110) } } }.scrollIndicators(.hidden)
                NavigationLink("Open Jellyfin library", value: AppDestination.jellyfin).font(.footnote).foregroundStyle(.primary)
            }
        }
    }
}
