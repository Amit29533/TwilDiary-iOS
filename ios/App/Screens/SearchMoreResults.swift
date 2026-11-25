import SwiftUI
import TwilDiaryCore

// MARK: Recently viewed

/// A title page you opened, for the search page's "Recently viewed" row.
struct RecentlyViewedTitle: Codable, Hashable, Identifiable, Sendable {
    /// "tv:1396" when TMDB knows it (a preview and its library title are one entry), else "library:<id>".
    let key: String
    let name: String
    let poster: String?
    var libraryID: String?
    var movie: Bool
    var tmdb: Int?
    var id: String { key }
    var route: CatalogRoute? { tmdb.map { CatalogRoute(kind: movie ? .movie : .tv, id: $0) } }

    init(name: String, poster: String?, libraryID: String?, movie: Bool, tmdb: Int?) {
        self.key = tmdb.map { (movie ? "movie:" : "tv:") + String($0) } ?? "library:" + (libraryID ?? name)
        self.name = name; self.poster = poster; self.libraryID = libraryID; self.movie = movie; self.tmdb = tmdb
    }
}

/// The titles you opened last, newest first, kept on this iPhone (like recent searches).
enum RecentlyViewed {
    static let storageKey = "recentlyViewed.v1"
    static let limit = 15

    static func decode(_ json: String) -> [RecentlyViewedTitle] {
        (try? JSONDecoder().decode([RecentlyViewedTitle].self, from: Data(json.utf8))) ?? []
    }
    /// The list with `item` first: once each, a library id kept from an earlier visit, at most `limit`.
    static func adding(_ item: RecentlyViewedTitle, to list: [RecentlyViewedTitle]) -> [RecentlyViewedTitle] {
        var entry = item
        if entry.libraryID == nil { entry.libraryID = list.first { $0.key == item.key }?.libraryID }
        return Array(([entry] + list.filter { $0.key != item.key }).prefix(limit))
    }
    static func encode(_ list: [RecentlyViewedTitle]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    @MainActor static func record(_ item: RecentlyViewedTitle) {
        let defaults = UserDefaults.standard
        let list = adding(item, to: decode(defaults.string(forKey: storageKey) ?? "[]"))
        guard let data = try? JSONEncoder().encode(list), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: storageKey)
    }
}

/// The search page's row of the titles you opened last.
struct RecentlyViewedShelf: View {
    @PosterSizing private var posterSize
    @AppStorage(RecentlyViewed.storageKey) private var json = "[]"
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        let items = RecentlyViewed.decode(json)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recently viewed").font(.headline).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Clear") { json = "[]" }.font(.app(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                        .accessibilityIdentifier("search-clear-viewed")
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Artwork(path: item.poster, title: item.name, initialsOnly: false).frame(width: posterSize.shelf, height: posterSize.shelfHeight)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(item.name).font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }.frame(width: posterSize.shelf, alignment: .leading)
                            }.buttonStyle(.springPress).accessibilityIdentifier("search-viewed-" + item.key)
                                .contextMenu {
                                    Button("Remove", systemImage: "xmark", role: .destructive) {
                                        withAnimation(.snappy) { json = RecentlyViewed.encode(items.filter { $0.key != item.key }) }
                                    }
                                }
                        }
                    }
                }.scrollIndicators(.hidden).scrollClipDisabled()
            }
        }
    }
    private func open(_ item: RecentlyViewedTitle) {
        // The library title when it's (still or now) in the diary, else TMDB's page.
        if let id = item.libraryID, store.title(id) != nil { router.openTitle(id, tab: .search); return }
        if let route = item.route {
            if let id = store.libraryIdentity(CatalogItem(id: route.id, mediaType: route.kind, name: item.name)) { router.openTitle(id, tab: .search) }
            else { router.paths[.search, default: NavigationPath()].append(route) }
        }
    }
}

// MARK: Studios and franchises

/// Studios and franchises (TMDB's companies and collections) whose names match the search,
/// under the titles: "Ghibli" finds Studio Ghibli, "Harry Potter" the film series.
struct SearchStudiosAndFranchises: View {
    @PosterSizing private var posterSize
    let query: String
    let kind: CatalogSearchView.Kind
    var onChoose: () -> Void = {}
    @Environment(DiaryStore.self) private var store
    @State private var studios: [TitleCompany] = []
    private struct Franchise: Identifiable { let id: Int; let name: String; let poster: String? }
    @State private var franchises: [Franchise] = []
    @State private var loadedQuery: String?

