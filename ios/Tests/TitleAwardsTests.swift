import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class TitleAwardsTests: XCTestCase {
    func testBundledHistoryUsesMovieAndSeriesIdentities() async throws {
        let history = TitleAwardHistory.shared
        let movie = try await history.titleRecords(.init(kind: .movie, id: 872585)) // Oppenheimer
        XCTAssertTrue(movie.contains { $0.year == 2024 && $0.ceremony == "Academy Awards" &&
            $0.category == "Best Picture" && $0.won })
        let show = try await history.titleRecords(.init(kind: .tv, id: 119051)) // Wednesday
        XCTAssertTrue(show.contains { $0.year == 2023 && $0.ceremony == "Golden Globes" && !$0.won })
        let other = try await history.titleRecords(.init(kind: .tv, id: 872585))
        XCTAssertTrue(other.isEmpty)
    }

    func testMatchingWorkAndPersonRecordsPreserveDistinctCreditsAndEditions() {
        let work = TitleAwardRecord(year: 2024, ceremony: "Academy Awards", category: "Best Sound", won: true)
        var first = work
        first.recipient = "First recipient"
        var second = work
        second.recipient = "Second recipient"
        let nomination = TitleAwardRecord(year: 2024, ceremony: "Academy Award", category: "Best Sound",
                                          won: false, recipient: first.recipient)
        let earlier = TitleAwardRecord(year: 2023, ceremony: "Academy Awards", category: "Best Sound",
                                       won: false, recipient: first.recipient)
        XCTAssertEqual(Set(TitleAwardsPage.sortedRecords([work, nomination, second, first, earlier])),
                       Set([first, second, earlier]))
    }
}
