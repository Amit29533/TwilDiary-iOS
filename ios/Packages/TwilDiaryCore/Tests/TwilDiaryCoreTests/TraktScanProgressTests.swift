import Foundation
import Testing
@testable import TwilDiaryCore

private func scan(_ stage: String, page: Int, progress: Int) throws -> TraktSync {
    let run: [String: Any] = ["id": "fixture", "state": "building", "stage": stage, "page": page, "progress": progress, "retryAfter": 0]
    let object: [String: Any] = [
        "run": run,
        "items": [], "counts": ["pending": 720, "links": 2]
    ]
    return try JSONDecoder().decode(TraktSync.self, from: JSONSerialization.data(withJSONObject: object))
}
@Test func traktPlanningOffsetIsNotAnEverGrowingNetworkPage() throws {
    let sync = try scan("plan-remote-batch", page: 481, progress: 2185)
    let value = TraktScanProgress(run: try #require(sync.run))
    #expect(value.completed == 480); #expect(value.total == 2185)
    #expect(value.fraction == Double(480) / 2185)
    #expect(sync.discoveredChanges == 718); #expect(sync.pendingChanges == 0)
    #expect(!sync.reviewing)
}
@Test func traktPlanningBoundsBadAndFinishedOffsets() throws {
    for (page, progress, expected) in [(Int.min, 10, 0), (999, 10, 10), (1, -2, 0)] {
        let value = TraktScanProgress(run: try #require(scan("plan-remote-batch", page: page, progress: progress).run))
        #expect(value.completed == expected)
        if progress <= 0 { #expect(value.fraction == nil) }
    }
}
@Test func traktLocalPlanningDoesNotInventATotalOrCallOffsetsPages() throws {
    for stage in ["plan-history-batch", "plan-titles-batch"] {
        let value = TraktScanProgress(run: try #require(scan(stage, page: 51, progress: 2185).run))
        #expect(value.fraction == nil); #expect(value.total == nil)
        #expect(!value.detail.contains("Page")); #expect(value.detail.contains("50"))
    }
}
@Test func traktFetchingStillReportsRealNetworkPages() throws {
    let value = TraktScanProgress(run: try #require(scan("history", page: 3, progress: 200).run))
    #expect(value.detail == "Page 3 · 200 records received"); #expect(value.fraction == nil)
}
