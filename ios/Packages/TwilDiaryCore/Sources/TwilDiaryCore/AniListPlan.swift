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
        /// AniList's name for it (English, else romaji), for the comparison.
        public var title: String? = nil
        public init(id: Int, format: String?, episodes: Int?, start: String?, end: String?, title: String? = nil) {
            self.id = id; self.format = format; self.episodes = episodes; self.start = start; self.end = end; self.title = title
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
        /// The diary's note on the title (every one of its entries carries it).
        public var notes: String? = nil
        public init(mediaId: Int, status: String, progress: Int, score: Int? = nil, startedAt: String? = nil, completedAt: String? = nil, repeatCount: Int = 0, notes: String? = nil) {
            self.mediaId = mediaId; self.status = status; self.progress = progress; self.score = score
            self.startedAt = startedAt; self.completedAt = completedAt; self.repeatCount = repeatCount; self.notes = notes
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

    /// An entry on your AniList list, as read back.
    public struct Listed: Equatable, Sendable {
        public let mediaId: Int
        public let listId: Int
        public let status: String
        public let progress: Int
        public let score: Int?
        public let title: String
        public init(mediaId: Int, listId: Int, status: String, progress: Int, score: Int?, title: String) {
            self.mediaId = mediaId; self.listId = listId; self.status = status; self.progress = progress; self.score = score; self.title = title
        }
    }
    /// An entry the diary expects: the title it belongs to ("tv:98123") and what it should hold.
    public struct Expected: Equatable, Sendable {
        public let key: String
        public let label: String
        public let entry: Entry
        public init(key: String, label: String, entry: Entry) { self.key = key; self.label = label; self.entry = entry }
    }
    public struct Difference: Equatable, Sendable {
        /// The diary title it belongs to; nil for an entry only on AniList.
        public let key: String?
        public let mediaId: Int
        public let title: String
        public let detail: String
    }
    /// Your AniList list against what the diary expects, entry by entry: progress, status and score.
    public struct Comparison: Equatable, Sendable {
        public var matching = 0
        public var missing: [Difference] = []
        public var different: [Difference] = []
        public var onlyOnAniList: [Difference] = []
        /// Diary titles whose AniList entries aren't looked up yet (Send everything looks them up).
        public var notLookedUp = 0
        public var matches: Bool { missing.isEmpty && different.isEmpty && onlyOnAniList.isEmpty }
        /// The diary titles Make match sends again, in order.
        public var keysToSend: [String] {
            var seen = Set<String>()
            return (missing + different).compactMap(\.key).filter { seen.insert($0).inserted }
        }
        public init() {}
    }
    public static func label(_ status: String) -> String {
        switch status {
        case "PLANNING": "Planned"
        case "CURRENT": "Watching"
        case "COMPLETED": "Completed"
        case "PAUSED": "On hold"
        case "DROPPED": "Dropped"
        case "REPEATING": "Rewatching"
        default: status.capitalized
        }
    }
    public static func compare(expected: [Expected], listed: [Listed], notLookedUp: Int = 0) -> Comparison {
        var result = Comparison()
        result.notLookedUp = notLookedUp
        let byMedia = Dictionary(listed.map { ($0.mediaId, $0) }, uniquingKeysWith: { first, _ in first })
        var wanted = Set<Int>()
        for item in expected {
            let entry = item.entry
            wanted.insert(entry.mediaId)
            guard let there = byMedia[entry.mediaId] else {
                result.missing.append(Difference(key: item.key, mediaId: entry.mediaId, title: item.label, detail: "\(label(entry.status)) in the diary, not on AniList"))
                continue
            }
            var details: [String] = []
            // Rewatching is Completed watched again: the same here.
            let sameStatus = there.status == entry.status || (there.status == "REPEATING" && entry.status == "COMPLETED")
            if !sameStatus { details.append("\(label(entry.status)) in the diary, \(label(there.status)) on AniList") }
            if there.progress != entry.progress { details.append("\(entry.progress) watched in the diary, \(there.progress) on AniList") }
            if (there.score ?? 0) != (entry.score ?? 0) {
                func points(_ value: Int?) -> String { value.map { $0 == 0 ? "none" : String(format: "%g", Double($0) / 10) } ?? "none" }
                details.append("rated \(points(entry.score)) in the diary, \(points(there.score)) on AniList")
            }
            if details.isEmpty { result.matching += 1 }
            else { result.different.append(Difference(key: item.key, mediaId: entry.mediaId, title: item.label, detail: details.joined(separator: "; "))) }
        }
        for there in listed where !wanted.contains(there.mediaId) {
            result.onlyOnAniList.append(Difference(key: nil, mediaId: there.mediaId, title: there.title, detail: "\(label(there.status)) on AniList, not in the diary"))
        }
        return result
    }

    // MARK: Source of truth: AniList (its changes into the diary)

    /// An entry on your AniList list with what the diary could take from it.
    public struct ListedDetail: Equatable, Sendable {
        public let mediaId: Int
        public let status: String
        public let progress: Int
        public let score: Int?
        public let notes: String?
        /// When AniList last changed it ("2026-11-15T12:00:00Z"): the time for watches it adds.
        public let updatedAt: String?
        public init(mediaId: Int, status: String, progress: Int, score: Int?, notes: String?, updatedAt: String?) {
            self.mediaId = mediaId; self.status = status; self.progress = progress; self.score = score; self.notes = notes; self.updatedAt = updatedAt
        }
    }
    /// An episode AniList has watched that the diary hasn't, and when to log it.
    public struct EpisodeAdd: Equatable, Sendable {
        public let season: Int
        public let number: Int
        public let at: String?
        public init(season: Int, number: Int, at: String?) { self.season = season; self.number = number; self.at = at }
    }
    /// What one diary title would take from AniList.
    public struct Adoption: Equatable, Sendable {
        public var status: String?
        public var score: Double?
        public var notes: String?
        /// AniList's note differs from a note the diary has: the diary's stays.
        public var noteLeft = false
        /// A film AniList has watched and the diary hasn't: when.
        public var filmWatch: String?
        public var episodes: [EpisodeAdd] = []
        /// AniList episodes TwilDiary can't name (TMDB's air days don't reach them).
        public var unplaced = 0
        public var isEmpty: Bool { status == nil && score == nil && notes == nil && filmWatch == nil && episodes.isEmpty }
        public init() {}
    }
    /// The diary status for a title's AniList entries: watching while any is, then on hold or
    /// dropped, Completed when every listed one is, Planned when all are.
    public static func diaryStatus(fromAniList statuses: [String]) -> String? {
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(where: { $0 == "CURRENT" || $0 == "REPEATING" }) { return "watching" }
        if statuses.contains("PAUSED") { return "paused" }
        if statuses.contains("DROPPED") { return "dropped" }
        if statuses.allSatisfy({ $0 == "COMPLETED" }) { return "completed" }
        if statuses.allSatisfy({ $0 == "PLANNING" }) { return "planned" }
        return "watching"
    }
    /// What a diary title would take from its AniList entries: the status, the score (the first
    /// entry's), the note (only where the diary has none), and the episodes AniList has watched in
    /// each entry that the diary hasn't (an entry's first `progress` episodes, found by TMDB's air
    /// days in `seasons`: season → episode → day). Nothing is taken off the diary.
    public static func adoption(diaryStatus: String, diaryScore: Double?, diaryNotes: String, film: Bool, watches: [Watch],
                                chain: [Media], listed: [ListedDetail], seasons: [Int: [Int: String]],
                                map: AnimeMap? = nil, tmdb: Int? = nil) -> Adoption {
        var result = Adoption()
        let ids = chain.map(\.id)
        let mine = listed.filter { ids.contains($0.mediaId) }.sorted { (ids.firstIndex(of: $0.mediaId) ?? 0) < (ids.firstIndex(of: $1.mediaId) ?? 0) }
        guard !mine.isEmpty else { return result }
        if let status = Self.diaryStatus(fromAniList: mine.map(\.status)), status != diaryStatus,
           !(status == "paused" && diaryStatus == "on_hold") { result.status = status }
        if let score = mine.compactMap(\.score).first(where: { $0 > 0 }), score != diaryScore.map({ Int(($0 * 10).rounded()) }) {
            result.score = Double(score) / 10
        }
        let note = mine.compactMap(\.notes).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let current = diaryNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note, note != current { if current.isEmpty { result.notes = note } else { result.noteLeft = true } }
        if film {
            if watches.isEmpty, let entry = mine.first, entry.status == "COMPLETED" || entry.status == "REPEATING" || entry.progress > 0 {
                result.filmWatch = entry.updatedAt
            }
            return result
        }
        let watched = Set(watches.compactMap { watch in watch.season.map { "\($0)x\(watch.number ?? 0)" } })
        var byMedia: [Int: [(season: Int, number: Int)]] = [:]
        let regular = chain.filter { ["TV", "TV_SHORT", "ONA"].contains($0.format ?? "TV") }
        for (season, list) in seasons where season > 0 {
            for (number, day) in list { if let media = media(for: day, in: regular.isEmpty ? chain : regular) { byMedia[media.id, default: []].append((season, number)) } }
        }
        for entry in mine where entry.progress > 0 {
            // The anime map names each of the entry's episodes (specials too), when it names them all
            // and their air days (where known) fall in the entry's run.
            var named: [(season: Int, number: Int)] = []
            if let map, let tmdb, let media = chain.first(where: { $0.id == entry.mediaId }) {
                for episode in 1...entry.progress {
                    guard let at = map.tmdbEpisode(tmdb: tmdb, anilist: entry.mediaId, episode: episode),
                          AnimeMap.plausible(day: seasons[at.season]?[at.number], start: media.start, end: media.end) else { named = []; break }
                    named.append(at)
                }
            }
            if !named.isEmpty {
                for episode in named where !watched.contains("\(episode.season)x\(episode.number)") {
                    result.episodes.append(EpisodeAdd(season: episode.season, number: episode.number, at: entry.updatedAt))
                }
                continue
            }
            let episodes = (byMedia[entry.mediaId] ?? []).sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            if episodes.count < entry.progress { result.unplaced += entry.progress - episodes.count }
            for episode in episodes.prefix(entry.progress) where !watched.contains("\(episode.season)x\(episode.number)") {
                result.episodes.append(EpisodeAdd(season: episode.season, number: episode.number, at: entry.updatedAt))
            }
        }
        return result
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
        // Several named the same: the film or the series itself before an OVA, a special or an ad
        // ("Your Name." is also a synonym of a Suntory commercial, listed first; 2026-11-15).
        let order = film ? ["MOVIE", "ONA", "OVA", "SPECIAL"] : ["TV", "TV_SHORT", "ONA", "OVA"]
        func rank(_ candidate: Candidate) -> Int { order.firstIndex(of: candidate.media.format ?? "") ?? order.count }
        if let named = fitting.filter({ !wanted.isDisjoint(with: $0.names.map(plain)) }).min(by: { rank($0) < rank($1) }) { return named.media }
        if strict { return nil }
        // A film is MOVIE unless named the same (Simkl files some as an OVA or ONA, and so may AniList).
        return fitting.first { !film || $0.media.format == "MOVIE" }?.media
    }

    /// Simpler ways to search for a title AniList's search finds nothing for: it wants its own
    /// wording ("Nagi-Asu: A Lull in the Sea" finds nothing, "A Lull in the Sea" does; "Seven" vs
    /// "7"; "KissXSis" vs "Kiss x Sis"; checked 2026-11-15). The full name first.
    public static func searchNames(_ name: String) -> [String] {
        var names = [name]
        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if trimmed.count >= 3, !names.contains(trimmed) { names.append(trimmed) }
        }
        for mark in [": ", " - ", " – "] where name.contains(mark) {
            for part in name.components(separatedBy: mark) { add(part) }
        }
        add(name.replacingOccurrences(of: #"[:\-–]?\s*(The )?Movie$"#, with: "", options: .regularExpression))
        let numbers = ["One": "1", "Two": "2", "Three": "3", "Four": "4", "Five": "5", "Six": "6", "Seven": "7", "Eight": "8", "Nine": "9", "Ten": "10"]
        var digits = name
        for (word, digit) in numbers { digits = digits.replacingOccurrences(of: #"\b\#(word)\b"#, with: digit, options: .regularExpression) }
        add(digits)
        add(name.replacingOccurrences(of: #"(?<=[a-z])X(?=[A-Z])"#, with: " x ", options: .regularExpression))
        return names
    }

    /// Which entry an episode that aired on `day` belongs to: the one whose run holds the day (two
    /// days either side: time zones), else the one begun latest by then.
    public static func media(for day: String, in chain: [Media]) -> Media? {
        let slack = 2
        let begun = chain.filter { media in media.start.map { days($0, day) >= -slack } ?? false }
        let holding = begun.filter { media in media.end.map { days(day, $0) >= -slack } ?? true }
        return (holding.isEmpty ? begun : holding).max { ($0.start ?? "") < ($1.start ?? "") }
    }

    /// Each entry's state from the title's diary status, rating, note and watches. `chain`: the
    /// title's entries in order (a film: its one). Watches with no air day go to the only entry, if
    /// there is one; otherwise they're counted as unplaced. An entry with nothing watched is sent
    /// only as Planning (the first, while the diary has the title Planned) or Dropped/Paused (a
    /// film). A completed entry you're watching again (the diary has the title Watching, some
    /// episodes once more than the rest) is Rewatching, its progress the rewatch's. `placed`: the
    /// anime map's entry for an episode ("1x26" → its AniList id), already checked against air
    /// dates; it comes first, and a special is sent only so. The rest go by air dates, to the
    /// show's own seasons only (an OVA or special the map added isn't one).
    public static func entries(status diary: String, score: Double?, film: Bool, watches: [Watch], chain: [Media], notes: String? = nil,
                               placed: [String: Int] = [:]) -> (entries: [Entry], unplaced: Int) {
        guard let first = chain.first else { return ([], watches.count) }
        let score = score.map { min(100, max(0, Int(($0 * 10).rounded()))) }
        let notes = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        func day(_ text: String?) -> String? { text.map { String($0.prefix(10)) }.flatMap { $0.count == 10 ? $0 : nil } }
        if film {
            let times = watches.compactMap { day($0.watchedAt) }.sorted()
            if watches.isEmpty {
                guard ["planned", "dropped", "paused", "on_hold"].contains(diary) else { return ([], 0) }
                return ([Entry(mediaId: first.id, status: status(diary), progress: 0, score: score, notes: notes)], 0)
            }
            return ([Entry(mediaId: first.id, status: "COMPLETED", progress: first.episodes ?? 1, score: score,
                           startedAt: times.first, completedAt: times.last, repeatCount: max(0, watches.count - 1), notes: notes)], 0)
        }
        var assigned: [Int: [Watch]] = [:], unplaced = 0
        let ids = Set(chain.map(\.id))
        let seasons = chain.filter { ["TV", "TV_SHORT", "ONA"].contains($0.format ?? "TV") }
        let byDate = seasons.isEmpty ? chain : seasons
        for watch in watches {
            if let season = watch.season, let number = watch.number, let id = placed["\(season)x\(number)"], ids.contains(id) {
                assigned[id, default: []].append(watch); continue
            }
            // Specials (season 0) aren't a season's episodes: AniList keeps them as entries of their
            // own, which only the map names.
            guard watch.season != 0 else { continue }
            if let aired = day(watch.aired), let media = media(for: aired, in: byDate) { assigned[media.id, default: []].append(watch) }
            else if byDate.count == 1 { assigned[byDate[0].id, default: []].append(watch) }
            else { unplaced += 1 }
        }
        var result: [Entry] = []
        for media in chain {
            let watched = assigned[media.id] ?? []
            // Each episode's watch days, in order.
            var plays: [String: [String]] = [:]
            for watch in watched { plays["\(watch.season ?? 0)x\(watch.number ?? 0)", default: []].append(day(watch.watchedAt) ?? "") }
            let progress = min(plays.count, media.episodes ?? Int.max)
            if progress == 0 {
                if media.id == first.id, diary == "planned" { result.append(Entry(mediaId: media.id, status: "PLANNING", progress: 0, score: score, notes: notes)) }
                continue
            }
            let complete = media.episodes.map { progress >= $0 } ?? false
            let times = watched.compactMap { day($0.watchedAt) }.sorted()
            let held = ["dropped", "paused", "on_hold"].contains(diary)
            guard complete else {
                result.append(Entry(mediaId: media.id, status: held ? status(diary) : "CURRENT", progress: progress, score: score, startedAt: times.first, notes: notes))
                continue
            }
            // Complete: every episode watched `passes` times; finished when the last of them was.
            let counts = plays.values.map(\.count), passes = counts.min() ?? 1
            let finished = plays.values.compactMap { days in days.sorted().dropFirst(passes - 1).first }.filter { !$0.isEmpty }.max()
            let again = counts.filter { $0 > passes }.count
            let rewatching = diary == "watching" && again > 0
            result.append(Entry(mediaId: media.id, status: rewatching ? "REPEATING" : "COMPLETED", progress: rewatching ? again : progress, score: score,
                                startedAt: times.first, completedAt: finished, repeatCount: passes - 1, notes: notes))
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
