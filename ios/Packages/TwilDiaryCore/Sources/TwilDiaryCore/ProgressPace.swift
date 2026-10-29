import Foundation

/// Measures how fast a long task moves (Trakt comparison, applying a review) and
/// estimates the time left. Samples older than a minute are dropped, and a new stage
/// or a count going backwards starts over, so the estimate follows the current pace.
public struct ProgressPace: Equatable, Sendable {
    public struct Sample: Equatable, Sendable { public let date: Date; public let done: Int }
    public private(set) var scope = ""
    public private(set) var samples: [Sample] = []
    /// The first sample of this scope, for "1m 10s so far".
    public private(set) var startedAt: Date?
    public init() { }

    public mutating func record(_ done: Int, at date: Date, scope: String) {
        if scope != self.scope || (samples.last.map { done < $0.done } ?? false) {
            self.scope = scope; samples = []; startedAt = date
        }
        if let last = samples.last, last.done == done, date.timeIntervalSince(last.date) < 1 { return }
        samples.append(Sample(date: date, done: done))
        samples.removeAll { date.timeIntervalSince($0.date) > 60 }
        if startedAt == nil { startedAt = date }
    }

    /// Items per second over the kept window; nil until five seconds of real progress.
    public var perSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let seconds = last.date.timeIntervalSince(first.date), moved = last.done - first.done
        guard seconds >= 5, moved > 0 else { return nil }
        return Double(moved) / seconds
    }

    public func secondsLeft(remaining: Int) -> Double? {
        guard remaining >= 0, let rate = perSecond else { return nil }
        return Double(remaining) / rate
    }

    /// "Less than a minute left", "About 4 min left", "About 1 h 20 min left".
    public static func label(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "About \(minutes) min left" }
        return "About \(minutes / 60) h \(minutes % 60) min left"
    }

    /// "42 s", "3m 05s", "1h 02m" for the time a task has been running.
    public static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}

/// The three stages a Trakt scan reports as bars: Download, Compare and Review.
public struct TraktScanStages: Equatable, Sendable {
    public enum Stage: Int, Sendable { case download, compare, review }
    public let current: Stage
    /// The comparison's share done, when it has a known total.
    public let compare: Double?
    /// Units done and their total in the current comparison, for the pace and time left.
    public let done: Int?
    public let total: Int?

    /// `localPlays` and `localTitles` are the diary's active watches and titles: the
    /// history and ratings/watchlist comparisons walk exactly those.
    public init(run: TraktSync.Run, localPlays: Int, localTitles: Int) {
        let offset = max(0, run.page > 0 ? run.page - 1 : 0), received = max(0, run.progress)
        // Each comparison stage is a third of the comparison; its own total sizes the third.
        func part(_ index: Int, _ done: Int, _ total: Int) -> (Double?, Int?, Int?) {
            guard total > 0 else { return (Double(index) / 3, nil, nil) }
            let share = min(1, Double(min(done, total)) / Double(total))
            return ((Double(index) + share) / 3, min(done, total), total)
        }
        let value: (Stage, Double?, Int?, Int?)
        switch run.stage {
        case "plan-remote-batch": let p = part(0, offset, received); value = (.compare, p.0, p.1, p.2)
        case "plan-history-batch": let p = part(1, offset, localPlays); value = (.compare, p.0, p.1, p.2)
        case "plan-titles-batch": let p = part(2, offset, localTitles); value = (.compare, p.0, p.1, p.2)
        case "activities", "verify", "history", "movie-ratings", "show-ratings", "movie-watchlist", "show-watchlist":
            value = (.download, nil, nil, nil)
        default:
            value = run.state == "building" ? (.compare, nil, nil, nil) : (.review, 1, nil, nil)
        }
        current = value.0; compare = value.1; done = value.2; total = value.3
    }
}
