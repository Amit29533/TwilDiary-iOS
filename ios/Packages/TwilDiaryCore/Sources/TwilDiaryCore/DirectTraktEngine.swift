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
}

/// Reads Trakt's `GET /sync/last_activities` reply (the connection test in Settings uses it).
public enum DirectTraktEngine {
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
