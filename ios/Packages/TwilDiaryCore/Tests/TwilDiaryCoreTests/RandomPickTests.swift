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

