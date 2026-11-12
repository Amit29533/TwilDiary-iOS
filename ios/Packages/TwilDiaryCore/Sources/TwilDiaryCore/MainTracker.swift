import Foundation

// Main tracker (ios/docs/TRAKT-CLIENT-PLAN.md, "Choose your main tracker"): the owner picks which
// service is the diary: Trakt, Simkl or MDBList. Each one is read into the same
// `TraktLibrary` model, so the comparison, the cache and (later) the screens are shared. What a
// service can't hold stays in Cloudflare. Read-only for now: nothing here writes anywhere.

public enum MainTracker: String, Codable, CaseIterable, Identifiable, Sendable {
    case trakt, simkl, mdblist, wetrakr
    public var id: String { rawValue }

    /// What the service can hold as the diary. Anything it can't stays in Cloudflare.
    public struct Capabilities: Equatable, Sendable {
        /// Several plays of one movie or episode. Simkl keeps one watch each (rewatches need Simkl PRO/VIP).
        public let keepsRewatches: Bool
        public let holdsDropped: Bool
        public let holdsFavourites: Bool
        /// Longest note the service keeps; nil when it keeps none.
        public let noteLimit: Int?
        /// A cheap "has anything changed?" call, so an unchanged library isn't downloaded again.
        public let changeCheck: Bool
        /// Specials (season 0). MDBList answers "added" but never keeps them, so they're neither
        /// sent there nor counted as missing.
        public var keepsSpecials = true
    }

    public var name: String {
        switch self { case .trakt: "Trakt"; case .simkl: "Simkl"; case .mdblist: "MDBList"; case .wetrakr: "WeTrakr" }
    }

    public var capabilities: Capabilities {
        switch self {
        case .trakt: Capabilities(keepsRewatches: true, holdsDropped: true, holdsFavourites: true, noteLimit: 500, changeCheck: true)
        case .simkl: Capabilities(keepsRewatches: false, holdsDropped: true, holdsFavourites: false, noteLimit: 140, changeCheck: true)
        case .mdblist: Capabilities(keepsRewatches: false, holdsDropped: true, holdsFavourites: false, noteLimit: nil, changeCheck: true, keepsSpecials: false)
        // WeTrakr keeps every play, favourites and dropped titles, and its journal names what changed.
        case .wetrakr: Capabilities(keepsRewatches: true, holdsDropped: true, holdsFavourites: true, noteLimit: nil, changeCheck: true)
        }
    }

    /// One line on what the service keeps, for the picker.
    public var summary: String {
        switch self {
        case .trakt: "History with rewatches, ratings, watchlist, favourites, dropped shows, notes up to 500 characters."
        case .simkl: "History (one watch per episode), ratings, plan to watch, dropped, notes up to 140 characters. Best for anime."
        case .mdblist: "History, ratings, watchlist and dropped. No notes or favourites."
        case .wetrakr: "History with rewatches, ratings, watchlist, favourites and dropped. Notes stay in TwilDiary."
        }
    }

    /// What stays in the Cloudflare backup with this service as the diary (besides what always does:
    /// file locations, tags, people favourites and trash).
    public var keptInCloudflare: [String] {
        let can = capabilities
        var result: [String] = []
        if !can.keepsRewatches { result.append("rewatch counts") }
        if !can.holdsFavourites { result.append("favourite titles") }
        if !can.holdsDropped { result.append("dropped titles") }
        if let limit = can.noteLimit { result.append("the full text of notes over \(limit) characters") } else { result.append("notes") }
        return result
    }
}

