import Foundation
import TwilDiaryCore

enum SearchBrowseShelf: String, CaseIterable, Identifiable {
    case tags, genres, themes, awards, studios, directors, actors, decades, franchises, worldCinema, internationalTV
    var id: Self { self }

    var title: String {
        switch self {
        case .tags: "Popular tags"
        case .genres: "Genres"
        case .themes: "Themes"
        case .awards: "Awards"
        case .studios: "Studios"
        case .directors: "Popular directors"
        case .actors: "Popular actors"
        case .decades: "Decades"
        case .franchises: "Popular franchises"
        case .worldCinema: "World Cinema"
        case .internationalTV: "International TV"
        }
    }
}

struct SearchBrowseCategory: Hashable, Identifiable {
    enum Filter: Hashable {
        case genre(String)
        case studio(Int)
        case decade(Int)
        case country(String, MediaKind)
        case tag(Int)
        case anime
        case koreanDrama
        case miniseries
        case hiddenGems
    }

    let title: String
    let symbol: String
    let tint: String
    let filter: Filter
    let types: [MediaKind]
    var id: Filter { filter }

    func query(type: MediaKind) -> [String: String] {
        var filters = DiscoveryFilters(section: .genres)
        filters.type = type.rawValue
        switch filter {
        case .genre(let name): filters.genre = name
        case .studio(let id): filters.company = id
        case .decade(let year):
            filters.yearFrom = year
            filters.yearTo = year + 9
        case .country(let code, _):
            var query = filters.query(section: .genres)
            query["country"] = code
            return query
        case .tag(let id): filters.keyword = id
        case .anime:
            filters.genre = "Animation"
            filters.language = "ja"
        case .koreanDrama:
            filters.genre = "Drama"
            var query = filters.query(section: .genres)
            query["country"] = "KR"
            return query
        case .miniseries, .hiddenGems:
            var query = filters.query(section: .genres)
            query["searchTheme"] = filter == .miniseries ? "miniseries" : "hidden-gems"
            return query
        }
        return filters.query(section: .genres)
    }

    func artwork(in titles: [MediaTitle]) -> String? {
        let matches: [MediaTitle]
        switch filter {
        case .genre(let name):
            matches = titles.filter { $0.genres.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        case .decade(let year):
            matches = titles.filter { title in title.year.map { (year...year + 9).contains($0) } ?? false }
        case .studio, .country, .tag, .anime, .koreanDrama, .miniseries, .hiddenGems:
            return nil
        }
        return matches.lazy.compactMap(\.backdrop).first
    }
}

enum SearchBrowseTheme: String, CaseIterable, Identifiable {
    case miniseries, sitcoms, anime, koreanDramas = "k-dramas", docuseries, trueCrime = "true-crime", hiddenGems = "hidden-gems"
    var id: Self { self }

    enum Content {
        case category(SearchBrowseCategory.Filter)
        case keyword(String)
    }

    var content: Content {
        switch self {
        case .miniseries: .category(.miniseries)
        case .sitcoms: .keyword("sitcom")
        case .anime: .category(.anime)
        case .koreanDramas: .category(.koreanDrama)
        case .docuseries: .category(.genre("Documentary"))
        case .trueCrime: .keyword("true crime")
        case .hiddenGems: .category(.hiddenGems)
        }
    }

    var types: [MediaKind] {
        switch self {
        case .miniseries, .sitcoms, .koreanDramas, .docuseries: [.tv]
        case .anime, .trueCrime, .hiddenGems: [.movie, .tv]
        }
    }

