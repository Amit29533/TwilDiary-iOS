import Foundation

/// AniList as an add-on (phase 1, 2026-11-15). AniList keeps one list entry per season or cour of
/// an anime, holding how many of its episodes you've watched, a status, a score, start and finish
/// dates and a rewatch count. It keeps no watch history: the diary keeps every watch and AniList
/// gets each entry's state, worked out here from the diary.
public enum AniListPlan {
    /// One AniList anime entry, as AniList dates it ("2016-04-04").
    public struct Media: Codable, Hashable, Sendable {
        public let id: Int
        public let format: String?
        public let episodes: Int?
        public let start: String?
        public let end: String?
        public init(id: Int, format: String?, episodes: Int?, start: String?, end: String?) {
            self.id = id; self.format = format; self.episodes = episodes; self.start = start; self.end = end
        }
    }
    /// What one AniList entry should hold. `score` is out of 100; dates are "2021-04-07".
    public struct Entry: Codable, Equatable, Sendable {
        public let mediaId: Int
        public var status: String
        public var progress: Int
        public var score: Int?
        public var startedAt: String?
        public var completedAt: String?
        public var repeatCount: Int
        public init(mediaId: Int, status: String, progress: Int, score: Int? = nil, startedAt: String? = nil, completedAt: String? = nil, repeatCount: Int = 0) {
            self.mediaId = mediaId; self.status = status; self.progress = progress; self.score = score
            self.startedAt = startedAt; self.completedAt = completedAt; self.repeatCount = repeatCount
        }
    }
    /// One watch of a title in the diary: the episode (nil for a film), the day it aired, and when it was watched.
    public struct Watch: Equatable, Sendable {
        public let season: Int?
        public let number: Int?
        public let aired: String?
        public let watchedAt: String?
        public init(season: Int?, number: Int?, aired: String?, watchedAt: String?) {
            self.season = season; self.number = number; self.aired = aired; self.watchedAt = watchedAt
        }
    }
    /// A candidate from AniList's search, for finding a diary title's entry.
    public struct Candidate: Equatable, Sendable {
        public let media: Media
        public let names: [String]
        public init(media: Media, names: [String]) { self.media = media; self.names = names }
    }

    /// AniList's list status for a diary status.
    public static func status(_ diary: String) -> String {
        switch diary {
        case "planned": "PLANNING"
        case "completed": "COMPLETED"
        case "dropped": "DROPPED"
        case "paused", "on_hold": "PAUSED"
        default: "CURRENT"
        }
    }

    /// The search result that is this title: one named the same (any of AniList's names) within a
    /// year, of the right kind; else the first within a year of the right kind that AniList ranks
    /// best. `strict` (a title the diary doesn't mark anime): only one named the same.
    public static func pick(_ candidates: [Candidate], names: [String], year: Int?, film: Bool, strict: Bool = false) -> Media? {
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = Set(names.map(plain).filter { !$0.isEmpty })
        let films: Set<String> = ["MOVIE"], series: Set<String> = ["TV", "TV_SHORT", "ONA", "OVA"]
        let fitting = candidates.filter { candidate in
            guard let format = candidate.media.format, (film ? films.union(["SPECIAL", "ONA", "OVA"]) : series).contains(format) else { return false }
            guard let year, let started = candidate.media.start.flatMap({ Int($0.prefix(4)) }) else { return true }
            return abs(started - year) <= 1
        }
        if let named = fitting.first(where: { !wanted.isDisjoint(with: $0.names.map(plain)) }) { return named.media }
        if strict { return nil }
        // A film is MOVIE unless named the same (Simkl files some as an OVA or ONA, and so may AniList).
        return fitting.first { !film || $0.media.format == "MOVIE" }?.media
    }

    /// Which entry an episode that aired on `day` belongs to: the one whose run holds the day (two
    /// days either side: time zones), else the one begun latest by then.
    public static func media(for day: String, in chain: [Media]) -> Media? {
        let slack = 2
        let begun = chain.filter { media in media.start.map { days($0, day) >= -slack } ?? false }
        let holding = begun.filter { media in media.end.map { days(day, $0) >= -slack } ?? true }
        return (holding.isEmpty ? begun : holding).max { ($0.start ?? "") < ($1.start ?? "") }
    }

    /// Each entry's state from the title's diary status, rating and watches. `chain`: the title's
    /// entries in order (a film: its one). Watches with no air day go to the only entry, if there is
    /// one; otherwise they're counted as unplaced. An entry with nothing watched is sent only as
    /// Planning (the first, while the diary has the title Planned) or Dropped/Paused (a film).
    public static func entries(status diary: String, score: Double?, film: Bool, watches: [Watch], chain: [Media]) -> (entries: [Entry], unplaced: Int) {
        guard let first = chain.first else { return ([], watches.count) }
        let score = score.map { min(100, max(0, Int(($0 * 10).rounded()))) }
        func day(_ text: String?) -> String? { text.map { String($0.prefix(10)) }.flatMap { $0.count == 10 ? $0 : nil } }
        if film {
            let times = watches.compactMap { day($0.watchedAt) }.sorted()
            if watches.isEmpty {
                guard ["planned", "dropped", "paused", "on_hold"].contains(diary) else { return ([], 0) }
                return ([Entry(mediaId: first.id, status: status(diary), progress: 0, score: score)], 0)
            }
            return ([Entry(mediaId: first.id, status: "COMPLETED", progress: first.episodes ?? 1, score: score,
                           startedAt: times.first, completedAt: times.last, repeatCount: max(0, watches.count - 1))], 0)
        }
        var assigned: [Int: [Watch]] = [:], unplaced = 0
        for watch in watches {
            if let aired = day(watch.aired), let media = media(for: aired, in: chain) { assigned[media.id, default: []].append(watch) }
            else if chain.count == 1 { assigned[first.id, default: []].append(watch) }
            else { unplaced += 1 }
        }
        var result: [Entry] = []
        for media in chain {
            let watched = assigned[media.id] ?? []
            var plays: [String: Int] = [:]
            for watch in watched { plays["\(watch.season ?? 0)x\(watch.number ?? 0)", default: 0] += 1 }
            let progress = min(plays.count, media.episodes ?? Int.max)
            if progress == 0 {
                if media.id == first.id, diary == "planned" { result.append(Entry(mediaId: media.id, status: "PLANNING", progress: 0, score: score)) }
                continue
            }
            let complete = media.episodes.map { progress >= $0 } ?? false
            let times = watched.compactMap { day($0.watchedAt) }.sorted()
            let held = ["dropped", "paused", "on_hold"].contains(diary)
            result.append(Entry(mediaId: media.id, status: complete ? "COMPLETED" : held ? status(diary) : "CURRENT", progress: progress, score: score,
                                startedAt: times.first, completedAt: complete ? times.last : nil,
                                repeatCount: complete ? max(0, (plays.values.min() ?? 1) - 1) : 0))
        }
        return (result, unplaced)
    }

    /// `b` minus `a` in days ("2016-04-04", "2016-04-06" → 2); 0 when either isn't a day.
    static func days(_ a: String, _ b: String) -> Int {
        func date(_ text: String) -> Date? {
            let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let x = date(a), let y = date(b) else { return 0 }
        return Int((y.timeIntervalSince(x) / 86_400).rounded())
    }
}
