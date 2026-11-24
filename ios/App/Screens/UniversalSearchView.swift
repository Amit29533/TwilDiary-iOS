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
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    let kind: CatalogSearchView.Kind
    let recent: [String]
    let choose: (String) -> Void
    let clear: () -> Void
    var remove: (String) -> Void = { _ in }
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var shows: [CatalogItem] = []
    @State private var loadedRevision: UUID?
    @State private var loadingRevision: UUID?
    @State private var failure: String?
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    init(kind: CatalogSearchView.Kind, recent: [String], choose: @escaping (String) -> Void, clear: @escaping () -> Void, remove: @escaping (String) -> Void = { _ in }) {
        self.kind = kind; self.recent = recent; self.choose = choose; self.clear = clear; self.remove = remove
        // The chart shown last, at once (it's checked against this session when the page appears).
        // Anime and People have none (they showed the shows' chart kept from another tab).
        _shows = State(initialValue: [.all, .movies, .shows].contains(kind) ? Self.trending[kind == .movies ? "movie" : "tv"]?.items ?? [] : [])
    }
    private var loading: Bool { loadingRevision == store.sessionRevision }
    /// This session's chart isn't here yet and hasn't failed: its row (and its tags) are coming.
    private var trendingPending: Bool {
        [.all, .movies, .shows].contains(kind) && shows.isEmpty && failure == nil && loadedRevision != store.sessionRevision
    }
    private var trendingHeading: String { kind == .movies ? "Most searched movies today" : kind == .shows ? "Most searched shows today" : "Most searched today" }
    /// A trending title's poster with its place in the chart.
    private func rankedPoster(index: Int, item: CatalogItem) -> some View {
        CatalogPoster(item: item).overlay(alignment: .topLeading) {
            Text("\(index + 1)").font(.app(size: 15, weight: .heavy)).monospacedDigit()
                .foregroundStyle(index < 3 ? ThemeStore.current.accentInk : .white)
                .frame(minWidth: 28, minHeight: 28).padding(.horizontal, 2)
                .background(index < 3 ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.black.opacity(0.7)), in: Capsule())
                .padding(6).accessibilityLabel("Number \(index + 1)")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            RecentlyViewedShelf()
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent searches").font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Button("Clear", action: clear).font(.app(size: 15, weight: .semibold)).foregroundStyle(theme.accent).accessibilityIdentifier("search-clear-recents")
                    }
                    InlineFlowLayout {
                        ForEach(recent, id: \.self) { query in
                            Button { choose(query) } label: {
                                HStack(spacing: 6) { Image(systemName: "clock").font(.app(size: 12)); Text(query).lineLimit(1) }
                                    .font(.app(size: 15, weight: .medium)).foregroundStyle(HomeStyle.ink).padding(.horizontal, 12).frame(height: 36)
                                    .background(Color.primary.opacity(0.07), in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.outline(0.1)))
                            }.buttonStyle(.plain).accessibilityLabel("Search again for " + query)
                                .contextMenu { Button("Remove", systemImage: "xmark", role: .destructive) { withAnimation(.snappy) { remove(query) } } }
                        }
                    }
                }
            }
            if !shows.isEmpty {
                // The week's top ten as one row of posters, as the other shelves, each with its rank.
                VStack(alignment: .leading, spacing: 8) {
                    Text(trendingHeading).font(.title2.bold())
                        .foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(shows.prefix(10).enumerated()), id: \.element.key) { index, item in
                                Group {
                                    if let id = store.libraryIdentity(item) { NavigationLink(value: id) { rankedPoster(index: index, item: item) } }
                                    else { NavigationLink(value: item.route) { rankedPoster(index: index, item: item) } }
                                }.buttonStyle(.springPress).containerRelativeFrame(.horizontal, count: posterSize.columns, spacing: 12)
                                    .accessibilityIdentifier("trending-show-\(index + 1)")
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }.accessibilityElement(children: .contain).accessibilityIdentifier("search-top-shows")
            }
            if trendingPending {
                // The row's own shape (heading and a shelf of posters) while it loads: a list-shaped
                // placeholder was a different height, so the page below jumped when the posters came.
                VStack(alignment: .leading, spacing: 8) {
                    Text(trendingHeading).font(.title2.bold()).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
                    DiaryLoadingPlaceholder(label: "Loading trending titles", layout: .posterShelf)
                }
            }
            if let failure { RetryNotice(message: failure) { Task { await load() } } }
            SearchBrowseShelves(shows: shows, kind: kind, trendingPending: trendingPending)
        }.smoothChange(of: shows.isEmpty)
            .task(id: store.sessionRevision) {
                guard [.all, .movies, .shows].contains(kind), loadedRevision != store.sessionRevision else { return }
                // This session's chart, kept: switching tabs or clearing a search doesn't load it again.
                if let kept = Self.trending[trendingType], kept.revision == store.sessionRevision, Date.now.timeIntervalSince(kept.at) < 1_800 {
                    shows = kept.items; loadedRevision = kept.revision; return
                }
                shows = []
                await load()
            }
    }
    /// Trending this week, per chart ("movie" or "tv"), for this session.
    private static var trending: [String: (revision: UUID, items: [CatalogItem], at: Date)] = [:]
    private var trendingType: String { kind == .movies ? "movie" : "tv" }
    private func load() async {
        let revision = store.sessionRevision
        guard loadingRevision != revision else { return }
        loadingRevision = revision
        failure = nil
        defer { if loadingRevision == revision { loadingRevision = nil } }
        do {
            let service = LiveDiscoveryService(store: store, recoverBrowseReads: true)
            let trendingShows = try await service.page(["source": "tmdb", "type": kind == .movies ? "movie" : "tv", "sort": "trending", "window": "day", "page": "1", "limit": "10"])
            guard !Task.isCancelled, revision == store.sessionRevision else { return }
            shows = Array(CatalogTools.merging([], trendingShows.items).prefix(10))
            loadedRevision = revision
            Self.trending[trendingType] = (revision, shows, .now)
        } catch { if !Task.isCancelled && revision == store.sessionRevision { failure = FriendlyError.message(error) } }
    }
}

