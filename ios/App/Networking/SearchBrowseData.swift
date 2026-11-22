import Foundation
import TwilDiaryCore

enum SearchBrowseShelf: String, CaseIterable, Identifiable {
    case tags, genres, themes, awards, studios, directors, actors, decades, franchises, worldCinema, internationalTV, officialLists
    var id: Self { self }

    var browseSymbol: String {
        switch self {
        case .tags: "tag"
        case .genres: "film.stack"
        case .themes: "square.grid.2x2"
        case .awards: "trophy"
        case .studios: "building.2"
        case .directors: "video"
        case .actors: "person.2"
        case .decades: "calendar"
        case .franchises: "square.stack.3d.up"
        case .worldCinema: "globe"
        case .internationalTV: "tv"
        case .officialLists: "list.bullet.rectangle"
        }
    }

    var title: String {
        switch self {
        case .tags: "Browse tags"
        case .genres: "Genres"
        case .themes: "Themes"
        case .awards: "Awards"
        case .studios: "Studios"
        case .directors: "Popular directors"
        case .actors: "Popular actors"
        case .decades: "Decades"
        case .franchises: "Featured franchises"
        case .worldCinema: "World Cinema"
        case .internationalTV: "International TV"
        case .officialLists: "Official Lists"
        }
    }
}

struct SearchBrowseCategory: Hashable, Identifiable {
    enum Filter: Hashable {
        case genre(String)
        case genreKeywords(String, [Int])
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

