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
