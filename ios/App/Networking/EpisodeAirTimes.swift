import Foundation
import Observation

/// The hour an episode airs, for every calendar row: Trakt's calendar when Trakt is signed in on
/// this iPhone, otherwise TVmaze (free, no key or sign-in), which has the exact air time of most
/// shows and anime. TMDB itself only knows the day.
@MainActor @Observable final class EpisodeAirTimes {
    static let shared = EpisodeAirTimes()
    /// "tmdb|yyyy-MM-dd" → when it airs.
    private(set) var times: [String: Date] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    nonisolated static func key(_ tmdb: Int, _ day: String) -> String { "\(tmdb)|\(day)" }

    func time(tmdb: Int?, season: Int? = nil, number: Int? = nil, day: String) -> Date? {
        guard let tmdb else { return nil }
        if let season, let number, let trakt = TraktAirTimes.shared.times[TraktAirTimes.key(tmdb: tmdb, season: season, number: number)] { return trakt }
        return times[Self.key(tmdb, day)]
    }

    /// Looks the time up once per show and day (rows call it as they come on screen).
    func load(tmdb: Int?, season: Int? = nil, number: Int? = nil, day: String, store: DiaryStore) async {
        guard let tmdb, !store.isPreview else { return }
        let key = Self.key(tmdb, day)
        guard times[key] == nil, time(tmdb: tmdb, season: season, number: number, day: day) == nil,
              let token = TMDBDirect.token(store), asked.insert(key).inserted else { return }
        let found = await TVmazeSchedule.shared.airstamp(tmdb: tmdb, day: day, season: season, number: number, token: token)
        if let found { times[key] = found } else { asked.remove(key) }
    }
}

