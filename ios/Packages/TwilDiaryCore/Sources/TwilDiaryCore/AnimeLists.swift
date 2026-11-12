import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The community Anime-Lists mapping (github.com/Anime-Lists/anime-lists, `anime-list-master.xml`):
/// each AniDB entry with its TVDB and TMDB show, the season it falls in and the offset of its
/// episodes there, plus per-episode mappings (specials, split seasons). Simkl's anime entries follow
/// AniDB, so this is how an episode the diary numbers TMDB's way (a season of one show) is found on
/// Simkl when Simkl can't place it by TVDB numbering: by its AniDB entry and that entry's own
/// episode number (Simkl's documented `anime[]` envelope), as MAL-Sync, Shoko and PlexAniBridge do.
public struct AnimeListIndex: Sendable, Equatable {
    public struct Mapping: Sendable, Equatable {
        /// 1: the entry's regular episodes; 0: its AniDB specials (not addressable on Simkl).
        public var anidbSeason: Int
        public var tvdbSeason: Int
        public var start: Int?
        public var end: Int?
        public var offset: Int?
        /// Single episodes: AniDB episode → TVDB episode (";1-5;2-6;").
        public var pairs: [Int: Int] = [:]
    }
    public struct Entry: Sendable, Equatable {
        public var anidb: Int
        public var tvdb: Int?
        /// nil: absolute numbering ("a") or none.
        public var tvdbSeason: Int?
        public var tvdbOffset: Int = 0
        public var tmdb: Int?
        public var tmdbSeason: Int?
        public var tmdbOffset: Int = 0
        public var mappings: [Mapping] = []
        /// TMDB numbers this entry as TVDB does (same season and offset), so TVDB's per-episode
        /// mappings hold for TMDB too.
        var tmdbMirrorsTVDB: Bool { tmdbSeason != nil && tmdbSeason == tvdbSeason && tmdbOffset == tvdbOffset }
    }
    public private(set) var byAniDB: [Int: Entry] = [:]
    public private(set) var byTMDB: [Int: [Entry]] = [:]
    public private(set) var byTVDB: [Int: [Entry]] = [:]

    public init(_ entries: [Entry]) {
        for entry in entries {
            byAniDB[entry.anidb] = entry
            if let tmdb = entry.tmdb { byTMDB[tmdb, default: []].append(entry) }
            if let tvdb = entry.tvdb { byTVDB[tvdb, default: []].append(entry) }
        }
    }
    public var isEmpty: Bool { byAniDB.isEmpty }

    /// The AniDB entry and its episode for a show's season and episode, numbered TMDB's way (the
    /// diary's), or TVDB's when TMDB isn't listed for that show. nil when nothing places it.
    public func anidb(tmdb: Int?, tvdb: Int?, season: Int, episode: Int) -> (anidb: Int, episode: Int)? {
        guard episode > 0 else { return nil }
        if let tmdb, let entries = byTMDB[tmdb], let found = Self.place(entries, season: season, episode: episode, tmdb: true) { return found }
        if let tvdb, let entries = byTVDB[tvdb], let found = Self.place(entries, season: season, episode: episode, tmdb: false) { return found }
        return nil
    }

    /// The other way: an AniDB entry's episode as a show's season and episode (TMDB's numbering
    /// when the entry lists TMDB, else TVDB's).
    public func show(anidb: Int, episode: Int) -> (tmdb: Int?, tvdb: Int?, season: Int, episode: Int)? {
        guard episode > 0, let entry = byAniDB[anidb] else { return nil }
        // TMDB numbers this entry its own way (the diary's numbering): TMDB's season and offset, not
        // TVDB's per-episode mappings.
        if let tmdb = entry.tmdb, let season = entry.tmdbSeason, !entry.tmdbMirrorsTVDB, episode + entry.tmdbOffset > 0 {
            return (tmdb, entry.tvdb, season, episode + entry.tmdbOffset)
        }
        for mapping in entry.mappings where mapping.anidbSeason == 1 {
            var target: Int?
            if let mapped = mapping.pairs[episode] { target = mapped }
            else if mapping.pairs.isEmpty, let start = mapping.start, let end = mapping.end, (start...end).contains(episode) { target = episode + (mapping.offset ?? 0) }
            guard let target, target > 0 else { continue }
            // Per-episode mappings are TVDB's: TMDB only when it numbers the entry the same way.
            return (entry.tmdbMirrorsTVDB ? entry.tmdb : nil, entry.tvdb, mapping.tvdbSeason, target)
        }
        if let tmdb = entry.tmdb, let season = entry.tmdbSeason, episode + entry.tmdbOffset > 0 {
            return (tmdb, entry.tvdb, season, episode + entry.tmdbOffset)
        }
        if let season = entry.tvdbSeason, episode + entry.tvdbOffset > 0 { return (nil, entry.tvdb, season, episode + entry.tvdbOffset) }
        return nil
    }

