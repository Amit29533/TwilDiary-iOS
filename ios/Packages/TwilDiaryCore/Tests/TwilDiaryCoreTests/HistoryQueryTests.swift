import Foundation
import Testing
@testable import TwilDiaryCore

private struct WebHistoryCase: Decodable {
    struct Row: Decodable { let id: String; let rewatched: Bool }
    struct Range: Decodable { let from: String; let to: String }
    let name: String
    let workspace: Workspace
    let filters: HistoryQuery
    let timeZone: String
    let now: String
    let expected: [Row]
    let ranges: [String: Range]
}
@Test func historyAgreesWithWebOrderingLocalDatesUnknownsAndSearch() throws {
    let url = try #require(Bundle.module.url(forResource: "history-golden", withExtension: "json"))
    let cases = try JSONDecoder().decode([WebHistoryCase].self, from: Data(contentsOf: url))
    #expect(cases.count == 19)
    for item in cases {
        let zone = try #require(TimeZone(identifier: item.timeZone))
        let result = item.filters.entries(in: item.workspace, timeZone: zone)
        #expect(result.map(\.id) == item.expected.map(\.id), "\(item.name): ordered event identities")
        #expect(result.map(\.rewatched) == item.expected.map(\.rewatched), "\(item.name): rewatch evidence outside the selected range")
        for limit in [0, 1, 4] {
            let preview = item.filters.entries(in: item.workspace, timeZone: zone, limit: limit)
            #expect(preview.map(\.id) == result.prefix(limit).map(\.id), "\(item.name): limited ordering")
            #expect(preview.map(\.rewatched) == result.prefix(limit).map(\.rewatched), "\(item.name): limited rewatch evidence")
        }
        for preset in HistoryPreset.allCases {
            let expected = try #require(item.ranges[preset.rawValue])
            var query = HistoryQuery(unknownOnly: true)
            query.select(preset, now: try #require(DiaryDate.parse(item.now)), timeZone: zone)
            #expect(query.from == expected.from && query.to == expected.to && !query.unknownOnly, "\(item.name): \(preset.rawValue) local dates")
            #expect(query.selects(preset, now: try #require(DiaryDate.parse(item.now)), timeZone: zone))
        }
    }
}
@Test func recentHistoryKeepsTheFullOrderForOlderSnapshotsWithoutRecordedDates() throws {
    let url = try #require(Bundle.module.url(forResource: "history-golden", withExtension: "json"))
    let cases = try JSONDecoder().decode([WebHistoryCase].self, from: Data(contentsOf: url))
    var workspace = try #require(cases.first).workspace
    let title = try #require(workspace.activeTitles.first)
    workspace.events = (0..<12).map { index in
        WatchEvent(id: "legacy-\(index)", operationId: "watch-\(index)", titleId: title.id, episodeId: nil,
                   watchedAt: index.isMultiple(of: 3) ? nil : "2026-10-23T12:00:00Z",
                   recordedAt: index.isMultiple(of: 2) ? "" : "2026-10-22T12:00:00Z")
    }
    let history = HistoryQuery()
    let full = history.entries(in: workspace)
    let preview = history.entries(in: workspace, limit: 4)
    #expect(full.count == 12)
    #expect(preview.map(\.id) == full.prefix(4).map(\.id))
    let previewIsAllRewatched = preview.allSatisfy { $0.rewatched }
    #expect(previewIsAllRewatched)
}
@Test func historyLocalDatePickerPreservesTheDayAcrossTimeZones() throws {
    for name in ["UTC", "Asia/Kolkata", "America/New_York"] {
        let zone = try #require(TimeZone(identifier: name))
        let date = try #require(HistoryQuery.localDay("2026-03-08", timeZone: zone))
        #expect(DiaryDate.day(date, timeZone: zone) == "2026-03-08")
        #expect(HistoryQuery.localDay("2026-02-30", timeZone: zone) == nil)
    }
    #expect(HistoryQuery(from: "2026-10-24", to: "2026-10-23").invalidRange)
    #expect(!HistoryQuery(from: "2026-10-24").invalidRange)
}
