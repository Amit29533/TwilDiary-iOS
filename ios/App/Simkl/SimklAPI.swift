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

    private func send(_ path: String, method: String, query: [String: String], body: Data?) async throws -> Data {
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
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.unavailable(error.localizedDescription) }
        let http = response as? HTTPURLResponse, status = http?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        switch status {
        case 401, 403: throw Failure.signIn
        case 429: throw Failure.busy(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
        // Simkl takes one write per account at a time; a second one is refused with "rate_limit".
        case 400 where text.contains("rate_limit"): throw Failure.busy(5)
        case 500...: throw Failure.unavailable("Simkl answered HTTP \(status).")
        default: throw Failure.refused(status, text.isEmpty ? "HTTP \(status)" : text)
        }
    }

    // MARK: Finding a title

    /// Simkl's own entry for a TMDB id, and whether Simkl files it as anime, a show or a movie.
    struct Match: Codable, Equatable, Sendable { let simkl: Int; let kind: String }

    func match(tmdb: Int, movie: Bool) async throws -> Match? {
        Self.match(from: try await get("/search/id", query: ["tmdb": String(tmdb), "type": movie ? "movie" : "show"]))
    }
    static func match(from data: Data) -> Match? {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        guard let first = rows.first, let ids = first["ids"] as? [String: Any] else { return nil }
        let simkl = (ids["simkl"] as? NSNumber)?.intValue ?? (ids["simkl_id"] as? NSNumber)?.intValue ?? Int(ids["simkl"] as? String ?? "")
        guard let simkl, simkl > 0 else { return nil }
        return Match(simkl: simkl, kind: (first["type"] as? String) ?? (first["endpoint_type"] as? String) ?? "tv")
    }

    // MARK: A show's episodes (for placing one by its air date)

    struct Episode: Equatable, Sendable {
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

/// The bodies Simkl's sync routes take, and what its replies say.
enum SimklBody {
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

    /// One title's item: its ids (Simkl's own when known, and TMDB's), name and year. A batch is
    /// one title: a movie, or episodes of one show.
    static func body(_ jobs: [SimklJob], simkl: Int?) -> Data {
        guard let first = jobs.first else { return Data("{}".utf8) }
        var ids: [String: Any] = ["tmdb": first.tmdb]
        if let simkl { ids["simkl"] = simkl }
        var item: [String: Any] = ["title": first.name, "ids": ids]
        if let year = first.year { item["year"] = year }
        switch first.kind {
        case .rate: item["rating"] = first.rating ?? 0
        case .list: item["to"] = first.list ?? "plantowatch"
        case .unrate: break
        case .watch, .unwatch:
            if first.movie {
                if first.kind == .watch, let when = first.watchedAt { item["watched_at"] = when }
            } else {
                // Anime in TVDB's seasons (TMDB's mostly match), unless the episode was placed in
                // Simkl's own numbering by its air date.
                if first.anime && !first.ownNumbering { item["use_tvdb_anime_seasons"] = true }
                let seasons = Dictionary(grouping: jobs) { $0.season ?? 1 }
                item["seasons"] = seasons.keys.sorted().map { season in
                    ["number": season, "episodes": (seasons[season] ?? []).map { job -> [String: Any] in
                        var episode: [String: Any] = ["number": job.number ?? 0]
                        if job.kind == .watch, let when = job.watchedAt { episode["watched_at"] = when }
                        return episode
                    }] as [String: Any]
                }
            }
        }
        let root = [first.movie ? "movies" : "shows": [item]]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Which of the sent jobs Simkl couldn't place. A title it doesn't know: all of them; episodes
    /// it names: those; episodes it doesn't name in a form TwilDiary reads: all the episodes.
    static func notFound(_ reply: Data, sent jobs: [SimklJob]) -> Set<String> {
        guard let root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let missing = root["not_found"] as? [String: Any] else { return [] }
        func has(_ key: String) -> Bool { !((missing[key] as? [Any]) ?? []).isEmpty }
        if has("movies") || has("shows") || has("anime") { return Set(jobs.map(\.id)) }
        guard has("episodes") else { return [] }
        var places = Set<String>()
        for entry in (missing["episodes"] as? [[String: Any]]) ?? [] {
            let number = (entry["number"] as? NSNumber)?.intValue ?? (entry["episode"] as? NSNumber)?.intValue
            if let season = (entry["season"] as? NSNumber)?.intValue, let number { places.insert("\(season):\(number)") }
            for season in (entry["seasons"] as? [[String: Any]]) ?? [] {
                guard let s = (season["number"] as? NSNumber)?.intValue else { continue }
                for episode in (season["episodes"] as? [[String: Any]]) ?? [] {
                    if let n = (episode["number"] as? NSNumber)?.intValue { places.insert("\(s):\(n)") }
                }
            }
        }
        let named = jobs.filter { places.contains("\($0.season ?? 1):\($0.number ?? 0)") }.map(\.id)
        return named.isEmpty ? Set(jobs.map(\.id)) : Set(named)
    }

    /// The episode Simkl lists on that day (a day either side: time zones), as the job should send
    /// it: TVDB's season and number when Simkl knows them, else Simkl's own number.
    static func place(day: String, in episodes: [SimklAPI.Episode]) -> (season: Int, number: Int, own: Bool)? {
        let near = episodes.filter { episode in episode.day.map { daysApart($0, day) <= 1 } ?? false }
        guard let best = near.min(by: { daysApart($0.day ?? "", day) < daysApart($1.day ?? "", day) }) else { return nil }
        if let season = best.tvdbSeason, let number = best.tvdbEpisode { return (season, number, false) }
        return (best.special ? 0 : 1, best.number, true)
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
