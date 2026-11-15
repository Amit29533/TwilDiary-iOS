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

    /// Up, added as Planned, then set to another status from the title page's menu (owner's
    /// recordings, 2026-11-16): the page turned to "Title unavailable" and Search offered Add again.
    /// Every status must keep the title, with that status.
    func testAStatusChangeKeepsANewlyAddedTitle() async throws {
        let store = makeStore()
        defer {
            TraktDirectStore.shared.useLocal(false)
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        await store.startOnThisPhone()
        for (tmdb, status) in [(14160, "watching"), (14161, "completed"), (14162, "dropped")] {
            let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":\#(tmdb),"mediaType":"movie","name":"Up \#(status)","year":2009,"overview":"","posterPath":"/u.jpg","genres":["Animation"],"suggestedCategory":"movie"}"#.utf8))
            let added = await store.importTitle(details, category: "movie")
            let id = try XCTUnwrap(added, "\(status): Add to Planned failed: \(store.error ?? "no error")")
            await store.waitForTitle(id)
            let title = try XCTUnwrap(store.title(id), "\(status): not in the diary after Add to Planned")
            XCTAssertEqual(title.status, "planned", status)
            let done = await store.setSeasonStatus(title, season: 1, status: status, watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertTrue(done, "\(status): the change failed: \(store.error ?? "no error")")
            await store.waitForTitle(id)
            XCTAssertNotNil(store.title(id), "\(status): the title left the diary")
            XCTAssertEqual(store.title(id)?.status, status, "\(status): wrong status after the change")
        }
    }

    /// The same with the diary on MDBList and on WeTrakr: neither holds Watching or Completed for
    /// a movie (Completed logs a watch), and MDBList drops only shows.
    func testAStatusChangeKeepsANewlyAddedTitleOnEachService() async throws {
        let store = makeStore()
        defer {
            for tracker in [MainTracker.mdblist, .wetrakr] { TrackerPreviewStore.shared.seedForTesting(tracker, nil) }
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        store.enterPhoneOnlyForTesting()
        var tmdb = 15000
        for tracker in [MainTracker.mdblist, .wetrakr] {
            TrackerPreviewStore.shared.seedForTesting(tracker, TraktLibrary())
            store.diaryFromTracker = tracker
            for status in ["watching", "completed", "dropped"] {
                tmdb += 1
                let label = "\(tracker.name) \(status)"
                let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":\#(tmdb),"mediaType":"movie","name":"Film \#(tmdb)","year":2009,"overview":"","posterPath":"/f.jpg","genres":["Animation"],"suggestedCategory":"movie"}"#.utf8))
                let added = await store.importTitle(details, category: "movie")
                let id = try XCTUnwrap(added, "\(label): Add to Planned failed: \(store.error ?? "no error")")
                await store.waitForTitle(id)
                let title = try XCTUnwrap(store.title(id), "\(label): not in the diary after Add to Planned")
                let done = await store.setSeasonStatus(title, season: 1, status: status, watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
                XCTAssertTrue(done, "\(label): the change failed: \(store.error ?? "no error")")
                await store.waitForTitle(id)
                XCTAssertNotNil(store.title(id), "\(label): the title left the diary")
                XCTAssertEqual(store.title(id)?.status, status, "\(label): wrong status after the change")
            }
        }
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
