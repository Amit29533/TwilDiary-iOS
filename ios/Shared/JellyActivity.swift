import Foundation
import ActivityKit

#if canImport(ActivityKit)
/// The Live Activity older builds showed while JellySpace played. Kept only so the app can find and
/// end one that's still around (JellyLiveActivity.endLeftovers); nothing starts it any more.
public struct JellyPlaybackAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var detail: String
        public var startedAt: Date
        public var endsAt: Date
        public var paused: Bool
        public var position: Double
        public var duration: Double
        public var nextTitle: String?
        public var nextAt: Date?
    }
    public let itemID: String
    public init(itemID: String) { self.itemID = itemID }
}
#endif
