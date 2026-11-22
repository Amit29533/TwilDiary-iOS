import Foundation
import Security
import TwilDiaryCore
import Observation
import AuthenticationServices
import SwiftUI

// Simkl as a service of its own (2026-11-14): signed in like MDBList and WeTrakr (its tokens in
// the shared provider settings, encrypted on this iPhone), kept in step with the diary by its own
// sync (SimklMirror: each edit placed in Simkl's own numbering), never the main tracker.

/// What Simkl's sync keeps on this iPhone (its waiting list, what Simkl didn't keep, look-ups),
/// all under one name: files in `folder`; Keychain items under `service` and settings under
/// `prefix` only from the add-on's first build (moved into the provider settings on first launch).
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
    /// Everything Simkl's sync kept on this iPhone. Nothing on Simkl changes.
    static func removeEverything(defaults: UserDefaults = .standard) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Simkl's sign-in and the "Also save my activity to Simkl" switch, kept in the shared provider
/// settings (`providerSettings.simkl`). Signing in goes through the shared web sign-in
/// (`ServiceSignIn`): Simkl's page in Apple's sheet, OAuth 2 with PKCE, back to
/// twildiary://auth/simkl. Simkl's tokens last a week; they're renewed a day before.
@MainActor @Observable final class SimklAccount {
    static let shared = SimklAccount()
    /// TwilDiary's Simkl app (an app ID is public; there's no secret).
    nonisolated static let clientId = "b8a8608d8971e7efeb787d21fde2e236704c066749a9bb2cc1367314421d657e"
    nonisolated static let tokenURL = URL(string: "https://api.simkl.com/oauth2/token")!
    private static let enabledKey = SimklStorage.prefix + "enabled"
    private static let nameKey = SimklStorage.prefix + "username"

    /// The diary's store, for the provider settings (set on launch and with each edit).
    @ObservationIgnored private weak var store: DiaryStore?
    private var config: ExternalProviderConfig { store?.providerSettings.simkl ?? ExternalProviderConfig(provider: .simkl) }

    var signedIn: Bool { config.isAuthenticated }
    var username: String? { config.username }
    /// Copy what you do to Simkl (off until you turn it on).
    var saving: Bool {
        get { config.enabled }
        set {
            guard let store, newValue != config.enabled else { return }
            var next = config; next.enabled = newValue
            store.updateProviderConfig(next)
            if newValue { Task { await SimklMirror.shared.resume() } }
        }
    }
    var canSend: Bool { signedIn && saving }

    /// Remembers the store, and once moves a sign-in made with the add-on's first build (its own
    /// Keychain items) into the provider settings, so nobody signs in twice.
    func adopt(_ store: DiaryStore) {
        guard !store.isPreview else { return }
        self.store = store
        guard !store.providerSettings.simkl.isAuthenticated, let access = SimklStorage.secret("access") else { return }
        var moved = store.providerSettings.simkl
        moved.clientId = Self.clientId; moved.accessToken = access; moved.refreshToken = SimklStorage.secret("refresh")
        moved.tokenExpiresAt = SimklStorage.secret("expires").flatMap(Double.init).map { Date(timeIntervalSince1970: $0).ISO8601Format() }
        moved.username = UserDefaults.standard.string(forKey: Self.nameKey)
        moved.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        moved.connection = .signIn
        guard store.updateProviderConfig(moved) else { return }
        for name in ["access", "refresh", "expires"] { SimklStorage.setSecret(nil, name) }
        UserDefaults.standard.removeObject(forKey: Self.enabledKey); UserDefaults.standard.removeObject(forKey: Self.nameKey)
    }

    /// After a sign-in (`ServiceSignIn`): the account name, then what's waiting goes.
    func signedIn(store: DiaryStore) async {
        adopt(store)
        if let token = config.accessToken, let data = try? await SimklAPI(token: token).get("/users/settings"),
           let user = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["user"] as? [String: Any],
           let name = user["name"] as? String, !name.isEmpty {
            var named = config; named.username = name
            store.updateProviderConfig(named)
        }
        await SimklMirror.shared.resume(store: store)
    }

    /// Signs in on Simkl's page. Returns false if cancelled.
    func signIn(using session: WebAuthenticationSession) async throws -> Bool {
        guard let store else { throw APIError.message("Open TwilDiary’s diary first, then sign in to Simkl.") }
        if case .signedIn = try await ServiceSignIn.run(.simkl, store: store, using: session) { return true }
        return false
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

    /// A working access token (renewed a day before Simkl's week runs out).
    func token(session: URLSession = .shared) async -> String? {
        guard let store else { return nil }
        return await store.freshProviderConfig(.simkl).accessToken
    }
    /// A new token now (Simkl refused the current one); nil if Simkl won't (then you sign in again).
    func renew(session: URLSession = .shared) async -> String? {
        guard let store, let refresh = config.refreshToken, let clientId = config.clientId,
              let tokens = try? await store.directClient.refreshSignIn(provider: .simkl, clientId: clientId, refreshToken: refresh) else { return nil }
        var renewed = config
        renewed.accessToken = tokens.accessToken; renewed.refreshToken = tokens.refreshToken ?? refresh; renewed.tokenExpiresAt = tokens.expiresAt
        return store.updateProviderConfig(renewed) ? tokens.accessToken : nil
    }
    /// Simkl refused the token: you're shown as signed out, with what's waiting kept.
    func signInLapsed() {
        guard let store else { return }
        var lapsed = config; lapsed.accessToken = nil
        store.updateProviderConfig(lapsed)
    }

    /// Disconnects and removes everything TwilDiary kept for Simkl on this iPhone.
    func removeEverything() {
        SimklMirror.shared.forget()
        AccountProfiles.shared.forget(.simkl)
        store?.updateProviderConfig(ExternalProviderConfig(provider: .simkl))
        SimklStorage.removeEverything()
    }
}
