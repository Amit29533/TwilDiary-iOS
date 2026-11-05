import Foundation

/// "Sign in with …" for services that use the standard device sign-in (RFC 8628): the app shows a
/// short code, you approve it on the service's site, and the app receives tokens. No client secret
/// is involved, so TwilDiary's own client ID (or yours) can sit on the phone.
///
/// - MDBList: a "Device Code App" registered at mdblist.com/developer (scope `write`).
/// - Simkl: an AUTH V2 app (scopes `media:read media:write`; without `media:write` Simkl quietly
///   grants read-only). Older AUTH V1 apps use Simkl's PIN flow instead.
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
        case .simkl:
            Endpoints(authorize: URL(string: "https://api.simkl.com/oauth2/device")!,
                      token: URL(string: "https://api.simkl.com/oauth2/token")!, scope: "media:read media:write")
        case .trakt, .cloudflare:
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
    /// standard `error` codes. Simkl has no deny signal, so the caller also times out.
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
    /// Simkl downgrades an unknown scope to read-only without an error; a sign-in without write
    /// access can't sync, so it is refused rather than saved.
    public static func grantsWrite(_ tokens: Tokens, provider: SyncProviderKind) -> Bool {
        guard provider == .simkl, let scope = tokens.scope else { return true }
        return scope.split(separator: " ").contains("media:write")
    }
}

public enum ProviderSignInError: LocalizedError, Equatable, Sendable {
    case unexpected(String)
    public var errorDescription: String? {
        switch self { case .unexpected(let message): message }
    }
}
