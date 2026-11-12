import Foundation

// Trakt-first plan, phase 2 (ios/docs/TRAKT-CLIENT-PLAN.md): "Make Trakt match the diary". The diary
// is the record until the switch-over, so Trakt is brought in line with it, never the other way,
// except favourites, which are shared both ways. Nothing is deleted from Trakt's history: plays
// only on Trakt stay (the incoming worker brings them into the diary). Every play sent carries the
// diary's own watch time, so the incoming worker links it to that watch instead of importing a copy.
//
// Phase 5: the same plan for Simkl and MDBList ("Make Simkl match the diary"), within what each
// keeps: one watch per episode or movie (the first, at the diary's time; rewatches stay in
// Cloudflare), no favourites, and each service's own endpoints. Simkl has no "take off Plan to
// Watch" that keeps history, so a title leaving Planned is moved to the list for its status.

public struct TraktWritePlan: Equatable, Sendable {
    /// A movie or show as Trakt is told about it (by TMDB id, which Trakt accepts).
    public struct Ref: Hashable, Sendable {
        public let movie: Bool
        public let tmdbId: Int
        public let name: String
    }
    public struct Play: Hashable, Sendable {
        public let title: Ref
        public let season: Int?
        public let episode: Int?
        /// The diary's watch time, ISO 8601 with milliseconds (Trakt's own format).
        public let watchedAt: String
        /// Another play of something the service already has: only then may WeTrakr log it again.
        public var rewatch = false
    }
    public struct Rating: Hashable, Sendable {
        public let title: Ref
        public let rating: Int
    }
    /// One POST: its path, JSON body and what it does, for progress and receipts.
    public struct Request: Equatable, Sendable {
        public let path: String
        public let body: Data
        public let summary: String
        public let count: Int
    }

    /// Simkl: a title moved to another of its lists (`/sync/add-to-list`).
    public struct Move: Hashable, Sendable {
        public let title: Ref
        public let to: String
    }

    /// The service the plan writes to.
    public var tracker: MainTracker = .trakt
    public var plays: [Play] = []
    public var ratings: [Rating] = []
    public var watchlistAdd: [Ref] = []
    public var watchlistRemove: [Ref] = []
    public var favouritesAdd: [Ref] = []
    public var dropped: [Ref] = []
    public var moves: [Move] = []
    /// Diary titles to mark as favourites (favourites on Trakt but not in the diary).
    public var diaryFavourites: [String] = []
    /// Diary watches that can't be sent: no date (Trakt needs one), or a title without a TMDB id.
    public var skippedPlays = 0
    public var isEmpty: Bool {
        plays.isEmpty && ratings.isEmpty && watchlistAdd.isEmpty && watchlistRemove.isEmpty && favouritesAdd.isEmpty && dropped.isEmpty
            && moves.isEmpty && diaryFavourites.isEmpty
    }

