import Foundation

// Trakt-first plan, phase 1 (ios/docs/TRAKT-CLIENT-PLAN.md): the owner's Trakt data as the app
// reads it directly from Trakt, and a shadow comparison with the current diary. Nothing here
// writes to Trakt or changes the diary.

/// A movie or show as Trakt identifies it.
public struct TraktTitleRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case movie, show }
    public let kind: Kind
    public let traktId: Int?
    public let tmdbId: Int?
    public let imdbId: String?
    public let tvdbId: Int?
    public let name: String
    public let year: Int?
    /// WeTrakr's own id (WeTrakr reads only): how its journal names titles.
    public let weTrakrId: Int?
    public init(kind: Kind, traktId: Int?, tmdbId: Int?, imdbId: String? = nil, tvdbId: Int? = nil, name: String, year: Int? = nil, weTrakrId: Int? = nil) {
        self.kind = kind; self.traktId = traktId; self.tmdbId = tmdbId; self.imdbId = imdbId; self.tvdbId = tvdbId; self.name = name; self.year = year
        self.weTrakrId = weTrakrId
    }
    /// "movie:603" or "tv:1399", as the diary matches titles; nil without a TMDB id.
    public var diaryKey: String? { tmdbId.map { (kind == .movie ? "movie:" : "tv:") + String($0) } }
}

/// One play in Trakt's history: its own history id, so a later Undo removes exactly this play.
public struct TraktPlay: Codable, Hashable, Sendable {
    /// A movie, or one episode. MDBList's watched list also has show and season rows (a show or
    /// season it counts as finished); they aren't plays and can't be taken off one by one.
    public var isMovieOrEpisode: Bool { title.kind == .movie || (season != nil && episode != nil) }
    public let historyId: Int64
    public let title: TraktTitleRef
    public let season: Int?
    public let episode: Int?
    /// ISO 8601 from Trakt; nil when Trakt has no date.
    public let watchedAt: String?
    /// The service's own id for this play when it isn't a number (WeTrakr's play_id).
    public let remoteId: String?
    public init(historyId: Int64, title: TraktTitleRef, season: Int? = nil, episode: Int? = nil, watchedAt: String?, remoteId: String? = nil) {
        self.historyId = historyId; self.title = title; self.season = season; self.episode = episode; self.watchedAt = watchedAt
        self.remoteId = remoteId
    }
}

public struct TraktRating: Codable, Hashable, Sendable {
    public let title: TraktTitleRef
    public let rating: Int
    public let ratedAt: String?
    public init(title: TraktTitleRef, rating: Int, ratedAt: String?) { self.title = title; self.rating = rating; self.ratedAt = ratedAt }
}

/// A watchlist, favourite or dropped entry.
public struct TraktListed: Codable, Hashable, Sendable {
    public let title: TraktTitleRef
    public let listedAt: String?
    public init(title: TraktTitleRef, listedAt: String?) { self.title = title; self.listedAt = listedAt }
}

public struct TraktNote: Codable, Hashable, Sendable {
    public let id: Int64
    public let title: TraktTitleRef?
    public let text: String
    public let updatedAt: String?
    public init(id: Int64, title: TraktTitleRef?, text: String, updatedAt: String?) { self.id = id; self.title = title; self.text = text; self.updatedAt = updatedAt }
}

/// The lists the app reads from Trakt; each is fetched only when its activity time changed.
public enum TraktDomain: String, Codable, CaseIterable, Sendable {
    case history, ratings, watchlist, favorites, dropped, notes
    /// The `/sync/last_activities` fields ("section.field") that move when this list changes.
    public var activityKeys: [String] {
        switch self {
        case .history: ["movies.watched_at", "episodes.watched_at"]
        case .ratings: ["movies.rated_at", "shows.rated_at"]
        case .watchlist: ["movies.watchlisted_at", "shows.watchlisted_at"]
        case .favorites: ["movies.favorited_at", "shows.favorited_at"]
        case .dropped: ["shows.dropped_at", "shows.hidden_at"]
        case .notes: ["notes.updated_at"]
        }
    }
}

