import Foundation
import Testing
@testable import TwilDiaryCore

private final class ControlledProviderSecrets: ProviderSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var rejectWrites = false
    var rejectReads = false
    func readSecret(for account: String) throws -> String? {
        try lock.withLock {
            if rejectReads { throw ProviderSettingsPersistenceError.secureStoreUnavailable }
            return values[account]
        }
    }
    func writeSecret(_ value: String?, for account: String) -> Bool {
        lock.withLock {
            guard !rejectWrites else { return false }
            values[account] = value
            return true
        }
    }
}

@Test func keychainWriteFailureNeverFallsBackToPlaintextOrReplacesPreviousCredentials() throws {
    let suiteName = "twildiary.secure-test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = ControlledProviderSecrets()
    let store = UserDefaultsProviderSettingsStore(defaults: defaults, key: "settings", secrets: secrets)
    var original = ProviderConnectionSettings(customTmdbToken: "synthetic-previous-secret")
    try store.save(original)
    let saved = defaults.data(forKey: "settings")
    secrets.rejectWrites = true
    original.customTmdbToken = "synthetic-rejected-secret"
    #expect(throws: ProviderSettingsPersistenceError.self) { try store.save(original) }
    #expect(defaults.data(forKey: "settings") == saved)
    let raw = String(decoding: saved ?? Data(), as: UTF8.self)
    #expect(!raw.contains("synthetic-previous-secret"))
    #expect(!raw.contains("synthetic-rejected-secret"))
    #expect(try store.load().customTmdbToken == "synthetic-previous-secret")
}

@Test func lockedKeychainDoesNotBecomeAnEmptySuccessfulConfiguration() throws {
    let suiteName = "twildiary.secure-test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = ControlledProviderSecrets()
    let store = UserDefaultsProviderSettingsStore(defaults: defaults, key: "settings", secrets: secrets)
    try store.save(ProviderConnectionSettings(customTmdbToken: "synthetic-secret"))
    secrets.rejectReads = true
    #expect(throws: ProviderSettingsPersistenceError.self) { try store.load() }
}

@Test func providerSecretsMigrateAndExplicitClearsCannotResurrectLegacyTokens() throws {
    let suiteName = "twildiary.secure-test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = ControlledProviderSecrets()
    let legacy = ProviderConnectionSettings(customTmdbToken: "synthetic-legacy")
    defaults.set(try JSONEncoder().encode(legacy), forKey: "settings")
    let store = UserDefaultsProviderSettingsStore(defaults: defaults, key: "settings", secrets: secrets)
    #expect(try store.load().customTmdbToken == "synthetic-legacy")
    #expect(!String(decoding: defaults.data(forKey: "settings") ?? Data(), as: UTF8.self).contains("synthetic-legacy"))
    try store.save(ProviderConnectionSettings())
    #expect(try store.load().customTmdbToken == nil)
}

@Test func weTrakrTokensStayOutOfPreferences() throws {
    let suiteName = "twildiary.secure-test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsProviderSettingsStore(defaults: defaults, key: "settings", secrets: ControlledProviderSecrets())
    let wetrakr = ExternalProviderConfig(provider: .wetrakr, enabled: true, clientId: "app", accessToken: "synthetic-wetrakr-access", refreshToken: "synthetic-wetrakr-refresh")
    try store.save(ProviderConnectionSettings(wetrakr: wetrakr))
    let raw = String(decoding: defaults.data(forKey: "settings") ?? Data(), as: UTF8.self)
    #expect(!raw.contains("synthetic-wetrakr-access") && !raw.contains("synthetic-wetrakr-refresh"))
    let loaded = try store.load().wetrakr
    #expect(loaded.accessToken == "synthetic-wetrakr-access" && loaded.refreshToken == "synthetic-wetrakr-refresh")
}
