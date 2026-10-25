import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func libraryFiltersComposeWithoutTurningQueueIntoWatchStatus() throws {
    let workspace = SampleWorkspace.make()
    let title = try #require(workspace.activeTitles.first)
    var value = LibraryQuery(); value.query = "  " + title.name.uppercased() + "  "
    #expect(value.titles(in: workspace).map(\.id) == [title.id])
    value.queued = true
    #expect(value.titles(in: workspace).isEmpty == (title.queued != true))
    value.queued = false; value.status = "planned"
    #expect(value.titles(in: workspace).isEmpty == (title.status != "planned"))
    value.status = "all"; value.favorites = true
    #expect(value.titles(in: workspace).isEmpty == !title.favorite)
    value.favorites = false; value.disk = "unmapped"
    #expect(value.titles(in: workspace).isEmpty == workspace.locations.contains { $0.titleId == title.id })
    value.disk = "all"; value.availability = "present"
    #expect(value.titles(in: workspace).isEmpty == !workspace.locations.contains { $0.titleId == title.id && $0.evidence == "present" })
}

@Test func librarySortingUsesOnlyTheChosenPublicRatingAndShelvesDoNotDuplicateTitles() throws {
    let workspace = SampleWorkspace.make()
    var value = LibraryQuery(); value.sort = .score
    let first = try #require(workspace.activeTitles.first)
    let sorted = value.titles(in: workspace, ratingFor: { $0.id == first.id ? 10 : nil })
    #expect(sorted.first?.id == first.id)
    #expect(sorted.count == workspace.activeTitles.count)
    let shelves = LibraryShelf.make(workspace.activeTitles)
    for shelf in shelves { #expect(Set(shelf.titles.map(\.id)).count == shelf.titles.count) }
    value.archived = true
    #expect(value.titles(in: workspace).isEmpty)
}
