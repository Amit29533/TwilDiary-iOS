import Foundation
import Testing
@testable import TwilDiaryCore

private func json(_ text: String) -> Data { Data(text.utf8) }

@Test func mdblistAndSimklUseTheirDocumentedDeviceSignIn() throws {
    let mdblist = try #require(ProviderDeviceSignIn.endpoints(for: .mdblist))
    #expect(mdblist.authorize.absoluteString == "https://api.mdblist.com/oauth/device-authorization/")
    #expect(mdblist.token.absoluteString == "https://api.mdblist.com/oauth/token/", "MDBList needs the trailing slash")
    #expect(mdblist.scope == "write")
    let simkl = try #require(ProviderDeviceSignIn.endpoints(for: .simkl))
    #expect(simkl.authorize.absoluteString == "https://api.simkl.com/oauth2/device")
    #expect(simkl.scope == "media:read media:write")
    #expect(ProviderDeviceSignIn.endpoints(for: .trakt) == nil)
    #expect(String(decoding: ProviderDeviceSignIn.authorizeBody(clientId: "abc 1", scope: simkl.scope), as: UTF8.self)
            == "client_id=abc%201&scope=media%3Aread%20media%3Awrite")
    #expect(String(decoding: ProviderDeviceSignIn.pollBody(clientId: "abc", deviceCode: "d/1"), as: UTF8.self)
            == "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=d%2F1&client_id=abc")
}