    /// What the diary has that Trakt doesn't (with the rules above).
    ///
    /// `fillOnly`: Trakt holds the diary now and `workspace` is the old server copy. Only what
    /// Trakt lacks altogether is sent (a play, a rating where Trakt has none, Planned for a title
    /// never watched on Trakt, a favourite, a dropped show); nothing on Trakt is changed or taken
    /// off, and nothing is written back to the server. `except` holds `tokens` already sent once,
    /// so a thing you later took off Trakt isn't offered again.
    public static func make(library: TraktLibrary, workspace: Workspace, tracker: MainTracker = .trakt,
                            fillOnly: Bool = false, except: Set<String> = []) -> TraktWritePlan {
        var plan = TraktWritePlan()
        plan.tracker = tracker
        let can = tracker.capabilities
        var sentSlots = Set<String>()
        let titles = workspace.activeTitles
        func key(_ movie: Bool, _ tmdb: Int) -> String { (movie ? "movie:" : "tv:") + String(tmdb) }
        func ref(_ title: MediaTitle) -> Ref? { title.tmdbId.map { Ref(movie: !title.isSeries, tmdbId: $0, name: title.name) } }
        var byKey: [String: MediaTitle] = [:]
        for title in titles { if let tmdb = title.tmdbId { byKey[key(!title.isSeries, tmdb)] = byKey[key(!title.isSeries, tmdb)] ?? title } }
        let byID = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Plays: each diary watch that Trakt doesn't have at the same time (within a minute). A
        // watch the service keeps at another time (it rounds or shifts times) still counts: a
        // movie or episode gets new plays only when the diary has more of them than the service,
        // or every match would log it again (WeTrakr had films twice that way).
        var traktTimes: [String: [Date]] = [:]
        var unmatched: [String: [Play]] = [:], slotOrder: [String] = []
        var allServiceSlots: [String: Int] = [:]
        for play in library.plays {
            guard let diaryKey = play.title.diaryKey else { continue }
            let slot = diaryKey + (play.season.map { "|s\($0)e\(play.episode ?? 0)" } ?? "")
            traktTimes[slot, default: []].append(play.watchedAt.flatMap(DiaryDate.parse) ?? .distantPast)
            allServiceSlots[slot, default: 0] += 1
        }
        for event in workspace.activeEvents.sorted(by: { ($0.watchedAt ?? "") < ($1.watchedAt ?? "") }) {
            guard let title = byID[event.titleId], let titleRef = ref(title) else { plan.skippedPlays += 1; continue }
            let episode = event.episodeId.flatMap { episodes[$0] }
            if title.isSeries && episode == nil { plan.skippedPlays += 1; continue }
            if episode?.season == 0, !can.keepsSpecials { continue }
            let slot = key(titleRef.movie, titleRef.tmdbId) + (episode.map { "|s\($0.season)e\($0.number)" } ?? "")
            if except.contains("play|" + slot) { continue }
            guard let when = DiaryDate.parse(event.watchedAt) else { plan.skippedPlays += 1; continue }
            if !can.keepsRewatches {
                // One watch per episode or movie: the first one, and only when the service has none.
                if !(traktTimes[slot] ?? []).isEmpty || sentSlots.contains(slot) { continue }
                sentSlots.insert(slot)
            } else if let index = traktTimes[slot]?.firstIndex(where: { abs($0.timeIntervalSince(when)) <= 60 }) {
                traktTimes[slot]?.remove(at: index); continue
            } else {
                if unmatched[slot] == nil { slotOrder.append(slot) }
                unmatched[slot, default: []].append(Play(title: titleRef, season: episode?.season, episode: episode?.number,
                                                         watchedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(when)))
                continue
            }
            plan.plays.append(Play(title: titleRef, season: episode?.season, episode: episode?.number,
                                   watchedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(when)))
        }
        // The service's other plays (at other times) stand for that many of these; the newest
        // of the rest are sent.
        for slot in slotOrder {
            let waiting = unmatched[slot] ?? [], kept = traktTimes[slot]?.count ?? 0
            let sending = Array(waiting.suffix(max(0, waiting.count - kept)))
            // The first play of something the service has none of is a first watch; the rest are rewatches.
            let serviceHasIt = (allServiceSlots[slot] ?? 0) > 0
            for (index, play) in sending.enumerated() {
                var play = play
                play.rewatch = serviceHasIt || index > 0
                plan.plays.append(play)
            }
        }

        // Title facts.
        let traktRatings = Dictionary(library.ratings.compactMap { r in r.title.diaryKey.map { ($0, r.rating) } }, uniquingKeysWith: { first, _ in first })
        func keys(_ list: [TraktListed]) -> Set<String> { Set(list.compactMap(\.title.diaryKey)) }
        let watchlist = keys(library.watchlist), favourites = keys(library.favorites), dropped = keys(library.dropped)
        let played = Set(library.plays.compactMap(\.title.diaryKey))
        for (diaryKey, title) in byKey.sorted(by: { $0.key < $1.key }) {
            guard let titleRef = ref(title) else { continue }
            if let score = title.score, score.isFinite, (1...10).contains(score), traktRatings[diaryKey] != Int(score.rounded()),
               !fillOnly || traktRatings[diaryKey] == nil, !except.contains("rating|" + diaryKey) {
                plan.ratings.append(Rating(title: titleRef, rating: Int(score.rounded())))
            }
            let planned = title.status == "planned"
            if planned && !watchlist.contains(diaryKey),
               !fillOnly || !played.contains(diaryKey), !except.contains("planned|" + diaryKey) { plan.watchlistAdd.append(titleRef) }
            var moved = false
            if !fillOnly && !planned && watchlist.contains(diaryKey) {
                if tracker == .simkl {
                    if let list = simklList(title) { plan.moves.append(Move(title: titleRef, to: list)); moved = true }
                } else { plan.watchlistRemove.append(titleRef) }
            }
            if can.holdsFavourites {
                if title.favorite && !favourites.contains(diaryKey) && !except.contains("favourite|" + diaryKey) { plan.favouritesAdd.append(titleRef) }
                if !fillOnly && !title.favorite && favourites.contains(diaryKey) { plan.diaryFavourites.append(title.id) }
            }
            // Dropped is for shows only (a dropped movie stays in the diary's own record).
            if title.status == "dropped" && title.isSeries && !dropped.contains(diaryKey) && !moved && !except.contains("dropped|" + diaryKey) {
                plan.dropped.append(titleRef)
            }
        }
        return plan
    }

