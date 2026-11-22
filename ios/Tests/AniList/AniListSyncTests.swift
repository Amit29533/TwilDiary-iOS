import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// The AniList sync's sign-in reply (the implicit grant's redirect).
final class AniListSyncTests: XCTestCase {
    func testTheTokenComesBackInTheRedirectsFragment() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (token, expires) = try AniListSyncAccount.token(from: URL(string: "twildiary://auth/anilist#access_token=abc.def&token_type=Bearer&expires_in=31536000")!, now: now)
        XCTAssertEqual(token, "abc.def")
        XCTAssertEqual(expires, now.addingTimeInterval(31_536_000), "a year")
        XCTAssertThrowsError(try AniListSyncAccount.token(from: URL(string: "twildiary://auth/anilist?error=access_denied")!), "declined")
        XCTAssertThrowsError(try AniListSyncAccount.token(from: URL(string: "twildiary://auth/anilist")!), "nothing came back")
    }

    func testAniListDatesReadAndWriteAsDays() {
        XCTAssertEqual(AniListSyncAPI.day(["year": 2016, "month": 4, "day": 4]), "2016-04-04")
        XCTAssertNil(AniListSyncAPI.day(["year": 2016, "month": NSNull(), "day": NSNull()] as [String: Any]), "a year alone isn't a day")
        XCTAssertEqual(AniListSyncAPI.fuzzy("2021-04-07T12:04:00Z"), ["year": 2021, "month": 4, "day": 7])
    }

    /// A date to clear goes as nulls (left out, AniList keeps the old one: checked on the test account).
    func testAClearedDateGoesAsNulls() throws {
        let empty: [String: any Sendable] = ["year": AniListSyncAPI.Null(), "month": AniListSyncAPI.Null(), "day": AniListSyncAPI.Null()]
        let data = try AniListSyncAPI.body("mutation", ["mediaId": 15583, "completedAt": empty, "startedAt": ["year": 2021, "month": 4, "day": 7] as [String: any Sendable]])
        let variables = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["variables"] as? [String: Any])
        XCTAssertTrue((variables["completedAt"] as? [String: Any])?["year"] is NSNull)
        XCTAssertEqual((variables["startedAt"] as? [String: Any])?["day"] as? Int, 7)
        XCTAssertEqual(variables["mediaId"] as? Int, 15583)
    }

    /// The id map's reply (arm.haglund.dev, 2026-11-15): a film by its MOVIE entry, a show by its
    /// first TMDB season; TMDB's movie and TV ids overlap, so the kind must fit.
    @MainActor func testTheIdMapGivesTheFilmOrTheShowsFirstSeason() {
        let film = Data(#"[{"anilist":21519,"media":"MOVIE","themoviedb":372058,"themoviedb-season":null,"myanimelist":32281}]"#.utf8)
        XCTAssertEqual(AniListSync.mappedID(from: film, film: true), 21519)
        XCTAssertNil(AniListSync.mappedID(from: film, film: false), "a TV id that happens to equal a film's isn't that film")
        let show = Data(#"[{"anilist":108632,"media":"TV","themoviedb-season":2},{"anilist":21355,"media":"TV","themoviedb-season":1},{"media":"TV","themoviedb-season":3}]"#.utf8)
        XCTAssertEqual(AniListSync.mappedID(from: show, film: false), 21355)
        XCTAssertNil(AniListSync.mappedID(from: Data("[]".utf8), film: false))
    }
}
