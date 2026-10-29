import XCTest
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
    func testOnlyMoviesAndShowsAreOnByDefaultAndPersonalLibrariesAreNeverRead() {
        let types: [String?] = ["movies", "tvshows", "mixed", nil, "photos", "homevideos", "music"]
        let libraries = types.enumerated().map { JellyfinLibrary(id: "\($0.offset)", name: "L", type: $0.element) }
        XCTAssertEqual(libraries.map(\.readable), [true, true, true, true, false, false, false])
        XCTAssertEqual(libraries.map(\.onByDefault), [true, true, false, false, false, false, false])
    }
}
