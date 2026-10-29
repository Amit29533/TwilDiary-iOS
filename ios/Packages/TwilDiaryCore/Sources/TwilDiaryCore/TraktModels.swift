import Foundation

public struct TraktStatus: Codable, Sendable {
    public let configured: Bool
    public var connected: Bool
    public let username: String?
    public let lastSyncAt: String?
    public let needsReconnect: Bool
    public init(configured: Bool, connected: Bool, username: String? = nil, lastSyncAt: String? = nil, needsReconnect: Bool = false) {
        self.configured = configured; self.connected = connected; self.username = username; self.lastSyncAt = lastSyncAt; self.needsReconnect = needsReconnect
    }
}
public struct TraktChange: Codable, Identifiable, Sendable {
    public struct Context: Codable, Sendable {
        public let local: String?
        public let remote: String?
        public let season: Int?
        public let episode: Int?
    }
    public let id: String
    public let kind: String
    public let direction: String
    public let name: String
    public let detail: String
    public let review: Bool
    public var state: String
    public let error: String?
    public let blocked: Bool
    public let context: Context?
    public var kindLabel: String { switch kind { case "history": "History"; case "rating": "Rating"; case "watchlist": "Watchlist"; default: kind.capitalized } }
}
public struct TraktSync: Codable, Sendable {
    public struct Run: Codable, Sendable {
        public let id: String
        public var state: String
        public let stage: String
        public let page: Int
        public let progress: Int
        public let ratingMode: String?
        public let error: String?
        public let retryAfter: Int
    }
    public var next: String?
    public var run: Run?
    public var items: [TraktChange]
    public var counts: [String: Int]
    public var reviewing: Bool { ["review", "applying"].contains(run?.state ?? "") }
    public var unresolved: Int { (counts["pending"] ?? 0) + (counts["failed"] ?? 0) + (counts["uncertain"] ?? 0) }
    public var pendingChanges: Int {
        guard reviewing else { return 0 }
        return max(0, unresolved - (counts["links"] ?? 0))
    }
    public var readyChanges: Int { max(0, (counts["safe"] ?? 0) - (counts["links"] ?? 0)) }
    public func appending(_ page: Self) -> Self {
        guard run?.id == page.run?.id else { return page }
        var ids = Set(items.map(\.id)), result = page
        result.items = items + page.items.filter { ids.insert($0.id).inserted }
        return result
    }
}
public enum TraktKind: String, CaseIterable, Identifiable, Sendable {
    case all, history, rating, watchlist
    public var id: Self { self }
    public var label: String { switch self { case .all: "All"; case .history: "History"; case .rating: "Ratings"; case .watchlist: "Watchlist" } }
}
public enum TraktChoice: String, Sendable { case apply, local, trakt, skip }
/// How conflicts are settled. Anything but `ask` also makes a scan apply itself when it finishes.
public enum TraktConflictDefault: String, CaseIterable, Identifiable, Sendable {
    case ask, local, trakt
    public var id: Self { self }
    public var label: String { switch self { case .ask: "Ask me"; case .local: "Keep TwilDiary"; case .trakt: "Use Trakt" } }
    public var choice: TraktChoice? { switch self { case .ask: nil; case .local: .local; case .trakt: .trakt } }
}
public enum TraktRatingMode: String, CaseIterable, Identifiable, Sendable {
    case round, integerOnly = "integer-only"
    public var id: Self { self }
    public var label: String { self == .round ? "Round for Trakt" : "Whole numbers only" }
}