/// Every timestamp `/sync/last_activities` returned, flattened to "section.field". Unknown or
/// new Trakt fields are kept, so a list whose fields Trakt doesn't report still refreshes
/// whenever anything changed ("all").
public struct TraktActivities: Codable, Equatable, Sendable {
    public let all: String?
    public let stamps: [String: String]
    public init(all: String?, stamps: [String: String]) { self.all = all; self.stamps = stamps }

    /// Lists to fetch, given the activities saved with the last complete read.
    public func changed(since previous: TraktActivities?) -> Set<TraktDomain> {
        guard let previous else { return Set(TraktDomain.allCases) }
        if let all, all == previous.all { return [] }
        var result = Set<TraktDomain>()
        for domain in TraktDomain.allCases {
            let reported = domain.activityKeys.filter { stamps[$0] != nil || previous.stamps[$0] != nil }
            if reported.isEmpty || reported.contains(where: { stamps[$0] != previous.stamps[$0] }) { result.insert(domain) }
        }
        return result
    }
}

/// The owner's Trakt data, as last read.
public struct TraktLibrary: Codable, Equatable, Sendable {
    public var activities: TraktActivities?
    public var plays: [TraktPlay]
    public var ratings: [TraktRating]
    public var watchlist: [TraktListed]
    public var favorites: [TraktListed]
    public var dropped: [TraktListed]
    public var notes: [TraktNote]
    /// Items Trakt returned that could not be read (missing ids, bad dates); counted, not guessed.
    public var skipped: Int
    public var fetchedAt: String?
    public init(activities: TraktActivities? = nil, plays: [TraktPlay] = [], ratings: [TraktRating] = [], watchlist: [TraktListed] = [],
                favorites: [TraktListed] = [], dropped: [TraktListed] = [], notes: [TraktNote] = [], skipped: Int = 0, fetchedAt: String? = nil) {
        self.activities = activities; self.plays = plays; self.ratings = ratings; self.watchlist = watchlist
        self.favorites = favorites; self.dropped = dropped; self.notes = notes; self.skipped = skipped; self.fetchedAt = fetchedAt
    }
}

extension TraktLibrary {
    /// The same library with a name for every title that came without one (WeTrakr's compact
    /// lists carry ids only): `lookup` gives it from the diary or the phone's TMDB catalog.
    public func naming(_ lookup: (TraktTitleRef) -> String?) -> TraktLibrary {
        func named(_ ref: TraktTitleRef) -> TraktTitleRef {
            guard ref.name.trimmingCharacters(in: .whitespaces).isEmpty, let name = lookup(ref), !name.isEmpty else { return ref }
            return TraktTitleRef(kind: ref.kind, traktId: ref.traktId, tmdbId: ref.tmdbId, imdbId: ref.imdbId, tvdbId: ref.tvdbId,
                                 name: name, year: ref.year, weTrakrId: ref.weTrakrId)
        }
        var copy = self
        copy.plays = plays.map { TraktPlay(historyId: $0.historyId, title: named($0.title), season: $0.season, episode: $0.episode, watchedAt: $0.watchedAt, remoteId: $0.remoteId) }
        copy.ratings = ratings.map { TraktRating(title: named($0.title), rating: $0.rating, ratedAt: $0.ratedAt) }
        copy.watchlist = watchlist.map { TraktListed(title: named($0.title), listedAt: $0.listedAt) }
        copy.favorites = favorites.map { TraktListed(title: named($0.title), listedAt: $0.listedAt) }
        copy.dropped = dropped.map { TraktListed(title: named($0.title), listedAt: $0.listedAt) }
        return copy
    }
}

