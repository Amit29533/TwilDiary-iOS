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
}
