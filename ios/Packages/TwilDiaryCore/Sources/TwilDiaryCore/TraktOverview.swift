import Foundation

/// Copy and priority rules from the More page's Trakt summary.
public struct TraktOverview: Equatable, Sendable {
    public let badge: String
    public let title: String
    public let detail: String
    public let action: String
    public let attention: Bool
    public let pending: Int
    public init(status: TraktStatus?, sync: TraktSync?, checked: Bool, unavailable: Bool, locale: Locale = .current) {
        let connected = status?.connected == true
        let reconnect = status?.needsReconnect == true
        let live = connected && !reconnect ? sync : nil
        pending = live?.pendingChanges ?? 0
        attention = pending > 0 || reconnect
        let reviewing = live?.reviewing == true
        let building = live?.run?.state == "building"
        if !checked { badge = "Checking…"; title = "Your diary, connected" }
        else if unavailable { badge = "Unavailable"; title = "Check your connection" }
        else if pending > 0 { badge = "Needs review"; title = "\(pending) \(pending == 1 ? "change" : "changes") to review" }
        else if reconnect { badge = "Reconnect"; title = "Reconnect to Trakt" }
        else { badge = connected ? "Connected" : "Not connected"; title = building ? "Your scan is in progress" : connected ? "Keep your watches in sync" : "Bring your watch history together" }
        if pending > 0 || reviewing { detail = "Your scan is ready. Review changes before applying them." }
        else if unavailable { detail = "Open Trakt to retry and check its status." }
        else if building { detail = "Your scan prepares a review of history, ratings and watchlist changes." }
        else if let date = DiaryDate.parse(status?.lastSyncAt) {
            let value = date.formatted(Date.FormatStyle().month(.abbreviated).day().year().locale(locale))
            detail = "Last synced \(value). Scan again when you’re ready."
        } else { detail = connected ? "Scan Trakt to review incoming and outgoing changes before applying them." : "Connect Trakt to review your history, ratings and watchlist in one place." }
        action = pending > 0 || reviewing ? "Review changes" : building ? "Continue scan" : connected ? "Open Trakt sync" : "Set up Trakt"
    }
}
