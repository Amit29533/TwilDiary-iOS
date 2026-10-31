import XCTest
import TwilDiaryCore
@testable import TwilDiary

final class HomeMediaCardsTests: XCTestCase {
    private let now = DiaryDate.parse("2026-10-23T12:00:00Z")!

    func testUpcomingKeepsTheLinkedEpisodeAndUsesTitleArtworkWithoutSpoilerStills() throws {
        let item = try XCTUnwrap(HomeOverview(workspace: PreviewData.upcomingWorkspace, now: now).upcoming.first { $0.title.id == "again" })
        let model = HomeEpisodeCardModel(upcoming: item)
        XCTAssertEqual(model.id, item.id)
        XCTAssertEqual(model.episode, "S2 · E1")
        XCTAssertEqual(model.artwork, item.title.backdrop ?? item.title.poster)
        XCTAssertEqual(model.date, item.date)
        XCTAssertEqual(model.status, "Tomorrow")
        XCTAssertTrue(model.isUpcoming)
        XCTAssertFalse(model.isRewatch)
        XCTAssertTrue(model.accessibilityLabel.contains("Tomorrow"))
    }
    func testUpcomingStatusFollowsTheOverviewLocalDayWithoutGuessingDates() throws {
        let snapshot = PreviewData.upcomingWorkspace
        let date = try XCTUnwrap(DiaryDate.parse("2026-10-24T12:00:00Z"))
        let today = try XCTUnwrap(HomeOverview(workspace: snapshot, now: date).upcoming.first { $0.title.id == "again" })
        XCTAssertEqual(HomeEpisodeCardModel(upcoming: today).status, "Today")
        let earlier = try XCTUnwrap(HomeOverview(workspace: snapshot, now: now.addingTimeInterval(-86400)).upcoming.first { $0.title.id == "again" })
        XCTAssertEqual(HomeEpisodeCardModel(upcoming: earlier).status, "In 2 days")
    }
    func testHistoryPreservesSeparateEventIdentitiesOrderAndRewatchSemantics() throws {
        let snapshot = try historyFixture(unknown: false)
        let entries = HistoryQuery().entries(in: snapshot)
        XCTAssertEqual(entries.count, 2)
        let models = entries.map(HomeEpisodeCardModel.init(history:))
        XCTAssertEqual(models.map(\.id), entries.map(\.id))
        XCTAssertNotEqual(models[0].id, models[1].id)
        XCTAssertEqual(models[0].name, models[1].name)
        XCTAssertTrue(models.allSatisfy { $0.isRewatch && !$0.isUpcoming && $0.status == "Rewatched" })
        XCTAssertTrue(models.allSatisfy { $0.accessibilityLabel.contains("Rewatched") })
        XCTAssertEqual(models[0].date, DiaryDate.parse(entries[0].event.watchedAt))
    }
    func testUnknownWatchDateStaysUnknownInsteadOfUsingRecordedAt() throws {
        let entry = try XCTUnwrap(HistoryQuery(unknownOnly: true).entries(in: historyFixture(unknown: true)).first)
        let model = HomeEpisodeCardModel(history: entry)
        XCTAssertNotNil(DiaryDate.parse(entry.event.recordedAt))
        XCTAssertNil(model.date)
        XCTAssertEqual(model.dateLabel, "Watch date unknown")
        XCTAssertTrue(model.accessibilityLabel.contains("Watch date unknown"))
    }
    private func historyFixture(unknown: Bool) throws -> Workspace {
        let snapshot = PreviewData.workspace
        let template = try XCTUnwrap(snapshot.events.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        object["events"] = (0..<2).map { index in
            var row = source
            row["id"] = "home-history-\(index)"; row["operationId"] = "home-operation-\(index)"; row["revokedAt"] = NSNull()
            row["watchedAt"] = unknown ? NSNull() : "2026-10-\(22 - index)T12:00:00Z" as Any
            return row
        }
        return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
