import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Undo on the "Watch marked" notice takes back exactly the watch just logged, the way the − button
/// does: never another title's play from the same second, never an earlier watch of the same title.
@MainActor final class WatchUndoTests: XCTestCase {
    @MainActor private final class MemorySessionStorage: SessionStoring {
        var credential: AccessCredential?
        func read() -> AccessCredential? { credential }
        func save(_ credential: AccessCredential) throws { self.credential = credential }
        func delete() { credential = nil }
    }
    private func makeStore() -> DiaryStore {
        DiaryStore(sessionStorage: MemorySessionStorage(), outboxStore: MemorySyncOutboxStore(), providerSettingsStore: MemoryProviderSettingsStore())
    }
    override func tearDown() async throws {
        TraktDirectStore.shared.useLocal(false)
        for tracker in [MainTracker.mdblist, .wetrakr] { TrackerPreviewStore.shared.seedForTesting(tracker, nil) }
        UserDefaults.standard.set("server", forKey: DiaryStore.diarySourceKey)
        UserDefaults.standard.removeObject(forKey: DiaryStore.phoneOnlyKey)
    }
    private func movie(_ store: DiaryStore, _ tmdb: Int) async throws -> MediaTitle {
        let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":\#(tmdb),"mediaType":"movie","name":"Film \#(tmdb)","year":2001,"overview":"","posterPath":"/f.jpg","genres":["Drama"],"suggestedCategory":"movie"}"#.utf8))
        let added = await store.importTitle(details, category: "movie")
        let id = try XCTUnwrap(added, store.error ?? "add failed")
        await store.waitForTitle(id)
        return try XCTUnwrap(store.title(id))
    }
    private func plays(_ store: DiaryStore, _ id: String) -> [WatchEvent] { store.workspace.events.filter { $0.titleId == id && $0.revokedAt == nil } }

    func testUndoTakesBackOnlyThatTitlesWatchFromTheSameSecond() async throws {
        let store = makeStore()
        await store.startOnThisPhone()
        let first = try await movie(store, 21001), second = try await movie(store, 21002)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let markedSecond = await store.recordViewing(second, watchedAt: moment)
        XCTAssertTrue(markedSecond)
        let markedFirst = await store.recordViewing(try XCTUnwrap(store.title(first.id)), watchedAt: moment)
        XCTAssertTrue(markedFirst)
        XCTAssertTrue(store.canUndo, "the notice offers Undo")
        await store.undo()
        XCTAssertTrue(plays(store, first.id).isEmpty, "the watch just logged is gone: \(store.error ?? "")")
        XCTAssertEqual(plays(store, second.id).count, 1, "the other title logged in the same second keeps its watch")
        XCTAssertFalse(store.canUndo); XCTAssertNil(store.undoLabel)
    }

    func testUndoOfARewatchKeepsTheEarlierWatch() async throws {
        let store = makeStore()
        await store.startOnThisPhone()
        let film = try await movie(store, 21003)
        try await store.serviceAddPlays(film, episodes: [], at: Date(timeIntervalSince1970: 1_700_000_000))
        let earlier = try XCTUnwrap(plays(store, film.id).first?.watchedAt)
        let marked = await store.recordViewing(try XCTUnwrap(store.title(film.id)), rewatch: true, watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(marked)
        XCTAssertEqual(plays(store, film.id).count, 2)
        await store.undo()
        XCTAssertEqual(plays(store, film.id).map(\.watchedAt), [earlier], "only the rewatch comes off")
    }

    func testUndoFollowsTheNewestWatch() async throws {
        let store = makeStore()
        await store.startOnThisPhone()
        let older = try await movie(store, 21004), newer = try await movie(store, 21005)
        _ = await store.recordViewing(older, watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        _ = await store.recordViewing(newer, watchedAt: Date(timeIntervalSince1970: 1_800_000_060))
        await store.undo()
        XCTAssertEqual(plays(store, older.id).count, 1, "an earlier mark isn't what Undo takes back")
        XCTAssertTrue(plays(store, newer.id).isEmpty)
    }

    func testUndoWorksWithTheDiaryOnMDBListAndWeTrakr() async throws {
        let store = makeStore()
        store.enterPhoneOnlyForTesting()
        var tmdb = 21100
        for tracker in [MainTracker.mdblist, .wetrakr] {
            TrackerPreviewStore.shared.seedForTesting(tracker, TraktLibrary())
            store.diaryFromTracker = tracker
            tmdb += 1
            let film = try await movie(store, tmdb)
            let marked = await store.recordViewing(film, watchedAt: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertTrue(marked, "\(tracker.name): \(store.error ?? "")")
            XCTAssertEqual(plays(store, film.id).count, 1, tracker.name)
            XCTAssertTrue(store.canUndo, tracker.name)
            await store.undo()
            XCTAssertTrue(plays(store, film.id).isEmpty, "\(tracker.name): \(store.error ?? "the watch stayed")")
        }
    }

    func testAShowLeftWithNothingWatchedGoesBackToPlanToWatchOnSimkl() async throws {
        let store = makeStore()
        let empty = DetachedWatch(tmdbId: 97546, movie: false, season: 1, number: 1, watchedAt: "2027-01-15T08:00:00.000Z", othersRemain: false, titleEmpty: true)
        let jobs = SimklMirror.jobs(for: .revokeWatch(eventId: empty.eventID, titleId: "tv:97546", expectedVersion: 1, revokedAt: "2027-01-15T08:00:05.000Z"), store: store)
        XCTAssertEqual(jobs.map(\.kind), [.unwatch, .list], "the episode off, then the show back on Plan to watch")
        XCTAssertEqual(jobs.last?.list, "plantowatch")
        // Other episodes still watched, or a movie: only the removal.
        let more = DetachedWatch(tmdbId: 97546, movie: false, season: 1, number: 2, watchedAt: "2027-01-15T08:00:00.000Z", othersRemain: false)
        XCTAssertEqual(SimklMirror.jobs(for: .revokeWatch(eventId: more.eventID, titleId: "tv:97546", expectedVersion: 1, revokedAt: "x"), store: store).map(\.kind), [.unwatch])
        let film = DetachedWatch(tmdbId: 346648, movie: true, season: nil, number: nil, watchedAt: "2027-01-15T08:00:00.000Z", othersRemain: false, titleEmpty: true)
        XCTAssertEqual(SimklMirror.jobs(for: .revokeWatch(eventId: film.eventID, titleId: "movie:346648", expectedVersion: 1, revokedAt: "x"), store: store).map(\.kind), [.unwatch])
        // A removal queued before this change (no flag) still reads.
        let old = DetachedWatch(eventID: "detached:" + Data(#"{"movie":false,"number":1,"othersRemain":false,"season":1,"tmdbId":5,"watchedAt":"2027-01-15T08:00:00.000Z"}"#.utf8).base64EncodedString())
        XCTAssertNotNil(old); XCTAssertNil(old?.titleEmpty)
    }

    func testPlaysAreMatchedWithinASecondOfTheirTime() async throws {
        let store = makeStore()
        await store.startOnThisPhone()
        let film = try await movie(store, 21006)
        try await store.serviceAddPlays(film, episodes: [], at: Date(timeIntervalSince1970: 1_800_000_000))
        // A refreshed copy writes the time its own way ("…00.000Z"): still the same play.
        XCTAssertEqual(store.undoablePlays(titleID: film.id, at: "2027-01-15T08:00:00.000Z").count, 1)
        XCTAssertTrue(store.undoablePlays(titleID: film.id, at: "2027-01-15T08:00:02.000Z").isEmpty)
    }
}
