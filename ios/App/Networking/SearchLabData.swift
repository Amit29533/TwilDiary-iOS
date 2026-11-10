import SwiftUI
import TwilDiaryCore

/// Search Lab's reads. With your TMDB key they go straight to TMDB from this iPhone, which is what
/// makes TV age ratings, "All titles", "Most popular" and the keyword search work; without a key the
/// diary server's discovery is the backup (movie age ratings only, one type at a time).
@MainActor enum SearchLabData {
    static let tvRatings = ["TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA"]
    static let movieRatings = ["G", "PG", "PG-13", "R", "NC-17"]
    static func ratings(type: String) -> [String] { type == "tv" ? tvRatings : type == "movie" ? movieRatings : tvRatings + movieRatings }
    /// The year slider's left end; "Older" (a decade chip) reaches further back.
    static let lowestYear = 1990
    static var highestYear: Int { Calendar.current.component(.year, from: .now) }
    /// TMDB has no TV genre for these; shows are found by TMDB's keyword of the same name (as the server does).
    static let tvGenreKeywords: [String: Int] = ["Romance": 9840]

    /// The media types a set of filters can match. "All titles" reads shows and movies together,
    /// unless a filter only one of them has (a show status, a TV or film age rating, a genre only
    /// one side has) narrows it.
    static func kinds(_ filters: DiscoveryFilters) -> [MediaKind] {
        if filters.type == "tv" { return [.tv] }
        if filters.type == "movie" { return [.movie] }
        var tv = true, movie = true
        if filters.showStatus != nil { movie = false }
        if let rating = filters.certification { if tvRatings.contains(rating) { movie = false } else { tv = false } }
        for name in filters.genres ?? [] {
            guard let genre = DiscoveryGenre.all.first(where: { $0.name == name }) else { continue }
            if genre.tv == nil && tvGenreKeywords[name] == nil { tv = false }
            if genre.movie == nil { movie = false }
        }
        return (tv ? [.tv] : []) + (movie ? [.movie] : [])
    }

    /// One page of matches; "All titles" reads the same page of shows and of movies and mixes them.
    static func page(_ filters: DiscoveryFilters, page: Int, store: DiaryStore) async throws -> CatalogPage {
        let kinds = kinds(filters)
        if kinds.count == 2 {
            async let shows = one(filters, kind: .tv, page: page, store: store)
            async let movies = one(filters, kind: .movie, page: page, store: store)
            return merge(try await shows, try await movies, sort: filters.sort)
        }
        guard let kind = kinds.first else { return CatalogPage(items: [], page: 1, totalPages: 1, totalResults: 0) }
        return try await one(filters, kind: kind, page: page, store: store)
    }

    /// Whether a title found by the keyword search fits the filters a search result can show.
    static func matches(_ item: CatalogItem, _ filters: DiscoveryFilters, kind: MediaKind) -> Bool {
        let wanted = (filters.genres ?? []).filter { name in
            DiscoveryGenre.all.first { $0.name == name }.map { (kind == .movie ? $0.movie : $0.tv) != nil } ?? false
        }
        if !wanted.allSatisfy({ item.genres?.contains($0) == true }) { return false }
        if let minimum = Double(filters.minimum), minimum > 0, (item.rating ?? 0) < minimum { return false }
        if let from = filters.yearFrom, (item.year ?? 0) < from { return false }
        if let to = filters.yearTo, (item.year ?? 9999) > to { return false }
        return true
    }

    private static func one(_ filters: DiscoveryFilters, kind: MediaKind, page: Int, store: DiaryStore) async throws -> CatalogPage {
        if !store.isPreview, let token = TMDBDirect.token(store) { return try await TMDBDirect.lab(filters, kind: kind, page: page, token: token) }
        let text = filters.searchText
        if !text.isEmpty {
            let found = try await store.searchDiary(text, page: page)
            return CatalogPage(items: found.online.filter { $0.mediaType == kind && matches($0, filters, kind: kind) }, page: found.page, totalPages: found.totalPages)
        }
        var server = filters
        server.type = kind == .movie ? "movie" : "tv"
        if server.sort == "votes" { server.sort = "popular" }
        return try await LiveDiscoveryService(store: store).page(server.query(section: .genres, page: page))
    }

    private static func merge(_ shows: CatalogPage, _ movies: CatalogPage, sort: String) -> CatalogPage {
        let a = shows.items, b = movies.items
        var items: [CatalogItem] = []
        switch sort {
        case "rating": items = (a + b).sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case "newest": items = (a + b).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case "votes": items = (a + b).sorted { ($0.votes ?? 0) > ($1.votes ?? 0) }
        default: for index in 0..<max(a.count, b.count) { if index < a.count { items.append(a[index]) }; if index < b.count { items.append(b[index]) } }
        }
        let totals = [shows.totalResults, movies.totalResults].compactMap { $0 }
        return CatalogPage(items: items, page: max(shows.page, movies.page), totalPages: max(shows.totalPages, movies.totalPages),
                           totalResults: totals.count == 2 ? totals.reduce(0, +) : nil)
    }
}

