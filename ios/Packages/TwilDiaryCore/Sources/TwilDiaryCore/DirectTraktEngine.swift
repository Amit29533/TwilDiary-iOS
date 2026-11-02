import Foundation

/// Credentials for direct device-to-Trakt communication (`https://api.trakt.tv`).
public struct DirectTraktCredentials: Codable, Equatable, Sendable {
    public let clientId: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: String?
    public var username: String?

    public init(
        clientId: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: String? = nil,
        username: String? = nil
    ) {
        self.clientId = clientId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.username = username
    }
}

/// Snapshot of Trakt's `GET /sync/last_activities` timestamps used to skip unchanged endpoints.
public struct DirectTraktLastActivities: Codable, Equatable, Sendable {
    public let all: String
    public let moviesWatchedAt: String?
    public let moviesRatedAt: String?
    public let moviesWatchlistedAt: String?
    public let episodesWatchedAt: String?
    public let showsRatedAt: String?
    public let showsWatchlistedAt: String?

    public init(
        all: String,
        moviesWatchedAt: String? = nil,
        moviesRatedAt: String? = nil,
        moviesWatchlistedAt: String? = nil,
        episodesWatchedAt: String? = nil,
        showsRatedAt: String? = nil,
        showsWatchlistedAt: String? = nil
    ) {
        self.all = all
        self.moviesWatchedAt = moviesWatchedAt
        self.moviesRatedAt = moviesRatedAt
        self.moviesWatchlistedAt = moviesWatchlistedAt
        self.episodesWatchedAt = episodesWatchedAt
        self.showsRatedAt = showsRatedAt
        self.showsWatchlistedAt = showsWatchlistedAt
    }

    public struct DomainsToFetch: Equatable, Sendable {
        public let watchedMovies: Bool
        public let watchedShows: Bool
        public let ratedMovies: Bool
        public let ratedShows: Bool
        public let watchlistMovies: Bool
        public let watchlistShows: Bool
        public var anyChanged: Bool {
            watchedMovies || watchedShows || ratedMovies || ratedShows || watchlistMovies || watchlistShows
        }
    }

    /// Compares remote activity timestamps against a saved checkpoint so only changed domains are fetched.
    public func changedDomains(since previous: DirectTraktLastActivities?) -> DomainsToFetch {
        guard let previous else {
            return DomainsToFetch(
                watchedMovies: true,
                watchedShows: true,
                ratedMovies: true,
                ratedShows: true,
                watchlistMovies: true,
                watchlistShows: true
            )
        }
        if previous.all == all {
            return DomainsToFetch(
                watchedMovies: false,
                watchedShows: false,
                ratedMovies: false,
                ratedShows: false,
                watchlistMovies: false,
                watchlistShows: false
            )
        }
        return DomainsToFetch(
            watchedMovies: moviesWatchedAt != previous.moviesWatchedAt,
            watchedShows: episodesWatchedAt != previous.episodesWatchedAt,
            ratedMovies: moviesRatedAt != previous.ratedMovies,
            ratedShows: showsRatedAt != previous.showsRatedAt,
            watchlistMovies: moviesWatchlistedAt != previous.moviesWatchlistedAt,
            watchlistShows: showsWatchlistedAt != previous.showsWatchlistedAt
        )
    }
}

public struct DirectTraktWatchPlay: Codable, Equatable, Hashable, Sendable {
    public let tmdbId: Int
    public let isSeries: Bool
    public let season: Int?
    public let episode: Int?
    public let watchedAt: String

    public init(tmdbId: Int, isSeries: Bool, season: Int? = nil, episode: Int? = nil, watchedAt: String) {
        self.tmdbId = tmdbId
        self.isSeries = isSeries
        self.season = season
        self.episode = episode
        self.watchedAt = watchedAt
    }
}

public struct DirectTraktRatingItem: Codable, Equatable, Hashable, Sendable {
    public let tmdbId: Int
    public let isSeries: Bool
    public let rating: Int
    public let ratedAt: String

    public init(tmdbId: Int, isSeries: Bool, rating: Int, ratedAt: String) {
        self.tmdbId = tmdbId
        self.isSeries = isSeries
        self.rating = rating
        self.ratedAt = ratedAt
    }
}

public struct DirectTraktWatchlistItem: Codable, Equatable, Hashable, Sendable {
    public let tmdbId: Int
    public let isSeries: Bool
    public let listedAt: String

