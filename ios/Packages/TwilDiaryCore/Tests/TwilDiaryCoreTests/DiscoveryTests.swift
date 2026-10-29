import Foundation
import Testing
@testable import TwilDiaryCore

private struct DiscoveryGolden: Decodable {
    struct Pick: Decodable { let day: String; let id: String? }
    struct Scenario: Decodable {
        struct Filters: Decodable {
            let type: String; let genre: String; let year: String; let sort: String; let minimum: Double?; let error: String
        }
        let section: DiscoverySection; let filters: Filters; let expectedKeys: [String]
    }
    let workspace: Workspace; let unwatched: [String]; let picks: [Pick]; let items: [CatalogItem]; let cases: [Scenario]; let merged: [String]
    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "discovery-golden", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@Test func discoveryFiltersMatchEveryWebGoldenScenario() throws {
    let fixture = try DiscoveryGolden.load()
    for scenario in fixture.cases {
        var filters = DiscoveryFilters(section: scenario.section)
        filters.type = scenario.filters.type; filters.genre = scenario.filters.genre; filters.year = scenario.filters.year
        filters.sort = scenario.filters.sort; filters.minimum = scenario.filters.minimum.map { String($0) } ?? "invalid"
        // JSON stores the parsed numeric minimum; invalid raw syntax is validated separately below.
        #expect(filters.applying(fixture.items).map(\.key) == scenario.expectedKeys, "\(scenario.section.rawValue): \(scenario.filters)")
        if scenario.filters.error.isEmpty { #expect(filters.error(section: scenario.section) == nil) }
    }
}

@Test func dailyDiscoveryMatchesWebHashAndNeverPicksStartedOrArchivedTitles() throws {
    let fixture = try DiscoveryGolden.load()
    #expect(DiscoveryTools.unwatched(fixture.workspace).map(\.id) == fixture.unwatched)
    for pick in fixture.picks { #expect(DiscoveryTools.dailyPick(fixture.workspace, day: pick.day)?.id == pick.id) }
    #expect(DiscoveryTools.dailyPick(Workspace(), day: "2026-10-23") == nil)
}

@Test func discoveryValidationPreservesWebErrorPriorityAndMediaSpecificGenres() {
    var filters = DiscoveryFilters(section: .genres)
    filters.genre = "Fantasy"; #expect(filters.error(section: .genres) == "Choose a supported genre.")
    filters.type = "movie"; #expect(filters.error(section: .genres) == nil)
    filters.minimum = "10.1"; #expect(filters.error(section: .genres) == "Choose a rating from 0 to 10.")
    filters.year = "1879"; #expect(filters.error(section: .genres) == "Enter a year from 1880 to 2200.")
    for raw in ["-1", "11", "7.55", "7e0", "", "NaN"] { filters.year = ""; filters.minimum = raw; #expect(filters.error(section: .genres) == "Choose a rating from 0 to 10.") }
    filters.minimum = "10.0"; #expect(filters.error(section: .genres) == nil)
    #expect(!DiscoveryGenre.names(type: "movie").contains("Reality"))
    #expect(DiscoveryGenre.names(type: "tv").contains("Reality"))
    // TMDB has no TV Romance genre; the server finds those shows by keyword.
    #expect(DiscoveryGenre.names(type: "tv").contains("Romance"))
}

@Test func discoveryMergesBothPagesByMediaIdentityAndKeepsFirstOccurrence() throws {
    let fixture = try DiscoveryGolden.load()
    let first = fixture.items[0], second = fixture.items[1]
    let sameIDMovie = CatalogItem(id: first.id, mediaType: .movie, name: first.name)
    #expect(CatalogTools.merging([first, first, second], [second, sameIDMovie]).map(\.key) == fixture.merged)
}
