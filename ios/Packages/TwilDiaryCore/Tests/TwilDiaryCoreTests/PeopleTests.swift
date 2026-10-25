import Foundation
import Testing
@testable import TwilDiaryCore

private struct PeopleGolden: Decodable {
    struct Scenario: Decodable { let kind: PersonSection; let params: [String: String]; let expectedKeys: [String]; let heading: String; let error: String }
    let workspace: Workspace; let person: PersonDetails; let sections: [String: [String]]; let cases: [Scenario]
    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "people-golden", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
@Test func personSectionsMatchWebRoleProminenceAndServerMediaIdentity() throws {
    let fixture = try PeopleGolden.load(), sections = PersonSections(person: fixture.person, workspace: fixture.workspace)
    #expect(sections.movies.map(\.key) == fixture.sections["movies"])
    #expect(sections.shows.map(\.key) == fixture.sections["shows"])
    #expect(sections.knownFor.map(\.key) == fixture.sections["knownFor"])
    #expect(sections.localMovies.map(\.key) == fixture.sections["localMovies"])
    #expect(sections.localShows.map(\.key) == fixture.sections["localShows"])
    #expect(!sections.knownFor.contains { ($0.character ?? "").hasPrefix("Self -") })
    #expect(sections.knownFor.count == 12)
}
@Test func personFilmographyMatchesAllWebGoldenFiltersSortsAndErrors() throws {
    let fixture = try PeopleGolden.load()
    for scenario in fixture.cases {
        var filters = PersonFilmographyFilters(section: scenario.kind, onServer: scenario.params["scope"] == "server")
        filters.sort = scenario.params["sort"] ?? filters.sort
        filters.genre = scenario.params["genre"] ?? ""; filters.year = scenario.params["year"] ?? ""
        filters.minimum = scenario.params["minimum"] ?? "0"; filters.query = scenario.params["q"] ?? ""
        #expect(filters.applying(person: fixture.person, workspace: fixture.workspace, section: scenario.kind).map(\.key) == scenario.expectedKeys, "\(scenario.kind.rawValue): \(scenario.params)")
        #expect((filters.error ?? "") == scenario.error)
        #expect(filters.heading(person: fixture.person, section: scenario.kind) == scenario.heading)
    }
}

@Test func catalogIdentityResolvesOnlyTheMatchingMediaKindAndManualLibraryID() throws {
    let fixture = try PeopleGolden.load()
    #expect(CatalogTools.libraryIdentity(CatalogItem(id: 42, mediaType: .tv, name: "Series"), in: fixture.workspace) == "frieren")
    #expect(CatalogTools.libraryIdentity(CatalogItem(id: 42, mediaType: .movie, name: "Movie"), in: fixture.workspace) == "after-rain")
    #expect(CatalogTools.libraryIdentity(CatalogItem(id: 0, mediaType: .movie, name: "Manual", inLibraryId: "quiet-orbit"), in: fixture.workspace) == "quiet-orbit")
    #expect(CatalogTools.libraryIdentity(CatalogItem(id: 0, mediaType: .tv, name: "Missing", inLibraryId: "missing"), in: fixture.workspace) == nil)
}
