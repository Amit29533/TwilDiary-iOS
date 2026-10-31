import XCTest
import TwilDiaryCore
@testable import TwilDiary

final class ProfileFormattingTests: XCTestCase {
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
        XCTAssertTrue(value.markdown.contains("- Game role\n- Drama role"))
        XCTAssertTrue(value.markdown.contains("Text.\nNext paragraph."))
        XCTAssertFalse(value.markdown.contains("Hidden"))
    }
    func testUnknownAndDuplicateFieldsArePreservedInProse() {
        let source = "__Height:__ 152 cm\n__Height:__ Conflicting supplied value\n__Unrecognised detail:__ Keep this.\nAgency appears in a sentence."
        let value = ProfileFormattedBiography(description: source, hideSpoilers: true)
        XCTAssertEqual(value.facts.count, 1)
        XCTAssertTrue(value.markdown.contains("Conflicting supplied value"))
        XCTAssertTrue(value.markdown.contains("Unrecognised detail"))
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
}