/// TVmaze's episode list for a show, found from its TMDB id (TMDB's TVDB or IMDb id → TVmaze's
/// lookup). The TVmaze id is kept on the phone; each show's air times for six months either side of
/// today are kept twelve hours. TVmaze allows 20 requests in 10 seconds, so requests go one at a
/// time, about two a second.
actor TVmazeSchedule {
    static let shared = TVmazeSchedule()
    struct Stamp: Codable, Sendable, Equatable { let day: String; let at: Date }
    struct Show: Codable, Sendable, Equatable {
        var fetchedAt: Date
        /// The earliest air time on each day (TVmaze's air date, the network's own day, as TMDB's).
        var byDay: [String: Date]
        /// "season:number" → its day and time.
        var byNumber: [String: Stamp]
    }
    private static let idsKey = "tvmaze.showIDs"
    private static var cacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "tvmaze-shows.json")
    }

    private let session: URLSession
    /// TMDB id → TVmaze id; 0 when TVmaze doesn't have the show.
    private var ids: [Int: Int]
    private var shows: [Int: Show]
    private var pending: [Int: Task<Show?, Never>] = [:]
    private var nextSlot = Date.distantPast

    init(session: URLSession = .shared, stored: Bool = true) {
        self.session = session
        var ids: [Int: Int] = [:]
        if stored {
            for (key, value) in (UserDefaults.standard.dictionary(forKey: Self.idsKey) as? [String: Int]) ?? [:] { if let tmdb = Int(key) { ids[tmdb] = value } }
        }
        self.ids = ids
        if stored, let file = Self.cacheFile, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Int: Show].self, from: data) {
            shows = saved
        } else { shows = [:] }
    }

    func airstamp(tmdb: Int, day: String, season: Int?, number: Int?, token: String) async -> Date? {
        guard let show = await show(tmdb: tmdb, token: token) else { return nil }
        return Self.pick(show, day: day, season: season, number: number)
    }

    /// That day's time for the show; otherwise the episode by its number, if TVmaze has it within a
    /// day of TMDB's date (numbering can differ, as with anime counted across seasons).
    nonisolated static func pick(_ show: Show, day: String, season: Int?, number: Int?) -> Date? {
        if let at = show.byDay[day] { return at }
        if let season, let number, let stamp = show.byNumber["\(season):\(number)"], daysApart(stamp.day, day) <= 1 { return stamp.at }
        return nil
    }

    private func show(tmdb: Int, token: String) async -> Show? {
        if let saved = shows[tmdb], Date().timeIntervalSince(saved.fetchedAt) < 12 * 3_600 { return saved }
        if let running = pending[tmdb] { return await running.value }
        let task = Task { await self.fetch(tmdb: tmdb, token: token) }
        pending[tmdb] = task
        let show = await task.value
        pending[tmdb] = nil
        if let show {
            shows[tmdb] = show
            if let file = Self.cacheFile, let data = try? JSONEncoder().encode(shows) { try? data.write(to: file, options: .atomic) }
        }
        return show
    }

    private func fetch(tmdb: Int, token: String) async -> Show? {
        let empty = Show(fetchedAt: Date(), byDay: [:], byNumber: [:])
        if ids[tmdb] == nil {
            guard let external = try? await TMDBDirect.data("tv/\(tmdb)/external_ids", query: [:], token: token),
                  let root = (try? JSONSerialization.jsonObject(with: external)) as? [String: Any] else { return nil }
            var lookups: [String] = []
            if let tvdb = root["tvdb_id"] as? Int, tvdb > 0 { lookups.append("thetvdb=\(tvdb)") }
            if let imdb = root["imdb_id"] as? String, !imdb.isEmpty { lookups.append("imdb=\(imdb)") }
            var found = 0
            for lookup in lookups where found == 0 {
                switch await get("/lookup/shows?" + lookup) {
                case .found(let data): found = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? Int ?? 0
                case .missing: continue
                case .failed: return nil
                }
            }
            ids[tmdb] = found
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: ids.map { (String($0.key), $0.value) }), forKey: Self.idsKey)
        }
        guard let id = ids[tmdb], id > 0 else { return empty }
        switch await get("/shows/\(id)/episodes") {
        case .found(let data): return Self.decode(data, now: Date())
        case .missing: return empty
        case .failed: return nil
        }
    }

    private enum Reply { case found(Data), missing, failed }
    private func get(_ path: String) async -> Reply {
        guard let url = URL(string: "https://api.tvmaze.com" + path) else { return .failed }
        for attempt in 0..<2 {
            let now = Date(), slot = max(now, nextSlot)
            nextSlot = slot.addingTimeInterval(0.55)
            if slot > now { try? await Task.sleep(for: .seconds(slot.timeIntervalSince(now))) }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("TwilDiary/2.0", forHTTPHeaderField: "User-Agent")
            guard let reply = try? await session.data(for: request), let http = reply.1 as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .missing }
            if http.statusCode == 429, attempt == 0 { nextSlot = Date().addingTimeInterval(3); continue }
            return (200..<300).contains(http.statusCode) ? .found(reply.0) : .failed
        }
        return .failed
    }

    /// TVmaze's episodes: `airdate` ("2026-11-14", the network's day) and `airstamp` (exact, with
    /// its offset). Only six months either side of today are kept.
    nonisolated static func decode(_ data: Data, now: Date) -> Show {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        let parser = ISO8601DateFormatter()
        let earliest = now.addingTimeInterval(-183 * 86_400), latest = now.addingTimeInterval(183 * 86_400)
        var show = Show(fetchedAt: now, byDay: [:], byNumber: [:])
        for row in rows {
            guard let stamp = row["airstamp"] as? String, let at = parser.date(from: stamp), at >= earliest, at <= latest,
                  let day = row["airdate"] as? String, day.count == 10 else { continue }
            if show.byDay[day].map({ at < $0 }) ?? true { show.byDay[day] = at }
            if let season = row["season"] as? Int, let number = row["number"] as? Int { show.byNumber["\(season):\(number)"] = Stamp(day: day, at: at) }
        }
        return show
    }

    nonisolated static func daysApart(_ first: String, _ second: String) -> Int {
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
