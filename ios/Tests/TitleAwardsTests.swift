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

    /// Oppenheimer (2026-11-19): the archive's "BAFTA Film Awards" and Wikidata's "British Academy
    /// Film Awards" (or no family at all) are one ceremony; "Best Writing, Adapted Screenplay" is
    /// "Best Adapted Screenplay"; a Golden Globe Wikidata dates 2023 belongs to the archive's 2024.
    func testArchiveAndWikidataNameTheSameAwardTheSameWay() {
        let archive = [
            TitleAwardRecord(year: 2024, ceremony: "BAFTA Film Awards", category: "Best Cinematography", won: true),
            TitleAwardRecord(year: 2024, ceremony: "Academy Awards", category: "Best Adapted Screenplay", won: false),
            TitleAwardRecord(year: 2024, ceremony: "Golden Globes", category: "Best Original Score - Motion Picture", won: true)
        ]
        let people = [
            TitleAwardRecord(year: 2024, ceremony: "Other awards", category: "BAFTA Award for Best Cinematography", won: true, recipient: "Hoyte van Hoytema"),
            TitleAwardRecord(year: 2024, ceremony: "British Academy Film Awards", category: "BAFTA Award for Best Direction", won: true, recipient: "Christopher Nolan"),
            TitleAwardRecord(year: 2024, ceremony: "Other awards", category: "Academy Award for Best Writing, Adapted Screenplay", won: false, recipient: "Christopher Nolan"),
            TitleAwardRecord(year: 2023, ceremony: "Golden Globes", category: "Golden Globe Award for Best Original Score", won: true, recipient: "Ludwig Göransson")
        ]
        let merged = AwardNames.merge(archive: archive, people: people, movie: true)
        let credits = Array(merged.suffix(4))
        XCTAssertEqual(credits[0].ceremony, "BAFTA Film Awards")
        XCTAssertEqual(credits[0].category, "Best Cinematography")
        XCTAssertEqual(credits[1].ceremony, "BAFTA Film Awards")
        XCTAssertEqual(credits[1].category, "Best Director")
        XCTAssertEqual(credits[2].ceremony, "Academy Awards")
        XCTAssertEqual(credits[2].category, "Best Adapted Screenplay")
        XCTAssertEqual(credits[3].year, 2024, "the archive's edition")
        XCTAssertEqual(credits[3].category, "Best Original Score \u{2013} Motion Picture", "the archive's fuller name for it")
        XCTAssertFalse(TitleAwardsPage.sortedRecords(merged).contains { $0.recipient == nil && $0.category.hasPrefix("Best Original Score") })
        XCTAssertEqual(merged[2].category, "Best Original Score \u{2013} Motion Picture", "one kind of dash")
        // Named credits stand in for the archive's own row of the same award.
        let shown = TitleAwardsPage.sortedRecords(merged)
        XCTAssertFalse(shown.contains { $0.recipient == nil && $0.category == "Best Cinematography" })
        XCTAssertFalse(shown.contains { $0.recipient == nil && $0.category == "Best Adapted Screenplay" })
        // A show keeps Wikidata's year: its seasons are honoured year after year.
        XCTAssertEqual(AwardNames.merge(archive: archive, people: [people[3]], movie: false).last?.year, 2023)
    }

    /// The title page's summary: per ceremony, wins and other nominations, an award shared by
    /// several people counted once; the most decorated ceremony first.
    func testCeremonyCountsCountEachAwardOnce() {
        let rows = [
            TitleAwardRecord(year: 2024, ceremony: "Academy Awards", category: "Best Picture", won: true, recipient: "Emma Thomas"),
            TitleAwardRecord(year: 2024, ceremony: "Academy Awards", category: "Best Picture", won: true, recipient: "Charles Roven"),
            TitleAwardRecord(year: 2024, ceremony: "Academy Awards", category: "Best Sound", won: false),
            TitleAwardRecord(year: 2024, ceremony: "Actor Awards", category: "Cast", won: false),
            TitleAwardRecord(year: 2024, ceremony: "Actor Awards", category: "Actor", won: false),
            TitleAwardRecord(year: 2024, ceremony: "Golden Globes", category: "Drama", won: true),
            TitleAwardRecord(year: 2024, ceremony: "Golden Globes", category: "Drama", won: false)
        ]
        let counts = TitleAwardsPage.ceremonyCounts(rows)
        XCTAssertEqual(counts.map(\.ceremony), ["Oscars", "Golden Globes", "SAG Awards"])
        XCTAssertEqual(counts[0], .init(ceremony: "Oscars", wins: 1, nominations: 1))
        XCTAssertEqual(counts[1], .init(ceremony: "Golden Globes", wins: 1, nominations: 0), "won, so not also counted as a nomination")
        XCTAssertEqual(counts[2], .init(ceremony: "SAG Awards", wins: 0, nominations: 2))
    }
}
