import Foundation
import Security
import CryptoKit
import Observation
import AuthenticationServices
import SwiftUI

// The Simkl add-on (owner's design, 2026-11-14): everything Simkl is in this folder, reached
// from three lines elsewhere (an edit is copied, the Connections row, resume on foreground).
// Removing it is deleting this folder and those lines; "Disconnect and remove" clears what it
// kept on the phone. Simkl never holds the diary: it gets a copy of what you do in TwilDiary.

/// What the add-on keeps on this iPhone, all under one name: Keychain items under `service`,
/// settings under `prefix`, files in `folder`.
enum SimklStorage {
    static let service = "twildiary.simkl.addon"
    static let prefix = "simkl.addon."
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "SimklAddOn") }

    static func secret(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func setSecret(_ value: String?, _ name: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(match as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func file(_ name: String) -> URL { folder.appending(path: name) }
    static func save<Value: Encodable>(_ value: Value, _ name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: file(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
    static func load<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    /// Everything the add-on kept on this iPhone. Nothing on Simkl changes.
    static func removeEverything(defaults: UserDefaults = .standard) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Signing in to Simkl and the "Also save my activity to Simkl" switch.
/// Sign-in: Simkl's own page in Apple's sign-in sheet (OAuth 2 with PKCE, no secret on the phone),
/// back to twildiary://auth/simkl, the app registered with Simkl before. Simkl's tokens last a
/// week and are renewed with the refresh token.
@MainActor @Observable final class SimklAccount {
    static let shared = SimklAccount()
    /// TwilDiary's Simkl app (an app ID is public; there's no secret).
    nonisolated static let clientId = "b8a8608d8971e7efeb787d21fde2e236704c066749a9bb2cc1367314421d657e"
    nonisolated static let redirect = "twildiary://auth/simkl"
    nonisolated static let scope = "media:read media:write"
    private static let enabledKey = SimklStorage.prefix + "enabled"
    private static let nameKey = SimklStorage.prefix + "username"

    private(set) var signedIn: Bool
    private(set) var username: String?
    /// Copy what you do to Simkl (off until you turn it on).
    var saving: Bool {
        didSet {
            UserDefaults.standard.set(saving, forKey: Self.enabledKey)
            if saving { Task { await SimklMirror.shared.resume() } }
        }
    }

    init() {
        signedIn = SimklStorage.secret("access") != nil
        username = UserDefaults.standard.string(forKey: Self.nameKey)
        saving = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var canSend: Bool { signedIn && saving }

    // MARK: Sign-in

    struct Attempt: Equatable, Sendable { let state: String; let verifier: String; let url: URL }

    nonisolated static func start(randomBytes: (Int) -> [UInt8] = SimklAccount.secureBytes) -> Attempt {
        let verifier = base64URL(Data(randomBytes(64))), state = base64URL(Data(randomBytes(24)))
        var page = URLComponents(string: "https://simkl.com/oauth2/authorize")!
        page.queryItems = [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientId),
                           URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "scope", value: scope),
                           URLQueryItem(name: "state", value: state),
                           URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                           URLQueryItem(name: "code_challenge_method", value: "S256")]
        return Attempt(state: state, verifier: verifier, url: page.url!)
    }
    /// The code from Simkl's reply, checked: this attempt, not declined.
    nonisolated static func code(from callback: URL, for attempt: Attempt) throws -> String {
        guard callback.scheme == "twildiary", callback.host == "auth", callback.path == "/simkl",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw APIError.message("The Simkl sign-in came back in a form TwilDiary doesn’t recognise.")
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == attempt.state else { throw APIError.message("This sign-in doesn’t match the one TwilDiary started. Try again.") }
        if let error = value("error") { throw APIError.message(error == "access_denied" ? "The Simkl sign-in was declined." : "Simkl refused the sign-in (\(error)).") }
        guard let code = value("code"), !code.isEmpty else { throw APIError.message("Simkl didn’t return a sign-in code.") }
        return code
    }

    struct Tokens: Equatable, Sendable { let access: String; let refresh: String?; let expires: Date?; let scope: String? }
    /// Simkl's token reply. A sign-in without `media:write` (read-only) can't copy anything.
    nonisolated static func tokens(from data: Data, status: Int, now: Date = .now) throws -> Tokens {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let access = object["access_token"] as? String, !access.isEmpty else {
            let reason = (object["error_description"] as? String) ?? (object["error"] as? String) ?? "HTTP \(status)"
            throw APIError.message("Simkl didn’t finish the sign-in (\(reason)).")
        }
        let scope = object["scope"] as? String
        if let scope, !scope.split(separator: " ").contains("media:write") {
            throw APIError.message("Simkl gave read-only access. Sign in again and allow TwilDiary to make changes.")
        }
        let seconds = (object["expires_in"] as? NSNumber)?.doubleValue
        return Tokens(access: access, refresh: object["refresh_token"] as? String, expires: seconds.map { now.addingTimeInterval($0) }, scope: scope)
    }
    nonisolated static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }.joined(separator: "&").utf8)
    }

    /// Opens Simkl's page, trades the code for tokens and saves them. Returns false if cancelled.
    func signIn(using session: WebAuthenticationSession, urlSession: URLSession = .shared) async throws -> Bool {
        let attempt = Self.start()
        let callback: URL
        do { callback = try await session.authenticate(using: attempt.url, callbackURLScheme: "twildiary") }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { return false }
        let code = try Self.code(from: callback, for: attempt)
        let tokens = try await exchange([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Self.redirect),
                                         ("client_id", Self.clientId), ("code_verifier", attempt.verifier)], session: urlSession)
        keep(tokens)
        if let data = try? await SimklAPI(token: tokens.access, session: urlSession).get("/users/settings"),
           let user = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["user"] as? [String: Any],
           let name = user["name"] as? String, !name.isEmpty {
            username = name
            UserDefaults.standard.set(name, forKey: Self.nameKey)
        }
        return true
    }

    private func exchange(_ fields: [(String, String)], session: URLSession) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://api.simkl.com/oauth2/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.form(fields)
        let (data, response) = try await session.data(for: request)
        return try Self.tokens(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private func keep(_ tokens: Tokens) {
        SimklStorage.setSecret(tokens.access, "access")
        if let refresh = tokens.refresh { SimklStorage.setSecret(refresh, "refresh") }
        SimklStorage.setSecret(tokens.expires.map { String($0.timeIntervalSince1970) }, "expires")
        signedIn = true
    }

    /// A working access token: renewed a day before Simkl's week runs out.
    func token(session: URLSession = .shared) async -> String? {
        guard let access = SimklStorage.secret("access") else { return nil }
        guard let expires = SimklStorage.secret("expires").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
              expires.timeIntervalSinceNow < 86_400 else { return access }
        return await renew(session: session) ?? (expires > .now ? access : nil)
    }
    /// A new token from the refresh token; nil if Simkl won't (then you sign in again).
    func renew(session: URLSession = .shared) async -> String? {
        guard let refresh = SimklStorage.secret("refresh"),
              let tokens = try? await exchange([("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", Self.clientId)], session: session)
        else { return nil }
        keep(tokens)
        return tokens.access
    }
    /// Simkl refused the token: you're shown as signed out, with what's waiting kept.
    func signInLapsed() { signedIn = false; SimklStorage.setSecret(nil, "access") }

    /// Disconnects and removes everything the add-on kept on this iPhone.
    func removeEverything() {
        SimklMirror.shared.forget()
        saving = false; signedIn = false; username = nil
        SimklStorage.removeEverything()
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    nonisolated static func secureBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
