import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func pendingBackendEditsCannotReachDirectProvidersBeforeConfirmation() throws {
    var queue = SyncOutboxQueue()
    let entry = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: .patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: 9, clearScore: false, favorite: nil, queued: nil, notes: nil), pendingProviders: [.cloudflare, .trakt])
    queue.enqueue(entry)
    #expect(MultiProviderOutboxDispatcher.prepareBatch(for: .trakt, from: queue, in: try SampleWorkspace.mapped()) == nil)
    queue.acknowledge(entryID: entry.id, provider: .cloudflare)
    #expect(MultiProviderOutboxDispatcher.prepareBatch(for: .trakt, from: queue, in: try SampleWorkspace.mapped()) != nil)
}

@Test func ambiguousPatchIsNotCoalescedAndTagsSurviveSerialization() throws {
    let mutation = OptimisticMutation.patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: nil, clearScore: false, favorite: nil, queued: nil, notes: "first", tags: ["Weekend"])
    let first = SyncOutboxEntry(createdAt: "2026-11-03T00:00:00Z", mutation: mutation, attempts: 1)
    var queue = SyncOutboxQueue(entries: [first])
    queue.enqueue(SyncOutboxEntry(createdAt: "2026-11-03T00:00:01Z", mutation: .patchTitle(titleId: "again", expectedVersion: 2, status: nil, score: 8, clearScore: false, favorite: nil, queued: nil, notes: nil)))
    #expect(queue.count == 2)
    let decoded = try JSONDecoder().decode(SyncOutboxQueue.self, from: JSONEncoder().encode(queue))
    #expect(decoded == queue)
    #expect(decoded.project(onto: SampleWorkspace.make()).titles.first { $0.id == "again" }?.tags == ["Weekend"])
}

@Test func confirmedWatchReplacesLocalIDsAndAdvancesOnlyItsDependentTitleEdit() throws {
    let watch = SyncOutboxEntry(operationId: "op", createdAt: "2026-11-03T00:00:00Z", mutation: .markWatch(operationId: "op", titleId: "again", episodeId: nil, watchedAt: "2026-11-03T00:00:00Z", recordedAt: "2026-11-03T00:00:00Z", rewatch: true))
    let revoke = SyncOutboxEntry(createdAt: watch.createdAt, mutation: .revokeWatch(eventId: "local-op", titleId: "again", expectedVersion: 1, revokedAt: watch.createdAt))
    let patch = SyncOutboxEntry(createdAt: watch.createdAt, mutation: .patchTitle(titleId: "again", expectedVersion: 3, status: nil, score: 9, clearScore: false, favorite: nil, queued: nil, notes: nil))
    let receipt = WatchEvent(id: "server-event", operationId: "op", titleId: "again", episodeId: nil, watchedAt: watch.createdAt, recordedAt: watch.createdAt)
    let queue = SyncOutboxQueue(entries: [watch, revoke, patch]).confirming(watch, titleVersion: 7, event: receipt)
    #expect(queue.count == 2)
    #expect(queue.entries[0].mutation == .revokeWatch(eventId: "server-event", titleId: "again", expectedVersion: 1, revokedAt: watch.createdAt))
    #expect(queue.entries[1].mutation == patch.mutation.rebased(titleVersion: 7))
}

@Test func retryReconciliationChecksOnlyTheEditedFieldsAndRejectsConflictingValues() throws {
    var base = SampleWorkspace.make()
    let index = try #require(base.titles.firstIndex { $0.id == "again" })
    let mutation = OptimisticMutation.patchTitle(titleId: "again", expectedVersion: 1, status: nil, score: nil, clearScore: false, favorite: true, queued: nil, notes: nil)
    base.titles[index].favorite = true
    base.titles[index].notes = "Changed elsewhere"
    #expect(mutation.isSatisfied(in: base))
    base.titles[index].favorite = false
    #expect(!mutation.isSatisfied(in: base))
}
