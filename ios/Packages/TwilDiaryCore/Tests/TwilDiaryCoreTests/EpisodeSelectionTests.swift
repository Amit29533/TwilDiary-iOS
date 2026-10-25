import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

private func selectionEpisode(_ id: String, season: Int, number: Int, aired: String? = "2026-01-01", skipped: Bool = false) throws -> Episode {
    let body: [String: Any] = ["id": id, "titleId": "again", "season": season, "number": number, "name": id, "overview": "", "airedOn": aired as Any? ?? NSNull(), "skipped": skipped]
    return try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: body))
}

@Test func initialSeasonSkipsWatchedSkippedSpecialsAndUnairedEpisodes() throws {
    let title = try #require(SampleWorkspace.make().titles.first { $0.id == "again" })
    let episodes = try [selectionEpisode("special", season: 0, number: 1), selectionEpisode("seen", season: 1, number: 1), selectionEpisode("skip", season: 1, number: 2, skipped: true), selectionEpisode("future", season: 1, number: 3, aired: "2027-01-01"), selectionEpisode("unknown", season: 1, number: 4, aired: nil), selectionEpisode("next", season: 2, number: 1)]
    let event = try JSONDecoder().decode(WatchEvent.self, from: Data(#"{"id":"watch","operationId":"operation","titleId":"again","episodeId":"seen","watchedAt":null,"recordedAt":"2026-01-01T12:00:00Z","origin":"manual","version":1}"#.utf8))
    let workspace = Workspace(titles: [title], episodes: episodes, events: [event])
    #expect(EpisodeSelection.next(in: workspace, titleID: title.id, today: "2026-10-23")?.id == "next")
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: "2026-10-23") == 2)
    #expect(EpisodeSelection.next(in: workspace, titleID: title.id, today: "2026-10-23", season: 1) == nil)
    #expect(EpisodeSelection.next(in: workspace, titleID: title.id, today: "2026-10-23", season: 0)?.id == "special")
    #expect(EpisodeSelection.next(in: workspace, titleID: title.id, today: "invalid") == nil)
    #expect(EpisodeSelection.preferredSeason(in: Workspace(titles: [title]), titleID: title.id, today: "2026-10-23") == 1)
}

@Test func episodeWindowUsesTheNextIdentityAndDoesNotBackfillAtTheEnd() throws {
    let episodes = try (1...6).map { try selectionEpisode("e\($0)", season: 1, number: $0) }.reversed()
    let rows = Array(episodes)
    #expect(EpisodeSelection.window(rows, season: 1, nextID: "e1").map(\.number) == [1, 2, 3, 4])
    #expect(EpisodeSelection.window(rows, season: 1, nextID: "e4").map(\.number) == [3, 4, 5, 6])
    #expect(EpisodeSelection.window(rows, season: 1, nextID: "e6").map(\.number) == [5, 6])
    #expect(EpisodeSelection.window(rows, season: 1, nextID: nil).map(\.number) == [3, 4, 5, 6])
    #expect(EpisodeSelection.window(rows, season: 1, all: true, nextID: "e6").count == 6)
}

@Test func linkedSeasonUsesOnlyThisTitlesManifestOrEpisodesBeforeTheNextUnwatchedSeason() throws {
    let title = try #require(SampleWorkspace.make().titles.first { $0.id == "again" })
    let regular = try selectionEpisode("next-regular", season: 1, number: 1)
    let future = try selectionEpisode("later-season", season: 2, number: 1, aired: "2027-01-01")
    let special = try selectionEpisode("special", season: 0, number: 1)
    let workspace = Workspace(titles: [title], episodes: [regular, future, special])
    #expect(EpisodeSelection.seasons(in: workspace, titleID: title.id) == [0, 1, 2])
    #expect(EpisodeSelection.seasons(in: workspace, titleID: "another-title").isEmpty)
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: "2026-10-23") == 1)
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: "2026-10-23", linkedSeason: 2) == 2)
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: "2026-10-23", linkedSeason: 0) == 0)
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: "2026-10-23", linkedSeason: -1) == 1)
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: "2026-10-23", linkedSeason: 999) == 1)
    #expect(EpisodeSelection.preferredSeason(in: workspace, titleID: "another-title", today: "2026-10-23", linkedSeason: 2) == 1)
}
