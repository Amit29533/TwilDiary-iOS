import Foundation
import TwilDiaryCore

/// Where Simkl keeps one diary episode (or an anime film), as placed by Simkl's sync: its entry
/// and its own numbering. `entry` nil: Simkl lists no such episode (the formula found no place),
/// so it isn't compared, never counted as missing.
struct SimklPlacement: Codable, Equatable, Sendable {
    var entry: Int?
    var season: Int?
    var number: Int?
    var at: Date
}

/// Simkl's library read back for the comparison (phase 2), in the diary's own terms.
///
/// Movies and TV shows carry TMDB ids. Anime don't, reliably: Simkl keeps one entry per cour,
/// OVA or special, often with no TMDB id or another one (Re:Zero's second cour has none; JoJo's
/// Stone Ocean part 2 and Demon Slayer's Kimetsu Academy have their own, tested 2026-11-14). So
/// an anime episode on Simkl is read through where the diary's episodes were placed (`Mapping`):
/// one that isn't the place of any diary episode is counted as skipped ("can't compare"), never
/// shown as a difference to fix.
enum SimklLibrary {
    struct Spot: Equatable, Sendable { let tmdb: Int; let season: Int; let number: Int }
    struct Mapping: Sendable {
        /// "entry:season:number" (Simkl's) → the diary's episode.
        var episodes: [String: Spot] = [:]
        /// A Simkl entry → the diary's show or film it belongs to.
        var shows: [Int: Int] = [:]
        var films: [Int: Int] = [:]
        /// The diary's titles, by TMDB id, with their names.
        var diaryShows: [Int: String] = [:]
        var diaryMovies: [Int: String] = [:]
        static func key(_ entry: Int, _ season: Int, _ number: Int) -> String { "\(entry):\(season):\(number)" }
    }

    /// From the placements ("tmdb:season:number" for an episode, "movie:tmdb" for a film) and the diary.
    static func mapping(placements: [String: SimklPlacement], diary: Workspace) -> Mapping {
        var mapping = Mapping()
        for title in diary.activeTitles {
            guard let tmdb = title.tmdbId else { continue }
            if title.isSeries { mapping.diaryShows[tmdb] = title.name } else { mapping.diaryMovies[tmdb] = title.name }
        }
        for (key, placed) in placements.sorted(by: { $0.key < $1.key }) {
            guard let entry = placed.entry else { continue }
            let parts = key.split(separator: ":").map(String.init)
            if parts.count == 2, parts[0] == "movie", let tmdb = Int(parts[1]) { mapping.films[entry] = tmdb; continue }
            guard parts.count == 3, let tmdb = Int(parts[0]), let season = Int(parts[1]), let number = Int(parts[2]), let simklNumber = placed.number else { continue }
            mapping.episodes[Mapping.key(entry, placed.season ?? 1, simklNumber)] = Spot(tmdb: tmdb, season: season, number: number)
            if mapping.shows[entry] == nil { mapping.shows[entry] = tmdb }
        }
        return mapping
    }

