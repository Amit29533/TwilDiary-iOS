import XCTest
import TwilDiaryCore
@testable import TwilDiary

final class WikidataAnimeTests: XCTestCase {
    func testOneQueryAsksForEveryAnimeOnThePage() throws {
        let url = try XCTUnwrap(WikidataAnime.url([154587, 182255]))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value)
        XCTAssertTrue(query.contains("VALUES ?x { \"154587\" \"182255\" }"))
        XCTAssertTrue(query.contains("wdt:P8729") && query.contains("wdt:P4983") && query.contains("wdt:P4947"))
    }
    func testRowsDecodeSparqlBindings() throws {
        let data = Data(#"{"head":{"vars":["x","tv","mv","ptv"]},"results":{"bindings":[{"x":{"type":"literal","value":"182255"},"ptv":{"type":"literal","value":"209867"}},{"x":{"type":"literal","value":"oops"}}]}}"#.utf8)
        XCTAssertEqual(WikidataAnime.rows(data), [.init(anime: 182255, seriesShow: 209867)])
        XCTAssertNil(WikidataAnime.rows(Data("<html>".utf8)))
    }
    func testLaterSeasonOpensTheSeriesShowAndFilmsOnlyOpenFilms() {
        let rows: [WikidataAnime.Row] = [
            .init(anime: 182255, seriesShow: 209867),                 // Frieren season 2: only the series has TMDB
            .init(anime: 1, show: 10, seriesShow: 99),                // its own show wins over the series
            .init(anime: 2, seriesShow: 20), .init(anime: 2, seriesShow: 21), // two series: ambiguous
            .init(anime: 3, film: 30, seriesShow: 31),                // a film opens only its film
            .init(anime: 4, seriesShow: 40)                           // a film without its own film link: none
        ]
        let routes = WikidataAnime.routes(rows, for: [
            .init(id: 182255, format: "TV"), .init(id: 1, format: "TV"), .init(id: 2, format: "TV"),
            .init(id: 3, format: "MOVIE"), .init(id: 4, format: "MOVIE"), .init(id: 5, format: "OVA")
        ])
        XCTAssertEqual(routes[182255], CatalogRoute(kind: .tv, id: 209867))
        XCTAssertEqual(routes[1], CatalogRoute(kind: .tv, id: 10))
        XCTAssertNil(routes[2])
        XCTAssertEqual(routes[3], CatalogRoute(kind: .movie, id: 30))
        XCTAssertNil(routes[4]); XCTAssertNil(routes[5])
    }
}
