import Foundation

/// Which AniList entry and episode each TMDB episode is, and each anime's Simkl entry (2026-11-15).
///
/// Built from two public maps, both MIT: anibridge-mappings (episode ranges from TMDB seasons to
/// AniList entries, built daily from the Anime-Lists and others; specials included where known)
/// and animeApi (a title's ids across Simkl, AniList, TMDB and more). Only what TwilDiary uses is
/// kept: every TMDB-keyed anime, about 560 KB. Tested against the owner's 263 anime on Simkl: 60
/// of 60 films and 172 of 175 series entries agreed with Simkl's own AniList ids; 233 of 238 gave
/// Simkl's entry, none another. The maps are sometimes wrong (Bisque Doll's season 1 is season 2's
/// entry; Re:Zero's ranges one apart in places), so callers check air dates (`plausible`) and fall
/// back to their own matching wherever the map is silent or doubtful.
public struct AnimeMap: Codable, Equatable, Sendable {
    /// TMDB episodes `from` through `to` (nil: open) are an AniList entry's episodes from `start` on.
    public struct Span: Codable, Equatable, Sendable {
        public let from: Int
        public let to: Int?
        public let anilist: Int
        public let start: Int
        public init(from: Int, to: Int?, anilist: Int, start: Int) { self.from = from; self.to = to; self.anilist = anilist; self.start = start }
        func holds(_ episode: Int) -> Bool { episode >= from && (to.map { episode <= $0 } ?? true) }
    }
    /// "tmdb:season" → its spans.
    public var shows: [String: [Span]] = [:]
    /// A TMDB film → its AniList entries.
    public var films: [String: [Int]] = [:]
    /// A TMDB show → its Simkl entry, only where animeApi lists one; a TMDB film → its Simkl entry.
    public var simklShows: [String: Int] = [:]
    public var simklFilms: [String: Int] = [:]
    /// An AniList entry → the Simkl entry for it.
    public var simklAniList: [String: Int] = [:]
    /// When it was built ("2026-11-15T08:42:10Z").
    public var builtAt: String = ""
    public init() {}

    // MARK: Looking things up

