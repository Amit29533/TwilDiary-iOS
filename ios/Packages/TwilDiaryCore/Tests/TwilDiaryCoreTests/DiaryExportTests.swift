import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func diaryExportRoundTripsTheWholeArchiveWithoutCredentials() throws {
    let workspace = SampleWorkspace.make(), data = try DiaryExport(workspace: SampleWorkspace.make()).encoded()
    let archive = try JSONDecoder().decode(DiaryExport.self, from: data)
    #expect(archive.schemaVersion == 1)
    #expect(archive.titles == workspace.titles)
    #expect(archive.events.map(\.id) == workspace.events.map(\.id))
    #expect(archive.episodes == workspace.episodes)
    #expect(archive.locations == workspace.locations)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["schemaVersion", "titles", "episodes", "events", "locations", "skippedEpisodeIds"])
    #expect(!String(decoding: data, as: UTF8.self).contains("CF_Authorization"))
}

@Test func diaryExportFillsAbsentFieldsWithoutOverwritingCurrentRatingsOrStatus() throws {
    let base = SampleWorkspace.make()
    let modified = base.applying(.patchTitle(
        titleId: "again",
        expectedVersion: 1,
        status: "watching",
        score: 9.5,
        clearScore: false,
        favorite: true,
        queued: nil,
        notes: "Merged from second device"
    ))
    let exportedData = try DiaryExport(workspace: modified).encoded()
    let decodedArchive = try DiaryExport.decoded(from: exportedData)
    let merged = try decodedArchive.merged(into: base)
    let mergedTitle = try #require(merged.titles.first { $0.id == "again" })
    #expect(mergedTitle.score == base.titles.first { $0.id == "again" }?.score)
    #expect(mergedTitle.status == base.titles.first { $0.id == "again" }?.status)
    #expect(try decodedArchive.merged(into: merged).titles == merged.titles)
    #expect(mergedTitle.favorite == true)
    #expect(mergedTitle.notes == "Merged from second device")
}
