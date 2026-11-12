import Foundation

/// Force Match: one side (the target) is made exactly like the other (the source of truth), both ways
/// of a difference: what the source has and the target lacks is sent (`send`, the usual match plan),
/// and what the target has that the source doesn't is taken off it.
///
/// Only within what both sides can hold: when either keeps one watch per episode, rewatches are never
/// taken off; when either drops specials, specials are left alone; favourites and dropped only when
/// both keep them. A title whose episodes are missing on one side and extra on the other is left as
/// it is (no episodes sent, none taken off): the two services number its episodes differently
/// (anime seasons), and removing the "extra" episodes would take off the very watches just sent.
public struct ForceMatchPlan: Equatable, Sendable {
    /// A title on the target, by the ids the target itself gave it.
    public struct Item: Hashable, Sendable {
        public let movie: Bool
        public let tmdbId: Int
        public let simklId: Int?
        public let imdbId: String?
        public let name: String
        init(_ ref: TraktTitleRef, tmdb: Int) {
            movie = ref.kind == .movie; tmdbId = tmdb; simklId = ref.simklId; imdbId = ref.imdbId; name = ref.name
        }
    }
    /// One play to take off the target.
    public struct PlayRemoval: Hashable, Sendable {
        public let title: Item
        public let season: Int?
        public let episode: Int?
        public let watchedAt: String?
        /// Trakt's history id.
        public let historyId: Int64
        /// WeTrakr's play_id.
        public let remoteId: String?
    }
    /// One call: a POST with a body, or (WeTrakr's single play) a DELETE.
    public struct Request: Equatable, Sendable {
        public let method: String
        public let path: String
        public let body: Data?
        public let summary: String
        public let count: Int

        /// A refused call of several titles in two halves, so one title the service won't take
        /// doesn't hold back the rest; nil when it names a single title (or isn't a JSON body).
        public func halves() -> [Request]? {
            guard method == "POST", let body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
            func request(_ value: [String: Any], _ share: Int, of total: Int) -> Request? {
                guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
                return Request(method: method, path: path, body: data, summary: summary, count: max(1, count * share / max(1, total)))
            }
            if let ids = root["ids"] as? [Any] {
                guard ids.count > 1 else { return nil }
                let middle = ids.count / 2
                var first = root, second = root
                first["ids"] = Array(ids[..<middle]); second["ids"] = Array(ids[middle...])
                return [request(first, middle, of: ids.count), request(second, ids.count - middle, of: ids.count)].compactMap { $0 }
            }
            let items: [(slot: String, item: Any)] = ["movies", "shows"].flatMap { slot in ((root[slot] as? [Any]) ?? []).map { (slot, $0) } }
            guard items.count > 1 else { return nil }
            let middle = items.count / 2
            func half(_ part: ArraySlice<(slot: String, item: Any)>) -> [String: Any] {
                var value = root
                for slot in ["movies", "shows"] where root[slot] != nil { value[slot] = part.filter { $0.slot == slot }.map(\.item) }
                return value
            }
            return [request(half(items[..<middle]), middle, of: items.count), request(half(items[middle...]), items.count - middle, of: items.count)].compactMap { $0 }
        }
    }

    public init() {}
    public var tracker: MainTracker = .trakt
    /// What the target lacks, sent as a match always is.
    public var send = TraktWritePlan()
    public var plays: [PlayRemoval] = []
    public var ratings: [Item] = []
    public var watchlist: [Item] = []
    public var dropped: [Item] = []
    public var favourites: [Item] = []
    /// Simkl: titles the source doesn't have at all, taken off Simkl whole (history and its lists).
    public var titles: [Item] = []
    /// Titles left as they are because the two sides number their episodes differently.
    public var renumbered: [String] = []
    /// Titles cleared off the target altogether (every play, its rating, watchlist, dropped and
    /// favourite). Never part of a Force Match run: clearing loses what the source can't hold
    /// (rewatches, specials, favourites), so it's only for a reset you ask for, title by title.
    public var wipe: [Item] = []
    public var removalCount: Int { plays.count + ratings.count + watchlist.count + dropped.count + favourites.count + titles.count + wipe.count }
    public var isEmpty: Bool { send.isEmpty && removalCount == 0 }

