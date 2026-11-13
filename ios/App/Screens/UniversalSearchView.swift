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
    /// The session the lists were loaded for: coming back to Search keeps them instead of
    /// clearing and downloading them again.
    @State private var loadedRevision: UUID?
    @State private var loading = false
    @State private var failure: String?
    @State private var allTop = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("RECENT").font(.system(size: 13, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear", action: clear).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).accessibilityIdentifier("search-clear-recents")
                    }
                    InlineFlowLayout {
                        ForEach(recent, id: \.self) { query in
                            Button { choose(query) } label: {
                                HStack(spacing: 6) { Image(systemName: "clock").font(.system(size: 12)); Text(query).lineLimit(1) }
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 36)
                                    .background(.white.opacity(0.07), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                            }.buttonStyle(.plain).accessibilityLabel("Search again for " + query)
                        }
                    }
                }
            }
            if !shows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top 10 shows this week").font(.system(size: 22, weight: .bold)).tracking(-0.5)
                    ForEach(Array(shows.prefix(allTop ? 10 : 6).enumerated()), id: \.element.key) { index, item in
                        NavigationLink(value: item.route) {
                            HStack(spacing: 14) {
                                Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 60, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    HStack(spacing: 8) {
                                        if let score = item.rating, score > 0 {
                                            HStack(spacing: 3) { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color(webHex: "#ffc83d")); Text(score.formatted(.number.precision(.fractionLength(1)))) }
                                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(webHex: "#ffc83d"))
                                        }
                                        if CatalogTools.libraryIdentity(item, in: store.workspace) != nil {
                                            Text("In library").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                                                .padding(.horizontal, 8).frame(height: 22).background(theme.accent.opacity(0.16), in: Capsule())
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                Text("\(index + 1)").font(.system(size: 28, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(index < 3 ? theme.accent : Color.white.opacity(0.3))
                            }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08))).contentShape(Rectangle())
                        }.buttonStyle(.springPress).foregroundStyle(.primary).accessibilityIdentifier("trending-show-\(index + 1)")
                    }
                    if !allTop && shows.count > 6 {
                        Button { allTop = true } label: {
                            Text("See all \(min(10, shows.count))").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 50).background(.white.opacity(0.04), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                        }.buttonStyle(.springPress).accessibilityIdentifier("search-top-all")
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("search-top-shows")
            }
            if loading && items.isEmpty && shows.isEmpty { DiaryLoadingPlaceholder(height: 210, label: "Loading trending titles") }
            if !items.isEmpty { Text("Trending movies").font(.system(size: 22, weight: .bold)).tracking(-0.5) }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                        NavigationLink(value: item.route) {
                            VStack(alignment: .leading, spacing: 6) {
                                Artwork(path: item.artwork, title: item.name, initialsOnly: false).frame(width: 124, height: 176).clipShape(RoundedRectangle(cornerRadius: 14))
                                    // TMDB's score (or the diary's for a title in your library), as on the anime row below.
                                    .overlay(alignment: .bottomLeading) {
                                        if let score = item.rating ?? store.libraryIdentity(item).flatMap({ store.title($0)?.communityScore }), score > 0 {
                                            RatingBadge(score: score, source: "TMDB").padding(5)
                                        }
                                    }
                                Text("No. \(index + 1) today").font(.system(size: 14)).foregroundStyle(.secondary)
                            }.frame(width: 124, alignment: .leading)
                        }.buttonStyle(.springPress).shelfTransition().accessibilityIdentifier("trending-" + item.key)
                    }
                }
            }.scrollIndicators(.hidden).accessibilityIdentifier("search-trending")
            if !anime.isEmpty {
                Text("Trending anime").font(.system(size: 22, weight: .bold)).tracking(-0.5)
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
            .task(id: store.sessionRevision) {
                guard loadedRevision != store.sessionRevision || (shows.isEmpty && items.isEmpty) else { return }
                items = []; shows = []
                await load()
                if failure == nil, !shows.isEmpty || !items.isEmpty { loadedRevision = store.sessionRevision }
            }
            .task { await loadAnime() }
    }
    /// Best effort: AniList being down only hides its rows.
    private func loadAnime() async {
        #if DEBUG
        if store.isPreview { return }
        #endif
        guard anime.isEmpty, let found = try? await AniListClient.shared.trendingAnime(), !Task.isCancelled else { return }
        anime = found
        // Each one's TMDB title worked out ahead of a tap (owner's report: still 3–4 s): one Wikidata
        // request for the row, then the same look-up a tap makes, for any still unknown, remembered.
        await WikidataAnime.shared.routes(found.map { WikidataAnime.Anime(id: $0.id, format: $0.format) })
        for item in found {
            guard !Task.isCancelled else { return }
            if await AniListClient.shared.tmdbTitle(item.id) != nil { continue }
            guard let result = try? await store.animeNavigation.title(item, service: store) else { continue }
            if case .catalog(let route)? = result.destination { await AniListClient.shared.rememberTitle(item.id, route: route) }
        }
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
    /// How many people matched, for Search's People chip.
    var onCount: (Int) -> Void = { _ in }
    @Environment(DiaryStore.self) private var store
    @State private var results: [SearchPerson] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var shown = 0
    var body: some View {
        // Design: PEOPLE, then a card per person: a round photo, the name and what they are.
        VStack(alignment: .leading, spacing: 10) {
            if !visible.isEmpty {
                Text(kind == "cast" ? "CAST" : kind == "character" ? "CHARACTERS" : kind == "voice" ? "VOICE ACTORS" : "PEOPLE")
                    .font(.system(size: 13, weight: .bold)).tracking(1.2).foregroundStyle(HomeStyle.secondary).padding(.top, 10)
            }
            ForEach(Array(visible.prefix(limit + shown)), id: \.key) { person in
                Button { onChoose(); open(person) } label: {
                    HStack(spacing: 14) {
                        Artwork(path: person.image, title: person.name, alignment: .top).frame(width: 64, height: 64).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name).font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                            Text(person.kind == "cast" ? "Cast" : person.kind == "character" ? "Character" : "Voice actor")
                                .font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4); Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(webHex: "#6a6a78"))
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard()).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("search-person-" + person.key)
            }
            if visible.count > limit + shown { Button("More people") { shown += 12 }.font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText).frame(minHeight: 44) }
            if let failure, visible.isEmpty == false { Text(failure).font(.caption).foregroundStyle(.secondary) }
        }.task(id: query + (kind ?? "all") + String(describing: store.sessionRevision)) { await load() }
            .onChange(of: visible.count) { _, count in onCount(count) }
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
                let items: [SearchPerson]
                if let token = TMDBDirect.token(store) { items = try await TMDBDirect.searchPeople(requested, token: token) }
                else { items = (try await store.read(CatalogTools.apiPath("/api/metadata/people", query: ["q": requested])) as Reply).items }
                guard !Task.isCancelled, requested == query, revision == store.sessionRevision else { return }
                results = items
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
        let items = JellyfinShelf.matched(shelf.entries, diary: store.activeTitles).filter { $0.name.localizedCaseInsensitiveContains(query) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("On Jellyfin").font(.headline)
                ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { ForEach(items.prefix(20)) { item in JellyfinEntryCard(entry: item).frame(width: 110) } } }.scrollIndicators(.hidden)
                NavigationLink("Open Jellyfin library", value: AppDestination.jellyfin).font(.footnote).foregroundStyle(.primary)
            }
        }
    }
}
