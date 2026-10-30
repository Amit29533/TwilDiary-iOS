import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class JellyfinSyncTests: XCTestCase {
    func testOnlyTMDBIMDbAndTVDBCountAsMatches() {
        XCTAssertEqual(JellyfinSync.ids(["Tmdb": "95396", "Imdb": "tt11280740", "Tvdb": "371980", "TvRage": "1"]), ["tmdb": "95396", "imdb": "tt11280740", "tvdb": "371980"])
        // Personal media has no provider IDs at all, or only empty ones.
        XCTAssertTrue(JellyfinSync.ids(nil).isEmpty)
        XCTAssertTrue(JellyfinSync.ids(["Tmdb": ""]).isEmpty)
    }
    func testFolderOfAFileOnWindowsAndPOSIXPaths() {
        XCTAssertEqual(JellyfinSync.parent("D:\\Movies\\Arrival (2016)\\Arrival.mkv"), "D:\\Movies\\Arrival (2016)")
        XCTAssertEqual(JellyfinSync.parent("/mnt/media/TV/Show/Season 1/E01.mkv"), "/mnt/media/TV/Show/Season 1")
    }
    func testAddressesAreNormalizedToTheServerRoot() {
        XCTAssertEqual(JellyfinSettings.normalized("192.168.1.20:8096")?.absoluteString, "http://192.168.1.20:8096")
        XCTAssertEqual(JellyfinSettings.normalized("http://jelly.local:8096/web/")?.absoluteString, "http://jelly.local:8096")
        XCTAssertNil(JellyfinSettings.normalized("ftp://192.168.1.20"))
        XCTAssertNil(JellyfinSettings.normalized(""))
    }
    private func title(_ id: String, _ category: String, tmdb: Int?) throws -> MediaTitle {
        let object: [String: Any] = ["id": id, "name": id, "category": category, "overview": "", "tmdbId": tmdb as Any? ?? NSNull(), "genres": [],
                                     "status": "planned", "favorite": false, "notes": ""]
        return try JSONDecoder().decode(MediaTitle.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func entry(_ id: String, movie: Bool, tmdb: Int?, diaryID: String? = nil) -> JellyfinEntry {
        JellyfinEntry(id: id, name: id, year: nil, movie: movie, tmdb: tmdb, path: "E:\\" + id, drive: "E:", poster: nil, diaryID: diaryID)
    }
    func testTheSavedListIsMatchedAgainstTheDiaryAsItIsNow() throws {
        let diary = try [title("dune", "movie", tmdb: 438631), title("show", "show", tmdb: 438631), title("kept", "anime", tmdb: nil)]
        let matched = JellyfinShelf.matched([
            entry("j1", movie: true, tmdb: 438631),                          // added to the diary after the list was read
            entry("j2", movie: false, tmdb: 438631),                         // same TMDB id, other type
            entry("j3", movie: false, tmdb: nil, diaryID: "kept"),           // saved match, title still in the diary
            entry("j4", movie: true, tmdb: 1, diaryID: "removed")            // saved match, title since removed
        ], diary: diary)
        XCTAssertEqual(matched.map(\.diaryID), ["dune", "show", "kept", nil])
        // Signed out (no diary): nothing points at a title.
        XCTAssertEqual(JellyfinShelf.matched(matched, diary: []).compactMap(\.diaryID), [])
    }
    func testTheJellyfinListIsSavedAndReadBackUntilForgotten() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/library.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let shelf = JellyfinShelf(file: file)
        XCTAssertTrue(shelf.entries.isEmpty)
        shelf.replace([entry("j1", movie: true, tmdb: 438631)], personal: 3)
        // A fresh start (no Jellyfin reachable) reads the saved list.
        let reopened = JellyfinShelf(file: file)
        XCTAssertEqual(reopened.entries.map(\.id), ["j1"]); XCTAssertEqual(reopened.personal, 3); XCTAssertNotNil(reopened.savedAt)
        let dune = try title("dune", "movie", tmdb: 438631)
        XCTAssertEqual(reopened.titleIDs(diary: [dune]), ["dune"])
        // Preview data is shown but never saved over the owner's list.
        reopened.replace([entry("preview", movie: true, tmdb: nil)], personal: 0, save: false)
        XCTAssertEqual(JellyfinShelf(file: file).entries.map(\.id), ["j1"])
        reopened.forget()
        XCTAssertTrue(JellyfinShelf(file: file).entries.isEmpty)
    }
    func testTitlesNotInTheDiaryFollowLibrarysCategoryGenreAndDriveFilters() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/library.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let shelf = JellyfinShelf(file: file)
        func listed(_ id: String, movie: Bool, tmdb: Int, drive: String, year: Int, genres: [String]) -> JellyfinEntry {
            JellyfinEntry(id: id, name: id, year: year, movie: movie, tmdb: tmdb, path: drive + "\\" + id, drive: drive, poster: nil, diaryID: nil, genres: genres)
        }
        shelf.replace([listed("arrival", movie: true, tmdb: 1, drive: "E:", year: 2016, genres: ["Science Fiction", "Drama"]),
                       listed("dune", movie: true, tmdb: 2, drive: "G:", year: 2021, genres: ["Science Fiction"]),
                       listed("bocchi", movie: false, tmdb: 3, drive: "E:", year: 2022, genres: ["Animation", "Comedy"]),
                       listed("severance", movie: false, tmdb: 4, drive: "D:", year: 2022, genres: ["Drama"])], personal: 0, save: false)
        let diary = try [title("in-diary", "show", tmdb: 4)]
        func names(category: String = "all", genres: Set<String> = [], disk: String = "all", favorites: Bool = false, sort: LibraryQuery.Sort = .title) -> [String] {
            shelf.extras(diary: diary, category: category, genres: genres, disk: disk, favorites: favorites, sort: sort).map(\.id)
        }
        XCTAssertEqual(names(), ["arrival", "bocchi", "dune"], "Severance is in the diary, so it isn't an extra")
        XCTAssertEqual(names(category: "movie"), ["arrival", "dune"])
        XCTAssertEqual(names(category: "anime"), ["bocchi"])
        XCTAssertEqual(names(category: "show"), [], "Animation counts as Anime, not Shows")
        XCTAssertEqual(names(genres: ["Drama", "Comedy"]), ["arrival", "bocchi"])
        XCTAssertEqual(names(disk: "drive:E"), ["arrival", "bocchi"])
        XCTAssertEqual(names(disk: "[\"jellyfin\",\"jellyfin:G:\"]"), ["dune"])
        XCTAssertEqual(names(disk: "unmapped"), [], "Everything on Jellyfin is on a disk")
        XCTAssertEqual(names(favorites: true), [], "Only diary titles can be favourites")
        XCTAssertEqual(names(sort: .year), ["bocchi", "dune", "arrival"])
    }
    func testTheServerGetsTheImageTagNotTheHomeAddressAndOnlyAChangedListIsSentAgain() throws {
        let base = try XCTUnwrap(URL(string: "http://192.168.1.20:8096"))
        let poster = JellyfinClient.posterURL(base: base, item: "abc", tag: "f00d")
        XCTAssertEqual(poster?.absoluteString, "http://192.168.1.20:8096/Items/abc/Images/Primary?fillHeight=450&quality=90&tag=f00d")
        XCTAssertNil(JellyfinClient.posterURL(base: base, item: "abc", tag: nil))
        let arrival = JellyfinEntry(id: "abc", name: "Arrival", year: 2016, movie: true, tmdb: 329865, path: "E:\\Movies\\Arrival", drive: "E:",
                                    poster: poster, diaryID: "film", genres: ["Drama"])
        let sent = JellyfinShelf.uploadItem(arrival)
        XCTAssertEqual(sent["imageTag"] as? String, "f00d")
        XCTAssertEqual(sent["kind"] as? String, "movie")
        XCTAssertFalse(sent.values.contains { "\($0)".contains("192.168") }, "No home network address leaves the phone")
        XCTAssertNil(sent["diaryID"], "Diary matches are worked out on each device")
        let other = entry("xyz", movie: false, tmdb: nil)
        // Order and diary matches don't change what is sent; a renamed title or another personal count does.
        XCTAssertEqual(JellyfinShelf.digest([arrival, other], personal: 1), JellyfinShelf.digest([other, arrival], personal: 1))
        XCTAssertNotEqual(JellyfinShelf.digest([arrival, other], personal: 1), JellyfinShelf.digest([arrival, other], personal: 2))
        let renamed = JellyfinEntry(id: "abc", name: "Arrival (2016)", year: 2016, movie: true, tmdb: 329865, path: arrival.path,
                                    drive: "E:", poster: poster, diaryID: "film", genres: ["Drama"])
        XCTAssertNotEqual(JellyfinShelf.digest([arrival], personal: 0), JellyfinShelf.digest([renamed], personal: 0))
        var matched = arrival; matched.diaryID = nil
        XCTAssertEqual(JellyfinShelf.digest([arrival], personal: 0), JellyfinShelf.digest([matched], personal: 0))
    }
    func testOnlyMoviesAndShowsAreOnByDefaultAndPersonalLibrariesAreNeverRead() {
        let types: [String?] = ["movies", "tvshows", "mixed", nil, "photos", "homevideos", "music"]
        let libraries = types.enumerated().map { JellyfinLibrary(id: "\($0.offset)", name: "L", type: $0.element) }
        XCTAssertEqual(libraries.map(\.readable), [true, true, true, true, false, false, false])
        XCTAssertEqual(libraries.map(\.onByDefault), [true, true, false, false, false, false, false])
    }
}
