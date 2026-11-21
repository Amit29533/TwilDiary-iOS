import Foundation
import NaturalLanguage

// MARK: The library, read for recommending

/// One title of the server, as recommending reads it: the words in its name, file and folder (each
/// reduced to its root: "dancing" and "danced" are "dance"), its folder, date, length, genres, tags,
/// studios and TMDB id, and a key that two copies of the same thing share.
struct JellyIndexEntry: Sendable {
    let item: JellyfinClient.Item
    /// Root word → the word as it was written (for a row's name: "Rain").
    let words: [String: String]
    let folder: String
    let date: Date?
    let minutes: Double
    let genres: Set<String>
    let tags: Set<String>
    let studios: Set<String>
    let tmdb: Int?
    /// A film or show Jellyfin knows (TMDB), not a home video or an unmatched file.
    let titled: Bool
    let duplicateKey: String
    var played: Bool { item.UserData?.Played == true }
    var lastPlayed: Date? { JellyWords.date(item.UserData?.LastPlayedDate) }
}

/// Every film, show and video on the server, read once (kept while the app runs), with how many titles
/// each word appears in: a word in few titles says more than one in half the library.
struct JellyLibraryIndex: Sendable {
    let entries: [JellyIndexEntry]
    let position: [String: Int]
    let frequency: [String: Int]

    func idf(_ word: String) -> Double {
        log(Double(entries.count + 1) / Double((frequency[word] ?? 0) + 1))
    }

