import Foundation
import Testing
@testable import TwilDiaryCore

private func note(_ tmdb: Int, _ text: String, movie: Bool = true, name: String = "Title") -> TraktNote {
    TraktNote(id: Int64(tmdb), title: TraktTitleRef(kind: movie ? .movie : .show, traktId: nil, tmdbId: tmdb, name: name), text: text, updatedAt: nil)
}

@Test func simklNotesGoOnlyWhereTraktHasNone() {
    let simkl = [note(1, "Old 2020 note"), note(2, "Same as Trakt"), note(3, "Simkl's words", name: "Heat"), note(4, "  "), note(5, "A show note", movie: false)]
    let trakt = [note(2, "Same as Trakt"), note(3, "Written on Trakt"), note(5, "Not this one: a movie with the same id")]
    let plan = NoteCopyPlan.make(from: simkl, to: trakt)
    #expect(plan.send.map { $0.title?.diaryKey } == ["movie:1", "tv:5"], "a movie and a show with the same TMDB id are different titles")
    #expect(plan.alreadyThere == 1)
    #expect(plan.keptThere == ["Heat"], "a different note on Trakt is never replaced")
    #expect(plan.cut == 0)
}

@Test func aLongSimklNoteCountsAsThereWhenTraktKeepsItsFirst500Characters() {
    let long = String(repeating: "a", count: 520)
    #expect(NoteCopyPlan.make(from: [note(1, long)], to: [note(1, String(long.prefix(500)))]).alreadyThere == 1, "copied before, then cut by Trakt")
    let plan = NoteCopyPlan.make(from: [note(1, long)], to: [])
    #expect(plan.send.first?.text == long, "sent whole; Trakt cuts it and the phone keeps the rest")
    #expect(plan.cut == 1)
}

@Test func eachTitleIsCopiedOnce() {
    let plan = NoteCopyPlan.make(from: [note(1, "first"), note(1, "second")], to: [])
    #expect(plan.send.map(\.text) == ["first"])
    #expect(NoteCopyPlan.make(from: [], to: [note(1, "x")]) == NoteCopyPlan())
}
