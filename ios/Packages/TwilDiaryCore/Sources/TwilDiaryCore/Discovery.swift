import Foundation

/// Names, sources and defaults mirror discovery.ts and explore-sections.ts.
public enum DiscoverySection: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily, recommended, ratedShows = "rated-shows", ratedMovies = "rated-movies"
    case popularShows = "popular-shows", popularMovies = "popular-movies", genres
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .daily: "Recommendation of the day"
        case .recommended: "Recommended for you"
        case .ratedShows: "Highest rated shows"
        case .ratedMovies: "Highest rated movies"
        case .popularShows: "Popular shows"
        case .popularMovies: "Popular movies"
        case .genres: "Browse by genre"
        }
    }
    public var source: String { self == .daily ? "library" : self == .recommended ? "trakt" : "tmdb" }
    public var fixedType: MediaKind? {
        switch self { case .ratedShows, .popularShows: .tv; case .ratedMovies, .popularMovies: .movie; default: nil }
    }
    public var defaultSort: String { self == .ratedShows || self == .ratedMovies ? "rating" : "popular" }
    public static let shelves: [Self] = [.ratedShows, .ratedMovies, .popularShows, .popularMovies]
}

public struct DiscoveryGenre: Sendable {
    public let name: String
    public let movie: Int?
    public let tv: Int?
    public static let all: [Self] = [
        .init(name: "Action & adventure", movie: 28, tv: 10759), .init(name: "Animation", movie: 16, tv: 16),
        .init(name: "Comedy", movie: 35, tv: 35), .init(name: "Crime", movie: 80, tv: 80),
        .init(name: "Documentary", movie: 99, tv: 99), .init(name: "Drama", movie: 18, tv: 18),
        .init(name: "Family", movie: 10751, tv: 10751), .init(name: "Mystery", movie: 9648, tv: 9648),
        .init(name: "Sci-fi & fantasy", movie: 878, tv: 10765), .init(name: "Fantasy", movie: 14, tv: nil),
        .init(name: "Horror", movie: 27, tv: nil), .init(name: "History", movie: 36, tv: nil),
        .init(name: "Music", movie: 10402, tv: nil), .init(name: "Romance", movie: 10749, tv: nil),
        .init(name: "Thriller", movie: 53, tv: nil), .init(name: "War", movie: 10752, tv: 10768),
        .init(name: "Western", movie: 37, tv: 37), .init(name: "Reality", movie: nil, tv: 10764),
        .init(name: "Kids", movie: nil, tv: 10762), .init(name: "News", movie: nil, tv: 10763),
        .init(name: "Talk", movie: nil, tv: 10767), .init(name: "Soap", movie: nil, tv: 10766)
    ]
    public static func names(type: String) -> [String] { all.filter { type == "all" || (type == "movie" ? $0.movie : $0.tv) != nil }.map(\.name) }
}

public struct DiscoveryFilters: Codable, Hashable, Sendable {
    public var type: String
    public var genre = ""
    public var year = ""
    public var sort: String
    public var minimum = "0"
    public init(section: DiscoverySection) {
        type = section.fixedType?.rawValue ?? (section.source == "tmdb" ? "tv" : "all")
        sort = section.defaultSort
    }
    public func error(section: DiscoverySection) -> String? {
        if !year.isEmpty && (year.range(of: #"^\d{4}$"#, options: .regularExpression) == nil || !(1880...2200).contains(Int(year) ?? 0)) { return "Enter a year from 1880 to 2200." }
        if minimum.range(of: #"^(?:[0-9](?:\.\d)?|10(?:\.0)?)$"#, options: .regularExpression) == nil { return "Choose a rating from 0 to 10." }
        if !genre.isEmpty && section.source == "tmdb" && !DiscoveryGenre.names(type: type).contains(genre) { return "Choose a supported genre." }
        if genre.count > 100 { return "Choose a shorter genre." }
        return nil
    }
    public func query(section: DiscoverySection, page: Int = 1, limit: Int = 24) -> [String: String] {
        ["source": section.source, "type": section.fixedType?.rawValue ?? (type == "movie" ? "movie" : "tv"),
         "genre": genre, "year": year, "sort": sort == "title" ? "popular" : sort,
         "minimum": minimum, "page": String(page), "limit": String(limit)]
    }
    public func applying(_ items: [CatalogItem]) -> [CatalogItem] {
        let threshold = Double(minimum) ?? 0
        let filtered = items.enumerated().filter { _, item in
            (type == "all" || item.mediaType.rawValue == type) && (genre.isEmpty || item.genres?.contains(genre) == true)
                && (year.isEmpty || item.year.map(String.init) == year) && (threshold == 0 || item.rating.map { $0 >= threshold } == true)
        }
        return filtered.sorted { a, b in
            switch sort {
            case "rating":
                if (a.element.rating ?? -1) != (b.element.rating ?? -1) { return (a.element.rating ?? -1) > (b.element.rating ?? -1) }
                if (a.element.votes ?? 0) != (b.element.votes ?? 0) { return (a.element.votes ?? 0) > (b.element.votes ?? 0) }
            case "newest": if (a.element.year ?? 0) != (b.element.year ?? 0) { return (a.element.year ?? 0) > (b.element.year ?? 0) }
            case "title":
                let order = a.element.name.localizedCompare(b.element.name)
                if order != .orderedSame { return order == .orderedAscending }
            default: break
            }
            return a.offset < b.offset
        }.map { $0.element }
    }
}

public enum DiscoveryTools {
    public static func unwatched(_ workspace: Workspace) -> [MediaTitle] {
        let watched = Set(workspace.events.filter { $0.revokedAt == nil }.map(\.titleId))
        return workspace.activeTitles.filter { $0.status == "planned" && !watched.contains($0.id) }
            .sorted { $0.id.localizedCompare($1.id) == .orderedAscending }
    }
    public static func dailyPick(_ workspace: Workspace, day: String) -> MediaTitle? {
        let titles = unwatched(workspace)
        guard !titles.isEmpty else { return nil }
        // JavaScript Math.imul's signed 32-bit overflow followed by unsigned indexing.
        let hash = day.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
        return titles[Int(UInt32(bitPattern: hash)) % titles.count]
    }
    public static func item(_ title: MediaTitle) -> CatalogItem {
        CatalogItem(id: title.tmdbId ?? 0, mediaType: title.isSeries ? .tv : .movie, name: title.name,
                    year: title.year, overview: title.overview, rating: title.communityScore, genres: title.genres,
                    inLibraryId: title.id, poster: title.poster, backdrop: title.backdrop)
    }
}

public struct ExploreSectionRoute: Hashable, Sendable {
    public let section: DiscoverySection
    public let filters: DiscoveryFilters
    public init(section: DiscoverySection, filters: DiscoveryFilters? = nil) { self.section = section; self.filters = filters ?? DiscoveryFilters(section: section) }
}