/// Reads Trakt's JSON defensively: an item that can't be identified is skipped and counted, so
/// one odd entry never hides the rest of a list.
public enum TraktDecode {
    private static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func array(_ data: Data) throws -> [Any] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Trakt returned something other than a list.")) }
        return list
    }
    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return Double(integer) == number.doubleValue && integer > 0 && integer <= 9_999_999_999 ? Int(integer) : nil
    }
    private static func date(_ value: Any?) -> String? {
        guard let text = value as? String, text.count >= 10, text.count <= 40, text.contains("T") else { return nil }
        return text
    }
    /// The movie or show inside an item ("movie" or "show" key), with its ids and name.
    static func ref(_ item: [String: Any], prefer kind: TraktTitleRef.Kind? = nil) -> TraktTitleRef? {
        let pick: TraktTitleRef.Kind
        if let kind { pick = kind }
        else if item["movie"] != nil { pick = .movie }
        else if item["show"] != nil { pick = .show }
        else { return nil }
        guard let media = object(item[pick == .movie ? "movie" : "show"]), let ids = object(media["ids"]) else { return nil }
        let name = (media["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trakt = int(ids["trakt"]), tmdb = int(ids["tmdb"])
        guard !name.isEmpty, trakt != nil || tmdb != nil else { return nil }
        let imdb = (ids["imdb"] as? String).flatMap { $0.hasPrefix("tt") && $0.count <= 15 ? $0 : nil }
        return TraktTitleRef(kind: pick, traktId: trakt, tmdbId: tmdb, imdbId: imdb, tvdbId: int(ids["tvdb"]), name: String(name.prefix(300)), year: int(media["year"]))
    }

    public static func activities(from data: Data) throws -> TraktActivities {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Trakt last activities were not an object."))
        }
        var stamps: [String: String] = [:]
        for (section, value) in root {
            guard let fields = object(value) else { continue }
            for (field, stamp) in fields { if let stamp = stamp as? String { stamps[section + "." + field] = stamp } }
        }
        return TraktActivities(all: root["all"] as? String, stamps: stamps)
    }

    /// `GET /sync/history` pages: movie and episode plays.
    public static func history(from data: Data) throws -> (items: [TraktPlay], skipped: Int) {
        var items: [TraktPlay] = [], skipped = 0
        for raw in try array(data) {
            guard let item = object(raw), let id = (item["id"] as? NSNumber)?.int64Value, id > 0 else { skipped += 1; continue }
            switch item["type"] as? String {
            case "movie":
                guard let title = ref(item, prefer: .movie) else { skipped += 1; continue }
                items.append(TraktPlay(historyId: id, title: title, watchedAt: date(item["watched_at"])))
            case "episode":
                guard let title = ref(item, prefer: .show), let episode = object(item["episode"]),
                      let season = (episode["season"] as? NSNumber)?.intValue, season >= 0, season <= 999,
                      let number = int(episode["number"]), number <= 5000 else { skipped += 1; continue }
                items.append(TraktPlay(historyId: id, title: title, season: season, episode: number, watchedAt: date(item["watched_at"])))
            default:
                skipped += 1
            }
        }
        return (items, skipped)
    }

    /// `GET /sync/ratings/movies` or `/shows`.
    public static func ratings(from data: Data) throws -> (items: [TraktRating], skipped: Int) {
        var items: [TraktRating] = [], skipped = 0
        for raw in try array(data) {
            guard let item = object(raw), let title = ref(item), let rating = int(item["rating"]), rating <= 10 else { skipped += 1; continue }
            items.append(TraktRating(title: title, rating: rating, ratedAt: date(item["rated_at"])))
        }
        return (items, skipped)
    }

    /// Watchlist and favourites (`listed_at`) and dropped shows (`hidden_at`); seasons and
    /// episodes in a list are left out, as the diary lists only movies and shows.
    public static func listed(from data: Data) throws -> (items: [TraktListed], skipped: Int) {
        var items: [TraktListed] = [], skipped = 0
        for raw in try array(data) {
            guard let item = object(raw) else { skipped += 1; continue }
            if let type = item["type"] as? String, type != "movie", type != "show" { continue }
            guard let title = ref(item) else { skipped += 1; continue }
            items.append(TraktListed(title: title, listedAt: date(item["listed_at"]) ?? date(item["hidden_at"])))
        }
        return (items, skipped)
    }

    /// `GET /users/me/notes`: the note text may sit under "note" or at the top level.
    public static func notes(from data: Data) throws -> (items: [TraktNote], skipped: Int) {
        var items: [TraktNote] = [], skipped = 0
        for raw in try array(data) {
            guard let item = object(raw) else { skipped += 1; continue }
            let note = object(item["note"]) ?? item
            guard let id = (note["id"] as? NSNumber)?.int64Value, let text = note["notes"] as? String ?? note["text"] as? String else { skipped += 1; continue }
            items.append(TraktNote(id: id, title: ref(item), text: String(text.prefix(500)), updatedAt: date(note["updated_at"]) ?? date(note["created_at"])))
        }
        return (items, skipped)
    }
}