    /// One token per thing the plan sends, matching `except` (and `TraktComparison.compare`).
    public var tokens: Set<String> {
        func key(_ ref: Ref) -> String { (ref.movie ? "movie:" : "tv:") + String(ref.tmdbId) }
        var result = Set<String>()
        for play in plays { result.insert("play|" + key(play.title) + (play.season.map { "|s\($0)e\(play.episode ?? 0)" } ?? "")) }
        for rating in ratings { result.insert("rating|" + key(rating.title)) }
        for ref in watchlistAdd { result.insert("planned|" + key(ref)) }
        for ref in favouritesAdd { result.insert("favourite|" + key(ref)) }
        for ref in dropped { result.insert("dropped|" + key(ref)) }
        return result
    }

    /// The Simkl list for a title that's no longer Planned (nil: leave it where it is).
    public static func simklList(_ title: MediaTitle) -> String? { simklList(status: title.status, isSeries: title.isSeries) }
    public static func simklList(status: String, isSeries: Bool) -> String? {
        switch status {
        case "planned": return "plantowatch"
        case "dropped": return isSeries ? "dropped" : nil
        case "paused", "on_hold", "hold": return isSeries ? "hold" : nil
        case "watching": return isSeries ? "watching" : "completed"
        default: return "completed"
        }
    }

    /// The writes, at most 100 items per request (each service takes batches; one request a second).
    public func requests() -> [Request] {
        let historyPath = tracker == .mdblist ? "/sync/watched" : tracker == .wetrakr ? "/sync/tracking" : "/sync/history"
        var result: [Request] = []
        func ids(_ ref: Ref) -> [String: Any] { ["ids": ["tmdb": ref.tmdbId]] }
        func batches<T>(_ items: [T], _ size: Int = 100) -> [[T]] {
            stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
        }
        func add(_ path: String, _ body: [String: Any], _ summary: String, _ count: Int) {
            guard count > 0, let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
            result.append(Request(path: path, body: data, summary: summary, count: count))
        }
        func split(_ refs: [Ref]) -> [String: Any] {
            ["movies": refs.filter(\.movie).map(ids), "shows": refs.filter { !$0.movie }.map(ids)]
        }
        for batch in batches(plays) {
            var movies: [[String: Any]] = []
            var shows: [Int: (ref: Ref, seasons: [Int: [[String: Any]]])] = [:]
            for play in batch {
                if play.title.movie { movies.append(["ids": ["tmdb": play.title.tmdbId], "watched_at": play.watchedAt]) }
                else if let season = play.season, let episode = play.episode {
                    shows[play.title.tmdbId, default: (play.title, [:])].seasons[season, default: []].append(["number": episode, "watched_at": play.watchedAt])
                }
            }
            let showBodies: [[String: Any]] = shows.keys.sorted().map { id in
                let entry = shows[id]!
                return ["ids": ["tmdb": id], "seasons": entry.seasons.keys.sorted().map { ["number": $0, "episodes": entry.seasons[$0]!] }]
            }
            if tracker == .wetrakr {
                // First watches and rewatches go apart: only a rewatch may log another play.
                for rewatch in [false, true] {
                    let part = batch.filter { $0.rewatch == rewatch }
                    guard !part.isEmpty else { continue }
                    var partMovies: [[String: Any]] = [], partShows: [Int: [Int: [[String: Any]]]] = [:]
                    for play in part {
                        if play.title.movie { partMovies.append(["ids": ["tmdb": play.title.tmdbId], "watched_at": play.watchedAt]) }
                        else if let season = play.season, let episode = play.episode {
                            partShows[play.title.tmdbId, default: [:]][season, default: []].append(["number": episode, "watched_at": play.watchedAt])
                        }
                    }
                    let bodies: [[String: Any]] = partShows.keys.sorted().map { id in
                        ["ids": ["tmdb": id], "seasons": partShows[id]!.keys.sorted().map { ["number": $0, "episodes": partShows[id]![$0]!] }]
                    }
                    add(historyPath, ["movies": partMovies.map { WeTrakrWrite.watched($0, rewatch: rewatch) }, "shows": bodies.map { WeTrakrWrite.watched($0, rewatch: rewatch) }], "plays", part.count)
                }
            } else { add(historyPath, ["movies": movies, "shows": showBodies], "plays", batch.count) }
        }
        for batch in batches(ratings) {
            let body: [String: Any] = [
                "movies": batch.filter(\.title.movie).map { ["ids": ["tmdb": $0.title.tmdbId], "rating": $0.rating] },
                "shows": batch.filter { !$0.title.movie }.map { ["ids": ["tmdb": $0.title.tmdbId], "rating": $0.rating] }
            ]
            add("/sync/ratings", body, "ratings", batch.count)
        }
        func listed(_ refs: [Ref], _ to: (Ref) -> String) -> [String: Any] {
            ["movies": refs.filter(\.movie).map { ids($0).merging(["to": to($0)]) { $1 } },
             "shows": refs.filter { !$0.movie }.map { ids($0).merging(["to": to($0)]) { $1 } }]
        }
        switch tracker {
        case .trakt:
            for batch in batches(watchlistAdd) { add("/sync/watchlist", split(batch), "added to the watchlist", batch.count) }
            for batch in batches(watchlistRemove) { add("/sync/watchlist/remove", split(batch), "taken off the watchlist", batch.count) }
            for batch in batches(favouritesAdd) { add("/sync/favorites", split(batch), "favourites", batch.count) }
            for batch in batches(dropped) { add("/users/hidden/dropped", ["shows": batch.map(ids)], "dropped shows", batch.count) }
        case .simkl:
            for batch in batches(watchlistAdd) { add("/sync/add-to-list", listed(batch) { _ in "plantowatch" }, "added to Plan to Watch", batch.count) }
            for batch in batches(moves) {
                let to = Dictionary(batch.map { ($0.title, $0.to) }, uniquingKeysWith: { first, _ in first })
                add("/sync/add-to-list", listed(batch.map(\.title)) { to[$0] ?? "completed" }, "moved off Plan to Watch", batch.count)
            }
            for batch in batches(dropped) { add("/sync/add-to-list", listed(batch) { _ in "dropped" }, "dropped shows", batch.count) }
        case .wetrakr:
            func status(_ refs: [Ref], _ value: String) -> [String: Any] {
                ["movies": refs.filter(\.movie).map { ids($0).merging(["status": value]) { $1 } },
                 "shows": refs.filter { !$0.movie }.map { ids($0).merging(["status": value]) { $1 } }]
            }
            for batch in batches(watchlistAdd) { add("/sync/tracking", status(batch, "planning"), "added to the watchlist", batch.count) }
            for batch in batches(watchlistRemove) { add("/sync/tracking/remove", status(batch, "planning"), "taken off the watchlist", batch.count) }
            for batch in batches(favouritesAdd) { add("/sync/favorites", split(batch), "favourites", batch.count) }
            for batch in batches(dropped) { add("/sync/tracking", status(batch, "dropped"), "dropped shows", batch.count) }
        case .mdblist:
            for batch in batches(watchlistAdd) { add("/watchlist/items/add", split(batch), "added to the watchlist", batch.count) }
            for batch in batches(watchlistRemove) { add("/watchlist/items/remove", split(batch), "taken off the watchlist", batch.count) }
            for batch in batches(dropped) { add("/sync/dropped", ["shows": batch.map(ids)], "dropped shows", batch.count) }
        }
        return result
    }

