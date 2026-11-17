import SwiftUI
import TwilDiaryCore

private enum SearchTVDBListCatalog {
    static let franchises: [TVDBDirect.Franchise] = [
        list(4, "Marvel Cinematic Universe", "movies/108/posters/108.jpg"),
        list(17, "Star Wars Franchise", "movies/334/posters/334.jpg"),
        list(7038, "Game of Thrones Franchise", "posters/121361-4.jpg"),
        list(13, "Harry Potter Franchise", "movies/66/posters/5ecacb306a644.jpg"),
        list(90, "The Lord of the Rings Franchise", "movies/107/posters/107.jpg"),
        list(6010, "DC Extended Universe", "movies/746/posters/746.jpg"),
        list(6652, "One Chicago", "posters/258541-6.jpg"),
        list(79, "Breaking Bad Franchise", "posters/81189-10.jpg"),
        list(3, "The Matrix Franchise", "movies/169/posters/5f274c00c85c1.jpg"),
        list(23, "Star Trek: Original Timeline", "posters/77526-3.jpg"),
        list(31, "Toy Story Franchise", "v4/movie/318/posters/62718ce691c56.jpg"),
        list(7285, "Demon Slayer: Kimetsu no Yaiba Franchise", "v4/series/348545/posters/60908d475f49a.jpg")
    ]
    static let official: [TVDBDirect.Franchise] = [
        list(7289, "TheTVDB’s Best Shows of 2020", "posters/83268-12.jpg"),
        list(8507, "Pixar SparkShorts", "movies/21097/posters/21097.jpg"),
        list(82, "Based on Jane Austen’s Pride & Prejudice", "posters/65e89fe13b2d3.jpg"),
        list(7221, "Representations of Autism", "v4/series/372611/posters/67a13985b26e9.jpg")
    ]

    private static func list(_ id: Int, _ name: String, _ image: String) -> TVDBDirect.Franchise {
        .init(id: id, name: name, image: "https://artworks.thetvdb.com/banners/" + image, score: nil, isOfficial: true)
    }

    static func isFranchise(_ list: TVDBDirect.Franchise) -> Bool {
        franchises.contains { $0.id == list.id }
            || list.name.localizedStandardContains("franchise")
            || list.name.localizedStandardContains("universe")
            || list.name.localizedStandardContains("Star Trek:")
            || list.name == "Arrowverse"
    }
}

struct SearchTVDBListShelf: View {
    let shelf: SearchBrowseShelf

    var body: some View {
        let lists = shelf == .officialLists ? SearchTVDBListCatalog.official : SearchTVDBListCatalog.franchises
        VStack(alignment: .leading, spacing: 8) {
            SearchBrowseHeading(shelf: shelf)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(lists) { list in
                        SearchTVDBListLink(list: list)
                            .containerRelativeFrame(.horizontal) { width, _ in min(210, width * 0.44) }
                    }
                }.padding(.horizontal, 14)
            }.scrollIndicators(.hidden).padding(.horizontal, -14)
        }
    }
}

struct SearchTVDBListsPage: View {
    let shelf: SearchBrowseShelf
    @State private var text = ""

