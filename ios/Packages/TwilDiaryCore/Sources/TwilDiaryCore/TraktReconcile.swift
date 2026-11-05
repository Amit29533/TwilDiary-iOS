import Foundation

// Trakt-first plan, phase 2 (ios/docs/TRAKT-CLIENT-PLAN.md): "Make Trakt match the diary". The diary
// is the record until the switch-over, so Trakt is brought in line with it, never the other way,
// except favourites, which are shared both ways. Nothing is deleted from Trakt's history: plays
// only on Trakt stay (the incoming worker brings them into the diary). Every play sent carries the
// diary's own watch time, so the incoming worker links it to that watch instead of importing a copy.

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

    public var plays: [Play] = []
    public var ratings: [Rating] = []
    public var watchlistAdd: [Ref] = []
    public var watchlistRemove: [Ref] = []
    public var favouritesAdd: [Ref] = []
    public var dropped: [Ref] = []
    /// Diary titles to mark as favourites (favourites on Trakt but not in the diary).
    public var diaryFavourites: [String] = []
    /// Diary watches that can't be sent: no date (Trakt needs one), or a title without a TMDB id.
    public var skippedPlays = 0
    public var isEmpty: Bool {
        plays.isEmpty && ratings.isEmpty && watchlistAdd.isEmpty && watchlistRemove.isEmpty && favouritesAdd.isEmpty && dropped.isEmpty && diaryFavourites.isEmpty
    }

    /// What the diary has that Trakt doesn't (with the rules above).
    public static func make(library: TraktLibrary, workspace: Workspace) -> TraktWritePlan {
        var plan = TraktWritePlan()
        let titles = workspace.activeTitles
        func key(_ movie: Bool, _ tmdb: Int) -> String { (movie ? "movie:" : "tv:") + String(tmdb) }
        func ref(_ title: MediaTitle) -> Ref? { title.tmdbId.map { Ref(movie: !title.isSeries, tmdbId: $0, name: title.name) } }
        var byKey: [String: MediaTitle] = [:]
        for title in titles { if let tmdb = title.tmdbId { byKey[key(!title.isSeries, tmdb)] = byKey[key(!title.isSeries, tmdb)] ?? title } }
        let byID = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(workspace.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Plays: each diary watch that Trakt doesn't have at the same time (within a minute).
        var traktTimes: [String: [Date]] = [:]
        for play in library.plays {
            guard let diaryKey = play.title.diaryKey else { continue }
            let slot = diaryKey + (play.season.map { "|s\($0)e\(play.episode ?? 0)" } ?? "")
            traktTimes[slot, default: []].append(play.watchedAt.flatMap(DiaryDate.parse) ?? .distantPast)
        }
        for event in workspace.activeEvents.sorted(by: { ($0.watchedAt ?? "") < ($1.watchedAt ?? "") }) {
            guard let title = byID[event.titleId], let titleRef = ref(title) else { plan.skippedPlays += 1; continue }
            let episode = event.episodeId.flatMap { episodes[$0] }
            if title.isSeries && episode == nil { plan.skippedPlays += 1; continue }
            let slot = key(titleRef.movie, titleRef.tmdbId) + (episode.map { "|s\($0.season)e\($0.number)" } ?? "")
            guard let when = DiaryDate.parse(event.watchedAt) else { plan.skippedPlays += 1; continue }
            if let index = traktTimes[slot]?.firstIndex(where: { abs($0.timeIntervalSince(when)) <= 60 }) {
                traktTimes[slot]?.remove(at: index); continue
            }
            plan.plays.append(Play(title: titleRef, season: episode?.season, episode: episode?.number,
                                   watchedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(when)))
        }

        // Title facts.
        let traktRatings = Dictionary(library.ratings.compactMap { r in r.title.diaryKey.map { ($0, r.rating) } }, uniquingKeysWith: { first, _ in first })
        func keys(_ list: [TraktListed]) -> Set<String> { Set(list.compactMap(\.title.diaryKey)) }
        let watchlist = keys(library.watchlist), favourites = keys(library.favorites), dropped = keys(library.dropped)
        for (diaryKey, title) in byKey.sorted(by: { $0.key < $1.key }) {
            guard let titleRef = ref(title) else { continue }
            if let score = title.score, score.isFinite, (1...10).contains(score), traktRatings[diaryKey] != Int(score.rounded()) {
                plan.ratings.append(Rating(title: titleRef, rating: Int(score.rounded())))
            }
            let planned = title.status == "planned"
            if planned && !watchlist.contains(diaryKey) { plan.watchlistAdd.append(titleRef) }
            if !planned && watchlist.contains(diaryKey) { plan.watchlistRemove.append(titleRef) }
            if title.favorite && !favourites.contains(diaryKey) { plan.favouritesAdd.append(titleRef) }
            if !title.favorite && favourites.contains(diaryKey) { plan.diaryFavourites.append(title.id) }
            // Trakt drops shows only (a dropped movie stays in the diary's own record).
            if title.status == "dropped" && title.isSeries && !dropped.contains(diaryKey) { plan.dropped.append(titleRef) }
        }
        return plan
    }

    /// The writes, at most 100 items per request (Trakt takes batches; one request a second).
    public func requests() -> [Request] {
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
            add("/sync/history", ["movies": movies, "shows": showBodies], "plays", batch.count)
        }
        for batch in batches(ratings) {
            let body: [String: Any] = [
                "movies": batch.filter(\.title.movie).map { ["ids": ["tmdb": $0.title.tmdbId], "rating": $0.rating] },
                "shows": batch.filter { !$0.title.movie }.map { ["ids": ["tmdb": $0.title.tmdbId], "rating": $0.rating] }
            ]
            add("/sync/ratings", body, "ratings", batch.count)
        }
        for batch in batches(watchlistAdd) { add("/sync/watchlist", split(batch), "added to the watchlist", batch.count) }
        for batch in batches(watchlistRemove) { add("/sync/watchlist/remove", split(batch), "taken off the watchlist", batch.count) }
        for batch in batches(favouritesAdd) { add("/sync/favorites", split(batch), "favourites", batch.count) }
        for batch in batches(dropped) { add("/users/hidden/dropped", ["shows": batch.map(ids)], "dropped shows", batch.count) }
        return result
    }

    /// One line per kind of change, for the confirmation.
    public var summary: [String] {
        var lines: [String] = []
        if !plays.isEmpty { lines.append(plays.count.formatted() + (plays.count == 1 ? " watch" : " watches") + " added to Trakt history, at the diary’s times") }
        if !ratings.isEmpty { lines.append(ratings.count.formatted() + (ratings.count == 1 ? " rating" : " ratings") + " set on Trakt") }
        if !watchlistAdd.isEmpty { lines.append(watchlistAdd.count.formatted() + " Planned " + (watchlistAdd.count == 1 ? "title" : "titles") + " added to the Trakt watchlist") }
        if !watchlistRemove.isEmpty { lines.append(watchlistRemove.count.formatted() + " no-longer-Planned " + (watchlistRemove.count == 1 ? "title" : "titles") + " taken off the watchlist") }
        if !favouritesAdd.isEmpty { lines.append(favouritesAdd.map(\.name).joined(separator: ", ") + " made Trakt favourites") }
        if !dropped.isEmpty { lines.append(dropped.map(\.name).joined(separator: ", ") + " dropped on Trakt") }
        if !diaryFavourites.isEmpty { lines.append(diaryFavourites.count.formatted() + " Trakt " + (diaryFavourites.count == 1 ? "favourite" : "favourites") + " made a diary favourite") }
        return lines
    }
}
