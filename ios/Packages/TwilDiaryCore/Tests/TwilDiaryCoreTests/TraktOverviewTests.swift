import Foundation
import Testing
@testable import TwilDiaryCore

private func overviewSync(_ state: String, pending: Int = 8, links: Int = 0) throws -> TraktSync {
    try JSONDecoder().decode(TraktSync.self, from: Data("{\"run\":{\"id\":\"reference\",\"state\":\"\(state)\",\"stage\":\"history\",\"page\":1,\"progress\":120,\"error\":null,\"retryAfter\":0},\"items\":[],\"counts\":{\"pending\":\(pending),\"links\":\(links)}}".utf8))
}
@Test func traktOverviewNeverShowsStaleReviewCountsAfterDisconnectOrExpiry() throws {
    let review = try overviewSync("review")
    let disconnected = TraktStatus(configured: true, connected: false)
    let stale = TraktOverview(status: disconnected, sync: review, checked: true, unavailable: false)
    #expect(stale.pending == 0); #expect(stale.title == "Bring your watch history together"); #expect(stale.action == "Set up Trakt")
    let expired = TraktStatus(configured: true, connected: true, needsReconnect: true)
    let reconnect = TraktOverview(status: expired, sync: review, checked: true, unavailable: false)
    #expect(reconnect.pending == 0); #expect(reconnect.badge == "Reconnect"); #expect(reconnect.title == "Reconnect to Trakt"); #expect(reconnect.attention)
    #expect(reconnect.action == "Open Trakt sync")
}
@Test func traktOverviewMatchesLoadingFailureBuildingAndReviewPriorities() throws {
    let connected = TraktStatus(configured: true, connected: true)
    let loading = TraktOverview(status: nil, sync: nil, checked: false, unavailable: false)
    #expect(loading.badge == "Checking…"); #expect(loading.title == "Your diary, connected")
    let failure = TraktOverview(status: nil, sync: nil, checked: true, unavailable: true)
    #expect(failure.title == "Check your connection"); #expect(failure.detail == "Open Trakt to retry and check its status.")
    let building = TraktOverview(status: connected, sync: try overviewSync("building"), checked: true, unavailable: false)
    #expect(building.title == "Your scan is in progress"); #expect(building.action == "Continue scan"); #expect(building.pending == 0)
    let singular = TraktOverview(status: connected, sync: try overviewSync("review", pending: 3, links: 2), checked: true, unavailable: false)
    #expect(singular.title == "1 change to review"); #expect(singular.action == "Review changes")
    let linked = TraktOverview(status: connected, sync: try overviewSync("review", pending: 2, links: 2), checked: true, unavailable: false)
    #expect(linked.title == "Keep your watches in sync"); #expect(linked.action == "Review changes"); #expect(!linked.attention)
    let finished = TraktOverview(status: connected, sync: try overviewSync("complete"), checked: true, unavailable: false)
    #expect(finished.pending == 0); #expect(finished.action == "Open Trakt sync")
}

@Test func traktOverviewUsesTheLastSuccessfulSyncCopy() {
    let status = TraktStatus(configured: true, connected: true, lastSyncAt: "2026-10-23T12:00:00Z")
    let value = TraktOverview(status: status, sync: nil, checked: true, unavailable: false, locale: Locale(identifier: "en_US"))
    #expect(value.detail.hasPrefix("Last synced ")); #expect(value.detail.contains("2026")); #expect(value.detail.hasSuffix(". Scan again when you’re ready."))
}