    /// An exact per-episode mapping wins; else the entry whose default season holds it, the one
    /// starting latest at or before the episode (later cours of a season start further in).
    static func place(_ entries: [Entry], season: Int, episode: Int, tmdb: Bool) -> (anidb: Int, episode: Int)? {
        for entry in entries where !tmdb || entry.tmdbMirrorsTVDB || entry.tmdbSeason == nil {
            for mapping in entry.mappings where mapping.anidbSeason == 1 && mapping.tvdbSeason == season {
                if let source = mapping.pairs.first(where: { $0.value == episode })?.key { return (entry.anidb, source) }
                if mapping.pairs.isEmpty, let start = mapping.start, let end = mapping.end {
                    let source = episode - (mapping.offset ?? 0)
                    if (start...end).contains(source) { return (entry.anidb, source) }
                }
            }
        }
        var best: (anidb: Int, episode: Int, offset: Int)?
        for entry in entries {
            let entrySeason = tmdb ? entry.tmdbSeason : entry.tvdbSeason
            let offset = tmdb ? entry.tmdbOffset : entry.tvdbOffset
            guard entrySeason == season else { continue }
            let source = episode - offset
            guard source >= 1 else { continue }
            if best == nil || offset > best!.offset { best = (entry.anidb, source, offset) }
        }
        return best.map { ($0.anidb, $0.episode) }
    }

    /// Reads `anime-list-master.xml`. Entries without an AniDB id are skipped.
    public static func parse(_ data: Data) -> AnimeListIndex {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return AnimeListIndex(reader.entries)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var mapping: Mapping?
        private var text = ""
        private static func int(_ value: String?) -> Int? { value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "anime":
                guard let anidb = Self.int(attributes["anidbid"]) else { current = nil; return }
                current = Entry(anidb: anidb, tvdb: Self.int(attributes["tvdbid"]).flatMap { $0 > 0 ? $0 : nil },
                                tvdbSeason: Self.int(attributes["defaulttvdbseason"]), tvdbOffset: Self.int(attributes["episodeoffset"]) ?? 0,
                                tmdb: Self.int(attributes["tmdbtv"]).flatMap { $0 > 0 ? $0 : nil },
                                tmdbSeason: Self.int(attributes["tmdbseason"]), tmdbOffset: Self.int(attributes["tmdboffset"]) ?? 0)
            case "mapping":
                guard current != nil, let anidbSeason = Self.int(attributes["anidbseason"]), let tvdbSeason = Self.int(attributes["tvdbseason"]) else { mapping = nil; return }
                mapping = Mapping(anidbSeason: anidbSeason, tvdbSeason: tvdbSeason, start: Self.int(attributes["start"]),
                                  end: Self.int(attributes["end"]), offset: Self.int(attributes["offset"]))
                text = ""
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if mapping != nil { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "mapping":
                guard var done = mapping else { return }
                for pair in text.split(separator: ";") {
                    // "1-5" (AniDB 1 is TVDB 5); "3-0" or "3-" mean AniDB 3 has no TVDB episode.
                    let sides = pair.split(separator: "-", omittingEmptySubsequences: false)
                    guard sides.count == 2, let source = Int(sides[0]), let target = Int(sides[1]), target > 0 else { continue }
                    done.pairs[source] = target
                }
                current?.mappings.append(done)
                mapping = nil
            case "anime":
                if let current { entries.append(current) }
                current = nil
            default: break
            }
        }
    }
}

