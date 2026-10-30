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

private func adding(_ dates: [String: String], to workspace: Workspace) throws -> Workspace {
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
    value["titles"] = (value["titles"] as! [[String: Any]]).map { title in
        var copy = title; if let date = dates[title["id"] as! String] { copy["createdAt"] = date }; return copy
    }
    return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: value))
}

@Test func recentlyAddedPutsTheNewestTitlesFirstAndUndatedOnesLastByName() throws {
    let sample = SampleWorkspace.make()
    let ids = sample.activeTitles.map(\.id)
    #expect(ids.count >= 3)
    let workspace = try adding([ids[0]: "2026-10-01T10:00:00.000Z", ids[1]: "2026-10-20T10:00:00.000Z"], to: sample)
    var value = LibraryQuery(); value.sort = .added
    let sorted = value.titles(in: workspace).map(\.id)
    #expect(Array(sorted.prefix(2)) == [ids[1], ids[0]])
    let undated = workspace.activeTitles.filter { $0.createdAt == nil }.sorted { LibraryQuery.nameBefore($0.name, $1.name) }.map(\.id)
    #expect(Array(sorted.dropFirst(2)) == undated)
}

@Test func jellyfinKeepsTitlesWithAPresentJellyfinFolderOrAMatchInTheJellyfinList() throws {
    let sample = SampleWorkspace.make()
    let ids = sample.activeTitles.map(\.id)
    #expect(ids.count >= 3)
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
    // The first title has a Jellyfin folder; the second had one Jellyfin no longer sees.
    func folder(_ id: String, _ title: String, _ evidence: String) -> [String: Any] {
        ["id": id, "titleId": title, "deviceName": "Jellyfin", "deviceId": "jellyfin", "volumeId": "jellyfin:E:", "driveLetter": "E:",
         "root": "E:\\", "relativePath": "Movies\\" + id, "fileCount": 1, "evidence": evidence]
    }
    value["locations"] = (value["locations"] as? [[String: Any]] ?? []) + [folder("j1", ids[0], "present"), folder("j2", ids[1], "missing")]
    let workspace = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: value))
    var query = LibraryQuery(); query.jellyfin = true
    #expect(query.titles(in: workspace).map(\.id) == [ids[0]])
    // Titles matched in the saved Jellyfin list count too, folder or not.
    query.jellyfinTitles = [ids[2], "no-longer-in-the-diary"]
    #expect(Set(query.titles(in: workspace).map(\.id)) == [ids[0], ids[2]])
    // Other filters still apply on top.
    query.status = "no such status"
    #expect(query.titles(in: workspace).isEmpty)
    query = LibraryQuery()
    #expect(query.titles(in: workspace).count == workspace.activeTitles.count)
}

@Test func severalGenresMatchTitlesInAnyOfThem() throws {
    let workspace = SampleWorkspace.make()
    let genre = try #require(workspace.activeTitles.flatMap(\.genres).first)
    let expected = Set(workspace.activeTitles.filter { $0.genres.contains(genre) }.map(\.id))
    // The sample has one genre: a second chosen genre that no title has adds nothing.
    var value = LibraryQuery(); value.genres = [genre, "Not a genre"]
    #expect(Set(value.titles(in: workspace).map(\.id)) == expected)
    value.genres = ["Not a genre"]
    #expect(value.titles(in: workspace).isEmpty)
    value.genres = []
    #expect(value.titles(in: workspace).count == workspace.activeTitles.count)
}
