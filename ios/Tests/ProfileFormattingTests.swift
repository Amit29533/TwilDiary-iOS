import XCTest
import SwiftUI
import UIKit
import TwilDiaryCore
@testable import TwilDiary

final class ProfileFormattingTests: XCTestCase {
    @MainActor func testCompactFactsFitPhoneWidthsAndGrowForAccessibleText() {
        let facts = [
            ProfileFact(id: "born", icon: "calendar", label: "Born", value: "22 Feb 1996"),
            ProfileFact(id: "age", icon: "person", label: "Age", value: "30"),
            ProfileFact(id: "career", icon: "briefcase", label: "Active since", value: "2012"),
            ProfileFact(id: "favourites", icon: "heart", label: "Favourites", value: "5"),
            ProfileFact(id: "place", icon: "mappin", label: "Birthplace", value: "New Britain, Connecticut, USA", wide: true)
        ].compactMap { $0 }
        for width in [CGFloat(292), 334, 362, 402] {
            let normal = UIHostingController(rootView: ProfileFacts(items: facts).environment(\.dynamicTypeSize, .large))
            let large = UIHostingController(rootView: ProfileFacts(items: facts).environment(\.dynamicTypeSize, .accessibility5))
            let proposal = CGSize(width: width, height: 2000)
            let compact = normal.sizeThatFits(in: proposal)
            let accessible = large.sizeThatFits(in: proposal)
            XCTAssertLessThanOrEqual(compact.width, width + 1)
            XCTAssertLessThan(compact.height, 200, "Five everyday facts should not become a stack of oversized cards")
            XCTAssertGreaterThan(accessible.height, compact.height, "Large text must expand naturally instead of shrinking or clipping")
            XCTAssertLessThanOrEqual(accessible.width, width + 1)
        }
    }
    func testAbsentFactsAreOmittedWithoutChangingFreeformValues() throws {
        XCTAssertNil(ProfileFact(id: "missing", icon: "calendar", label: "Born", value: nil))
        XCTAssertNil(ProfileFact(id: "blank", icon: "mappin", label: "Hometown", value: " \n "))
        let age = try XCTUnwrap(ProfileFact(id: "age", icon: "person", label: "Age", value: "17 (physically)"))
        XCTAssertEqual(age.value, "17 (physically)")
    }
    @MainActor func testNarrowPosterRatingKeepsOneLineAndSourceDoesNotChangeItsSize() {
        for score in [6.8, 8.1, 10.0] {
            let standard = UIHostingController(rootView: RatingBadge(score: score))
            let sourced = UIHostingController(rootView: RatingBadge(score: score, source: "AniList")
                .environment(\.dynamicTypeSize, .accessibility5))
            let proposal = CGSize(width: 44, height: 100)
            let expected = standard.sizeThatFits(in: proposal)
            let actual = sourced.sizeThatFits(in: proposal)
            XCTAssertLessThan(actual.height, 30, "A poster score must never stack digits vertically")
            XCTAssertLessThan(actual.width, 60, "Use the existing compact badge rather than a provider panel")
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
        }
    }
    func testAuditedMatrixCoversAllThreeProfileTypesAndBothProviders() {
        let samples = ProfileFormattingPreview.samples
        XCTAssertEqual(samples.count, 22)
        XCTAssertEqual(samples.filter { $0.kind == "character" }.count, 8)
        XCTAssertEqual(samples.filter { $0.kind == "voice" }.count, 6)
        XCTAssertEqual(samples.filter { $0.kind == "cast" }.count, 8)
        for sample in samples {
            let value = ProfileFormattedBiography(description: sample.description, hideSpoilers: true)
            XCTAssertFalse(value.markdown.contains("Hidden spoiler detail"), sample.name)
            XCTAssertFalse(value.links.contains { ProfileDeepLink.parse($0.url) != nil }, sample.name)
            XCTAssertEqual(Set(value.facts.map(\.id)).count, value.facts.count)
            for fact in value.facts { XCTAssertNotNil(ProfileText.line(fact.markdown)) }
        }
    }
    func testFictionalAgesAndPartialBirthdaysAreNotTurnedIntoRealWorldAges() throws {
        for (id, expected) in [(70069, "17 (physically)"), (176754, "1000+"), (138100, "6 (self asserted)"), (90169, "14-18"), (12, "14-15")] {
            let character = try XCTUnwrap(ProfileFormattingPreview.character(id))
            XCTAssertEqual(character.age, expected)
        }
        XCTAssertEqual(ProfileFormattingPreview.character(12)?.birthday, "1900")
        XCTAssertNil(ProfileFormattingPreview.character(176754)?.birthday)
        XCTAssertEqual(ProfileFormattingPreview.character(70069)?.birthday, "10 June")
        let today = try XCTUnwrap(DiaryDate.parse("2026-10-31T12:00:00Z"))
        for partial in ["1900", "10 June", "June 1994", "June"] { XCTAssertNil(ProfileDate.age(birthday: partial, until: today)) }
    }
    func testPartialDatePrecisionAndLeapDaysArePreserved() {
        XCTAssertEqual(ProfileDate.partial(year: 1900, month: nil, day: nil), "1900")
        XCTAssertEqual(ProfileDate.partial(year: nil, month: nil, day: 24), "Day 24 (month unknown)")
        XCTAssertEqual(ProfileDate.partial(year: nil, month: 2, day: 29), "29 February")
        XCTAssertEqual(ProfileDate.partial(year: 2000, month: 6, day: nil), "June 2000")
        XCTAssertEqual(ProfileDate.partial(year: nil, month: 6, day: nil), "June")
        XCTAssertNil(ProfileDate.partial(year: nil, month: nil, day: nil))
        XCTAssertNil(ProfileDate.partial(year: 1991, month: 2, day: 29))
        XCTAssertEqual(ProfileDate.short("1900"), "1900")
        XCTAssertEqual(ProfileDate.short("June 2000"), "Jun 2000")
        XCTAssertEqual(ProfileDate.short("June"), "Jun")
    }
    func testHumanAgeStopsAtDeathAndRejectsFutureOrInvalidBirthdates() throws {
        let death = try XCTUnwrap(DiaryDate.parse("2020-08-28T00:00:00Z"))
        XCTAssertEqual(ProfileDate.age(birthday: "1976-11-29", until: death), 43)
        XCTAssertNil(ProfileDate.age(birthday: "2021-01-01", until: death))
        XCTAssertNil(ProfileDate.age(birthday: "1991-02-29", until: death))
    }
    func testMetadataUsesExplicitLabelsAnywhereAndRetainsInlineRelationships() {
        let source = "Public paragraph.\n\n__Height:__ 152 cm\n**Agency:** [Studio](https://example.org/studio)\n__Family:__ [Fern](https://anilist.co/character/2) (friend)\n\nMore prose."
        let value = ProfileFormattedBiography(description: source, hideSpoilers: true)
        XCTAssertEqual(value.facts.map(\.id), ["height", "agency", "family"])
        XCTAssertTrue(value.facts.last!.markdown.contains("https://anilist.co/character/2"))
        XCTAssertEqual(value.markdown, "Public paragraph.\n\nMore prose.")
        XCTAssertTrue(value.links.isEmpty)
    }
    func testWebsiteIconsAndNativeTextReferencesCannotBeMixed() {
        let source = "[Website](https://example.org) | [Fern](https://anilist.co/character/2) | [Frieren](https://anilist.co/anime/154587)\n\nMember of [Blue Drops](https://anilist.co/staff/106305)."
        let value = ProfileFormattedBiography(description: source, hideSpoilers: true)
        XCTAssertEqual(value.links.map(\.id), ["https://example.org"])
        XCTAssertEqual(value.references.map(\.title), ["Fern", "Frieren"])
        XCTAssertTrue(value.markdown.contains("[Blue Drops]"))
        XCTAssertFalse(value.markdown.contains("[Website]"))
    }
    func testHiddenMetadataAndMultilineListsDoNotLeakOrLoseFormatting() {
        let source = "__Height:__ 152 cm\n\n~!__Agency:__ Hidden Agency\n[Hidden site](https://example.org/hidden)!~\n\n**Non-Anime Roles:**\n- Game role\n- Drama role\n\nText.<BR />Next paragraph."
        let value = ProfileFormattedBiography(description: source, hideSpoilers: true)
        XCTAssertEqual(value.facts.map(\.id), ["height"])
        XCTAssertTrue(value.links.isEmpty)
        // A bulleted list under its own heading becomes a section of its own, out of the prose.
        XCTAssertEqual(value.sections.map(\.title), ["Non-Anime Roles"])
        XCTAssertEqual(value.sections.first?.items, ["Game role", "Drama role"])
        XCTAssertFalse(value.markdown.contains("Game role"))
        XCTAssertTrue(value.markdown.contains("Text.\nNext paragraph."))
        XCTAssertFalse(value.markdown.contains("Hidden"))
    }
    func testAnyLabelledFieldIsPickedOutAndGroupedByKind() {
        let source = "__Height:__ 99.5 cm\n__Occupation:__ First-Grade Student, Test Subject (Formerly)\n__Affiliation:__ Eden Academy, Unknown Organization (Formerly)\n__Relatives:__ [Loid Forger](https://anilist.co/character/138101) (Adoptive Father), [Yor Forger](https://anilist.co/character/138102) (Adoptive Mother)\n__Cursed Technique:__ Six Eyes, Limitless\n__Devil Fruit:__ Gomu Gomu no Mi\n__Bounty:__ 3,000,000,000 Berries\n__Hobbies:__ Traveling alone, sky watching\n__Favorite Food:__ Peanuts\n__Note:__ not a field\n\nProse."
        let value = ProfileFormattedBiography(description: source, hideSpoilers: true)
        let kinds = Dictionary(uniqueKeysWithValues: value.facts.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds["occupation"], .role)
        XCTAssertEqual(kinds["affiliation"], .affiliation)
        XCTAssertEqual(kinds["relatives"], .relations)
        XCTAssertEqual(kinds["cursed-technique"], .powers)
        XCTAssertEqual(kinds["devil-fruit"], .powers)
        XCTAssertEqual(kinds["bounty"], .role)
        XCTAssertEqual(kinds["hobbies"], .interests)
        XCTAssertEqual(kinds["favorite-food"], .interests)
        XCTAssertNil(kinds["note"])
        // Lists split on commas outside brackets and links; a number with commas stays whole.
        XCTAssertEqual(value.facts.first { $0.id == "affiliation" }?.items, ["Eden Academy", "Unknown Organization (Formerly)"])
        XCTAssertEqual(value.facts.first { $0.id == "relatives" }?.items.count, 2)
        XCTAssertEqual(value.facts.first { $0.id == "bounty" }?.items.count, 1)
        // AniList's HTML links count only their visible names.
        let html = ProfileFormattedBiography(description: "__Relatives:__ <a href=\"https://anilist.co/character/138101/Loid-Forger\">Loid Forger</a> (Adoptive Father), <a href=\"https://anilist.co/character/138102/Yor-Forger\">Yor Forger</a> (Adoptive Mother)", hideSpoilers: true)
        XCTAssertEqual(html.facts.first?.items.count, 2)
    }
    func testAwardsAreFoundInTMDBBiographies() {
        let text = "He won an Academy Award and two Golden Globe Awards, and was nominated for a Primetime Emmy."
        XCTAssertEqual(ProfileFormattedBiography.awards(in: text), ["Academy Award", "Golden Globe", "Emmy"])
        XCTAssertTrue(ProfileFormattedBiography.awards(in: "An actor from Seoul.").isEmpty)
    }
    func testSpoilerOnlyRoleListsDoNotLeaveAnEmptyHeading() {
        let value = ProfileFormattedBiography(description: "Public.\n\n**Non-Anime Roles:**\n~!- Hidden role.!~", hideSpoilers: true)
        XCTAssertEqual(value.markdown, "Public.")
        let visible = ProfileFormattedBiography(description: "Public.\n\n**Non-Anime Roles:**\n- Visible role.", hideSpoilers: true)
        // A visible list becomes its own section (heading and items), not prose.
        XCTAssertEqual(visible.sections.first?.title, "Non-Anime Roles")
        XCTAssertEqual(visible.sections.first?.items, ["Visible role."])
        let ending = ProfileFormattedBiography(description: "Public.\n\n**Important words**", hideSpoilers: true)
        XCTAssertTrue(ending.markdown.contains("Important words"))
    }
    func testUnknownAndDuplicateFieldsArePreservedInProse() {
        let source = "__Height:__ 152 cm\n__Height:__ Conflicting supplied value\n__Unrecognised detail:__ Keep this.\nAgency appears in a sentence."
        let value = ProfileFormattedBiography(description: source, hideSpoilers: true)
        // Any labelled field is picked out (an unknown one goes under More details); a duplicate
        // label stays in the prose so nothing supplied is lost.
        XCTAssertEqual(value.facts.map(\.id), ["height", "unrecognised-detail"])
        XCTAssertEqual(value.facts.last?.kind, .other)
        XCTAssertTrue(value.markdown.contains("Conflicting supplied value"))
        XCTAssertTrue(value.markdown.contains("Agency appears"))
    }
    func testAliasesCountsAndCareerUseConsistentTextWithoutGuessing() {
        XCTAssertEqual(ProfileText.aliases([" Asami   Seto ", "瀬戸麻沙美", "Seto Asami", "seto asami", "Сето, Асамі"], excluding: ["Asami Seto", "瀬戸麻沙美"]), ["Seto Asami", "Сето, Асамі"])
        XCTAssertEqual(ProfileText.watched(15, anime: true), "15 anime watched")
        XCTAssertEqual(ProfileText.watched(1, anime: false), "1 title watched")
        XCTAssertNil(ProfileText.watched(-1, anime: true))
        XCTAssertEqual(ProfileText.favourites(1), "1 favourite on AniList")
        XCTAssertNil(ProfileText.favourites(nil))
        XCTAssertEqual(ProfileText.career([2008]), "Active since 2008")
        XCTAssertEqual(ProfileText.career([2008, 2020]), "Active 2008–2020")
        XCTAssertNil(ProfileText.career([]))
    }
    /// Bios end with the same credit lines everywhere; they become a short source, not prose.
    func testCommonCreditLinesBecomeASourceNote() {
        let tmdb = ProfileText.withoutSourceCredit("Kana Hanazawa is a Japanese voice actress.\n\nDescription above from the Wikipedia article Kana Hanazawa, licensed under CC-BY-SA, full list of contributors on Wikipedia.")
        XCTAssertEqual(tmdb.text, "Kana Hanazawa is a Japanese voice actress.")
        XCTAssertEqual(tmdb.source, "Wikipedia")
        let anilist = ProfileText.withoutSourceCredit("A strange 2nd year student.\n\n(Source: Crunchyroll)")
        XCTAssertEqual(anilist.text, "A strange 2nd year student.")
        XCTAssertEqual(anilist.source, "Crunchyroll")
        let sentence = ProfileText.withoutSourceCredit("Her main source: books")
        XCTAssertEqual(sentence.text, "Her main source: books", "A sentence that mentions a source is prose")
        XCTAssertNil(sentence.source)
        let formatted = ProfileFormattedBiography(description: "Public paragraph.\n\n[Written by MAL Rewrite]", hideSpoilers: true)
        XCTAssertEqual(formatted.markdown, "Public paragraph.")
        XCTAssertEqual(formatted.source, "MAL Rewrite")
    }
    func testProfileStatsUseCompactValuesWithSeparateCareerLabels() {
        XCTAssertEqual(ProfileText.favouritesValue(10_676), 10_676.formatted())
        XCTAssertNil(ProfileText.favouritesValue(nil))
        XCTAssertEqual(ProfileText.careerValue([2008]), "2008")
        XCTAssertEqual(ProfileText.careerLabel([2008]), "Active since")
        XCTAssertEqual(ProfileText.careerValue([2008, 2020]), "2008–2020")
        XCTAssertEqual(ProfileText.careerLabel([2008, 2020]), "Active years")
        XCTAssertEqual(ProfileText.careerValue([0, 2008, 10000]), "2008")
        XCTAssertEqual(ProfileText.careerLabel([0, 2008, 10000]), "Active since")
        XCTAssertEqual(ProfileText.careerValue([2008, 2012, 2020]), "2008, 2012, 2020")
        XCTAssertEqual(ProfileText.careerValue([2020, 2008]), "2020, 2008", "Do not invent a valid career range from reversed source data")
        XCTAssertNil(ProfileText.careerValue([]))
        XCTAssertNil(ProfileText.careerValue([0, -1, 10000]))
    }
}
