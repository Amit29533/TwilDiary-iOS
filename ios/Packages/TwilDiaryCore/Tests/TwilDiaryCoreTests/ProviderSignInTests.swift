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
    #expect(ProviderDeviceSignIn.endpoints(for: .trakt) == nil && ProviderDeviceSignIn.endpoints(for: .wetrakr) == nil)
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