    static func build(_ items: [JellyfinClient.Item]) -> JellyLibraryIndex {
        let tagger = NLTagger(tagSchemes: [.lemma])
        var entries: [JellyIndexEntry] = []
        var frequency: [String: Int] = [:]
        entries.reserveCapacity(items.count)
        for item in items {
            let tmdb = item.ProviderIds?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) }
            let titled = tmdb != nil && item.kind != "Video"
            let path = item.Path ?? ""
            let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            let file = parts.last.map { ($0 as NSString).deletingPathExtension } ?? ""
            let folder = parts.count >= 2 ? parts[parts.count - 2] : ""
            // The name, the file and the folder all count (a clip in "Goa Trip 2023" is about Goa).
            var words: [String: String] = [:]
            for source in [item.Name ?? "", file, folder] {
                for (root, written) in JellyWords.words(source, tagger: tagger) where words[root] == nil { words[root] = written }
            }
            for root in words.keys { frequency[root, default: 0] += 1 }
            let date = item.kind == "Video"
                ? (JellyWords.dateInName(file) ?? JellyWords.date(item.PremiereDate) ?? JellyWords.date(item.DateCreated))
                : (JellyWords.date(item.PremiereDate) ?? item.ProductionYear.flatMap { JellyWords.year($0) })
            let minutes = Double(item.RunTimeTicks ?? 0) / 600_000_000
            let key = tmdb.map { "tmdb:\(item.kind):\($0)" }
                ?? words.keys.filter { !JellyWords.copyMarks.contains($0) }.sorted().joined(separator: " ") + "|\(Int(minutes.rounded()))"
            entries.append(JellyIndexEntry(item: item, words: words, folder: folder, date: date, minutes: minutes,
                                           genres: Set((item.Genres ?? []).map { $0.lowercased() }),
                                           tags: Set((item.Tags ?? []).map { $0.lowercased() }),
                                           studios: Set((item.Studios ?? []).compactMap { $0.Name?.lowercased() }),
                                           tmdb: tmdb, titled: titled, duplicateKey: key))
        }
        let position = Dictionary(entries.enumerated().map { ($0.element.item.Id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return JellyLibraryIndex(entries: entries, position: position, frequency: frequency)
    }
}

/// Words out of names: split at spaces, dots, underscores, dashes and CamelCase; lower-cased; filler
/// ("the", "video", "final", camera prefixes like VID or PXL, release tags like 1080p) left out;
/// each word reduced to its root by Apple's on-device language tools.
enum JellyWords {
    static let filler: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "this", "that", "these", "those", "are", "was", "were", "has", "have",
        "had", "his", "her", "hers", "their", "our", "ours", "your", "you", "its", "not", "but", "all", "any", "one", "two",
        "video", "videos", "clip", "clips", "final", "copy", "edit", "edited", "new", "old", "part", "full", "untitled",
        "img", "vid", "pxl", "dsc", "dscn", "dscf", "gopr", "mvi", "dji", "mov", "mpg", "mp4", "mkv", "avi", "wmv", "m4v",
        "trim", "export", "exported", "compressed", "camera", "recording", "screen", "rpreplay", "signal", "whatsapp", "snapchat",
        "web", "webrip", "webdl", "bluray", "brrip", "bdrip", "hdrip", "dvdrip", "hdtv", "remux", "proper", "repack", "extended",
        "x264", "x265", "hevc", "h264", "h265", "aac", "dts", "ddp", "atmos", "hdr", "uhd", "sdr", "multi", "dual", "audio",
        "season", "episode", "sample", "movie", "film",
    ]
    /// Marks of a second copy ("dance_compressed", "dance (1)"), left out of the copy key.
    static let copyMarks: Set<String> = ["copy", "compressed", "final", "edit", "export"]

    static func words(_ text: String, tagger: NLTagger) -> [(String, String)] {
        guard !text.isEmpty else { return [] }
        let spaced = text.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }
        let pieces = spaced.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        guard !pieces.isEmpty else { return [] }
        let lowered = pieces.map { $0.lowercased() }.filter { !filler.contains($0) }
        guard !lowered.isEmpty else { return [] }
        let sentence = lowered.joined(separator: " ")
        tagger.string = sentence
        var out: [(String, String)] = []
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = String(sentence[range])
            var root = tag?.rawValue.lowercased() ?? word
            if tag == nil, root.count > 4, root.hasSuffix("s"), !root.hasSuffix("ss") { root.removeLast() }
            if root.count >= 3, !filler.contains(root) {
                let written = pieces.first { $0.lowercased() == word } ?? word
                out.append((root, written.prefix(1).uppercased() + written.dropFirst()))
            }
            return true
        }
        return out
    }

    /// Jellyfin's dates ("2023-05-12T18:30:22.0000000Z"), to the second, in UTC.
    static func date(_ iso: String?) -> Date? {
        guard let iso, iso.count >= 10 else { return nil }
        let digits = iso.prefix(19).split { !$0.isNumber }.compactMap { Int($0) }
        guard digits.count >= 3, digits[0] > 1800 else { return nil }
        var parts = DateComponents(year: digits[0], month: digits[1], day: digits[2])
        if digits.count >= 6 { parts.hour = digits[3]; parts.minute = digits[4]; parts.second = digits[5] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: parts)
    }
    static func year(_ year: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: year, month: 7, day: 1))
    }
    /// A date (and time) in a camera's file name: VID_20230512_183022, PXL_20230512_183022123, 2023-05-12 18.30.22.
    static func dateInName(_ name: String) -> Date? {
        guard let match = name.firstMatch(of: /(20\d{2}|19\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?:[ _T.-]?([01]\d|2[0-3])[-_.:]?([0-5]\d)[-_.:]?([0-5]\d))?/) else { return nil }
        var parts = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))
        if let hour = match.4, let minute = match.5 { parts.hour = Int(hour); parts.minute = Int(minute); parts.second = match.6.flatMap { Int($0) } }
        return Calendar(identifier: .gregorian).date(from: parts)
    }
}

// MARK: More like this

/// A title recommended, and why ("Same director · Bong Joon-ho", "Kevin · Rain", "Same day").
struct JellyRecommendation: Sendable {
    let item: JellyfinClient.Item
    let reason: String
}

enum JellyRecommender {
    /// What's known about the title beyond the library itself, fetched for it.
    struct Signals: Sendable {
        /// TMDB's recommendations for it (its ids, most recommended first).
        var tmdb: [Int] = []
        /// Its leads and director, and their other titles on the server.
        var people: [Person] = []
        /// Jellyfin's own similar titles.
        var jellyfin: Set<String> = []
        struct Person: Sendable {
            let name: String
            let director: Bool
            let titles: Set<String>
        }
    }

