import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class DiscoveryCacheLoader {
    var calls = 0
    var fail = false
    var delayed = false
    var waiting: CheckedContinuation<CatalogPage, any Error>?
    var statusCalls = 0
    var waitingStatus: CheckedContinuation<TraktStatus, any Error>?
    var now = Date(timeIntervalSince1970: 1_000)
    func page() async throws -> CatalogPage {
        calls += 1
        if delayed { return try await withCheckedThrowingContinuation { waiting = $0 } }
        if fail { throw APIError.message("Synthetic discovery outage") }
        return CatalogPage(items: [CatalogItem(id: calls, mediaType: .tv, name: "Result \(calls)")], page: 1, totalPages: 1)
    }
    func resume(id: Int) {
        waiting?.resume(returning: CatalogPage(items: [CatalogItem(id: id, mediaType: .tv, name: "Delayed")], page: 1, totalPages: 1))
        waiting = nil
    }
    func status() async throws -> TraktStatus {
        statusCalls += 1
        return try await withCheckedThrowingContinuation { waitingStatus = $0 }
    }
}

@MainActor final class DiscoveryCacheTests: XCTestCase {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic cache request did not start")
        throw APIError.message("Synthetic request wait timed out")
    }
    func testCoalescedReadersSurviveOneCancelledShelf() async throws {
        let cache = DiscoveryCache(), scope = UUID(), loader = DiscoveryCacheLoader()
        loader.delayed = true
        let first = Task { try await cache.page("same", scope: scope, personal: false) { try await loader.page() } }
        try await waitUntil { loader.waiting != nil }
        let second = Task { try await cache.page("same", scope: scope, personal: false) { try await loader.page() } }
        for _ in 0..<10 { await Task.yield() }
        first.cancel(); loader.resume(id: 42)
        do { _ = try await first.value; XCTFail("Cancelled shelf must not publish") } catch is CancellationError { }
        let result = try await second.value
        XCTAssertEqual(result.items.map(\.id), [42]); XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(cache.cached("same", scope: scope, personal: false)?.items.map(\.id), [42])
    }
    func testAccountSwitchCancelsOldPersonalReadAndPreservesPublicCache() async throws {
        let cache = DiscoveryCache(), scope = UUID(), loader = DiscoveryCacheLoader()
        _ = try await cache.page("public", scope: scope, personal: false) { try await loader.page() }
        cache.activateAccount("Account-A")
        loader.delayed = true
        let old = Task { try await cache.page("recommendations", scope: scope, personal: true) { try await loader.page() } }
        try await waitUntil { loader.waiting != nil }
        cache.activateAccount("Account-B")
        XCTAssertNil(cache.cached("recommendations", scope: scope, personal: true, allowStale: true))
        loader.delayed = false
        let fresh = try await cache.page("recommendations", scope: scope, personal: true) { try await loader.page() }
        loader.resume(id: 999)
        do { _ = try await old.value; XCTFail("Old account response must be discarded") } catch is CancellationError { }
        XCTAssertEqual(cache.cached("recommendations", scope: scope, personal: true)?.items.map(\.id), fresh.items.map(\.id))
        XCTAssertNotNil(cache.cached("public", scope: scope, personal: false))
        cache.activateAccount(nil)
        XCTAssertNil(cache.cached("recommendations", scope: scope, personal: true, allowStale: true))
    }
    func testSessionChangeRejectsCancellationIgnoringOldResponse() async throws {
        let cache = DiscoveryCache(), loader = DiscoveryCacheLoader(), oldScope = UUID(), newScope = UUID()
        loader.delayed = true
        let old = Task { try await cache.page("same", scope: oldScope, personal: false) { try await loader.page() } }
        try await waitUntil { loader.waiting != nil }
        loader.delayed = false
        let fresh = try await cache.page("same", scope: newScope, personal: false) { try await loader.page() }
        loader.resume(id: 999)
        do { _ = try await old.value; XCTFail("Old owner response must be discarded") } catch is CancellationError { }
        XCTAssertEqual(cache.cached("same", scope: newScope, personal: false)?.items.map(\.id), fresh.items.map(\.id))
    }
    func testExpiredContentCanStayVisibleWhileRefreshFailsAndRetryReplacesIt() async throws {
        let clock = DiscoveryCacheLoader(), loader = DiscoveryCacheLoader(), scope = UUID()
        let cache = DiscoveryCache(now: { clock.now })
        _ = try await cache.page("same", scope: scope, personal: false) { try await loader.page() }
        clock.now += 301
        XCTAssertNil(cache.cached("same", scope: scope, personal: false))
        XCTAssertEqual(cache.cached("same", scope: scope, personal: false, allowStale: true)?.items.first?.id, 1)
        loader.fail = true
        do { _ = try await cache.page("same", scope: scope, personal: false) { try await loader.page() }; XCTFail("Outage must remain an error") } catch { }
        XCTAssertEqual(cache.cached("same", scope: scope, personal: false, allowStale: true)?.items.first?.id, 1)
        loader.fail = false
        let refreshed = try await cache.page("same", scope: scope, personal: false, refresh: true) { try await loader.page() }
        XCTAssertEqual(refreshed.items.first?.id, 3)
    }
    func testUnknownAccountNeverReusesPersonalContent() async throws {
        let cache = DiscoveryCache(), scope = UUID(), loader = DiscoveryCacheLoader()
        _ = try await cache.page("personal", scope: scope, personal: true) { try await loader.page() }
        _ = try await cache.page("personal", scope: scope, personal: true) { try await loader.page() }
        XCTAssertEqual(loader.calls, 2)
        XCTAssertNil(cache.cached("personal", scope: scope, personal: true, allowStale: true))
    }
    func testBoundedCacheEvictsOldestMetadataAndFreshPagesAvoidAnotherRead() async throws {
        let clock = DiscoveryCacheLoader(), loader = DiscoveryCacheLoader(), scope = UUID()
        let cache = DiscoveryCache(now: { clock.now })
        for number in 0..<17 {
            _ = try await cache.page("\(number)", scope: scope, personal: false) { try await loader.page() }
            clock.now += 1
        }
        XCTAssertNil(cache.cached("0", scope: scope, personal: false, allowStale: true))
        XCTAssertNotNil(cache.cached("16", scope: scope, personal: false))
        _ = try await cache.page("16", scope: scope, personal: false) { try await loader.page() }
        XCTAssertEqual(loader.calls, 17)
        _ = try await cache.page("16", scope: scope, personal: false, refresh: true) { try await loader.page() }
        XCTAssertNotNil(cache.cached("1", scope: scope, personal: false), "Replacing one cached page must not evict an unrelated page")
        _ = try await cache.page("1", scope: scope, personal: false) { try await loader.page() }
        XCTAssertEqual(loader.calls, 18)
    }
    func testConnectionChecksCoalesceButAreRevalidatedAfterCompletion() async throws {
        let cache = DiscoveryCache(), scope = UUID(), loader = DiscoveryCacheLoader()
        let first = Task { try await cache.status(scope: scope) { try await loader.status() } }
        try await waitUntil { loader.waitingStatus != nil }
        let second = Task { try await cache.status(scope: scope) { try await loader.status() } }
        for _ in 0..<10 { await Task.yield() }
        loader.waitingStatus?.resume(returning: TraktStatus(configured: true, connected: true, username: "Account-A"))
        loader.waitingStatus = nil
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.username, b.username); XCTAssertEqual(loader.statusCalls, 1)
        let next = Task { try await cache.status(scope: scope) { try await loader.status() } }
        try await waitUntil { loader.waitingStatus != nil }
        loader.waitingStatus?.resume(returning: TraktStatus(configured: true, connected: false))
        loader.waitingStatus = nil
        let disconnected = try await next.value
        XCTAssertFalse(disconnected.connected); XCTAssertEqual(loader.statusCalls, 2)
    }
}
