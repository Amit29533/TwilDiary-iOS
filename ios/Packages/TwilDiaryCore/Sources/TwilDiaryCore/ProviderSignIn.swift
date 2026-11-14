import Foundation
import CryptoKit

/// "Sign in with …" for services that use the standard device sign-in (RFC 8628): the app shows a
/// short code, you approve it on the service's site, and the app receives tokens. No client secret
/// is involved, so TwilDiary's own client ID (or yours) can sit on the phone.
///
/// - MDBList: a "Device Code App" registered at mdblist.com/developer (scope `write`).
public enum ProviderDeviceSignIn {
    public struct Endpoints: Equatable, Sendable {
        public let authorize: URL
        public let token: URL
        public let scope: String
    }
    public static func endpoints(for provider: SyncProviderKind) -> Endpoints? {
        switch provider {
        case .mdblist:
            Endpoints(authorize: URL(string: "https://api.mdblist.com/oauth/device-authorization/")!,
                      token: URL(string: "https://api.mdblist.com/oauth/token/")!, scope: "write")
        // WeTrakr: refreshing is its own route (`refresh`); the device flow isn't used.
        case .wetrakr:
            Endpoints(authorize: URL(string: "https://api.wetrakr.com/oauth/device/code")!,
                      token: URL(string: "https://api.wetrakr.com/oauth/token")!, scope: "")
        case .trakt, .simkl, .cloudflare:
            nil
        }
    }

    /// `application/x-www-form-urlencoded`, as both services expect.
    public static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(body.utf8)
    }
    public static func authorizeBody(clientId: String, scope: String) -> Data {
        form([("client_id", clientId), ("scope", scope)])
    }
    public static func pollBody(clientId: String, deviceCode: String) -> Data {
        form([("grant_type", "urn:ietf:params:oauth:grant-type:device_code"), ("device_code", deviceCode), ("client_id", clientId)])
    }
    public static func refreshBody(clientId: String, refreshToken: String) -> Data {
        form([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientId)])
    }

    /// What to show while waiting for approval.
    public struct Authorization: Equatable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURL: URL
        /// The same page with the code filled in, when the service offers one.
        public let verificationURLComplete: URL?
        public let expiresIn: Int
        public let interval: Int
    }
    public static func decodeAuthorization(_ data: Data) throws -> Authorization {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device_code"] as? String, !device.isEmpty,
              let user = object["user_code"] as? String, !user.isEmpty,
              let page = (object["verification_uri"] as? String ?? object["verification_url"] as? String).flatMap({ URL(string: $0) }),
              page.scheme == "https" else {
            throw ProviderSignInError.unexpected("The service didn’t start a sign-in.")
        }
        let complete = (object["verification_uri_complete"] as? String).flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
        return Authorization(deviceCode: device, userCode: user, verificationURL: page, verificationURLComplete: complete,
                             expiresIn: max(60, (object["expires_in"] as? Int) ?? 600), interval: min(max((object["interval"] as? Int) ?? 5, 1), 60))
    }

    public struct Tokens: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        /// ISO 8601, from `expires_in`.
        public let expiresAt: String?
        public let scope: String?
    }
    public enum Poll: Equatable, Sendable {
        case authorized(Tokens)
        /// Not approved yet: ask again after `interval` seconds.
        case pending
        /// Asked too often: wait 5 seconds longer from now on.
        case slowDown
        case expired
        case denied
        case failed(String)
    }
    /// Reads a token-endpoint reply (the poll, or a refresh): tokens on success, otherwise the
    /// standard `error` codes. A service may send no deny signal, so the caller also times out.
    public static func decodePoll(status: Int, data: Data, now: Date = .now) -> Poll {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status), let access = object["access_token"] as? String, !access.isEmpty {
            let expires = (object["expires_in"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue).formatted(.iso8601) }
            return .authorized(Tokens(accessToken: access, refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                      expiresAt: expires, scope: object["scope"] as? String))
        }
        switch object["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": return .expired
        case "access_denied": return .denied
        case "invalid_client", "unauthorized_client": return .failed("The service doesn’t recognise this app’s client ID.")
        case "invalid_grant": return .failed("The service no longer accepts this sign-in. Sign in again.")
        default: return .failed("The service answered HTTP \(status).")
        }
    }
}

public enum ProviderSignInError: LocalizedError, Equatable, Sendable {
    case unexpected(String)
    public var errorDescription: String? {
        switch self { case .unexpected(let message): message }
    }
}

