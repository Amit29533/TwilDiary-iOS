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

    /// A title moved to Trash earlier, then added again from its page: it leaves the phone's Trash,
    /// and a status change afterwards keeps it (it stayed in Trash before, and vanished).
    func testAddingATrashedTitleAgainBringsItBack() async throws {
        let store = makeStore()
        defer {
            PhoneTrash.shared.replace(PhoneTrash.shared.titles.filter { $0.id != "movie:14170" })
            TraktDirectStore.shared.useLocal(false)
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        await store.startOnThisPhone()
        let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":14170,"mediaType":"movie","name":"Up again","year":2009,"overview":"","posterPath":"/u.jpg","genres":["Animation"],"suggestedCategory":"movie"}"#.utf8))
        let first = await store.importTitle(details, category: "movie")
        let id = try XCTUnwrap(first)
        await store.waitForTitle(id)
        let toTrash = try XCTUnwrap(store.title(id))
        let trashed = await store.trash(toTrash)
        XCTAssertTrue(trashed)
        XCTAssertTrue(PhoneTrash.shared.contains(id))
        let again = await store.importTitle(details, category: "movie")
        XCTAssertEqual(again, id)
        XCTAssertFalse(PhoneTrash.shared.contains(id), "added again: out of Trash")
        await store.waitForTitle(id)
        let title = try XCTUnwrap(store.title(id))
        let dropped = await store.setSeasonStatus(title, season: 1, status: "dropped", watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(dropped)
        await store.waitForTitle(id)
        XCTAssertEqual(store.title(id)?.status, "dropped", "still in the diary, dropped")
    }

    /// Trash's titles open their page, which knows the title is in the phone's Trash and restores
    /// it there (owner's request, 2026-11-16: Trash's titles couldn't be opened).
    func testATrashedTitlesPageRestoresIt() async throws {
        let store = makeStore()
        defer {
            PhoneTrash.shared.replace(PhoneTrash.shared.titles.filter { $0.id != "movie:14180" })
            TraktDirectStore.shared.useLocal(false)
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        await store.startOnThisPhone()
        let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":14180,"mediaType":"movie","name":"Restore me","year":2009,"overview":"","posterPath":"/r.jpg","genres":["Animation"],"suggestedCategory":"movie"}"#.utf8))
        let added = await store.importTitle(details, category: "movie")
        let id = try XCTUnwrap(added)
        await store.waitForTitle(id)
        let title = try XCTUnwrap(store.title(id))
        let trashed = await store.trash(title)
        XCTAssertTrue(trashed)
        let route = CatalogRoute(kind: .movie, id: 14180)
        let inTrash = try XCTUnwrap(store.phoneTrashed(route), "the page knows it's in Trash")
        let restored = await store.restore(inTrash)
        XCTAssertTrue(restored)
        await store.waitForTitle(id)
        XCTAssertEqual(store.title(id)?.status, "planned", "back in the diary")
        XCTAssertNil(store.phoneTrashed(route), "out of Trash")
    }

    func testPermanentDeletionSurvivesStaleTrackerRowsAndAllowsAddingAgain() async throws {
        let store = makeStore()
        let originalTrash = PhoneTrash.shared.titles
        PhoneTrash.shared.replace([])
        defer {
            PhoneTrash.shared.replace(originalTrash)
            TraktDirectStore.shared.useLocal(false)
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        await store.startOnThisPhone()
        // Exercise both the selected-title action and Empty Trash, which used to leave
        // a local status behind and unhide a title still present in the tracker's copy.
        for (tmdb, emptyAll) in [(14201, false), (14202, true)] {
            let details = try JSONDecoder().decode(CatalogDetails.self, from: Data("""
                {"id":\(tmdb),"mediaType":"movie","name":"Trash fixture","year":2009,"overview":"","posterPath":"/r.jpg","genres":[],"suggestedCategory":"movie"}
                """.utf8))
            let added = await store.importTitle(details, category: "movie")
            let id = try XCTUnwrap(added)
            await store.waitForTitle(id)
            let title = try XCTUnwrap(store.title(id))
            let moved = await store.trash(title)
            XCTAssertTrue(moved)
            let archived = try XCTUnwrap(store.phoneTrashed(CatalogRoute(kind: .movie, id: tmdb)))
            XCTAssertNil(PhoneExtras.shared.entries[PhoneExtras.key(title)]?.status, "moving to Trash must not create a Completed entry")
            PhoneExtras.shared.update(title, ["status": "completed"])
            XCTAssertNil(store.title(id))

            let deleted: Bool
            if emptyAll { deleted = await store.emptyTrash() }
            else { deleted = await store.manage([archived], change: .purge) }
            XCTAssertTrue(deleted)
            XCTAssertFalse(PhoneTrash.shared.contains(id))
            XCTAssertNil(PhoneExtras.shared.entries[PhoneExtras.key(title)]?.status)
            let backup = try JSONDecoder().decode(PhoneExtras.Backup.self, from: JSONEncoder().encode(PhoneExtras.shared.backup))
            XCTAssertEqual(backup.entries[PhoneExtras.key(title)]?.purged, true)
            XCTAssertNil(store.title(id), "an old phone status cannot recreate the title")

            TraktDirectStore.shared.update(store: store) { library in
                let ref = TraktTitleRef(kind: .movie, traktId: nil, tmdbId: tmdb, name: title.name, year: title.year)
                library.watchlist.append(TraktListed(title: ref, listedAt: nil))
            }
            store.applyDiarySource()
            XCTAssertNil(store.title(id), "a stale tracker response cannot recreate the title")

            let readded = await store.importTitle(details, category: "movie")
            XCTAssertEqual(readded, id)
            await store.waitForTitle(id)
            XCTAssertEqual(store.title(id)?.status, "planned")
            XCTAssertFalse(PhoneTrash.shared.contains(id))
        }
    }

    /// Trash's status only takes a title off the watchlist. Simkl keeps Completed and Watching as
    /// lists of their own, so a trashed Planned film went onto its Completed list (2026-11-16):
    /// while trashing, the whole title comes off Simkl instead.
    func testTrashTakesATitleOffSimklInsteadOfMovingItToCompleted() async throws {
        let store = makeStore()
        defer {
            TraktDirectStore.shared.useLocal(false)
            UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
            UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
        }
        await store.startOnThisPhone()
        let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":14190,"mediaType":"movie","name":"Planned film","year":2009,"overview":"","posterPath":"/p.jpg","genres":["Drama"],"suggestedCategory":"movie"}"#.utf8))
        let added = await store.importTitle(details, category: "movie")
        let id = try XCTUnwrap(added)
        await store.waitForTitle(id)
        let edit = OptimisticMutation.patchTitle(titleId: id, expectedVersion: nil, status: "completed", score: nil, clearScore: false, favorite: false, queued: nil, notes: nil)
        XCTAssertEqual(SimklMirror.jobs(for: edit, store: store).map(\.list), ["completed"], "a plain status change: Simkl's list")
        store.trashing.insert(id)
        let jobs = SimklMirror.jobs(for: edit, store: store)
        store.trashing.remove(id)
        XCTAssertEqual(jobs.map(\.kind), [.unwatch])
        XCTAssertEqual(jobs.first?.wholeTitle, true, "the whole title off Simkl")
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