/// Simkl and MDBList read into the shared library model. Like `TraktDecode`, an item that can't be
/// identified is skipped and counted, never guessed.
public enum TrackerDecode {
    private static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    /// A positive whole number, from a JSON number or a numeric string (Simkl sends TMDB ids as text).
    static func int(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 && $0 <= 9_999_999_999 ? $0 : nil } }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return Double(integer) == number.doubleValue && integer > 0 && integer <= 9_999_999_999 ? Int(integer) : nil
    }
    private static func date(_ value: Any?) -> String? {
        guard let text = value as? String, text.count >= 10, text.count <= 40, text.contains("T") else { return nil }
        return text
    }
    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(300))
    }
    /// A stable id for a play the service doesn't number itself (FNV-1a of what identifies it).
    public static func playID(_ parts: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return Int64(bitPattern: hash & 0x7fffffffffffffff)
    }
    /// A title from a block with "ids" (or flat id fields), "title" and "year".
    static func ref(_ media: [String: Any], kind: TraktTitleRef.Kind) -> TraktTitleRef? {
        let ids = object(media["ids"]) ?? media
        guard let name = text(media["title"]) ?? text(media["name"]) else { return nil }
        // MDBList list items have no "ids" block: their "id" is the TMDB id.
        let tmdb = int(ids["tmdb"]) ?? int(ids["tmdb_id"]) ?? int(ids["tmdbid"])
            ?? (media["ids"] == nil && media["mediatype"] != nil ? int(media["id"]) : nil)
        let trakt = int(ids["trakt"]) ?? int(ids["trakt_id"])
        let imdb = ((ids["imdb"] ?? ids["imdb_id"]) as? String).flatMap { $0.hasPrefix("tt") && $0.count <= 15 ? $0 : nil }
        guard tmdb != nil || trakt != nil || imdb != nil || int(ids["simkl"]) != nil || int(ids["mdblist"]) != nil else { return nil }
        return TraktTitleRef(kind: kind, traktId: trakt, tmdbId: tmdb, imdbId: imdb, tvdbId: int(ids["tvdb"]) ?? int(ids["tvdb_id"]),
                             name: name, year: int(media["year"]) ?? int(media["release_year"]), simklId: int(ids["simkl"]) ?? int(ids["simkl_id"]))
    }

    // MARK: Simkl

    /// `GET /sync/all-items/?extended=full&episode_watched_at=yes&memos=yes&include_all_episodes=yes`:
    /// movies, shows and anime with their status, rating, memo and watched episodes.
    public static func simklLibrary(from data: Data) throws -> TraktLibrary {
        let parsed = try JSONSerialization.jsonObject(with: data)
        // An empty library is `{}` (or, from some clients, `null`).
        guard let root = parsed as? [String: Any] else {
            if parsed is NSNull { return TraktLibrary() }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Simkl returned something other than a library."))
        }
        var library = TraktLibrary()
        for bucket in ["movies", "shows", "anime"] {
            for case let item as [String: Any] in (root[bucket] as? [Any]) ?? [] {
                let block = object(item["movie"]) ?? object(item["show"])
                let movie = item["movie"] != nil || (item["anime_type"] as? String)?.lowercased() == "movie"
                guard let block, let title = ref(block, kind: movie ? .movie : .show) else { library.skipped += 1; continue }
                let status = (item["status"] as? String)?.lowercased()
                if status == "plantowatch" { library.watchlist.append(TraktListed(title: title, listedAt: date(item["added_to_watchlist_at"]))) }
                if status == "dropped" { library.dropped.append(TraktListed(title: title, listedAt: date(item["last_watched_at"]))) }
                if let rating = int(item["user_rating"]), (1...10).contains(rating) {
                    library.ratings.append(TraktRating(title: title, rating: rating, ratedAt: date(item["user_rated_at"])))
                }
                if let memo = object(item["memo"]), let note = text(memo["text"]) {
                    library.notes.append(TraktNote(id: playID("simkl-note|\(title.name)|\(title.tmdbId ?? 0)"), title: title, text: note, updatedAt: nil))
                }
                if movie {
                    // One watch per movie (Simkl keeps rewatches only for PRO/VIP accounts).
                    if status == "completed" || date(item["last_watched_at"]) != nil, status != "plantowatch" {
                        let watched = date(item["last_watched_at"])
                        library.plays.append(TraktPlay(historyId: playID("simkl|m|\(title.tmdbId ?? 0)|\(title.name)"), title: title, watchedAt: watched))
                    }
                    continue
                }
                // Anime: Simkl files each season as its own entry numbered from season 1. With
                // `extended=full_anime_seasons` each episode says where it is in TVDB's numbering
                // (closest to TMDB's), and the entry which TVDB seasons it covers.
                let mapped = ((item["mapped_tvdb_seasons"] as? [Any]) ?? []).compactMap { int($0) }
                for case let season as [String: Any] in (item["seasons"] as? [Any]) ?? [] {
                    for case let episode as [String: Any] in (season["episodes"] as? [Any]) ?? [] {
                        let tvdb = object(episode["tvdb"])
                        guard let number = int(tvdb?["episode"]) ?? int(episode["number"]) else { library.skipped += 1; continue }
                        // An episode without its own mapping, in an entry that covers one TVDB season: that season.
                        let seasonNumber = tvdb.flatMap { int($0["season"]) } ?? (mapped.count == 1 ? mapped[0] : nil) ?? int(season["number"]) ?? 1
                        let watched = date(episode["watched_at"])
                        library.plays.append(TraktPlay(historyId: playID("simkl|e|\(title.tmdbId ?? 0)|\(title.name)|\(seasonNumber)|\(number)"),
                                                       title: title, season: seasonNumber, episode: number, watchedAt: watched))
                    }
                }
            }
        }
        return library
    }

    /// Every title's Simkl id in an all-items reply (any `extended`, including `simkl_ids_only`:
    /// `{"shows":[{"show":{"ids":{"simkl":297}}}]}`). An entry without one throws, so a reply that
    /// can't be read in full never makes titles look removed.
    public static func simklIDs(from data: Data) throws -> Set<Int> {
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let root = parsed as? [String: Any] else {
            if parsed is NSNull || (parsed as? [Any])?.isEmpty == true { return [] }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Simkl returned something other than a library."))
        }
        var ids = Set<Int>()
        for bucket in ["movies", "shows", "anime"] {
            for case let item as [String: Any] in (root[bucket] as? [Any]) ?? [] {
                let block = object(item["movie"]) ?? object(item["show"]) ?? item
                guard let id = int(object(block["ids"])?["simkl"]) ?? int(object(item["ids"])?["simkl"]) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A Simkl item had no Simkl id."))
                }
                ids.insert(id)
            }
        }
        return ids
    }

    /// `GET /sync/ratings/{type}`: the rated titles (buckets like all-items, or a plain list).
    public static func simklRatings(from data: Data) throws -> [TraktRating] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        var entries: [Any] = []
        if let root = parsed as? [String: Any] {
            for bucket in ["movies", "shows", "anime"] { entries += (root[bucket] as? [Any]) ?? [] }
        } else if let list = parsed as? [Any] {
            entries = list
        } else if !(parsed is NSNull) {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Simkl returned something other than ratings."))
        }
        var ratings: [TraktRating] = []
        for case let item as [String: Any] in entries {
            let movie = item["movie"] != nil || (item["anime_type"] as? String)?.lowercased() == "movie"
            guard let block = object(item["movie"]) ?? object(item["show"]), let title = ref(block, kind: movie ? .movie : .show),
                  let rating = int(item["user_rating"]), (1...10).contains(rating) else { continue }
            ratings.append(TraktRating(title: title, rating: rating, ratedAt: date(item["user_rated_at"])))
        }
        return ratings
    }

    // MARK: MDBList

    /// The MDBList lists to read again, from what moved in `/sync/last_activities`; nil means all
    /// of them (first read, or a field TwilDiary doesn't recognise moved).
    public static func mdblistListsToRead(previous: TraktActivities?, now: TraktActivities) -> Set<TraktDomain>? {
        guard let previous else { return nil }
        var lists = Set<TraktDomain>()
        for key in Set(now.stamps.keys).union(previous.stamps.keys) where now.stamps[key] != previous.stamps[key] {
            let name = key.lowercased()
            // Removals show only in the journal's stamp: watches and ratings come from the journal.
            if name == "journal_at" { lists.formUnion([.history, .ratings]); continue }
            // Collection, paused, lists and comments aren't read into the diary.
            if ["collected_at", "paused_at", "episode_paused_at", "list_updated_at", "external_lists_updated_at",
                "liked_lists_updated_at", "commented_at", "journal.since"].contains(name) { continue }
            if name.contains("watchlist") { lists.insert(.watchlist) }
            else if name.contains("rat") { lists.insert(.ratings) }
            else if name.contains("drop") || name.contains("hidden") { lists.insert(.dropped) }
            else if name.contains("watch") { lists.insert(.history) }
            else { return nil }
        }
        return lists
    }

    /// `GET /sync/last_activities` on MDBList is flat ("watched_at", "rated_at", …), unlike Trakt's
    /// sections; `server_time` changes on every call, so it's left out.
    public static func flatActivities(from data: Data) throws -> TraktActivities {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Last activities were not an object."))
        }
        var stamps: [String: String] = [:]
        for (key, value) in root where key != "server_time" { if let stamp = value as? String { stamps[key] = stamp } }
        return TraktActivities(all: nil, stamps: stamps)
    }

    /// One page of an MDBList sync list (`/sync/watched`, `/sync/ratings`, `/sync/dropped`,
    /// `/watchlist/items`). MDBList doesn't publish its response format outside the browser, so this
    /// reads both Trakt-style items ({"movie": {...}} / {"show": {...}, "episode": {...}}) and flat
    /// ones ({"title", "ids", "mediatype"}), under a top-level list or any of the usual keys.
    public struct MDBListPage: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let title: TraktTitleRef
            public let season: Int?
            public let episode: Int?
            public let date: String?
            public let rating: Int?
        }
        public var items: [Item] = []
        public var skipped = 0
        /// The cursor for the next page; nil on the last page.
        public var next: String?
    }

    public static func mdblistPage(from data: Data) throws -> MDBListPage {
        let parsed = try JSONSerialization.jsonObject(with: data)
        var page = MDBListPage()
        var entries: [(Any, TraktTitleRef.Kind?)] = []
        if let list = parsed as? [Any] { entries = list.map { ($0, nil) } }
        else if let root = parsed as? [String: Any] {
            for (key, kind) in [("movies", TraktTitleRef.Kind.movie), ("shows", .show), ("episodes", .show), ("seasons", .show)] {
                for value in (root[key] as? [Any]) ?? [] { entries.append((value, kind)) }
            }
            for key in ["items", "results", "data", "watched", "ratings", "dropped", "watchlist"] {
                for value in (root[key] as? [Any]) ?? [] { entries.append((value, nil)) }
            }
            let pagination = object(root["pagination"]) ?? object(root["cursor"])
            page.next = text(root["next_cursor"]) ?? text(pagination?["next_cursor"]) ?? text(pagination?["next"])
            if root["has_more"] as? Bool == false { page.next = nil }
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "MDBList returned something unexpected."))
        }
        for (value, bucketKind) in entries {
            guard let item = value as? [String: Any] else { page.skipped += 1; continue }
            // MDBList's watched episodes carry their show inside the episode ("episode.show").
            let movieBlock = object(item["movie"]), showBlock = object(item["show"]) ?? object(object(item["episode"])?["show"])
            let type = ((item["mediatype"] ?? item["type"] ?? item["media_type"]) as? String)?.lowercased()
            let kind: TraktTitleRef.Kind = movieBlock != nil ? .movie : showBlock != nil ? .show
                : type == "movie" ? .movie : (type == "show" || type == "tv" || type == "episode" || type == "season") ? .show : bucketKind ?? .movie
            guard let title = ref(movieBlock ?? showBlock ?? item, kind: kind) else { page.skipped += 1; continue }
            // Trakt-style watched shows: seasons[].episodes[] inside the show.
            if kind == .show, let seasons = item["seasons"] as? [Any], !seasons.isEmpty {
                for case let season as [String: Any] in seasons {
                    for case let episode as [String: Any] in (season["episodes"] as? [Any]) ?? [] {
                        guard let seasonNumber = int(season["number"]) ?? (season["number"] as? NSNumber)?.intValue,
                              let number = int(episode["number"]) else { page.skipped += 1; continue }
                        page.items.append(.init(title: title, season: seasonNumber, episode: number,
                                                date: date(episode["last_watched_at"]) ?? date(episode["watched_at"]), rating: nil))
                    }
                }
                continue
            }
            let episode = object(item["episode"])
            let season = int(episode?["season"]) ?? int(item["season"]) ?? int(object(item["season"])?["number"])
            let number = int(episode?["number"]) ?? int(episode?["episode"]) ?? int(item["episode"]) ?? int(item["episode_number"])
            let rating = int(item["rating"]) ?? int(item["user_rating"])
            let stamp = date(item["watched_at"]) ?? date(item["last_watched_at"]) ?? date(item["rated_at"]) ?? date(item["listed_at"]) ?? date(item["dropped_at"]) ?? date(item["added_at"])
            page.items.append(.init(title: title, season: kind == .show ? season : nil, episode: kind == .show ? number : nil,
                                    date: stamp, rating: rating.flatMap { (1...10).contains($0) ? $0 : nil }))
        }
        return page
    }
}

