import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func randomPickExcludesTrashAndDoesNotImmediatelyRepeat() throws {
    let titles = SampleWorkspace.make().titles
    let active = titles.filter { $0.deletedAt == nil }
    let first = try #require(active.first)
    #expect(RandomPick.choose([]) == nil)
    #expect(RandomPick.choose(titles.filter { $0.deletedAt != nil }) == nil)
    #expect(RandomPick.choose([first], previousID: first.id)?.id == first.id)
    for sample in [0, 0.25, 0.5, 0.75, 0.9999, 1, .nan, -.infinity, .infinity, -1, 1e308] {
        let picked = try #require(RandomPick.choose(titles, previousID: first.id, sample: sample))
        #expect(picked.id != first.id); #expect(picked.deletedAt == nil)
    }
    #expect(RandomPick.choose(titles, sample: 0)?.id == active.first?.id)
    #expect(RandomPick.choose(titles, sample: 0.99999)?.id == active.last?.id)
}

@Test func rapidLogoTapUsesOneBoundedGestureAndResets() {
    var result = RandomPick.tap(previous: [], now: 1)
    #expect(!result.triggered)
    result = RandomPick.tap(previous: result.taps, now: 1.2)
    #expect(!result.triggered)
    result = RandomPick.tap(previous: result.taps, now: 1.7)
    #expect(result.triggered); #expect(result.taps.isEmpty)
    #expect(!RandomPick.tap(previous: result.taps, now: 1.8).triggered)
    var taps: [Double] = []
    for instant in [1.0, 2.0, 3.0, 4.5] {
        let slow = RandomPick.tap(previous: taps, now: instant)
        #expect(!slow.triggered); taps = slow.taps
    }
    #expect(RandomPick.tap(previous: [0, 0.4], now: 0.85).triggered)
    #expect(!RandomPick.tap(previous: [0, 0.4], now: 0.851).triggered)
    #expect(RandomPick.tap(previous: [10, 20], now: 1).taps == [1])
}
