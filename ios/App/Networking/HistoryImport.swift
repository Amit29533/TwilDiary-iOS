import Foundation
import Compression
import TwilDiaryCore

/// Import from another app: Letterboxd's export (the ZIP or its CSVs), IMDb's ratings or
/// watchlist CSV, TV Time's data export (the ZIP or its CSVs). Each title is matched to TMDB,
/// then everything goes where your diary lives, the way a backup is restored: only what's missing
/// there is added (watches at their dates, ratings, Planned), so importing twice adds nothing twice.
enum ImportSource: String, CaseIterable, Identifiable, Sendable {
    case letterboxd, imdb, tvtime
    var id: Self { self }
    var name: String { switch self { case .letterboxd: "Letterboxd"; case .imdb: "IMDb"; case .tvtime: "TV Time" } }
    @MainActor var logo: BrandLogo.Service { switch self { case .letterboxd: .letterboxd; case .imdb: .imdb; case .tvtime: .tvtime } }
    var hint: String {
        switch self {
        case .letterboxd: "Settings → Data → Export your data on letterboxd.com. Pick the ZIP (or its CSV files)."
        case .imdb: "Your Ratings or Watchlist → ⋯ → Export on imdb.com. Pick the CSV."
        case .tvtime: "Your data export from TV Time. Pick the ZIP (or its CSV files)."
        }
    }
}

/// One title from the export, before and after it's matched to TMDB.
struct ImportEntry: Sendable, Hashable {
    enum Kind: String, Sendable { case movie, show }
    var kind: Kind
    var name: String
    var year: Int?
    var imdb: String?
    var tvdb: Int?
    var tmdb: Int?
    /// 1–10.
    var rating: Double?
    var planned = false
    var plays: [ImportPlay] = []
}
struct ImportPlay: Sendable, Hashable {
    var season: Int?
    var episode: Int?
    /// ISO 8601.
    var watchedAt: String
}

enum HistoryImport {
    // MARK: Reading the files

