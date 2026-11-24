import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Studio's orderings for a person's credits, and the bio clean-up every theme gets.
final class StudioPeopleTests: XCTestCase {
    private func credit(_ id: Int, _ name: String, tv: Bool = true, year: Int? = 2020, votes: Int, episodes: Int? = nil, character: String = "Role") -> CatalogItem {
        CatalogItem(id: id, mediaType: tv ? .tv : .movie, name: name, year: year, votes: votes, character: character, popularity: 50, episodeCount: episodes)
    }

    func testKnownForPutsLeadRolesAboveGuestSpotsOnBigShows() {
        let guest = credit(1, "Law & Order: SVU", votes: 4_000, episodes: 1)
        let arc = credit(2, "The Mentalist", votes: 4_000, episodes: 9)
        let lead = credit(3, "The Last of Us", votes: 6_000, episodes: 18)
        let talk = credit(4, "Faut Voir", votes: 90_000, episodes: 1, character: "Self - Guest")
        let film = credit(5, "The Wild Robot", tv: false, votes: 5_000)
        let ranked = StudioPeople.rankKnownFor([guest, arc, talk, lead, film]).map(\.name)
        XCTAssertEqual(ranked, ["The Last of Us", "The Wild Robot", "The Mentalist", "Law & Order: SVU"])
        // A show credit with no episode count weighs as a single episode, not a lead role.
        XCTAssertLessThan(StudioPeople.prominence(credit(6, "Old show", votes: 4_000)), StudioPeople.prominence(arc))
    }

    func testReleasedWorkComesBeforeSelfAppearancesAndUnreleasedTitles() {
        let items = [
            credit(1, "Secret Wars", tv: false, year: 2027, votes: 0),
            credit(2, "Halftime Show", tv: false, year: 2026, votes: 10, character: "Self"),
            credit(3, "Doomsday", tv: false, year: 2026, votes: 0),
            credit(4, "Gladiator II", tv: false, year: 2024, votes: 3_000),
            credit(5, "No year", tv: false, year: nil, votes: 0)
        ]
        XCTAssertEqual(StudioPeople.releasedFirst(items, currentYear: 2026).map(\.name), ["Doomsday", "Gladiator II", "Halftime Show", "Secret Wars", "No year"])
    }

    func testBiosLoseWikipediaPronunciationButKeepFootnotesAndLinks() {
        let bio = "José Pedro Balmaceda Pascal (Spanish: [xo ˈse ˈpeðɾo βalmaˈseða pasˈkal]; born April 2, 1975) is a Chilean and American actor."
        XCTAssertEqual(ProfileText.withoutSourceCredit(bio).text, "José Pedro Balmaceda Pascal (born April 2, 1975) is a Chilean and American actor.")
        XCTAssertEqual(ProfileText.withoutPronunciation("An actor.[1] Known for [Frieren](https://anilist.co/anime/1)."), "An actor.[1] Known for [Frieren](https://anilist.co/anime/1).")
        XCTAssertEqual(ProfileText.withoutPronunciation("Voiced by [宮間 かれん](https://example.org)."), "Voiced by [宮間 かれん](https://example.org).")
    }

    @MainActor func testCompanyInitialsSkipGenericWords() {
        XCTAssertEqual(CompanyLogo.initials("Bill/Phillips Productions"), "BP")
        XCTAssertEqual(CompanyLogo.initials("Columbia Pictures"), "C")
        XCTAssertEqual(CompanyLogo.initials("Studio"), "S")
    }

    @MainActor func testEpisodeTrackSharesLongSeasonsOutOverSixteenCapsules() {
        // Short seasons: a capsule per episode; longer ones: a few episodes to a capsule, never more than 16.
        XCTAssertEqual(StudioEpisodeTrack.perCapsule(12), 1); XCTAssertEqual(StudioEpisodeTrack.perCapsule(16), 1)
        XCTAssertEqual(StudioEpisodeTrack.perCapsule(24), 2); XCTAssertEqual(StudioEpisodeTrack.perCapsule(50), 4)
        XCTAssertTrue(StudioEpisodeTrack.fits(1)); XCTAssertTrue(StudioEpisodeTrack.fits(1_000)); XCTAssertFalse(StudioEpisodeTrack.fits(0))
        // 3 of 24 watched: the first capsule full, the second half, the third empty.
        XCTAssertEqual(StudioEpisodeTrack.fill(0, watched: 3, total: 24), 1)
        XCTAssertEqual(StudioEpisodeTrack.fill(1, watched: 3, total: 24), 0.5)
        XCTAssertEqual(StudioEpisodeTrack.fill(2, watched: 3, total: 24), 0)
        // A short last capsule (episodes 49–50 of 50) fills by its own two episodes.
        XCTAssertEqual(StudioEpisodeTrack.fill(12, watched: 49, total: 50), 0.5)
    }

    func testSentenceCase() {
        XCTAssertEqual(Studio.sentenceCase("LAST WATCHED"), "Last watched")
        XCTAssertEqual(Studio.sentenceCase(""), "")
    }
}
