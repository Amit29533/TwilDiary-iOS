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
            self.session = URLSession(configuration: configuration, delegate: StopRedirects(), delegateQueue: nil)
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
            method: "GET",
            headers: simklHeaders(config)
        )
        return try SimklSyncEngine.decodeActivities(from: data)
    }

    func fetchSimklAllItems(config: ExternalProviderConfig, dateFrom: String? = nil) async throws -> DirectTraktRemoteSnapshot {
        var components = URLComponents(string: "https://api.simkl.com/sync/all-items/")!
        var query = [URLQueryItem(name: "extended", value: "full"), URLQueryItem(name: "episode_watched_at", value: "yes"), URLQueryItem(name: "include_all_episodes", value: "yes")]
        if let dateFrom, !dateFrom.isEmpty { query.append(URLQueryItem(name: "date_from", value: dateFrom)) }
        components.queryItems = query
        let data = try await send(
            url: components.url!,
            method: "GET",
            headers: simklHeaders(config)
        )
        return try SimklSyncEngine.decodeAllItems(from: data)
    }

    func fetchMDBListRatings(config: ExternalProviderConfig, tmdbId: Int, isSeries: Bool) async throws -> MDBListSyncEngine.RatingSummary {
        let kind = isSeries ? "show" : "movie"
        var components = URLComponents(string: "https://api.mdblist.com/tmdb/\(kind)/\(tmdbId)")!
        let auth = mdblistAuth(config)
        if !auth.query.isEmpty { components.queryItems = auth.query }
        let data = try await send(url: components.url!, method: "GET", headers: auth.headers.merging(["Accept": "application/json"]) { first, _ in first })
        return try MDBListSyncEngine.decodeRatingSummary(from: data, tmdbId: tmdbId, isSeries: isSeries)
    }

    /// Acknowledgement is owned by DiaryStore and requires an item-level response receipt.
    func deliver(_ delivery: ProviderDelivery, entry: SyncOutboxEntry, config: ExternalProviderConfig) async throws {
        guard config.enabled, config.isAuthenticated else { throw APIError.message("Reconnect this provider before syncing pending edits.") }
        let base: String
        let headers: [String: String]
        switch config.provider {
        case .trakt:
            base = "https://api.trakt.tv"
            headers = traktHeaders(DirectTraktCredentials(clientId: config.clientId ?? "", accessToken: config.accessToken ?? ""))
        case .simkl: base = "https://api.simkl.com"; headers = simklHeaders(config)
        case .mdblist: base = "https://api.mdblist.com"; headers = mdblistAuth(config).headers.merging(["Accept": "application/json", "Content-Type": "application/json"]) { first, _ in first }
        case .cloudflare: throw APIError.message("Diary mutations must use the authenticated diary API.")
        }
        var components = URLComponents(string: base + delivery.path)!
        if config.provider == .mdblist, !mdblistAuth(config).query.isEmpty { components.queryItems = mdblistAuth(config).query }
        let data = try await send(url: components.url!, method: "POST", headers: headers, jsonBody: delivery.body)
        guard ProviderDeliveryPlanner.confirms(data) else { throw APIError.message("The provider did not confirm this item; the edit remains pending.") }
    }

    /// A read for the main-tracker preview (Simkl or MDBList): GET with the service's own sign-in.
    func read(_ config: ExternalProviderConfig, path: String, query: [String: String] = [:]) async throws -> Data {
        guard config.isAuthenticated else { throw APIError.message("Connect \(config.provider == .simkl ? "Simkl" : "MDBList") first, in Settings.") }
        let base: String, headers: [String: String]
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        switch config.provider {
        case .simkl: base = "https://api.simkl.com"; headers = simklHeaders(config)
        case .mdblist:
            base = "https://api.mdblist.com"
            let auth = mdblistAuth(config)
            headers = auth.headers.merging(["Accept": "application/json"]) { first, _ in first }
            items += auth.query
        default: throw APIError.message("This service is read by its own client.")
        }
        var components = URLComponents(string: base + path)!
        if !items.isEmpty { components.queryItems = items }
        do { return try await send(url: components.url!, method: "GET", headers: headers) }
        catch APIError.rejected(let status, _) where status == 401 || status == 403 {
            throw APIError.message("\(config.provider == .simkl ? "Simkl" : "MDBList") didn’t accept the sign-in (HTTP \(status)). Reconnect it in Settings.")
        }
    }

    /// MDBList takes a sign-in token as Bearer, or an API key as ?apikey= — never both (MDBList
    /// warns that sending the same credential both ways fails).
    private func mdblistAuth(_ config: ExternalProviderConfig) -> (query: [URLQueryItem], headers: [String: String]) {
        if config.connection == .signIn || config.apiKey == nil, let token = config.accessToken {
            return ([], ["Authorization": "Bearer \(token)"])
        }
        return ([URLQueryItem(name: "apikey", value: config.apiKey)], [:])
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

    // MARK: - Sign in with MDBList or Simkl (standard device sign-in, no client secret)

    enum SignInStart {
        /// Show the code and page, then poll.
        case device(ProviderDeviceSignIn.Authorization)
        /// An older Simkl app (AUTH V1) can't use the device sign-in; Simkl's PIN instead.
        case simklPin(DeviceCodeAuthSession)
    }
    func startSignIn(provider: SyncProviderKind, clientId: String) async throws -> SignInStart {
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: provider) else { throw APIError.message("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.authorize, ProviderDeviceSignIn.authorizeBody(clientId: clientId, scope: endpoints.scope))
        if (200..<300).contains(status) { return .device(try ProviderDeviceSignIn.decodeAuthorization(data)) }
        if provider == .simkl, status == 400 || status == 401 {
            let pin = try await requestDeviceCode(provider: .simkl, clientId: clientId)
            return .simklPin(pin)
        }
        if case .failed(let message) = ProviderDeviceSignIn.decodePoll(status: status, data: data) { throw APIError.message(message) }
        throw APIError.message("The service answered HTTP \(status).")
    }
    func pollSignIn(provider: SyncProviderKind, clientId: String, deviceCode: String) async throws -> ProviderDeviceSignIn.Poll {
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: provider) else { return .failed("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.token, ProviderDeviceSignIn.pollBody(clientId: clientId, deviceCode: deviceCode))
        return ProviderDeviceSignIn.decodePoll(status: status, data: data)
    }
    /// A new access token from the refresh token (MDBList: 30-day tokens; Simkl: 7 days).
    func refreshSignIn(provider: SyncProviderKind, clientId: String, refreshToken: String) async throws -> ProviderDeviceSignIn.Tokens {
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: provider) else { throw APIError.message("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.token, ProviderDeviceSignIn.refreshBody(clientId: clientId, refreshToken: refreshToken))
        switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
        case .authorized(let tokens): return tokens
        case .failed(let message): throw APIError.message(message)
        default: throw APIError.message("The service didn’t renew the sign-in (HTTP \(status)).")
        }
    }
    private func postForm(_ url: URL, _ body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TwilDiary/2.0.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
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
