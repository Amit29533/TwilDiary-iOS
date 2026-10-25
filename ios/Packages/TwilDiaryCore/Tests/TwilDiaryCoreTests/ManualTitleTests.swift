import Foundation
import Testing
@testable import TwilDiaryCore

@Test func manualTitleNormalizesNamesAndMatchesReleaseYearBounds() throws {
    var draft = ManualTitleDraft(); draft.name = "  Ｓｔｏｒｙ  "; draft.year = "1800"; draft.status = "watching"; draft.score = "7.5"
    let input = try draft.validated(id: "manual-reference")
    #expect(input.name == "Story"); #expect(input.year == 1800); #expect(input.score == 7.5); #expect(input.status == "watching")
    for year in ["1799", "2201", "+2020", "2020 ", "２０２０", "bad"] {
        draft.year = year
        #expect(throws: ManualTitleError.self) { try draft.validated(id: "manual-reference") }
    }
    draft.year = "2200"; #expect(try draft.validated(id: "manual-reference").year == 2200)
}
@Test func manualTitleRejectsControlsOversizeNamesAndInvalidScores() throws {
    var draft = ManualTitleDraft()
    for name in ["", "  ", "bad\nname", String(repeating: "😀", count: 151)] {
        draft.name = name; #expect(throws: ManualTitleError.self) { try draft.validated(id: "manual-reference") }
    }
    draft.name = String(repeating: "😀", count: 150)
    #expect(try draft.validated(id: "manual-reference").name.utf16.count == 300)
    for score in ["nan", "inf", "0", "10.1", "bad"] {
        draft.score = score; #expect(throws: ManualTitleError.self) { try draft.validated(id: "manual-reference") }
    }
}
@Test func manualCompletedCreationDefersHistoryToExistingProgressTransaction() throws {
    var draft = ManualTitleDraft(); draft.name = "Story"; draft.status = "completed"
    let value = try draft.validated(id: "manual-reference")
    #expect(value.status == "planned")
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    #expect(object["score"] is NSNull); #expect(object["year"] is NSNull)
    #expect(Set(object.keys) == ["id", "name", "category", "year", "status", "score"])
}
