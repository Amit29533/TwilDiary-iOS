import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// The search page's "Recently viewed": newest first, each title once whether opened as a TMDB
/// preview or from the library, and no more than fifteen.
final class RecentlyViewedTests: XCTestCase {
    func testNewestFirstOnceEachAndCapped() {
        let preview = RecentlyViewedTitle(name: "Frieren", poster: nil, libraryID: nil, movie: false, tmdb: 209867)
        let library = RecentlyViewedTitle(name: "Frieren", poster: nil, libraryID: "title-1", movie: false, tmdb: 209867)
        let film = RecentlyViewedTitle(name: "Oppenheimer", poster: nil, libraryID: nil, movie: true, tmdb: 872585)
        var list = RecentlyViewed.adding(preview, to: [])
        list = RecentlyViewed.adding(film, to: list)
        list = RecentlyViewed.adding(library, to: list)
        XCTAssertEqual(list.map(\.name), ["Frieren", "Oppenheimer"], "the preview and the library title are one entry")
        XCTAssertEqual(list.first?.libraryID, "title-1")
        list = RecentlyViewed.adding(preview, to: list)
        XCTAssertEqual(list.first?.libraryID, "title-1", "opening the preview again keeps the library title")
        XCTAssertEqual(film.key, "movie:872585")
        XCTAssertEqual(RecentlyViewedTitle(name: "Local", poster: nil, libraryID: "x", movie: true, tmdb: nil).key, "library:x")

        for id in 1...20 { list = RecentlyViewed.adding(RecentlyViewedTitle(name: "T\(id)", poster: nil, libraryID: nil, movie: true, tmdb: id), to: list) }
        XCTAssertEqual(list.count, RecentlyViewed.limit)
        XCTAssertEqual(list.first?.name, "T20")
        XCTAssertEqual(RecentlyViewed.decode(String(data: try! JSONEncoder().encode(list), encoding: .utf8)!), list)
        XCTAssertEqual(RecentlyViewed.decode("not json"), [])
    }
}
