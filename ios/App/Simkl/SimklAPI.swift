import Foundation

/// Simkl's API as the add-on uses it: your sign-in as Bearer, the app ID as `simkl-api-key`, and
/// the app's name and version on every request, as Simkl asks.
struct SimklAPI: Sendable {
    static let base = "https://api.simkl.com"
    let token: String?
    var session: URLSession = .shared

    enum Failure: Error, Equatable {
        /// Simkl refused the sign-in.
        case signIn
        /// Too many requests, or another write still running ("rate_limit"): wait this long.
        case busy(TimeInterval)
        /// No answer, or Simkl having trouble: try again later.
        case unavailable(String)
        /// Simkl refused this request.
        case refused(Int, String)
    }

    func get(_ path: String, query: [String: String] = [:]) async throws -> Data { try await send(path, method: "GET", query: query, body: nil) }
    func post(_ path: String, body: Data) async throws -> Data { try await send(path, method: "POST", query: [:], body: body) }

    private func request(_ path: String, method: String, query: [String: String], body: Data?) -> URLRequest {
        var components = URLComponents(string: Self.base + path)!
        components.queryItems = (query.merging(["client_id": SimklAccount.clientId, "app-name": "twildiary", "app-version": "2.0"]) { first, _ in first })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TwilDiary/2.0", forHTTPHeaderField: "User-Agent")
        request.setValue(SimklAccount.clientId, forHTTPHeaderField: "simkl-api-key")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ path: String, method: String, query: [String: String], body: Data?) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request(path, method: method, query: query, body: body)) }
        catch { throw Failure.unavailable(error.localizedDescription) }
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        try Self.check(status: status, data: data, http: http)
        return data
    }
    private static func check(status: Int, data: Data, http: HTTPURLResponse?) throws {
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        switch status {
        case 401, 403: throw Failure.signIn
        // The account's daily allowance used up ("user_limit_exceeded"): waits for the next day (UTC).
        case 429 where text.contains("user_limit"): throw Failure.busy(untilTomorrow())
        case 429: throw Failure.busy(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
        // Simkl takes one write per account at a time; a second one is refused with "rate_limit".
        case 400 where text.contains("rate_limit"): throw Failure.busy(5)
        case 500...: throw Failure.unavailable("Simkl answered HTTP \(status).")
        default: throw Failure.refused(status, text.isEmpty ? "HTTP \(status)" : text)
        }
    }

    static func untilTomorrow(now: Date = .now) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3_600)
        return max(60, next.timeIntervalSince(now))
    }

    // MARK: Finding a title

    /// Simkl's own entry, and whether Simkl files it as anime, a show (tv) or a movie.
    struct Match: Codable, Equatable, Sendable { let simkl: Int; let kind: String }

    /// Simkl's `/redirect` (its docs' lightest lookup, as Cinopsys finds titles): answered with the
    /// entry's address (simkl.com/anime/509292/…), or Simkl's home page when it has no such title.
    func redirect(_ query: [String: String]) async throws -> Match? {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request("/redirect", method: "GET", query: query.merging(["to": "simkl"]) { first, _ in first }, body: nil),
                                                      delegate: SimklNoRedirects()) }
        catch { throw Failure.unavailable(error.localizedDescription) }
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
        if (300..<400).contains(status) { return Self.match(location: http?.value(forHTTPHeaderField: "Location") ?? "") }
        if (200..<300).contains(status) { return nil }
        try Self.check(status: status, data: data, http: http)
        return nil
    }
    static func match(location: String) -> Match? {
        guard let url = URL(string: location), url.host?.hasSuffix("simkl.com") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let simkl = Int(parts[1]), simkl > 0 else { return nil }
        switch parts[0] {
        case "anime": return Match(simkl: simkl, kind: "anime")
        case "tv": return Match(simkl: simkl, kind: "tv")
        case "movies": return Match(simkl: simkl, kind: "movie")
        default: return nil
        }
    }
    /// A show never takes a movie, nor a movie a show (Cinopsys's check): TMDB's ids collide across
    /// kinds (TMDB 65942 is Re:Zero as a show and another film as a movie). Anime can be either.
    static func accepts(_ match: Match, movie: Bool) -> Bool { movie ? match.kind != "tv" : match.kind != "movie" }

    /// `/search/id`'s answer (kept for reading a search reply).
    static func match(from data: Data) -> Match? {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        guard let first = rows.first, let ids = first["ids"] as? [String: Any] else { return nil }
        let simkl = (ids["simkl"] as? NSNumber)?.intValue ?? (ids["simkl_id"] as? NSNumber)?.intValue ?? Int(ids["simkl"] as? String ?? "")
        guard let simkl, simkl > 0 else { return nil }
        return Match(simkl: simkl, kind: (first["type"] as? String) ?? (first["endpoint_type"] as? String) ?? "tv")
    }

    /// An anime by its title and year (Simkl files some films, such as ONAs, as anime with no TMDB
    /// id): the result whose title and year match.
    func searchAnime(title: String, year: Int?) async throws -> Match? {
        Self.pickAnime(from: try await get("/search/anime", query: ["q": title, "limit": "10"]), title: title, year: year)
    }
    static func pickAnime(from data: Data, title: String, year: Int?) -> Match? {
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = plain(title)
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        for row in rows {
            let ids = row["ids"] as? [String: Any] ?? [:]
            guard let simkl = (ids["simkl_id"] as? NSNumber)?.intValue ?? (ids["simkl"] as? NSNumber)?.intValue, simkl > 0 else { continue }
            let rowYear = (row["year"] as? NSNumber)?.intValue
            if let year, let rowYear, abs(rowYear - year) > 1 { continue }
            let names = ["title", "title_en", "title_romaji"].compactMap { row[$0] as? String }.map(plain)
            if !wanted.isEmpty, names.contains(wanted) { return Match(simkl: simkl, kind: "anime") }
        }
        return nil
    }

    /// An anime's own anime-database ids (MAL, AniDB, AniList: one per Simkl entry, unlike TMDB's,
    /// which a show's cours share) and the entries Simkl links to it.
    struct Related: Codable, Equatable, Sendable {
        let simkl: Int; let tmdb: String?; let year: Int?; var type: String? = nil
        var native: [String: String]? = nil
    }
    struct Detail: Codable, Equatable, Sendable { let native: [String: String]; let related: [Related] }
    static let nativeKeys = ["mal", "anidb", "anilist"]
    static func native(_ ids: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for key in nativeKeys {
            if let text = ids[key] as? String, !text.isEmpty { out[key] = text }
            else if let number = ids[key] as? NSNumber { out[key] = number.stringValue }
        }
        return out
    }
    func detail(of simkl: Int) async throws -> Detail {
        Self.detail(from: try await get("/anime/\(simkl)", query: ["extended": "full"]))
    }
    static func detail(from data: Data) -> Detail {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let related: [Related] = ((root?["relations"] as? [[String: Any]]) ?? []).compactMap { row in
            let ids = row["ids"] as? [String: Any] ?? [:]
            guard let simkl = (ids["simkl"] as? NSNumber)?.intValue else { return nil }
            let tmdb = (ids["tmdb"] as? String) ?? (ids["tmdb"] as? NSNumber)?.stringValue
            return Related(simkl: simkl, tmdb: tmdb, year: (row["year"] as? NSNumber)?.intValue, type: row["anime_type"] as? String, native: native(ids))
        }
        return Detail(native: native(root?["ids"] as? [String: Any] ?? [:]), related: related)
    }
    static func related(from data: Data) -> [Related] { detail(from: data).related }

    // MARK: A show's episodes (for placing one by its air date)

    struct Episode: Codable, Equatable, Sendable {
        let number: Int
        /// The day it aired ("2026-11-14").
        let day: String?
        let special: Bool
        /// The same episode in TVDB's numbering, when Simkl knows it.
        let tvdbSeason: Int?
        let tvdbEpisode: Int?
    }
    func episodes(of match: Match) async throws -> [Episode] {
        Self.episodes(from: try await get((match.kind == "anime" ? "/anime/episodes/" : "/tv/episodes/") + String(match.simkl)))
    }
    static func episodes(from data: Data) -> [Episode] {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let number = (row["episode"] as? NSNumber)?.intValue else { return nil }
            let tvdb = row["tvdb"] as? [String: Any]
            let date = (row["date"] as? String).map { String($0.prefix(10)) }
            return Episode(number: number, day: date?.count == 10 ? date : nil, special: (row["type"] as? String) == "special",
                           tvdbSeason: (tvdb?["season"] as? NSNumber)?.intValue, tvdbEpisode: (tvdb?["episode"] as? NSNumber)?.intValue)
        }
    }
}