/// Simkl's not-found episodes sent again by their AniDB entry (`anime[]`, Simkl's own episode
/// numbers), then both answers combined so the rest of the app sees what really landed.
public enum SimklAnimeFallback {
    public struct Retry: Sendable {
        public let body: Data
        /// "tmdb:1429|s2e4" for each episode resent, with the AniDB entry it went to.
        public let placed: [String: Int]
    }
    static func ids(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    /// Whether a history answer has episodes Simkl couldn't place (cheap: no mapping needed).
    public static func hasMissingEpisodes(_ reply: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return false }
        return !((ids(root["not_found"])["episodes"] as? [Any]) ?? []).isEmpty
    }
    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) } }

    /// The resend for a `/sync/history` (or `/remove`) answer's not-found episodes that Anime-Lists
    /// places; nil when there's none to resend.
    public static func retry(sent: Data, reply: Data, index: AnimeListIndex) -> Retry? {
        guard !index.isEmpty,
              let replyRoot = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let missing = ids(replyRoot["not_found"])["episodes"] as? [[String: Any]], !missing.isEmpty else { return nil }
        // Each sent episode's time, by show and episode.
        var times: [String: Any] = [:]
        let sentRoot = (try? JSONSerialization.jsonObject(with: sent)) as? [String: Any] ?? [:]
        for show in sentRoot["shows"] as? [[String: Any]] ?? [] {
            guard let tmdb = int(ids(show["ids"])["tmdb"]) else { continue }
            for season in show["seasons"] as? [[String: Any]] ?? [] {
                guard let number = int(season["number"]) else { continue }
                for episode in season["episodes"] as? [[String: Any]] ?? [] {
                    if let e = int(episode["number"]), let at = episode["watched_at"] { times["tmdb:\(tmdb)|s\(number)e\(e)"] = at }
                }
            }
        }
        var byEntry: [Int: [[String: Any]]] = [:], order: [Int] = [], placed: [String: Int] = [:]
        for show in missing {
            let showIDs = ids(show["ids"])
            let tmdb = int(showIDs["tmdb"]), tvdb = int(showIDs["tvdb"])
            for season in show["seasons"] as? [[String: Any]] ?? [] {
                guard let number = int(season["number"]) else { continue }
                for episode in season["episodes"] as? [[String: Any]] ?? [] {
                    guard let e = int(episode["number"]), let found = index.anidb(tmdb: tmdb, tvdb: tvdb, season: number, episode: e) else { continue }
                    let key = "tmdb:\(tmdb ?? 0)|s\(number)e\(e)"
                    var item: [String: Any] = ["number": found.episode]
                    if let at = times[key] { item["watched_at"] = at }
                    if byEntry[found.anidb] == nil { order.append(found.anidb) }
                    byEntry[found.anidb, default: []].append(item)
                    placed[key] = found.anidb
                }
            }
        }
        guard !order.isEmpty else { return nil }
        let anime: [[String: Any]] = order.map { ["ids": ["anidb": $0], "episodes": byEntry[$0] ?? []] }
        guard let body = try? JSONSerialization.data(withJSONObject: ["anime": anime], options: [.sortedKeys]) else { return nil }
        return Retry(body: body, placed: placed)
    }

    /// The first answer with the resent episodes Simkl took off its not-found list and counted as
    /// added (or deleted). When the resend wasn't answered, the first answer stands.
    public static func merge(reply: Data, retry: Retry, retryReply: Data?) -> Data {
        guard let retryReply, var root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let second = (try? JSONSerialization.jsonObject(with: retryReply)) as? [String: Any] else { return reply }
        // The resend's misses come back by AniDB entry: every episode sent to an entry Simkl
        // still missed stays not found (whatever list Simkl puts it under).
        var missedEntries = Set<Int>()
        for case let list as [[String: Any]] in ids(second["not_found"]).values {
            for item in list { if let anidb = int(ids(item["ids"])["anidb"]) { missedEntries.insert(anidb) } }
        }
        let landed = Set(retry.placed.filter { !missedEntries.contains($0.value) }.keys)
        guard !landed.isEmpty else { return reply }
        var notFound = ids(root["not_found"])
        let episodes = notFound["episodes"] as? [[String: Any]] ?? []
        var kept: [[String: Any]] = []
        for show in episodes {
            let tmdb = int(ids(show["ids"])["tmdb"]) ?? 0
            var seasons: [[String: Any]] = []
            for season in show["seasons"] as? [[String: Any]] ?? [] {
                let number = int(season["number"]) ?? -1
                let left = (season["episodes"] as? [[String: Any]] ?? []).filter { !landed.contains("tmdb:\(tmdb)|s\(number)e\(int($0["number"]) ?? -1)") }
                if !left.isEmpty { var copy = season; copy["episodes"] = left; seasons.append(copy) }
            }
            if !seasons.isEmpty { var copy = show; copy["seasons"] = seasons; kept.append(copy) }
        }
        notFound["episodes"] = kept
        root["not_found"] = notFound
        for key in ["added", "deleted"] {
            guard var counts = root[key] as? [String: Any], let extra = int(ids(second[key])["episodes"]) else { continue }
            counts["episodes"] = (int(counts["episodes"]) ?? 0) + extra
            root[key] = counts
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? reply
    }
}
