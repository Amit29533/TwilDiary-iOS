import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func savedSeasonPreparationHonorsSixHourBoundaryVersionAndLoadedCount() throws {
    let workspace = SampleWorkspace.make(), original = try #require(workspace.titles.first)
    let now = try #require(DiaryDate.parse("2026-10-23T12:00:00Z"))
    let count = workspace.episodes.filter { $0.titleId == original.id && $0.season == 1 }.count
    func title(age: Double = 0, version: Int = 2, linked: Bool = true) throws -> MediaTitle {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["category"] = "show"
        if linked { object["tmdbId"] = 42 } else { object["tmdbId"] = NSNull() }
        object["seasons"] = [["number": 1, "name": "Season 1", "expectedEpisodes": count, "metadataLoadedAt": now.addingTimeInterval(-age).ISO8601Format(), "metadataVersion": version]]
        return try JSONDecoder().decode(MediaTitle.self, from: JSONSerialization.data(withJSONObject: object))
    }
    #expect(try !SeasonMetadata.needsPreparation(title: title(age: 21599), workspace: workspace, season: 1, now: now))
    #expect(try SeasonMetadata.needsPreparation(title: title(age: 21600), workspace: workspace, season: 1, now: now))
    #expect(try SeasonMetadata.needsPreparation(title: title(version: 1), workspace: workspace, season: 1, now: now))
    #expect(try !SeasonMetadata.needsPreparation(title: title(age: 90000, linked: false), workspace: workspace, season: 1, now: now))
    var partial = workspace; partial.episodes = []
    #expect(try SeasonMetadata.needsPreparation(title: title(), workspace: partial, season: 1, now: now))
    #expect(try !SeasonMetadata.needsPreparation(title: title(), workspace: partial, season: 99, now: now))
}
