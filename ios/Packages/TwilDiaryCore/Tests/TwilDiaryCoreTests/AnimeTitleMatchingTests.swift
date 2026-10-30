import Foundation
import Testing
@testable import TwilDiaryCore

@Test func animeAppearanceNavigationRequiresAnUnambiguousTitleMatch() throws {
    let names = ["Demon Slayer: Kimetsu no Yaiba", "Kimetsu no Yaiba"]
    let show = CatalogItem(id: 85937, mediaType: .tv, name: names[0], year: 2019)
    let movie = CatalogItem(id: 635302, mediaType: .movie, name: names[0], year: 2020)
    let remake = CatalogItem(id: 123, mediaType: .tv, name: names[0], year: 2026)
    #expect(AnimeTitleMatching.catalog([movie, remake, show], names: names, year: 2019, kind: .tv)?.route == show.route)
    // These are TMDB routes, never the AniList ID carried by the tapped poster.
    #expect(show.route.id == 85937)
    #expect(AnimeTitleMatching.catalog([movie, show], names: names, year: nil, kind: nil) == nil)
    #expect(AnimeTitleMatching.catalog([remake], names: names, year: 2019, kind: .tv) == nil)
    #expect(AnimeTitleMatching.catalog([movie], names: names, year: 2020, kind: .tv) == nil)
    #expect(AnimeTitleMatching.catalog([show, show], names: names, year: 2019, kind: .tv)?.id == show.id)
    let alias = CatalogItem(id: 85937, mediaType: .tv, name: "KIMETSU NO YAIBA", year: 2019)
    #expect(AnimeTitleMatching.catalog([alias], names: names, year: 2019, kind: .tv)?.id == show.id)
    let ambiguous = CatalogItem(id: 999, mediaType: .tv, name: names[0], year: 2019)
    #expect(AnimeTitleMatching.catalog([show, ambiguous], names: names, year: 2019, kind: .tv) == nil)
    #expect(AnimeTitleMatching.catalog([show], names: ["Different anime"], year: 2019, kind: .tv) == nil)
    #expect(AnimeTitleMatching.catalog([show], names: [""], year: 2019, kind: .tv) == nil)

    func saved(_ id: String, category: String = "anime", deletedAt: String? = nil) throws -> MediaTitle {
        var object: [String: Any] = ["id": id, "name": names[0], "category": category, "year": 2019,
                                   "overview": "", "genres": [], "status": "watching", "favorite": false, "notes": ""]
        if let deletedAt { object["deletedAt"] = deletedAt }
        return try JSONDecoder().decode(MediaTitle.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let active = try saved("saved-show")
    let film = try saved("film", category: "anime-movie")
    let trash = try saved("trash", deletedAt: "2026-10-30T00:00:00Z")
    #expect(AnimeTitleMatching.saved([active, film, trash], names: names, year: 2019, kind: .tv).map(\.id) == [active.id])
    #expect(AnimeTitleMatching.saved([active], names: names, year: 2020, kind: .tv).isEmpty)
    let duplicate = try saved("another-copy")
    #expect(AnimeTitleMatching.saved([active, duplicate], names: names, year: 2019, kind: .tv).count == 2)
    // The server removes known identities from `online`; preserve their diary links
    // independently of the exact-name matcher (including a user's renamed title).
    var renamedObject: [String: Any] = ["id": "renamed", "name": "My custom anime name", "category": "anime",
                                        "overview": "", "genres": [], "status": "watching", "favorite": false, "notes": ""]
    renamedObject["year"] = 2019
    let renamed = try JSONDecoder().decode(MediaTitle.self, from: JSONSerialization.data(withJSONObject: renamedObject))
    let page = DiarySearchPage(library: [SearchLibraryTitle(renamed), SearchLibraryTitle(film)], online: [], page: 1, totalPages: 1)
    #expect(AnimeTitleMatching.libraryChoices([], page: page, kind: .tv).map(\.id) == [renamed.id])
    #expect(AnimeTitleMatching.libraryChoices([SearchLibraryTitle(renamed)], page: page, kind: nil).map(\.id) == [renamed.id, film.id])
    let exact = CatalogItem(id: 910002, mediaType: .tv, name: "Rascal Does Not Dream of Santa Claus", year: 2025)
    let withNoise = DiarySearchPage(library: [SearchLibraryTitle(renamed)], online: [exact], page: 1, totalPages: 1)
    #expect(AnimeTitleMatching.destination(page: withNoise, names: [exact.name], year: 2025, kind: .tv) == .catalog(exact.route))
    #expect(AnimeTitleMatching.destination(page: page, names: [renamed.name], year: 2019, kind: .tv) == .saved(renamed.id))
}

@Test func voiceActorPersonMatchingUsesUniqueTmdbCastIdentity() throws {
    let data = Data(#"[{"id":700001,"name":"Rie Takahashi","character":"Voice"},{"id":700001,"name":"Takahashi Rie","character":"Another voice"}]"#.utf8)
    let cast = try JSONDecoder().decode([CastPerson].self, from: data)
    #expect(PersonIdentityMatching.uniqueID(in: cast, names: ["RIE TAKAHASHI"]) == 700001)
    #expect(PersonIdentityMatching.uniqueID(in: cast, names: ["Different Person"]) == nil)
    let other = try JSONDecoder().decode([CastPerson].self, from: Data(#"[{"id":700002,"name":"Rie Takahashi","character":"Voice"}]"#.utf8))
    #expect(PersonIdentityMatching.uniqueID(in: cast + other, names: ["Rie Takahashi"]) == nil)
    #expect(PersonIdentityMatching.sameName("Yoko Hikasa", "Youko Hikasa"))
    #expect(!PersonIdentityMatching.sameName("", ""))
}
