import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func providerDeliveryDoesNotAcknowledgeMissingMappingsOrUnknownReceipts() throws {
    let queue = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: .patchTitle(titleId: "missing", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil), pendingProviders: [.trakt])
    for provider in [SyncProviderKind.trakt, .simkl, .wetrakr, .mdblist] {
        let plan = ProviderDeliveryPlanner.plan(queue, provider: provider, in: SampleWorkspace.make())
        #expect(plan.deliveries.isEmpty)
        #expect(!plan.blocked.isEmpty)
    }
    #expect(!ProviderDeliveryPlanner.confirms(Data(#"{"ok":true}"#.utf8)))
    #expect(!ProviderDeliveryPlanner.confirms(Data(#"{"added":{"movies":1},"not_found":{"movies":[{"ids":{"tmdb":1}}]}}"#.utf8)))
    #expect(ProviderDeliveryPlanner.confirms(Data(#"{"deleted":{"movies":1},"not_found":{"movies":[]}}"#.utf8)))
}

@Test func providerDeliveryProgressSurvivesEncodingAndCannotBeCoalesced() throws {
    let mutation = OptimisticMutation.patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: 8, clearScore: false, favorite: nil, queued: true, notes: nil)
    let entry = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: mutation, pendingProviders: [.simkl])
    var queue = SyncOutboxQueue(entries: [entry])
    queue.recordDelivery(entryID: entry.id, key: "simkl:rating", confirmed: true)
    queue.recordDelivery(entryID: entry.id, key: "simkl:history", confirmed: false)
    queue = try JSONDecoder().decode(SyncOutboxQueue.self, from: JSONEncoder().encode(queue))
    #expect(queue.entries[0].confirmedActions == ["simkl:rating"])
    #expect(queue.entries[0].uncertainActions == ["simkl:history"])
    queue.enqueue(SyncOutboxEntry(createdAt: entry.createdAt, mutation: mutation, pendingProviders: [.simkl]))
    #expect(queue.count == 2)
    queue.recordDelivery(entryID: entry.id, key: "simkl:history", confirmed: false, rejected: true)
    #expect(queue.entries[0].uncertainActions?.isEmpty == true)
}
