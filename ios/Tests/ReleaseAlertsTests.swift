import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Release alerts: the dates read from TMDB's replies.
@MainActor final class ReleaseAlertsTests: XCTestCase {
    func testDigitalReleaseInYourRegionElseTheUS() {
        let data: [String: Any] = ["results": [
            ["iso_3166_1": "US", "release_dates": [["type": 3, "release_date": "2026-10-01T00:00:00.000Z"], ["type": 4, "release_date": "2026-12-02T00:00:00.000Z"]]],
            ["iso_3166_1": "IN", "release_dates": [["type": 4, "release_date": "2026-12-20T00:00:00.000Z"], ["type": 4, "release_date": "2026-12-10T00:00:00.000Z"]]],
        ]]
        XCTAssertEqual(ReleaseAlerts.digitalDay(data, region: "IN"), "2026-12-10", "the earliest digital date in your region")
        XCTAssertEqual(ReleaseAlerts.digitalDay(data, region: "GB"), "2026-12-02", "no date there: the US one")
        XCTAssertNil(ReleaseAlerts.digitalDay(["results": [["iso_3166_1": "US", "release_dates": [["type": 3, "release_date": "2026-10-01"]]]]], region: "US"),
                     "cinema only: nothing to stream yet")
    }

    func testShowsPremiereReturnOrNothing() {
        let premiere = ReleaseAlerts.showFound(["next_episode_to_air": ["air_date": "2027-03-14", "season_number": 3, "episode_number": 1]])
        XCTAssertEqual(premiere.kind, "premiere"); XCTAssertEqual(premiere.season, 3); XCTAssertEqual(premiere.day, "2027-03-14")
        let back = ReleaseAlerts.showFound(["next_episode_to_air": ["air_date": "2027-01-20", "season_number": 2, "episode_number": 9],
                                            "last_episode_to_air": ["air_date": "2026-11-20"]])
        XCTAssertEqual(back.kind, "return", "two months off: a return")
        let weekly = ReleaseAlerts.showFound(["next_episode_to_air": ["air_date": "2026-11-27", "season_number": 2, "episode_number": 9],
                                              "last_episode_to_air": ["air_date": "2026-11-20"]])
        XCTAssertNil(weekly.kind, "next week's episode is a new-episode alert, not a release")
        XCTAssertNil(ReleaseAlerts.showFound(["status": "Ended"]).day)
        XCTAssertEqual(ReleaseAlerts.days(from: "2026-11-20", to: "2027-01-20"), 61)
    }
}
