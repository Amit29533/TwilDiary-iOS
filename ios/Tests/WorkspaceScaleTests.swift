import XCTest
import TwilDiaryCore
import TwilDiaryTestSupport
@testable import TwilDiary

@MainActor final class WorkspaceScaleTests: XCTestCase {
    func testEpisodeIndexesKeepNumericOrderAndDropRemovedWatchesAfterSnapshotReplacement() throws {
        var snapshot = SampleWorkspace.make()
        let episode = try XCTUnwrap(snapshot.episodes.first)
        snapshot.episodes.reverse()
        let store = DiaryStore(); store.workspace = snapshot
        let rows = store.episodesForSeason(episode.titleId, season: episode.season)
        XCTAssertEqual(rows.map(\.number), rows.map(\.number).sorted())
        XCTAssertEqual(store.watchedEpisodeIDs(episode.titleId), Set(snapshot.activeEvents.filter { $0.titleId == episode.titleId }.compactMap(\.episodeId)))
        snapshot.events = []; store.workspace = snapshot
        XCTAssertTrue(store.watchedEpisodeIDs(episode.titleId).isEmpty)
        XCTAssertTrue(store.episodesForSeason("missing", season:1).isEmpty)
    }
}
