import Foundation
import TwilDiaryCore

/// Reads TMDB straight from the phone with your own TMDB key (Settings → TMDB), kept encrypted in
/// the iOS Keychain with the other provider credentials. Every TMDB read is made here when a key is
/// saved (TwilDiary's server is only the fallback without one), so metadata never needs Cloudflare.
@MainActor enum TMDBDirect {
    struct Overview: Sendable {
        let genres: [TitleKeyword]
        let collection: TitleCollectionRef?
    }
    struct GenrePage: Sendable {
        let total: Int?
        let artwork: [String]
    }

    /// Your key, when one is saved on this phone.
    static func token(_ store: DiaryStore) -> String? {
        guard let value = store.providerSettings.customTmdbToken?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// A title's genres (with TMDB ids) and, for a movie, the collection it belongs to.
    static func overview(_ route: CatalogRoute, token: String) async throws -> Overview {
        let data = try await object("\(route.kind == .movie ? "movie" : "tv")/\(route.id)", query: [:], token: token)
        let genres = (data["genres"] as? [[String: Any]] ?? []).compactMap { item -> TitleKeyword? in
            guard let id = item["id"] as? Int, id > 0, let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TitleKeyword(id: id, name: name)
        }
        var collection: TitleCollectionRef?
        if route.kind == .movie, let owner = data["belongs_to_collection"] as? [String: Any],
           let id = owner["id"] as? Int, id > 0, let name = owner["name"] as? String, !name.isEmpty {
            collection = TitleCollectionRef(id: id, name: name, posterPath: owner["poster_path"] as? String, backdropPath: owner["backdrop_path"] as? String)
        }
        return Overview(genres: genres, collection: collection)
    }

    /// TMDB's count of titles in a genre (same media type; Japanese for anime) and two backdrops.
    static func genre(_ genre: Int, kind: MediaKind, anime: Bool, token: String) async throws -> GenrePage {
        var query = ["with_genres": String(genre), "sort_by": "popularity.desc", "include_adult": "false", "page": "1"]
        if anime { query["with_original_language"] = "ja" }
        let data = try await object("discover/\(kind == .movie ? "movie" : "tv")", query: query, token: token)
        let results = data["results"] as? [[String: Any]] ?? []
        let art = results.compactMap { ($0["backdrop_path"] as? String).flatMap { CatalogTools.image($0, size: "w780") } }
        return GenrePage(total: data["total_results"] as? Int, artwork: Array(art.prefix(2)))
    }

    /// A title page's extras, mapped exactly as the diary server maps them (src/lib/server/tmdb.ts
    /// `extras`): status, age rating (US, then the title's country, then any), studios, networks,
    /// keywords, the most important crew, genres and a movie's collection.
    static func extras(_ route: CatalogRoute, token: String) async throws -> (TitleExtras, community: Double?) {
        let tv = route.kind == .tv
        let data = try await object("\(tv ? "tv" : "movie")/\(route.id)", query: ["append_to_response": tv ? "keywords,content_ratings,credits" : "keywords,release_dates,credits"], token: token)
        func list(_ value: Any?, _ max: Int) -> [[String: Any]] { Array((value as? [[String: Any]] ?? []).prefix(max)) }
        func company(_ item: [String: Any], _ kind: String) -> TitleCompany? {
            guard let id = item["id"] as? Int, id > 0, let name = item["name"] as? String, !name.isEmpty else { return nil }
            let logo = (item["logo_path"] as? String).flatMap { $0.hasPrefix("/") && !$0.contains("..") ? $0 : nil }
            return TitleCompany(id: id, name: String(name.prefix(200)), logoPath: logo, kind: kind, country: (item["origin_country"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(4)) })
        }
        let studios = list(data["production_companies"], 30).compactMap { company($0, "studio") }
        let networks = list(data["networks"], 20).compactMap { company($0, "network") }
        let words = data["keywords"] as? [String: Any] ?? [:]
        let keywords = list(tv ? words["results"] : words["keywords"], 60).compactMap { item -> TitleKeyword? in
            guard let id = item["id"] as? Int, id > 0, let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TitleKeyword(id: id, name: name)
        }
        let origin = (data["origin_country"] as? [String])?.first ?? ""
        let ratings: [(country: String, rating: String)] = tv
            ? list((data["content_ratings"] as? [String: Any])?["results"], 200).map { ($0["iso_3166_1"] as? String ?? "", $0["rating"] as? String ?? "") }
            : list((data["release_dates"] as? [String: Any])?["results"], 200).map { item in
                (item["iso_3166_1"] as? String ?? "", list(item["release_dates"], 30).compactMap { $0["certification"] as? String }.first { !$0.isEmpty } ?? "")
            }
        let rated = ratings.filter { !$0.rating.isEmpty }
        let certification = (rated.first { $0.country == "US" } ?? rated.first { $0.country == origin } ?? rated.first)?.rating
        let jobs = ["Creator", "Director", "Series Director", "Original Concept", "Original Story", "Novel", "Comic Book", "Series Composition",
                    "Screenplay", "Writer", "Character Designer", "Original Music Composer", "Music", "Executive Producer"]
        let people = list(data["created_by"], 20).map { $0.merging(["job": "Creator"]) { _, new in new } } + list((data["credits"] as? [String: Any])?["crew"], 400)
        var seen = Set<Int>()
        let crew = people.compactMap { item -> (TitleCrewMember, Int)? in
            guard let id = item["id"] as? Int, id > 0, let name = item["name"] as? String, !name.isEmpty,
                  let job = item["job"] as? String, let rank = jobs.firstIndex(of: job) else { return nil }
            return (TitleCrewMember(id: id, name: name, job: job, profilePath: item["profile_path"] as? String), rank)
        }.sorted { $0.1 < $1.1 }.map(\.0).filter { seen.insert($0.id).inserted }.prefix(24)
        let genres = list(data["genres"], 20).compactMap { item -> TitleKeyword? in
            guard let id = item["id"] as? Int, id > 0, let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TitleKeyword(id: id, name: name)
        }
        var collection: TitleCollectionRef?
        if !tv, let owner = data["belongs_to_collection"] as? [String: Any], let id = owner["id"] as? Int, id > 0, let name = owner["name"] as? String, !name.isEmpty {
            collection = TitleCollectionRef(id: id, name: name, posterPath: owner["poster_path"] as? String, backdropPath: owner["backdrop_path"] as? String)
        }
        let status = (data["status"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let community = (data["vote_average"] as? Double).flatMap { $0 > 0 && $0 <= 10 ? $0 : nil }
        return (TitleExtras(status: status, certification: certification, studios: studios, networks: networks, keywords: keywords,
                            crew: Array(crew), genres: genres, collection: collection), community)
    }
    /// TMDB's community score for a title (the page's community circle when the diary has none).
    static func community(_ route: CatalogRoute, token: String) async -> Double? { try? await extras(route, token: token).community }

    /// The cast as the server lists it: each actor once, their main role, at most 24.
    static func cast(_ route: CatalogRoute, token: String) async throws -> CastResponse {
        let data = try await object(route.kind == .tv ? "tv/\(route.id)/aggregate_credits" : "movie/\(route.id)/credits", query: [:], token: token)
        var seen = Set<Int>(), people: [[String: Any]] = []
        for actor in data["cast"] as? [[String: Any]] ?? [] {
            guard let id = actor["id"] as? Int, id > 0, let name = actor["name"] as? String, !name.isEmpty, seen.insert(id).inserted else { continue }
            let roles = (actor["roles"] as? [[String: Any]] ?? []).sorted { ($0["episode_count"] as? Int ?? 0) > ($1["episode_count"] as? Int ?? 0) }
            let character = actor["character"] as? String ?? roles.first?["character"] as? String ?? ""
            people.append(["id": id, "name": name, "character": character, "profilePath": actor["profile_path"] as Any? ?? NSNull()])
            if people.count == 24 { break }
        }
        return try JSONDecoder().decode(CastResponse.self, from: JSONSerialization.data(withJSONObject: ["cast": people, "stale": false]))
    }

    /// TMDB's recommendations for a title (More like this), same type only, at most 20.
    static func related(_ route: CatalogRoute, token: String) async throws -> RelatedResponse {
        let data = try await object("\(route.kind == .movie ? "movie" : "tv")/\(route.id)/recommendations", query: ["page": "1"], token: token)
        var seen: Set<Int> = [route.id]
        let items = (data["results"] as? [[String: Any]] ?? []).compactMap { item -> CatalogItem? in
            guard item["adult"] as? Bool != true, let id = item["id"] as? Int, seen.insert(id).inserted else { return nil }
            return catalogItem(item, kind: route.kind)
        }
        return RelatedResponse(items: Array(items.prefix(20)), stale: false)
    }

    /// A TMDB list result as the app's catalog item (genre names from TMDB's ids, as the server does).
    static func catalogItem(_ item: [String: Any], kind: MediaKind) -> CatalogItem? {
        guard let id = item["id"] as? Int, id > 0,
              let name = (kind == .movie ? item["title"] : item["name"]) as? String, !name.isEmpty else { return nil }
        let date = (kind == .movie ? item["release_date"] : item["first_air_date"]) as? String
        let rating = (item["vote_average"] as? Double).flatMap { $0 > 0 && $0 <= 10 ? $0 : nil }
        let ids = item["genre_ids"] as? [Int] ?? []
        let genres = genreNames.filter { ids.contains(kind == .movie ? $0.movie ?? -1 : $0.tv ?? -1) }.map(\.name)
        return CatalogItem(id: id, mediaType: kind, name: name, year: date.flatMap { Int($0.prefix(4)) }, overview: item["overview"] as? String ?? "",
                           posterPath: item["poster_path"] as? String, backdropPath: item["backdrop_path"] as? String, rating: rating,
                           votes: item["vote_count"] as? Int ?? 0, genres: genres)
    }
    /// The server's genre table (src/lib/discovery.ts `discoveryGenres`).
    private static let genreNames: [(name: String, movie: Int?, tv: Int?)] = [
        ("Action & adventure", 28, 10759), ("Animation", 16, 16), ("Comedy", 35, 35), ("Crime", 80, 80), ("Documentary", 99, 99),
        ("Drama", 18, 18), ("Family", 10751, 10751), ("Mystery", 9648, 9648), ("Sci-fi & fantasy", 878, 10765), ("Fantasy", 14, nil),
        ("Horror", 27, nil), ("History", 36, nil), ("Music", 10402, nil), ("Romance", 10749, nil), ("Thriller", 53, nil),
        ("War", 10752, 10768), ("Western", 37, 37), ("Reality", nil, 10764), ("Kids", nil, 10762), ("News", nil, 10763),
        ("Talk", nil, 10767), ("Soap", nil, 10766)
    ]

    /// A title's details as the server builds them (`details` in src/lib/server/tmdb.ts): name, year,
    /// seasons, genres, runtime, score, IMDb id and the suggested category (anime when it's Japanese animation).
    static func details(_ route: CatalogRoute, token: String) async throws -> CatalogDetails {
        let tv = route.kind == .tv
        let data = try await object("\(tv ? "tv" : "movie")/\(route.id)", query: ["append_to_response": "external_ids"], token: token)
        guard let base = catalogItem(data, kind: route.kind), base.id == route.id else { throw APIError.message("TMDB sent incomplete details.") }
        let seasons: [[String: Any]] = tv ? (data["seasons"] as? [[String: Any]] ?? []).map { season in
            let number = season["season_number"] as? Int ?? 0
            let name = (season["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (number > 0 ? "Season \(number)" : "Specials")
            return ["number": number, "name": name, "expectedEpisodes": season["episode_count"] as? Int ?? 0]
        } : []
        let genres = (data["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        let runtime = tv ? (data["episode_run_time"] as? [Int])?.first : data["runtime"] as? Int
        let imdb = ((data["external_ids"] as? [String: Any])?["imdb_id"] as? String) ?? data["imdb_id"] as? String
        let anime = genres.contains("Animation") && data["original_language"] as? String == "ja"
        let object: [String: Any] = [
            "id": base.id, "mediaType": route.kind.rawValue, "name": base.name, "year": base.year as Any? ?? NSNull(), "overview": base.overview,
            "posterPath": base.posterPath as Any? ?? NSNull(), "backdropPath": base.backdropPath as Any? ?? NSNull(),
            "suggestedCategory": anime ? (tv ? "anime" : "anime-movie") : (tv ? "show" : "movie"),
            "seasons": seasons, "genres": genres,
            "runtimeMinutes": runtime.flatMap { $0 > 0 && $0 <= 1440 ? $0 : nil } as Any? ?? NSNull(),
            "communityScore": base.rating as Any? ?? NSNull(),
            "imdbId": imdb.flatMap { $0.range(of: #"^tt\d{7,10}$"#, options: .regularExpression) != nil ? $0 : nil } as Any? ?? NSNull()
        ]
        return try JSONDecoder().decode(CatalogDetails.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// A season's episodes as the server sends them; names, summaries and stills stay blank unless revealed.
    static func season(_ id: Int, number: Int, reveal: Bool, token: String) async throws -> CatalogEpisodesPage {
        let data = try await object("tv/\(id)/season/\(number)", query: [:], token: token)
        guard data["season_number"] as? Int == number else { throw APIError.message("TMDB sent a different season.") }
        let items = (data["episodes"] as? [[String: Any]] ?? []).compactMap { episode -> CatalogEpisode? in
            guard let n = episode["episode_number"] as? Int, n > 0 else { return nil }
            let votes = episode["vote_count"] as? Int ?? 0
            let score = (episode["vote_average"] as? Double).flatMap { $0 > 0 && $0 <= 10 && votes > 0 ? $0 : nil }
            return CatalogEpisode(number: n, name: reveal ? episode["name"] as? String ?? "" : "", overview: reveal ? episode["overview"] as? String ?? "" : "",
                                  airedOn: (episode["air_date"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  stillPath: reveal ? episode["still_path"] as? String : nil, communityScore: score)
        }
        return CatalogEpisodesPage(items: items)
    }

    /// A collection's films, oldest first.
    static func collection(_ id: Int, token: String) async throws -> TitleCollection {
        let data = try await object("collection/\(id)", query: [:], token: token)
        let parts: [[String: Any]] = (data["parts"] as? [[String: Any]] ?? []).filter { ($0["adult"] as? Bool) != true }
        let items = parts.compactMap { part -> CatalogItem? in
            guard let id = part["id"] as? Int, let name = (part["title"] as? String) ?? (part["name"] as? String), !name.isEmpty else { return nil }
            let year = (part["release_date"] as? String).flatMap { Int($0.prefix(4)) }
            let rating = (part["vote_average"] as? Double).flatMap { $0 > 0 ? $0 : nil }
            return CatalogItem(id: id, mediaType: .movie, name: name, year: year, overview: part["overview"] as? String ?? "",
                               posterPath: part["poster_path"] as? String, backdropPath: part["backdrop_path"] as? String, rating: rating)
        }.sorted { ($0.year ?? 9999) < ($1.year ?? 9999) }
        return TitleCollection(id: id, name: data["name"] as? String ?? "", overview: data["overview"] as? String ?? "",
                               posterPath: data["poster_path"] as? String, backdropPath: data["backdrop_path"] as? String, parts: items)
    }

    // MARK: Search and people, as the server's routes answer them (src/lib/server/tmdb.ts)

    /// Online search (`search/multi`, or `find` for an IMDb id), movies and shows only.
    static func search(_ query: String, page: Int, token: String) async throws -> CatalogPage {
        if query.range(of: #"^tt\d{7,10}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let data = try await object("find/\(query.lowercased())", query: ["external_source": "imdb_id"], token: token)
            let movies = (data["movie_results"] as? [[String: Any]] ?? []).compactMap { catalogItem($0, kind: .movie) }
            let shows = (data["tv_results"] as? [[String: Any]] ?? []).compactMap { catalogItem($0, kind: .tv) }
            return CatalogPage(items: movies + shows, page: 1, totalPages: 1)
        }
        let data = try await object("search/multi", query: ["query": query, "page": String(page), "include_adult": "false", "language": "en-US"], token: token)
        let items = (data["results"] as? [[String: Any]] ?? []).compactMap { item -> CatalogItem? in
            guard item["adult"] as? Bool != true, let type = item["media_type"] as? String, let kind = MediaKind(rawValue: type) else { return nil }
            return catalogItem(item, kind: kind)
        }
        return CatalogPage(items: items, page: data["page"] as? Int ?? page, totalPages: min(data["total_pages"] as? Int ?? 0, 500),
                           totalResults: data["total_results"] as? Int)
    }

    /// People by name (`search/person`), each once, adults left out.
    static func searchPeople(_ query: String, token: String) async throws -> [SearchPerson] {
        let data = try await object("search/person", query: ["query": query, "page": "1", "include_adult": "false", "language": "en-US"], token: token)
        var seen = Set<Int>()
        return (data["results"] as? [[String: Any]] ?? []).compactMap { item in
            guard item["adult"] as? Bool != true, let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty, seen.insert(id).inserted else { return nil }
            return SearchPerson(id: id, name: name, image: CatalogTools.image(item["profile_path"] as? String, size: "w185"))
        }
    }

    /// Keyword tags by name (`search/keyword`), at most 20.
    static func keywords(_ query: String, token: String) async throws -> [TitleKeyword] {
        let q = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard q.count >= 2 else { return [] }
        let data = try await object("search/keyword", query: ["query": q, "page": "1"], token: token)
        return (data["results"] as? [[String: Any]] ?? []).prefix(20).compactMap { item in
            guard let id = item["id"] as? Int, id > 0, let name = item["name"] as? String, !name.isEmpty else { return nil }
            return TitleKeyword(id: id, name: name)
        }
    }

    /// A person's page: details, every credit once (roles and jobs joined), portraits then the
    /// posters and stills they're tagged in, as the server's `person` builds it.
    static func person(_ id: Int, token: String) async throws -> PersonResponse {
        let data = try await object("person/\(id)", query: ["append_to_response": "combined_credits,images,tagged_images", "language": "en-US"], token: token)
        guard data["id"] as? Int == id, let name = data["name"] as? String, !name.isEmpty else { throw APIError.message("TMDB sent an incomplete person.") }
        let combined = data["combined_credits"] as? [String: Any] ?? [:]
        var order: [String] = [], credits: [String: [String: Any]] = [:]
        for item in (combined["cast"] as? [[String: Any]] ?? []) + (combined["crew"] as? [[String: Any]] ?? []) {
            guard item["adult"] as? Bool != true, let type = item["media_type"] as? String, let kind = MediaKind(rawValue: type),
                  let base = catalogItem(item, kind: kind) else { continue }
            let key = base.key
            let character = (item["character"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let job = (item["job"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if var existing = credits[key] {
                func joined(_ field: String, _ value: String, limit: Int) {
                    let current = existing[field] as? String ?? ""
                    guard !value.isEmpty, !current.components(separatedBy: " / ").contains(value) else { return }
                    existing[field] = String([current, value].filter { !$0.isEmpty }.joined(separator: " / ").prefix(limit))
                }
                joined("character", character, limit: 600); joined("job", job, limit: 400)
                credits[key] = existing
                continue
            }
            order.append(key)
            let episodes = (item["episode_count"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let popularity = (item["popularity"] as? Double).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
            credits[key] = [
                "id": base.id, "mediaType": kind.rawValue, "name": base.name, "year": base.year as Any? ?? NSNull(), "overview": base.overview,
                "posterPath": base.posterPath as Any? ?? NSNull(), "backdropPath": base.backdropPath as Any? ?? NSNull(),
                "rating": base.rating as Any? ?? NSNull(), "votes": base.votes ?? 0, "genres": base.genres ?? [],
                "character": character, "job": job, "popularity": popularity, "episodeCount": episodes as Any? ?? NSNull()
            ]
        }
        var seenPhotos = Set<String>(), photos: [[String: Any]] = []
        func photo(_ item: [String: Any], kind: String, title: String?) {
            guard let file = item["file_path"] as? String, CatalogTools.image(file) != nil, seenPhotos.insert(file).inserted else { return }
            let ratio = (item["aspect_ratio"] as? Double).flatMap { $0 > 0.2 && $0 < 5 ? $0 : nil } ?? 0.667
            photos.append(["path": file, "kind": kind, "aspectRatio": ratio, "title": title as Any? ?? NSNull()])
        }
        for item in ((data["images"] as? [String: Any])?["profiles"] as? [[String: Any]] ?? []).prefix(30) { photo(item, kind: "portrait", title: nil) }
        for item in ((data["tagged_images"] as? [String: Any])?["results"] as? [[String: Any]] ?? []).prefix(40) {
            let media = item["media"] as? [String: Any]
            let title = ((media?["title"] as? String) ?? (media?["name"] as? String)).flatMap { $0.isEmpty ? nil : $0 }
            photo(item, kind: item["image_type"] as? String == "poster" ? "poster" : "still", title: title)
        }
        func date(_ key: String) -> Any { (data[key] as? String).flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil } as Any? ?? NSNull() }
        var aliases: [String] = []
        for alias in data["also_known_as"] as? [String] ?? [] where !alias.isEmpty && !aliases.contains(alias) && aliases.count < 20 { aliases.append(alias) }
        let person: [String: Any] = [
            "id": id, "name": name, "biography": data["biography"] as? String ?? "", "birthday": date("birthday"), "deathday": date("deathday"),
            "birthplace": data["place_of_birth"] as? String ?? "", "department": data["known_for_department"] as? String ?? "",
            "profilePath": data["profile_path"] as Any? ?? NSNull(), "aliases": aliases,
            "credits": order.compactMap { credits[$0] }, "photos": Array(photos.prefix(60))
        ]
        return try JSONDecoder().decode(PersonResponse.self, from: JSONSerialization.data(withJSONObject: ["person": person, "stale": false]))
    }

    // MARK: Discovery, as the server's /api/discovery answers it

    /// Explore and Canvas shelves: TMDB's weekly trending, `discover` with the same filters, "because
    /// you watched" (a title of yours, by its TMDB id) and Trakt picks (`tmdbIds`, read from Trakt on
    /// the phone), each filled in from TMDB here.
    static func discover(_ q: [String: String], workspace: Workspace, token: String) async throws -> CatalogPage {
        let source = q["source"] ?? "tmdb"
        guard let kind = MediaKind(rawValue: q["type"] ?? "movie") else { throw APIError.message("Choose valid discovery filters") }
        let type = kind.rawValue
        let sort = q["sort"] ?? "popular"
        let page = Int(q["page"] ?? "1") ?? 1
        let minimum = Double(q["minimum"] ?? "0") ?? 0
        func filtered(_ items: [CatalogItem]) -> [CatalogItem] {
            let kept = items.filter { item in
                (q["genre"].map { $0.isEmpty || (item.genres ?? []).contains($0) } ?? true)
                && (q["year"].map { $0.isEmpty || item.year.map(String.init) == $0 } ?? true)
                && (minimum == 0 || (item.rating ?? -1) >= minimum)
            }
            switch sort {
            case "rating": return kept.sorted { ($0.rating ?? -1) != ($1.rating ?? -1) ? ($0.rating ?? -1) > ($1.rating ?? -1) : ($0.votes ?? 0) > ($1.votes ?? 0) }
            case "newest": return kept.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            default: return kept
            }
        }
        if source == "trakt" {
            let limit = Int(q["limit"] ?? "8") ?? 8
            var ids: [Int] = []
            for id in (q["tmdbIds"] ?? "").split(separator: ",").compactMap({ Int($0) }) where !ids.contains(id) && ids.count < limit { ids.append(id) }
            var items: [CatalogItem] = []
            // Four at a time, in the picks' order.
            for start in stride(from: 0, to: ids.count, by: 4) {
                let chunk = Array(ids[start..<min(start + 4, ids.count)])
                let found = await withTaskGroup(of: (Int, CatalogDetails?).self) { group in
                    for (index, id) in chunk.enumerated() { group.addTask { (index, try? await details(CatalogRoute(kind: kind, id: id), token: token)) } }
                    var all: [(Int, CatalogDetails?)] = []
                    for await result in group { all.append(result) }
                    return all.sorted { $0.0 < $1.0 }.compactMap(\.1)
                }
                for detail in found {
                    let genres = detail.genres.map { name in
                        name == "Science Fiction" || name == "Sci-Fi & Fantasy" ? "Sci-fi & fantasy"
                        : name == "Action" || name == "Action & Adventure" ? "Action & adventure" : name
                    }
                    items.append(CatalogItem(id: detail.id, mediaType: kind, name: detail.name, year: detail.year, overview: detail.overview,
                                             posterPath: detail.posterPath, backdropPath: detail.backdropPath, genres: genres))
                }
            }
            if !ids.isEmpty && items.isEmpty { throw APIError.message("Trakt responded, but poster metadata could not be loaded. Try again.") }
            return CatalogPage(items: filtered(items), page: 1, totalPages: 1)
        }
        var params: [String: String] = ["page": String(page), "include_adult": "false", "language": "en-US"]
        let path: String
        var trending = false
        if source == "because" {
            guard let seed = q["seed"], let title = workspace.activeTitles.first(where: { $0.id == seed }) else {
                throw APIError.message("Choose a watched title for recommendations.")
            }
            guard let id = title.tmdbId else { throw APIError.message("Match this title to TMDb first.") }
            path = "\(title.isSeries ? "tv" : "movie")/\(id)/recommendations"
        } else {
            let genre = DiscoveryGenre.all.first { $0.name == q["genre"] }
            let genreID = genre.flatMap { kind == .movie ? $0.movie : $0.tv }
            let keyword = q["keyword"].flatMap(Int.init) ?? (kind == .tv && !(q["genre"] ?? "").isEmpty && genreID == nil ? SearchLabData.tvGenreKeywords[q["genre"] ?? ""] : nil)
            let lab = ["keywords", "genres", "certification", "yearFrom", "yearTo", "status", "language"].contains { !(q[$0] ?? "").isEmpty }
            trending = sort == "trending" && keyword == nil && (q["company"] ?? "").isEmpty && (q["network"] ?? "").isEmpty && !lab
            if trending {
                path = "trending/\(type)/week"
            } else {
                path = "discover/\(type)"
                let dateField = kind == .movie ? "primary_release_date" : "first_air_date"
                params["sort_by"] = sort == "rating" ? "vote_average.desc" : sort == "newest" ? dateField + ".desc" : "popularity.desc"
                if let keyword { params["with_keywords"] = String(keyword) }
                if let genreID, q["keyword"] != nil || keyword == nil { params["with_genres"] = String(genreID) }
                if let company = q["company"], !company.isEmpty { params["with_companies"] = company }
                let keywords = (q["keywords"] ?? "").split(separator: ",").map(String.init)
                if !keywords.isEmpty { params["with_keywords"] = keywords.joined(separator: q["keywordMode"] == "all" ? "," : "|") }
                let names = (q["genres"] ?? "").split(separator: ",").map(String.init)
                if !names.isEmpty {
                    let ids = names.compactMap { name in DiscoveryGenre.all.first { $0.name == name }.flatMap { kind == .movie ? $0.movie : $0.tv } }
                    if !ids.isEmpty { params["with_genres"] = ids.map(String.init).joined(separator: ",") }
                    let missing = kind == .tv ? names.compactMap { SearchLabData.tvGenreKeywords[$0] }.map(String.init) : []
                    if !missing.isEmpty { params["with_keywords"] = ([params["with_keywords"] ?? ""] + missing).filter { !$0.isEmpty }.joined(separator: ",") }
                }
                if let rating = q["certification"], !rating.isEmpty, kind == .movie { params["certification_country"] = "US"; params["certification"] = rating }
                if let from = q["yearFrom"], !from.isEmpty { params[dateField + ".gte"] = from + "-01-01" }
                if let to = q["yearTo"], !to.isEmpty { params[dateField + ".lte"] = to + "-12-31" }
                if kind == .tv, let status = q["status"], let code = ["returning": "0", "production": "2", "ended": "3", "canceled": "4"][status] { params["with_status"] = code }
                if let language = q["language"], !language.isEmpty { params["with_original_language"] = language }
                if kind == .tv, let network = q["network"], !network.isEmpty { params["with_networks"] = network }
                if let year = q["year"], !year.isEmpty { params[kind == .movie ? "primary_release_year" : "first_air_date_year"] = year }
                params["vote_count.gte"] = sort == "rating" ? "200" : "20"
                if minimum > 0 { params["vote_average.gte"] = q["minimum"] }
                let today = Date.now.formatted(.iso8601.year().month().day())
                if (params[dateField + ".lte"] ?? "9999") > today { params[dateField + ".lte"] = today }
            }
        }
        let data = try await object(path, query: params, token: token)
        let items = (data["results"] as? [[String: Any]] ?? []).filter { ($0["adult"] as? Bool) != true }.compactMap { catalogItem($0, kind: kind) }
        return CatalogPage(items: trending || source == "because" ? filtered(items) : items, page: data["page"] as? Int ?? page,
                           totalPages: min(data["total_pages"] as? Int ?? 0, 500), totalResults: data["total_results"] as? Int)
    }

    /// One TMDB v3 read. A v4 read access token goes in the Authorization header; a 32-character
    /// v3 API key goes in `api_key`.
    static func object(_ path: String, query: [String: String], token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let apiKey = token.count == 32 && token.allSatisfy(\.isHexDigit)
        if apiKey { items.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw APIError.message("Invalid TMDB request.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("TMDB didn't answer.") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.message(http.statusCode == 401 ? "TMDB didn't accept your key. Check it in Settings → TMDB." : "TMDB is unavailable right now (\(http.statusCode)).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.message("TMDB sent an unexpected reply.") }
        return object
    }
}