/// "Sign in with …" the way Cinopsys does it: the service's own sign-in page opens in Apple's
/// sign-in sheet, you approve, and it returns to the app. Authorization code with PKCE: no client
/// secret, so the app ID can live on the phone (MDBList: a Public PKCE app; each registered with
/// the https return page's redirect for that service).
public enum ProviderWebSignIn {
    public static let callbackScheme = "twildiary"
    /// The https return address (workers/auth-return): live Trakt apps accept only https://
    /// redirects, so Trakt sends the browser there and it hands the reply to
    /// twildiary://auth/trakt, which Apple's sign-in sheet catches, as Cinopsys does with its site.
    public static let returnSite = "https://twildiary-auth.amit29533.workers.dev"
    /// The redirect registered with the service (and sent in the token exchange).
    public static func redirect(for provider: SyncProviderKind) -> String {
        // Simkl: the app address registered with Simkl (its pages accept custom schemes).
        if provider == .simkl { return callbackScheme + "://auth/simkl" }
        // Trakt, MDBList and WeTrakr (as Cinopsys signs in to them) through the https page.
        return returnSite + "/" + provider.rawValue
    }
    static func authorizePage(for provider: SyncProviderKind) -> URL? {
        switch provider {
        case .mdblist: URL(string: "https://mdblist.com/oauth/authorize/")
        case .trakt: URL(string: "https://auth.trakt.tv/oauth/authorize")
        case .wetrakr: URL(string: "https://api.wetrakr.com/oauth/authorize")
        case .simkl: URL(string: "https://simkl.com/oauth2/authorize")
        case .cloudflare: nil
        }
    }
    /// What the app asks for. Trakt has no scopes: a sign-in can always read and write.
    static func scope(for provider: SyncProviderKind) -> String? {
        if provider == .simkl { return "media:read media:write" }
        return provider == .trakt || provider == .wetrakr ? nil : ProviderDeviceSignIn.endpoints(for: provider)?.scope
    }

    /// One sign-in attempt: what to open, and what to check when the service comes back.
    public struct Request: Equatable, Sendable {
        public let provider: SyncProviderKind
        public let clientId: String
        public let state: String
        public let verifier: String
        public let url: URL
    }

    public static func start(provider: SyncProviderKind, clientId: String, randomBytes: (Int) -> [UInt8] = secureBytes) -> Request? {
        let client = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty, let page = authorizePage(for: provider) else { return nil }
        let scope = scope(for: provider)
        guard provider == .trakt || provider == .wetrakr || scope != nil else { return nil }
        let verifier = base64URL(Data(randomBytes(64)))
        let state = base64URL(Data(randomBytes(24)))
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "redirect_uri", value: redirect(for: provider)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if let scope { components.queryItems?.insert(URLQueryItem(name: "scope", value: scope), at: 3) }
        guard let url = components.url else { return nil }
        return Request(provider: provider, clientId: client, state: state, verifier: verifier, url: url)
    }

    /// The code from the service's reply, once it is checked: same attempt (state), the right
    /// service, and not declined.
    public static func code(from callback: URL, for request: Request) throws -> String {
        guard callback.scheme == callbackScheme, callback.host == "auth", callback.path == "/" + request.provider.rawValue, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ProviderSignInError.unexpected("The sign-in came back in a form TwilDiary doesn’t recognise.")
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == request.state else { throw ProviderSignInError.unexpected("This sign-in doesn’t match the one TwilDiary started. Try again.") }
        if let error = value("error") {
            throw ProviderSignInError.unexpected(error == "access_denied" ? "The sign-in was declined." : "The service refused the sign-in (\(error)).")
        }
        guard let code = value("code"), !code.isEmpty else { throw ProviderSignInError.unexpected("The service didn’t return a sign-in code.") }
        return code
    }

    public static func tokenBody(code: String, for request: Request) -> Data {
        ProviderDeviceSignIn.form([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect(for: request.provider)),
                                   ("client_id", request.clientId), ("code_verifier", request.verifier)])
    }

    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func secureBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// Trakt signed in on this iPhone, without TwilDiary's server: Trakt's own sign-in page in Apple's
/// sheet (`ProviderWebSignIn`, redirect `twildiary://auth/trakt`, PKCE), then Trakt's token route
/// with JSON bodies and no client secret, the same requests the server makes today. Trakt replaces
/// the refresh token on every renewal, so the pair is always saved together.
public enum TraktPhoneSignIn {
    public static let tokenURL = URL(string: "https://api.trakt.tv/oauth/token")!
    public static let revokeURL = URL(string: "https://api.trakt.tv/oauth/revoke")!
    /// Renew this long before the access token stops working.
    public static let renewalMargin: TimeInterval = 15 * 60

    static func json(_ fields: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }
    public static func codeBody(code: String, for request: ProviderWebSignIn.Request) -> Data {
        json(["code": code, "client_id": request.clientId, "redirect_uri": ProviderWebSignIn.redirect(for: .trakt),
              "grant_type": "authorization_code", "code_verifier": request.verifier])
    }
    public static func refreshBody(clientId: String, refreshToken: String) -> Data {
        json(["refresh_token": refreshToken, "client_id": clientId, "redirect_uri": ProviderWebSignIn.redirect(for: .trakt),
              "grant_type": "refresh_token"])
    }
    public static func revokeBody(clientId: String, token: String) -> Data {
        json(["token": token, "client_id": clientId])
    }
    /// Trakt's answer: both tokens are required (a renewal without a new refresh token would leave
    /// the next renewal with a spent one).
    public static func decode(status: Int, data: Data, now: Date = .now) -> ProviderDeviceSignIn.Poll {
        let poll = ProviderDeviceSignIn.decodePoll(status: status, data: data, now: now)
        if case .authorized(let tokens) = poll, tokens.refreshToken == nil || tokens.expiresAt == nil {
            return .failed("Trakt returned an incomplete sign-in. Sign in again.")
        }
        return poll
    }
    /// The account name from `GET /users/settings`.
    public static func username(from data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let user = object?["user"] as? [String: Any]
        let name = (user?["username"] as? String) ?? ((user?["ids"] as? [String: Any])?["slug"] as? String)
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