    /// Up to `limit` titles like this one, each with its reason. Strong signals first (TMDB, people,
    /// tags, words in the names, the same moment or day); where there are too few, similar length and
    /// random picks from the same folder. Copies show once; unwatched ones are lifted a little; the
    /// random part changes day to day, not each time the page opens.
    static func similar(to id: String, in index: JellyLibraryIndex, signals: Signals, limit: Int = 12) -> [JellyRecommendation] {
        guard let spot = index.position[id] else { return [] }
        let target = index.entries[spot]
        var random = SeededRandom(seed: SeededRandom.hash(id + Self.today))
        // Words close to the title's own count half (rain ~ storm, dance ~ party).
        let related = Self.relatedWords(Array(target.words.keys))
        let tmdbRank = Dictionary(signals.tmdb.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var scored: [(score: Double, reason: String, entry: JellyIndexEntry)] = []
        for (offset, candidate) in index.entries.enumerated() where offset != spot {
            guard candidate.titled == target.titled, candidate.duplicateKey != target.duplicateKey,
                  ["Movie", "Series", "Video"].contains(candidate.item.kind) else { continue }
            var strong: [(Double, String)] = []
            if let tmdb = candidate.tmdb, let rank = tmdbRank[tmdb] { strong.append((7 - Double(min(rank, 10)) * 0.25, "Recommended by TMDB")) }
            for person in signals.people where person.titles.contains(candidate.item.Id) {
                strong.append(person.director ? (6, "Same director · " + person.name) : (4.5, "Also with " + person.name))
            }
            if signals.jellyfin.contains(candidate.item.Id) { strong.append((3, "Similar on Jellyfin")) }
            let tags = target.tags.intersection(candidate.tags)
            if let tag = tags.first { strong.append((3 * Double(tags.count), "Tag · " + tag.capitalized)) }
            // Words in the names: rare ones weigh more; a titled film's own title words count less
            // (its genres and people say more than "dark" in "The Dark Knight").
            let shared = target.words.keys.filter { candidate.words[$0] != nil }
            var wordScore = shared.reduce(0) { $0 + index.idf($1) }
            let near = related.filter { candidate.words[$0.key] != nil }
            wordScore += near.reduce(0) { $0 + index.idf($1.key) * 0.5 }
            if wordScore > 0 {
                let named = shared.sorted { index.idf($0) > index.idf($1) }.prefix(2).compactMap { target.words[$0] }
                let label = named.isEmpty ? near.keys.prefix(2).map { $0.capitalized }.joined(separator: " · ") : named.joined(separator: " · ")
                strong.append((wordScore * (target.titled ? 0.35 : 1), label))
            }
            if target.titled {
                let genres = target.genres.intersection(candidate.genres)
                if !genres.isEmpty { strong.append((1.4 * Double(genres.count), genres.sorted().prefix(2).map { $0.capitalized }.joined(separator: " · "))) }
                if let studio = target.studios.intersection(candidate.studios).first { strong.append((1.5, "Same studio · " + studio.capitalized)) }
            } else if let a = target.date, let b = candidate.date {
                // Home videos: taken at the same moment (within a few hours), day or week.
                let apart = abs(a.timeIntervalSince(b))
                if apart < 3 * 3600 { strong.append((5, "Same moment")) }
                else if Calendar.current.isDate(a, inSameDayAs: b) { strong.append((3.5, "Same day")) }
                else if apart < 7 * 86_400 { strong.append((1.5, "Same week")) }
            }
            // The weak part: the same folder, a close date or length, unwatched, and a little chance.
            var weak: [(Double, String)] = []
            if !target.folder.isEmpty, candidate.folder == target.folder {
                weak.append((target.titled ? 0.3 : 1.2, "Random from " + target.folder))
            }
            if target.minutes > 0, candidate.minutes > 0 {
                let closeness = 1 - min(1, abs(target.minutes - candidate.minutes) / max(target.minutes, candidate.minutes))
                weak.append((closeness * 0.6, "Similar length"))
            }
            if target.titled, let a = target.date, let b = candidate.date, abs(a.timeIntervalSince(b)) < 2 * 365 * 86_400 {
                weak.append((0.3, "Around the same time"))
            }
            let unwatched = candidate.played ? 0 : 0.5
            let chance = Double.random(in: 0..<0.4, using: &random)
            let strongTotal = strong.reduce(0) { $0 + $1.0 }
            let weakTotal = weak.reduce(0) { $0 + $1.0 } + unwatched + chance
            let reason = strongTotal >= 1.5
                ? (strong.max { $0.0 < $1.0 }?.1 ?? "")
                : (weak.max { $0.0 < $1.0 }?.1 ?? "Random pick")
            scored.append((strongTotal * 10 + weakTotal, reason, candidate))
        }
        var seen = Set<String>(), picks: [JellyRecommendation] = []
        for pick in scored.sorted(by: { $0.score > $1.score }) where seen.insert(pick.entry.duplicateKey).inserted {
            picks.append(JellyRecommendation(item: pick.entry.item, reason: pick.reason))
            if picks.count == limit { break }
        }
        return picks
    }

    static var today: String { String(Int(Date.now.timeIntervalSince1970 / 86_400)) }

    /// Words near these in meaning, by Apple's on-device English word model (rain → storm, monsoon).
    static func relatedWords(_ words: [String]) -> [String: Double] {
        guard let model = NLEmbedding.wordEmbedding(for: .english) else { return [:] }
        var near: [String: Double] = [:]
        for word in words.prefix(8) {
            for (other, distance) in model.neighbors(for: word, maximumCount: 6) where distance < 0.9 && !words.contains(other) {
                near[other] = max(near[other] ?? 0, 1 - distance)
            }
        }
        return near
    }
}

// MARK: Rows across the whole server

/// A themed row on the home: "Recommendations for Rain", "Random picks for Dance", "Must watch Parks".
struct JellyTheme: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [JellyfinClient.Item]
}

