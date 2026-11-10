import Foundation
import TwilDiaryCore

/// The "view all" pages a show page opens.
enum ShowPageRoute: Hashable {
    case episodes(titleID: String, season: Int)
    case cast(CatalogRoute, title: String, anime: Bool, year: Int?)
    case lists(CatalogRoute, title: String)
    /// Related collections: the movie's TMDb collection, then TMDb's catalogue for each genre.
    case collections(CatalogRoute, title: String, anime: Bool)
    /// One TMDb collection's films.
    case tmdbCollection(id: Int, name: String)
    /// Every TMDB recommendation for a title (More like this).
    case related(CatalogRoute, title: String)
    /// "Show all N episodes" on a preview page (a title not in the diary).
    case catalogEpisodes(CatalogRoute, season: Int)
    case companies(CatalogRoute, title: String)
}

/// Companies, networks, tags, status, age rating and crew for a title page, from
/// `GET /api/metadata/extras`. Kept for a day: they rarely change, and the page is opened often.
@MainActor enum TitleExtrasCache {
    private static var cache: [CatalogRoute: (at: Date, value: TitleExtras)] = [:]
    static func cached(_ route: CatalogRoute) -> TitleExtras? { cache[route]?.value }
    static func load(store: DiaryStore, route: CatalogRoute) async throws -> TitleExtras {
        if let entry = cache[route], Date.now.timeIntervalSince(entry.at) < 86_400 { return entry.value }
        if store.isPreview {
            #if DEBUG
            // Design screenshots: a realistic set, so Tags, chips and Related collections draw.
            if ProcessInfo.processInfo.arguments.contains("--ui-design-data") {
                let tags = ["detective", "female protagonist", "work", "maid", "politics", "historical", "mystery", "palace", "medicine", "court", "poison", "apothecary"]
                return TitleExtras(status: "Ended", certification: "TV-14", studios: [],
                                   networks: [TitleCompany(id: 614, name: "KBS2", logoPath: nil, kind: "network", country: "KR")],
                                   keywords: tags.enumerated().map { TitleKeyword(id: 9000 + $0.offset, name: $0.element) },
                                   genres: [TitleKeyword(id: 18, name: "Drama"), TitleKeyword(id: 10749, name: "Romance"), TitleKeyword(id: 35, name: "Comedy")])
            }
            #endif
            return TitleExtras(status: nil, certification: nil, studios: [], networks: [], keywords: [])
        }
        // Straight from TMDB with your key; the diary server is only the backup.
        let value: TitleExtras
        if let token = TMDBDirect.token(store), let direct = try? await TMDBDirect.extras(route, token: token) { value = direct.0 }
        else { value = try await store.read(CatalogTools.apiPath("/api/metadata/extras", query: ["type": route.kind.rawValue, "id": String(route.id)])) }
        if cache.count >= 200 { cache.removeAll() }
        cache[route] = (.now, value)
        return value
    }
}

/// Trakt lists containing a title, with poster collages, from Canvas's list endpoint.
@MainActor enum TitleListsCache {
    private static var cache: [String: (at: Date, value: [CanvasList])] = [:]
    /// `sort` is "popular" or "updated".
    static func load(store: DiaryStore, route: CatalogRoute, sort: String) async throws -> [CanvasList] {
        let key = route.kind.rawValue + ":" + String(route.id) + ":" + sort
        if let entry = cache[key], Date.now.timeIntervalSince(entry.at) < 3_600 { return entry.value }
        if store.isPreview { return [] }
        let page: CanvasListsPage = try await store.read(CatalogTools.apiPath("/api/canvas/lists", query: [
            "title": route.kind.rawValue + ":" + String(route.id), "sort": sort, "kind": "all"
        ]), timeout: 30)
        if cache.count >= 100 { cache.removeAll() }
        cache[key] = (.now, page.lists)
        return page.lists
    }
}

/// Trakt's per-episode community ratings and your own lists, read with your Trakt sign-in.
@MainActor enum TraktTitleReads {
    private static var traktIDs: [CatalogRoute: Int] = [:]
    private static var seasonRatings: [String: (at: Date, value: [EpisodeRatingPoint])] = [:]