@Test func theCodeToShowAndThePageToOpenAreRead() throws {
    let auth = try ProviderDeviceSignIn.decodeAuthorization(json("""
    {"device_code":"dev-1","user_code":"WDJB-MJHT","verification_uri":"https://mdblist.com/oauth/device/",
     "verification_uri_complete":"https://mdblist.com/oauth/device/?user_code=WDJB-MJHT","expires_in":300,"interval":5}
    """))
    #expect(auth.userCode == "WDJB-MJHT" && auth.deviceCode == "dev-1" && auth.expiresIn == 300 && auth.interval == 5)
    #expect(auth.verificationURLComplete?.absoluteString == "https://mdblist.com/oauth/device/?user_code=WDJB-MJHT")
    #expect(throws: ProviderSignInError.self) { try ProviderDeviceSignIn.decodeAuthorization(json(#"{"user_code":"X"}"#)) }
    #expect(throws: ProviderSignInError.self) {
        try ProviderDeviceSignIn.decodeAuthorization(json(#"{"device_code":"d","user_code":"X","verification_uri":"http://insecure.example"}"#))
    }
}

@Test func everyPollOutcomeIsRecognised() throws {
    let now = try Date("2026-11-05T10:00:00Z", strategy: .iso8601)
    let ok = ProviderDeviceSignIn.decodePoll(status: 200, data: json("""
    {"access_token":"tok","token_type":"Bearer","expires_in":2592000,"refresh_token":"ref","scope":"write"}
    """), now: now)
    #expect(ok == .authorized(.init(accessToken: "tok", refreshToken: "ref", expiresAt: "2026-12-05T10:00:00Z", scope: "write")))
    #expect(ProviderDeviceSignIn.decodePoll(status: 400, data: json(#"{"error":"authorization_pending"}"#)) == .pending)
    #expect(ProviderDeviceSignIn.decodePoll(status: 400, data: json(#"{"error":"slow_down"}"#)) == .slowDown)
    #expect(ProviderDeviceSignIn.decodePoll(status: 400, data: json(#"{"error":"expired_token"}"#)) == .expired)
    #expect(ProviderDeviceSignIn.decodePoll(status: 400, data: json(#"{"error":"access_denied"}"#)) == .denied)
    if case .failed = ProviderDeviceSignIn.decodePoll(status: 401, data: json(#"{"error":"invalid_client"}"#)) {} else { Issue.record("invalid_client must fail") }
    if case .failed = ProviderDeviceSignIn.decodePoll(status: 500, data: Data()) {} else { Issue.record("An empty error must fail") }
}

@Test func aSimklSignInWithoutWriteAccessIsNotSaved() {
    let readOnly = ProviderDeviceSignIn.Tokens(accessToken: "t", refreshToken: nil, expiresAt: nil, scope: "media:read")
    let writable = ProviderDeviceSignIn.Tokens(accessToken: "t", refreshToken: nil, expiresAt: nil, scope: "media:read media:write")
    #expect(!ProviderDeviceSignIn.grantsWrite(readOnly, provider: .simkl))
    #expect(ProviderDeviceSignIn.grantsWrite(writable, provider: .simkl))
    #expect(ProviderDeviceSignIn.grantsWrite(readOnly, provider: .mdblist), "Only Simkl downgrades quietly")
}

@Test func signInTokensRefreshBeforeTheyExpireAndNeverReachPlainPreferences() throws {
    let now = try Date("2026-11-05T10:00:00Z", strategy: .iso8601)
    var config = ExternalProviderConfig(provider: .mdblist, enabled: true, clientId: "app", accessToken: "tok",
                                        refreshToken: "ref", tokenExpiresAt: "2026-11-05T20:00:00Z", connection: .signIn)
    #expect(config.isAuthenticated, "MDBList counts as connected with a sign-in token and no API key")
    #expect(config.needsRefresh(now: now), "Under a day left")
    config.tokenExpiresAt = "2026-12-05T10:00:00Z"
    #expect(!config.needsRefresh(now: now))
    config.refreshToken = nil; config.tokenExpiresAt = "2026-11-05T11:00:00Z"
    #expect(!config.needsRefresh(now: now), "Nothing to refresh with")
    // Saved settings keep tokens in the Keychain envelope only.
    final class Secrets: ProviderSecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        func readSecret(for account: String) throws -> String? { values[account] }
        func writeSecret(_ value: String?, for account: String) -> Bool { values[account] = value; return true }
    }
    let defaults = try #require(UserDefaults(suiteName: "provider-signin-\(UUID().uuidString)"))
    let secrets = Secrets()
    let store = UserDefaultsProviderSettingsStore(defaults: defaults, key: "test.settings", secrets: secrets)
    var settings = ProviderConnectionSettings()
    settings.setConfig(ExternalProviderConfig(provider: .simkl, enabled: true, clientId: "app", accessToken: "secret-access",
                                              refreshToken: "secret-refresh", tokenExpiresAt: "2026-11-12T10:00:00Z", connection: .signIn))
    try store.save(settings)
    let plain = String(decoding: try #require(defaults.data(forKey: "test.settings")), as: UTF8.self)
    #expect(!plain.contains("secret-access") && !plain.contains("secret-refresh"))
    #expect(try store.load().simkl.refreshToken == "secret-refresh")
    #expect(try store.load().simkl.connection == .signIn)
}

@Test func webSignInOpensTheServicePageWithPKCEAndChecksTheReply() throws {
    var counter: UInt8 = 0
    let bytes: (Int) -> [UInt8] = { count in (0..<count).map { _ in counter &+= 1; return counter } }
    let simkl = try #require(ProviderWebSignIn.start(provider: .simkl, clientId: " simkl-app ", randomBytes: bytes))
    let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: simkl.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(simkl.url.host == "simkl.com" && simkl.url.path == "/oauth2/authorize")
    #expect(query["client_id"] == "simkl-app" && query["response_type"] == "code" && query["code_challenge_method"] == "S256")
    #expect(query["redirect_uri"] == "twildiary://auth/simkl" && query["scope"] == "media:read media:write")
    #expect(query["code_challenge"] == ProviderWebSignIn.challenge(for: simkl.verifier))
    #expect((43...128).contains(simkl.verifier.count))
    // RFC 7636 appendix B: the S256 challenge of the sample verifier.
    #expect(ProviderWebSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let good = URL(string: "twildiary://auth/simkl?code=abc&state=\(simkl.state)&iss=https://simkl.com")!
    #expect(try ProviderWebSignIn.code(from: good, for: simkl) == "abc")
    #expect(throws: ProviderSignInError.self) { try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/simkl?code=abc&state=other&iss=https://simkl.com")!, for: simkl) }
    #expect(throws: ProviderSignInError.self) { try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/simkl?code=abc&state=\(simkl.state)&iss=https://evil.example")!, for: simkl) }
    #expect(throws: ProviderSignInError.unexpected("The sign-in was declined.")) {
        try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/simkl?error=access_denied&state=\(simkl.state)&iss=https://simkl.com")!, for: simkl)
    }
    let body = String(decoding: ProviderWebSignIn.tokenBody(code: "abc", for: simkl), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code") && body.contains("code_verifier=" + simkl.verifier) && !body.contains("client_secret"))
    let mdblist = try #require(ProviderWebSignIn.start(provider: .mdblist, clientId: "md-app"))
    #expect(mdblist.url.absoluteString.hasPrefix("https://mdblist.com/oauth/authorize/?"))
    // MDBList's Public PKCE apps take an https redirect: the return page hands it to the app.
    #expect(ProviderWebSignIn.redirect(for: .mdblist) == "https://twildiary-auth.amit29533.workers.dev/mdblist")
    #expect(try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/mdblist?code=xyz&state=\(mdblist.state)")!, for: mdblist) == "xyz")
    #expect(ProviderWebSignIn.start(provider: .cloudflare, clientId: "x") == nil && ProviderWebSignIn.start(provider: .simkl, clientId: "  ") == nil)
}

/// Trakt on the phone: Trakt's own page with PKCE and no scope, JSON token requests without a
/// client secret (as the server sends them), and a renewal is only kept with both new tokens.
@Test func traktSignsInOnThePhoneWithPKCE() throws {
    let trakt = try #require(ProviderWebSignIn.start(provider: .trakt, clientId: "trakt-app"))
    let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: trakt.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(trakt.url.host == "auth.trakt.tv" && trakt.url.path == "/oauth/authorize")
    // Trakt takes only https:// redirects: its return page hands the reply to twildiary://auth/trakt.
    #expect(query["redirect_uri"] == "https://twildiary-auth.amit29533.workers.dev/trakt" && query["scope"] == nil && query["code_challenge_method"] == "S256")
    #expect(try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/trakt?code=c0de&state=\(trakt.state)")!, for: trakt) == "c0de")
    #expect(throws: ProviderSignInError.self) { try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/trakt?code=c0de&state=nope")!, for: trakt) }
    // Another service's return address is refused, even with the right state.
    #expect(throws: ProviderSignInError.self) { try ProviderWebSignIn.code(from: URL(string: "twildiary://auth/simkl?code=c0de&state=\(trakt.state)")!, for: trakt) }

    let exchange = try #require(JSONSerialization.jsonObject(with: TraktPhoneSignIn.codeBody(code: "c0de", for: trakt)) as? [String: String])
    #expect(exchange == ["code": "c0de", "client_id": "trakt-app", "redirect_uri": "https://twildiary-auth.amit29533.workers.dev/trakt",
                         "grant_type": "authorization_code", "code_verifier": trakt.verifier])
    let renew = try #require(JSONSerialization.jsonObject(with: TraktPhoneSignIn.refreshBody(clientId: "trakt-app", refreshToken: "r1")) as? [String: String])
    #expect(renew["grant_type"] == "refresh_token" && renew["refresh_token"] == "r1" && renew["client_secret"] == nil)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reply = Data(#"{"access_token":"a2","refresh_token":"r2","expires_in":86400,"created_at":1800000000,"token_type":"bearer","scope":"public"}"#.utf8)
    guard case .authorized(let tokens) = TraktPhoneSignIn.decode(status: 200, data: reply, now: now) else { Issue.record("not signed in"); return }
    #expect(tokens.accessToken == "a2" && tokens.refreshToken == "r2" && tokens.expiresAt == now.addingTimeInterval(86_400).formatted(.iso8601))
    #expect(TraktPhoneSignIn.decode(status: 200, data: Data(#"{"access_token":"a2","expires_in":86400}"#.utf8), now: now)
            == .failed("Trakt returned an incomplete sign-in. Sign in again."))
    #expect(TraktPhoneSignIn.decode(status: 401, data: Data(#"{"error":"invalid_grant"}"#.utf8), now: now)
            == .failed("The service no longer accepts this sign-in. Sign in again."))
    #expect(TraktPhoneSignIn.username(from: Data(#"{"user":{"username":"amit","ids":{"slug":"amit"}}}"#.utf8)) == "amit")

    // Renewed 15 minutes ahead for Trakt; a day ahead elsewhere.
    var config = ExternalProviderConfig(provider: .trakt, enabled: true, clientId: "trakt-app", accessToken: "a", refreshToken: "r",
                                        tokenExpiresAt: now.addingTimeInterval(3_600).formatted(.iso8601), connection: .signIn)
    #expect(!config.needsRefresh(now: now))
    config.tokenExpiresAt = now.addingTimeInterval(600).formatted(.iso8601)
    #expect(config.needsRefresh(now: now))
    let simkl = ExternalProviderConfig(provider: .simkl, refreshToken: "r", tokenExpiresAt: now.addingTimeInterval(3_600).formatted(.iso8601))
    #expect(simkl.needsRefresh(now: now))
}