    public init(tmdbId: Int, isSeries: Bool, listedAt: String) {
        self.tmdbId = tmdbId
        self.isSeries = isSeries
        self.listedAt = listedAt
    }
}

public struct DirectTraktRemoteSnapshot: Codable, Equatable, Sendable {
    public var plays: [DirectTraktWatchPlay]
    public var ratings: [DirectTraktRatingItem]
    public var watchlist: [DirectTraktWatchlistItem]

    public init(
        plays: [DirectTraktWatchPlay] = [],
        ratings: [DirectTraktRatingItem] = [],
        watchlist: [DirectTraktWatchlistItem] = []
    ) {
        self.plays = plays
        self.ratings = ratings
        self.watchlist = watchlist
    }
}

/// Per-title baseline remembered after the last device-side Trakt sync for 3-way conflict resolution.
public struct DirectTraktTitleBaseline: Codable, Equatable, Sendable {
    public let titleId: String
    public let score: Int?
    public let watchlisted: Bool
    public let watchedEpisodeKeys: Set<String>

    public init(titleId: String, score: Int?, watchlisted: Bool, watchedEpisodeKeys: Set<String> = []) {
        self.titleId = titleId
        self.score = score
        self.watchlisted = watchlisted
        self.watchedEpisodeKeys = watchedEpisodeKeys
    }
}

public struct DirectTraktSyncBaseline: Codable, Equatable, Sendable {
    public var lastActivities: DirectTraktLastActivities?
    public var titles: [String: DirectTraktTitleBaseline]

    public init(lastActivities: DirectTraktLastActivities? = nil, titles: [String: DirectTraktTitleBaseline] = [:]) {
        self.lastActivities = lastActivities
        self.titles = titles
    }
}

/// Actions produced by the on-device 3-way Trakt diff engine.
public enum DirectTraktDiffAction: Codable, Equatable, Sendable {
    case pullWatch(titleId: String, episodeId: String?, watchedAt: String)
    case pullRating(titleId: String, score: Double)
    case pullWatchlist(titleId: String, status: String, queued: Bool)
    case pushWatch(titleId: String, tmdbId: Int, isSeries: Bool, season: Int?, episode: Int?, watchedAt: String)
    case pushRating(titleId: String, tmdbId: Int, isSeries: Bool, rating: Int)
    case pushWatchlist(titleId: String, tmdbId: Int, isSeries: Bool)
    case conflictRating(titleId: String, localScore: Double, remoteRating: Int)
    case importMissingTmdb(tmdbId: Int, isSeries: Bool)
}

public struct DirectTraktPlan: Codable, Equatable, Sendable {
    public let actions: [DirectTraktDiffAction]

    public init(actions: [DirectTraktDiffAction]) {
        self.actions = actions
    }

    public var pulls: [DirectTraktDiffAction] {
        actions.filter {
            switch $0 {
            case .pullWatch, .pullRating, .pullWatchlist: true
            default: false
            }
        }
    }

    public var pushes: [DirectTraktDiffAction] {
        actions.filter {
            switch $0 {
            case .pushWatch, .pushRating, .pushWatchlist: true
            default: false
            }
        }
    }

    public var conflicts: [DirectTraktDiffAction] {
        actions.filter {
            if case .conflictRating = $0 { return true }
            return false
        }
    }

    public var missingImports: [DirectTraktDiffAction] {
        actions.filter {
            if case .importMissingTmdb = $0 { return true }
            return false
        }
    }
}

