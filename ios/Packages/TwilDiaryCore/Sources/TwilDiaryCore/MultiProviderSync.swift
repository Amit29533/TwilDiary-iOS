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

/// How a provider was connected: by signing in to it (TwilDiary's app, or your own client ID with
/// a device code/PIN), or by pasting your own API key or access token.
public enum ProviderConnectionMethod: String, Codable, Sendable {
    case signIn = "sign_in"
    case apiKey = "api_key"
}

/// Configuration for an external sync provider (Trakt, MDBList, WeTrakr).
public struct ExternalProviderConfig: Codable, Equatable, Identifiable, Sendable {
    public let provider: SyncProviderKind
    public var enabled: Bool
    public var loggingMethod: WatchLoggingMethod
    public var clientId: String?
    public var apiKey: String?
    public var accessToken: String?
    public var username: String?
    public var lastSyncedAt: String?
    /// From a sign-in that issues one (Trakt, MDBList, WeTrakr); renews the access token.
    public var refreshToken: String?
    /// ISO 8601; when the access token stops working, if the service says.
    public var tokenExpiresAt: String?
    public var connection: ProviderConnectionMethod?

    public var id: SyncProviderKind { provider }

    public init(
        provider: SyncProviderKind,
        enabled: Bool = false,
        loggingMethod: WatchLoggingMethod = .serverAndDirectAPI,
        clientId: String? = nil,
        apiKey: String? = nil,
        accessToken: String? = nil,
        username: String? = nil,
        lastSyncedAt: String? = nil,
        refreshToken: String? = nil,
        tokenExpiresAt: String? = nil,
        connection: ProviderConnectionMethod? = nil
    ) {
        self.provider = provider
        self.enabled = enabled
        self.loggingMethod = loggingMethod
        self.clientId = Self.trimmed(clientId)
        self.apiKey = Self.trimmed(apiKey)
        self.accessToken = Self.trimmed(accessToken)
        self.username = Self.trimmed(username)
        self.lastSyncedAt = Self.trimmed(lastSyncedAt)
        self.refreshToken = Self.trimmed(refreshToken)
        self.tokenExpiresAt = Self.trimmed(tokenExpiresAt)
        self.connection = connection
    }

    /// True when the access token expires within `margin` seconds and a refresh token can renew it
    /// (by default a day; Trakt's tokens are short-lived, so 15 minutes there).
    public func needsRefresh(now: Date = .now, margin: TimeInterval? = nil) -> Bool {
        guard refreshToken != nil, let text = tokenExpiresAt,
              let expires = try? Date(text, strategy: .iso8601) else { return false }
        return expires.timeIntervalSince(now) < (margin ?? (provider == .trakt ? TraktPhoneSignIn.renewalMargin : 86_400))
    }

    /// True when the required API credentials for this provider have been entered.
    public var hasCredentials: Bool {
        switch provider {
        case .trakt, .wetrakr:
            guard let cid = Self.trimmed(clientId), !cid.isEmpty else { return false }
            return true
        case .mdblist:
            // An API key, or a sign-in token (sent as Bearer instead of ?apikey=).
            return Self.trimmed(apiKey) != nil || Self.trimmed(accessToken) != nil
        case .cloudflare:
            return true
        }
    }

    /// True when the provider has both an API key/client ID and an user access token (or API key for MDBList).
    public var isAuthenticated: Bool {
        switch provider {
        case .trakt, .wetrakr:
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
    public var mdblist: ExternalProviderConfig
    public var wetrakr: ExternalProviderConfig

    private enum CodingKeys: String, CodingKey { case customTmdbToken, trakt, mdblist, wetrakr }
    /// Settings saved before WeTrakr came back have no entry for it. Settings saved while Simkl was
    /// offered still hold a "simkl" entry; it isn't read (and the next save leaves it out).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customTmdbToken = try c.decodeIfPresent(String.self, forKey: .customTmdbToken)
        trakt = try c.decode(ExternalProviderConfig.self, forKey: .trakt)
        mdblist = try c.decode(ExternalProviderConfig.self, forKey: .mdblist)
        wetrakr = try c.decodeIfPresent(ExternalProviderConfig.self, forKey: .wetrakr) ?? ExternalProviderConfig(provider: .wetrakr)
    }

    public init(
        customTmdbToken: String? = nil,
        trakt: ExternalProviderConfig = ExternalProviderConfig(provider: .trakt),
        mdblist: ExternalProviderConfig = ExternalProviderConfig(provider: .mdblist),
        wetrakr: ExternalProviderConfig = ExternalProviderConfig(provider: .wetrakr)
    ) {
        self.customTmdbToken = customTmdbToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.customTmdbToken?.isEmpty == true { self.customTmdbToken = nil }
        self.trakt = trakt
        self.mdblist = mdblist
        self.wetrakr = wetrakr
    }

    public func config(for provider: SyncProviderKind) -> ExternalProviderConfig {
        switch provider {
        case .trakt: trakt
        case .mdblist: mdblist
        case .wetrakr: wetrakr
        case .cloudflare: ExternalProviderConfig(provider: .cloudflare, enabled: true)
        }
    }

    public mutating func setConfig(_ config: ExternalProviderConfig) {
        switch config.provider {
        case .trakt: trakt = config
        case .mdblist: mdblist = config
        case .wetrakr: wetrakr = config
        case .cloudflare: break
        }
    }

    /// Returns all direct providers that are currently enabled, authenticated, and configured to receive watch logs.
    public var activeDirectLoggingProviders: Set<SyncProviderKind> {
        var result: Set<SyncProviderKind> = []
        for item in [trakt, mdblist, wetrakr] {
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
        for provider in [SyncProviderKind.trakt, .mdblist] {
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
        for provider in [SyncProviderKind.trakt, .mdblist, .wetrakr] {
            var config = value.config(for: provider)
            config.accessToken = nil; config.apiKey = nil; config.refreshToken = nil
            value.setConfig(config)
        }
        return value
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
        case .mdblist: "ML"
        case .wetrakr: "WT"
        case .cloudflare: "TD"
        }
    }

    public var providerDisplayName: String {
        switch provider {
        case .trakt: "Trakt"
        case .mdblist: "MDBList"
        case .wetrakr: "WeTrakr"
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
        case .mdblist: "MDBList"
        case .wetrakr: "WeTrakr"
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
