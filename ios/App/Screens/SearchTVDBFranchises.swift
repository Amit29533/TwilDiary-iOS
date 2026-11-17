import SwiftUI
import TwilDiaryCore

struct SearchTVDBFranchises: View {
    let query: String
    @Environment(DiaryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    private static let featured: [TVDBDirect.Franchise] = [
        .init(id: 4, name: "Marvel Cinematic Universe", image: "https://artworks.thetvdb.com/banners/movies/108/posters/108.jpg",
              score: nil, isOfficial: true),
        .init(id: 7038, name: "Game of Thrones Franchise", image: "https://artworks.thetvdb.com/banners/posters/121361-4.jpg",
              score: nil, isOfficial: true),
        .init(id: 13, name: "Harry Potter Franchise", image: "https://artworks.thetvdb.com/banners/movies/66/posters/66.jpg",
              score: nil, isOfficial: true)
    ]
    @State private var lists: [TVDBDirect.Franchise] = []
    @State private var nextPage: Int? = 0
    @State private var visibleCount = 24
    @State private var loading = false
    @State private var failure: String?

    private var matching: [TVDBDirect.Franchise] {
        let featured = Self.featured.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        return featured + lists
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                      count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(matching.prefix(visibleCount)) { franchise in
                    NavigationLink(value: SearchBrowseRoute.tvdbFranchise(franchise)) {
                        ZStack(alignment: .bottomLeading) {
                            if let image = franchise.image, !image.isEmpty {
                                Artwork(path: image, title: franchise.name)
                                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                            } else {
                                LinearGradient(colors: [HomeStyle.round, HomeStyle.card], startPoint: .topTrailing, endPoint: .bottomLeading)
                                Image(systemName: "square.stack")
                                    .font(.title2).foregroundStyle(HomeStyle.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                                    .accessibilityHidden(true)
                            }
                            Text(franchise.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .lineLimit(3).padding(12)
                        }.frame(minHeight: 116).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.springPress)
                }
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
            let matchingFeatured = Self.featured.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            var ids = Set((matchingFeatured + lists).map(\.id))
            lists += result.franchises.filter { ids.insert($0.id).inserted }
            nextPage = result.hasNext ? page + 1 : nil
            if page > 0 { visibleCount += 24 }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
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
        if store.isPreview { entries = []; return }
        guard let key = TVDBDirect.key(store), !key.isEmpty else {
            failure = "Connect TheTVDB in Profile → Connections."
            return
        }
        do {
            let result = try await TVDBDirect.entries(franchise, key: key)
            try Task.checkCancellation()
            entries = result
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
                    NavigationLink(value: CatalogRoute(kind: entry.kind, id: id)) { card(title) }.buttonStyle(.springPress)
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
        guard let key = TVDBDirect.key(store), !key.isEmpty else { failed = true; return }
        do {
            let result = try await TVDBDirect.title(entry, key: key)
            try Task.checkCancellation()
            title = result
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failed = true } }
    }
}
