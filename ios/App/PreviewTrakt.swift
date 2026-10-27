#if DEBUG
import Foundation
import TwilDiaryCore

/// Isolated simulator provider. No HTTP requests or real-account changes are possible here.
@MainActor final class FixtureTraktService: TraktServicing {
    private var connection: TraktStatus
    private var snapshot: TraktSync
    private let unavailable: Bool
    private let largeImport: Bool
    private var quotaOnStatus: Bool
    init(scenario: String = "review") {
        unavailable = scenario == "unavailable"
        largeImport = scenario == "large-import" || scenario == "cold-quota"
        quotaOnStatus = scenario == "cold-quota"
        let statusURL = Bundle.main.url(forResource: "trakt-status", withExtension: "json")!
        let syncURL = Bundle.main.url(forResource: "trakt-sync", withExtension: "json")!
        connection = try! JSONDecoder().decode(TraktStatus.self, from: Data(contentsOf: statusURL))
        snapshot = try! JSONDecoder().decode(TraktSync.self, from: Data(contentsOf: syncURL))
        if scenario == "disconnected" {
            connection = TraktStatus(configured: true, connected: false)
            snapshot.run = nil; snapshot.items = []; snapshot.counts = [:]
        } else if scenario == "reconnect" { connection = TraktStatus(configured: true, connected: true, username: "reference-user", needsReconnect: true) }
        else if scenario == "scanning" { snapshot.run?.state = "building" }
        else if scenario == "comparing" {
            snapshot.run = try! JSONDecoder().decode(TraktSync.Run.self, from: Data(#"{"id":"fixture-comparing","state":"building","stage":"plan-remote-batch","page":481,"progress":2185,"retryAfter":0}"#.utf8))
            snapshot.counts = ["pending": 720, "links": 2]
        }
        if largeImport { snapshot.counts = ["pending": 2000, "safe": 2000, "applied": 0] }
    }
    func status() async throws -> TraktStatus {
        if unavailable { throw APIError.message("The connection is temporarily unavailable. Try again.") }
        if quotaOnStatus { quotaOnStatus = false; throw APIError.databaseLimit(.now.addingTimeInterval(20)) }
        return connection
    }
    func review(kind: TraktKind, query: String, after: String?) async throws -> TraktSync {
        var result = snapshot
        result.items = result.items.filter { (kind == .all || $0.kind == kind.rawValue) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        return result
    }
    func start(mode: TraktRatingMode) async throws -> String {
        self.snapshot = FixtureTraktService().snapshot
        snapshot.run?.state = "building"
        return snapshot.run!.id
    }
    func step(id: String) async throws -> TraktSync { snapshot.run?.state = "review"; return snapshot }
    func apply(id: String, change: String?, choice: TraktChoice) async throws -> TraktSync {
        if largeImport && change == nil {
            // A real batched apply on the free plan takes about a second. Model it,
            // so the 50-batch import is still running while tests visit other tabs.
            try await Task.sleep(for: .seconds(1))
            let saved = min(40, snapshot.counts["pending"] ?? 0)
            snapshot.counts["pending", default: 0] -= saved
            snapshot.counts["safe", default: 0] -= saved
            snapshot.counts["applied", default: 0] += saved
            snapshot.run?.state = saved == 0 ? "complete" : "applying"
            return snapshot
        }
        for index in snapshot.items.indices {
            let item = snapshot.items[index]
            guard item.state == "pending", change.map({ $0 == item.id }) ?? (!item.review && !item.blocked) else { continue }
            if item.review && choice == .apply { throw APIError.message("Choose Keep TwilDiary or Use Trakt for this conflict.") }
            if item.blocked && choice != .skip { throw APIError.message("This item needs to be skipped.") }
            snapshot.items[index].state = choice == .skip ? "skipped" : "applied"
        }
        snapshot.counts["pending"] = snapshot.items.filter { $0.state == "pending" }.count
        snapshot.counts["safe"] = snapshot.items.filter { $0.state == "pending" && !$0.review && !$0.blocked }.count
        snapshot.counts["skipped"] = snapshot.items.filter { $0.state == "skipped" }.count
        snapshot.counts["applied"] = snapshot.items.filter { $0.state == "applied" }.count
        if snapshot.counts["pending"] == 0 { snapshot.run?.state = "complete" }
        return snapshot
    }
    func cancel(id: String) async throws { snapshot.run?.state = "cancelled" }
    func disconnect() async throws { connection.connected = false; snapshot.run = nil; snapshot.items = []; snapshot.counts = [:] }
}
#endif

@MainActor func makeTraktService(store: DiaryStore) -> any TraktServicing {
    #if DEBUG
    if store.isPreview {
        let prefix = "--ui-trakt="
        let scenario = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "review"
        return FixtureTraktService(scenario: scenario)
    }
    #endif
    return LiveTraktService(store: store)
}