    /// The CSV files in what you picked (a ZIP is opened on the phone).
    static func csvFiles(_ picked: [(name: String, data: Data)]) -> [(name: String, data: Data)] {
        var files: [(name: String, data: Data)] = []
        for file in picked {
            if file.data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]) { files += ZipReader.entries(file.data).filter { $0.name.lowercased().hasSuffix(".csv") } }
            else { files.append(file) }
        }
        return files
    }

    static func entries(_ source: ImportSource, files: [(name: String, data: Data)]) -> [ImportEntry] {
        switch source {
        case .letterboxd: letterboxd(files)
        case .imdb: imdb(files)
        case .tvtime: tvTime(files)
        }
    }

    /// diary.csv (dated watches and their ratings), watched.csv (a watch for films with none
    /// dated), ratings.csv, watchlist.csv. Letterboxd's 0.5–5 stars are doubled to 1–10.
    static func letterboxd(_ files: [(name: String, data: Data)]) -> [ImportEntry] {
        var films: [String: ImportEntry] = [:]
        var watchedOn: [String: String] = [:]
        func key(_ row: [String: String]) -> String { (row["name"] ?? "") + "|" + (row["year"] ?? "") }
        func entry(_ row: [String: String]) -> ImportEntry? {
            guard let name = row["name"], !name.isEmpty else { return nil }
            return films[key(row)] ?? ImportEntry(kind: .movie, name: name, year: row["year"].flatMap { Int($0) })
        }
        for file in files {
            let base = (file.name as NSString).lastPathComponent.lowercased()
            // The ZIP also holds deleted/, orphaned/ and likes/ copies: only the main files count.
            let folder = file.name.lowercased()
            guard !folder.contains("deleted/"), !folder.contains("orphaned/"), !folder.contains("likes/") else { continue }
            for row in CSV.rows(file.data) {
                guard var film = entry(row) else { continue }
                let stars = row["rating"].flatMap { Double($0) }.map { $0 * 2 }
                switch base {
                case "diary.csv":
                    if let day = row["watched date"].flatMap(isoDay) ?? row["date"].flatMap(isoDay) { film.plays.append(ImportPlay(watchedAt: day)) }
                    if let stars { film.rating = stars }
                case "watched.csv":
                    if let day = row["date"].flatMap(isoDay) { watchedOn[key(row)] = day }
                case "ratings.csv":
                    if let stars { film.rating = stars }
                case "watchlist.csv":
                    film.planned = true
                default:
                    continue
                }
                films[key(row)] = film
            }
        }
        // Watched without a dated diary entry: one watch on the day it was logged.
        for (slot, day) in watchedOn {
            guard var film = films[slot], film.plays.isEmpty else { continue }
            film.plays.append(ImportPlay(watchedAt: day))
            films[slot] = film
        }
        return films.values.sorted { $0.name < $1.name }
    }

    /// Ratings CSV (Const, Your Rating, Date Rated, Title, Title Type, Year): a rating, and a
    /// movie counts as watched the day you rated it. Watchlist CSV (no Your Rating): Planned.
    /// Episode ratings are left out.
    static func imdb(_ files: [(name: String, data: Data)]) -> [ImportEntry] {
        var titles: [String: ImportEntry] = [:]
        for file in files {
            for row in CSV.rows(file.data) {
                guard let id = row["const"], id.hasPrefix("tt"), let name = row["title"] else { continue }
                let type = (row["title type"] ?? "movie").lowercased()
                if type.contains("episode") { continue }
                var title = titles[id] ?? ImportEntry(kind: type.contains("series") ? .show : .movie, name: name, year: row["year"].flatMap { Int($0) }, imdb: id)
                if let rating = row["your rating"].flatMap({ Double($0) }) {
                    title.rating = rating
                    if title.kind == .movie, let day = row["date rated"].flatMap(isoDay) ?? row["created"].flatMap(isoDay) { title.plays = [ImportPlay(watchedAt: day)] }
                } else {
                    title.planned = true
                }
                titles[id] = title
            }
        }
        return titles.values.sorted { $0.name < $1.name }
    }

    /// TV Time's episode watches: any CSV with a show, season and episode number (seen_episode.csv
    /// and the like), dated by when you marked it; the show is found by its TVDB id or name.
    static func tvTime(_ files: [(name: String, data: Data)]) -> [ImportEntry] {
        var shows: [String: ImportEntry] = [:]
        func column(_ row: [String: String], _ names: [String]) -> String? {
            for name in names { if let value = row[name], !value.isEmpty { return value } }
            return nil
        }
        for file in files {
            for row in CSV.rows(file.data) {
                guard let name = column(row, ["tv_show_name", "series_name", "show_name", "tv_show", "series"]),
                      let season = column(row, ["episode_season_number", "season_number", "season"]).flatMap({ Int($0) }),
                      let number = column(row, ["episode_number", "number", "episode"]).flatMap({ Int($0) }) else { continue }
                let tvdb = column(row, ["tv_show_id", "series_id", "tvdb_id", "show_id"]).flatMap { Int($0) }
                let slot = tvdb.map(String.init) ?? name.lowercased()
                var show = shows[slot] ?? ImportEntry(kind: .show, name: name, tvdb: tvdb)
                guard let day = column(row, ["created_at", "watched_at", "updated_at", "date"]).flatMap(isoTime) else { continue }
                if !show.plays.contains(where: { $0.season == season && $0.episode == number }) {
                    show.plays.append(ImportPlay(season: season, episode: number, watchedAt: day))
                }
                shows[slot] = show
            }
        }
        return shows.values.sorted { $0.name < $1.name }
    }

    /// "2023-05-14" → noon that day (UTC), the time a dated-only watch is given.
    static func isoDay(_ value: String) -> String? {
        let day = value.trimmingCharacters(in: .whitespaces).prefix(10)
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return day + "T12:00:00.000Z"
    }
    /// "2019-03-02 21:33:12" (or ISO) → ISO 8601; a date alone → noon.
    static func isoTime(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil {
            return String(text.prefix(10)) + "T" + String(text.dropFirst(11).prefix(8)) + ".000Z"
        }
        return isoDay(text)
    }

    // MARK: Matching to TMDB

    /// Finds each title on TMDB (IMDb or TVDB id, else name and year). Returns the matched ones
    /// (the same title from several files merged) and the names it couldn't place.
    @MainActor static func match(_ entries: [ImportEntry], token: String, progress: @MainActor (Int, Int) -> Void) async -> (matched: [ImportEntry], missed: [String]) {
        var matched: [String: ImportEntry] = [:], missed: [String] = []
        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            progress(index + 1, entries.count)
            guard let tmdb = await tmdbID(entry, token: token) else { missed.append(entry.year.map { "\(entry.name) (\($0))" } ?? entry.name); continue }
            let slot = entry.kind.rawValue + ":\(tmdb)"
            var value = entry
            value.tmdb = tmdb
            if let existing = matched[slot] {
                value = existing
                value.rating = entry.rating ?? existing.rating
                value.planned = existing.planned || entry.planned
                for play in entry.plays where !value.plays.contains(play) { value.plays.append(play) }
            }
            matched[slot] = value
        }
        return (matched.values.sorted { $0.name < $1.name }, missed)
    }
    @MainActor private static func tmdbID(_ entry: ImportEntry, token: String) async -> Int? {
        if let tmdb = entry.tmdb { return tmdb }
        func first(_ list: Any?) -> Int? { ((list as? [[String: Any]])?.first?["id"] as? NSNumber)?.intValue }
        if let imdb = entry.imdb, let found = try? await TMDBDirect.object("find/\(imdb)", query: ["external_source": "imdb_id"], token: token) {
            if let id = first(entry.kind == .movie ? found["movie_results"] : found["tv_results"]) { return id }
        }
        if let tvdb = entry.tvdb, let found = try? await TMDBDirect.object("find/\(tvdb)", query: ["external_source": "tvdb_id"], token: token),
           let id = first(found["tv_results"]) { return id }
        let path = entry.kind == .movie ? "search/movie" : "search/tv"
        if let year = entry.year,
           let found = try? await TMDBDirect.object(path, query: ["query": entry.name, entry.kind == .movie ? "year" : "first_air_date_year": String(year)], token: token),
           let id = first(found["results"]) { return id }
        if let found = try? await TMDBDirect.object(path, query: ["query": entry.name], token: token) { return first(found["results"]) }
        return nil
    }

    // MARK: Into the diary

    /// The matched titles as a diary (titles, episodes, watches), ready for the backup restore.
    static func workspace(_ entries: [ImportEntry], now: Date = .now) -> Workspace {
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now)
        var titles: [MediaTitle] = [], episodes: [Episode] = [], events: [WatchEvent] = []
        for entry in entries {
            guard let tmdb = entry.tmdb else { continue }
            let movie = entry.kind == .movie
            let id = (movie ? "movie:" : "tv:") + String(tmdb)
            let status = !entry.plays.isEmpty ? (movie ? "completed" : "watching") : entry.planned ? "planned" : "completed"
            titles.append(.imported(id: id, name: entry.name, series: !movie, year: entry.year, tmdbId: tmdb, status: status, score: entry.rating, createdAt: stamp))
            var made = Set<String>()
            for (index, play) in entry.plays.enumerated() {
                var episodeID: String?
                if let season = play.season, let number = play.episode {
                    let episode = "\(id)|s\(season)e\(number)"
                    if made.insert(episode).inserted {
                        episodes.append(.numbered(id: episode, titleId: id, season: season, number: number))
                    }
                    episodeID = episode
                }
                let event = "import-\(id)-\(index)-\(play.watchedAt)"
                events.append(WatchEvent(id: event, operationId: event, titleId: id, episodeId: episodeID, watchedAt: play.watchedAt,
                                         recordedAt: play.watchedAt, origin: "import"))
            }
        }
        return Workspace(titles: titles, episodes: episodes, events: events)
    }
}

