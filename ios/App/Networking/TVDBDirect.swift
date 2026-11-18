import Foundation
import TwilDiaryCore

@MainActor enum TVDBDirect {
    private static let base = URL(string: "https://api4.thetvdb.com/v4")!
    private static var session: (key: String, token: String, loaded: Date)?
    private static var signingIn: (key: String, id: UUID, task: Task<String, Error>)?
    private static var listDetailsCache: [Int: (date: Date, contents: ListContents)] = [:]
    private static var listTitles: [ListEntry: (date: Date, title: ListTitle)] = [:]
    private static let englishAwardTitles: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()
    static var builtIn: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryTVDBKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static func key(_ store: DiaryStore) -> String? {
        store.providerSettings.customTvdbKey ?? builtIn
    }

    /// Verify both the project key and read access to the Awards catalog.
    static func checkConnection(key: String) async throws {
        struct Awards: Decodable {
            struct Award: Decodable { let id: Int }
            let data: [Award]
        }
        let token = try await login(key: key)
        let reply = try await send(request("awards", token: token), as: Awards.self)
        guard !reply.data.isEmpty else { throw APIError.message("TheTVDB returned an empty Awards catalog.") }
    }

    private struct AwardReply<Value: Decodable>: Decodable {
        let data: Value
    }

    static func awardCatalog(key: String) async throws -> [SearchAwardCeremony] {
        let reply = try await authorized("awards", key: key, as: AwardReply<[SearchAwardCeremony]>.self)
        var ids = Set<Int>()
        let catalog = reply.data.filter { $0.id > 0 && !$0.name.isEmpty && ids.insert($0.id).inserted }
        guard !catalog.isEmpty else { throw APIError.message("TheTVDB returned an empty Awards catalog.") }
        return catalog
    }

    static func awardCategories(_ id: Int, key: String) async throws -> [SearchAwardCategory] {
        struct Ceremony: Decodable {
            let id: Int
            let categories: [SearchAwardCategory]?
        }
        let reply = try await authorized("awards/\(id)/extended", key: key, as: AwardReply<Ceremony>.self)
        guard reply.data.id == id else { throw APIError.message("TheTVDB returned a different award.") }
        var ids = Set<Int>()
        return (reply.data.categories ?? []).filter { $0.id > 0 && !$0.name.isEmpty && ids.insert($0.id).inserted }
    }

    static func awardResults(_ id: Int, key: String) async throws -> SearchAwardResults {
        let reply = try await authorized("awards/categories/\(id)/extended", key: key, as: AwardReply<SearchAwardResults>.self)
        guard reply.data.id == id else { throw APIError.message("TheTVDB returned a different category.") }
        return reply.data
    }

    static func awardPersonTMDB(_ id: Int, key: String) async throws -> Int? {
        struct Person: Decodable { let remoteIds: [ListTitle.Remote]? }
        let reply = try await authorized("people/\(id)/extended", key: key, as: AwardReply<Person>.self)
        return reply.data.remoteIds?.first { $0.sourceName == "TheMovieDB.com" }
            .flatMap { Int($0.id) }.flatMap { $0 > 0 ? $0 : nil }
    }

    static func englishAwardTitle(_ item: ListEntry, key: String) async throws -> String? {
        struct Translation: Decodable { let name: String? }
        let cacheKey = item.id as NSString
        if let cached = englishAwardTitles.object(forKey: cacheKey) {
            return cached.length == 0 ? nil : cached as String
        }
        let reply = try await authorized("\(item.path)/\(item.providerID)/translations/eng", key: key, as: AwardReply<Translation?>.self)
        let name = reply.data?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        englishAwardTitles.setObject(name as NSString, forKey: cacheKey)
        return name.isEmpty ? nil : name
    }

    private static func login(key: String) async throws -> String {
        struct Login: Decodable {
            struct Credentials: Decodable { let token: String }
            let data: Credentials
        }
        var login = URLRequest(url: base.appending(path: "login"), timeoutInterval: 15)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue("application/json", forHTTPHeaderField: "Accept")
        login.httpBody = try JSONEncoder().encode(["apikey": key])
        let token = try await send(login, as: Login.self).data.token
        guard !token.isEmpty else { throw APIError.message("TheTVDB did not return an access token.") }

        return token
    }

    struct Franchise: Decodable, Hashable, Identifiable, Sendable {
        let id: Int
        let name: String
        let image: String?
        let score: Double?
        let isOfficial: Bool?
    }

    struct ListPage: Sendable {
        let franchises: [Franchise]
        let hasNext: Bool
    }

    struct ListEntry: Hashable, Sendable, Identifiable {
        let providerID: Int
        let kind: MediaKind
        var id: String { "\(kind.rawValue):\(providerID)" }
        var path: String { kind == .tv ? "series" : "movies" }
        var webLink: URL {
            URL(string: "https://www.thetvdb.com/dereferrer/\(kind == .tv ? "series" : "movie")/\(providerID)")!
        }
    }

    struct ListContents: Sendable {
        let artwork: String?
        let entries: [ListEntry]
    }

    static func artworkURL(_ path: String?) -> String? {
        guard let value = path?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let address = value.hasPrefix("/banners/") ? "https://artworks.thetvdb.com" + value : value
        guard let url = URL(string: address), url.scheme == "https",
              url.host == "artworks.thetvdb.com", url.path.hasPrefix("/banners/") else { return nil }
        return url.absoluteString
    }

