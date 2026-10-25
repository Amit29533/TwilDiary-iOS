import Foundation
import Testing
@testable import TwilDiaryCore

private struct WebHomeCase: Decodable {
    struct Expected: Decodable {
        struct Week: Decodable {
            struct Day: Decodable { let date: String; let minutes: Int; let count: Int; let future: Bool }
            let minutes: Int; let watches: Int; let streak: Int; let unknownDates: Int; let missingRuntime: Int; let days: [Day]
        }
        struct Upcoming: Decodable { let title: String; let episode: String; let daysAway: Int }
        let week: Week
        let planned: [String]
        let upcoming: [Upcoming]
    }
    let name: String
    let workspace: Workspace
    let now: String
    let timeZone: String
    let expected: Expected
}
@Test func homeAgreesWithWebWeekCoveragePlannedOrderAndUpcomingRules() throws {
    let url = try #require(Bundle.module.url(forResource: "home-golden", withExtension: "json"))
    let cases = try JSONDecoder().decode([WebHomeCase].self, from: Data(contentsOf: url))
    #expect(cases.count == 9)
    for item in cases {
        let zone = try #require(TimeZone(identifier: item.timeZone))
        let actual = HomeOverview(workspace: item.workspace, now: try #require(DiaryDate.parse(item.now)), calendar: DiaryDate.calendar(timeZone: zone))
        let week = item.expected.week
        #expect(actual.minutes == week.minutes && actual.watches == week.watches && actual.streak == week.streak, "\(item.name): weekly totals/streak")
        #expect(actual.unknownDates == week.unknownDates && actual.missingRuntime == week.missingRuntime, "\(item.name): date/runtime coverage")
        #expect(actual.days.count == week.days.count)
        for (a, b) in zip(actual.days, week.days) {
            #expect(DiaryDate.day(a.date, timeZone: zone) == b.date && a.count == b.count && a.minutes == b.minutes && a.future == b.future, "\(item.name): local week cell \(b.date)")
        }
        #expect(actual.planned.map(\.id) == item.expected.planned, "\(item.name): stable source planned order")
        #expect(actual.upcoming.map { $0.title.id } == item.expected.upcoming.map(\.title), "\(item.name): upcoming title deduplication")
        #expect(actual.upcoming.map { $0.episode.id } == item.expected.upcoming.map(\.episode))
        #expect(actual.upcoming.map(\.daysAway) == item.expected.upcoming.map(\.daysAway))
    }
}