    var style: (title: String, icon: String, start: String, end: String) {
        switch self {
        case .miniseries: ("Miniseries", "rectangle.stack.fill", "#595dbd", "#303378")
        case .sitcoms: ("Sitcoms", "sofa.fill", "#b15d18", "#803d0c")
        case .anime: ("Anime", "wand.and.stars", "#b036c4", "#651a89")
        case .koreanDramas: ("K-dramas", "heart.text.square.fill", "#c52c58", "#8b1c3c")
        case .docuseries: ("Docuseries", "globe.americas.fill", "#237f4a", "#155835")
        case .trueCrime: ("True Crime", "magnifyingglass", "#c12e36", "#891e29")
        case .hiddenGems: ("Hidden Gems", "diamond.fill", "#227e97", "#14586d")
        }
    }
}

enum SearchBrowseCatalog {
    static let genres: [SearchBrowseCategory] = {
        let styles: [String: (symbol: String, tint: String)] = [
            "Action & adventure": ("mountain.2", "#4c7998"), "Mystery": ("magnifyingglass", "#606d9b"),
            "Comedy": ("face.smiling", "#b26c3c"), "Drama": ("theatermasks", "#936873"),
            "Sci-fi & fantasy": ("sparkles", "#66549a"), "Animation": ("paintpalette", "#378c8d"),
            "Crime": ("fingerprint", "#557b81"), "Documentary": ("globe.europe.africa", "#55866e"),
            "Horror": ("moon.stars", "#a25b63"), "Romance": ("heart", "#ab557a")
        ]
        let preferred = ["Action & adventure", "Mystery", "Comedy", "Drama", "Sci-fi & fantasy", "Animation"]
        let names = preferred + DiscoveryGenre.all.map(\.name).filter { !preferred.contains($0) }
        return names.map { name in
            let style = styles[name] ?? ("film", "#64728c")
            let types: [MediaKind] = [MediaKind.movie, .tv].filter { DiscoveryGenre.names(type: $0.rawValue).contains(name) }
            return SearchBrowseCategory(title: name, symbol: style.symbol, tint: style.tint, filter: .genre(name), types: types)
        }
    }()

    static let decades: [SearchBrowseCategory] = {
        let start = Calendar.current.component(.year, from: .now) / 10 * 10
        let symbols = ["building.2", "camera", "sun.horizon", "music.note.tv"]
        let tints = ["#65719e", "#a07791", "#477f87", "#a67957"]
        return stride(from: start, through: 1920, by: -10).enumerated().map { index, year in
            SearchBrowseCategory(title: "\(year)s", symbol: symbols[index % symbols.count],
                                 tint: tints[index % tints.count], filter: .decade(year), types: [.movie, .tv])
        }
    }()

    static let studios: [SearchBrowseCategory] = [
        studio("Marvel Studios", 420, types: [.movie, .tv]), studio("Pixar", 3),
        studio("A24", 41077, types: [.movie, .tv]), studio("Studio Ghibli", 10342),
        studio("Lucasfilm", 1, types: [.movie, .tv]), studio("Universal Pictures", 33),
        studio("Paramount Pictures", 4), studio("Warner Bros. Pictures", 174)
    ]

    static let worldCinema: [SearchBrowseCategory] = [
        country("French films", "FR", "building.columns", "#51608e", .movie),
        country("Japanese films", "JP", "mountain.2", "#9b536a", .movie),
        country("South Korean films", "KR", "building.2", "#406a87", .movie),
        country("Indian films", "IN", "sun.horizon", "#a46537", .movie),
        country("Italian films", "IT", "building.columns", "#607a57", .movie),
        country("Spanish films", "ES", "sun.max", "#9b565c", .movie),
        country("Hong Kong films", "HK", "building.2", "#535b9a", .movie),
        country("Brazilian films", "BR", "mountain.2", "#3e7e69", .movie)
    ]

    static let internationalTV: [SearchBrowseCategory] = [
        country("Korean TV", "KR", "building.2", "#406a87", .tv),
        country("Japanese TV", "JP", "mountain.2", "#9b536a", .tv),
        country("British TV", "GB", "building.columns", "#72638d", .tv),
        country("Indian TV", "IN", "sun.horizon", "#a46537", .tv),
        country("Turkish TV", "TR", "moon.stars", "#a05554", .tv),
        country("Spanish TV", "ES", "sun.max", "#9b565c", .tv),
        country("Chinese TV", "CN", "mountain.2", "#58688e", .tv),
        country("Thai TV", "TH", "leaf", "#4a7c70", .tv)
    ]

