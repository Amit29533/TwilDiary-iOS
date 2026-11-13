import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// The diary lives on Trakt, MDBList, WeTrakr or this phone, never on the server (owner's rule).
/// These keep the phone diary honest: it never asks the server for the diary, edits On this phone
/// stay on the phone, and a settings save that fails isn't shown as saved.
@MainActor final class PhoneStoreTests: XCTestCase {
    @MainActor private final class MemorySessionStorage: SessionStoring {
        var credential: AccessCredential?
        func read() -> AccessCredential? { credential }
        func save(_ credential: AccessCredential) throws { self.credential = credential }
        func delete() { credential = nil }
    }
    private struct RejectingProviderSettings: ProviderSettingsStoring {
        func load() throws -> ProviderConnectionSettings { ProviderConnectionSettings() }
        func save(_ settings: ProviderConnectionSettings) throws { throw APIError.message("Synthetic secure storage failure") }
    }
    private func makeStore(providerSettingsStore: (any ProviderSettingsStoring)? = nil) -> DiaryStore {
        DiaryStore(sessionStorage: MemorySessionStorage(), outboxStore: MemorySyncOutboxStore(),
                   providerSettingsStore: providerSettingsStore ?? MemoryProviderSettingsStore())
    }

    func testPhoneDiaryNeverAsksTheServerForTheDiary() async throws {
        let extras = ExtrasStorage.server
        ExtrasStorage.server = false
        defer { ExtrasStorage.server = extras }
        let store = makeStore()
        store.enterPhoneOnlyForTesting()
        do { let _: EmptyResponse = try await store.read("/api/backups"); XCTFail("read should not reach the server") }
        catch { XCTAssertEqual(error.localizedDescription, DiaryStore.needsServer) }
        // Even signed in to the server, the diary's own calls never go there.
        ExtrasStorage.server = true
        do { let _: EmptyResponse = try await store.read("/api/titles/movie:603", method: "PATCH", body: [:]); XCTFail("the diary isn't on the server") }
        catch { XCTAssertEqual(error.localizedDescription, DiaryStore.needsServer) }
        XCTAssertFalse(store.needsSignIn)
        XCTAssertTrue(store.phoneOnly)
    }

    func testOnThisPhoneDiaryKeepsEditsOnThePhone() async throws {
        let store = makeStore()
        defer {
            // Leave no trace for the next test: the diary source and the on-phone mode are app-wide settings.
            TraktDirectStore.shared.useLocal(false)
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        await store.startOnThisPhone()
        XCTAssertTrue(store.onThisPhone); XCTAssertFalse(store.needsSignIn)
        let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":603,"mediaType":"movie","name":"The Matrix","year":1999,"overview":"","posterPath":"/m.jpg","genres":["Action"],"suggestedCategory":"movie"}"#.utf8))
        let id = await store.importTitle(details, category: "movie")
        XCTAssertEqual(id, "movie:603")
        XCTAssertEqual(store.title("movie:603")?.status, "planned")
        XCTAssertNotNil(store.title("movie:603")?.poster)
        // A watch logged by accident, then the movie set back to Planned: the watch goes too.
        let movie = try XCTUnwrap(store.title("movie:603"))
        try await store.serviceAddPlays(movie, episodes: [], at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(store.workspace.events.filter { $0.titleId == "movie:603" }.count, 1)
        XCTAssertEqual(store.title("movie:603")?.status, "completed")
        try await store.servicePatch(try XCTUnwrap(store.title("movie:603")), values: ["status": "planned"])
        XCTAssertTrue(store.workspace.events.filter { $0.titleId == "movie:603" && $0.revokedAt == nil }.isEmpty)
        XCTAssertEqual(store.title("movie:603")?.status, "planned")
    }

    func testRejectedProviderCredentialSaveDoesNotPublishTheNewConfiguration() {
        let store = makeStore(providerSettingsStore: RejectingProviderSettings())
        XCTAssertFalse(store.updateCustomTmdbToken("synthetic-rejected-token"))
        XCTAssertNil(store.providerSettings.customTmdbToken)
        XCTAssertFalse(store.updateProviderConfig(ExternalProviderConfig(provider: .wetrakr, enabled: true, clientId: "fixture", accessToken: "fixture")))
        XCTAssertNil(store.providerSettings.wetrakr.accessToken)
        XCTAssertNotNil(store.error)
    }
}