    private var showsStudios: Bool { kind != .people }
    private var showsFranchises: Bool { kind == .all || kind == .movies }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsFranchises, !franchises.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Franchises").font(.headline).accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(franchises) { item in
                                NavigationLink(value: ShowPageRoute.tmdbCollection(id: item.id, name: item.name)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Artwork(path: item.poster, title: item.name, initialsOnly: false).frame(width: posterSize.shelf, height: posterSize.shelfHeight)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(item.name).font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                    }.frame(width: posterSize.shelf, alignment: .leading)
                                }.buttonStyle(.springPress).simultaneousGesture(TapGesture().onEnded(onChoose))
                                    .accessibilityIdentifier("search-franchise-\(item.id)")
                            }
                        }
                    }.scrollIndicators(.hidden).scrollClipDisabled()
                }
            }
            if showsStudios, !studios.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Studios").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(studios) { company in
                        NavigationLink(value: CompanyRoutes.explore(company, kind: studioKind(company))) {
                            HStack(spacing: 14) {
                                CompanyLogo(company: company).frame(width: 64, height: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(company.name).font(.headline).foregroundStyle(HomeStyle.primary).lineLimit(2)
                                    Text(["Studio", company.country.flatMap { Locale.current.localizedString(forRegionCode: $0) }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.app(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.app(size: 14, weight: .semibold)).foregroundStyle(Color(themed: "#6a6a78"))
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard()).contentShape(Rectangle())
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded(onChoose))
                            .accessibilityIdentifier("search-studio-\(company.id)")
                    }
                }
            }
        }
        .task(id: query) { await load() }
    }

    /// Shows for a studio in Japan (anime studios) or when searching shows or anime, films otherwise.
    private func studioKind(_ company: TitleCompany) -> MediaKind {
        switch kind {
        case .shows, .anime: .tv
        case .movies: .movie
        default: company.country == "JP" ? .tv : .movie
        }
    }

    private func load() async {
        guard loadedQuery != query else { return }
        studios = []; franchises = []
        guard !store.isPreview, query.count >= 3, let token = TMDBDirect.token(store) else { return }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        let wanted = SpellingSuggestion.comparable(query)
        func matches(_ name: String) -> Bool { (" " + SpellingSuggestion.comparable(name) + " ").contains(" " + wanted) }
        let companies = try? await TMDBDirect.object("search/company", query: ["query": query, "page": "1"], token: token)
        guard !Task.isCancelled else { return }
        let collections = try? await TMDBDirect.object("search/collection", query: ["query": query, "page": "1", "language": "en-US"], token: token)
        guard !Task.isCancelled else { return }
        studios = Array(((companies?["results"] as? [[String: Any]]) ?? []).compactMap { row -> TitleCompany? in
            guard let id = row["id"] as? Int, id > 0, let name = row["name"] as? String, !name.isEmpty, matches(name) else { return nil }
            let logo = (row["logo_path"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            let country = (row["origin_country"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return TitleCompany(id: id, name: name, logoPath: logo, kind: "studio", country: country)
        }.prefix(4))
        franchises = Array(((collections?["results"] as? [[String: Any]]) ?? []).compactMap { row -> Franchise? in
            guard let id = row["id"] as? Int, id > 0, let name = row["name"] as? String, !name.isEmpty, matches(name) else { return nil }
            return Franchise(id: id, name: name, poster: CatalogTools.image(row["poster_path"] as? String))
        }.prefix(10))
        loadedQuery = query
    }
}

// MARK: Did you mean

/// "Did you mean …?" when a search finds nothing: the closest title name the phone knows (your
/// diary, its catalog, what you viewed), else Wikipedia's spelling suggestion, offered only when
/// TMDB finds something for it. Wikipedia is asked only after a search came back empty.
struct DidYouMeanView: View {
    let query: String
    let choose: (String) -> Void
    @Environment(DiaryStore.self) private var store
    @State private var suggestion: String?

    var body: some View {
        Group {
            if let suggestion {
                Button { choose(suggestion) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass").accessibilityHidden(true)
                        Text("Did you mean \(Text(suggestion).bold())?").multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.font(.body).foregroundStyle(HomeStyle.primary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard()).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("search-did-you-mean")
            }
        }
        .task(id: query) {
            suggestion = nil
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            suggestion = await find()
        }
    }

    private func find() async -> String? {
        let known = store.activeTitles.map(\.name) + PhoneCatalog.shared.titles.values.map(\.name)
            + RecentlyViewed.decode(UserDefaults.standard.string(forKey: RecentlyViewed.storageKey) ?? "[]").map(\.name)
        if let local = SpellingSuggestion.best(for: query, in: known) { return local }
        guard !store.isPreview, let guess = await Self.wikipedia(query), !Task.isCancelled,
              SpellingSuggestion.comparable(guess) != SpellingSuggestion.comparable(query),
              let page = try? await store.searchDiary(guess, page: 1), !Task.isCancelled else { return nil }
        // TMDB's own spelling of it when its first result is that name ("breaking bad" → Breaking Bad).
        if let first = page.online.first, SpellingSuggestion.comparable(first.name) == SpellingSuggestion.comparable(guess) { return first.name }
        return page.online.isEmpty && page.library.isEmpty ? nil : guess
    }

    private static func wikipedia(_ query: String) async -> String? {
        var parts = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        parts?.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "srsearch", value: query),
                             .init(name: "srinfo", value: "suggestion"), .init(name: "srlimit", value: "1"), .init(name: "format", value: "json")]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("TwilDiary/1.0 (iOS app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = (root["query"] as? [String: Any])?["searchinfo"] as? [String: Any],
              let suggestion = info["suggestion"] as? String, !suggestion.isEmpty else { return nil }
        return suggestion
    }
}
