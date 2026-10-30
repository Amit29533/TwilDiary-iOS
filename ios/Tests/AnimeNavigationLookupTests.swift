import XCTest
import TwilDiaryCore
import TwilDiaryTestSupport
@testable import TwilDiary

@MainActor private final class AnimeNavigationFixture: AnimeNavigationServing {
    var workspace = SampleWorkspace.make()
    var sessionRevision = UUID()
    var searches = 0, casts = 0
    var rotateSession = false, fail = false
    var knownRoute: CatalogRoute?, knownPerson: Int?
    func knownAnimeRoute(_ id: Int) async -> CatalogRoute? { knownRoute }
    func knownPersonID(_ id: Int) async -> Int? { knownPerson }
    var page = DiarySearchPage(library: [], online: [], page: 1, totalPages: 1)
    var credits: CastResponse {
        get throws {
            try JSONDecoder().decode(CastResponse.self, from: Data(#"{"cast":[{"id":700001,"name":"Kana Ichinose","character":"Fern"}],"stale":false}"#.utf8))
        }
    }
    func searchDiary(_ query: String, page: Int) async throws -> DiarySearchPage {
        searches += 1
        if rotateSession { sessionRevision = UUID(); rotateSession = false }
        if fail { throw APIError.message("Synthetic metadata outage") }
        return self.page
    }
    func cast(_ route: CatalogRoute) async throws -> CastResponse { casts += 1; return try credits }
}

@MainActor final class AnimeNavigationLookupTests: XCTestCase {
    private let santa = AniAppearance(id: 900002, title: "Rascal Does Not Dream of Santa Claus", cover: nil,
                                     year: 2025, role: "MAIN", voiceActor: nil, format: "TV")
    func testExactSantaClausOpensDirectlyDespiteAnUnrelatedDiaryHitAndCachesTheLookup() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        let item = CatalogItem(id: 910002, mediaType: .tv, name: santa.title, year: 2025)
        service.page = DiarySearchPage(library: service.workspace.activeTitles.prefix(1).map(SearchLibraryTitle.init), online: [item], page: 1, totalPages: 1)
        let first = try await lookup.title(santa, service: service)
        XCTAssertEqual(first.destination, .catalog(item.route))
        let second = try await lookup.title(santa, service: service)
        XCTAssertEqual(second.destination, first.destination); XCTAssertEqual(service.searches, 1)
        let otherCharacter = AniAppearance(id: santa.id, title: santa.title, cover: "different-poster", year: 2025,
                                          role: "SUPPORTING", voiceActor: nil, format: "TV")
        let third = try await lookup.title(otherCharacter, service: service)
        XCTAssertEqual(third.destination, first.destination); XCTAssertEqual(service.searches, 1)
    }
    func testKnapsackKidMovieOpensItsOwnTmdbRouteInsteadOfTheAniListID() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        let appearance = AniAppearance(id: 900001, title: "Rascal Does Not Dream of a Knapsack Kid", cover: nil,
                                       year: 2023, role: "MAIN", voiceActor: nil, format: "MOVIE")
        let item = CatalogItem(id: 910001, mediaType: .movie, name: appearance.title, year: 2023)
        service.page = DiarySearchPage(library: [], online: [item], page: 1, totalPages: 1)
        let result = try await lookup.title(appearance, service: service)
        XCTAssertEqual(result.destination, .catalog(item.route)); XCTAssertNotEqual(item.id, appearance.id)
    }
    func testLocalTitleOpensWithoutNetworkAndAmbiguousTitlesRequireAChoice() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        let title = try XCTUnwrap(service.workspace.activeTitles.first { $0.id == "frieren" })
        let appearance = AniAppearance(id: 154587, title: title.name, cover: nil, year: title.year, role: "MAIN", voiceActor: nil)
        let result = try await lookup.title(appearance, service: service)
        XCTAssertEqual(result.destination, .saved(title.id)); XCTAssertEqual(service.searches, 0)
        let duplicate = CatalogItem(id: 910002, mediaType: .tv, name: santa.title, year: 2025)
        let other = CatalogItem(id: 910003, mediaType: .tv, name: santa.title, year: 2025)
        service.page = DiarySearchPage(library: [], online: [duplicate, other], page: 1, totalPages: 1)
        let ambiguous = try await lookup.title(santa, service: service)
        XCTAssertNil(ambiguous.destination); XCTAssertEqual(ambiguous.page.online.count, 2)
    }
    func testSessionChangeRejectsInFlightResultsAndOldCacheIsNotReused() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        service.page = DiarySearchPage(library: [], online: [CatalogItem(id: 910002, mediaType: .tv, name: santa.title, year: 2025)], page: 1, totalPages: 1)
        service.rotateSession = true
        do { _ = try await lookup.title(santa, service: service); XCTFail("A stale session must not navigate") }
        catch is CancellationError { }
        _ = try await lookup.title(santa, service: service)
        XCTAssertEqual(service.searches, 2)
        service.sessionRevision = UUID()
        _ = try await lookup.title(santa, service: service)
        XCTAssertEqual(service.searches, 3)
    }
    func testFailedLookupCanRetryAndDoesNotPoisonTheCache() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup(); service.fail = true
        do { _ = try await lookup.title(santa, service: service); XCTFail("Expected failure") } catch { }
        service.fail = false
        service.page = DiarySearchPage(library: [], online: [CatalogItem(id: 910002, mediaType: .tv, name: santa.title, year: 2025)], page: 1, totalPages: 1)
        let result = try await lookup.title(santa, service: service)
        XCTAssertNotNil(result.destination); XCTAssertEqual(service.searches, 2)
    }
    func testVoiceActorUsesTmdbCreditsAndRemembersTheNativePersonIdentity() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        let actor = AniListPreview.voiceActor(12)
        let first = try await lookup.person(actor, knownID: nil, service: service)
        XCTAssertEqual(first, 700001); XCTAssertNotEqual(first, actor.id)
        let second = try await lookup.person(actor, knownID: nil, service: service)
        XCTAssertEqual(second, first); XCTAssertEqual(service.casts, 1); XCTAssertEqual(service.searches, 0)
    }
    func testKnownTmdbIDDoesNotPerformANameSearchOrReadCredits() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        let id = try await lookup.person(AniListPreview.voiceActor(12), knownID: 123456, service: service)
        XCTAssertEqual(id, 123456); XCTAssertEqual(service.searches, 0); XCTAssertEqual(service.casts, 0)
    }
    func testExistingAniListBridgeIsReusedWithoutSearchingAgain() async throws {
        let service = AnimeNavigationFixture(), lookup = AnimeNavigationLookup()
        let route = CatalogRoute(kind: .tv, id: 910002)
        service.knownRoute = route; service.knownPerson = 123456
        let title = try await lookup.title(santa, service: service)
        let person = try await lookup.person(AniListPreview.voiceActor(12), knownID: nil, service: service)
        XCTAssertEqual(title.destination, .catalog(route)); XCTAssertEqual(person, 123456)
        XCTAssertEqual(service.searches, 0); XCTAssertEqual(service.casts, 0)
    }
    func testShortLivedCacheExpiresAndReconcilesNewDiaryImportsByTmdbIdentity() async throws {
        let service = AnimeNavigationFixture()
        var clock = Date(timeIntervalSince1970: 1000)
        let lookup = AnimeNavigationLookup(now: { clock })
        service.page = DiarySearchPage(library: [], online: [CatalogItem(id: 910002, mediaType: .tv, name: santa.title, year: 2025)], page: 1, totalPages: 1)
        _ = try await lookup.title(santa, service: service)
        let saved = try JSONDecoder().decode(MediaTitle.self, from: Data(#"{"id":"renamed-santa","name":"My custom name","category":"anime","year":2025,"tmdbId":910002,"overview":"","genres":[],"status":"planned","favorite":false,"notes":""}"#.utf8))
        service.workspace.titles.append(saved)
        let cached = try await lookup.title(santa, service: service)
        XCTAssertEqual(cached.destination, .saved(saved.id)); XCTAssertEqual(service.searches, 1)
        clock = clock.addingTimeInterval(301)
        _ = try await lookup.title(santa, service: service)
        XCTAssertEqual(service.searches, 2)
    }
}
