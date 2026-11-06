import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// The rules behind the automatic Trakt copy: what Trakt has held, when the diary changed it, and
/// when Trakt last changed that list (the newer change wins).
@MainActor final class TraktSyncRulesTests: XCTestCase {
    private func title(_ json: String) throws -> MediaTitle {
        try JSONDecoder().decode(MediaTitle.self, from: Data(json.utf8))
    }
    private func show(updatedAt: String?) throws -> MediaTitle {
        try title(#"{"id":"t1","name":"Frieren","category":"anime","year":2023,"overview":"","poster":null,"backdrop":null,"communityScore":null,"tmdbId":209867,"genres":[],"runtimeMinutes":null,"status":"planned","favorite":false,"score":null,"notes":"","deletedAt":null,"version":1,"createdAt":"2026-01-01T00:00:00Z""# + (updatedAt.map { #","updatedAt":""# + $0 + #"""# } ?? "") + "}")
    }
    private let ref = TraktTitleRef(kind: .show, traktId: 1, tmdbId: 209867, name: "Frieren", year: 2023)

    func testTokensCoverEveryListTraktHolds() {
        let movie = TraktTitleRef(kind: .movie, traktId: 2, tmdbId: 603, name: "The Matrix", year: 1999)
        let library = TraktLibrary(plays: [TraktPlay(historyId: 1, title: ref, season: 1, episode: 2, watchedAt: nil),
                                           TraktPlay(historyId: 2, title: movie, watchedAt: nil)],
                                   ratings: [TraktRating(title: ref, rating: 9, ratedAt: nil)],
                                   watchlist: [TraktListed(title: movie, listedAt: nil)])
        XCTAssertEqual(TraktDirectStore.tokens(library),
                       ["play|tv:209867|s1e2", "play|movie:603", "rating|tv:209867", "planned|movie:603"])
    }

    func testDiaryTimeIsTheTitleChangeOrTheWatchItself() throws {
        let episode = try JSONDecoder().decode(Episode.self, from: Data(#"{"id":"e1","titleId":"t1","season":1,"number":2,"name":"","overview":"","airedOn":null,"still":null}"#.utf8))
        let watch = WatchEvent(id: "w1", operationId: "o1", titleId: "t1", episodeId: "e1", watchedAt: "2026-11-01T10:00:00Z", recordedAt: "2026-11-02T08:00:00Z")
        let diary = Workspace(titles: [try show(updatedAt: "2026-11-05T12:00:00Z")], episodes: [episode], events: [watch])
        XCTAssertEqual(TraktDirectStore.diaryTime("planned|tv:209867", diary), DiaryDate.parse("2026-11-05T12:00:00Z"))
        XCTAssertEqual(TraktDirectStore.diaryTime("play|tv:209867|s1e2", diary), DiaryDate.parse("2026-11-02T08:00:00Z"), "a play uses when it was recorded")
        XCTAssertNil(TraktDirectStore.diaryTime("play|tv:209867|s1e3", diary), "an episode the diary doesn't have")
        XCTAssertNil(TraktDirectStore.diaryTime("planned|movie:603", diary), "a title the diary doesn't have")
        let old = Workspace(titles: [try show(updatedAt: nil)])
        XCTAssertNil(TraktDirectStore.diaryTime("planned|tv:209867", old), "no change time from an older server")
    }

    func testTraktTimeIsTheLatestChangeToThatList() {
        let library = TraktLibrary(activities: TraktActivities(all: nil, stamps: [
            "movies.watchlisted_at": "2026-11-03T09:00:00Z", "shows.watchlisted_at": "2026-11-04T09:00:00Z",
            "shows.rated_at": "2026-10-01T00:00:00Z"
        ]))
        XCTAssertEqual(TraktDirectStore.traktTime("planned|tv:1", library), DiaryDate.parse("2026-11-04T09:00:00Z"))
        XCTAssertEqual(TraktDirectStore.traktTime("rating|tv:1", library), DiaryDate.parse("2026-10-01T00:00:00Z"))
        XCTAssertNil(TraktDirectStore.traktTime("favourite|tv:1", library), "no time reported for that list")
        XCTAssertNil(TraktDirectStore.traktTime("unknown|tv:1", library))
    }

    func testTitlesDecodeWithAndWithoutChangeTime() throws {
        XCTAssertEqual(try show(updatedAt: "2026-11-05T12:00:00Z").updatedAt, "2026-11-05T12:00:00Z")
        XCTAssertNil(try show(updatedAt: nil).updatedAt)
    }
}