    /// One line per kind of change, for the confirmation.
    public var summary: [String] {
        var lines: [String] = []
        let name = tracker.name
        let list = tracker == .simkl ? "Plan to Watch" : "the \(name) watchlist"
        if !plays.isEmpty { lines.append(plays.count.formatted() + (plays.count == 1 ? " watch" : " watches") + " added to \(name) history, at the diary’s times") }
        if !ratings.isEmpty { lines.append(ratings.count.formatted() + (ratings.count == 1 ? " rating" : " ratings") + " set on \(name)") }
        if !watchlistAdd.isEmpty { lines.append(watchlistAdd.count.formatted() + " Planned " + (watchlistAdd.count == 1 ? "title" : "titles") + " added to \(list)") }
        if !watchlistRemove.isEmpty { lines.append(watchlistRemove.count.formatted() + " no-longer-Planned " + (watchlistRemove.count == 1 ? "title" : "titles") + " taken off \(list)") }
        if !moves.isEmpty { lines.append(moves.count.formatted() + " no-longer-Planned " + (moves.count == 1 ? "title" : "titles") + " moved off Plan to Watch to their status") }
        if !favouritesAdd.isEmpty { lines.append(favouritesAdd.map(\.name).joined(separator: ", ") + " made \(name) favourites") }
        if !dropped.isEmpty { lines.append(dropped.map(\.name).joined(separator: ", ") + " dropped on \(name)") }
        if !diaryFavourites.isEmpty { lines.append(diaryFavourites.count.formatted() + " Trakt " + (diaryFavourites.count == 1 ? "favourite" : "favourites") + " made a diary favourite") }
        return lines
    }
}
