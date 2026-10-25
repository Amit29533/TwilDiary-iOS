import Foundation
import Observation
import TwilDiaryCore

@MainActor protocol DiscoveryServing {
    func page(_ query: [String: String]) async throws -> CatalogPage
    func page(_ query: [String: String], refresh: Bool) async throws -> CatalogPage
    func traktConnected() async throws -> Bool
    var recommendationScope: UUID? { get }
    var recommendationOwner: String? { get }
    func cachedRecommendations(limit: Int) -> [CatalogItem]?
}

extension DiscoveryServing {
    func page(_ query: [String: String], refresh: Bool) async throws -> CatalogPage { try await page(query) }
    var recommendationScope: UUID? { nil }
    var recommendationOwner: String? { nil }
    func cachedRecommendations(limit: Int) -> [CatalogItem]? { nil }
}

@MainActor final class LiveDiscoveryService: DiscoveryServing {
    private let store: DiaryStore
    init(store: DiaryStore) { self.store = store }
    var recommendationScope: UUID? { store.discoveryRevision }
    var recommendationOwner: String? { store.discoveryCache.account }
    func page(_ query: [String: String]) async throws -> CatalogPage { try await page(query, refresh: false) }
    func page(_ query: [String: String], refresh: Bool) async throws -> CatalogPage {
        guard !store.needsSignIn else { store.discoveryCache.reset(); throw APIError.signIn }
        let revision = store.discoveryRevision
        let key = CatalogTools.apiPath("/api/discovery", query: query)
        let result = try await store.discoveryCache.page(key, scope: revision, personal: query["source"] == "trakt", refresh: refresh) { [store] in
            #if DEBUG
            if store.isPreview { return PreviewCatalog.discovery(query) }
            #endif
            return try await store.read(key)
        }
        guard revision == store.discoveryRevision, !store.needsSignIn else { throw CancellationError() }
        return reconcileLibrary(result)
    }
    func traktConnected() async throws -> Bool {
        guard !store.needsSignIn else { store.discoveryCache.reset(); throw APIError.signIn }
        if store.isPreview { return false }
        let revision = store.discoveryRevision
        let status = try await store.discoveryCache.status(scope: revision) { [store] in try await store.read("/api/trakt/status") }
        guard revision == store.discoveryRevision, !store.needsSignIn else { throw CancellationError() }
        let connected = status.connected && !status.needsReconnect
        store.discoveryCache.activateAccount(connected ? status.username : nil)
        return connected
    }
    func cachedRecommendations(limit: Int) -> [CatalogItem]? {
        guard !store.needsSignIn, store.discoveryCache.account != nil else { return nil }
        var items: [CatalogItem] = [], found = false
        for kind in [MediaKind.movie, .tv] {
            let path = CatalogTools.apiPath("/api/discovery", query: Self.recommendationQuery(kind))
            if let saved = store.discoveryCache.cached(path, scope: store.discoveryRevision, personal: true, allowStale: true) {
                found = true; items += reconcileLibrary(saved).items.prefix(max(1, min(24, limit)))
            }
        }
        return found ? CatalogTools.merging([], items) : nil
    }
    static func recommendationQuery(_ kind: MediaKind) -> [String: String] {
        var filters = DiscoveryFilters(section: .recommended); filters.type = kind.rawValue
        return filters.query(section: .recommended, limit: 24)
    }
    private func reconcileLibrary(_ page: CatalogPage) -> CatalogPage {
        // Cache metadata, but derive routing from the current active library.
        let pairs = store.workspace.activeTitles.compactMap { title -> (String, String)? in
            guard let id = title.tmdbId else { return nil }
            return ((title.isSeries ? "tv:" : "movie:") + String(id), title.id)
        }
        let ids = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let items = page.items.map { item in
            CatalogItem(id: item.id, mediaType: item.mediaType, name: item.name, year: item.year, overview: item.overview, posterPath: item.posterPath, backdropPath: item.backdropPath, rating: item.rating, votes: item.votes, genres: item.genres ?? [], inLibraryId: ids[item.key], poster: item.poster, backdrop: item.backdrop, character: item.character, job: item.job, popularity: item.popularity, episodeCount: item.episodeCount)
        }
        return CatalogPage(items: items, page: page.page, totalPages: page.totalPages)
    }
}

