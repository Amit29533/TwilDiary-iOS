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
    func testOnlyMoviesAndShowsAreOnByDefaultAndPersonalLibrariesAreNeverRead() {
        let types: [String?] = ["movies", "tvshows", "mixed", nil, "photos", "homevideos", "music"]
        let libraries = types.enumerated().map { JellyfinLibrary(id: "\($0.offset)", name: "L", type: $0.element) }
        XCTAssertEqual(libraries.map(\.readable), [true, true, true, true, false, false, false])
        XCTAssertEqual(libraries.map(\.onByDefault), [true, true, false, false, false, false, false])
    }
}
