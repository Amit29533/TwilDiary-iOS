import Foundation
import AuthenticationServices
import SwiftUI
import TwilDiaryCore

/// TwilDiary's own app IDs for "Sign in with …", so signing in is one tap with nothing to paste.
/// Client IDs are public (no secrets): they come from the build (`TWILDIARY_TRAKT_CLIENT_ID` and
/// friends in the build settings, read from Info.plist), else the last ones your server listed
/// (`GET /api/providers/apps`), remembered on this iPhone.
@MainActor enum ProviderAppIDs {
    private static let defaultsKey = "providerAppIDs"
    private static func infoKey(_ provider: SyncProviderKind) -> String? {
        switch provider {
        case .trakt: "TwilDiaryTraktClientID"
        case .simkl: "TwilDiarySimklClientID"
        case .mdblist: "TwilDiaryMDBListClientID"
        case .cloudflare: nil
        }
    }
    static func id(for provider: SyncProviderKind, defaults: UserDefaults = .standard) -> String? {
        #if DEBUG
        // UI tests show the one-tap buttons (they never open a real sign-in page).
        if provider == .trakt, ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "preview-trakt" }
        #endif
        if let key = infoKey(provider), let built = Bundle.main.object(forInfoDictionaryKey: key) as? String, let value = clean(built) { return value }
        return (defaults.dictionary(forKey: defaultsKey) as? [String: String])?[provider.rawValue].flatMap(clean)
    }
    /// Keeps what the server listed (a missing one leaves the earlier value).
    static func remember(_ ids: [SyncProviderKind: String?], defaults: UserDefaults = .standard) {
        var saved = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        for (provider, value) in ids { if let value = value.flatMap(clean) { saved[provider.rawValue] = value } }
        defaults.set(saved, forKey: defaultsKey)
    }
    /// Asks your server once per launch for its app IDs and remembers them.
    static func refresh(store: DiaryStore) async {
        guard !store.isPreview, !store.needsSignIn, !refreshed else { return }
        struct Apps: Decodable { let trakt: String?; let simkl: String?; let mdblist: String? }
        guard let apps: Apps = try? await store.read("/api/providers/apps") else { return }
        refreshed = true
        remember([.trakt: apps.trakt, .simkl: apps.simkl, .mdblist: apps.mdblist])
    }
    private static var refreshed = false
    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting arrives as "" or as its own "$(NAME)".
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }
}

/// One-tap sign-in: the service's own page in Apple's sign-in sheet, back to the app signed in.
/// Trakt and Simkl only; MDBList's sign-in is a device code shown on its page.
enum ServiceSignIn {
    enum Outcome: Equatable { case signedIn(String), cancelled }

    static func supportsSheet(_ provider: SyncProviderKind) -> Bool { provider == .trakt || provider == .simkl }

    /// Opens the page, checks the reply and trades the code for tokens. Nothing is saved here.
    @MainActor static func tokens(_ provider: SyncProviderKind, clientId: String, using session: WebAuthenticationSession,
                                  client: DirectProviderClient) async throws -> ProviderDeviceSignIn.Tokens? {
        guard let request = ProviderWebSignIn.start(provider: provider, clientId: clientId) else {
            throw APIError.message("TwilDiary can’t sign in to \(provider.displayName) yet.")
        }
        let callback: URL
        do { callback = try await session.authenticate(using: request.url, callbackURLScheme: ProviderWebSignIn.callbackScheme) }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { return nil }
        let code = try ProviderWebSignIn.code(from: callback, for: request)
        return try await client.finishWebSignIn(request, code: code)
    }

    /// Signs this iPhone in to the service and turns it on.
    @MainActor static func run(_ provider: SyncProviderKind, store: DiaryStore, using session: WebAuthenticationSession) async throws -> Outcome {
        await ProviderAppIDs.refresh(store: store)
        guard let clientId = ProviderAppIDs.id(for: provider) else {
            throw APIError.message("TwilDiary’s \(provider.displayName) app isn’t set up yet. Open \(provider.displayName) in Connections to add it once.")
        }
        guard let tokens = try await tokens(provider, clientId: clientId, using: session, client: store.directClient) else { return .cancelled }
        if provider == .trakt {
            try await store.finishTraktPhoneSignIn(clientId: clientId, tokens: tokens)
            return .signedIn(store.providerSettings.config(for: .trakt).username.map { "@" + $0 } ?? "Trakt")
        }
        guard ProviderDeviceSignIn.grantsWrite(tokens, provider: provider) else {
            throw APIError.message("\(provider.displayName) gave read-only access. Sign in again and allow TwilDiary to make changes.")
        }
        var signedIn = store.providerSettings.config(for: provider)
        signedIn.clientId = clientId; signedIn.accessToken = tokens.accessToken
        signedIn.refreshToken = tokens.refreshToken; signedIn.tokenExpiresAt = tokens.expiresAt
        signedIn.connection = .signIn; signedIn.enabled = true
        if !signedIn.loggingMethod.includesDirectAPI { signedIn.loggingMethod = .serverAndDirectAPI }
        guard store.updateProviderConfig(signedIn) else { throw APIError.message(store.error ?? "The sign-in couldn’t be saved.") }
        return .signedIn(provider.displayName)
    }
}

/// A Trakt sign-in made on the sign-in page, before the diary session exists: saved to this
/// iPhone's Trakt connection as soon as you're signed in to the diary.
@MainActor enum PendingTraktSignIn {
    static var waiting: (clientId: String, tokens: ProviderDeviceSignIn.Tokens)?
    static func adopt(store: DiaryStore) async {
        guard let waiting else { return }
        self.waiting = nil
        try? await store.finishTraktPhoneSignIn(clientId: waiting.clientId, tokens: waiting.tokens)
    }
}
