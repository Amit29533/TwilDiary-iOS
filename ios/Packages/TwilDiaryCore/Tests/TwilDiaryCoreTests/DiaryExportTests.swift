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
