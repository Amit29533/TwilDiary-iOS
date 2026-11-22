import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Explore's new rows: this season's anime (AniList's seasons and the next-episode countdown)
/// and Coming soon's day labels.
@MainActor final class ExploreMoreTests: XCTestCase {
    func testAniListSeasonsByMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func date(_ month: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: 15))! }
        XCTAssertEqual(SeasonalAnime.Season.of(date(1), calendar: calendar).season, .winter)
        XCTAssertEqual(SeasonalAnime.Season.of(date(4), calendar: calendar).season, .spring)
        XCTAssertEqual(SeasonalAnime.Season.of(date(9), calendar: calendar).season, .summer)
        XCTAssertEqual(SeasonalAnime.Season.of(date(11), calendar: calendar).season, .fall)
        XCTAssertEqual(SeasonalAnime.Season.of(date(11), calendar: calendar).year, 2026)
        XCTAssertEqual(SeasonalAnime.Season.fall.name, "Fall")
    }

    func testNextEpisodeCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SeasonalAnime.countdown(episode: 8, at: now.addingTimeInterval(2 * 86_400 + 4 * 3_600 + 60), now: now), "Ep 8 in 2d 4h")
        XCTAssertEqual(SeasonalAnime.countdown(episode: 8, at: now.addingTimeInterval(3 * 3_600 + 5 * 60), now: now), "Ep 8 in 3h 5m")
        XCTAssertEqual(SeasonalAnime.countdown(episode: 9, at: now.addingTimeInterval(35 * 60), now: now), "Ep 9 in 35m")
        XCTAssertEqual(SeasonalAnime.countdown(episode: 9, at: now.addingTimeInterval(-60), now: now), "Ep 9 airing now")
        XCTAssertNil(SeasonalAnime.countdown(episode: nil, at: nil, now: now), "finished: no countdown")
    }

    func testOneTapPromptsAreSentAsDescriptions() {
        let route = ExploreAIPromptRoute(label: "Cozy anime", prompt: "Cozy, relaxing slice-of-life anime")
        let text = (((SemanticSearch.body(route.prompt)["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, route.prompt, "only the prompt's description is sent")
        let custom = SemanticSearch.body("x", instruction: "Recommend")
        let instruction = (((custom["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(instruction, "Recommend", "CineMind's picks use their own instruction")
    }
}
