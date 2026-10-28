import Foundation
import Observation
import TwilDiaryCore

/// A public Trakt list on Canvas, with up to four TMDb poster paths for its collage.
struct CanvasList: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let user: String
    let itemCount: Int
    let likes: Int
    let posters: [String]
}
struct CanvasListsPage: Decodable, Sendable { let lists: [CanvasList]; let page: Int; let totalPages: Int }
struct CanvasListItem: Decodable, Hashable, Sendable {
    let tmdbId: Int
    let mediaType: MediaKind
    let name: String
    let year: Int?
    let posterPath: String?
    let backdropPath: String?
}
struct CanvasListItemsPage: Decodable, Sendable { let items: [CanvasListItem]; let page: Int; let totalPages: Int }
struct CanvasListRoute: Hashable { let id: Int; let name: String; let user: String }

/// Trakt list pages for Canvas. Each filter change starts a new generation, so a late page
/// never lands in a newer filter.
@MainActor @Observable final class CanvasListsLoader {
    private let store: DiaryStore
    private var generation = UUID()
    private var scope: [String: String] = [:]
    private(set) var lists: [CanvasList] = []
    private(set) var page = 0
    private(set) var totalPages = 1
    private(set) var loading = false
    private(set) var error: String?
    init(store: DiaryStore) { self.store = store }
    var hasMore: Bool { page > 0 && page < totalPages }
    func load(sort: String, kind: String, more: Bool = false) async {
        let requested = ["sort": sort, "kind": kind]
        if more && (loading || !hasMore || requested != scope) { return }
        if !more { generation = UUID(); scope = requested; lists = []; page = 0; totalPages = 1 }
        let request = generation, number = more ? page + 1 : 1
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let next: CanvasListsPage
            #if DEBUG
            if store.isPreview { next = PreviewCatalog.canvasLists(page: number) } else { next = try await store.read(CatalogTools.apiPath("/api/canvas/lists", query: requested.merging(["page": String(number)]) { $1 })) }
            #else
            next = try await store.read(CatalogTools.apiPath("/api/canvas/lists", query: requested.merging(["page": String(number)]) { $1 }))
            #endif
            guard generation == request, !Task.isCancelled else { return }
            let known = Set(lists.map(\.id))
            lists += next.lists.filter { !known.contains($0.id) }
            page = next.page; totalPages = next.totalPages
        } catch is CancellationError { }
        catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

/// The titles on one Trakt list, as catalog items that open the saved title when it is in the library.
@MainActor @Observable final class CanvasListItemsLoader {
    private let store: DiaryStore
    private let id: Int
    private(set) var items: [CatalogItem] = []
    private(set) var page = 0
    private(set) var totalPages = 1
    private(set) var loading = false
    private(set) var error: String?
    init(store: DiaryStore, id: Int) { self.store = store; self.id = id }
    var hasMore: Bool { page > 0 && page < totalPages }
    func load(more: Bool = false) async {
        if loading || (more && !hasMore) || (!more && page > 0) { return }
        let number = more ? page + 1 : 1
        loading = true; error = nil
        defer { loading = false }
        do {
            let next: CanvasListItemsPage
            #if DEBUG
            if store.isPreview { next = PreviewCatalog.canvasListItems(page: number) } else { next = try await store.read("/api/canvas/lists/\(id)?page=\(number)") }
            #else
            next = try await store.read("/api/canvas/lists/\(id)?page=\(number)")
            #endif
            let library = Dictionary(store.workspace.activeTitles.compactMap { title in title.tmdbId.map { ((title.isSeries ? "tv:" : "movie:") + String($0), title.id) } }, uniquingKeysWith: { first, _ in first })
            let converted = next.items.map { item in
                CatalogItem(id: item.tmdbId, mediaType: item.mediaType, name: item.name, year: item.year, posterPath: item.posterPath, backdropPath: item.backdropPath,
                            inLibraryId: library[item.mediaType.rawValue + ":" + String(item.tmdbId)])
            }
            items = CatalogTools.merging(items, converted)
            page = next.page; totalPages = next.totalPages
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