/// Keeps `/redirect`'s answer instead of following it to Simkl's web page.
final class SimklNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// A title's IMDb and TVDB ids, from TMDB (sent beside TMDB's, as Simkl's docs recommend, and used
/// to find a title Simkl doesn't link to TMDB).
struct SimklExternalIDs: Codable, Equatable, Sendable { let imdb: String?; let tvdb: Int? }

/// The bodies Simkl's sync routes take, and what its replies say.
enum SimklBody {
    /// Simkl's own id goes with the write, except for anime episodes: Simkl's guide sends those by
    /// TMDB id in TVDB's seasons, so Simkl picks the right cour (its entries are one per cour, and
    /// pinning the looked-up one put every episode on that cour).
    static func pin(_ job: SimklJob, _ match: SimklAPI.Match?) -> Int? {
        job.anime && !job.movie ? nil : match?.simkl
    }
    /// The not_found part of Simkl's answer, short, for the Not kept list.
    static func missingPart(_ reply: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any], let missing = root["not_found"],
              let data = try? JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys]) else {
            return String(data: reply.prefix(300), encoding: .utf8)
        }
        return String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
    }

    /// Where a batch goes.
    static func path(_ kind: SimklJob.Kind) -> String {
        switch kind {
        case .watch: "/sync/history"
        case .unwatch: "/sync/history/remove"
        case .rate: "/sync/ratings"
        case .unrate: "/sync/ratings/remove"
        case .list: "/sync/add-to-list"
        }
    }

    /// Every id known for an item (Cinopsys sends all it has, and Simkl's docs ask for as many as
    /// possible): TMDB, IMDb, TVDB (shows) and Simkl's own. A placed entry goes by its Simkl id and
    /// its own anime-database ids, never TMDB's, IMDb's or TVDB's, which a show's cours share and
    /// which would lead back to the first cour.
    static func ids(_ job: SimklJob, simkl: Int?, external: SimklExternalIDs?) -> [String: Any] {
        if let entry = job.entry {
            var ids: [String: Any] = ["simkl": entry]
            for (key, value) in job.entryIDs ?? [:] { ids[key] = Int(value) ?? value }
            return ids
        }
        var ids: [String: Any] = ["tmdb": job.tmdb]
        if let imdb = external?.imdb { ids["imdb"] = imdb }
        if !job.movie, let tvdb = external?.tvdb { ids["tvdb"] = tvdb }
        if let simkl { ids["simkl"] = simkl }
        return ids
    }

    /// One item of a request: a title (or one Simkl entry of it) with its jobs.
    struct Group {
        let jobs: [SimklJob]
        let ids: [String: Any]
    }
    /// A batch as items, in order: one per title, Simkl entry and numbering.
    static func groups(_ jobs: [SimklJob], simkl: (SimklJob) -> Int?, external: (SimklJob) -> SimklExternalIDs?) -> [Group] {
        var order: [String] = [], byKey: [String: [SimklJob]] = [:]
        for job in jobs {
            let key = "\(job.titleKey)|\(job.entry ?? 0)|\(job.ownNumbering)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(job)
        }
        return order.compactMap { key in
            guard let list = byKey[key], let first = list.first else { return nil }
            return Group(jobs: list, ids: ids(first, simkl: simkl(first), external: external(first)))
        }
    }
    /// The request: several titles in one (Simkl's docs: every write takes arrays).
    static func body(_ groups: [Group]) -> Data {
        var movies: [[String: Any]] = [], shows: [[String: Any]] = []
        for group in groups {
            guard let first = group.jobs.first else { continue }
            var item: [String: Any] = ["title": first.name, "ids": group.ids]
            if let year = first.year { item["year"] = year }
            switch first.kind {
            case .rate: item["rating"] = first.rating ?? 0
            case .list: item["to"] = first.list ?? "plantowatch"
            case .unrate: break
            case .watch, .unwatch:
                if first.movie && first.entry != nil {
                    // A film Simkl files as an anime entry: its one episode (a removal takes the entry).
                    if first.kind == .watch {
                        var episode: [String: Any] = ["number": 1]
                        if let when = first.watchedAt { episode["watched_at"] = when }
                        item["seasons"] = [["number": 1, "episodes": [episode]] as [String: Any]]
                    }
                } else if first.movie {
                    if first.kind == .watch, let when = first.watchedAt { item["watched_at"] = when }
                } else {
                    // Anime in TVDB's seasons (TMDB's mostly match), unless placed in Simkl's own numbering.
                    if first.anime && !first.ownNumbering && first.entry == nil { item["use_tvdb_anime_seasons"] = true }
                    let seasons = Dictionary(grouping: group.jobs) { $0.season ?? 1 }
                    item["seasons"] = seasons.keys.sorted().map { season in
                        ["number": season, "episodes": (seasons[season] ?? []).map { job -> [String: Any] in
                            var episode: [String: Any] = ["number": job.number ?? 0]
                            if job.kind == .watch, let when = job.watchedAt { episode["watched_at"] = when }
                            return episode
                        }] as [String: Any]
                    }
                }
            }
            if first.movie && first.entry == nil { movies.append(item) } else { shows.append(item) }
        }
        var root: [String: Any] = [:]
        if !movies.isEmpty { root["movies"] = movies }
        if !shows.isEmpty { root["shows"] = shows }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    /// One title's request (as before batching).
    static func body(_ jobs: [SimklJob], simkl: Int?) -> Data {
        body(groups(jobs, simkl: { _ in simkl }, external: { _ in nil }))
    }

    /// Which jobs Simkl couldn't place. Its not_found items are copies of what was sent, so each is
    /// matched to its title by the ids it carries (or its title); one TwilDiary can't attribute
    /// counts for all of the batch's items of that kind. Episodes it names: those; otherwise all of
    /// that item's episodes.
    static func notFound(_ reply: Data, groups: [Group]) -> Set<String> {
        guard let root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let missing = root["not_found"] as? [String: Any] else { return [] }
        func owns(_ item: [String: Any], _ group: Group) -> Bool {
            let theirs = item["ids"] as? [String: Any] ?? [:]
            for (key, value) in theirs where key != "slug" {
                if let mine = group.ids[key], "\(mine)" == "\(value)" { return true }
            }
            return theirs.isEmpty && (item["title"] as? String) == group.jobs.first?.name
        }
        func places(_ item: [String: Any]) -> Set<String> {
            var out = Set<String>()
            let number = (item["number"] as? NSNumber)?.intValue ?? (item["episode"] as? NSNumber)?.intValue
            if let season = (item["season"] as? NSNumber)?.intValue, let number { out.insert("\(season):\(number)") }
            for season in (item["seasons"] as? [[String: Any]]) ?? [] {
                guard let s = (season["number"] as? NSNumber)?.intValue else { continue }
                for episode in (season["episodes"] as? [[String: Any]]) ?? [] {
                    if let n = (episode["number"] as? NSNumber)?.intValue { out.insert("\(s):\(n)") }
                }
            }
            return out
        }
        func place(_ job: SimklJob) -> String { "\(job.season ?? 1):\(job.number ?? 0)" }
        var out = Set<String>()
        for key in ["movies", "shows", "anime"] {
            for item in (missing[key] as? [[String: Any]]) ?? [] {
                let owners = groups.filter { owns(item, $0) }
                let named = places(item)
                for group in owners.isEmpty ? groups : owners {
                    let some = named.isEmpty ? [] : group.jobs.filter { named.contains(place($0)) }
                    out.formUnion((some.isEmpty ? group.jobs : some).map(\.id))
                }
            }
        }
        let episodes = (missing["episodes"] as? [[String: Any]]) ?? []
        if !episodes.isEmpty {
            let shows = groups.flatMap(\.jobs).filter { !$0.movie || $0.entry != nil }
            let named = episodes.reduce(into: Set<String>()) { $0.formUnion(places($1)) }
            let some = shows.filter { named.contains(place($0)) }
            out.formUnion((some.isEmpty ? shows : some).map(\.id))
        }
        return out
    }
    /// One title's answer (as before batching).
    static func notFound(_ reply: Data, sent jobs: [SimklJob]) -> Set<String> {
        notFound(reply, groups: groups(jobs, simkl: { _ in nil }, external: { _ in nil }))
    }

    /// The episode Simkl lists on that day (a day either side: time zones). A regular episode is
    /// never placed on a special; a special prefers a special (an OVA entry lists its parts as
    /// regular episodes). `anyKind` false: a special matches only a special (inside a show's own
    /// entries).
    static func find(day: String, in episodes: [SimklAPI.Episode], special: Bool = false, anyKind: Bool = true) -> SimklAPI.Episode? {
        episodes.filter { episode in (special ? anyKind || episode.special : !episode.special) && (episode.day.map { daysApart($0, day) <= 1 } ?? false) }
            .min { (daysApart($0.day ?? "", day), $0.special == special ? 0 : 1) < (daysApart($1.day ?? "", day), $1.special == special ? 0 : 1) }
    }
    /// `find`, and for a regular episode Simkl dates differently (a premiere it dates by its early
    /// screening: Re:Zero's third season), the one before the episode a week later, or after the one
    /// a week earlier: weekly shows keep their order.
    static func locate(day: String, in episodes: [SimklAPI.Episode], special: Bool, anyKind: Bool = true) -> SimklAPI.Episode? {
        if let found = find(day: day, in: episodes, special: special, anyKind: anyKind) { return found }
        guard !special else { return nil }
        if let later = shift(day, by: 7).flatMap({ find(day: $0, in: episodes) }),
           let found = episodes.first(where: { !$0.special && $0.number == later.number - 1 }) { return found }
        if let earlier = shift(day, by: -7).flatMap({ find(day: $0, in: episodes) }),
           let found = episodes.first(where: { !$0.special && $0.number == earlier.number + 1 }) { return found }
        return nil
    }
    static func shift(_ day: String, by days: Int) -> String? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func daysApart(_ first: String, _ second: String) -> Int {
        func date(_ text: String) -> Date? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let a = date(first), let b = date(second) else { return .max }
        return Int((abs(a.timeIntervalSince(b)) / 86_400).rounded())
    }
}
