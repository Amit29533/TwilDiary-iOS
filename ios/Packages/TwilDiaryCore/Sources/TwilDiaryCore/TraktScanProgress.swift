import Foundation

/// The server's planning `page` is a one-based record offset, not an API page.
/// Keep the transport checkpoint intact and translate it only for presentation.
public struct TraktScanProgress: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let completed: Int?
    public let total: Int?
    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    public init(run: TraktSync.Run) {
        let received = max(0, run.progress)
        let offset = run.page > 0 ? run.page - 1 : 0
        var done: Int? = nil, count: Int? = nil
        switch run.stage {
        case "plan-remote-batch":
            title = "Comparing Trakt records"
            done = min(offset, received); count = received
            detail = "\(min(offset, received).formatted()) of \(received.formatted()) records compared"
        case "plan-history-batch":
            title = "Comparing your watch history"
            detail = "\(offset.formatted()) local viewings compared"
        case "plan-titles-batch":
            title = "Comparing ratings and watchlist"
            detail = "\(offset.formatted()) library titles compared"
        case "activities":
            title = "Checking Trakt activity"; detail = "Starting the manual comparison"
        case "verify":
            title = "Verifying the Trakt snapshot"; detail = "Checking that the received records are consistent"
        case "history", "movie-ratings", "show-ratings", "movie-watchlist", "show-watchlist":
            switch run.stage {
            case "history": title = "Fetching watch history"
            case "movie-ratings": title = "Fetching movie ratings"
            case "show-ratings": title = "Fetching show ratings"
            case "movie-watchlist": title = "Fetching movie watchlist"
            default: title = "Fetching show watchlist"
            }
            detail = "Page \(max(1, run.page).formatted()) · \(received.formatted()) records received"
        default:
            title = "Preparing your review"; detail = "\(received.formatted()) Trakt records received"
        }
        completed = done; total = count
    }
}

extension TraktSync {
    /// Partial proposals exist during planning but cannot be applied yet.
    public var discoveredChanges: Int { max(0, unresolved - (counts["links"] ?? 0)) }
}
