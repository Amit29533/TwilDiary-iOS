import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// The Parental Guide's IMDb levels and ages, and the rating chart lining each source's episodes up
/// with TMDB's.
final class ParentsGuideAndSeriesRatingsTests: XCTestCase {
    func testReadsIMDbParentsGuideInOrderWithLevels() throws {
        let json = #"{"data":{"title":{"certificate":{"rating":"TV-MA"},"parentsGuide":{"categories":[{"category":{"id":"PROFANITY"},"severity":{"text":"Severe"}},{"category":{"id":"NUDITY"},"severity":{"text":"Mild"}},{"category":{"id":"ALCOHOL"},"severity":{"text":"None"}},{"category":{"id":"SPOILERS"},"severity":{"text":"Severe"}},{"category":{"id":"VIOLENCE"},"severity":{"text":"Moderate"}}]}}}}"#
        let guide = try ParentsGuide.decode(Data(json.utf8))
        XCTAssertEqual(guide.certificate, "TV-MA")
        XCTAssertEqual(guide.categories.map(\.id), ["NUDITY", "VIOLENCE", "PROFANITY", "ALCOHOL"], "IMDb's order; unknown categories left out")
        XCTAssertEqual(guide.categories.map(\.levelName), ["Mild", "Moderate", "Severe", "None"])
        XCTAssertEqual(guide.categories.map(\.bars), [2, 3, 5, 0], "out of five")
        XCTAssertThrowsError(try ParentsGuide.decode(Data(#"{"data":{"title":null}}"#.utf8)))
    }

    func testAgeForARating() {
        XCTAssertEqual(ParentsGuide.age(for: "TV-PG"), "10+")
        XCTAssertEqual(ParentsGuide.age(for: "PG-13"), "13+")
        XCTAssertEqual(ParentsGuide.age(for: "R"), "17+")
        XCTAssertEqual(ParentsGuide.age(for: "G"), "All ages")
        XCTAssertEqual(ParentsGuide.age(for: "15"), "15+")
        XCTAssertEqual(ParentsGuide.age(for: "16+"), "16+")
        XCTAssertNil(ParentsGuide.age(for: "Approved"))
    }

    func testEpisodesLineUpByNumberElseByOrder() {
        let score = SeriesRatings.Score(value: 8, votes: 10)
        let base = [(season: 1, number: 1), (season: 1, number: 2), (season: 2, number: 1), (season: 2, number: 2)]
        // The same numbers: by season and number.
        let same = SeriesRatings.align(base, [(season: 2, number: 1, score: score), (season: 1, number: 2, score: score)])
        XCTAssertEqual(Set(same.keys), [2, 1])
        // One long season elsewhere (an anime split differently): by order, as the counts agree.
        let long = SeriesRatings.align(base, (1...4).map { (season: 1, number: $0, score: SeriesRatings.Score(value: Double($0), votes: 1)) })
        XCTAssertEqual(long[2]?.value, 3, "the third episode either way")
        // Neither: left out rather than mismatched.
        XCTAssertTrue(SeriesRatings.align(base, (1...10).map { (season: 1, number: $0 + 20, score: score) }).isEmpty)
    }

    func testOverallIsThePlainAverageOfTheSources() {
        let episode = SeriesRatings.Episode(index: 1, season: 1, number: 1, name: nil,
                                            scores: [.imdb: .init(value: 9, votes: 1000), .tmdb: .init(value: 8, votes: 10), .trakt: .init(value: 7, votes: 100)])
        XCTAssertEqual(episode.overall, 8)
        XCTAssertEqual(episode.votes, 1110)
        XCTAssertEqual(episode.score(.tmdb), 8)
        XCTAssertEqual(episode.score(nil), 8)
    }
}