    var body: some View {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                if shelf == .franchises {
                    SearchField(placeholder: "Find a franchise", text: $text, label: "Find a franchise")
                }
                SearchTVDBLists(shelf: shelf, query: query).id(query)
            }.padding(14).padding(.bottom, 32)
        }.scrollDismissesKeyboard(.interactively)
            .diaryScreenBackground().navigationTitle(shelf.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SearchTVDBLists: View {
    let shelf: SearchBrowseShelf
    let query: String
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var lists: [TVDBDirect.Franchise] = []
    @State private var nextPage: Int? = 0
    @State private var visibleCount = 24
    @State private var loading = false
    @State private var failure: String?

    private var featured: [TVDBDirect.Franchise] {
        let list = shelf == .officialLists ? SearchTVDBListCatalog.official : SearchTVDBListCatalog.franchises
        return list.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        let matching = featured + lists
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                      count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(matching.prefix(visibleCount)) { SearchTVDBListLink(list: $0) }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44).accessibilityLabel("Loading TheTVDB lists")
            } else if let failure {
                RetryNotice(message: failure) { Task { await loadMore() } }
            } else {
                if matching.isEmpty {
                    ContentUnavailableView("No matching lists", systemImage: "film",
                                           description: nextPage == nil ? nil : Text("Load more lists to continue searching."))
                }
                if matching.count > visibleCount || nextPage != nil {
                    Button("Load more lists") {
                        if matching.count > visibleCount { visibleCount += 24 }
                        else { Task { await loadMore() } }
                    }.font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        .cardSurface(14).foregroundStyle(ThemeStore.accent).buttonStyle(.springPress)
                }
            }
        }.task {
            guard nextPage == 0, failure == nil else { return }
            if query.count >= 2 {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            await loadMore()
        }
    }

    private func loadMore() async {
        guard let page = nextPage, !loading else { return }
        if store.isPreview || query.count == 1 { nextPage = nil; return }
        guard let key = TVDBDirect.key(store), !key.isEmpty else {
            failure = "Connect TheTVDB in Profile → Connections."
            return
        }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let result = try await TVDBDirect.franchises(page: page, query: query, key: key)
            try Task.checkCancellation()
            var ids = Set((featured + lists).map(\.id))
            var names = Set((featured + lists).map { Self.nameKey($0.name) })
            lists += result.franchises.filter { list in
                let isFranchise = SearchTVDBListCatalog.isFranchise(list)
                return isFranchise == (shelf == .franchises)
                    && ids.insert(list.id).inserted && names.insert(Self.nameKey(list.name)).inserted
            }
            nextPage = result.hasNext ? page + 1 : nil
            if page > 0 { visibleCount += 24 }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private static func nameKey(_ name: String) -> String {
        String(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .filter { $0.isLetter || $0.isNumber })
    }
}

private struct SearchTVDBListLink: View {
    let list: TVDBDirect.Franchise
    @Environment(DiaryStore.self) private var store
    @State private var art: [String] = []
    @State private var cover: String?
    @State private var count: Int?
    @State private var loadedPreview = false

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.tvdbFranchise(list)) {
            VStack(spacing: 6) {
                let fallback = cover ?? TVDBDirect.artworkURL(list.image)
                SearchListPosterStack(posters: art.isEmpty ? fallback.map { [$0] } ?? [] : art, title: list.name)
                Text(list.name).font(.subheadline.weight(.semibold)).foregroundStyle(HomeStyle.primary)
                    .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                if let count {
                    Text(count == 1 ? "1 title" : "\(count) titles").font(.caption).foregroundStyle(HomeStyle.secondary)
                }
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.springPress).accessibilityIdentifier("search-tvdb-list-\(list.id)")
            .task {
                guard !loadedPreview, !store.isPreview, let key = TVDBDirect.key(store) else { return }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let contents = try await TVDBDirect.listContents(list, key: key)
                    try Task.checkCancellation()
                    cover = contents.artwork
                    count = contents.entries.count
                    var posters: [String] = []
                    for entry in contents.entries.prefix(5) {
                        try Task.checkCancellation()
                        let title = try? await TVDBDirect.title(entry, key: key)
                        try Task.checkCancellation()
                        if let path = TVDBDirect.artworkURL(title?.image), !posters.contains(path) {
                            posters.append(path)
                            art = posters
                        }
                        if posters.count == 3 { break }
                    }
                    loadedPreview = true
                } catch { /* The list remains tappable without its preview. */ }
            }
    }
}

private struct SearchListPosterStack: View {
    let posters: [String]
    let title: String

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width * 0.48
                    ZStack {
                        if posters.indices.contains(1) {
                            poster(posters[1], width: width * 0.89).rotationEffect(.degrees(-9))
                                .offset(x: -width * 0.44, y: 4)
                        }
                        if posters.indices.contains(2) {
                            poster(posters[2], width: width * 0.89).rotationEffect(.degrees(9))
                                .offset(x: width * 0.44, y: 4)
                        }
                        poster(posters.first, width: width)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
    }

