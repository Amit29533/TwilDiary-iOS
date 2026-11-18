import XCTest
import TwilDiaryCore
@testable import TwilDiary

final class IMDbEpisodeRatingsTests: XCTestCase {
    func testMatchesSeriesAndSeasonAndDropsMissingUnratedOrBarelyRatedEpisodes() throws {
        let json = #"{"id":"tt0944947","seasons":{"1":{"1":{"r":8.9,"v":42},"2":{"v":2},"3":{"r":7,"v":0},"4":{"r":10,"v":3}},"2":{"1":{"r":8.2,"v":18}}}}"#
        let data = Data(json.utf8)
        let result = try IMDbEpisodeRatings.decode(data, showID: "tt0944947")
        XCTAssertEqual(result[1], [.init(episode: 1, score: 8.9, votes: 42)])
        XCTAssertEqual(result[2], [.init(episode: 1, score: 8.2, votes: 18)])
        XCTAssertNil(result[3])
        XCTAssertThrowsError(try IMDbEpisodeRatings.decode(data, showID: "tt13443470"))
    }
}