/// How the Trakt library compares with the current diary: shadow mode before Trakt becomes the
/// diary. Counts plus a few examples of each difference.
public struct TraktComparison: Equatable, Sendable {
    public struct Difference: Equatable, Sendable {
        public let title: String
        public let detail: String
    }
    public var matchingPlays = 0
    public var onlyOnTrakt: [Difference] = []
    public var onlyInDiary: [Difference] = []
    public var ratingDifferences: [Difference] = []
    public var plannedDifferences: [Difference] = []
    public var favoriteDifferences: [Difference] = []
    public var droppedDifferences: [Difference] = []
    /// Trakt titles without a TMDB id, which the diary cannot match.
    public var unmatchedTraktTitles = 0
    /// Titles shown by their key ("movie:100068"): neither side gave a name (WeTrakr sends none for
    /// some), so the caller can look them up and pass them in `names` next time.
    public var unnamedKeys: Set<String> = []
    public var matches: Bool {
        onlyOnTrakt.isEmpty && onlyInDiary.isEmpty && ratingDifferences.isEmpty && plannedDifferences.isEmpty
            && favoriteDifferences.isEmpty && droppedDifferences.isEmpty
    }

    /// `tracker` names the service in the details and skips what it can't hold: with no rewatches,
    /// "watched at least once" is compared; without favourites or dropped, those stay in Cloudflare.
    ///
    /// `oneWay`: the service holds the diary and `workspace` is the old server copy, so only what
    /// that copy has and the service lacks altogether is a difference (the same rules as
    /// `TraktWritePlan.make(fillOnly:)`, skipping `except`); anything newer on the service is the diary.
    public static func compare(_ library: TraktLibrary, with workspace: Workspace, tracker: MainTracker = .trakt,
                               oneWay: Bool = false, except: Set<String> = [], names: [String: String] = [:]) -> TraktComparison {
        var result = TraktComparison()
        let service = tracker.name, can = tracker.capabilities
        let titles = workspace.activeTitles
        var byKey: [String: MediaTitle] = [:]
        for title in titles { if let tmdb = title.tmdbId { byKey[(title.isSeries ? "tv:" : "movie:") + String(tmdb)] = byKey[(title.isSeries ? "tv:" : "movie:") + String(tmdb)] ?? title } }
        let titleKey = Dictionary(titles.compactMap { title in title.tmdbId.map { (title.id, (title.isSeries ? "tv:" : "movie:") + String($0)) } }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func name(_ key: String) -> String { byKey[key]?.name ?? key }
        /// The diary's name for a title, else the service's (WeTrakr sometimes sends none), else one
        /// looked up (`names`), else its key.
        func label(_ key: String, _ service: String) -> String {
            if let known = byKey[key]?.name, !known.isEmpty { return known }
            if !service.isEmpty { return service }
            if let looked = names[key], !looked.isEmpty { return looked }
            result.unnamedKeys.insert(key)
            return key
        }

        // Plays: how many times each movie or episode was watched, on each side.
        func playKey(_ title: String, _ season: Int?, _ episode: Int?) -> String {
            season.map { title + "|s\($0)e\(episode ?? 0)" } ?? title
        }
        var trakt: [String: Int] = [:], diary: [String: Int] = [:], labels: [String: String] = [:]
        for play in library.plays {
            guard let key = play.title.diaryKey else { continue }
            if play.season == 0, !can.keepsSpecials { continue }
            let full = playKey(key, play.season, play.episode)
            trakt[full, default: 0] += 1
            let named = label(key, play.title.name)
            labels[full] = play.season.map { "\(named) S\($0)E\(play.episode ?? 0)" } ?? named
        }
        for event in workspace.activeEvents {
            guard let key = titleKey[event.titleId] else { continue }
            let episode = event.episodeId.flatMap { episodes[$0] }
            if episode?.season == 0, !can.keepsSpecials { continue }
            let full = playKey(key, episode?.season, episode?.number)
            diary[full, default: 0] += 1
            if labels[full] == nil { labels[full] = episode.map { "\(name(key)) S\($0.season)E\($0.number)" } ?? name(key) }
        }
        for key in Set(trakt.keys).union(diary.keys).sorted() {
            let cap = can.keepsRewatches ? Int.max : 1
            let onTrakt = min(trakt[key] ?? 0, cap), inDiary = min(diary[key] ?? 0, cap)
            result.matchingPlays += min(onTrakt, inDiary)
            // What was already tried and didn't stick (the ledger) isn't a difference to act on.
            if except.contains("play|" + key) { continue }
            if onTrakt > inDiary && !oneWay { result.onlyOnTrakt.append(Difference(title: labels[key] ?? key, detail: "\(onTrakt) on \(service), \(inDiary) in the diary")) }
            if inDiary > onTrakt { result.onlyInDiary.append(Difference(title: labels[key] ?? key, detail: "\(inDiary) in the diary, \(onTrakt) on \(service)")) }
        }

        // Title facts: ratings, Planned = watchlist, favourites, Dropped.
        result.unmatchedTraktTitles = Set((library.plays.map(\.title) + library.ratings.map(\.title) + library.watchlist.map(\.title)).filter { $0.tmdbId == nil }).count
        let ratings = Dictionary(library.ratings.compactMap { rating in rating.title.diaryKey.map { ($0, rating.rating) } }, uniquingKeysWith: { first, _ in first })
        func keys(_ list: [TraktListed]) -> Set<String> { Set(list.compactMap(\.title.diaryKey)) }
        let watchlist = keys(library.watchlist), favorites = keys(library.favorites), dropped = keys(library.dropped)
        let played = Set(library.plays.compactMap(\.title.diaryKey))
        if oneWay {
            for (key, title) in byKey.sorted(by: { $0.key < $1.key }) {
                if let score = title.score, score.isFinite, (1...10).contains(score), ratings[key] == nil, !except.contains("rating|" + key) {
                    result.ratingDifferences.append(Difference(title: title.name, detail: "rated \(Int(score.rounded())) in your old copy, not rated on \(service)"))
                }
                if title.status == "planned", !watchlist.contains(key), !played.contains(key), !except.contains("planned|" + key) {
                    result.plannedDifferences.append(Difference(title: title.name, detail: "Planned in your old copy, not on the \(service) watchlist"))
                }
                if can.holdsFavourites, title.favorite, !favorites.contains(key), !except.contains("favourite|" + key) {
                    result.favoriteDifferences.append(Difference(title: title.name, detail: "a favourite in your old copy, not on \(service)"))
                }
                if can.holdsDropped, title.status == "dropped", title.isSeries, !dropped.contains(key), !except.contains("dropped|" + key) {
                    result.droppedDifferences.append(Difference(title: title.name, detail: "dropped in your old copy, not on \(service)"))
                }
            }
            return result
        }
        for key in Set(byKey.keys).union(ratings.keys).union(watchlist).union(favorites).union(dropped).sorted() {
            let title = byKey[key]
            let listedName = (library.watchlist + library.favorites + library.dropped).first { $0.title.diaryKey == key }?.title.name
            let ratedName = library.ratings.first { $0.title.diaryKey == key }?.title.name
            let label: String = [title?.name, ratedName, listedName, names[key]].compactMap { $0 }.first { !$0.isEmpty } ?? {
                result.unnamedKeys.insert(key); return key
            }()
            let score = title?.score.map { Int($0.rounded()) }
            if score != ratings[key], !except.contains("rating|" + key) {
                result.ratingDifferences.append(Difference(title: label, detail: "diary \(score.map(String.init) ?? "none"), \(service) \(ratings[key].map(String.init) ?? "none")"))
            }
            if (title?.status == "planned") != watchlist.contains(key), !except.contains("planned|" + key) {
                result.plannedDifferences.append(Difference(title: label, detail: watchlist.contains(key) ? "on the \(service) watchlist, not Planned in the diary" : "Planned in the diary, not on the \(service) watchlist"))
            }
            if can.holdsFavourites, (title?.favorite == true) != favorites.contains(key) {
                result.favoriteDifferences.append(Difference(title: label, detail: favorites.contains(key) ? "a \(service) favourite, not in the diary" : "a diary favourite, not on \(service)"))
            }
            if can.holdsDropped, (title?.status == "dropped") != dropped.contains(key), !except.contains("dropped|" + key) {
                result.droppedDifferences.append(Difference(title: label, detail: dropped.contains(key) ? "dropped on \(service), not in the diary" : "dropped in the diary, not on \(service)"))
            }
        }
        return result
    }
}