    private static func studio(_ name: String, _ id: Int, types: [MediaKind] = [.movie]) -> SearchBrowseCategory {
        SearchBrowseCategory(title: name, symbol: "film", tint: "#62697f", filter: .studio(id), types: types)
    }

    private static func country(_ name: String, _ code: String, _ symbol: String, _ tint: String, _ kind: MediaKind) -> SearchBrowseCategory {
        SearchBrowseCategory(title: name, symbol: symbol, tint: tint, filter: .country(code, kind), types: [kind])
    }
}

struct SearchBrowseTag: Hashable, Identifiable {
    let name: String
    var keywordID: Int?
    var id: String { name.lowercased() }
    var emoji: String { name.caseInsensitiveCompare("neo-noir") == .orderedSame ? "🌃" : TagEmoji.symbol(for: name) }

    static let suggestions = ["Time travel", "Coming of age", "Neo-noir", "Superhero", "Mystery", "Friendship",
                              "Based on novel or book", "Psychological thriller"].map { Self(name: $0) }

    @MainActor
    static func popular(from shows: [CatalogItem], store: DiaryStore) async -> [Self] {
        // The tags shared by the current chart, with earlier shows breaking ties.
        let samples = shows.prefix(5).map(\.route)
        var counts: [Int: (keyword: TitleKeyword, count: Int, first: Int)] = [:]
        for (index, route) in samples.enumerated() {
            guard !Task.isCancelled else { return [] }
            guard let extras = try? await TitleExtrasCache.load(store: store, route: route) else { continue }
            var seen = Set<Int>()
            for keyword in extras.keywords where seen.insert(keyword.id).inserted {
                let current = counts[keyword.id]
                counts[keyword.id] = (keyword, (current?.count ?? 0) + 1, current?.first ?? index)
            }
        }
        return counts.values.filter { $0.count > 1 }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.first != $1.first { return $0.first < $1.first }
            return $0.keyword.name < $1.keyword.name
        }.prefix(16).map { Self(name: $0.keyword.name, keywordID: $0.keyword.id) }
    }

    @MainActor
    static func find(_ query: String, store: DiaryStore) async throws -> [Self] {
        #if DEBUG
        if store.isPreview { return suggestions.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        #endif
        let keywords: [TitleKeyword]
        if let token = TMDBDirect.token(store) {
            keywords = try await TMDBDirect.keywords(query, token: token)
        } else {
            struct Reply: Decodable { let items: [TitleKeyword] }
            let reply: Reply = try await store.read(CatalogTools.apiPath("/api/metadata/keywords", query: ["q": query]))
            keywords = reply.items
        }
        var seen = Set<String>()
        return keywords.map { Self(name: $0.name, keywordID: $0.id) }.filter { seen.insert($0.id).inserted }
    }

    @MainActor
    func resolve(store: DiaryStore, title: String? = nil, types: [MediaKind] = [.movie, .tv]) async throws -> SearchBrowseCategory {
        let keywordID: Int
        if let known = self.keywordID {
            keywordID = known
        } else {
            let search = name.replacingOccurrences(of: "-", with: " ")
            #if DEBUG
            if store.isPreview {
                return SearchBrowseCategory(title: title ?? name.capitalized, symbol: "tag", tint: "#58667f", filter: .tag(1), types: types)
            }
            #endif
            guard let match = try await Self.find(search, store: store).first(where: {
                DiarySearchTools.normalize($0.name.replacingOccurrences(of: "-", with: " "))
                    .caseInsensitiveCompare(DiarySearchTools.normalize(search)) == .orderedSame
            })?.keywordID else {
                throw APIError.message("TMDB has no matching tag.")
            }
            keywordID = match
        }
        return SearchBrowseCategory(title: title ?? name.capitalized, symbol: "tag", tint: "#58667f", filter: .tag(keywordID), types: types)
    }
}

struct SearchBrowsePerson: Hashable, Identifiable {
    let id: Int
    let name: String
    var image: String? = nil

