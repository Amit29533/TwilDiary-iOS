import Foundation
#if canImport(Security)
import Security
#endif

/// Controls how watch logging and library mutations are dispatched when a provider is connected.
public enum WatchLoggingMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Logs to the primary TwilDiary backend AND fans out to enabled direct provider APIs.
    case serverAndDirectAPI = "server_and_direct"
    /// Logs through the TwilDiary server only (default hosted behavior).
    case serverOnly = "server_only"
    /// Logs directly from the device to the provider API via the local outbox.
    case directAPIOnly = "direct_only"

    public var id: Self { self }

    public var label: String {
        switch self {
        case .serverAndDirectAPI: "Server & direct API"
        case .serverOnly: "Server sync only"
        case .directAPIOnly: "Direct device API"
        }
    }

    public var includesDirectAPI: Bool {
        self == .serverAndDirectAPI || self == .directAPIOnly
    }

    public var includesServerLogging: Bool {
        self == .serverAndDirectAPI || self == .serverOnly
    }
}

/// Configuration for an external sync provider (Trakt, Simkl, MDBList, WeTrakr).
public struct ExternalProviderConfig: Codable, Equatable, Identifiable, Sendable {
    public let provider: SyncProviderKind
    public var enabled: Bool
    public var loggingMethod: WatchLoggingMethod
    public var clientId: String?
    public var apiKey: String?
    public var accessToken: String?
    public var username: String?
    public var lastSyncedAt: String?

    public var id: SyncProviderKind { provider }

    public init(
        provider: SyncProviderKind,
        enabled: Bool = false,
        loggingMethod: WatchLoggingMethod = .serverAndDirectAPI,
        clientId: String? = nil,
        apiKey: String? = nil,
        accessToken: String? = nil,
        username: String? = nil,
        lastSyncedAt: String? = nil
    ) {
        self.provider = provider
        self.enabled = enabled
        self.loggingMethod = loggingMethod
        self.clientId = Self.trimmed(clientId)
        self.apiKey = Self.trimmed(apiKey)
        self.accessToken = Self.trimmed(accessToken)
        self.username = Self.trimmed(username)
        self.lastSyncedAt = Self.trimmed(lastSyncedAt)
    }

    /// True when the required API credentials for this provider have been entered.
    public var hasCredentials: Bool {
        switch provider {
        case .trakt, .wetrakr, .simkl:
            guard let cid = Self.trimmed(clientId), !cid.isEmpty else { return false }
            return true
        case .mdblist:
            guard let key = Self.trimmed(apiKey), !key.isEmpty else { return false }
            return true
        case .cloudflare:
            return true
        }
    }

    /// True when the provider has both an API key/client ID and an user access token (or API key for MDBList).
    public var isAuthenticated: Bool {
        switch provider {
        case .trakt, .wetrakr, .simkl:
            guard let cid = Self.trimmed(clientId), !cid.isEmpty,
                  let token = Self.trimmed(accessToken), !token.isEmpty else { return false }
            return true
        case .mdblist:
            return hasCredentials
        case .cloudflare:
            return true
        }
    }

    public var statusBadge: String {
        if enabled && isAuthenticated { return "Connected" }
        if hasCredentials { return "Configured" }
        return "Set up"
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Consolidated API & connection settings for all external metadata and sync providers.
public struct ProviderConnectionSettings: Codable, Equatable, Sendable {
    public var customTmdbToken: String?
    public var trakt: ExternalProviderConfig
    public var wetrakr: ExternalProviderConfig
    public var simkl: ExternalProviderConfig
    public var mdblist: ExternalProviderConfig

    public init(
        customTmdbToken: String? = nil,
        trakt: ExternalProviderConfig = ExternalProviderConfig(provider: .trakt),
        wetrakr: ExternalProviderConfig = ExternalProviderConfig(provider: .wetrakr),
        simkl: ExternalProviderConfig = ExternalProviderConfig(provider: .simkl),
        mdblist: ExternalProviderConfig = ExternalProviderConfig(provider: .mdblist)
    ) {
        self.customTmdbToken = customTmdbToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.customTmdbToken?.isEmpty == true { self.customTmdbToken = nil }
        self.trakt = trakt
        self.wetrakr = wetrakr
        self.simkl = simkl
        self.mdblist = mdblist
    }

    public func config(for provider: SyncProviderKind) -> ExternalProviderConfig {
        switch provider {
        case .trakt: trakt
        case .wetrakr: wetrakr
        case .simkl: simkl
        case .mdblist: mdblist
        case .cloudflare: ExternalProviderConfig(provider: .cloudflare, enabled: true)
        }
    }

    public mutating func setConfig(_ config: ExternalProviderConfig) {
        switch config.provider {
        case .trakt: trakt = config
        case .wetrakr: wetrakr = config
        case .simkl: simkl = config
        case .mdblist: mdblist = config
        case .cloudflare: break
        }
    }

    /// Returns all direct providers that are currently enabled, authenticated, and configured to receive watch logs.
    public var activeDirectLoggingProviders: Set<SyncProviderKind> {
        var result: Set<SyncProviderKind> = []
        for item in [trakt, wetrakr, simkl, mdblist] {
            if item.enabled && item.isAuthenticated && item.loggingMethod.includesDirectAPI {
                result.insert(item.provider)
            }
        }
        return result
    }
}

public protocol ProviderSecretStoring: Sendable {
    func readSecret(for account: String) throws -> String?
    @discardableResult func writeSecret(_ value: String?, for account: String) -> Bool
}

public final class KeychainProviderSecretStore: ProviderSecretStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.amit29533.TwilDiary.providers") {
        self.service = service
    }

