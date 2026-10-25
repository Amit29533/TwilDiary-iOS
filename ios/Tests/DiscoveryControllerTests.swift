import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class DiscoveryStub: DiscoveryServing {
    var connected = true
    var requests: [[String: String]] = []
    var delayed: CheckedContinuation<CatalogPage, any Error>?
    var failMovies = false
    var failTV = false
    var wrongPage = false
    func traktConnected() async throws -> Bool { connected }
    func page(_ query: [String: String]) async throws -> CatalogPage {
        requests.append(query)
        if query["genre"] == "Delayed" { return try await withCheckedThrowingContinuation { delayed = $0 } }
        if (query["type"] == "movie" && failMovies) || (query["type"] == "tv" && failTV) { throw APIError.message("Synthetic provider unavailable") }
        let kind = MediaKind(rawValue: query["type"] ?? "tv") ?? .tv, page = Int(query["page"] ?? "1") ?? 1
        let first = CatalogItem(id: 1, mediaType: kind, name: "First"), second = CatalogItem(id: 2, mediaType: kind, name: "Second")
        return CatalogPage(items: page == 1 ? [first] : [first, second], page: wrongPage ? 1 : page, totalPages: 2)
    }
}

@MainActor private final class HeldRecommendations: DiscoveryServing {
    var recommendationScope: UUID? = UUID()
    var recommendationOwner: String? = "Account-A"
    var cached: [CatalogItem]?
    var pending: [(kind: MediaKind, continuation: CheckedContinuation<CatalogPage, any Error>?)] = []
    func traktConnected() async throws -> Bool { true }
    func cachedRecommendations(limit: Int) -> [CatalogItem]? { cached }
    func page(_ query: [String: String]) async throws -> CatalogPage {
        let kind = MediaKind(rawValue: query["type"] ?? "") ?? .tv
        return try await withCheckedThrowingContinuation { pending.append((kind, $0)) }
    }
    func finish(_ index: Int, id: Int? = nil) {
        guard let continuation = pending[index].continuation else { return }
        pending[index].continuation = nil
        if let id { continuation.resume(returning: CatalogPage(items: [CatalogItem(id: id, mediaType: pending[index].kind, name: "Replacement")], page: 1, totalPages: 1)) }
        else { continuation.resume(throwing: APIError.message("Synthetic recommendation outage")) }
    }
    func finishAll() { for index in pending.indices { finish(index) } }
}