    static func traktID(_ client: TraktDirectClient, route: CatalogRoute) async throws -> Int? {
        if let id = traktIDs[route] { return id }
        let kind = route.kind == .tv ? "show" : "movie"
        let data = try await client.get("/search/tmdb/\(route.id)", query: ["type": kind]).data
        let found = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        let ids = found.compactMap { ($0[kind] as? [String: Any])?["ids"] as? [String: Any] }
            .first { ($0["tmdb"] as? Int) == route.id }
        guard let id = ids?["trakt"] as? Int, id > 0 else { return nil }
        traktIDs[route] = id
        return id
    }

    /// Trakt's average rating for each episode of a season (episodes nobody rated are left out).
    static func episodeRatings(store: DiaryStore, show: Int, season: Int) async throws -> [EpisodeRatingPoint] {
        let key = "\(show):\(season)"
        if let entry = seasonRatings[key], Date.now.timeIntervalSince(entry.at) < 21_600 { return entry.value }
        let client = try await TraktDirectStore.shared.client(store: store)
        guard let id = try await traktID(client, route: CatalogRoute(kind: .tv, id: show)) else { return [] }
        let data = try await client.get("/shows/\(id)/seasons/\(season)", query: ["extended": "full"]).data
        let episodes = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        let points = episodes.compactMap { item -> EpisodeRatingPoint? in
            guard let number = item["number"] as? Int, let rating = (item["rating"] as? NSNumber)?.doubleValue,
                  ((item["votes"] as? Int) ?? 0) > 0 else { return nil }
            return EpisodeRatingPoint(episode: number, score: rating)
        }
        if seasonRatings.count >= 60 { seasonRatings.removeAll() }
        seasonRatings[key] = (.now, points)
        return points
    }

    /// Trakt's episode ratings already read for a season (number → rating), without asking again.
    static func cachedRatings(show: Int, season: Int) -> [Int: Double] {
        Dictionary((seasonRatings["\(show):\(season)"]?.value ?? []).map { ($0.episode, $0.score) }, uniquingKeysWith: { first, _ in first })
    }

    /// Your own Trakt lists that contain the title (at most 12 lists are checked).
    static func yourLists(store: DiaryStore, route: CatalogRoute) async throws -> [CanvasList] {
        let client = try await TraktDirectStore.shared.client(store: store)
        let data = try await client.get("/users/me/lists").data
        let lists = ((try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []).prefix(12)
        let kind = route.kind == .tv ? "show" : "movie"
        var result: [CanvasList] = []
        for list in lists {
            guard let ids = list["ids"] as? [String: Any], let id = ids["trakt"] as? Int, let name = list["name"] as? String else { continue }
            guard let items = try? await client.get("/users/me/lists/\(id)/items/\(kind)").data,
                  let entries = try? JSONSerialization.jsonObject(with: items) as? [[String: Any]] else { continue }
            let contains = entries.contains { (($0[kind] as? [String: Any])?["ids"] as? [String: Any])?["tmdb"] as? Int == route.id }
            guard contains else { continue }
            let user = (list["user"] as? [String: Any])?["username"] as? String ?? client.token.username
            result.append(CanvasList(id: id, name: name, user: user, itemCount: list["item_count"] as? Int ?? entries.count,
                                     likes: list["likes"] as? Int ?? 0, posters: []))
        }
        return result
    }

    /// Rates one episode on Trakt (1–10). The phone remembers it so the sheet shows it at once.
    static func rateEpisode(store: DiaryStore, show: Int, season: Int, episode: Int, episodeID: String, rating: Int?) async throws {
        var saved = EpisodeRatings.all
        let body: [String: Any] = ["shows": [["ids": ["tmdb": show], "seasons": [["number": season, "episodes": [rating.map { ["number": episode, "rating": $0] } ?? ["number": episode]]]]]]]
        try await TraktDirectStore.shared.write(rating == nil ? "/sync/ratings/remove" : "/sync/ratings", body: body, store: store)
        saved[episodeID] = rating
        EpisodeRatings.all = saved
    }
}

/// Your episode ratings, kept on this iPhone (the diary itself rates whole titles).
enum EpisodeRatings {
    static var all: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "episodeRatings") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "episodeRatings") }
    }
}