    /// One `/sync/all-items/{movies|shows|anime}` reply (extended=full, episode_watched_at=yes)
    /// added to the library: plays, ratings, Plan to watch (the watchlist) and Dropped.
    static func apply(_ kind: String, _ data: Data, mapping: Mapping, into library: inout TraktLibrary) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        for item in (root[kind] as? [[String: Any]]) ?? [] {
            let media = (item["movie"] as? [String: Any]) ?? (item["show"] as? [String: Any]) ?? [:]
            let ids = media["ids"] as? [String: Any] ?? [:]
            let tmdb = number(ids["tmdb"])
            let entry = number(ids["simkl"]) ?? number(ids["simkl_id"])
            let name = media["title"] as? String ?? ""
            let year = number(media["year"])
            let imdb = (ids["imdb"] as? String).flatMap { $0.hasPrefix("tt") ? $0 : nil }
            var ref: TraktTitleRef?
            var episodes: [(season: Int, number: Int, at: String?)] = []
            switch kind {
            case "movies":
                ref = tmdb.map { TraktTitleRef(kind: .movie, traktId: nil, tmdbId: $0, imdbId: imdb, name: mapping.diaryMovies[$0] ?? name, year: year) }
            case "shows":
                ref = tmdb.map { TraktTitleRef(kind: .show, traktId: nil, tmdbId: $0, imdbId: imdb, name: mapping.diaryShows[$0] ?? name, year: year) }
                episodes = watched(item)
            default:
                if (item["anime_type"] as? String) == "movie" {
                    // An anime film: by its TMDB id when the diary has that film, else where one was placed.
                    let film = tmdb.flatMap { mapping.diaryMovies[$0] != nil ? $0 : nil } ?? entry.flatMap { mapping.films[$0] }
                    ref = film.map { TraktTitleRef(kind: .movie, traktId: nil, tmdbId: $0, imdbId: imdb, name: mapping.diaryMovies[$0] ?? name, year: year) }
                } else {
                    let show = entry.flatMap { mapping.shows[$0] } ?? tmdb.flatMap { mapping.diaryShows[$0] != nil ? $0 : nil }
                    ref = show.map { TraktTitleRef(kind: .show, traktId: nil, tmdbId: $0, name: mapping.diaryShows[$0] ?? name, year: year) }
                    // Each watched episode through its placement: Simkl's numbering isn't the diary's.
                    for episode in watched(item) {
                        guard let entry, let spot = mapping.episodes[Mapping.key(entry, episode.season, episode.number)] else { library.skipped += 1; continue }
                        let diaryRef = TraktTitleRef(kind: .show, traktId: nil, tmdbId: spot.tmdb, name: mapping.diaryShows[spot.tmdb] ?? name, year: nil)
                        library.plays.append(TraktPlay(historyId: TrackerDecode.playID("simkl|\(entry)|\(episode.season)|\(episode.number)"), title: diaryRef,
                                                       season: spot.season, episode: spot.number, watchedAt: episode.at))
                    }
                }
            }
            guard let ref else { library.skipped += 1; continue }
            if ref.kind == .movie, item["last_watched_at"] is String || (item["status"] as? String) == "completed" {
                library.plays.append(TraktPlay(historyId: TrackerDecode.playID("simkl|movie|\(ref.tmdbId ?? 0)"), title: ref, watchedAt: item["last_watched_at"] as? String))
            }
            for episode in episodes {
                library.plays.append(TraktPlay(historyId: TrackerDecode.playID("simkl|\(kind)|\(ref.tmdbId ?? 0)|\(episode.season)|\(episode.number)"), title: ref,
                                               season: episode.season, episode: episode.number, watchedAt: episode.at))
            }
            if let rating = number(item["user_rating"]), (1...10).contains(rating), !library.ratings.contains(where: { $0.title.diaryKey == ref.diaryKey }) {
                library.ratings.append(TraktRating(title: ref, rating: rating, ratedAt: item["user_rated_at"] as? String))
            }
            switch item["status"] as? String {
            case "plantowatch" where !library.watchlist.contains(where: { $0.title.diaryKey == ref.diaryKey }):
                library.watchlist.append(TraktListed(title: ref, listedAt: item["added_to_watchlist_at"] as? String))
            case "dropped" where !library.dropped.contains(where: { $0.title.diaryKey == ref.diaryKey }):
                library.dropped.append(TraktListed(title: ref, listedAt: item["added_to_watchlist_at"] as? String))
            default: break
            }
        }
    }
    /// The watched episodes of an all-items row (`seasons[].episodes[]`).
    private static func watched(_ item: [String: Any]) -> [(season: Int, number: Int, at: String?)] {
        var out: [(season: Int, number: Int, at: String?)] = []
        for season in (item["seasons"] as? [[String: Any]]) ?? [] {
            guard let s = number(season["number"]) ?? (season["number"] as? NSNumber)?.intValue else { continue }
            for episode in (season["episodes"] as? [[String: Any]]) ?? [] {
                if let n = number(episode["number"]) { out.append((s, n, episode["watched_at"] as? String)) }
            }
        }
        return out
    }
    /// A whole number from a JSON number or a numeric string (Simkl sends TMDB ids as text); 0 is a season.
    static func number(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue >= 0 ? number.intValue : nil
    }

    /// The diary without what can't be compared with Simkl: anime episodes whose place on Simkl
    /// isn't known yet, or that Simkl lists nowhere, and what Simkl didn't keep. (They go to
    /// Simkl with your edits as before; they just aren't counted as missing.)
    static func comparable(_ workspace: Workspace, placements: [String: SimklPlacement], notKept: Set<String>) -> Workspace {
        let titles = Dictionary(workspace.titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var copy = workspace
        copy.events = workspace.events.filter { event in
            guard let title = titles[event.titleId], let tmdb = title.tmdbId else { return true }
            if !title.isSeries { return !notKept.contains("movie:\(tmdb)") }
            guard let id = event.episodeId, let episode = episodes[id] else { return true }
            let key = "\(tmdb):\(episode.season):\(episode.number)"
            if notKept.contains("show:\(tmdb):\(episode.season):\(episode.number)") { return false }
            guard title.category == "anime" || title.category == "anime-movie" else { return true }
            return placements[key]?.entry != nil
        }
        return copy
    }
}
