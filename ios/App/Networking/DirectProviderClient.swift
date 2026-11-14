import Foundation
import CryptoKit
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

/// Direct device-to-provider HTTP client for Trakt (`api.trakt.tv`), MDBList (`api.mdblist.com`)
/// and WeTrakr (`api.wetrakr.com`), bypassing the server-side D1 bottleneck when configured.
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
        case .mdblist: base = "https://api.mdblist.com"; headers = mdblistAuth(config).headers.merging(["Accept": "application/json", "Content-Type": "application/json"]) { first, _ in first }
        case .wetrakr: base = "https://api.wetrakr.com"; headers = WeTrakrWrite.headers(clientId: config.clientId ?? "", accessToken: config.accessToken)
        case .cloudflare: throw APIError.message("Diary mutations must use the authenticated diary API.")
        case .simkl: throw APIError.message("Simkl’s edits go through its own sync.")
        }
        var components = URLComponents(string: base + delivery.path)!
        if config.provider == .mdblist, !mdblistAuth(config).query.isEmpty { components.queryItems = mdblistAuth(config).query }
        if config.provider == .trakt, delivery.key == "history-remove-timed" {
            // The play is looked up in Trakt's history at its time (a minute either side) and
            // removed by its own id; not there means there's nothing to remove.
            let body = try JSONSerialization.data(withJSONObject: delivery.body)
            let wanted = TraktDirectStore.requestedPlays(body)
            let times = wanted.compactMap(\.when)
            guard let first = times.min(), let last = times.max() else { return }
            let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            var lookup = URLComponents(string: base + "/sync/history")!
            lookup.queryItems = [URLQueryItem(name: "start_at", value: format.format(first.addingTimeInterval(-60))),
                                 URLQueryItem(name: "end_at", value: format.format(last.addingTimeInterval(60))), URLQueryItem(name: "limit", value: "1000")]
            let found = try TraktDecode.history(from: try await send(url: lookup.url!, method: "GET", headers: headers)).items
            let ids = TraktDirectStore.historyIDs(for: wanted, in: found)
            guard !ids.isEmpty else { return }
            let data = try await send(url: components.url!, method: "POST", headers: headers, rawBody: try JSONSerialization.data(withJSONObject: ["ids": ids]))
            guard ProviderDeliveryPlanner.confirms(data) else { throw DeliveryUnconfirmed(history: false) }
            return
        }
        let prepared = await ServiceIDs.shared.prepare(try JSONSerialization.data(withJSONObject: delivery.body), for: config.provider, config: config, client: self)
        if prepared.waiting > 0 { throw APIError.rejected(503, "WeTrakr couldn’t be asked for this title’s own id yet; it’s sent once WeTrakr answers.") }
        let data: Data
        if prepared.movies + prepared.shows == 0, !prepared.missing.isEmpty {
            data = ServiceIDs.reply(Data("{}".utf8), adding: prepared.missing)
        } else {
            var sendHeaders = headers
            if config.provider == .wetrakr { sendHeaders["Idempotency-Key"] = Self.idempotencyKey(entry.operationId + "-" + delivery.key, body: prepared.body) }
            data = ServiceIDs.reply(try await send(url: components.url!, method: "POST", headers: sendHeaders, rawBody: prepared.body), adding: prepared.missing)
        }
        guard ProviderDeliveryPlanner.confirms(data) else {
            // A title the service can't find is set aside (said once), not retried forever.
            if ProviderDeliveryPlanner.notFound(data) { throw APIError.rejected(404, "\(config.provider.displayName) couldn’t find this title by its TMDB id, so it wasn’t changed there.") }
            // Answered, with nothing added and nothing refused: usually it was already that way.
            throw DeliveryUnconfirmed(history: delivery.history)
        }
    }

    /// The service answered a write with nothing added and nothing refused (a service's reply for a
    /// watch it already had). A watch is checked against the service before it counts as done.
    struct DeliveryUnconfirmed: Error { let history: Bool }

    /// A read for the main-tracker preview (MDBList or WeTrakr): GET with the service's own sign-in.
    func read(_ config: ExternalProviderConfig, path: String, query: [String: String] = [:], method: String = "GET") async throws -> Data {
        guard config.isAuthenticated else { throw APIError.message("Connect \(config.provider.displayName) first, in Connections.") }
        let base: String, headers: [String: String]
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        switch config.provider {
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
        do { return try await send(url: components.url!, method: method, headers: headers) }
        catch APIError.rejected(let status, _) where status == 401 || status == 403 {
            throw APIError.message("\(config.provider.displayName) didn’t accept the sign-in (HTTP \(status)). Reconnect it in Connections.")
        }
    }

    /// A write for "Make MDBList / WeTrakr match the diary": POST of a ready JSON body, returning the reply.
    /// `partial`: a bulk send (a match, a restore, Force Match) goes ahead without the titles WeTrakr
    /// couldn't be asked about yet; they come back as not found and are asked about next time. One
    /// of your own edits waits whole instead, so no part of it is dropped.
    /// WeTrakr applies a write once per Idempotency-Key (as Cinopsys sends it): the key is the
    /// edit's own id and the exact body, so a resend after a lost answer can't apply twice, and a
    /// changed body (a title's id found meanwhile) is a new request rather than a reused key.
    nonisolated static func idempotencyKey(_ id: String, body: Data) -> String {
        id + "-" + SHA256.hash(data: body).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    func write(_ config: ExternalProviderConfig, path: String, body: Data, partial: Bool = false, idempotency: String? = nil) async throws -> Data {
        let name = config.provider.displayName
        // The service holding your diary (and a match you asked for) only needs the sign-in: the
        // "Send my edits" switch governs the other services, not the diary's own.
        guard config.isAuthenticated else { throw APIError.message("Connect \(name) first, in Connections.") }
        let base: String, headers: [String: String]
        var items: [URLQueryItem] = []
        switch config.provider {
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
        // Each title named by the service's own id too (looked up once when unknown); titles the
        // service doesn't have are left out and reported as not found.
        let prepared = await ServiceIDs.shared.prepare(body, for: config.provider, config: config, client: self)
        if prepared.waiting > 0, !partial || prepared.movies + prepared.shows == 0 {
            throw APIError.rejected(503, "WeTrakr couldn’t be asked for this title’s own id yet; it’s sent once WeTrakr answers.")
        }
        if prepared.movies + prepared.shows == 0, !prepared.missing.isEmpty { return ServiceIDs.reply(Data("{}".utf8), adding: prepared.missing) }
        let sending = prepared.body
        var writeHeaders = headers
        if config.provider == .wetrakr, let idempotency { writeHeaders["Idempotency-Key"] = Self.idempotencyKey(idempotency, body: sending) }
        do {
            let reply = try await send(url: components.url!, method: "POST", headers: writeHeaders, rawBody: sending)
            SyncReport.record(config.provider, path: path, body: sending, reply: reply)
            return ServiceIDs.reply(reply, adding: prepared.missing)
        }
        catch APIError.rejected(let status, let message) where status != 429 {
            SyncReport.record(config.provider, path: path, body: sending, reply: Data("HTTP \(status): \(message)".utf8))
            if status == 401 || status == 403 {
                throw APIError.message("\(name) didn’t accept the sign-in for writing (HTTP \(status)). Reconnect it in Connections and allow changes.")
            }
            throw APIError.rejected(status, message)
        }
        catch APIError.rejected(let status, _) where status == 429 {
            // Too many requests: wait a moment and try once more.
            try await Task.sleep(for: .seconds(3))
            do { return ServiceIDs.reply(try await send(url: components.url!, method: "POST", headers: writeHeaders, rawBody: sending), adding: prepared.missing) }
            catch APIError.rejected(let again, _) where again == 429 {
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
            throw APIError.rejected(http.statusCode, "Provider returned HTTP \(http.statusCode).")
        }
        return data
    }

    // MARK: - Sign in with MDBList or WeTrakr (their sign-in page in Apple's sheet; PKCE, no client secret)

    /// Trades the code from the sign-in sheet for tokens.
    func finishWebSignIn(_ request: ProviderWebSignIn.Request, code: String) async throws -> ProviderDeviceSignIn.Tokens {
        if request.provider == .simkl {
            // Simkl: a form to its token route; a sign-in without media:write can't copy anything.
            let (data, status) = try await postForm(SimklAccount.tokenURL, ProviderWebSignIn.tokenBody(code: code, for: request))
            _ = try SimklAccount.tokens(from: data, status: status)
            switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
            case .authorized(let tokens): return tokens
            case .failed(let message): throw APIError.message(message)
            default: throw APIError.message("Simkl didn’t finish the sign-in (HTTP \(status)).")
            }
        }
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
    /// A new access token from the refresh token (MDBList: 30-day tokens; WeTrakr: 7 days).
    func refreshSignIn(provider: SyncProviderKind, clientId: String, refreshToken: String) async throws -> ProviderDeviceSignIn.Tokens {
        if provider == .simkl {
            // Simkl's tokens last a week; renewed a day before with the refresh token.
            let (data, status) = try await postForm(SimklAccount.tokenURL, ProviderDeviceSignIn.refreshBody(clientId: clientId, refreshToken: refreshToken))
            switch ProviderDeviceSignIn.decodePoll(status: status, data: data) {
            case .authorized(let tokens): return tokens
            case .failed(let message) where status == 400 || status == 401: throw ProviderRenewalError.signInEnded(message)
            case .failed(let message): throw APIError.message(message)
            default: throw APIError.message("Simkl didn’t renew the sign-in (HTTP \(status)).")
            }
        }
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

    // MARK: - Interactive OAuth Device Code Sign-In (Trakt)

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
        throw APIError.message("Only Trakt signs in with a code here.")
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
        return .expired
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
        case "api.mdblist.com": "MDBList"
        case "api.wetrakr.com": "WeTrakr"
        case "api.simkl.com": "Simkl"
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
        ProviderQuota.record(host: host, headers: headers, now: now)
        guard let until = ProviderCooldown.until(status: response.statusCode, headers: headers, now: now) else { return }
        let key = prefix + host
        UserDefaults.standard.set(max(UserDefaults.standard.double(forKey: key), until.timeIntervalSince1970), forKey: key)
    }
}

/// A service's daily request allowance as its own replies state it, kept per host for the
/// account limits page. Only headers that are explicitly daily count: WeTrakr's X-Quota-Limit,
/// -Remaining and -Reset (seconds to midnight UTC). (MDBList's X-RateLimit-* may describe its
/// five-minute window, so its daily count comes from /user instead.)
enum ProviderQuota {
    struct Daily: Codable, Equatable, Sendable {
        let used: Int
        let limit: Int
        let resetsAt: Date?
        let readAt: Date
    }
    private static let prefix = "providerQuota."
    static func record(host: String, headers: [String: String], now: Date = .now) {
        guard let daily = parse(headers, now: now), let data = try? JSONEncoder().encode(daily) else { return }
        UserDefaults.standard.set(data, forKey: prefix + host)
    }
    /// The last count for `host`; once its reset time has passed it's a new day (nothing used yet).
    static func daily(host: String, now: Date = .now) -> Daily? {
        guard let data = UserDefaults.standard.data(forKey: prefix + host),
              let saved = try? JSONDecoder().decode(Daily.self, from: data) else { return nil }
        if let reset = saved.resetsAt, reset <= now { return Daily(used: 0, limit: saved.limit, resetsAt: nil, readAt: saved.readAt) }
        return saved
    }
    static func parse(_ headers: [String: String], now: Date) -> Daily? {
        var lower: [String: String] = [:]
        for (key, value) in headers { lower[key.lowercased()] = value.trimmingCharacters(in: .whitespaces) }
        guard let limit = lower["x-quota-limit"].flatMap({ Int($0) }), limit > 0,
              let remaining = lower["x-quota-remaining"].flatMap({ Int($0) }) else { return nil }
        let resets = lower["x-quota-reset"].flatMap { Double($0) }.map { now.addingTimeInterval($0) }
        return Daily(used: max(0, limit - remaining), limit: limit, resetsAt: resets, readAt: now)
    }
}