extension JellyRecommender {
    /// Three themed rows from the words and tags across the server: one from what you watched lately,
    /// one random, one of the best rated. A theme is a word or tag a handful of titles share (in three
    /// or more, not half the library). They change day to day.
    static func themes(in index: JellyLibraryIndex) -> [JellyTheme] {
        let count = index.entries.count
        guard count >= 6 else { return [] }
        let ceiling = max(8, count / 6)
        var random = SeededRandom(seed: SeededRandom.hash("themes" + today))
        // Themes: words and tags in between rare and everywhere.
        var members: [String: [Int]] = [:], names: [String: String] = [:]
        for (offset, entry) in index.entries.enumerated() where ["Movie", "Series", "Video"].contains(entry.item.kind) {
            for (root, written) in entry.words { members[root, default: []].append(offset); names[root] = names[root] ?? written }
            for tag in entry.tags { members["#" + tag, default: []].append(offset); names["#" + tag] = names["#" + tag] ?? tag.capitalized }
        }
        let eligible = members.filter { $0.value.count >= 3 && $0.value.count <= ceiling }
        guard !eligible.isEmpty else { return [] }
        var used = Set<String>(), rows: [JellyTheme] = []
        func unique(_ offsets: [Int]) -> [JellyfinClient.Item] {
            var keys = Set<String>()
            return offsets.map { index.entries[$0] }.filter { keys.insert($0.duplicateKey).inserted }.prefix(15).map(\.item)
        }
        // 1. From what you watched lately.
        let recent = index.entries.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }.prefix(6)
        if let theme = recent.lazy.flatMap({ $0.words.keys.sorted { index.idf($0) > index.idf($1) } }).first(where: { eligible[$0] != nil }) {
            used.insert(theme)
            let offsets = (eligible[theme] ?? []).sorted { a, b in
                let x = index.entries[a], y = index.entries[b]
                if x.played != y.played { return !x.played }
                return (x.item.CommunityRating ?? 0) > (y.item.CommunityRating ?? 0)
            }
            rows.append(JellyTheme(id: "for-" + theme, title: "Recommendations for " + (names[theme] ?? theme), items: unique(offsets)))
        }
        // 2. A random theme, shuffled.
        let pool = eligible.keys.filter { !used.contains($0) }.sorted()
        if let theme = pool.randomElement(using: &random) {
            used.insert(theme)
            rows.append(JellyTheme(id: "random-" + theme, title: "Random picks for " + (names[theme] ?? theme),
                                   items: unique((eligible[theme] ?? []).shuffled(using: &random))))
        }
        // 3. The best rated theme.
        let rated = eligible.filter { !used.contains($0.key) }.compactMap { theme -> (String, Double)? in
            let ratings = theme.value.compactMap { index.entries[$0].item.CommunityRating }
            return ratings.count >= 3 ? (theme.key, ratings.reduce(0, +) / Double(ratings.count)) : nil
        }.sorted { $0.1 > $1.1 }.prefix(5)
        if let theme = rated.randomElement(using: &random)?.0 {
            let offsets = (eligible[theme] ?? []).sorted { (index.entries[$0].item.CommunityRating ?? 0) > (index.entries[$1].item.CommunityRating ?? 0) }
            rows.append(JellyTheme(id: "best-" + theme, title: "Must watch " + (names[theme] ?? theme), items: unique(offsets)))
        }
        return rows.filter { $0.items.count >= 3 }
    }
}

