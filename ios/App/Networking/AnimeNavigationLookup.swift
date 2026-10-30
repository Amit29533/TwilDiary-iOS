import Foundation
import TwilDiaryCore

@MainActor protocol AnimeNavigationServing {
    var workspace: Workspace { get }
    var sessionRevision: UUID { get }
    func searchDiary(_ query: String, page: Int) async throws -> DiarySearchPage
    func cast(_ route: CatalogRoute) async throws -> CastResponse
    func knownAnimeRoute(_ id: Int) async -> CatalogRoute?
    func knownPersonID(_ id: Int) async -> Int?
}
extension AnimeNavigationServing {
    func knownAnimeRoute(_ id: Int) async -> CatalogRoute? { nil }
    func knownPersonID(_ id: Int) async -> Int? { nil }
}
extension DiaryStore: AnimeNavigationServing {
    func knownAnimeRoute(_ id: Int) async -> CatalogRoute? { await AniListClient.shared.tmdbTitle(id) }
    func knownPersonID(_ id: Int) async -> Int? { await AniListClient.shared.tmdbPerson(id) }
}

struct AnimeNavigationResult {
    let destination: AnimeTitleDestination?
    let page: DiarySearchPage
}

/// Resolve before pushing a page. Successful lookups are scoped to the signed-in
/// diary and cached briefly so returning to a cast/character page feels immediate.
@MainActor final class AnimeNavigationLookup {
    private var scope: UUID?
    private var pages: [Int: (at: Date, page: DiarySearchPage)] = [:]
    private var people: [Int: Int] = [:]
    private let now: () -> Date
    init(now: @escaping () -> Date = Date.init) { self.now = now }

