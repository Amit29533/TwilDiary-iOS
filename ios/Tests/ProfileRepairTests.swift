import XCTest
import TwilDiaryCore
@testable import TwilDiary

final class ProfileRepairTests: XCTestCase {
    func testHtmlBiographyLinksStayNativeAndHiddenSpoilersCannotExposeLinks() {
        let value = AniListText.formatted("<a href=\"https://anilist.co/character/2\">Fern</a> ~!<a href=\"https://anilist.co/character/3\">Hidden</a>!~", hideSpoilers: true)
        XCTAssertEqual(value.runs.compactMap { $0.link }, [URL(string: "https://anilist.co/character/2")!])
        XCTAssertFalse(String(value.characters).contains("Hidden"))
        XCTAssertFalse(AniListText.markdown("<a href=\"javascript:alert(1)\">Name</a>", hideSpoilers: true).contains("javascript"))
    }
    func testOfficialProfileLinksPreserveProviderIdentityAndIgnoreSlug() {
        XCTAssertEqual(ProfileDeepLink.parse(URL(string: "https://anilist.co/character/2/Fern")!), .character(2))
        XCTAssertEqual(ProfileDeepLink.parse(URL(string: "https://anilist.co/staff/11")!), .voice(11))
        XCTAssertEqual(ProfileDeepLink.parse(URL(string: "https://anilist.co/anime/154587/example?x=1")!), .anime(154587))
        XCTAssertEqual(ProfileDeepLink.parse(URL(string: "https://www.themoviedb.org/person/525-example")!), .person(525))
    }
    func testLookalikeHostsCredentialsAndInvalidProviderIDsStayOutsideNativeRoutes() {
        for raw in ["https://anilist.co.evil.test/character/2", "https://anilist.co/character/0", "https://anilist.co/character/-2", "https://example.com/staff/11", "https://user@anilist.co/staff/11", "https://anilist.co:444/staff/11", "https://anilist.co/manga/11"] {
            XCTAssertNil(ProfileDeepLink.parse(URL(string: raw)!), raw)
        }
    }
    func testWatchedAnimeCreditsUseHistoryAndDeduplicateAppearances() throws {
        let snapshot = PreviewData.profileRepairWorkspace
        let title = try XCTUnwrap(snapshot.activeTitles.first { $0.id == "frieren" })
        let appearance = AniAppearance(id: 154587, title: title.name, cover: nil, year: title.year, role: nil, voiceActor: nil, format: "TV")
        XCTAssertEqual(ProfileWatchMatching.titles([appearance, appearance], workspace: snapshot).map(\.id), [title.id])
        var cleared = snapshot; cleared.events = []
        XCTAssertTrue(ProfileWatchMatching.titles([appearance], workspace: cleared).isEmpty, "Watching status and files are not watch events")
    }
    func testConfirmedAnimeIdentityDoesNotFallBackToAnotherTitleByName() throws {
        let snapshot = PreviewData.profileRepairWorkspace
        let title = try XCTUnwrap(snapshot.activeTitles.first { $0.id == "frieren" })
        let appearance = AniAppearance(id: 154587, title: title.name, cover: nil, year: title.year, role: nil, voiceActor: nil)
        let id = try XCTUnwrap(title.tmdbId)
        XCTAssertEqual(ProfileWatchMatching.titles([appearance], workspace: snapshot, confirmed: [154587: CatalogRoute(kind: .tv, id: id)]).map(\.id), [title.id])
        XCTAssertTrue(ProfileWatchMatching.titles([appearance], workspace: snapshot, confirmed: [154587: CatalogRoute(kind: .movie, id: id)]).isEmpty, "TMDB movie and TV identities are distinct")
        XCTAssertTrue(ProfileWatchMatching.titles([appearance], workspace: snapshot, confirmed: [154587: CatalogRoute(kind: .tv, id: 999999)]).isEmpty, "A confirmed different title cannot be overridden by a name match")
    }
    func testCastWatchedCreditsExcludePlannedAndRevokedHistoryAndKeepMediaKinds() throws {
        var snapshot = PreviewData.profileRepairWorkspace
        let credits = snapshot.activeTitles.compactMap { title -> [String: Any]? in
            guard let id = title.tmdbId else { return nil }
            return ["id": id, "mediaType": title.isSeries ? "tv" : "movie", "name": title.name, "overview": ""]
        }
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "name": "Reference", "biography": "", "birthplace": "", "department": "Acting", "credits": credits])
        let person = try JSONDecoder().decode(PersonDetails.self, from: data)
        let expected = Set(snapshot.activeTitles.filter { title in snapshot.activeEvents.contains { $0.titleId == title.id } }.compactMap { title in title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } })
        XCTAssertFalse(expected.isEmpty, "Fixture must exercise actual matching credits")
        XCTAssertEqual(Set(PersonSections(person: person, workspace: snapshot).watched.map(\.key)), expected)
        let revoked = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.events)) as! [[String: Any]]
        snapshot.events = try JSONDecoder().decode([WatchEvent].self, from: JSONSerialization.data(withJSONObject: revoked.map { row in
            var value = row; value["revokedAt"] = "2026-10-31T00:00:00Z"; return value
        }))
        XCTAssertTrue(PersonSections(person: person, workspace: snapshot).watched.isEmpty, "Revoked watches cannot populate Watched")
        snapshot.events = []
        XCTAssertTrue(PersonSections(person: person, workspace: snapshot).watched.isEmpty)
        let filters = PersonFilmographyFilters(section: .credits, watchedOnly: true)
        XCTAssertTrue(filters.applying(person: person, workspace: snapshot, section: .credits).isEmpty)
    }
}
