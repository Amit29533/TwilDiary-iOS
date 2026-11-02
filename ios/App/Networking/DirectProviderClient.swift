import Foundation
import TwilDiaryCore

struct DeviceCodeAuthSession: Equatable, Sendable {
    let provider: SyncProviderKind
    let userCode: String
    let verificationURL: URL
    let deviceCode: String
    let expiresIn: Int
    let interval: Int
}

enum DeviceCodePollStatus: Equatable, Sendable {
    case pending
    case authorized(accessToken: String)
    case expired
}

/// Direct device-to-provider HTTP client for Trakt (`api.trakt.tv`), Simkl (`api.simkl.com`),
/// and MDBList (`api.mdblist.com`), bypassing the server-side D1 bottleneck when configured.
@MainActor final class DirectProviderClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetchTraktLastActivities(credentials: DirectTraktCredentials) async throws -> DirectTraktLastActivities {
        let data = try await send(
            url: URL(string: "https://api.trakt.tv/sync/last_activities")!,
            method: "GET",
            headers: traktHeaders(credentials)
        )
        return try DirectTraktEngine.decodeLastActivities(from: data)
    }

    func fetchSimklActivities(config: ExternalProviderConfig) async throws -> SimklSyncEngine.ActivityTimestamps {
        let data = try await send(
            url: URL(string: "https://api.simkl.com/sync/activities")!,
            method: "POST",
            headers: simklHeaders(config)
        )
        return try SimklSyncEngine.decodeActivities(from: data)
    }

    func fetchSimklAllItems(config: ExternalProviderConfig, dateFrom: String? = nil) async throws -> DirectTraktRemoteSnapshot {
        var components = URLComponents(string: "https://api.simkl.com/sync/all-items/")!
        if let dateFrom, !dateFrom.isEmpty {
            components.queryItems = [URLQueryItem(name: "date_from", value: dateFrom)]
        }
        let data = try await send(
            url: components.url!,
            method: "GET",
            headers: simklHeaders(config)
        )
        return try SimklSyncEngine.decodeAllItems(from: data)
    }

    func fetchMDBListRatings(apiKey: String, tmdbId: Int, isSeries: Bool) async throws -> MDBListSyncEngine.RatingSummary {
        let kind = isSeries ? "show" : "movie"
        var components = URLComponents(string: "https://api.mdblist.com/tmdb/\(kind)/\(tmdbId)")!
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        let data = try await send(url: components.url!, method: "GET", headers: ["Accept": "application/json"])
        return try MDBListSyncEngine.decodeRatingSummary(from: data, tmdbId: tmdbId, isSeries: isSeries)
    }

    func fetchWeTrakrActivities(config: ExternalProviderConfig) async throws -> WeTrakrSyncEngine.ActivityTimestamps {
        let data = try await send(
            url: URL(string: "https://api.wetrakr.com/sync/last_activities")!,
            method: "GET",
            headers: wetrakrHeaders(config)
        )
        return try WeTrakrSyncEngine.decodeActivities(from: data)
    }

    func fetchWeTrakrCompactRows(
        config: ExternalProviderConfig,
        path: String,
        fromDate: String? = nil,
        after: String? = nil
    ) async throws -> [WeTrakrSyncEngine.CompactRow] {
        var components = URLComponents(string: "https://api.wetrakr.com" + path)!
        var items = [
            URLQueryItem(name: "compact", value: "true"),
            URLQueryItem(name: "limit", value: "1000")
        ]
        if let fromDate, !fromDate.isEmpty {
            items.append(URLQueryItem(name: "from_date", value: fromDate))
        }
        if let after, !after.isEmpty {
            items.append(URLQueryItem(name: "after", value: after))
        }
        components.queryItems = items
        let data = try await send(
            url: components.url!,
            method: "GET",
            headers: wetrakrHeaders(config)
        )
        return try WeTrakrSyncEngine.decodeCompactRows(from: data)
    }

    func fetchWeTrakrSnapshot(
        config: ExternalProviderConfig,
        since previous: WeTrakrSyncEngine.ActivityTimestamps? = nil
    ) async throws -> (activities: WeTrakrSyncEngine.ActivityTimestamps, snapshot: WeTrakrSyncEngine.NormalizedWeTrakrSnapshot) {
        let activities = try await fetchWeTrakrActivities(config: config)
        let domains = activities.changedDomains(since: previous)
        guard domains.anyChanged else {
            return (activities, WeTrakrSyncEngine.NormalizedWeTrakrSnapshot(remote: DirectTraktRemoteSnapshot()))
        }
        let watchedMovies = domains.watchedMovies
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/tracking/watched/movies", fromDate: previous?.movies.watchedAt)
            : []
        let watchedEpisodes = domains.watchedEpisodes
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/tracking/watched/episodes", fromDate: previous?.episodes.watchedAt)
            : []
        let planningMovies = domains.watchlist
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/tracking/planning/movies")
            : []
        let planningShows = domains.watchlist
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/tracking/planning/shows")
            : []
        let ratingsMovies = domains.ratings
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/ratings/movies", fromDate: previous?.ratings.all)
            : []
        let ratingsShows = domains.ratings
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/ratings/shows", fromDate: previous?.ratings.all)
            : []
        let favoritesMovies = domains.favorites
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/favorites/movies", fromDate: previous?.favorites.all)
            : []
        let favoritesShows = domains.favorites
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/favorites/shows", fromDate: previous?.favorites.all)
            : []
        let droppedShows = domains.dropped
            ? try await fetchWeTrakrCompactRows(config: config, path: "/sync/tracking/dropped/shows")
            : []

        let snapshot = WeTrakrSyncEngine.normalizeSnapshot(
            watchedMovies: watchedMovies,
            watchedEpisodes: watchedEpisodes,
            planningMovies: planningMovies,
            planningShows: planningShows,
            ratingsMovies: ratingsMovies,
            ratingsShows: ratingsShows,
            favoritesMovies: favoritesMovies,
            favoritesShows: favoritesShows,
            droppedShows: droppedShows
        )
        return (activities, snapshot)
    }

    /// Flushes pending outbox mutations for an external provider directly from the device
    /// and acknowledges confirmed entries on `store`.
    func flushOutbox(for config: ExternalProviderConfig, in store: DiaryStore) async throws {
        guard config.enabled,
              let batch = MultiProviderOutboxDispatcher.prepareBatch(
                  for: config.provider,
                  from: store.outbox,
                  in: store.workspace
              ) else { return }

        let totalEntries = batch.entryIDs.count
        BackgroundSyncCoordinator.shared.updateForProviderBatch(
            provider: config.provider,
            completed: 0,
            total: totalEntries,
            phase: .flushingOutbox
        )

        switch config.provider {
        case .trakt:
            guard let clientId = config.clientId, !clientId.isEmpty,
                  let token = config.accessToken, !token.isEmpty else { return }
            let headers = traktHeaders(DirectTraktCredentials(clientId: clientId, accessToken: token))
            if let history = batch.historyPayload {
                _ = try await send(url: URL(string: "https://api.trakt.tv/sync/history")!, method: "POST", headers: headers, jsonBody: history)
            }
            if let ratings = batch.ratingsPayload {
                _ = try await send(url: URL(string: "https://api.trakt.tv/sync/ratings")!, method: "POST", headers: headers, jsonBody: ratings)
            }
            if let watchlist = batch.watchlistPayload {
                _ = try await send(url: URL(string: "https://api.trakt.tv/sync/watchlist")!, method: "POST", headers: headers, jsonBody: watchlist)
            }
        case .simkl:
            guard let clientId = config.clientId, !clientId.isEmpty,
                  let token = config.accessToken, !token.isEmpty else { return }
            let headers = simklHeaders(config)
            if let history = batch.historyPayload {
                _ = try await send(url: URL(string: "https://api.simkl.com/sync/history")!, method: "POST", headers: headers, jsonBody: history)
            }
            if let ratings = batch.ratingsPayload {
                _ = try await send(url: URL(string: "https://api.simkl.com/sync/ratings")!, method: "POST", headers: headers, jsonBody: ratings)
            }
            if let watchlist = batch.watchlistPayload {
                _ = try await send(url: URL(string: "https://api.simkl.com/sync/add-to-list")!, method: "POST", headers: headers, jsonBody: watchlist)
            }
        case .mdblist:
            guard let apiKey = config.apiKey, !apiKey.isEmpty else { return }
            let headers = ["Accept": "application/json", "Content-Type": "application/json"]
            if let history = batch.historyPayload {
                var comps = URLComponents(string: "https://api.mdblist.com/sync/watched")!
                comps.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
                _ = try await send(url: comps.url!, method: "POST", headers: headers, jsonBody: history)
            }
            if let watchlist = batch.watchlistPayload {
                var comps = URLComponents(string: "https://api.mdblist.com/watchlist/items/add")!
                comps.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
                _ = try await send(url: comps.url!, method: "POST", headers: headers, jsonBody: watchlist)
            }
        case .wetrakr:
            guard let clientId = config.clientId, !clientId.isEmpty,
                  let token = config.accessToken, !token.isEmpty else { return }
            let baseHeaders = wetrakrHeaders(config)
            if let history = batch.historyPayload {
                var headers = baseHeaders
                headers["Idempotency-Key"] = WeTrakrSyncEngine.idempotencyKey(path: "/sync/tracking:watched", entryIDs: batch.entryIDs)
                _ = try await send(url: URL(string: "https://api.wetrakr.com/sync/tracking")!, method: "POST", headers: headers, jsonBody: history)
            }
            if let watchlist = batch.watchlistPayload {
                var headers = baseHeaders
                headers["Idempotency-Key"] = WeTrakrSyncEngine.idempotencyKey(path: "/sync/tracking:planning", entryIDs: batch.entryIDs)
                _ = try await send(url: URL(string: "https://api.wetrakr.com/sync/tracking")!, method: "POST", headers: headers, jsonBody: watchlist)
            }
            if let ratings = batch.ratingsPayload {
                var headers = baseHeaders
                headers["Idempotency-Key"] = WeTrakrSyncEngine.idempotencyKey(path: "/sync/ratings", entryIDs: batch.entryIDs)
                _ = try await send(url: URL(string: "https://api.wetrakr.com/sync/ratings")!, method: "POST", headers: headers, jsonBody: ratings)
            }
            if let favorites = batch.favoritesPayload {
                var headers = baseHeaders
                headers["Idempotency-Key"] = WeTrakrSyncEngine.idempotencyKey(path: "/sync/favorites", entryIDs: batch.entryIDs)
                _ = try await send(url: URL(string: "https://api.wetrakr.com/sync/favorites")!, method: "POST", headers: headers, jsonBody: favorites)
            }
        case .cloudflare:
            break
        }

        for entryID in batch.entryIDs {
            store.acknowledgeOutbox(entryID, provider: config.provider)
        }
        BackgroundSyncCoordinator.shared.updateForProviderBatch(
            provider: config.provider,
            completed: totalEntries,
            total: totalEntries,
            phase: .completed
        )
    }

    private func traktHeaders(_ credentials: DirectTraktCredentials) -> [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": credentials.clientId,
            "Authorization": "Bearer \(credentials.accessToken)"
        ]
    }

    private func simklHeaders(_ config: ExternalProviderConfig) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "simkl-api-key": config.clientId ?? ""
        ]
        if let token = config.accessToken, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func wetrakrHeaders(_ config: ExternalProviderConfig) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "wetrakr-api-version": "1",
            "wetrakr-api-key": config.clientId ?? ""
        ]
        if let token = config.accessToken, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func send(
        url: URL,
        method: String,
        headers: [String: String],
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("Unexpected provider response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.rejected(http.statusCode, "Provider returned HTTP \(http.statusCode).")
        }
        return data
    }

    // MARK: - Interactive OAuth Device Code / PIN Sign-In (Trakt & Simkl)

    func requestDeviceCode(provider: SyncProviderKind, clientId: String) async throws -> DeviceCodeAuthSession {
        let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw APIError.message("Enter your Client ID first.")
        }
        if provider == .trakt {
            let data = try await send(
                url: URL(string: "https://api.trakt.tv/oauth/device/code")!,
                method: "POST",
                headers: ["Accept": "application/json", "Content-Type": "application/json"],
                jsonBody: ["client_id": cleanId]
            )
            struct TraktCodeReply: Decodable {
                let device_code: String
                let user_code: String
                let verification_url: String?
                let expires_in: Int?
                let interval: Int?
            }
            let reply = try JSONDecoder().decode(TraktCodeReply.self, from: data)
            let url = URL(string: reply.verification_url ?? "https://trakt.tv/activate") ?? URL(string: "https://trakt.tv/activate")!
            return DeviceCodeAuthSession(
                provider: .trakt,
                userCode: reply.user_code,
                verificationURL: url,
                deviceCode: reply.device_code,
                expiresIn: reply.expires_in ?? 600,
                interval: reply.interval ?? 5
            )
        }
        var comps = URLComponents(string: "https://api.simkl.com/oauth/pin")!
        comps.queryItems = [URLQueryItem(name: "client_id", value: cleanId)]
        let data = try await send(
            url: comps.url!,
            method: "GET",
            headers: ["Accept": "application/json"]
        )
        struct SimklPinReply: Decodable {
            let user_code: String
            let verification_url: String?
            let expires_in: Int?
            let interval: Int?
        }
        let reply = try JSONDecoder().decode(SimklPinReply.self, from: data)
        let url = URL(string: reply.verification_url ?? "https://simkl.com/pin") ?? URL(string: "https://simkl.com/pin")!
        return DeviceCodeAuthSession(
            provider: .simkl,
            userCode: reply.user_code,
            verificationURL: url,
            deviceCode: reply.user_code,
            expiresIn: reply.expires_in ?? 900,
            interval: reply.interval ?? 5
        )
    }

    func pollDeviceToken(session auth: DeviceCodeAuthSession, clientId: String, clientSecret: String? = nil) async throws -> DeviceCodePollStatus {
        let cleanId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if auth.provider == .trakt {
            var request = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["code": auth.deviceCode, "client_id": cleanId]
            if let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
                body["client_secret"] = secret
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .pending }
            if http.statusCode == 400 { return .pending }
            if [404, 410, 418].contains(http.statusCode) { return .expired }
            guard (200..<300).contains(http.statusCode) else { return .pending }
            struct TokenReply: Decodable { let access_token: String? }
            if let reply = try? JSONDecoder().decode(TokenReply.self, from: data), let token = reply.access_token, !token.isEmpty {
                return .authorized(accessToken: token)
            }
            return .pending
        }
        var comps = URLComponents(string: "https://api.simkl.com/oauth/pin/\(auth.userCode)")!
        comps.queryItems = [URLQueryItem(name: "client_id", value: cleanId)]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .pending }
        struct SimklTokenReply: Decodable {
            let result: String?
            let access_token: String?
        }
        if let reply = try? JSONDecoder().decode(SimklTokenReply.self, from: data),
           reply.result == "OK", let token = reply.access_token, !token.isEmpty {
            return .authorized(accessToken: token)
        }
        return .pending
    }
}