/// On-device 3-way Trakt diff and apply engine that runs directly against `Workspace` without requiring D1.
public enum DirectTraktEngine {
    public static func plan(
        workspace: Workspace,
        remote: DirectTraktRemoteSnapshot,
        baseline: DirectTraktSyncBaseline = DirectTraktSyncBaseline()
    ) -> DirectTraktPlan {
        var actions: [DirectTraktDiffAction] = []
        let activeTitles = workspace.activeTitles
        var titleByKey: [String: MediaTitle] = [:]
        for title in activeTitles {
            guard let tmdbId = title.tmdbId else { continue }
            let key = "\(title.isSeries ? "tv" : "movie"):\(tmdbId)"
            if titleByKey[key] == nil { titleByKey[key] = title }
        }

        let episodesByTitle = Dictionary(grouping: workspace.episodes, by: \.titleId)
        let eventsByTitle = Dictionary(grouping: workspace.activeEvents, by: \.titleId)

        var seenMissingKeys = Set<String>()
        func markMissing(tmdbId: Int, isSeries: Bool) {
            let key = "\(isSeries ? "tv" : "movie"):\(tmdbId)"
            if seenMissingKeys.insert(key).inserted {
                actions.append(.importMissingTmdb(tmdbId: tmdbId, isSeries: isSeries))
            }
        }

        // 1. Diff watched history (remote -> local pulls, and missing TMDb imports)
        var remoteWatchedKeysByTitle: [String: Set<String>] = [:]
        for play in remote.plays {
            let key = "\(play.isSeries ? "tv" : "movie"):\(play.tmdbId)"
            guard let title = titleByKey[key] else {
                markMissing(tmdbId: play.tmdbId, isSeries: play.isSeries)
                continue
            }
            if !title.isSeries {
                let inserted = remoteWatchedKeysByTitle[title.id, default: []].insert("movie").inserted
                let hasLocalWatch = (eventsByTitle[title.id] ?? []).contains { $0.episodeId == nil }
                if inserted && !hasLocalWatch {
                    actions.append(.pullWatch(titleId: title.id, episodeId: nil, watchedAt: play.watchedAt))
                }
            } else if let s = play.season, let e = play.episode {
                let epKey = "s\(s)e\(e)"
                let inserted = remoteWatchedKeysByTitle[title.id, default: []].insert(epKey).inserted
                guard let episode = (episodesByTitle[title.id] ?? []).first(where: { $0.season == s && $0.number == e }) else {
                    continue
                }
                let hasLocalWatch = (eventsByTitle[title.id] ?? []).contains { $0.episodeId == episode.id }
                if inserted && !hasLocalWatch {
                    actions.append(.pullWatch(titleId: title.id, episodeId: episode.id, watchedAt: play.watchedAt))
                }
            }
        }

        // 2. Diff local watch events -> remote pushes
        for title in activeTitles {
            guard let tmdbId = title.tmdbId else { continue }
            let remoteKeys = remoteWatchedKeysByTitle[title.id] ?? []
            let localEvents = eventsByTitle[title.id] ?? []
            if !title.isSeries {
                if let firstEvent = localEvents.first(where: { $0.episodeId == nil }), !remoteKeys.contains("movie") {
                    actions.append(.pushWatch(
                        titleId: title.id,
                        tmdbId: tmdbId,
                        isSeries: false,
                        season: nil,
                        episode: nil,
                        watchedAt: firstEvent.watchedAt ?? firstEvent.recordedAt
                    ))
                }
            } else {
                let episodeByID = Dictionary(uniqueKeysWithValues: (episodesByTitle[title.id] ?? []).map { ($0.id, $0) })
                var pushedEpisodes = Set<String>()
                for event in localEvents {
                    guard let epID = event.episodeId, let ep = episodeByID[epID], ep.season > 0 else { continue }
                    let epKey = "s\(ep.season)e\(ep.number)"
                    if !remoteKeys.contains(epKey), pushedEpisodes.insert(epKey).inserted {
                        actions.append(.pushWatch(
                            titleId: title.id,
                            tmdbId: tmdbId,
                            isSeries: true,
                            season: ep.season,
                            episode: ep.number,
                            watchedAt: event.watchedAt ?? event.recordedAt
                        ))
                    }
                }
            }
        }

        // 3. 3-way diff ratings
        var remoteRatingByTitle: [String: Int] = [:]
        for item in remote.ratings {
            let key = "\(item.isSeries ? "tv" : "movie"):\(item.tmdbId)"
            guard let title = titleByKey[key] else {
                markMissing(tmdbId: item.tmdbId, isSeries: item.isSeries)
                continue
            }
            remoteRatingByTitle[title.id] = item.rating
        }

        for title in activeTitles {
            guard let tmdbId = title.tmdbId else { continue }
            let localRounded = title.score.map { Int($0.rounded()) }
            let remoteScore = remoteRatingByTitle[title.id]
            let baseScore = baseline.titles[title.id]?.score

            if localRounded == remoteScore { continue }

            switch (localRounded, remoteScore) {
            case (nil, .some(let r)):
                if baseScore == nil || baseScore != r {
                    actions.append(.pullRating(titleId: title.id, score: Double(r)))
                }
            case (.some(let l), nil):
                if baseScore == nil || baseScore != l {
                    actions.append(.pushRating(titleId: title.id, tmdbId: tmdbId, isSeries: title.isSeries, rating: l))
                }
            case (.some(let l), .some(let r)):
                if baseScore == l {
                    actions.append(.pullRating(titleId: title.id, score: Double(r)))
                } else if baseScore == r {
                    actions.append(.pushRating(titleId: title.id, tmdbId: tmdbId, isSeries: title.isSeries, rating: l))
                } else {
                    actions.append(.conflictRating(titleId: title.id, localScore: title.score ?? Double(l), remoteRating: r))
                }
            case (nil, nil):
                break
            }
        }

        // 4. 3-way diff watchlist
        var remoteWatchlistedTitles = Set<String>()
        for item in remote.watchlist {
            let key = "\(item.isSeries ? "tv" : "movie"):\(item.tmdbId)"
            guard let title = titleByKey[key] else {
                markMissing(tmdbId: item.tmdbId, isSeries: item.isSeries)
                continue
            }
            remoteWatchlistedTitles.insert(title.id)
        }

        for title in activeTitles {
            guard let tmdbId = title.tmdbId else { continue }
            let localWatchlisted = title.status == "planned" || title.queued == true
            let remoteWatchlisted = remoteWatchlistedTitles.contains(title.id)
            let baseWatchlisted = baseline.titles[title.id]?.watchlisted

            if localWatchlisted == remoteWatchlisted { continue }
            if remoteWatchlisted && !localWatchlisted {
                if baseWatchlisted != true && (eventsByTitle[title.id] ?? []).isEmpty {
                    actions.append(.pullWatchlist(titleId: title.id, status: "planned", queued: true))
                }
            } else if localWatchlisted && !remoteWatchlisted {
                if baseWatchlisted != false {
                    actions.append(.pushWatchlist(titleId: title.id, tmdbId: tmdbId, isSeries: title.isSeries))
                }
            }
        }

        return DirectTraktPlan(actions: actions)
    }