/// A small CSV reader: quoted fields, commas and line breaks inside quotes, "" for a quote.
/// Rows come back keyed by the header, lower-cased.
enum CSV {
    static func rows(_ data: Data) -> [[String: String]] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if quoted {
                if character == "\"" {
                    // "" inside quotes is a quote; a lone one ends the quoted part.
                    var copy = iterator
                    if copy.next() == "\"" { field.append("\""); _ = iterator.next() } else { quoted = false }
                } else { field.append(character) }
                continue
            }
            switch character {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return [] }
        return rows.dropFirst().map { values in
            var keyed: [String: String] = [:]
            for (index, name) in header.enumerated() where index < values.count { keyed[name] = values[index].trimmingCharacters(in: .whitespaces) }
            return keyed
        }
    }
}

/// Opens a ZIP on the phone (stored or deflated entries; what Letterboxd and TV Time send).
enum ZipReader {
    static func entries(_ data: Data) -> [(name: String, data: Data)] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 22 else { return [] }
        // The end-of-directory record, within the last 64 KB.
        var end = -1
        var at = bytes.count - 22
        while at >= max(0, bytes.count - 65_557) { if u32(at) == 0x06054b50 { end = at; break }; at -= 1 }
        guard end >= 0 else { return [] }
        var out: [(name: String, data: Data)] = []
        var offset = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard offset + 46 <= bytes.count, u32(offset) == 0x02014b50 else { break }
            let method = u16(offset + 10), packed = u32(offset + 20), size = u32(offset + 24)
            let nameLength = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32), local = u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extra + comment
            guard !name.hasSuffix("/"), local + 30 <= bytes.count, u32(local) == 0x04034b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + packed <= bytes.count else { continue }
            let raw = Data(bytes[start..<(start + packed)])
            if method == 0 { out.append((name, raw)) }
            else if method == 8, let inflated = inflate(raw, size: size) { out.append((name, inflated)) }
        }
        return out
    }
    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB) to exactly `size` bytes.
    private static func inflate(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }
}