// MARK: Keeping it

/// The index for the server and user, built in the background once and kept for a quarter of an hour.
@MainActor enum JellyIndexStore {
    private static var kept: (key: String, at: Date, index: JellyLibraryIndex)?
    private static var building: Task<JellyLibraryIndex?, Never>?

    static func index(client: JellyfinClient, user: String?) async -> JellyLibraryIndex? {
        let key = client.base.absoluteString + "|" + (user ?? "")
        if let kept, kept.key == key, Date.now.timeIntervalSince(kept.at) < 900 { return kept.index }
        if let building { return await building.value }
        let task = Task<JellyLibraryIndex?, Never> {
            guard let items = try? await client.libraryIndex(user: user), !items.isEmpty else { return nil }
            return await Task.detached(priority: .utility) { JellyLibraryIndex.build(items) }.value
        }
        building = task
        let built = await task.value
        building = nil
        if let built { kept = (key, .now, built) }
        return built
    }
}

/// A random number generator from a seed, so "random" picks stay the same through a day.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    /// The same number for the same text on every launch (Swift's own hash changes each launch).
    static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: Readable names

/// Names for files Jellyfin couldn't match (no TMDB id): a camera's file name as its date and time
/// ("VID_20230512_183022" → "12 May 2023 · 6:30 PM"), a release name as a title and year
/// ("Movie.Name.2019.1080p.x265" → "Movie Name (2019)"), dots and underscores as spaces. A film or
/// show Jellyfin knows keeps its name.
enum JellyNames {
    static func title(_ item: JellyfinClient.Item) -> String {
        let titled = item.ProviderIds?.keys.contains(where: { $0.lowercased() == "tmdb" }) == true
        return title(item.Name ?? "", kind: item.kind, path: item.Path, titled: titled)
    }

    static func title(_ name: String, kind: String, path: String?, titled: Bool) -> String {
        guard !titled, kind == "Video" || kind == "Movie" else { return name }
        let file = path.flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { (String($0) as NSString).deletingPathExtension } }
        let base = name.isEmpty ? (file ?? "") : name
        guard !base.isEmpty else { return name }
        if looksLikeCamera(base), let date = JellyWords.dateInName(base) { return spoken(date) }
        if let release = (try? Regex(Self.releasePattern)).flatMap({ base.firstMatch(of: $0) }),
           let titlePart = release.output[1].substring, let yearPart = release.output[2].substring {
            let title = spaced(String(titlePart))
            if !title.isEmpty { return title + " (" + yearPart + ")" }
        }
        if base.contains(".") || base.contains("_") {
            // No year: up to the first release tag (1080p, x265, WEB…).
            let words = base.split { $0 == "." || $0 == "_" || $0 == " " }.map(String.init)
            let kept = words.prefix { !JellyWords.filler.contains($0.lowercased()) && $0.range(of: #"^\d{3,4}p$"#, options: .regularExpression) == nil }
            let title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? spaced(base) : title
        }
        return base
    }

    /// A title, then a year after a separator ("Movie.Name.2019.1080p").
    private static let releasePattern = #"^(.+?)[ ._\-\(\[]+((?:19|20)\d{2})(?:[ ._\-\)\]]|$)"#
    /// A phone's or camera's own name: a known prefix, or barely any letters.
    private static func looksLikeCamera(_ name: String) -> Bool {
        let lower = name.lowercased()
        let prefixes = ["vid", "img", "pxl", "mvi", "dsc", "gopr", "gp", "dji", "wp", "pano", "mov", "sam", "screen recording",
                        "screenrecording", "rpreplay", "signal", "whatsapp video", "video", "trim", "lv_", "inshot", "cap"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        return name.filter(\.isLetter).count < 4
    }
    private static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// "12 May 2023 · 6:30 PM" (the date alone when the name had no time).
    private static func spoken(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let day = date.formatted(.dateTime.day().month(.abbreviated).year())
        guard (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0 || (parts.second ?? 0) != 0 else { return day }
        return day + " · " + date.formatted(.dateTime.hour().minute())
    }
}