    func query(type: MediaKind, refinements: DiscoveryFilters = DiscoveryFilters(section: .genres)) -> [String: String] {
        var filters = refinements
        filters.type = (types.contains(type) ? type : types.first ?? .movie).rawValue
        switch filter {
        case .genre(let name): filters.genre = name
        case .genreKeywords(let name, let keywords):
            filters.genre = name
            filters.keywords = keywords
            filters.matchAllKeywords = false
        case .studio(let id): filters.company = id
        case .decade(let year):
            filters.year = ""
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

    var allowsGenreFilter: Bool {
        switch filter {
        case .genre, .genreKeywords, .anime, .koreanDrama: false
        default: true
        }
    }

    var allowsStudioFilter: Bool {
        if case .studio = filter { return false }
        return true
    }

    var allowsPeriodFilter: Bool {
        if case .decade = filter { return false }
        return true
    }

    func artwork(in titles: [MediaTitle]) -> String? {
        let matches: [MediaTitle]
        switch filter {
        case .genre(let name):
            matches = titles.filter { $0.genres.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        case .decade(let year):
            matches = titles.filter { title in title.year.map { (year...year + 9).contains($0) } ?? false }
        case .studio, .country, .tag, .genreKeywords, .anime, .koreanDrama, .miniseries, .hiddenGems:
            return nil
        }
        return matches.lazy.compactMap(\.backdrop).first
    }
}

enum SearchBrowseTheme: String, CaseIterable, Identifiable {
    case miniseries, sitcoms, anime, koreanDramas = "k-dramas", docuseries, trueCrime = "true-crime", hiddenGems = "hidden-gems"
    var id: Self { self }

    var category: SearchBrowseCategory {
        SearchBrowseCategory(title: style.title, symbol: style.icon, tint: style.start, filter: filter, types: types)
    }

    var filter: SearchBrowseCategory.Filter {
        switch self {
        case .miniseries: .miniseries
        case .sitcoms: .tag(193171)
        case .anime: .anime
        case .koreanDramas: .koreanDrama
        case .docuseries: .genre("Documentary")
        case .trueCrime: .tag(33722)
        case .hiddenGems: .hiddenGems
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

enum SearchBrowseRegion: String, CaseIterable, Identifiable {
    case asia = "Asia", europe = "Europe", americas = "Americas", africa = "Africa", oceania = "Oceania"
    var id: Self { self }

    var codes: [String] {
        switch self {
        case .asia: ["KR", "JP", "IN", "HK", "CN", "TW", "TH", "TR", "PH", "ID", "MY", "VN", "SG", "PK", "BD", "IR", "IL", "LB", "SA"]
        case .europe: ["FR", "GB", "IT", "ES", "DE", "SE", "NO", "DK", "FI", "IS", "PL", "NL", "BE", "PT", "IE", "GR", "CZ", "AT", "CH", "RO", "HU", "UA"]
        case .americas: ["BR", "MX", "CA", "US", "AR", "CL", "CO", "PE", "UY", "CU"]
        case .africa: ["EG", "NG", "ZA", "MA", "KE", "TN", "DZ", "SN"]
        case .oceania: ["AU", "NZ"]
        }
    }

    var style: (symbol: String, tint: String) {
        switch self {
        case .asia: ("globe.asia.australia", "#69578e")
        case .europe: ("building.columns", "#51678e")
        case .americas: ("globe.americas", "#43796c")
        case .africa: ("sun.horizon", "#9b6245")
        case .oceania: ("water.waves", "#477b8c")
        }
    }

    func contains(_ category: SearchBrowseCategory) -> Bool {
        guard case .country(let code, _) = category.filter else { return false }
        return codes.contains(code)
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
        studio("Paramount Pictures", 4), studio("Warner Bros. Pictures", 174),
        studio("Walt Disney Pictures", 2, types: [.movie, .tv]), studio("DreamWorks Animation", 521, types: [.movie, .tv]),
        studio("Sony Pictures Animation", 2251, types: [.movie, .tv]), studio("Illumination", 6704),
        studio("Legendary Pictures", 923, types: [.movie, .tv]), studio("Blumhouse Productions", 3172, types: [.movie, .tv]),
        studio("New Line Cinema", 12), studio("Focus Features", 10146), studio("Columbia Pictures", 5),
        studio("Metro-Goldwyn-Mayer", 21, types: [.movie, .tv]), studio("20th Century Studios", 127928),
        studio("Searchlight Pictures", 127929), studio("20th Century Fox", 25),
        studio("BBC Studios", 80893, types: [.movie, .tv]),
        studio("HBO", 3268, types: [.movie, .tv]), studio("Sony Pictures Television", 11073, types: [.tv]),
        studio("Warner Bros. Television", 1957, types: [.tv]), studio("Universal Television", 26727, types: [.tv]),
        studio("Toei Animation", 5542, types: [.movie, .tv]), studio("ufotable", 5887, types: [.movie, .tv]),
        studio("Toho", 882, types: [.movie, .tv]), studio("Yash Raj Films", 1569, types: [.movie, .tv]),

        studio("Lionsgate", 1632), studio("DreamWorks Pictures", 7),
        studio("Miramax", 14, types: [.movie, .tv]), studio("TriStar Pictures", 559),
        studio("United Artists", 60), studio("Amblin Entertainment", 56, types: [.movie, .tv]),
        studio("NEON", 90733), studio("StudioCanal", 694, types: [.movie, .tv]),

        studio("Walt Disney Animation Studios", 6125, types: [.movie, .tv]), studio("LAIKA", 11537),
        studio("MAPPA", 21444, types: [.tv, .movie]), studio("Kyoto Animation", 5438, types: [.tv, .movie]),
        studio("Madhouse", 3464, types: [.tv, .movie]), studio("BONES", 2849, types: [.tv, .movie]),
        studio("Production I.G", 529, types: [.tv, .movie]), studio("A-1 Pictures", 13113, types: [.tv, .movie]),
        studio("CloverWorks", 121589, types: [.tv, .movie]), studio("WIT STUDIO", 31058, types: [.tv, .movie]),
        studio("TRIGGER", 50908, types: [.tv, .movie]), studio("Science SARU", 99494, types: [.tv, .movie]),

        studio("20th Television", 236166, types: [.tv]), studio("CBS Studios", 1081, types: [.tv, .movie]),
        studio("ABC Signature", 236613, types: [.tv]), studio("FX Productions", 15990, types: [.tv, .movie]),
        studio("AMC Studios", 23242, types: [.tv, .movie]), studio("Amazon MGM Studios", 210099, types: [.tv, .movie]),
        studio("Apple Studios", 194232, types: [.tv, .movie]),

        studio("Studio Dragon", 86418, types: [.tv, .movie]), studio("CJ ENM", 128404, types: [.tv, .movie]),
        studio("Showbox", 3491), studio("Lotte Entertainment", 7819),
        studio("Dharma Productions", 19146), studio("Red Chillies Entertainment", 2343, types: [.movie, .tv]),
        studio("Excel Entertainment", 2934, types: [.movie, .tv]), studio("T-Series", 3522, types: [.movie, .tv]),
        studio("Maddock Films", 86699, types: [.movie, .tv]), studio("Lyca Productions", 35124),
        studio("Sun Pictures", 7135)
    ]

    static let worldCinema: [SearchBrowseCategory] = countries([
        country("French films", "FR", "building.columns", "#51608e", .movie),
        country("Japanese films", "JP", "mountain.2", "#9b536a", .movie),
        country("South Korean films", "KR", "building.2", "#406a87", .movie),
        country("Indian films", "IN", "sun.horizon", "#a46537", .movie),
        country("Italian films", "IT", "building.columns", "#607a57", .movie),
        country("Spanish films", "ES", "sun.max", "#9b565c", .movie),
        country("Hong Kong films", "HK", "building.2", "#535b9a", .movie),
        country("Brazilian films", "BR", "mountain.2", "#3e7e69", .movie)
    ], kind: .movie)

    static let internationalTV: [SearchBrowseCategory] = countries([
        country("Korean TV", "KR", "building.2", "#406a87", .tv),
        country("Japanese TV", "JP", "mountain.2", "#9b536a", .tv),
        country("British TV", "GB", "building.columns", "#72638d", .tv),
        country("Indian TV", "IN", "sun.horizon", "#a46537", .tv),
        country("Turkish TV", "TR", "moon.stars", "#a05554", .tv),
        country("Spanish TV", "ES", "sun.max", "#9b565c", .tv),
        country("Chinese TV", "CN", "mountain.2", "#58688e", .tv),
        country("Thai TV", "TH", "leaf", "#4a7c70", .tv)
    ], kind: .tv)

    private static func studio(_ name: String, _ id: Int, types: [MediaKind] = [.movie]) -> SearchBrowseCategory {
        SearchBrowseCategory(title: name, symbol: "film", tint: "#62697f", filter: .studio(id), types: types)
    }

    private static func country(_ name: String, _ code: String, _ symbol: String, _ tint: String, _ kind: MediaKind) -> SearchBrowseCategory {
        SearchBrowseCategory(title: name, symbol: symbol, tint: tint, filter: .country(code, kind), types: [kind])
    }

    private static func countries(_ featured: [SearchBrowseCategory], kind: MediaKind) -> [SearchBrowseCategory] {
        let seen = Set(featured.map(\.id))
        let available = SearchBrowseRegion.allCases.flatMap { region in
            region.codes.map { code in
                country(Locale.current.localizedString(forRegionCode: code) ?? code,
                        code, region.style.symbol, region.style.tint, kind)
            }
        }
        return featured + available.filter { !seen.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct SearchBrowseTag: Hashable, Identifiable {
    let name: String
    var keywordID: Int?
    var anilist = false
    var displayName: String?
    var id: String { (anilist ? "anilist:" : "") + name.lowercased() }
    var emoji: String { name.caseInsensitiveCompare("neo-noir") == .orderedSame ? "🌃" : TagEmoji.symbol(for: name) }

    static let suggestions: [Self] = [
        .init(name: "Time travel", keywordID: 4379),
        .init(name: "Coming of age"),
        .init(name: "Neo-noir", keywordID: 207268),
        .init(name: "Superhero", keywordID: 9715),
        .init(name: "Friendship", keywordID: 6054),
        .init(name: "Based on novel or book", keywordID: 818),
        .init(name: "Psychological thriller"),
        .init(name: "Found family", keywordID: 248927),
        .init(name: "Mystery"),
        .init(name: "True crime", keywordID: 33722),
        .init(name: "Survival", keywordID: 10349),
        .init(name: "Dystopia", keywordID: 4565),
        .init(name: "Alternate history", keywordID: 12026),
        .init(name: "Alien invasion", keywordID: 14909),
        .init(name: "Artificial intelligence", keywordID: 310),
        .init(name: "Heist", keywordID: 10051),
        .init(name: "Serial killer", keywordID: 10714),
        .init(name: "Organized crime", keywordID: 10291),
        .init(name: "Dark comedy", keywordID: 10123),
        .init(name: "Satire", keywordID: 8201),
        .init(name: "Road trip", keywordID: 7312),
        .init(name: "Small town", keywordID: 1415),
        .init(name: "Family relationships", keywordID: 10235),
        .init(name: "Samurai", keywordID: 1462),
        .init(name: "Post-apocalyptic future", keywordID: 4458),
        .init(name: "Vampire", keywordID: 3133),
        .init(name: "Supernatural", keywordID: 6152),
        .init(name: "Ghost", keywordID: 162846),
        .init(name: "Zombie", keywordID: 12377),
        .init(name: "Shōnen", keywordID: 207826),
        .init(name: "Music", keywordID: 283297),
        .init(name: "Dragon", keywordID: 12554),
        .init(name: "Medieval", keywordID: 161257),
        .init(name: "Revenge"),
        .init(name: "Courtroom", keywordID: 33519),
        .init(name: "Espionage", keywordID: 5265),
        .init(name: "High school"),
        .init(name: "Period drama", keywordID: 15060),
        .init(name: "Martial arts"),
        .init(name: "Haunted house", keywordID: 3358),
        .init(name: "Isekai", keywordID: 237451),
        .init(name: "Mecha"),
        .init(name: "Slice of life"),
        .init(name: "Cooking", keywordID: 1918),
        .init(name: "Sports")
    ]

    static let animeSuggestions = [
        "Isekai", "Mecha", "Slice of Life", "Iyashikei", "Mahou Shoujo", "Time Loop", "Coming of Age",
        "Super Power", "Found Family", "School Club", "Idol", "Vampire", "Historical", "Space",
        "Psychological", "Urban Fantasy", "Robots", "Martial Arts", "Mythology", "Food"
    ].map { Self(name: $0, anilist: true) }

    @MainActor private static var chartTags: (keys: [String], tags: [Self], date: Date)?

    @MainActor
    static func popular(from shows: [CatalogItem], store: DiaryStore) async -> [Self] {
        // Earlier shows break ties among recurring tags on the current chart.
        let samples = shows.prefix(5).map(\.route)
        let keys = shows.prefix(5).map(\.key)
        if let cached = chartTags, cached.keys == keys, Date.now.timeIntervalSince(cached.date) < 900 { return cached.tags }
        var counts: [Int: (keyword: TitleKeyword, count: Int, first: Int)] = [:]
        for start in stride(from: 0, to: samples.count, by: 3) {
            guard !Task.isCancelled else { return [] }
            let batch = samples[start..<min(start + 3, samples.count)]
            let collected = await withTaskGroup(of: (Int, [TitleKeyword]).self) { group in
                for (offset, route) in batch.enumerated() {
                    group.addTask {
                        let extras = try? await TitleExtrasCache.load(store: store, route: route)
                        return (start + offset, extras?.keywords ?? [])
                    }
                }
                var rows: [(Int, [TitleKeyword])] = []
                for await row in group { rows.append(row) }
                return rows.sorted { $0.0 < $1.0 }
            }
            for (index, keywords) in collected {
                var seen = Set<Int>()
                for keyword in keywords where seen.insert(keyword.id).inserted {
                    let current = counts[keyword.id]
                    counts[keyword.id] = (keyword, (current?.count ?? 0) + 1, current?.first ?? index)
                }
            }
        }
        let tags = counts.values.filter { $0.count > 1 }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.first != $1.first { return $0.first < $1.first }
            return $0.keyword.name < $1.keyword.name
        }.prefix(20).map { Self(name: $0.keyword.name, keywordID: $0.keyword.id) }
        if !tags.isEmpty { chartTags = (keys, tags, .now) }
        return tags
    }

    @MainActor
    static func find(_ query: String, store: DiaryStore) async throws -> [Self] {
        #if DEBUG
        if store.isPreview { return suggestions.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        #endif
        let keywords: [TitleKeyword]
        if let token = TMDBDirect.token(store) {
            keywords = try await SearchBrowseRead.retry { try await TMDBDirect.keywords(query, token: token) }
        } else {
            struct Reply: Decodable { let items: [TitleKeyword] }
            let reply: Reply = try await store.read(CatalogTools.apiPath("/api/metadata/keywords", query: ["q": query]))
            keywords = reply.items
        }
        var seen = Set<String>()
        return keywords.map { Self(name: $0.name, keywordID: $0.id) }.filter { seen.insert($0.id).inserted }
    }

    @MainActor
    func resolve(store: DiaryStore) async throws -> SearchBrowseCategory {
        let types: [MediaKind] = [.movie, .tv]
        let title = name.prefix(1).uppercased() + name.dropFirst()
        let keywordID: Int
        if let known = self.keywordID {
            keywordID = known
        } else {
            let search = name.replacingOccurrences(of: "-", with: " ")
            #if DEBUG
            if store.isPreview {
                return SearchBrowseCategory(title: title, symbol: "tag", tint: "#58667f", filter: .tag(1), types: types)
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
        return SearchBrowseCategory(title: title, symbol: "tag", tint: "#58667f", filter: .tag(keywordID), types: types)
    }
}

enum SearchBrowseRead {
    static func isTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.secureConnectionFailed, .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
            .contains(urlError.code)
    }

    @MainActor
    static func retry<Value>(_ read: () async throws -> Value) async throws -> Value {
        do { return try await read() }
        catch let error where isTransportError(error) {
            try await Task.sleep(for: .milliseconds(500))
            return try await read()
        }
    }
}

struct SearchBrowsePerson: Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    var image: String? = nil
    var knownFor: String? = nil

    static func selections(for shelf: SearchBrowseShelf) -> [Self] {
        shelf == .directors ? directors : actors
    }

    private static let directors: [Self] = [
        .init(id: 525, name: "Christopher Nolan"),
        .init(id: 45400, name: "Greta Gerwig"),
        .init(id: 137427, name: "Denis Villeneuve", image: "https://image.tmdb.org/t/p/w185/xzQYqb4nR8xT7Zdw5itbEL9K3fd.jpg"),
        .init(id: 488, name: "Steven Spielberg", image: "https://image.tmdb.org/t/p/w185/tZxcg19YQ3e8fJ0pOs7hjlnmmr6.jpg"),
        .init(id: 1032, name: "Martin Scorsese"),
        .init(id: 21684, name: "Bong Joon Ho", image: "https://image.tmdb.org/t/p/w185/stwnTvZAoD8gEJEDHpDQyLCyDy5.jpg"),
        .init(id: 147021, name: "S. S. Rajamouli", image: "https://image.tmdb.org/t/p/w185/qPskSZxvoYflC8Bye4tGNBSroy5.jpg"),
        .init(id: 1769, name: "Sofia Coppola", image: "https://image.tmdb.org/t/p/w185/dzHC2LxmarkBxWLhjp2DRa5oCev.jpg"),
        .init(id: 5655, name: "Wes Anderson", image: "https://image.tmdb.org/t/p/w185/s03CeUeC5yAXyB1acqP0zGNo2SC.jpg"),
        .init(id: 608, name: "Hayao Miyazaki", image: "https://image.tmdb.org/t/p/w185/ouhjt9KugzhWtdEyBPipihB3ic8.jpg"),
        .init(id: 5026, name: "Akira Kurosawa", image: "https://image.tmdb.org/t/p/w185/ca8fRqLDfTJTCamLKHp70up23ET.jpg"),
        .init(id: 309, name: "Pedro Almodóvar", image: "https://image.tmdb.org/t/p/w185/dKlaXJk3NLcsC1CKMx6xmyW5BZD.jpg"),
        .init(id: 1395183, name: "Chloé Zhao", image: "https://image.tmdb.org/t/p/w185/r8DmTdOqHbDUydCOVb277rncPTK.jpg"),
        .init(id: 68813, name: "Céline Sciamma", image: "https://image.tmdb.org/t/p/w185/4B5Bt47HYTObsde1einBDha03ka.jpg"),
        .init(id: 1056121, name: "Ryan Coogler", image: "https://image.tmdb.org/t/p/w185/dux4DCDaL6c639DTXGiV7nm1wcN.jpg"),
        .init(id: 122423, name: "Yorgos Lanthimos", image: "https://image.tmdb.org/t/p/w185/dvtv8eV1O8Fl385ctOu3sqO2PbD.jpg"),
        .init(id: 138, name: "Quentin Tarantino"),
        .init(id: 7467, name: "David Fincher"),
        .init(id: 2710, name: "James Cameron"),
        .init(id: 10099, name: "Park Chan-wook"),
        .init(id: 12453, name: "Wong Kar-wai"),
        .init(id: 2636, name: "Alfred Hitchcock"),
        .init(id: 240, name: "Stanley Kubrick"),
        .init(id: 5602, name: "David Lynch"),
        .init(id: 10828, name: "Guillermo del Toro"),
        .init(id: 40654, name: "Jane Campion"),
        .init(id: 14392, name: "Kathryn Bigelow"),
        .init(id: 62363, name: "Satoshi Kon"),
        .init(id: 74091, name: "Makoto Shinkai", image: "https://image.tmdb.org/t/p/w185/z8TN4Nkmhem6XqcnH2jMn5Ayf97.jpg"),
        .init(id: 1776, name: "Francis Ford Coppola"),
        .init(id: 578, name: "Ridley Scott"),
        .init(id: 55934, name: "Taika Waititi")
    ]

    private static let actors: [Self] = [
        .init(id: 505710, name: "Zendaya", image: "https://image.tmdb.org/t/p/w185/1qup8tSt95HLbcy2c2xrx4iJNxv.jpg"),
        .init(id: 1136406, name: "Tom Holland", image: "https://image.tmdb.org/t/p/w185/xKBAaPIa1c7tzZD3Y0MhBLv4hPE.jpg"),
        .init(id: 1373737, name: "Florence Pugh"),
        .init(id: 1620, name: "Michelle Yeoh", image: "https://image.tmdb.org/t/p/w185/i6fHvGt7Rb8oVyjjdQVV6vEHB94.jpg"),
        .init(id: 6384, name: "Keanu Reeves"),
        .init(id: 1813, name: "Anne Hathaway", image: "https://image.tmdb.org/t/p/w185/s6tflSD20MGz04ZR2R1lZvhmC4Y.jpg"),
        .init(id: 1253360, name: "Pedro Pascal", image: "https://image.tmdb.org/t/p/w185/cuhkTL3MezjArl80MnYl6QJQ4PQ.jpg"),
        .init(id: 974169, name: "Jenna Ortega", image: "https://image.tmdb.org/t/p/w185/yiL1tWLHwYrJznkjT2NKmR2YLMs.jpg"),
        .init(id: 6193, name: "Leonardo DiCaprio", image: "https://image.tmdb.org/t/p/w185/wo2hJpn04vbtmh0B9utCFdsQhxM.jpg"),
        .init(id: 2524, name: "Tom Hardy", image: "https://image.tmdb.org/t/p/w185/d81K0RH8UX7tZj49tZaQhZ9ewH.jpg"),
        .init(id: 2037, name: "Cillian Murphy", image: "https://image.tmdb.org/t/p/w185/2lKs67r7FI4bPu0AXxMUJZxmUXn.jpg"),
        .init(id: 1397778, name: "Anya Taylor-Joy", image: "https://image.tmdb.org/t/p/w185/qYNofOjlRke2MlJVihmJmEdQI4v.jpg"),
        .init(id: 3223, name: "Robert Downey Jr.", image: "https://image.tmdb.org/t/p/w185/5qHNjhtjMD4YWH3UP0rm4tKwxCL.jpg"),
        .init(id: 5292, name: "Denzel Washington", image: "https://image.tmdb.org/t/p/w185/jj2Gcobpopokal0YstuCQW0ldJ4.jpg"),
        .init(id: 150903, name: "Gong Yoo", image: "https://image.tmdb.org/t/p/w185/ocGoFb6TrK3uWGXt4WnuibUG1vD.jpg"),
        .init(id: 74421, name: "Song Hye-kyo", image: "https://image.tmdb.org/t/p/w185/tlAX3f82Mf5h0rznpVBVK7nD2om.jpg"),
        .init(id: 35742, name: "Shah Rukh Khan", image: "https://image.tmdb.org/t/p/w185/tKeQhSyXyzlzxNtxFq24iIvzXrC.jpg"),
        .init(id: 53975, name: "Deepika Padukone", image: "https://image.tmdb.org/t/p/w185/rzvvBQ0r6oiqDdzcsdTRB7jN4Rx.jpg"),
        .init(id: 3810, name: "Javier Bardem", image: "https://image.tmdb.org/t/p/w185/zfRID0jx8DKBluPGU9xtk9sZWUt.jpg"),
        .init(id: 1267329, name: "Lupita Nyong'o", image: "https://image.tmdb.org/t/p/w185/y40Wu1T742kynOqtwXASc5Qgm49.jpg"),
        .init(id: 25072, name: "Oscar Isaac", image: "https://image.tmdb.org/t/p/w185/dW5U5yrIIPmMjRThR9KT2xH6nTz.jpg"),
        .init(id: 76788, name: "Dev Patel", image: "https://image.tmdb.org/t/p/w185/byAo6xoleVSG5O9YpGrQ5YuCRX7.jpg"),
        .init(id: 234352, name: "Margot Robbie"),
        .init(id: 30614, name: "Ryan Gosling"),
        .init(id: 112, name: "Cate Blanchett"),
        .init(id: 20738, name: "Song Kang-ho"),
        .init(id: 1337, name: "Tony Leung Chiu-wai"),
        .init(id: 224513, name: "Ana de Armas"),
        .init(id: 955, name: "Penélope Cruz"),
        .init(id: 1019, name: "Mads Mikkelsen"),
        .init(id: 19492, name: "Viola Davis"),
        .init(id: 54693, name: "Emma Stone"),
        .init(id: 37625, name: "Andrew Garfield"),
        .init(id: 3063, name: "Tilda Swinton"),
        .init(id: 36592, name: "Saoirse Ronan", image: "https://image.tmdb.org/t/p/w185/9buDPdqKN9vbnQLLkHEinDtMrCG.jpg"),
        .init(id: 1190668, name: "Timothée Chalamet")
    ]

    struct Page {
        let people: [SearchBrowsePerson]
        let next: Int?
    }

    private struct PopularPage: Decodable, Sendable {
        struct Person: Decodable, Sendable {
            let id: Int
            let name: String
            let adult: Bool?
            struct Credit: Decodable, Sendable { let title: String?; let name: String? }
            let known_for: [Credit]?
            let known_for_department: String?
            let profile_path: String?
        }
        let page: Int
        let total_pages: Int
        let results: [Person]
    }

    private struct CachedPage {
        let id: UUID
        let loadedAt: Date
        let task: Task<PopularPage, Error>
    }

    @MainActor private static var cachedRevision: UUID?
    @MainActor private static var pages: [Int: CachedPage] = [:]

    @MainActor
    static func popular(
        for shelf: SearchBrowseShelf, page: Int = 1, store: DiaryStore
    ) async throws -> Page {
        guard !store.isPreview, let token = TMDBDirect.token(store) else { return Page(people: [], next: nil) }
        let department = shelf == .directors ? "Directing" : "Acting"
        let revision = store.discoveryRevision
        if revision != cachedRevision { pages.removeAll(); cachedRevision = revision }
        let entry: CachedPage
        if let cached = pages[page], Date.now.timeIntervalSince(cached.loadedAt) < 900 {
            entry = cached
        } else {
            let task = Task {
                let data = try await SearchBrowseRead.retry {
                    try await TMDBDirect.data("person/popular", query: ["page": String(page)], token: token)
                }
                let reply = try JSONDecoder().decode(PopularPage.self, from: data)
                guard reply.page == page else { throw APIError.message("TMDB returned an unexpected people page.") }
                return reply
            }
            entry = CachedPage(id: UUID(), loadedAt: .now, task: task)
            pages[page] = entry
            if pages.count > 40, let oldest = pages.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
                pages[oldest] = nil
            }
        }
        let reply: PopularPage
        do { reply = try await entry.task.value }
        catch {
            if pages[page]?.id == entry.id { pages[page] = nil }
            throw error
        }
        try Task.checkCancellation()
        guard revision == store.discoveryRevision else { throw CancellationError() }
        let people = reply.results.compactMap { person -> Self? in
            guard person.adult != true, person.known_for_department == department,
                  person.id > 0, !person.name.isEmpty else { return nil }
            return Self(id: person.id, name: person.name, image: CatalogTools.image(person.profile_path, size: "w185"),
                        knownFor: person.known_for?.first.flatMap { $0.title ?? $0.name })
        }
        return Page(people: people, next: page < min(reply.total_pages, 500) ? page + 1 : nil)
    }
}
