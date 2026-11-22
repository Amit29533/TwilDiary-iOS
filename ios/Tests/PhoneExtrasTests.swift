import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// With no server, what Trakt can't hold is kept on the phone and laid under Trakt's diary.
@MainActor final class PhoneExtrasTests: XCTestCase {
    private let show = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 1399, name: "Show")
    private let movie = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 603, name: "Movie")

    func testPhoneExtrasShowOnTraktDiary() {
        let long = String(repeating: "a", count: 520)
        let library = TraktLibrary(
            plays: [TraktPlay(historyId: 1, title: show, season: 1, episode: 1, watchedAt: "2026-11-01T10:00:00.000Z"),
                    TraktPlay(historyId: 2, title: movie, watchedAt: "2026-11-02T10:00:00.000Z")],
            notes: [TraktNote(id: 5, title: show, text: String(long.prefix(500)), updatedAt: nil)])
        let entries: [String: PhoneExtras.Entry] = [
            "tv:1399": .init(tags: ["comfy"], queued: true, notes: long, status: "paused", at: .now),
            "movie:603": .init(status: "dropped", at: .now),
            // Not on Trakt (any more): left out, not added to the diary.
            "tv:42": .init(tags: ["gone"], at: .now),
        ]
        let record = PhoneExtras.workspace(entries, locations: [], library: library, catalog: [:])
        XCTAssertEqual(Set(record.titles.map(\.id)), ["tv:1399", "movie:603"])
        let diary = TraktDiary.build(library: library, server: record)
        let built = diary.titles.first { $0.id == "tv:1399" }
        XCTAssertEqual(built?.status, "paused", "Paused stays (Trakt has no Paused)")
        XCTAssertEqual(built?.tags, ["comfy"])
        XCTAssertEqual(built?.queued, true)
        XCTAssertEqual(built?.notes, long, "The full note, not Trakt's first 500 characters")
        XCTAssertEqual(diary.titles.first { $0.id == "movie:603" }?.status, "dropped", "A dropped movie stays dropped")
        XCTAssertEqual(diary.events.count, 2)
        XCTAssertFalse(diary.titles.contains { $0.id == "tv:42" })
    }

    /// Up, unwatched, set to Completed with the diary on MDBList (2026-11-16): MDBList holds no
    /// status for an unwatched movie, so it left the watchlist and the title vanished. The status
    /// set here keeps it, from the phone's details; a title in the phone's Trash doesn't come back.
    func testAStatusSetHereKeepsATitleTheServiceHasNothingFor() {
        let up = MediaTitle.imported(id: "movie:14160", name: "Up", series: false, year: 2009, tmdbId: 14160, status: "planned", score: nil, createdAt: "")
        let gone = MediaTitle.imported(id: "movie:9", name: "Trashed", series: false, year: 2001, tmdbId: 9, status: "planned", score: nil, createdAt: "")
        let entries: [String: PhoneExtras.Entry] = ["movie:14160": .init(status: "completed", at: .now), "movie:9": .init(status: "completed", at: .now),
                                                     "tv:42": .init(tags: ["gone"], at: .now)]
        let library = TraktLibrary()
        let record = PhoneExtras.workspace(entries, locations: [], library: library, catalog: ["movie:14160": up, "movie:9": gone, "tv:42": up],
                                           trashed: ["movie:9"])
        XCTAssertEqual(record.titles.map(\.id), ["movie:14160"], "only a status keeps it; tags alone don't, nor a trashed title")
        let diary = TraktDiary.build(library: library, server: record, tracker: .mdblist)
        XCTAssertEqual(diary.titles.first { $0.id == "movie:14160" }?.status, "completed")
    }

    /// Moved to Trash, a title stays out of the diary even while the service still lists it (it
    /// came back after a restart, 2026-11-16); other titles are untouched.
    func testATrashedTitleStaysHiddenWhateverTheServiceLists() {
        let up = MediaTitle.imported(id: "movie:14160", name: "Up", series: false, year: 2009, tmdbId: 14160, status: "planned", score: nil, createdAt: "")
        let other = MediaTitle.imported(id: "movie:603", name: "The Matrix", series: false, year: 1999, tmdbId: 603, status: "completed", score: nil, createdAt: "")
        let diary = Workspace(titles: [up, other], episodes: [],
                              events: [WatchEvent(id: "trakt-1", operationId: "a", titleId: "movie:14160", episodeId: nil, watchedAt: "2026-11-01T10:00:00.000Z", recordedAt: "2026-11-01T10:00:00.000Z"),
                                       WatchEvent(id: "trakt-2", operationId: "b", titleId: "movie:603", episodeId: nil, watchedAt: "2026-11-02T10:00:00.000Z", recordedAt: "2026-11-02T10:00:00.000Z")],
                              locations: [])
        let shown = DiaryStore.hidingTrashed(diary, ["movie:14160"])
        XCTAssertEqual(shown.titles.map(\.id), ["movie:603"])
        XCTAssertEqual(shown.events.map(\.titleId), ["movie:603"])
        XCTAssertEqual(DiaryStore.hidingTrashed(diary, []).titles.count, 2, "nothing trashed: nothing hidden")
    }

    func testClearedEntryIsKeptButLeavesNoTrace() {
        let library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: movie, watchedAt: nil)])
        let record = PhoneExtras.workspace(["movie:603": .init(at: .now)], locations: [], library: library, catalog: [:])
        XCTAssertTrue(record.titles.isEmpty)
        XCTAssertEqual(TraktDiary.build(library: library, server: record).titles.first?.status, "completed")
    }

    func testJellyfinFoldersSplitLikeTheServer() {
        let windows = FileLocation.jellyfin(titleId: "tv:1", folder: "D:\\TV\\Show", season: 1, fileCount: 8, checkedAt: "x")
        XCTAssertEqual(windows.driveLetter, "D:"); XCTAssertEqual(windows.root, "D:\\"); XCTAssertEqual(windows.relativePath, "TV\\Show")
        XCTAssertEqual(windows.deviceId, "jellyfin"); XCTAssertEqual(windows.evidence, "present")
        let share = FileLocation.jellyfin(titleId: "tv:1", folder: "\\\\nas\\media\\TV", season: nil, fileCount: 1, checkedAt: "x")
        XCTAssertEqual(share.root, "\\\\nas\\media"); XCTAssertEqual(share.relativePath, "TV")
        let posix = FileLocation.jellyfin(titleId: "tv:1", folder: "/mnt/media/TV", season: nil, fileCount: 1, checkedAt: "x")
        XCTAssertEqual(posix.root, "/"); XCTAssertEqual(posix.relativePath, "mnt/media/TV"); XCTAssertEqual(posix.path, "/mnt/media/TV")
    }

    func testJellyfinMatchesOnThePhone() {
        let titles = [MediaTitle.imported(id: "tv:1399", name: "Show", series: true, year: nil, tmdbId: 1399, status: "watching", score: nil, createdAt: ""),
                      MediaTitle.imported(id: "movie:603", name: "Movie", series: false, year: nil, tmdbId: 603, status: "completed", score: nil, createdAt: "")]
        let items: [[String: Any]] = [
            ["kind": "series", "ids": ["tmdb": "1399"], "folder": "/m/Show", "fileCount": 12,
             "seasons": [["number": 1, "folder": "/m/Show/S1", "fileCount": 10], ["number": 2, "folder": "/m/Show/S2", "fileCount": 2]]],
            ["kind": "movie", "ids": ["tmdb": "603"], "folder": "/m/Movie", "fileCount": 1],
            ["kind": "movie", "ids": ["tmdb": "1"], "folder": "/m/Other", "fileCount": 1],
        ]
        let found = JellyfinSync.match(items, titles: titles, checkedAt: "2026-11-11T00:00:00Z")
        XCTAssertEqual(found.mapped, 2)
        XCTAssertEqual(found.locations.filter { $0.titleId == "tv:1399" }.compactMap(\.season), [1, 2])
        XCTAssertEqual(found.locations.first { $0.titleId == "movie:603" }?.path, "/m/Movie")
    }
}