    static func selections(for shelf: SearchBrowseShelf) -> [Self] {
        if shelf == .directors {
            return [.init(id: 525, name: "Christopher Nolan"), .init(id: 45400, name: "Greta Gerwig"),
                    .init(id: 137427, name: "Denis Villeneuve"), .init(id: 488, name: "Steven Spielberg"),
                    .init(id: 1032, name: "Martin Scorsese")]
        }
        return [.init(id: 505710, name: "Zendaya"), .init(id: 1136406, name: "Tom Holland"),
                .init(id: 1373737, name: "Florence Pugh"), .init(id: 1620, name: "Michelle Yeoh"),
                .init(id: 6384, name: "Keanu Reeves"), .init(id: 1813, name: "Anne Hathaway")]
    }

    @MainActor
    static func popular(for shelf: SearchBrowseShelf, store: DiaryStore) async -> [Self] {
        guard !store.isPreview, let token = TMDBDirect.token(store) else { return [] }
        let department = shelf == .directors ? "Directing" : "Acting"
        var people: [Self] = []
        var seen = Set<Int>()
        for page in 1...(shelf == .directors ? 4 : 2) {
            guard !Task.isCancelled, let data = try? await TMDBDirect.object("person/popular", query: ["page": String(page)], token: token),
                  let results = data["results"] as? [[String: Any]], !results.isEmpty else { break }
            for person in results {
                guard person["adult"] as? Bool != true, person["known_for_department"] as? String == department,
                      let id = person["id"] as? Int, id > 0, let name = person["name"] as? String,
                      !name.isEmpty, seen.insert(id).inserted else { continue }
                people.append(Self(id: id, name: name, image: CatalogTools.image(person["profile_path"] as? String, size: "w185")))
            }
            if people.count >= 12 { break }
        }
        return people
    }
}

struct SearchBrowseFranchise: Hashable, Identifiable {
    let id: Int
    let title: String

    static let collections: [Self] = [
        .init(id: 119, title: "The Lord of the Rings"), .init(id: 535313, title: "Godzilla"),
        .init(id: 173710, title: "Planet of the Apes"), .init(id: 17255, title: "Resident Evil"),
        .init(id: 1241, title: "Harry Potter"), .init(id: 131292, title: "Iron Man"),
        .init(id: 328, title: "Jurassic Park"), .init(id: 263, title: "The Dark Knight"),
        .init(id: 404609, title: "John Wick"), .init(id: 9485, title: "The Fast and the Furious")
    ]

    private struct CacheKey: Hashable { let id: Int; let session: UUID }
    private struct CachedCollection {
        let id: UUID
        let loadedAt: Date
        let task: Task<TitleCollection, Error>
    }
    @MainActor private static var cache: [CacheKey: CachedCollection] = [:]

    @MainActor
    func load(store: DiaryStore) async throws -> TitleCollection {
        #if DEBUG
        if store.isPreview {
            let preview = PreviewCatalog.discovery(["type": "movie"])
            return TitleCollection(id: id, name: title, overview: "", posterPath: nil, backdropPath: nil, parts: Array(preview.items.prefix(6)))
        }
        #endif
        let key = CacheKey(id: id, session: store.discoveryRevision)
        if let saved = Self.cache[key], Date.now.timeIntervalSince(saved.loadedAt) < 3_600 {
            let collection = try await saved.task.value
            try Task.checkCancellation()
            return collection
        }
        Self.cache = Self.cache.filter { $0.key.session == key.session && Date.now.timeIntervalSince($0.value.loadedAt) < 3_600 }
        let task = Task<TitleCollection, Error> {
            if let token = TMDBDirect.token(store) { return try await TMDBDirect.collection(id, token: token) }
            return try await store.read(CatalogTools.apiPath("/api/metadata/collection", query: ["id": String(id)]))
        }
        let entry = CachedCollection(id: UUID(), loadedAt: .now, task: task)
        Self.cache[key] = entry
        let collection: TitleCollection
        do {
            collection = try await task.value
        } catch {
            if Self.cache[key]?.id == entry.id { Self.cache[key] = nil }
            throw error
        }
        try Task.checkCancellation()
        return collection
    }
}