// MARK: MDBList's journal

/// `GET /sync/journal` (MDBList's published schema): the latest retained state per item for
/// watched and ratings, removals included, 30 days back. Rows are applied as the current truth;
/// season and show rows are skipped (episode rows carry each episode's own state).
public enum MDBListJournal {
    public struct Result: Equatable, Sendable {
        public var applied = 0
        /// The window expired (`requires_full_sync`): read the lists in full.
        public var needsFullRead = false
        public var nextCursor: String?
        /// The server's clock for this read: the next `since`.
        public var serverTime: String?
    }
    /// Saved activities without the journal mark kept among them (for "did anything move?").
    public static func unmarked(_ activities: TraktActivities?) -> TraktActivities? {
        activities.map { TraktActivities(all: $0.all, stamps: $0.stamps.filter { $0.key != "journal.since" }) }
    }
    public static func apply(_ data: Data, to library: inout TraktLibrary) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "MDBList sent an unreadable journal."))
        }
        var result = Result(serverTime: root["server_time"] as? String)
        if root["requires_full_sync"] as? Bool == true { result.needsFullRead = true; return result }
        let pagination = root["pagination"] as? [String: Any]
        if pagination?["has_more"] as? Bool == true { result.nextCursor = pagination?["next_cursor"] as? String }
        for row in root["journal"] as? [[String: Any]] ?? [] {
            let ids = row["ids"] as? [String: Any] ?? [:]
            guard let tmdb = TrackerDecode.int(ids["tmdb"]) else { continue }
            let type = row["item_type"] as? String, added = row["status"] as? String == "added"
            let kind: TraktTitleRef.Kind = type == "movie" ? .movie : .show
            let title = TraktTitleRef(kind: kind, traktId: nil, tmdbId: tmdb, imdbId: ids["imdb"] as? String, tvdbId: TrackerDecode.int(ids["tvdb"]), name: "")
            let season = (row["season"] as? NSNumber)?.intValue, episode = (row["episode"] as? NSNumber)?.intValue
            func same(_ other: TraktTitleRef) -> Bool { other.kind == kind && other.tmdbId == tmdb }
            switch row["category"] as? String {
            case "watched":
                guard type == "movie" || type == "episode" else { continue }
                if type == "episode", season == nil || episode == nil { continue }
                library.plays.removeAll { same($0.title) && $0.season == season && $0.episode == episode }
                if added {
                    let id = TrackerDecode.playID("mdblist|\(kind.rawValue)|\(tmdb)|\(season ?? -1)|\(episode ?? -1)")
                    library.plays.append(TraktPlay(historyId: id, title: title, season: season, episode: episode, watchedAt: row["value_at"] as? String))
                }
                result.applied += 1
            case "rated":
                guard type == "movie" || type == "show" else { continue }
                library.ratings.removeAll { same($0.title) }
                if added, let rating = TrackerDecode.int(row["rating"]), (1...10).contains(rating) {
                    library.ratings.append(TraktRating(title: title, rating: rating, ratedAt: row["value_at"] as? String))
                }
                result.applied += 1
            default: continue
            }
        }
        return result
    }
}