/// Each grid/shelf owns a generation, so a late page never overwrites a newer filter.
@MainActor @Observable final class DiscoveryResults {
    private let service: any DiscoveryServing
    private var generation = UUID()
    private var scope: [String: String] = [:]
    private(set) var items: [CatalogItem] = []
    private(set) var page = 0
    private(set) var totalPages = 1
    private(set) var loading = false
    private(set) var error: String?
    init(service: any DiscoveryServing) { self.service = service }
    var hasMore: Bool { page > 0 && page < min(500, totalPages) }
    func clear() { generation = UUID(); scope = [:]; items = []; page = 0; totalPages = 1; loading = false; error = nil }
    func load(_ query: [String: String], more: Bool = false) async {
        if more && (loading || !hasMore) { return }
        var requested = query; requested.removeValue(forKey: "page")
        if more && requested != scope { return }
        if !more { clear(); scope = requested }
        let request = generation, number = more ? page + 1 : 1
        requested["page"] = String(number)
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let next = try await service.page(requested)
            guard generation == request, !Task.isCancelled else { return }
            guard next.page == number else { throw APIError.message("The catalog returned an unexpected page. Retry before continuing.") }
            items = CatalogTools.merging(more ? items : [], next.items)
            page = next.page; totalPages = next.totalPages
        } catch is CancellationError { }
        catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor @Observable final class DiscoveryRecommendations {
    private let service: any DiscoveryServing
    private var generation = UUID()
    private var scope: UUID?
    private var owner: String?
    private(set) var items: [CatalogItem] = []
    private(set) var loading = false
    private(set) var connected = false
    private(set) var error: String?
    init(service: any DiscoveryServing) { self.service = service }
    func load(limit: Int = 8, refresh: Bool = false) async {
        let request = UUID(); generation = request
        let requestedScope = service.recommendationScope
        if scope != requestedScope { items = []; connected = false; scope = requestedScope; owner = nil }
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let available = try await service.traktConnected()
            guard generation == request, requestedScope == service.recommendationScope, !Task.isCancelled else { return }
            let account = service.recommendationOwner
            if owner != account { items = []; owner = account }
            connected = available
            guard available else { items = []; return }
            if let saved = service.cachedRecommendations(limit: limit) { items = saved }
            let retained = items
            async let movie = fetch(.movie, refresh: refresh)
            async let television = fetch(.tv, refresh: refresh)
            let (movies, shows) = try await (movie, television)
            guard generation == request, requestedScope == service.recommendationScope, account == service.recommendationOwner, !Task.isCancelled else { return }
            let bound = max(1, min(24, limit))
            let movieItems = movies.items ?? retained.filter { $0.mediaType == .movie }
            let showItems = shows.items ?? retained.filter { $0.mediaType == .tv }
            items = CatalogTools.merging([], Array(movieItems.prefix(bound)) + Array(showItems.prefix(bound)))
            if movies.error != nil && shows.error != nil { error = movies.error }
            else if movies.error != nil || shows.error != nil { error = "Some recommendations could not load." }
        } catch is CancellationError { }
        catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private struct KindResult: Sendable { let items: [CatalogItem]?; let error: String? }
    private func fetch(_ kind: MediaKind, refresh: Bool) async throws -> KindResult {
        do {
            let page = try await service.page(LiveDiscoveryService.recommendationQuery(kind), refresh: refresh)
            guard page.page == 1 else { throw APIError.message("The recommendations returned an unexpected page. Please retry.") }
            return KindResult(items: page.items, error: nil)
        } catch is CancellationError { throw CancellationError() }
        catch { return KindResult(items: nil, error: error.localizedDescription) }
    }
}
