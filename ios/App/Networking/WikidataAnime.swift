import Foundation
import TwilDiaryCore

/// Wikidata links AniList anime (P8729) to TMDB: the show (P4983) or film (P4947), on the item
/// itself or on the series it belongs to (P179 / P361). TMDB keeps every season under one show,
/// while AniList gives each season or part its own entry, so a name-and-year search misses later
/// seasons. Profile pages ask once for all their anime, so a tap usually opens at once.
/// Public data: a request carries only AniList ids, nothing from the diary. Answers, including
/// "no link", are kept for the session.
actor WikidataAnime {
    static let shared = WikidataAnime()
    struct Anime: Hashable, Sendable {
        let id: Int
        /// AniList's format: a MOVIE only takes a TMDB film.
        let format: String?
    }
    struct Row: Hashable, Sendable {
        let anime: Int
        var show: Int? = nil, film: Int? = nil, seriesShow: Int? = nil
    }
    private var known: [Int: CatalogRoute?] = [:]
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func route(_ anime: Anime) async -> CatalogRoute? { await routes([anime])[anime.id] }
    /// The known TMDB routes for these anime; one request covers the ones not asked about before.
    @discardableResult func routes(_ anime: [Anime]) async -> [Int: CatalogRoute] {
        var seen = Set<Int>()
        let ask = anime.filter { $0.id > 0 && known[$0.id] == nil && seen.insert($0.id).inserted }.prefix(150)
        if !ask.isEmpty, let url = Self.url(ask.map(\.id)), let rows = await fetch(url) {
            let found = Self.routes(rows, for: Array(ask))
            for item in ask { known.updateValue(found[item.id], forKey: item.id) }
        }
        return anime.reduce(into: [:]) { result, item in
            if let route = known[item.id] ?? nil { result[item.id] = route }
        }
    }

    static func url(_ ids: [Int]) -> URL? {
        let values = ids.map { "\"\($0)\"" }.joined(separator: " ")
        let query = "SELECT ?x ?tv ?mv ?ptv WHERE { VALUES ?x { \(values) } ?a wdt:P8729 ?x . "
            + "OPTIONAL { ?a wdt:P4983 ?tv } OPTIONAL { ?a wdt:P4947 ?mv } "
            + "OPTIONAL { ?a (wdt:P179|wdt:P361) ?s . ?s wdt:P4983 ?ptv } }"
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")
        parts?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        return parts?.url
    }
    static func rows(_ data: Data) -> [Row]? {
        struct Reply: Decodable {
            let results: Results
            struct Results: Decodable { let bindings: [[String: Value]] }
            struct Value: Decodable { let value: String }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return reply.results.bindings.compactMap { row in
            guard let anime = row["x"].flatMap({ Int($0.value) }) else { return nil }
            func id(_ key: String) -> Int? { row[key].flatMap { Int($0.value) }.flatMap { $0 > 0 ? $0 : nil } }
            return Row(anime: anime, show: id("tv"), film: id("mv"), seriesShow: id("ptv"))
        }
    }
    /// One TMDB entry per anime or none: the item's own link first, then its series' link.
    /// A film opens only a TMDB film; anything else prefers the show. Two candidates: none.
    static func routes(_ rows: [Row], for anime: [Anime]) -> [Int: CatalogRoute] {
        let grouped = Dictionary(grouping: rows, by: \.anime)
        var result: [Int: CatalogRoute] = [:]
        for item in anime {
            let found = grouped[item.id] ?? []
            func single(_ path: KeyPath<Row, Int?>) -> Int? {
                let ids = Set(found.compactMap { $0[keyPath: path] })
                return ids.count == 1 ? ids.first : nil
            }
            func has(_ path: KeyPath<Row, Int?>) -> Bool { found.contains { $0[keyPath: path] != nil } }
            let route: CatalogRoute?
            if item.format == "MOVIE" {
                route = single(\.film).map { CatalogRoute(kind: .movie, id: $0) }
            } else if has(\.show) {
                route = single(\.show).map { CatalogRoute(kind: .tv, id: $0) }
            } else if has(\.film) {
                route = single(\.film).map { CatalogRoute(kind: .movie, id: $0) }
            } else {
                route = single(\.seriesShow).map { CatalogRoute(kind: .tv, id: $0) }
            }
            if let route { result[item.id] = route }
        }
        return result
    }
    /// nil: the request failed, so these anime are asked about again next time.
    private func fetch(_ url: URL) async -> [Row]? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue("TwilDiary/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.rows(data)
    }
}