    /// Applies all pull actions from a `DirectTraktPlan` onto `workspace` in memory.
    public static func applyPulls(from plan: DirectTraktPlan, to workspace: Workspace, recordedAt: String) -> Workspace {
        var current = workspace
        for (index, action) in plan.actions.enumerated() {
            switch action {
            case .pullWatch(let titleId, let episodeId, let watchedAt):
                current = current.applying(.markWatch(
                    operationId: "trakt-direct-\(titleId)-\(episodeId ?? "movie")-\(index)",
                    titleId: titleId,
                    episodeId: episodeId,
                    watchedAt: watchedAt,
                    recordedAt: recordedAt,
                    rewatch: false
                ))
            case .pullRating(let titleId, let score):
                current = current.applying(.patchTitle(
                    titleId: titleId,
                    expectedVersion: nil,
                    status: nil,
                    score: score,
                    clearScore: false,
                    favorite: nil,
                    queued: nil,
                    notes: nil
                ))
            case .pullWatchlist(let titleId, let status, let queued):
                current = current.applying(.patchTitle(
                    titleId: titleId,
                    expectedVersion: nil,
                    status: status,
                    score: nil,
                    clearScore: false,
                    favorite: nil,
                    queued: queued,
                    notes: nil
                ))
            default:
                break
            }
        }
        return current
    }

    /// Builds a new `DirectTraktSyncBaseline` from the post-sync `Workspace` and `DirectTraktLastActivities`.
    public static func makeBaseline(workspace: Workspace, lastActivities: DirectTraktLastActivities?) -> DirectTraktSyncBaseline {
        let episodesByID = Dictionary(uniqueKeysWithValues: workspace.episodes.map { ($0.id, $0) })
        let eventsByTitle = Dictionary(grouping: workspace.activeEvents, by: \.titleId)
        var titles: [String: DirectTraktTitleBaseline] = [:]
        for title in workspace.activeTitles where title.tmdbId != nil {
            let events = eventsByTitle[title.id] ?? []
            var keys = Set<String>()
            if !title.isSeries {
                if events.contains(where: { $0.episodeId == nil }) { keys.insert("movie") }
            } else {
                for event in events {
                    if let epID = event.episodeId, let ep = episodesByID[epID] {
                        keys.insert("s\(ep.season)e\(ep.number)")
                    }
                }
            }
            titles[title.id] = DirectTraktTitleBaseline(
                titleId: title.id,
                score: title.score.map { Int($0.rounded()) },
                watchlisted: title.status == "planned" || title.queued == true,
                watchedEpisodeKeys: keys
            )
        }
        return DirectTraktSyncBaseline(lastActivities: lastActivities, titles: titles)
    }