    /// The AniList entry and its episode for TMDB's `season`, `episode` of show `tmdb`.
    public func anilist(tmdb: Int, season: Int, episode: Int) -> (id: Int, episode: Int)? {
        guard let span = shows["\(tmdb):\(season)"]?.first(where: { $0.holds(episode) }) else { return nil }
        return (span.anilist, span.start + episode - span.from)
    }
    /// A show's AniList entries in TMDB's order: its seasons' entries first (by season and first
    /// episode), then the specials' (season 0).
    public func anilistEntries(tmdb: Int) -> [Int] {
        var rows: [(season: Int, from: Int, id: Int)] = []
        for (key, spans) in shows {
            let parts = key.split(separator: ":")
            guard parts.count == 2, parts[0] == Substring(String(tmdb)), let season = Int(parts[1]) else { continue }
            for span in spans { rows.append((season == 0 ? Int.max : season, span.from, span.anilist)) }
        }
        var seen = Set<Int>(), out: [Int] = []
        for row in rows.sorted(by: { ($0.season, $0.from, $0.id) < ($1.season, $1.from, $1.id) }) where seen.insert(row.id).inserted { out.append(row.id) }
        return out
    }
    /// A film's AniList entry.
    public func anilistFilm(tmdb: Int) -> Int? { films[String(tmdb)]?.first }
    /// A title's Simkl entry: a film's; a show's first episode's entry (its first season), else the
    /// one animeApi lists for the show.
    public func simkl(tmdb: Int, film: Bool) -> Int? {
        if film { return simklFilms[String(tmdb)] ?? anilistFilm(tmdb: tmdb).flatMap { simkl(anilist: $0) } }
        if let first = anilist(tmdb: tmdb, season: 1, episode: 1), let entry = simkl(anilist: first.id) { return entry }
        return simklShows[String(tmdb)]
    }
    public func simkl(anilist: Int) -> Int? { simklAniList[String(anilist)] }
    /// TMDB's season and episode for an AniList entry's `episode` of show `tmdb`.
    public func tmdbEpisode(tmdb: Int, anilist: Int, episode: Int) -> (season: Int, number: Int)? {
        for (key, spans) in shows.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: ":")
            guard parts.count == 2, parts[0] == Substring(String(tmdb)), let season = Int(parts[1]) else { continue }
            for span in spans where span.anilist == anilist && episode >= span.start {
                let number = span.from + episode - span.start
                if span.holds(number) { return (season, number) }
            }
        }
        return nil
    }
    /// An episode that aired on `day` can belong to an entry that ran `start` to `end`: within 30
    /// days of its run (Simkl and TMDB date some premieres and home releases weeks apart). True when
    /// either side has no date: nothing contradicts the map.
    public static func plausible(day: String?, start: String?, end: String?) -> Bool {
        guard let day = day.map({ String($0.prefix(10)) }), day.count == 10, let start else { return true }
        if AniListPlan.days(start, day) < -30 { return false }
        if let end, AniListPlan.days(end, day) > 30 { return false }
        return true
    }

    // MARK: Building it

    /// From anibridge-mappings' `mappings.min.json` and animeApi's `animeapi.tsv`.
    public static func build(mappings: Data, animeApi: Data, builtAt: String) throws -> AnimeMap {
        guard let root = try JSONSerialization.jsonObject(with: mappings) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var map = AnimeMap()
        map.builtAt = builtAt
        for (key, value) in root {
            guard let targets = value as? [String: Any] else { continue }
            if key.hasPrefix("tmdb_show:") {
                // "tmdb_show:65942:s1" → "65942:1"
                let parts = key.split(separator: ":")
                guard parts.count == 3, let tmdb = Int(parts[1]), parts[2].hasPrefix("s"), let season = Int(parts[2].dropFirst()) else { continue }
                var spans: [Span] = []
                for (target, ranges) in targets {
                    guard target.hasPrefix("anilist:"), let anilist = Int(target.dropFirst(8)), let ranges = ranges as? [String: String] else { continue }
                    for (source, destination) in ranges {
                        // A ratio ("|2") or a split ("1-6,8-13") isn't one-for-one: left to the matching.
                        guard !source.contains(","), !destination.contains(","), !destination.contains("|"),
                              let from = range(source), let to = range(destination) else { continue }
                        spans.append(Span(from: from.lo, to: from.hi, anilist: anilist, start: to.lo))
                    }
                }
                if !spans.isEmpty { map.shows["\(tmdb):\(season)", default: []] += spans.sorted { $0.from < $1.from } }
            } else if key.hasPrefix("tmdb_movie:"), let tmdb = Int(key.dropFirst(11)) {
                let ids = targets.keys.compactMap { $0.hasPrefix("anilist:") ? Int($0.dropFirst(8)) : nil }.sorted()
                if !ids.isEmpty { map.films[String(tmdb)] = ids }
            }
        }
        guard let text = String(data: animeApi, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let header = lines.next() else { return map }
        let names = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let simkl = names.firstIndex(of: "simkl"), let anilist = names.firstIndex(of: "anilist"),
              let tmdb = names.firstIndex(of: "themoviedb"), let kind = names.firstIndex(of: "themoviedb_type") else { return map }
        var showEntries: [String: Set<Int>] = [:]
        while let line = lines.next() {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            func cell(_ index: Int) -> String { index < cells.count ? String(cells[index]).trimmingCharacters(in: .whitespaces) : "" }
            guard let entry = Int(cell(simkl)) else { continue }
            if !cell(anilist).isEmpty { map.simklAniList[cell(anilist)] = entry }
            let id = cell(tmdb)
            guard !id.isEmpty else { continue }
            if cell(kind) == "movie" { map.simklFilms[id] = map.simklFilms[id] ?? entry } else { showEntries[id, default: []].insert(entry) }
        }
        // A show animeApi files under several Simkl entries (one per cour) has no one entry here.
        for (id, entries) in showEntries where entries.count == 1 { map.simklShows[id] = entries.first }
        return map
    }
    /// "12" → 12...12, "12-24" → 12...24, "14-" → 14... (open).
    static func range(_ text: String) -> (lo: Int, hi: Int?)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard let lo = Int(parts[0]), lo > 0 else { return nil }
        if parts.count == 1 { return (lo, lo) }
        guard parts.count == 2 else { return nil }
        if parts[1].isEmpty { return (lo, nil) }
        guard let hi = Int(parts[1]), hi >= lo else { return nil }
        return (lo, hi)
    }
}

/// Stops sending what never lands (CrossWatch's "blackbox", 2026-11-15): something sent three
/// times that the service still lacks when read back is parked for 30 days, shown apart with
/// Try again, and no longer offered as a difference. Angel Beats!' S0 E2 went to Simkl on every
/// Make match and came back missing every time.
public struct RetryStop: Codable, Equatable, Sendable {
    public static let limit = 3
    public static let parkDays = 30
    /// Times sent since it last read back as missing.
    public var tries: [String: Int] = [:]
    /// Parked, and when.
    public var parked: [String: Date] = [:]
    public init() {}

    public mutating func sent(_ keys: some Sequence<String>) { for key in keys { tries[key, default: 0] += 1 } }
    /// After a read, with `missing` what the service still lacks (parked things left out): what
    /// landed is forgotten, what was sent `limit` times and is still missing is parked, and what
    /// was parked 30 days ago comes back. Returns what was parked and what came back.
    @discardableResult
    public mutating func observe(missing: Set<String>, now: Date = .now) -> (parked: [String], released: [String]) {
        for key in Array(tries.keys) where !missing.contains(key) { tries[key] = nil }
        var released: [String] = []
        for (key, at) in parked where now.timeIntervalSince(at) >= Double(Self.parkDays) * 86_400 { parked[key] = nil; released.append(key) }
        var newly: [String] = []
        for (key, count) in tries where count >= Self.limit && missing.contains(key) { parked[key] = now; tries[key] = nil; newly.append(key) }
        return (newly.sorted(), released.sorted())
    }
    public func isParked(_ key: String) -> Bool { parked[key] != nil }
    /// Try again: sent once more as if new.
    public mutating func retry(_ keys: some Sequence<String>) { for key in keys { parked[key] = nil; tries[key] = nil } }
}
