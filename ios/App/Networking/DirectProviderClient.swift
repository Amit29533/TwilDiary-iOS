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
        case .wetrakr: base = "https://api.wetrakr.com"; headers = WeTrakrWrite.headers(clientId: config.clientId ?? "", accessToken: config.accessToken)
        case .cloudflare: throw APIError.message("Diary mutations must use the authenticated diary API.")
        }
        var components = URLComponents(string: base + delivery.path)!
        if config.provider == .mdblist, !mdblistAuth(config).query.isEmpty { components.queryItems = mdblistAuth(config).query }
        let data = try await send(url: components.url!, method: "POST", headers: headers, jsonBody: delivery.body)
        guard ProviderDeliveryPlanner.confirms(data) else { throw APIError.message("The provider did not confirm this item; the edit remains pending.") }
    }

    /// A read for the main-tracker preview (Simkl or MDBList): GET with the service's own sign-in.
    func read(_ config: ExternalProviderConfig, path: String, query: [String: String] = [:]) async throws -> Data {
        guard config.isAuthenticated else { throw APIError.message("Connect \(config.provider.displayName) first, in Connections.") }
        let base: String, headers: [String: String]
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        switch config.provider {
        case .simkl: base = "https://api.simkl.com"; headers = simklHeaders(config)
        case .mdblist:
            base = "https://api.mdblist.com"
            let auth = mdblistAuth(config)
            headers = auth.headers.merging(["Accept": "application/json"]) { first, _ in first }
            items += auth.query
        case .wetrakr: base = "https://api.wetrakr.com"; headers = WeTrakrWrite.headers(clientId: config.clientId ?? "", accessToken: config.accessToken)
        default: throw APIError.message("This service is read by its own client.")
        }
        var components = URLComponents(string: base + path)!
        if !items.isEmpty { components.queryItems = items }
        do { return try await send(url: components.url!, method: "GET", headers: headers) }
        catch APIError.rejected(let status, _) where status == 401 || status == 403 {
            throw APIError.message("\(config.provider.displayName) didn’t accept the sign-in (HTTP \(status)). Reconnect it in Connections.")
        }
    }

    /// A write for "Make Simkl / MDBList match the diary": POST of a ready JSON body, returning the reply.
    func write(_ config: ExternalProviderConfig, path: String, body: Data) async throws -> Data {
        let name = config.provider.displayName
        guard config.enabled, config.isAuthenticated else { throw APIError.message("Connect \(name) first, in Connections.") }
        let base: String, headers: [String: String]
        var items: [URLQueryItem] = []
        switch config.provider {
        case .simkl: base = "https://api.simkl.com"; headers = simklHeaders(config)
        case .mdblist:
            base = "https://api.mdblist.com"
            let auth = mdblistAuth(config)
            headers = auth.headers.merging(["Accept": "application/json", "Content-Type": "application/json"]) { first, _ in first }
            items = auth.query
        case .wetrakr: base = "https://api.wetrakr.com"; headers = WeTrakrWrite.headers(clientId: config.clientId ?? "", accessToken: config.accessToken)
        default: throw APIError.message("This service is written by its own client.")
        }
        var components = URLComponents(string: base + path)!
        if !items.isEmpty { components.queryItems = items }
        do { return try await send(url: components.url!, method: "POST", headers: headers, rawBody: body) }
        catch APIError.rejected(let status, _) where status == 401 || status == 403 {
            throw APIError.message("\(name) didn’t accept the sign-in for writing (HTTP \(status)). Reconnect it in Connections and allow changes.")
        } catch APIError.rejected(let status, let message) where status == 429 || (config.provider == .simkl && status == 400 && message.contains("rate_limit")) {
            // Simkl takes one write per account at a time and answers "rate_limit" while another
            // is still running; its guide says wait and try once more (same for a plain 429).
            try await Task.sleep(for: .seconds(3))
            do { return try await send(url: components.url!, method: "POST", headers: headers, rawBody: body) }
            catch APIError.rejected(let again, _) where again == 400 || again == 429 {
                throw APIError.message("\(name) is busy with another change right now. Try again in a minute.")
            }
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
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil
    ) async throws -> Data {
        try ProviderCooldowns.check(url)
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let rawBody {
            request.httpBody = rawBody
        } else if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("Unexpected provider response.")
        }
        ProviderCooldowns.record(url, http)
        guard (200..<300).contains(http.statusCode) else {
            // Simkl's "one write at a time" refusal is a 400 whose body says rate_limit.
            let busy = (String(data: data.prefix(500), encoding: .utf8) ?? "").contains("rate_limit")
            throw APIError.rejected(http.statusCode, "Provider returned HTTP \(http.statusCode)." + (busy ? " (rate_limit)" : ""))
        }
        return data
    }

    // MARK: - Sign in with MDBList or Simkl (their sign-in page in Apple's sheet; PKCE, no client secret)

    /// Trades the code from the sign-in sheet for tokens.
    func finishWebSignIn(_ request: ProviderWebSignIn.Request, code: String) async throws -> ProviderDeviceSignIn.Tokens {
        if request.provider == .wetrakr {
            let body = WeTrakrWrite.codeBody(code: code, clientId: request.clientId, verifier: request.verifier, redirect: ProviderWebSignIn.redirect(for: .wetrakr))
            let (data, status) = try await post(WeTrakrWrite.tokenURL, body, json: true, extra: ["wetrakr-api-version": "1"])
            switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
            case .authorized(let tokens): return tokens
            case .failed(let message): throw APIError.message(message)
            default: throw APIError.message("WeTrakr didn’t finish the sign-in (HTTP \(status)).")
            }
        }
        if request.provider == .trakt {
            let (data, status) = try await post(TraktPhoneSignIn.tokenURL, TraktPhoneSignIn.codeBody(code: code, for: request), json: true)
            switch TraktPhoneSignIn.decode(status: status, data: data) {
            case .authorized(let tokens): return tokens
            case .failed(let message): throw APIError.message(message)
            default: throw APIError.message("Trakt didn’t finish the sign-in (HTTP \(status)).")
            }
        }
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: request.provider) else { throw APIError.message("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.token, ProviderWebSignIn.tokenBody(code: code, for: request))
        switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
        case .authorized(let tokens): return tokens
        case .failed(let message): throw APIError.message(message)
        default: throw APIError.message("The service didn’t finish the sign-in (HTTP \(status)).")
        }
    }
    /// MDBList's device sign-in (its OAuth only takes http(s) redirects, so the app can't be the
    /// redirect): a short code to approve on mdblist.com, then `pollDeviceSignIn` until approved.
    func startDeviceSignIn(provider: SyncProviderKind, clientId: String) async throws -> ProviderDeviceSignIn.Authorization {
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: provider) else { throw APIError.message("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.authorize, ProviderDeviceSignIn.authorizeBody(clientId: clientId, scope: endpoints.scope))
        if case .failed(let message) = ProviderDeviceSignIn.decodePoll(status: status, data: data), !(200..<300).contains(status) {
            throw APIError.message(message + " (A \"Device Code\" app is needed for this sign-in.)")
        }
        return try ProviderDeviceSignIn.decodeAuthorization(data)
    }
    func pollDeviceSignIn(provider: SyncProviderKind, clientId: String, deviceCode: String) async throws -> ProviderDeviceSignIn.Poll {
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: provider) else { throw APIError.message("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.token, ProviderDeviceSignIn.pollBody(clientId: clientId, deviceCode: deviceCode))
        return ProviderDeviceSignIn.decodePoll(status: status, data: data)
    }
    /// A new access token from the refresh token (MDBList: 30-day tokens; Simkl: 7 days).
    func refreshSignIn(provider: SyncProviderKind, clientId: String, refreshToken: String) async throws -> ProviderDeviceSignIn.Tokens {
        if provider == .wetrakr {
            // WeTrakr rotates the refresh token on every renewal (7-day access tokens).
            let (data, status) = try await post(WeTrakrWrite.refreshURL, WeTrakrWrite.refreshBody(refreshToken: refreshToken), json: true, extra: ["wetrakr-api-version": "1"])
            switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
            case .authorized(let tokens): return tokens
            case .failed(let message) where status == 400 || status == 401: throw ProviderRenewalError.signInEnded(message)
            case .failed(let message): throw APIError.message(message)
            default: throw APIError.message("WeTrakr didn’t renew the sign-in (HTTP \(status)).")
            }
        }
        if provider == .trakt {
            let (data, status) = try await post(TraktPhoneSignIn.tokenURL, TraktPhoneSignIn.refreshBody(clientId: clientId, refreshToken: refreshToken), json: true)
            switch TraktPhoneSignIn.decode(status: status, data: data) {
            case .authorized(let tokens): return tokens
            case .failed(let message) where status == 400 || status == 401: throw ProviderRenewalError.signInEnded(message)
            case .failed(let message): throw APIError.message(message)
            default: throw APIError.message("Trakt didn’t renew the sign-in (HTTP \(status)).")
            }
        }
        guard let endpoints = ProviderDeviceSignIn.endpoints(for: provider) else { throw APIError.message("This service has no sign-in TwilDiary can use.") }
        let (data, status) = try await postForm(endpoints.token, ProviderDeviceSignIn.refreshBody(clientId: clientId, refreshToken: refreshToken))
        switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
        case .authorized(let tokens): return tokens
        case .failed(let message): throw APIError.message(message)
        default: throw APIError.message("The service didn’t renew the sign-in (HTTP \(status)).")
        }
    }
    /// A WeTrakr read that also returns the reply's headers (its compact lists page with the
    /// `X-Pagination-Next` cursor).
    func readWeTrakr(_ config: ExternalProviderConfig, path: String, query: [String: String] = [:]) async throws -> (data: Data, next: String?) {
        guard config.isAuthenticated else { throw APIError.message("Connect WeTrakr first, in Connections.") }
        var components = URLComponents(string: "https://api.wetrakr.com" + path)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        try ProviderCooldowns.check(components.url!)
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        for (key, value) in WeTrakrWrite.headers(clientId: config.clientId ?? "", accessToken: config.accessToken) { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("WeTrakr didn’t answer.") }
        ProviderCooldowns.record(components.url!, http)
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.message("WeTrakr didn’t accept the sign-in (HTTP \(http.statusCode)). Reconnect it in Connections.") }
        guard (200..<300).contains(http.statusCode) else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw APIError.rejected(http.statusCode, code ?? "Provider returned HTTP \(http.statusCode).")
        }
        let next = http.value(forHTTPHeaderField: "X-Pagination-Next").flatMap { $0.isEmpty ? nil : $0 }
        return (data, next)
    }
    /// The Trakt account a token belongs to (`GET /users/settings`).
    func traktUsername(clientId: String, accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.trakt.tv/users/settings")!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("TwilDiary/2.0.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let name = TraktPhoneSignIn.username(from: data) else {
            throw APIError.message("Trakt didn’t say which account signed in (HTTP \(status)).")
        }
        return name
    }
    /// Ends a Trakt sign-in on Trakt's side too. Best effort: signing out works offline.
    func revokeTrakt(clientId: String, token: String) async {
        _ = try? await post(TraktPhoneSignIn.revokeURL, TraktPhoneSignIn.revokeBody(clientId: clientId, token: token), json: true)
    }
    private func postForm(_ url: URL, _ body: Data) async throws -> (Data, Int) {
        try await post(url, body, json: false)
    }
    private func post(_ url: URL, _ body: Data, json: Bool, extra: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in extra { request.setValue(value, forHTTPHeaderField: key) }
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

/// A renewal the service refused for good (spent or revoked refresh token): the account needs
/// signing in again. Anything else (offline, busy) keeps the sign-in for the next try.
enum ProviderRenewalError: LocalizedError, Equatable {
    case signInEnded(String)
    var errorDescription: String? {
        switch self { case .signInEnded(let message): message }
    }
}

/// A service's "wait before asking again", kept on this iPhone (per host, so it survives a
/// restart): no request goes to that service until the pause is over. From its own headers
/// (`ProviderCooldown`); a later answer that isn't a refusal doesn't shorten it.
enum ProviderCooldowns {
    private static let prefix = "providerCooldown."
    private static func name(_ host: String) -> String {
        switch host {
        case "api.trakt.tv": "Trakt"
        case "api.simkl.com": "Simkl"
        case "api.mdblist.com": "MDBList"
        case "api.wetrakr.com": "WeTrakr"
        default: host
        }
    }
    static func until(_ url: URL, now: Date = .now) -> Date? {
        guard let host = url.host else { return nil }
        let stamp = UserDefaults.standard.double(forKey: prefix + host)
        return stamp > now.timeIntervalSince1970 ? Date(timeIntervalSince1970: stamp) : nil
    }
    /// Throws while the service has asked TwilDiary to wait.
    static func check(_ url: URL) throws {
        guard let until = until(url), let host = url.host else { return }
        throw APIError.message("\(name(host)) asked TwilDiary to slow down. It tries again after \(until.formatted(date: .omitted, time: .shortened)).")
    }
    static func record(_ url: URL, _ response: HTTPURLResponse, now: Date = .now) {
        guard let host = url.host else { return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String, let value = value as? String { headers[key] = value } }
        guard let until = ProviderCooldown.until(status: response.statusCode, headers: headers, now: now) else { return }
        let key = prefix + host
        UserDefaults.standard.set(max(UserDefaults.standard.double(forKey: key), until.timeIntervalSince1970), forKey: key)
    }
}
