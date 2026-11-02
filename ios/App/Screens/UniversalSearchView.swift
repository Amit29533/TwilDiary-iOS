import SwiftUI
import TwilDiaryCore

struct UniversalSearchView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                PageHeader(name: "Search", part: .title)
                CatalogSearchView(universal: true)
            }.padding(.bottom, 24)
        }.scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) { PageHeader(name: "Search", part: .buttons) }
            .diaryScreenBackground()
    }
}

struct SearchLandingView: View {
    let recent: [String]
    let choose: (String) -> Void
    let clear: () -> Void
    @Environment(DiaryStore.self) private var store
    @State private var items: [CatalogItem] = []
    @State private var loading = false
    @State private var failure: String?
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
            Text("Search your library, online titles, cast, characters and voice actors.").font(.footnote).foregroundStyle(.secondary)
        }.task(id: store.sessionRevision) { items = []; await load() }
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
    let onChoose: () -> Void
    @Environment(DiaryStore.self) private var store
    @State private var results: [SearchPerson] = []
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People & characters").font(.headline)
            if loading && results.isEmpty { ProgressView("Finding people") }
            ForEach(results, id: \.key) { person in
                Button { onChoose(); open(person) } label: {
                    HStack(spacing: 12) {
                        Artwork(path: person.image, title: person.name).frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) { Text(person.name).font(.subheadline.weight(.semibold)); Text(person.kind == "cast" ? "Cast · TMDB" : person.kind == "character" ? "Character · AniList" : "Voice actor · AniList").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("search-person-" + person.key)
            }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
            if !loading && results.isEmpty && failure == nil { Text("No people found").font(.footnote).foregroundStyle(.secondary) }
        }.task(id: query + String(describing: store.sessionRevision)) { await load() }
    }
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
            if store.isPreview { results = [SearchPerson(id: 525, name: "Reference actor", image: nil)]; loading = false; return }
            #endif
            struct Reply: Decodable { let items: [SearchPerson] }
            do {
                let page: Reply = try await store.read(CatalogTools.apiPath("/api/metadata/people", query: ["q": requested]))
                guard !Task.isCancelled, requested == query, revision == store.sessionRevision else { return }
                results = page.items
            } catch { if !Task.isCancelled { failure = "TMDB people could not be loaded. Try again." } }
            let anime = try await AniListClient.shared.searchPeople(requested)
            guard !Task.isCancelled, requested == query, revision == store.sessionRevision else { return }
            results += anime
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