    private func synchronize(_ value: UUID) {
        if scope != value { scope = value; pages = [:]; people = [:] }
    }
    func rememberPerson(_ aniListID: Int, tmdbID: Int?, scope: UUID) {
        synchronize(scope)
        if let tmdbID, tmdbID > 0 { people[aniListID] = tmdbID }
    }
    func title(_ appearance: AniAppearance, service: any AnimeNavigationServing) async throws -> AnimeNavigationResult {
        let revision = service.sessionRevision; synchronize(revision)
        let local = AnimeTitleMatching.saved(service.workspace.activeTitles, names: appearance.names, year: appearance.year, kind: appearance.kind)
        let empty = DiarySearchPage(library: local.map(SearchLibraryTitle.init), online: [], page: 1, totalPages: 1)
        if local.count == 1 { return AnimeNavigationResult(destination: .saved(local[0].id), page: empty) }
        if local.count > 1 { return AnimeNavigationResult(destination: nil, page: empty) }
        let knownRoute = await service.knownAnimeRoute(appearance.id)
        try Task.checkCancellation()
        guard revision == service.sessionRevision else { throw CancellationError() }
        if let route = knownRoute {
            let saved = service.workspace.activeTitles.first { $0.tmdbId == route.id && $0.isSeries == (route.kind == .tv) }
            return AnimeNavigationResult(destination: saved.map { .saved($0.id) } ?? .catalog(route), page: empty)
        }
        if let cached = pages[appearance.id], now().timeIntervalSince(cached.at) < 300 {
            // A title trashed since the lookup must not be reopened from cached diary results.
            let staleID = cached.page.library.contains { row in
                service.workspace.titles.contains { $0.id == row.id && $0.deletedAt != nil }
            }
            if !staleID { return result(cached.page, appearance: appearance, workspace: service.workspace) }
        }
        var library: [SearchLibraryTitle] = [], online: [CatalogItem] = []
        var searched = Set<String>()
        for name in appearance.names {
            let query = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard DiarySearchTools.ready(query), searched.insert(query.lowercased()).inserted else { continue }
            let page = try await service.searchDiary(query, page: 1)
            try Task.checkCancellation()
            guard revision == service.sessionRevision else { throw CancellationError() }
            if !page.onlineError.isEmpty { throw APIError.message(page.onlineError) }
            library = AnimeTitleMatching.libraryChoices(library, page: page, kind: appearance.kind)
            online = CatalogTools.merging(online, page.online).filter { appearance.kind == nil || $0.mediaType == appearance.kind }
            let merged = DiarySearchPage(library: library, online: online, page: 1, totalPages: page.totalPages)
            let found = result(merged, appearance: appearance, workspace: service.workspace)
            if found.destination != nil || searched.count == 2 {
                remember(merged, for: appearance); return found
            }
        }
        let merged = DiarySearchPage(library: library, online: online, page: 1, totalPages: 1)
        if !library.isEmpty || !online.isEmpty { remember(merged, for: appearance) }
        return result(merged, appearance: appearance, workspace: service.workspace)
    }
    private func result(_ page: DiarySearchPage, appearance: AniAppearance, workspace: Workspace) -> AnimeNavigationResult {
        var destination = AnimeTitleMatching.destination(page: page, names: appearance.names, year: appearance.year, kind: appearance.kind)
        if case .catalog(let route)? = destination,
           let saved = workspace.activeTitles.first(where: { $0.tmdbId == route.id && $0.isSeries == (route.kind == .tv) }) {
            destination = .saved(saved.id)
        }
        return AnimeNavigationResult(destination: destination, page: page)
    }
    private func remember(_ page: DiarySearchPage, for appearance: AniAppearance) {
        if pages.count >= 64, pages[appearance.id] == nil, let oldest = pages.min(by: { $0.value.at < $1.value.at })?.key { pages.removeValue(forKey: oldest) }
        pages[appearance.id] = (now(), page)
    }
    func person(_ actor: AniVoiceActorDetail, knownID: Int?, service: any AnimeNavigationServing) async throws -> Int {
        let revision = service.sessionRevision; synchronize(revision)
        if let knownID, knownID > 0 { people[actor.id] = knownID; return knownID }
        if let id = people[actor.id] { return id }
        let knownPerson = await service.knownPersonID(actor.id)
        try Task.checkCancellation()
        guard revision == service.sessionRevision else { throw CancellationError() }
        if let id = knownPerson, id > 0 {
            people[actor.id] = id; return id
        }
        var seen = Set<Int>()
        let roles = actor.roles.filter { seen.insert($0.animeID).inserted }
        for role in roles.prefix(2) {
            let appearance = AniAppearance(id: role.animeID, title: role.anime, cover: role.cover, year: role.year,
                                           role: role.role, voiceActor: nil, format: role.format, alternateTitles: role.alternateTitles)
            let found = try await title(appearance, service: service)
            var route: CatalogRoute?
            switch found.destination {
            case .catalog(let value)?: route = value
            case .saved(let id)?:
                route = service.workspace.activeTitles.first { $0.id == id }.flatMap { title in
                    title.tmdbId.map { CatalogRoute(kind: title.isSeries ? .tv : .movie, id: $0) }
                }
            case nil: route = nil
            }
            // Legacy/local anime can match by name without having a TMDB identity.
            // Reuse a confirmed bridge or an exact catalog result to read credits.
            if route == nil, case .saved(_)? = found.destination {
                route = await service.knownAnimeRoute(role.animeID)
                try Task.checkCancellation()
                guard revision == service.sessionRevision else { throw CancellationError() }
                if route == nil, DiarySearchTools.ready(role.anime) {
                    let page = try await service.searchDiary(role.anime, page: 1)
                    try Task.checkCancellation()
                    guard revision == service.sessionRevision else { throw CancellationError() }
                    if !page.onlineError.isEmpty { throw APIError.message(page.onlineError) }
                    route = AnimeTitleMatching.catalog(page.online, names: appearance.names, year: role.year, kind: appearance.kind)?.route
                }
            }
            guard let route else { continue }
            let credits = try await service.cast(route)
            try Task.checkCancellation()
            guard revision == service.sessionRevision else { throw CancellationError() }
            if let id = PersonIdentityMatching.uniqueID(in: credits.cast, names: [actor.name] + [actor.native].compactMap { $0 }) {
                people[actor.id] = id; return id
            }
        }
        throw APIError.message("A matching TMDB profile could not be identified from this actor’s credits. Please try again later.")
    }
}