    /// Builds the batched JSON payloads for `POST https://api.trakt.tv/sync/history`,
    /// `/sync/ratings`, and `/sync/watchlist` from a `DirectTraktPlan`.
    public static func buildPushPayloads(from plan: DirectTraktPlan) -> (
        history: [String: Any]?,
        ratings: [String: Any]?,
        watchlist: [String: Any]?
    ) {
        var historyMovies: [[String: Any]] = []
        var historyEpisodesByShow: [Int: (tmdbId: Int, seasons: [Int: [[String: Any]]])] = [:]
        var ratedMovies: [[String: Any]] = []
        var ratedShows: [[String: Any]] = []
        var watchlistMovies: [[String: Any]] = []
        var watchlistShows: [[String: Any]] = []

        for action in plan.pushes {
            switch action {
            case .pushWatch(_, let tmdbId, let isSeries, let season, let episode, let watchedAt):
                if !isSeries {
                    historyMovies.append([
                        "watched_at": watchedAt,
                        "ids": ["tmdb": tmdbId]
                    ])
                } else if let season, let episode {
                    var entry = historyEpisodesByShow[tmdbId] ?? (tmdbId: tmdbId, seasons: [:])
                    entry.seasons[season, default: []].append([
                        "number": episode,
                        "watched_at": watchedAt
                    ])
                    historyEpisodesByShow[tmdbId] = entry
                }
            case .pushRating(_, let tmdbId, let isSeries, let rating):
                let payload: [String: Any] = ["rating": rating, "ids": ["tmdb": tmdbId]]
                if isSeries { ratedShows.append(payload) } else { ratedMovies.append(payload) }
            case .pushWatchlist(_, let tmdbId, let isSeries):
                let payload: [String: Any] = ["ids": ["tmdb": tmdbId]]
                if isSeries { watchlistShows.append(payload) } else { watchlistMovies.append(payload) }
            default:
                break
            }
        }

        let historyShows: [[String: Any]] = historyEpisodesByShow.values
            .sorted { $0.tmdbId < $1.tmdbId }
            .map { show in
                let seasons: [[String: Any]] = show.seasons.keys.sorted().map { sNum in
                    ["number": sNum, "episodes": show.seasons[sNum] ?? []]
                }
                return ["ids": ["tmdb": show.tmdbId], "seasons": seasons]
            }

        let history: [String: Any]? = (historyMovies.isEmpty && historyShows.isEmpty)
            ? nil
            : ["movies": historyMovies, "shows": historyShows]
        let ratings: [String: Any]? = (ratedMovies.isEmpty && ratedShows.isEmpty)
            ? nil
            : ["movies": ratedMovies, "shows": ratedShows]
        let watchlist: [String: Any]? = (watchlistMovies.isEmpty && watchlistShows.isEmpty)
            ? nil
            : ["movies": watchlistMovies, "shows": watchlistShows]

        return (history, ratings, watchlist)
    }

    /// Parses Trakt's `GET https://api.trakt.tv/sync/last_activities` response JSON.
    public static func decodeLastActivities(from data: Data) throws -> DirectTraktLastActivities {
        struct RawBucket: Decodable {
            let watched_at: String?
            let rated_at: String?
            let watchlisted_at: String?
        }
        struct RawResponse: Decodable {
            let all: String
            let movies: RawBucket?
            let episodes: RawBucket?
            let shows: RawBucket?
        }
        let raw = try JSONDecoder().decode(RawResponse.self, from: data)
        return DirectTraktLastActivities(
            all: raw.all,
            moviesWatchedAt: raw.movies?.watched_at,
            moviesRatedAt: raw.movies?.rated_at,
            moviesWatchlistedAt: raw.movies?.watchlisted_at,
            episodesWatchedAt: raw.episodes?.watched_at,
            showsRatedAt: raw.shows?.rated_at,
            showsWatchlistedAt: raw.shows?.watchlisted_at
        )
    }
}