    private func poster(_ image: String?, width: CGFloat) -> some View {
        Artwork(path: image, title: title)
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SearchTVDBFranchisePage: View {
    let franchise: TVDBDirect.Franchise
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var entries: [TVDBDirect.ListEntry]?
    @State private var type: MediaKind?
    @State private var visibleCount = 18
    @State private var failure: String?

    private var matching: [TVDBDirect.ListEntry] {
        (entries ?? []).filter { type == nil || $0.kind == type }
    }

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 12) {
                if let entries, !entries.isEmpty {
                    if Set(entries.map(\.kind)).count > 1 {
                        SearchBrowseFilterStrip {
                            Menu {
                                Picker("Title type", selection: $type) {
                                    Text("All titles").tag(nil as MediaKind?)
                                    Text("Movies").tag(Optional(MediaKind.movie))
                                    Text("Shows").tag(Optional(MediaKind.tv))
                                }
                            } label: {
                                ExplorePill(label: type == .movie ? "Movies" : type == .tv ? "Shows" : "All titles",
                                            icon: "film", tinted: type != nil)
                            }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                              count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 16) {
                        ForEach(matching.prefix(visibleCount)) { entry in SearchTVDBTitleCard(entry: entry) }
                    }
                    if matching.count > visibleCount {
                        Button("Load more titles") { visibleCount += 18 }
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                            .cardSurface(14).foregroundStyle(ThemeStore.accent).buttonStyle(.springPress)
                    }
                } else if entries != nil {
                    ContentUnavailableView("No titles in this list", systemImage: "film")
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else {
                    DiaryLoadingPlaceholder(label: "Loading TheTVDB list", layout: .posterGrid(columns: 3, rows: 2))
                }
            }.padding(14).padding(.bottom, 32)
        }.diaryScreenBackground().navigationTitle(franchise.name).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task { if entries == nil, failure == nil { await load() } }
    }

    private func load() async {
        failure = nil
        #if DEBUG
        if store.isPreview { entries = [.init(providerID: 900001, kind: .movie)]; return }
        #endif
        guard let key = TVDBDirect.key(store), !key.isEmpty else {
            failure = "Connect TheTVDB in Profile → Connections."
            return
        }
        do {
            let result = try await TVDBDirect.listContents(franchise, key: key)
            try Task.checkCancellation()
            entries = result.entries
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct SearchTVDBTitleCard: View {
    let entry: TVDBDirect.ListEntry
    @Environment(DiaryStore.self) private var store
    @State private var title: TVDBDirect.ListTitle?
    @State private var failed = false

    var body: some View {
        Group {
            if let title {
                if let id = title.tmdbID {
                    let item = CatalogItem(id: id, mediaType: entry.kind, name: title.name)
                    if let savedID = store.libraryIdentity(item) {
                        NavigationLink(value: savedID) { card(title) }.buttonStyle(.springPress)
                            .accessibilityIdentifier("catalog-\(item.key)")
                    } else {
                        NavigationLink(value: item.route) { card(title) }.buttonStyle(.springPress)
                            .accessibilityIdentifier("catalog-\(item.key)")
                    }
                } else {
                    Link(destination: entry.webLink) { card(title) }.buttonStyle(.springPress)
                        .accessibilityHint("Opens TheTVDB")
                }
            } else if failed {
                Button { Task { await load() } } label: {
                    Label("Retry title", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.springPress)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(HomeStyle.card).aspectRatio(2 / 3, contentMode: .fit)
                    .accessibilityHidden(true)
            }
        }.task {
            guard title == nil, !failed else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await load()
        }
    }

    private func card(_ title: TVDBDirect.ListTitle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(2 / 3, contentMode: .fit)
                .overlay { Artwork(path: title.image, title: title.name) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            ProfileCardCaption(title: title.name)
            if let year = title.year, !year.isEmpty { Text(year).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func load() async {
        failed = false
        #if DEBUG
        if store.isPreview, let item = PreviewCatalog.page(type: entry.kind.rawValue).items.first(where: { $0.id == entry.providerID }) {
            title = .init(name: item.name, image: item.artwork, year: item.year.map { String($0) },
                          remoteIds: [.init(id: String(item.id), sourceName: "TheMovieDB.com")])
            return
        }
        #endif
        guard let key = TVDBDirect.key(store), !key.isEmpty else { failed = true; return }
        do {
            let result = try await TVDBDirect.title(entry, key: key)
            try Task.checkCancellation()
            title = result
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failed = true } }
    }
}
