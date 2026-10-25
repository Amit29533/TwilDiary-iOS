import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func episodePiecesPreserveGapsAndUnloadedSlots() throws {
    let workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first)
    let episodes = workspace.episodes.filter { $0.titleId == title.id && $0.season == 1 }.sorted { $0.number < $1.number }
    #expect(episodes.count == 4)
    let segments = EpisodeSegment.make(episodes: Array(episodes.reversed()), total: 6,
                                       watched: [episodes[0].id, episodes[2].id], nextID: episodes[1].id)
    #expect(segments == [.watched, .next, .watched, .unwatched, .unwatched, .unwatched])
    #expect(EpisodeSegment.make(episodes: episodes, total: 0, watched: [], nextID: nil).isEmpty)
    #expect(EpisodeSegment.make(episodes: [], total: -1, watched: [], nextID: nil).isEmpty)
}

@Test func watchedPieceTakesPrecedenceOverStaleNextHint() throws {
    let episodes = SampleWorkspace.make().episodes
    let episode = try #require(episodes.first)
    #expect(EpisodeSegment.make(episodes: [episode], total: 1, watched: [episode.id], nextID: episode.id) == [.watched])
}
