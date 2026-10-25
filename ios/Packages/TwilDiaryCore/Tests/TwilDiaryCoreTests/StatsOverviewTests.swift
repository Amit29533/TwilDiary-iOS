import Foundation
import Testing
@testable import TwilDiaryCore

private struct WebStatsCase: Decodable {
    let name: String, workspace: Workspace, period: Period, now: String, timeZone: String, year: Int?, expected: StatsOverview
}

@Test func statsAgreeWithUnchangedWebCalculationAcrossEveryPeriodAndEdgeCase() throws {
    let url = try #require(Bundle.module.url(forResource: "stats-golden", withExtension: "json"))
    let cases = try JSONDecoder().decode([WebStatsCase].self, from: Data(contentsOf: url))
    #expect(cases.count == 17)
    for item in cases {
        let value = StatsOverview(workspace: item.workspace, period: item.period, year: item.year, now: try #require(DiaryDate.parse(item.now)), timeZone: try #require(TimeZone(identifier: item.timeZone)))
        #expect(value.coverage == item.expected.coverage, "\(item.name): date/runtime coverage")
        let actual = value.trend, expected = item.expected.trend
        #expect(actual.period == expected.period && actual.minutes == expected.minutes && actual.average == expected.average && actual.difference == expected.difference, "\(item.name): totals/average/comparison")
        #expect(actual.watches == expected.watches && actual.titles == expected.titles, "\(item.name): watch/title counts")
        #expect(actual.start == expected.start && actual.end == expected.end && actual.days == expected.days, "\(item.name): local calendar bounds")
        #expect(actual.comparison == expected.comparison && actual.previousStart == expected.previousStart && actual.previousEnd == expected.previousEnd, "\(item.name): previous-period bounds")
        #expect(actual.busiest == expected.busiest, "\(item.name): busiest day")
        #expect(actual.buckets.count == expected.buckets.count, "\(item.name): zero-filled bucket count")
        for (a, b) in zip(actual.buckets, expected.buckets) {
            #expect(a.key == b.key && a.label == b.label && a.description == b.description, "\(item.name), bucket \(a.key): label/range")
            #expect(a.minutes == b.minutes && a.events == b.events, "\(item.name), bucket \(a.key): minutes and original watches")
        }
        #expect(value.streaks == item.expected.streaks, "\(item.name): local day streaks and future heatmap cells")
        #expect(value.backlog == item.expected.backlog, "\(item.name): aired catalogue, unknown runtimes and stale titles")
        #expect(value.genres == item.expected.genres, "\(item.name): unique watched-title denominator and other-genre union")
        #expect(value.years == item.expected.years && value.selectedYear == item.expected.selectedYear)
    }
}