extension DiscoveryFilters {
    /// The keyword search, when it's long enough to search with (2+ characters).
    var searchText: String {
        let text = (self.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 2 ? text : ""
    }
}

extension TMDBDirect {
    /// Search Lab straight from TMDB: discover with every filter (the same mapping as the server's
    /// `discover` in src/lib/server/tmdb.ts, plus TV age ratings and "Most popular"), or, with a
    /// keyword, TMDB's title search narrowed by type, genre, rating, year and language.
    static func lab(_ filters: DiscoveryFilters, kind: MediaKind, page: Int, token: String) async throws -> CatalogPage {
        let type = kind == .movie ? "movie" : "tv"
        let text = filters.searchText
        if !text.isEmpty {
            let data = try await object("search/\(type)", query: ["query": text, "page": String(page), "include_adult": "false"], token: token)
            let raw = (data["results"] as? [[String: Any]] ?? []).filter { filters.language == nil || $0["original_language"] as? String == filters.language }
            let items = raw.compactMap { catalogItem($0, kind: kind) }.filter { SearchLabData.matches($0, filters, kind: kind) }
            return CatalogPage(items: items, page: data["page"] as? Int ?? page, totalPages: min(data["total_pages"] as? Int ?? page, 500))
        }
        let dateField = kind == .movie ? "primary_release_date" : "first_air_date"
        var query = ["include_adult": "false", "page": String(page)]
        switch filters.sort {
        case "rating": query["sort_by"] = "vote_average.desc"
        case "newest": query["sort_by"] = dateField + ".desc"
        case "votes": query["sort_by"] = "vote_count.desc"
        default: query["sort_by"] = "popularity.desc"
        }
        var keywords = (filters.keywords ?? []).map(String.init).joined(separator: filters.matchAllKeywords == true ? "," : "|")
        let names = filters.genres ?? []
        let ids = names.compactMap { name in DiscoveryGenre.all.first { $0.name == name }.flatMap { kind == .movie ? $0.movie : $0.tv } }
        if !ids.isEmpty { query["with_genres"] = ids.map(String.init).joined(separator: ",") }
        if kind == .tv {
            let standIns = names.compactMap { SearchLabData.tvGenreKeywords[$0] }.map(String.init)
            if !standIns.isEmpty { keywords = ([keywords] + standIns).filter { !$0.isEmpty }.joined(separator: ",") }
        }
        if !keywords.isEmpty { query["with_keywords"] = keywords }
        if let rating = filters.certification, (kind == .tv ? SearchLabData.tvRatings : SearchLabData.movieRatings).contains(rating) {
            query["certification_country"] = "US"; query["certification"] = rating
        }
        let today = Date.now.formatted(.iso8601.year().month().day())
        if let from = filters.yearFrom { query[dateField + ".gte"] = "\(from)-01-01" }
        query[dateField + ".lte"] = filters.yearTo.map { min("\($0)-12-31", today) } ?? today
        if kind == .tv, let status = filters.showStatus, let code = ["returning": "0", "production": "2", "ended": "3", "canceled": "4"][status] { query["with_status"] = code }
        if let language = filters.language { query["with_original_language"] = language }
        query["vote_count.gte"] = filters.sort == "rating" ? "200" : "20"
        if let minimum = Double(filters.minimum), minimum > 0 { query["vote_average.gte"] = filters.minimum }
        let data = try await object("discover/\(type)", query: query, token: token)
        let items = (data["results"] as? [[String: Any]] ?? []).filter { ($0["adult"] as? Bool) != true }.compactMap { catalogItem($0, kind: kind) }
        return CatalogPage(items: items, page: data["page"] as? Int ?? page, totalPages: min(data["total_pages"] as? Int ?? page, 500),
                           totalResults: data["total_results"] as? Int)
    }
}

/// The tags your own titles carry most, with how many of them carry each ("#isekai 14"): read
/// from the TMDB keywords of up to 36 of your most recently watched titles, once per launch, and
/// only with your own TMDB key (so it costs the diary server nothing).
@MainActor @Observable final class SearchLabTags {
    struct Tag: Identifiable, Hashable { let keyword: TitleKeyword; let count: Int; var id: Int { keyword.id } }
    static let shared = SearchLabTags()
    private(set) var top: [Tag] = []
    private var started = false
    func load(store: DiaryStore) async {
        guard !started, store.isPreview || TMDBDirect.token(store) != nil else { return }
        started = true
        let routes = Self.recent(store.workspace).prefix(36).compactMap { title in title.tmdbId.map { CatalogRoute(kind: title.isSeries ? .tv : .movie, id: $0) } }
        var counts: [TitleKeyword: Int] = [:]
        // All at once (each waits on the network), then counted in order.
        let reads = routes.map { route in Task { try? await TitleExtrasCache.load(store: store, route: route) } }
        for read in reads { for tag in await read.value?.keywords ?? [] { counts[tag, default: 0] += 1 } }
        top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.name < $1.key.name }.prefix(8).map { Tag(keyword: $0.key, count: $0.value) }
    }
    /// Your titles, most recently watched first, then the rest.
    private static func recent(_ workspace: Workspace) -> [MediaTitle] {
        let titles = workspace.activeTitles
        let byId = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(), order: [MediaTitle] = []
        for event in workspace.events.reversed() where event.revokedAt == nil {
            if seen.insert(event.titleId).inserted, let title = byId[event.titleId] { order.append(title) }
        }
        return order + titles.filter { !seen.contains($0.id) }
    }
}