    public func readSecret(for account: String) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProviderSettingsPersistenceError.secureStoreUnavailable }
        guard let data = result as? Data,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw ProviderSettingsPersistenceError.secureStoreUnavailable
        }
        return text
        #else
        throw ProviderSettingsPersistenceError.secureStoreUnavailable
        #endif
    }

    @discardableResult
    public func writeSecret(_ value: String?, for account: String) -> Bool {
        #if canImport(Security)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var insertQuery = baseQuery
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insertQuery as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }
}

public enum ProviderSettingsPersistenceError: LocalizedError, Sendable {
    case secureStoreUnavailable
    public var errorDescription: String? { "Provider credentials could not be saved securely. Unlock this device and try again. Your previous settings were kept." }
}

public protocol ProviderSettingsStoring: Sendable {
    func load() throws -> ProviderConnectionSettings
    func save(_ settings: ProviderConnectionSettings) throws
}

public final class UserDefaultsProviderSettingsStore: ProviderSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let secrets: (any ProviderSecretStoring)?
    public init(defaults: UserDefaults = .standard, key: String = "twildiary.provider.connection.settings", secrets: (any ProviderSecretStoring)? = KeychainProviderSecretStore()) {
        self.defaults = defaults; self.key = key; self.secrets = secrets
    }
    public func load() throws -> ProviderConnectionSettings {
        let metadata = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ProviderConnectionSettings.self, from: $0) }
        var decoded = metadata ?? ProviderConnectionSettings()
        guard let secrets else {
            guard Self.stripped(decoded) == decoded else { throw ProviderSettingsPersistenceError.secureStoreUnavailable }
            return decoded
        }
        if let sealed = try secrets.readSecret(for: "\(key).credentials.v2") {
            let stored = try JSONDecoder().decode(ProviderConnectionSettings.self, from: Data(sealed.utf8))
            // The atomic envelope owns credentials AND their matching client/configuration.
            // A crash between Keychain and preferences writes must not combine two accounts.
            defaults.set(try JSONEncoder().encode(Self.stripped(stored)), forKey: key)
            return stored
        }
        // One-time migration: do not claim success or erase the old copy unless the atomic Keychain write succeeds.
        if let token = try secrets.readSecret(for: "\(key).tmdb.token") { decoded.customTmdbToken = token }
        for provider in [SyncProviderKind.trakt, .wetrakr, .simkl, .mdblist] {
            var config = decoded.config(for: provider)
            if let token = try secrets.readSecret(for: "\(key).\(provider.rawValue).accessToken") { config.accessToken = token }
            if let token = try secrets.readSecret(for: "\(key).\(provider.rawValue).apiKey") { config.apiKey = token }
            decoded.setConfig(config)
        }
        if Self.stripped(decoded) != decoded { try save(decoded) }
        return decoded
    }
    public func save(_ settings: ProviderConnectionSettings) throws {
        let sanitized = Self.stripped(settings)
        let metadata = try JSONEncoder().encode(sanitized)
        let sealed = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        if let secrets {
            // A single Keychain item makes all provider credential updates atomic, including explicit clears.
            guard secrets.writeSecret(sealed, for: "\(key).credentials.v2") else { throw ProviderSettingsPersistenceError.secureStoreUnavailable }
        } else if sanitized != settings { throw ProviderSettingsPersistenceError.secureStoreUnavailable }
        defaults.set(metadata, forKey: key)
    }
    private static func stripped(_ settings: ProviderConnectionSettings) -> ProviderConnectionSettings {
        var value = settings
        value.customTmdbToken = nil
        for provider in [SyncProviderKind.trakt, .wetrakr, .simkl, .mdblist] {
            var config = value.config(for: provider)
            config.accessToken = nil; config.apiKey = nil
            value.setConfig(config)
        }
        return value
    }
}

/// Simkl (`https://api.simkl.com`) activity timestamps and payload normalization engine.
public enum SimklSyncEngine {
    public struct ActivityTimestamps: Codable, Equatable, Sendable {
        public let all: String
        public let tvShowsAll: String?
        public let animeAll: String?
        public let moviesAll: String?

        public init(all: String, tvShowsAll: String? = nil, animeAll: String? = nil, moviesAll: String? = nil) {
            self.all = all
            self.tvShowsAll = tvShowsAll
            self.animeAll = animeAll
            self.moviesAll = moviesAll
        }

        public func hasChanges(since previous: ActivityTimestamps?) -> Bool {
            guard let previous else { return true }
            return previous.all != all
                || previous.tvShowsAll != tvShowsAll
                || previous.animeAll != animeAll
                || previous.moviesAll != moviesAll
        }
    }

