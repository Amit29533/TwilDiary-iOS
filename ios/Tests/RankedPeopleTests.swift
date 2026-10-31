import XCTest
@testable import TwilDiary

final class RankedPeopleTests: XCTestCase {
    private var row: RankedRow { RankedRow(id: 700001, name: "Reference Voice", detail: "Fern", image: nil, number: 17, count: "17 anime", extra: "223 plays") }
    func testDiaryVoicePreservesBothProviderIdentitiesAndWatchCount() {
        guard case .voice(let route) = RankedPerson.diary(row, voice: true, staffID: 12).destination else { return XCTFail("Expected voice actor") }
        XCTAssertEqual(route.id, 12)
        XCTAssertEqual(route.tmdbID, 700001)
        XCTAssertEqual(route.watchedCount, 17)
        guard case .voice(let unresolved) = RankedPerson.diary(row, voice: true).destination else { return XCTFail("Expected unresolved voice") }
        XCTAssertNil(unresolved.id, "A TMDB ID must never become an AniList staff ID")
        XCTAssertEqual(unresolved.name, row.name)
        XCTAssertEqual(unresolved.tmdbID, row.id)
    }
    func testAniListAndCastRankingsKeepTheirOwnRouteTypes() {
        XCTAssertEqual(RankedPerson.aniList(row, voice: false).destination, .character(row.id))
        XCTAssertEqual(RankedPerson.diary(row, voice: false).destination, .cast(row.id))
        guard case .voice(let route) = RankedPerson.aniList(row, voice: true).destination else { return XCTFail("Expected staff identity") }
        XCTAssertEqual(route.id, row.id)
        XCTAssertNil(route.tmdbID)
    }
    func testViewAllKeepsTheLoadedOrderDetailsAndProviderDestinations() {
        let other = RankedRow(id: 42, name: "Second person", detail: "A long role in another title", image: nil, number: 4, count: "4 titles", extra: "80 plays")
        let snapshot = PeopleRankingRoute(category: "Cast", identifier: "top-cast", people: [.diary(row, voice: false), .diary(other, voice: false)])
        XCTAssertEqual(snapshot.people.map(\.id), [700001, 42])
        XCTAssertEqual(snapshot.people[1].row.detail, other.detail)
        XCTAssertEqual(snapshot.people[1].row.extra, "80 plays")
        XCTAssertEqual(snapshot.people[1].destination, .cast(42))
    }
}