    static func key(movie: Bool, _ tmdb: Int) -> String { (movie ? "movie:" : "tv:") + String(tmdb) }
    /// Every title the plan changes, by key ("tv:1399"), with its name.
    public var names: [String: String] {
        var result: [String: String] = [:]
        for ref in send.plays.map(\.title) + send.ratings.map(\.title) + send.watchlistAdd + send.watchlistRemove + send.favouritesAdd
            + send.dropped + send.moves.map(\.title) { result[Self.key(movie: ref.movie, ref.tmdbId)] = ref.name }
        for item in plays.map(\.title) + ratings + watchlist + dropped + favourites + titles + wipe { result[Self.key(movie: item.movie, item.tmdbId)] = item.name }
        return result
    }
    /// The titles one call changes, by key: from its body's TMDB ids, or (Trakt's history ids,
    /// WeTrakr's play ids) from the plays it takes off.
    public func keys(of request: Request) -> [String] {
        if request.method == "DELETE", let id = request.path.split(separator: "/").last.map(String.init)?.removingPercentEncoding {
            return plays.filter { $0.remoteId == id }.map { Self.key(movie: $0.title.movie, $0.title.tmdbId) }
        }
        guard let body = request.body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return [] }
        if let ids = root["ids"] as? [Any] {
            let wanted = Set(ids.compactMap { ($0 as? NSNumber)?.int64Value })
            return Array(Set(plays.filter { wanted.contains($0.historyId) }.map { Self.key(movie: $0.title.movie, $0.title.tmdbId) })).sorted()
        }
        var keys: [String] = []
        for (slot, movie) in [("movies", true), ("shows", false)] {
            for case let item as [String: Any] in (root[slot] as? [Any]) ?? [] {
                if let tmdb = ((item["ids"] as? [String: Any])?["tmdb"] as? NSNumber)?.intValue { keys.append(Self.key(movie: movie, tmdb)) }
            }
        }
        return keys
    }
    /// The plan without these titles (ones a service refused, so they aren't sent again).
    public func without(_ keys: Set<String>) -> ForceMatchPlan {
        keys.isEmpty ? self : filtered { !keys.contains($0) }
    }
    /// Only these titles.
    public func only(_ keys: Set<String>) -> ForceMatchPlan { filtered { keys.contains($0) } }
    /// Clears these titles off `target` altogether (see `wipe`).
    public static func wipe(_ keys: Set<String>, target: TraktLibrary, tracker: MainTracker) -> ForceMatchPlan {
        var plan = ForceMatchPlan()
        plan.tracker = tracker
        var seen = Set<String>()
        for ref in target.plays.map(\.title) + target.ratings.map(\.title) + target.watchlist.map(\.title) + target.favorites.map(\.title) + target.dropped.map(\.title) {
            guard let k = ref.diaryKey, let tmdb = ref.tmdbId, keys.contains(k), seen.insert(k).inserted else { continue }
            plan.wipe.append(Item(ref, tmdb: tmdb))
        }
        return plan
    }
    private func filtered(_ include: (String) -> Bool) -> ForceMatchPlan {
        func keep(_ ref: TraktWritePlan.Ref) -> Bool { include(Self.key(movie: ref.movie, ref.tmdbId)) }
        func keep(_ item: Item) -> Bool { include(Self.key(movie: item.movie, item.tmdbId)) }
        var plan = self
        plan.send.plays = send.plays.filter { keep($0.title) }
        plan.send.ratings = send.ratings.filter { keep($0.title) }
        plan.send.watchlistAdd = send.watchlistAdd.filter(keep)
        plan.send.watchlistRemove = send.watchlistRemove.filter(keep)
        plan.send.favouritesAdd = send.favouritesAdd.filter(keep)
        plan.send.dropped = send.dropped.filter(keep)
        plan.send.moves = send.moves.filter { keep($0.title) }
        plan.plays = plays.filter { keep($0.title) }
        plan.ratings = ratings.filter(keep); plan.watchlist = watchlist.filter(keep); plan.dropped = dropped.filter(keep)
        plan.favourites = favourites.filter(keep); plan.titles = titles.filter(keep); plan.wipe = wipe.filter(keep)
        plan.renumbered = []
        return plan
    }

    /// `target`: the library being changed, on `tracker`. `source`: the side that wins, as a diary,
    /// and `sourceHolds`: what that side can keep (the diary keeps everything Trakt does). `keep`:
    /// titles the source has but can't name by TMDB id (`keepTokens`), never taken off the target.
    public static func make(target: TraktLibrary, tracker: MainTracker, source: Workspace, sourceHolds: MainTracker.Capabilities,
                            keep: Set<String> = []) -> ForceMatchPlan {
        var plan = ForceMatchPlan()
        plan.tracker = tracker
        func kept(_ ref: TraktTitleRef) -> Bool {
            if let imdb = ref.imdbId, keep.contains("imdb:" + imdb) { return true }
            return Self.nameToken(ref.name, ref.year).map(keep.contains) ?? false
        }
        plan.send = TraktWritePlan.make(library: target, workspace: source, tracker: tracker)
        // Favourites only on one side are taken off the target below, not copied into the source.
        plan.send.diaryFavourites = []
        let can = tracker.capabilities
        let rewatches = can.keepsRewatches && sourceHolds.keepsRewatches
        let specials = can.keepsSpecials && sourceHolds.keepsSpecials
        let favourites = can.holdsFavourites && sourceHolds.holdsFavourites
        let droppedToo = can.holdsDropped && sourceHolds.holdsDropped

        // The source, by title key ("tv:1399") and by play slot ("tv:1399|s1e2").
        let titles = source.activeTitles
        func key(_ title: MediaTitle) -> String? { title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } }
        var byKey: [String: MediaTitle] = [:]
        for title in titles { if let k = key(title), byKey[k] == nil { byKey[k] = title } }
        let keyOf = Dictionary(titles.compactMap { title in key(title).map { (title.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(source.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sourceTimes: [String: [Date]] = [:]
        for event in source.activeEvents {
            guard let k = keyOf[event.titleId] else { continue }
            let episode = event.episodeId.flatMap { episodes[$0] }
            if byKey[k]?.isSeries == true, episode == nil { continue }
            let slot = k + (episode.map { "|s\($0.season)e\($0.number)" } ?? "")
            sourceTimes[slot, default: []].append(DiaryDate.parse(event.watchedAt) ?? .distantPast)
        }

        // Titles getting plays: a title also losing other episodes is renumbered, not different.
        let sending = Set(plan.send.plays.map { ($0.title.movie ? "movie:" : "tv:") + String($0.title.tmdbId) })
        // Simkl takes a title off whole when the source doesn't have it at all.
        let wholeTitles = tracker == .simkl

        // Plays the target has beyond the source's.
        var targetPlays: [String: [TraktPlay]] = [:], order: [String] = []
        for play in target.plays {
            guard let k = play.title.diaryKey, play.title.tmdbId != nil, !kept(play.title) else { continue }
            if play.season == 0, !specials { continue }
            let slot = k + (play.season.map { "|s\($0)e\(play.episode ?? 0)" } ?? "")
            if targetPlays[slot] == nil { order.append(slot) }
            targetPlays[slot, default: []].append(play)
        }
        var removing: [String: [PlayRemoval]] = [:]
        for slot in order {
            let plays = (targetPlays[slot] ?? []).sorted { ($0.watchedAt ?? "") < ($1.watchedAt ?? "") }
            var times = sourceTimes[slot] ?? []
            let extra: [TraktPlay]
            if rewatches {
                // Plays at the source's times (within a minute) match; the source's other plays stand
                // for that many of the rest; the newest of what's left go.
                var left: [TraktPlay] = []
                for play in plays {
                    let when = play.watchedAt.flatMap(DiaryDate.parse) ?? .distantPast
                    if let index = times.firstIndex(where: { abs($0.timeIntervalSince(when)) <= 60 }) { times.remove(at: index) } else { left.append(play) }
                }
                extra = Array(left.suffix(max(0, left.count - times.count)))
            } else {
                // One watch per episode or movie: only one the source has no watch of goes.
                extra = times.isEmpty ? plays : []
            }
            guard !extra.isEmpty, let first = extra.first, let tmdb = first.title.tmdbId, let k = first.title.diaryKey else { continue }
            let item = Item(first.title, tmdb: tmdb)
            removing[k, default: []] += extra.map {
                PlayRemoval(title: item, season: $0.season, episode: $0.episode, watchedAt: $0.watchedAt, historyId: $0.historyId, remoteId: $0.remoteId)
            }
        }
        var renumberedKeys = Set<String>()
        for (k, plays) in removing.sorted(by: { $0.key < $1.key }) {
            // Missing episodes and extra ones of the same show: numbered differently on the two sides.
            if k.hasPrefix("tv:"), sending.contains(k), plays.contains(where: { $0.season != nil }) {
                plan.renumbered.append(plays[0].title.name); renumberedKeys.insert(k); continue
            }
            if wholeTitles, byKey[k] == nil { continue }
            plan.plays += plays
        }
        // Left as it is means its episodes aren't sent either: the target would file them under its
        // own numbers again (or drop them), and the show would never stop looking different.
        if !renumberedKeys.isEmpty {
            plan.send.plays.removeAll { renumberedKeys.contains(Self.key(movie: $0.title.movie, $0.title.tmdbId)) }
        }

        // Title facts: ratings, watchlist, favourites and dropped the source doesn't have.
        var refs: [String: TraktTitleRef] = [:]
        for ref in target.plays.map(\.title) + target.ratings.map(\.title) + target.watchlist.map(\.title) + target.favorites.map(\.title) + target.dropped.map(\.title) {
            if let k = ref.diaryKey, ref.tmdbId != nil, refs[k] == nil, !kept(ref) { refs[k] = ref }
        }
        func item(_ k: String) -> Item? { refs[k].flatMap { ref in ref.tmdbId.map { Item(ref, tmdb: $0) } } }
        if wholeTitles {
            for k in refs.keys.sorted() where byKey[k] == nil { if let item = item(k) { plan.titles.append(item) } }
        }
        let gone = Set(plan.titles.map { ($0.movie ? "movie:" : "tv:") + String($0.tmdbId) })
        func keys(_ list: [TraktListed]) -> [String] { Array(Set(list.compactMap(\.title.diaryKey))).sorted() }
        for rating in target.ratings {
            guard let k = rating.title.diaryKey, !gone.contains(k), refs[k] != nil else { continue }
            let score = byKey[k]?.score.flatMap { $0.isFinite && (1...10).contains($0) ? Int($0.rounded()) : nil }
            if score == nil, let item = item(k), !plan.ratings.contains(item) { plan.ratings.append(item) }
        }
        // Watchlist entries of titles the source has are already moved or taken off by `send`.
        for k in keys(target.watchlist) where byKey[k] == nil && !gone.contains(k) { if let item = item(k) { plan.watchlist.append(item) } }
        if favourites {
            for k in keys(target.favorites) where byKey[k]?.favorite != true && !gone.contains(k) { if let item = item(k) { plan.favourites.append(item) } }
        }
        if droppedToo {
            for k in keys(target.dropped) where byKey[k]?.status != "dropped" && !gone.contains(k) {
                // Simkl moves a title the source has to the list for its status instead.
                if tracker == .simkl, let title = byKey[k], let list = TraktWritePlan.simklList(title), let item = item(k) {
                    plan.send.moves.append(TraktWritePlan.Move(title: TraktWritePlan.Ref(movie: item.movie, tmdbId: item.tmdbId, name: item.name), to: list))
                    continue
                }
                if let item = item(k) { plan.dropped.append(item) }
            }
        }
        return plan
    }

    /// Titles a side has without a TMDB id, by IMDb id and by name and year, for `keep`.
    public static func keepTokens(_ refs: [TraktTitleRef]) -> Set<String> {
        var tokens = Set<String>()
        for ref in refs where ref.tmdbId == nil {
            if let imdb = ref.imdbId { tokens.insert("imdb:" + imdb) }
            if let token = nameToken(ref.name, ref.year) { tokens.insert(token) }
        }
        return tokens
    }
    public static func keepTokens(_ titles: [MediaTitle]) -> Set<String> {
        Set(titles.filter { $0.tmdbId == nil }.compactMap { nameToken($0.name, $0.year) })
    }
    /// nil for a title with no name to go by (WeTrakr and MDBList send some without one): every
    /// nameless title would otherwise share one token and be kept together.
    static func nameToken(_ name: String, _ year: Int?) -> String? {
        let letters = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? nil : "name:" + letters + "|" + (year.map(String.init) ?? "")
    }

    /// The sends first (as a match), then the removals, at most 100 items per call.
    public func requests() -> [Request] {
        var result = send.requests().map { Request(method: "POST", path: $0.path, body: $0.body, summary: $0.summary, count: $0.count) }
        func batches<T>(_ items: [T], _ size: Int = 100) -> [[T]] {
            stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
        }
        func add(_ path: String, _ body: [String: Any], _ summary: String, _ count: Int) {
            guard count > 0, let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
            result.append(Request(method: "POST", path: path, body: data, summary: summary, count: count))
        }
        func ids(_ item: Item) -> [String: Any] {
            var value: [String: Any] = ["tmdb": item.tmdbId]
            // Simkl finds its own titles best by its id (and anime by it alone).
            if tracker == .simkl { if let simkl = item.simklId { value["simkl"] = simkl }; if let imdb = item.imdbId { value["imdb"] = imdb } }
            return ["ids": value]
        }
        func split(_ items: [Item], _ extra: [String: Any] = [:]) -> [String: Any] {
            ["movies": items.filter(\.movie).map { ids($0).merging(extra) { $1 } },
             "shows": items.filter { !$0.movie }.map { ids($0).merging(extra) { $1 } }]
        }
        // Plays.
        switch tracker {
        case .trakt:
            for batch in batches(plays) { add("/sync/history/remove", ["ids": batch.map(\.historyId)], "plays taken off", batch.count) }
        case .wetrakr:
            // A hundred plays a call, each by its time (WeTrakr then takes off only that play): its
            // writes are limited per minute and per day, so one call per play could run out. A play
            // without a time goes on its own, by its play_id.
            let timed = plays.filter { $0.watchedAt != nil }
            for batch in batches(timed) {
                var movies: [[String: Any]] = [], shows: [Int: (item: Item, seasons: [Int: [[String: Any]]])] = [:]
                for play in batch {
                    guard let date = play.watchedAt else { continue }
                    if play.title.movie { movies.append(ids(play.title).merging(["status": "watched", "tracked_at": date]) { $1 }) }
                    else if let season = play.season {
                        shows[play.title.tmdbId, default: (play.title, [:])].seasons[season, default: []].append(["number": play.episode ?? 0, "tracked_at": date])
                    }
                }
                let showBodies: [[String: Any]] = shows.keys.sorted().map { id in
                    let entry = shows[id]!
                    return ids(entry.item).merging(["status": "watched",
                                                    "seasons": entry.seasons.keys.sorted().map { ["number": $0, "episodes": entry.seasons[$0]!] }]) { $1 }
                }
                add("/sync/tracking/remove", ["movies": movies, "shows": showBodies], "plays taken off", batch.count)
            }
            for play in plays where play.watchedAt == nil {
                if let id = play.remoteId, let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    result.append(Request(method: "DELETE", path: "/sync/tracklogs/" + escaped, body: nil, summary: "play taken off", count: 1))
                }
            }
        case .simkl, .mdblist:
            let path = tracker == .mdblist ? "/sync/watched/remove" : "/sync/history/remove"
            for batch in batches(plays) {
                var movies: [[String: Any]] = [], shows: [Int: (item: Item, seasons: [Int: [Int]])] = [:]
                for play in batch {
                    if play.title.movie { movies.append(ids(play.title)) }
                    else if let season = play.season, let episode = play.episode {
                        shows[play.title.tmdbId, default: (play.title, [:])].seasons[season, default: []].append(episode)
                    }
                }
                let showBodies: [[String: Any]] = shows.keys.sorted().map { id in
                    let entry = shows[id]!
                    return ids(entry.item).merging(["seasons": entry.seasons.keys.sorted().map { ["number": $0, "episodes": entry.seasons[$0]!.sorted().map { ["number": $0] }] }]) { $1 }
                }
                add(path, ["movies": movies, "shows": showBodies], "plays taken off", batch.count)
            }
        }
        // Titles cleared altogether, with each service's own calls.
        for batch in batches(wipe) {
            let count = batch.count
            switch tracker {
            case .trakt:
                add("/sync/history/remove", split(batch), "titles cleared", count)
                add("/sync/ratings/remove", split(batch), "ratings cleared", count)
                add("/sync/watchlist/remove", split(batch), "taken off the watchlist", count)
                add("/sync/favorites/remove", split(batch), "favourites cleared", count)
                let shows = batch.filter { !$0.movie }
                if !shows.isEmpty { add("/users/hidden/dropped/remove", ["shows": shows.map(ids)], "taken off dropped", shows.count) }
            case .wetrakr:
                add("/sync/tracking/remove/all", split(batch, ["status": "watched"]), "titles cleared", count)
                add("/sync/tracking/remove", split(batch, ["status": "planning"]), "taken off the watchlist", count)
                add("/sync/tracking/remove", split(batch, ["status": "dropped"]), "taken off dropped", count)
                add("/sync/ratings/remove", split(batch), "ratings cleared", count)
                add("/sync/favorites/remove", split(batch), "favourites cleared", count)
            case .simkl:
                add("/sync/history/remove", split(batch), "titles cleared", count)
                add("/sync/ratings/remove", split(batch), "ratings cleared", count)
            case .mdblist:
                add("/sync/watched/remove", split(batch), "titles cleared", count)
                add("/sync/ratings/remove", split(batch), "ratings cleared", count)
                add("/watchlist/items/remove", split(batch), "taken off the watchlist", count)
                add("/sync/dropped/remove", split(batch), "taken off dropped", count)
            }
        }
        // Simkl titles taken off whole.
        for batch in batches(titles) { add("/sync/history/remove", split(batch), "titles taken off", batch.count) }
        for batch in batches(ratings) { add("/sync/ratings/remove", split(batch), "ratings taken off", batch.count) }
        for batch in batches(watchlist) {
            switch tracker {
            case .trakt: add("/sync/watchlist/remove", split(batch), "taken off the watchlist", batch.count)
            case .wetrakr: add("/sync/tracking/remove", split(batch, ["status": "planning"]), "taken off the watchlist", batch.count)
            case .mdblist: add("/watchlist/items/remove", split(batch), "taken off the watchlist", batch.count)
            case .simkl: add("/sync/history/remove", split(batch), "taken off Plan to Watch", batch.count)
            }
        }
        for batch in batches(favourites) { add("/sync/favorites/remove", split(batch), "favourites taken off", batch.count) }
        for batch in batches(dropped) {
            switch tracker {
            case .trakt: add("/users/hidden/dropped/remove", ["shows": batch.filter { !$0.movie }.map(ids)], "taken off dropped", batch.count)
            case .wetrakr: add("/sync/tracking/remove", split(batch, ["status": "dropped"]), "taken off dropped", batch.count)
            case .mdblist: add("/sync/dropped/remove", split(batch), "taken off dropped", batch.count)
            case .simkl: add("/sync/history/remove", split(batch), "taken off dropped", batch.count)
            }
        }
        return result
    }

    /// One line per kind of change, for the preview.
    public var summary: [String] {
        let name = tracker.name
        func counted(_ count: Int, _ one: String, _ many: String) -> String { count.formatted() + " " + (count == 1 ? one : many) }
        var lines = send.summary
        if !plays.isEmpty { lines.append(counted(plays.count, "watch", "watches") + " taken off \(name) history") }
        if !titles.isEmpty { lines.append(counted(titles.count, "title", "titles") + " not in the source taken off \(name)") }
        if !ratings.isEmpty { lines.append(counted(ratings.count, "rating", "ratings") + " taken off \(name)") }
        if !watchlist.isEmpty { lines.append(counted(watchlist.count, "title", "titles") + " taken off the \(name) watchlist") }
        if !favourites.isEmpty { lines.append(counted(favourites.count, "favourite", "favourites") + " taken off \(name)") }
        if !dropped.isEmpty { lines.append(counted(dropped.count, "title", "titles") + " taken off dropped on \(name)") }
        if !renumbered.isEmpty { lines.append(counted(renumbered.count, "show", "shows") + " left as they are (episodes numbered differently)") }
        if !wipe.isEmpty { lines.append(counted(wipe.count, "title", "titles") + " cleared off \(name) to be sent again") }
        return lines
    }
}