    public static func decodeActivities(from data: Data) throws -> ActivityTimestamps {
        struct Bucket: Decodable { let all: String? }
        struct Raw: Decodable {
            let all: String
            let tv_shows: Bucket?
            let anime: Bucket?
            let movies: Bucket?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return ActivityTimestamps(
            all: raw.all,
            tvShowsAll: raw.tv_shows?.all,
            animeAll: raw.anime?.all,
            moviesAll: raw.movies?.all
        )
    }

    /// Normalizes Simkl's `GET /sync/all-items/` response (`movies`, `shows`, `anime`) into
    /// `DirectTraktRemoteSnapshot` so the 3-way diff engine (`DirectTraktEngine.plan`) works identically.
    public static func decodeAllItems(from data: Data) throws -> DirectTraktRemoteSnapshot {
        struct IDs: Decodable {
            let tmdb: StringOrInt?
        }
        struct EpisodeItem: Decodable {
            let number: Int
            let watched_at: String?
        }
        struct SeasonItem: Decodable {
            let number: Int
            let episodes: [EpisodeItem]?
        }
        struct MediaNode: Decodable {
            let ids: IDs?
        }
        struct Item: Decodable {
            let last_watched_at: String?
            let user_rated_at: String?
            let added_to_watchlist_at: String?
            let user_rating: Int?
            let status: String?
            let movie: MediaNode?
            let show: MediaNode?
            let seasons: [SeasonItem]?
        }
        struct RawAllItems: Decodable {
            let movies: [Item]?
            let shows: [Item]?
            let anime: [Item]?
        }
        let raw = try JSONDecoder().decode(RawAllItems.self, from: data)
        var plays: [DirectTraktWatchPlay] = []
        var ratings: [DirectTraktRatingItem] = []
        var watchlist: [DirectTraktWatchlistItem] = []

        for item in raw.movies ?? [] {
            guard let tmdbId = item.movie?.ids?.tmdb?.intValue, tmdbId > 0 else { continue }
            if item.status == "completed", let stamp = item.last_watched_at {
                plays.append(DirectTraktWatchPlay(tmdbId: tmdbId, isSeries: false, watchedAt: stamp))
            }
            if let rating = item.user_rating, (1...10).contains(rating) {
                ratings.append(DirectTraktRatingItem(
                    tmdbId: tmdbId,
                    isSeries: false,
                    rating: rating,
                    ratedAt: item.user_rated_at ?? item.last_watched_at ?? "2026-01-01T00:00:00Z"
                ))
            }
            if item.status == "plantowatch" {
                watchlist.append(DirectTraktWatchlistItem(
                    tmdbId: tmdbId,
                    isSeries: false,
                    listedAt: item.added_to_watchlist_at ?? "2026-01-01T00:00:00Z"
                ))
            }
        }

        for item in (raw.shows ?? []) + (raw.anime ?? []) {
            guard let tmdbId = item.show?.ids?.tmdb?.intValue, tmdbId > 0 else { continue }
            for season in item.seasons ?? [] {
                for ep in season.episodes ?? [] {
                    plays.append(DirectTraktWatchPlay(
                        tmdbId: tmdbId,
                        isSeries: true,
                        season: season.number,
                        episode: ep.number,
                        watchedAt: ep.watched_at ?? item.last_watched_at ?? "2026-01-01T00:00:00Z"
                    ))
                }
            }
            if let rating = item.user_rating, (1...10).contains(rating) {
                ratings.append(DirectTraktRatingItem(
                    tmdbId: tmdbId,
                    isSeries: true,
                    rating: rating,
                    ratedAt: item.user_rated_at ?? item.last_watched_at ?? "2026-01-01T00:00:00Z"
                ))
            }
            if item.status == "plantowatch" {
                watchlist.append(DirectTraktWatchlistItem(
                    tmdbId: tmdbId,
                    isSeries: true,
                    listedAt: item.added_to_watchlist_at ?? "2026-01-01T00:00:00Z"
                ))
            }
        }

        return DirectTraktRemoteSnapshot(plays: plays, ratings: ratings, watchlist: watchlist)
    }

    /// Builds Simkl `POST /sync/history`, `/sync/ratings`, and `/sync/add-to-list` payloads from a `DirectTraktPlan`.
    public static func buildPushPayloads(from plan: DirectTraktPlan) -> (
        history: [String: Any]?,
        ratings: [String: Any]?,
        watchlist: [String: Any]?
    ) {
        let base = DirectTraktEngine.buildPushPayloads(from: plan)
        guard let rawWatchlist = base.watchlist else {
            return (base.history, base.ratings, nil)
        }
        let movies = (rawWatchlist["movies"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
            var copy = item; copy["to"] = "plantowatch"; return copy
        }
        let shows = (rawWatchlist["shows"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
            var copy = item; copy["to"] = "plantowatch"; return copy
        }
        return (base.history, base.ratings, ["movies": movies, "shows": shows])
    }
}

/// MDBList (`https://api.mdblist.com`) multi-source public rating aggregator & sync payload builder.
public enum MDBListSyncEngine {
    public struct SourceScore: Codable, Equatable, Sendable {
        public let source: String
        public let value: Double?
        public let score: Double?
        public let votes: Int?

        public init(source: String, value: Double?, score: Double?, votes: Int?) {
            self.source = source
            self.value = value
            self.score = score
            self.votes = votes
        }
    }

    public struct RatingSummary: Codable, Equatable, Sendable {
        public let tmdbId: Int
        public let isSeries: Bool
        public let aggregatedScore: Double?
        public let ratings: [SourceScore]

        public init(tmdbId: Int, isSeries: Bool, aggregatedScore: Double?, ratings: [SourceScore]) {
            self.tmdbId = tmdbId
            self.isSeries = isSeries
            self.aggregatedScore = aggregatedScore
            self.ratings = ratings
        }

        public func score(for source: String) -> Double? {
            ratings.first { $0.source.lowercased() == source.lowercased() }?.score
        }
    }

    public static func decodeRatingSummary(from data: Data, tmdbId: Int, isSeries: Bool) throws -> RatingSummary {
        struct RawRating: Decodable {
            let source: String
            let value: Double?
            let score: Double?
            let votes: Int?
        }
        struct RawResponse: Decodable {
            let score: Double?
            let ratings: [RawRating]?
        }
        let raw = try JSONDecoder().decode(RawResponse.self, from: data)
        let ratings = (raw.ratings ?? []).map {
            SourceScore(source: $0.source, value: $0.value, score: $0.score, votes: $0.votes)
        }
        return RatingSummary(tmdbId: tmdbId, isSeries: isSeries, aggregatedScore: raw.score, ratings: ratings)
    }

    public static func buildWatchedPayload(from plan: DirectTraktPlan) -> [String: Any]? {
        DirectTraktEngine.buildPushPayloads(from: plan).history
    }

    public static func buildWatchlistPayload(from plan: DirectTraktPlan) -> [String: Any]? {
        DirectTraktEngine.buildPushPayloads(from: plan).watchlist
    }
}

/// WeTrakr (`https://api.wetrakr.com`) full two-way sync engine (activities, compact row normalization,
/// decimal ratings, favorites, dropped shows, and idempotent batched writes).
public enum WeTrakrSyncEngine {
    public struct ActivitySection: Codable, Equatable, Sendable {
        public let all: String?
        public let ratedAt: String?
        public let favoritedAt: String?
        public let planningAt: String?
        public let watchedAt: String?
        public let droppedAt: String?
        public let removedAt: String?
        public let playbackAt: String?

        public init(
            all: String? = nil,
            ratedAt: String? = nil,
            favoritedAt: String? = nil,
            planningAt: String? = nil,
            watchedAt: String? = nil,
            droppedAt: String? = nil,
            removedAt: String? = nil,
            playbackAt: String? = nil
        ) {
            self.all = all
            self.ratedAt = ratedAt
            self.favoritedAt = favoritedAt
            self.planningAt = planningAt
            self.watchedAt = watchedAt
            self.droppedAt = droppedAt
            self.removedAt = removedAt
            self.playbackAt = playbackAt
        }
    }

    public struct ActivityTimestamps: Codable, Equatable, Sendable {
        public let movies: ActivitySection
        public let shows: ActivitySection
        public let episodes: ActivitySection
        public let ratings: ActivitySection
        public let favorites: ActivitySection

        public init(
            movies: ActivitySection = ActivitySection(),
            shows: ActivitySection = ActivitySection(),
            episodes: ActivitySection = ActivitySection(),
            ratings: ActivitySection = ActivitySection(),
            favorites: ActivitySection = ActivitySection()
        ) {
            self.movies = movies
            self.shows = shows
            self.episodes = episodes
            self.ratings = ratings
            self.favorites = favorites
        }

        public struct ChangedDomains: Equatable, Sendable {
            public let watchedMovies: Bool
            public let watchedEpisodes: Bool
            public let watchlist: Bool
            public let dropped: Bool
            public let ratings: Bool
            public let favorites: Bool
            public var anyChanged: Bool {
                watchedMovies || watchedEpisodes || watchlist || dropped || ratings || favorites
            }
        }

        public func changedDomains(since previous: ActivityTimestamps?) -> ChangedDomains {
            guard let previous else {
                return ChangedDomains(
                    watchedMovies: true,
                    watchedEpisodes: true,
                    watchlist: true,
                    dropped: true,
                    ratings: true,
                    favorites: true
                )
            }
            let watchedMovies = movies.watchedAt != previous.movies.watchedAt
            let watchedEpisodes = episodes.watchedAt != previous.episodes.watchedAt
            let watchlist = movies.planningAt != previous.movies.planningAt
                || movies.removedAt != previous.movies.removedAt
                || shows.planningAt != previous.shows.planningAt
                || shows.removedAt != previous.shows.removedAt
            let dropped = shows.droppedAt != previous.shows.droppedAt
                || shows.removedAt != previous.shows.removedAt
            let ratingsChanged = ratings.all != previous.ratings.all
            let favoritesChanged = favorites.all != previous.favorites.all
            return ChangedDomains(
                watchedMovies: watchedMovies,
                watchedEpisodes: watchedEpisodes,
                watchlist: watchlist,
                dropped: dropped,
                ratings: ratingsChanged,
                favorites: favoritesChanged
            )
        }
    }

    public struct CompactRow: Codable, Equatable, Sendable {
        public let type: String?
        public let id: Int?
        public let tmdbId: Int?
        public let showTmdbId: Int?
        public let seasonNumber: Int?
        public let number: Int?
        public let status: String?
        public let trackedAt: String?
        public let lastWatchedAt: String?
        public let watchedAt: String?
        public let plays: Int?
        public let rating: Double?
        public let ratedAt: String?
        public let favoritedAt: String?
        public let removedAt: String?
        public let progressPercent: Double?

        public init(
            type: String? = nil,
            id: Int? = nil,
            tmdbId: Int? = nil,
            showTmdbId: Int? = nil,
            seasonNumber: Int? = nil,
            number: Int? = nil,
            status: String? = nil,
            trackedAt: String? = nil,
            lastWatchedAt: String? = nil,
            watchedAt: String? = nil,
            plays: Int? = nil,
            rating: Double? = nil,
            ratedAt: String? = nil,
            favoritedAt: String? = nil,
            removedAt: String? = nil,
            progressPercent: Double? = nil
        ) {
            self.type = type
            self.id = id
            self.tmdbId = tmdbId
            self.showTmdbId = showTmdbId
            self.seasonNumber = seasonNumber
            self.number = number
            self.status = status
            self.trackedAt = trackedAt
            self.lastWatchedAt = lastWatchedAt
            self.watchedAt = watchedAt
            self.plays = plays
            self.rating = rating
            self.ratedAt = ratedAt
            self.favoritedAt = favoritedAt
            self.removedAt = removedAt
            self.progressPercent = progressPercent
        }
    }

    public struct FavoriteState: Codable, Equatable, Sendable {
        public let tmdbId: Int
        public let isSeries: Bool
        public let favoritedAt: String
        public let removed: Bool

        public init(tmdbId: Int, isSeries: Bool, favoritedAt: String, removed: Bool = false) {
            self.tmdbId = tmdbId
            self.isSeries = isSeries
            self.favoritedAt = favoritedAt
            self.removed = removed
        }
    }

    public struct NormalizedWeTrakrSnapshot: Codable, Equatable, Sendable {
        public let remote: DirectTraktRemoteSnapshot
        public let decimalRatings: [String: Double]
        public let favorites: [FavoriteState]
        public let droppedShowTmdbIds: [Int]

        public init(
            remote: DirectTraktRemoteSnapshot,
            decimalRatings: [String: Double] = [:],
            favorites: [FavoriteState] = [],
            droppedShowTmdbIds: [Int] = []
        ) {
            self.remote = remote
            self.decimalRatings = decimalRatings
            self.favorites = favorites
            self.droppedShowTmdbIds = droppedShowTmdbIds
        }
    }

    public static func decodeActivities(from data: Data) throws -> ActivityTimestamps {
        struct RawSection: Decodable {
            let all: String?
            let last_rated_at: String?
            let last_favorited_at: String?
            let last_tracking_planning_at: String?
            let last_tracking_watched_at: String?
            let last_tracking_dropped_at: String?
            let last_tracking_removed_at: String?
            let last_playback_at: String?
            var section: ActivitySection {
                ActivitySection(
                    all: all,
                    ratedAt: last_rated_at,
                    favoritedAt: last_favorited_at,
                    planningAt: last_tracking_planning_at,
                    watchedAt: last_tracking_watched_at,
                    droppedAt: last_tracking_dropped_at,
                    removedAt: last_tracking_removed_at,
                    playbackAt: last_playback_at
                )
            }
        }
        struct RawResponse: Decodable {
            let movies: RawSection?
            let shows: RawSection?
            let episodes: RawSection?
            let ratings: RawSection?
            let favorites: RawSection?
        }
        let raw = try JSONDecoder().decode(RawResponse.self, from: data)
        return ActivityTimestamps(
            movies: raw.movies?.section ?? ActivitySection(),
            shows: raw.shows?.section ?? ActivitySection(),
            episodes: raw.episodes?.section ?? ActivitySection(),
            ratings: raw.ratings?.section ?? ActivitySection(),
            favorites: raw.favorites?.section ?? ActivitySection()
        )
    }

    public static func decodeCompactRows(from data: Data) throws -> [CompactRow] {
        struct RawIDs: Decodable {
            let tmdb: StringOrInt?
        }
        struct RawRow: Decodable {
            let type: String?
            let id: Int?
            let ids: RawIDs?
            let show_ids: RawIDs?
            let season_number: Int?
            let number: Int?
            let status: String?
            let tracked_at: String?
            let last_watched_at: String?
            let watched_at: String?
            let plays: Int?
            let rating: Double?
            let rated_at: String?
            let favorited_at: String?
            let removed_at: String?
            let progress_percent: Double?
        }
        let rawRows = try JSONDecoder().decode([RawRow].self, from: data)
        return rawRows.map {
            CompactRow(
                type: $0.type,
                id: $0.id,
                tmdbId: $0.ids?.tmdb?.intValue,
                showTmdbId: $0.show_ids?.tmdb?.intValue,
                seasonNumber: $0.season_number,
                number: $0.number,
                status: $0.status,
                trackedAt: $0.tracked_at,
                lastWatchedAt: $0.last_watched_at,
                watchedAt: $0.watched_at,
                plays: $0.plays,
                rating: $0.rating,
                ratedAt: $0.rated_at,
                favoritedAt: $0.favorited_at,
                removedAt: $0.removed_at,
                progressPercent: $0.progress_percent
            )
        }
    }

    public static func normalizeSnapshot(
        watchedMovies: [CompactRow] = [],
        watchedEpisodes: [CompactRow] = [],
        planningMovies: [CompactRow] = [],
        planningShows: [CompactRow] = [],
        ratingsMovies: [CompactRow] = [],
        ratingsShows: [CompactRow] = [],
        favoritesMovies: [CompactRow] = [],
        favoritesShows: [CompactRow] = [],
        droppedShows: [CompactRow] = []
    ) -> NormalizedWeTrakrSnapshot {
        var plays: [DirectTraktWatchPlay] = []
        var ratings: [DirectTraktRatingItem] = []
        var watchlist: [DirectTraktWatchlistItem] = []
        var decimalRatings: [String: Double] = [:]
        var favorites: [FavoriteState] = []
        var droppedShowTmdbIds: [Int] = []

        for row in watchedMovies {
            guard let tmdbId = row.tmdbId, tmdbId > 0 else { continue }
            let stamp = row.lastWatchedAt ?? row.watchedAt ?? row.trackedAt ?? "2026-01-01T00:00:00Z"
            plays.append(DirectTraktWatchPlay(tmdbId: tmdbId, isSeries: false, watchedAt: stamp))
        }

        for row in watchedEpisodes {
            guard let tmdbId = row.showTmdbId ?? row.tmdbId, tmdbId > 0,
                  let season = row.seasonNumber, let episode = row.number, episode > 0 else { continue }
            let stamp = row.lastWatchedAt ?? row.watchedAt ?? row.trackedAt ?? "2026-01-01T00:00:00Z"
            plays.append(DirectTraktWatchPlay(tmdbId: tmdbId, isSeries: true, season: season, episode: episode, watchedAt: stamp))
        }

        for (rows, isSeries) in [(planningMovies, false), (planningShows, true)] {
            for row in rows where row.status != "removed" {
                guard let tmdbId = row.tmdbId, tmdbId > 0 else { continue }
                watchlist.append(DirectTraktWatchlistItem(
                    tmdbId: tmdbId,
                    isSeries: isSeries,
                    listedAt: row.trackedAt ?? "2026-01-01T00:00:00Z"
                ))
            }
        }

        for (rows, isSeries) in [(ratingsMovies, false), (ratingsShows, true)] {
            for row in rows where row.status != "removed" {
                guard let tmdbId = row.tmdbId, tmdbId > 0,
                      let rawRating = row.rating, rawRating > 0, rawRating <= 10 else { continue }
                let roundedOneDecimal = (rawRating * 10).rounded() / 10
                let key = "\(isSeries ? "tv" : "movie"):\(tmdbId)"
                decimalRatings[key] = roundedOneDecimal
                let intRating = max(1, min(10, Int((rawRating + 0.5).rounded(.down))))
                ratings.append(DirectTraktRatingItem(
                    tmdbId: tmdbId,
                    isSeries: isSeries,
                    rating: intRating,
                    ratedAt: row.ratedAt ?? "2026-01-01T00:00:00Z"
                ))
            }
        }

        for (rows, isSeries) in [(favoritesMovies, false), (favoritesShows, true)] {
            for row in rows {
                guard let tmdbId = row.tmdbId, tmdbId > 0 else { continue }
                let removed = row.status == "removed"
                favorites.append(FavoriteState(
                    tmdbId: tmdbId,
                    isSeries: isSeries,
                    favoritedAt: (removed ? row.removedAt : row.favoritedAt) ?? row.favoritedAt ?? "2026-01-01T00:00:00Z",
                    removed: removed
                ))
            }
        }

        for row in droppedShows where row.status != "removed" {
            guard let tmdbId = row.tmdbId, tmdbId > 0 else { continue }
            droppedShowTmdbIds.append(tmdbId)
        }

        return NormalizedWeTrakrSnapshot(
            remote: DirectTraktRemoteSnapshot(plays: plays, ratings: ratings, watchlist: watchlist),
            decimalRatings: decimalRatings,
            favorites: favorites,
            droppedShowTmdbIds: droppedShowTmdbIds
        )
    }

    /// Applies a `NormalizedWeTrakrSnapshot` onto `workspace` in memory, preserving WeTrakr's decimal ratings,
    /// favorite flags, and dropped show statuses on top of the 3-way diff pulls.
    public static func applySnapshot(
        _ snapshot: NormalizedWeTrakrSnapshot,
        to workspace: Workspace,
        baseline: DirectTraktSyncBaseline = DirectTraktSyncBaseline(),
        recordedAt: String
    ) -> Workspace {
        let plan = DirectTraktEngine.plan(workspace: workspace, remote: snapshot.remote, baseline: baseline)
        var current = DirectTraktEngine.applyPulls(from: plan, to: workspace, recordedAt: recordedAt)

        var titleByKey: [String: MediaTitle] = [:]
        for title in current.activeTitles {
            guard let tmdbId = title.tmdbId else { continue }
            let key = "\(title.isSeries ? "tv" : "movie"):\(tmdbId)"
            if titleByKey[key] == nil { titleByKey[key] = title }
        }

        let pulledRatingTitleIDs = Set(plan.pulls.compactMap { action -> String? in
            if case .pullRating(let titleId, _) = action { return titleId }
            return nil
        })

        for (key, decimalScore) in snapshot.decimalRatings {
            guard let title = titleByKey[key],
                  pulledRatingTitleIDs.contains(title.id),
                  let idx = current.titles.firstIndex(where: { $0.id == title.id }) else { continue }
            current.titles[idx].score = decimalScore
        }

        for fav in snapshot.favorites {
            let key = "\(fav.isSeries ? "tv" : "movie"):\(fav.tmdbId)"
            guard let title = titleByKey[key], title.favorite == fav.removed else { continue }
            current = current.applying(.patchTitle(
                titleId: title.id,
                expectedVersion: nil,
                status: nil,
                score: nil,
                clearScore: false,
                favorite: !fav.removed,
                queued: nil,
                notes: nil
            ))
        }

        for tmdbId in snapshot.droppedShowTmdbIds {
            guard let title = titleByKey["tv:\(tmdbId)"], title.status != "dropped" else { continue }
            current = current.applying(.patchTitle(
                titleId: title.id,
                expectedVersion: nil,
                status: "dropped",
                score: nil,
                clearScore: false,
                favorite: nil,
                queued: false,
                notes: nil
            ))
        }

        return current
    }

    /// Builds WeTrakr's batched JSON bodies (`POST /sync/tracking`, `/sync/ratings`, `/sync/favorites`).
    public static func buildPushPayloads(
        from plan: DirectTraktPlan,
        decimalScoresByTitle: [String: Double] = [:],
        favorites: [(tmdbId: Int, isSeries: Bool)] = [],
        droppedShowTmdbIds: [Int] = [],
        allowRewatch: Bool = true
    ) -> (
        history: [String: Any]?,
        ratings: [String: Any]?,
        watchlist: [String: Any]?,
        favorites: [String: Any]?
    ) {
        var watchedMovies: [[String: Any]] = []
        var watchedShowsByTmdb: [Int: [Int: [[String: Any]]]] = [:]
        var ratedMovies: [[String: Any]] = []
        var ratedShows: [[String: Any]] = []
        var planningMovies: [[String: Any]] = []
        var planningShows: [[String: Any]] = []

        for action in plan.pushes {
            switch action {
            case .pushWatch(_, let tmdbId, let isSeries, let season, let episode, let watchedAt):
                if !isSeries {
                    watchedMovies.append([
                        "status": "watched",
                        "tracked_at": watchedAt,
                        "ids": ["tmdb": tmdbId]
                    ])
                } else if let season, let episode {
                    watchedShowsByTmdb[tmdbId, default: [:]][season, default: []].append([
                        "number": episode,
                        "status": "watched",
                        "tracked_at": watchedAt
                    ])
                }
            case .pushRating(let titleId, let tmdbId, let isSeries, let rating):
                let score = decimalScoresByTitle[titleId] ?? Double(rating)
                let entry: [String: Any] = ["rating": score, "ids": ["tmdb": tmdbId]]
                if isSeries { ratedShows.append(entry) } else { ratedMovies.append(entry) }
            case .pushWatchlist(_, let tmdbId, let isSeries):
                let entry: [String: Any] = ["status": "planning", "ids": ["tmdb": tmdbId]]
                if isSeries { planningShows.append(entry) } else { planningMovies.append(entry) }
            default:
                break
            }
        }

        for tmdbId in droppedShowTmdbIds {
            planningShows.append(["status": "dropped", "ids": ["tmdb": tmdbId]])
        }

        let watchedShows: [[String: Any]] = watchedShowsByTmdb.keys.sorted().map { tmdbId in
            let seasonsMap = watchedShowsByTmdb[tmdbId] ?? [:]
            let seasons: [[String: Any]] = seasonsMap.keys.sorted().map { sNum in
                ["number": sNum, "episodes": seasonsMap[sNum] ?? []]
            }
            return ["ids": ["tmdb": tmdbId], "seasons": seasons]
        }

        let history: [String: Any]? = (watchedMovies.isEmpty && watchedShows.isEmpty)
            ? nil
            : [
                "movies": watchedMovies,
                "shows": watchedShows,
                "allow_rewatch": allowRewatch
            ]
        let ratings: [String: Any]? = (ratedMovies.isEmpty && ratedShows.isEmpty)
            ? nil
            : ["movies": ratedMovies, "shows": ratedShows]
        let watchlist: [String: Any]? = (planningMovies.isEmpty && planningShows.isEmpty)
            ? nil
            : ["movies": planningMovies, "shows": planningShows]

        let favMovies = favorites.filter { !$0.isSeries }.map { ["ids": ["tmdb": $0.tmdbId]] }
        let favShows = favorites.filter { $0.isSeries }.map { ["ids": ["tmdb": $0.tmdbId]] }
        let favoritesPayload: [String: Any]? = (favMovies.isEmpty && favShows.isEmpty)
            ? nil
            : ["movies": favMovies, "shows": favShows]

        return (history, ratings, watchlist, favoritesPayload)
    }

    public static func idempotencyKey(path: String, entryIDs: [String]) -> String {
        let joined = ([path] + entryIDs.sorted()).joined(separator: "|")
        var hash: UInt64 = 14695981039346656037
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "wetrakr-%016llx", hash)
    }
}

/// Universal external tracker bridge (WeTrakr / Cinopsys / multi-provider outbox fan-out).
public enum MultiProviderOutboxDispatcher {
    public struct ProviderBatch {
        public let provider: SyncProviderKind
        public let entryIDs: [String]
        public let historyPayload: [String: Any]?
        public let ratingsPayload: [String: Any]?
        public let watchlistPayload: [String: Any]?
        public let favoritesPayload: [String: Any]?
        public let idempotencyKey: String?
    }

    /// Compiles pending outbox mutations for an external provider (`.trakt`, `.simkl`, `.mdblist`, `.wetrakr`)
    /// into batched request payloads using TMDb identities from `workspace`.
    public static func prepareBatch(
        for provider: SyncProviderKind,
        from queue: SyncOutboxQueue,
        in workspace: Workspace
    ) -> ProviderBatch? {
        guard provider != .cloudflare else { return nil }
        var ids: [String] = []
        var payloads: [String: [String: [[String: Any]]]] = [:]
        for entry in queue.pending(for: provider) where !entry.pendingProviders.contains(.cloudflare) {
            let plan = ProviderDeliveryPlanner.plan(entry, provider: provider, in: workspace)
            guard plan.blocked.isEmpty, !plan.deliveries.isEmpty,
                  !plan.deliveries.contains(where: { $0.path.hasSuffix("/remove") }) else { continue }
            ids.append(entry.id)
            for delivery in plan.deliveries {
                let bucket = delivery.key == "status" ? "watchlist" : delivery.key
                for slot in ["movies", "shows"] {
                    payloads[bucket, default: [:]][slot, default: []].append(contentsOf: delivery.body[slot] as? [[String: Any]] ?? [])
                }
            }
        }
        guard !ids.isEmpty else { return nil }
        func body(_ key: String) -> [String: Any]? { payloads[key].map { $0 as [String: Any] } }
        return ProviderBatch(provider: provider, entryIDs: ids, historyPayload: body("history"), ratingsPayload: body("rating"), watchlistPayload: body("watchlist"), favoritesPayload: body("favorite"), idempotencyKey: provider == .wetrakr ? WeTrakrSyncEngine.idempotencyKey(path: "/sync", entryIDs: ids) : nil)
    }
}

/// Cross-platform state payload for iOS Dynamic Island (`ActivityKit`) & background sync progress.
public struct SyncLiveActivityState: Codable, Equatable, Hashable, Sendable {
    public enum Phase: String, Codable, Equatable, Hashable, Sendable {
        case scanning
        case importing
        case syncingProvider
        case flushingOutbox
        case paused
        case completed
        case failed
    }

    public let provider: SyncProviderKind
    public let phase: Phase
    public let title: String
    public let subtitle: String
    public let completedCount: Int
    public let totalCount: Int
    public let isBackgrounded: Bool

    public var fraction: Double {
        guard totalCount > 0 else { return phase == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(completedCount) / Double(totalCount)))
    }

    public var percent: Int {
        Int((fraction * 100).rounded(.down))
    }

    public var compactBadge: String {
        switch provider {
        case .trakt: "TK"
        case .wetrakr: "WT"
        case .simkl: "SK"
        case .mdblist: "ML"
        case .cloudflare: "TD"
        }
    }

    public var providerDisplayName: String {
        switch provider {
        case .trakt: "Trakt"
        case .wetrakr: "WeTrakr"
        case .simkl: "Simkl"
        case .mdblist: "MDBList"
        case .cloudflare: "TwilDiary"
        }
    }

    public init(
        provider: SyncProviderKind,
        phase: Phase,
        title: String,
        subtitle: String,
        completedCount: Int,
        totalCount: Int,
        isBackgrounded: Bool = false
    ) {
        self.provider = provider
        self.phase = phase
        self.title = title
        self.subtitle = subtitle
        self.completedCount = max(0, completedCount)
        self.totalCount = max(0, totalCount)
        self.isBackgrounded = isBackgrounded
    }

    /// Builds a Dynamic Island `SyncLiveActivityState` from a `TraktSync` snapshot.
    public static func fromTrakt(_ sync: TraktSync, paused: Bool = false, isBackgrounded: Bool = false) -> SyncLiveActivityState? {
        guard let run = sync.run else { return nil }
        if run.state == "building" {
            let scan = TraktScanProgress(run: run)
            let done = scan.completed ?? max(0, run.page - 1)
            let total = scan.total ?? max(done, run.progress)
            return SyncLiveActivityState(
                provider: .trakt,
                phase: paused ? .paused : .scanning,
                title: paused ? "Trakt scan paused" : scan.title,
                subtitle: scan.detail,
                completedCount: done,
                totalCount: total,
                isBackgrounded: isBackgrounded
            )
        }
        let applied = max(0, sync.counts["applied"] ?? 0)
        let skipped = max(0, sync.counts["skipped"] ?? 0)
        let remaining = max(0, (sync.counts["pending"] ?? 0) + (sync.counts["failed"] ?? 0) + (sync.counts["uncertain"] ?? 0))
        let finished = applied + skipped
        let total = finished + remaining
        if run.state == "complete" {
            return SyncLiveActivityState(
                provider: .trakt,
                phase: .completed,
                title: "Trakt sync complete",
                subtitle: "\(applied.formatted()) saved · \(skipped.formatted()) skipped",
                completedCount: total,
                totalCount: max(1, total),
                isBackgrounded: isBackgrounded
            )
        }
        guard sync.reviewing else { return nil }
        return SyncLiveActivityState(
            provider: .trakt,
            phase: paused ? .paused : .importing,
            title: paused ? "Trakt import paused" : (isBackgrounded ? "Background Trakt import" : "Importing Trakt changes"),
            subtitle: "\(applied.formatted()) saved · \(remaining.formatted()) remaining",
            completedCount: finished,
            totalCount: total,
            isBackgrounded: isBackgrounded
        )
    }

    /// Builds a Dynamic Island `SyncLiveActivityState` for an external provider outbox/sync batch.
    public static func forProviderBatch(
        provider: SyncProviderKind,
        completed: Int,
        total: Int,
        phase: Phase = .flushingOutbox,
        isBackgrounded: Bool = false
    ) -> SyncLiveActivityState {
        let name: String = switch provider {
        case .trakt: "Trakt"
        case .wetrakr: "WeTrakr"
        case .simkl: "Simkl"
        case .mdblist: "MDBList"
        case .cloudflare: "TwilDiary"
        }
        let title: String = switch phase {
        case .completed: "\(name) sync complete"
        case .paused: "\(name) sync paused"
        case .failed: "\(name) sync needs attention"
        default: isBackgrounded ? "Background \(name) sync" : "Syncing \(name)"
        }
        let remaining = max(0, total - completed)
        let subtitle = phase == .completed
            ? "\(completed.formatted()) items synced"
            : "\(completed.formatted()) synced · \(remaining.formatted()) remaining"
        return SyncLiveActivityState(
            provider: provider,
            phase: phase,
            title: title,
            subtitle: subtitle,
            completedCount: completed,
            totalCount: total,
            isBackgrounded: isBackgrounded
        )
    }
}

private enum StringOrInt: Decodable {
    case string(String)
    case int(Int)
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else { throw DecodingError.typeMismatch(StringOrInt.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected String or Int")) }
    }
    var intValue: Int? {
        switch self {
        case .int(let i): i
        case .string(let s): Int(s)
        }
    }
}
