import Foundation
import Testing
@testable import TwilDiaryCore

@Test func traktPendingCountExcludesLinksAndFinishedRuns() throws {
    let data = Data(#"{"run":{"id":"fixture","state":"review","stage":"review","page":1,"progress":100,"error":null,"retryAfter":0},"items":[],"counts":{"pending":8,"failed":2,"uncertain":1,"links":3,"safe":5}}"#.utf8)
    var review = try JSONDecoder().decode(TraktSync.self, from: data)
    #expect(review.pendingChanges == 8)
    #expect(review.readyChanges == 2)
    #expect(review.unresolved == 11)
    review.run?.state = "complete"
    #expect(review.pendingChanges == 0)
    review.run?.state = "cancelled"
    #expect(review.pendingChanges == 0)
}