struct SearchPerson: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let image: String?
    var kind = "cast"
    /// What they're known from (a character's anime).
    var detail: String? = nil
    var key: String { kind + ":" + String(id) }
    enum CodingKeys: String, CodingKey { case id, name, image }
}

struct SearchPeoplePage: Decodable, Sendable {
    let items: [SearchPerson]
    let page: Int
    let totalPages: Int
}

struct SearchPeopleView: View {
    let query: String
    var limit = 40
    var mixed: [SearchPerson]? = nil
    var usePreview = false
    let onChoose: () -> Void
    var onCount: (Int) -> Void = { _ in }
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    private enum Source: String, CaseIterable, Sendable { case cast = "TMDB cast", anime = "AniList people" }
    @State private var results: [SearchPerson] = []
    @State private var nextPage: [Source: Int] = [.cast: 1, .anime: 1]
    @State private var loading: Set<Source> = []
    @State private var failures: [Source: String] = [:]
    @State private var started = false
    @State private var shown = 0
    private var displayed: [SearchPerson] {
        var seen = Set<String>()
        return ((usePreview ? mixed ?? [] : []) + results).filter { seen.insert($0.key).inserted }
    }
    var body: some View {
        let people = displayed
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("People").font(.headline).foregroundStyle(.primary)
                .padding(.top, 10).accessibilityAddTraits(.isHeader)
            ForEach(people.prefix(limit + shown), id: \.key) { person in
                Button { onChoose(); open(person) } label: {
                    HStack(spacing: 14) {
                        Artwork(path: person.image, title: person.name, alignment: .top).frame(width: 64, height: 64).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name).font(.headline).foregroundStyle(HomeStyle.primary).lineLimit(2)
                            Text([person.kind == "cast" ? "Cast" : person.kind == "character" ? "Character" : "Voice actor", person.detail].compactMap { $0 }.joined(separator: " · "))
                                .font(.app(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4); Image(systemName: "chevron.right").font(.app(size: 14, weight: .semibold)).foregroundStyle(Color(themed: "#6a6a78"))
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard()).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("search-person-" + person.key)
            }
            if !started || !loading.isEmpty {
                if people.isEmpty { DiaryLoadingPlaceholder(label: "Searching people", layout: .list(rows: 3)) }
                else { ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Searching people") }
            }
            ForEach(Source.allCases, id: \.self) { source in
                if let failure = failures[source] {
                    RetryNotice(message: failure) { Task { await load(source) } }
                }
            }
            if started, loading.isEmpty {
                if !people.isEmpty && (people.count > limit + shown || nextPage.keys.contains(where: { failures[$0] == nil })) {
                    Button("More people") {
                        if people.count > limit + shown { shown += 20 }
                        else {
                            shown += 20
                            Task { await loadPages() }
                        }
                    }.font(.subheadline.weight(.semibold)).foregroundStyle(HomeStyle.chipText).frame(minHeight: 44)
                        .accessibilityIdentifier("search-people-more")
                } else if people.isEmpty && failures.isEmpty {
                    Text("No people match “\(query)”.").font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("search-people-empty")
                }
            }
        }.task {
            guard !started else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await load(.anime, retry: false)
            if !Task.isCancelled { started = true }
        }.task(id: usePreview) {
            guard !usePreview, nextPage[.cast] == 1 else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await load(.cast, retry: false)
        }.onChange(of: people.count, initial: true) { _, count in onCount(count) }
    }
    private func open(_ person: SearchPerson) {
        switch person.kind {
        case "character": router.paths[.search, default: NavigationPath()].append(CharacterRoute(id: person.id))
        case "voice": router.paths[.search, default: NavigationPath()].append(VoiceActorRoute(id: person.id))
        default: router.paths[.search, default: NavigationPath()].append(PersonRoute(id: person.id))
        }
    }
    private func loadPages() async {
        async let cast: Void = load(.cast, retry: false)
        async let anime: Void = load(.anime, retry: false)
        _ = await (cast, anime)
    }

    private func load(_ source: Source, retry: Bool = true) async {
        guard let page = nextPage[source], !loading.contains(source),
              retry || failures[source] == nil else { return }
        let revision = store.sessionRevision
        loading.insert(source)
        failures[source] = nil
        defer { loading.remove(source) }
        do {
            let reply = try await fetch(source, page: page)
            guard !Task.isCancelled, revision == store.sessionRevision else { return }
            guard reply.page == page else { throw APIError.message("Search returned an unexpected page.") }
            var ids = Set(results.map(\.key))
            results += reply.items.filter { ids.insert($0.key).inserted }
            nextPage[source] = page < min(500, reply.totalPages) ? page + 1 : nil
        } catch {
            if !Task.isCancelled, revision == store.sessionRevision {
                failures[source] = "\(source.rawValue) could not be loaded. \(FriendlyError.message(error))"
            }
        }
    }

    private func fetch(_ source: Source, page: Int) async throws -> SearchPeoplePage {
        #if DEBUG
        if store.isPreview {
            if source == .cast, query == "Reference", ProcessInfo.processInfo.arguments.contains("--ui-search-regression") {
                let person = page == 1 ? SearchPerson(id: 525, name: "Reference Actor", image: nil)
                                      : SearchPerson(id: 526, name: "Second Reference Actor", image: nil)
                return SearchPeoplePage(items: [person], page: page, totalPages: 2)
            }
            let cast = [SearchPerson(id: 525, name: "Reference Actor", image: nil)]
            let anime = [SearchPerson(id: 2, name: "Fern", image: nil, kind: "character"),
                         SearchPerson(id: 12, name: "Kana Ichinose", image: nil, kind: "voice")]
            let items = (source == .cast ? cast : anime).filter { $0.name.localizedCaseInsensitiveContains(query) }
            return SearchPeoplePage(items: items, page: 1, totalPages: 1)
        }
        #endif
        if source == .anime { return try await AniListClient.shared.searchPeople(query, page: page) }
        if let token = TMDBDirect.token(store) {
            do {
                return try await SearchBrowseRead.retry { try await TMDBDirect.searchPeople(query, page: page, token: token) }
            } catch let error where SearchBrowseRead.isTransportError(error) && ExtrasStorage.server { }
        }
        return try await store.read(CatalogTools.apiPath("/api/metadata/people", query: ["q": query, "page": String(page)]))
    }
}

struct SearchJellyfinView: View {
    let query: String
    let kind: CatalogSearchView.Kind
    @Environment(DiaryStore.self) private var store
    private var shelf: JellyfinShelf { .shared }
    var body: some View {
        let titles = store.activeTitles
        let saved = Dictionary(titles.map { ($0.id, $0.category) }, uniquingKeysWith: { first, _ in first })
        let items = JellyfinShelf.matched(shelf.entries, diary: titles).filter { entry in
            guard entry.name.localizedCaseInsensitiveContains(query) else { return false }
            let anime = entry.diaryID.flatMap { saved[$0]?.hasPrefix("anime") }
                ?? (entry.genres?.contains { $0.caseInsensitiveCompare("anime") == .orderedSame } == true)
            return kind.includes(entry.movie ? .movie : .tv, anime: anime)
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("On Jellyfin").font(.headline)
                ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { ForEach(items.prefix(20)) { item in JellyfinEntryCard(entry: item).frame(width: 110) } } }.scrollIndicators(.hidden)
                NavigationLink("Open Jellyfin library", value: AppDestination.jellyfin).font(.footnote).foregroundStyle(.primary)
            }
        }
    }
}
