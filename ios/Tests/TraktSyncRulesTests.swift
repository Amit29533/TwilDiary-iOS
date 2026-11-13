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

    func testTitlesDecodeWithAndWithoutChangeTime() throws {
        XCTAssertEqual(try show(updatedAt: "2026-11-05T12:00:00Z").updatedAt, "2026-11-05T12:00:00Z")
        XCTAssertNil(try show(updatedAt: nil).updatedAt)
    }
}