    struct ListTitle: Decodable, Sendable {
        struct Remote: Decodable, Sendable {
            let id: String
            let sourceName: String?
        }
        let name: String
        let image: String?
        let year: String?
        let remoteIds: [Remote]?
        var tmdbID: Int? {
            remoteIds?.first { $0.sourceName == "TheMovieDB.com" }
                .flatMap { Int($0.id) }.flatMap { $0 > 0 ? $0 : nil }
        }
        var imdbID: String? {
            guard let value = remoteIds?.first(where: { $0.sourceName?.caseInsensitiveCompare("IMDb") == .orderedSame })?.id,
                  value.range(of: #"^tt\d{7,10}$"#, options: .regularExpression) != nil else { return nil }
            return value
        }
    }

    private struct ListLinks: Decodable {
        let next: String?
    }

    static func franchises(page: Int, query: String, key: String) async throws -> ListPage {
        if query.count >= 2 {
            struct Search: Decodable {
                struct Result: Decodable {
                    let tvdb_id: String
                    let name: String
                    let image_url: String?
                }
                let data: [Result]?
                let links: ListLinks?
            }
            let reply = try await authorized("search", query: [
                "type": "list", "query": query, "limit": "24", "page": String(page)
            ], key: key, as: Search.self)
            let lists = (reply.data ?? []).compactMap { hit -> Franchise? in
                guard let id = Int(hit.tvdb_id), id > 0, !hit.name.isEmpty else { return nil }
                return Franchise(id: id, name: hit.name, image: hit.image_url, score: nil, isOfficial: nil)
            }
            return ListPage(franchises: lists, hasNext: reply.links?.next != nil)
        }
        struct Reply: Decodable {
            let data: [Franchise]
            let links: ListLinks?
        }
        let reply = try await authorized("lists", query: ["page": String(page)], key: key, as: Reply.self)
        let lists = reply.data.filter { $0.isOfficial == true && $0.id > 0 && !$0.name.isEmpty }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        return ListPage(franchises: lists, hasNext: reply.links?.next != nil)
    }

    static func listContents(_ franchise: Franchise, key: String) async throws -> ListContents {
        struct Reply: Decodable {
            struct Result: Decodable {
                struct Entry: Decodable { let order: Int?; let seriesId: Int?; let movieId: Int? }
                let id: Int
                let image: String?
                let entities: [Entry]?
            }
            let data: Result
        }
        if let cached = listDetailsCache[franchise.id], Date.now.timeIntervalSince(cached.date) < 900 {
            return cached.contents
        }
        let reply = try await authorized("lists/\(franchise.id)/extended", key: key, as: Reply.self)
        guard reply.data.id == franchise.id else { throw APIError.message("TheTVDB returned a different list.") }
        var seen = Set<String>()
        let entries: [ListEntry] = (reply.data.entities ?? []).sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }.compactMap {
            let entry: ListEntry
            if let series = $0.seriesId, series > 0 { entry = ListEntry(providerID: series, kind: .tv) }
            else if let movie = $0.movieId, movie > 0 { entry = ListEntry(providerID: movie, kind: .movie) }
            else { return nil }
            return seen.insert(entry.id).inserted ? entry : nil
        }
        let contents = ListContents(artwork: artworkURL(reply.data.image), entries: entries)
        if listDetailsCache.count >= 64 { listDetailsCache.removeAll(keepingCapacity: true) }
        listDetailsCache[franchise.id] = (.now, contents)
        return contents
    }

    static func title(_ item: ListEntry, key: String) async throws -> ListTitle {
        struct Reply: Decodable { let data: ListTitle }
        if let cached = listTitles[item], Date.now.timeIntervalSince(cached.date) < 900 { return cached.title }
        let title = try await authorized("\(item.path)/\(item.providerID)/extended", query: ["short": "true"], key: key, as: Reply.self).data
        if listTitles.count >= 256 { listTitles.removeAll(keepingCapacity: true) }
        listTitles[item] = (.now, title)
        return title
    }

    private static func browseToken(key: String) async throws -> String {
        if let session, session.key == key, Date.now.timeIntervalSince(session.loaded) < 3600 { return session.token }
        let pending: (key: String, id: UUID, task: Task<String, Error>)
        if let signingIn, signingIn.key == key { pending = signingIn }
        else {
            pending = (key, UUID(), Task { try await login(key: key) })
            signingIn = pending
        }
        defer { if signingIn?.id == pending.id { signingIn = nil } }
        let token = try await pending.task.value
        if signingIn?.id == pending.id { session = (key, token, .now) }
        try Task.checkCancellation()
        return token
    }

    /// TheTVDB refused the sign-in (401/403).
    private struct Rejected: LocalizedError {
        var errorDescription: String? { "TheTVDB didn’t accept these credentials. Check the API key." }
    }
    /// A read with the kept sign-in. One TheTVDB rejects (expired or revoked) is dropped and the
    /// read tried once more with a fresh sign-in; before, every read failed until the hour was up.
    private static func authorized<T: Decodable>(_ path: String, query: [String: String] = [:], key: String, as type: T.Type) async throws -> T {
        let token = try await browseToken(key: key)
        do { return try await send(request(path, query: query, token: token), as: type) }
        catch is Rejected {
            if session?.token == token { session = nil }
            let fresh = try await browseToken(key: key)
            return try await send(request(path, query: query, token: fresh), as: type)
        }
    }

    private static func request(_ path: String, query: [String: String] = [:], token: String) -> URLRequest {
        var url = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw APIError.message("TheTVDB didn’t answer.")
        }
        switch status {
        case 200..<300: break
        case 401, 403: throw Rejected()
        case 429: throw APIError.message("TheTVDB is busy. Try checking the connection again shortly.")
        default: throw APIError.message("TheTVDB is unavailable right now (\(status)).")
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.message("TheTVDB sent an unexpected reply.") }
    }
}