@MainActor final class DiscoveryControllerTests: XCTestCase {
    func testRecommendationsStartBothMediaTypesAndRetainStaleContentDuringPartialRefresh() async throws {
        let service = HeldRecommendations()
        service.cached = [CatalogItem(id: 70, mediaType: .movie, name: "Saved movie"), CatalogItem(id: 80, mediaType: .tv, name: "Saved show")]
        let model = DiscoveryRecommendations(service: service)
        let loading = Task { await model.load(limit: 24) }
        defer { service.finishAll() }
        try await waitForRequests(2, service: service)
        XCTAssertTrue(model.loading)
        XCTAssertEqual(model.items.map(\.key), ["movie:70", "tv:80"])
        // Neither request had to finish before the other could begin.
        for index in service.pending.indices { service.finish(index, id: service.pending[index].kind == .tv ? 81 : nil) }
        await loading.value
        XCTAssertEqual(model.items.map(\.key), ["movie:70", "tv:81"])
        XCTAssertEqual(model.error, "Some recommendations could not load.")
        XCTAssertFalse(model.loading)
    }
    func testNewOwnerClearsOldVisibleRecommendationsAndRejectsLateResponses() async throws {
        let service = HeldRecommendations()
        service.cached = [CatalogItem(id: 70, mediaType: .movie, name: "Account A")]
        let model = DiscoveryRecommendations(service: service)
        let old = Task { await model.load() }
        defer { service.finishAll() }
        try await waitForRequests(2, service: service)
        XCTAssertEqual(model.items.first?.id, 70)
        service.recommendationScope = UUID(); service.recommendationOwner = "Account-B"; service.cached = nil
        let fresh = Task { await model.load() }
        try await waitForRequests(4, service: service)
        XCTAssertTrue(model.items.isEmpty)
        service.finish(2, id: 200); service.finish(3, id: 200)
        await fresh.value
        XCTAssertEqual(Set(model.items.map(\.key)), ["movie:200", "tv:200"])
        service.finish(0, id: 999); service.finish(1, id: 999)
        await old.value
        XCTAssertEqual(Set(model.items.map(\.key)), ["movie:200", "tv:200"])
        XCTAssertNil(model.error)
    }
    private func waitForRequests(_ count: Int, service: HeldRecommendations) async throws {
        for _ in 0..<200 {
            if service.pending.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Concurrent recommendation requests did not start")
        throw APIError.message("Synthetic request wait timed out")
    }
    func testPagingRetainsFirstIdentityAndRejectsAnotherFilterScope() async {
        let service = DiscoveryStub()
        let results = DiscoveryResults(service: service)
        var filters = DiscoveryFilters(section: .genres); filters.genre = "Drama"
        await results.load(filters.query(section: .genres))
        XCTAssertTrue(results.hasMore)
        await results.load(filters.query(section: .genres), more: true)
        XCTAssertEqual(results.items.map(\.key), ["tv:1", "tv:2"])
        XCTAssertFalse(results.hasMore)
        filters.genre = "Animation"
        await results.load(filters.query(section: .genres), more: true)
        XCTAssertEqual(service.requests.count, 2)
    }
    func testLateFilterResponseCannotReplaceTheLatestGrid() async {
        let service = DiscoveryStub()
        let model = DiscoveryResults(service: service)
        var old = DiscoveryFilters(section: .genres); old.genre = "Delayed"
        let query = old.query(section: .genres)
        let pending = Task { await model.load(query) }
        while service.delayed == nil { await Task.yield() }
        var fresh = DiscoveryFilters(section: .genres); fresh.type = "movie"
        await model.load(fresh.query(section: .genres))
        service.delayed?.resume(returning: CatalogPage(items: [CatalogItem(id: 99, mediaType: .tv, name: "Stale")], page: 1, totalPages: 1))
        await pending.value
        XCTAssertEqual(model.items.map(\.key), ["movie:1"])
        XCTAssertFalse(model.loading)
    }
    func testAppendFailureKeepsTheConfirmedPageAndCanRetryIt() async {
        let service = DiscoveryStub()
        let results = DiscoveryResults(service: service), query = DiscoveryFilters(section: .ratedShows).query(section: .ratedShows)
        await results.load(query)
        service.failTV = true; await results.load(query, more: true)
        XCTAssertEqual(results.items.map(\.id), [1]); XCTAssertEqual(results.page, 1); XCTAssertNotNil(results.error)
        service.failTV = false; await results.load(query, more: true)
        XCTAssertEqual(results.items.map(\.id), [1, 2]); XCTAssertNil(results.error)
    }
    func testUnexpectedProviderPageDoesNotPublishOrAdvance() async {
        let service = DiscoveryStub()
        let results = DiscoveryResults(service: service), query = DiscoveryFilters(section: .ratedShows).query(section: .ratedShows)
        await results.load(query)
        service.wrongPage = true; await results.load(query, more: true)
        XCTAssertEqual(results.page, 1); XCTAssertEqual(results.items.count, 1); XCTAssertNotNil(results.error)
    }
    func testRecommendationsKeepSuccessfulTypeAndDoNotRequestDisconnectedProvider() async {
        let service = DiscoveryStub()
        let model = DiscoveryRecommendations(service: service)
        service.failMovies = true; await model.load(limit: 24)
        XCTAssertEqual(model.items.map(\.key), ["tv:1"])
        XCTAssertEqual(model.error, "Some recommendations could not load.")
        XCTAssertTrue(service.requests.allSatisfy { $0["source"] == "trakt" && $0["limit"] == "24" && $0["page"] == "1" })
        service.requests = []; service.connected = false; await model.load()
        XCTAssertTrue(service.requests.isEmpty); XCTAssertTrue(model.items.isEmpty); XCTAssertFalse(model.connected)
    }
}
