import Foundation
import TwilDiaryCore

/// Preserve provider/retry evidence only for the reviewed Trakt endpoints.
/// A lost POST response is reconciled by GET before any further write.
struct TraktTransferFailure: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var retryAt: Date? = nil
    var errorDescription: String? { message }
    var retryable: Bool {
        if ["trakt_reconnect_required", "trakt_access_limited", "setup_required", "sync_snapshot_changed", "sync_review_required"].contains(code) { return false }
        // trakt_refresh_pending: another request is refreshing the Trakt sign-in; it clears in seconds.
        return [0, 408, 425, 429, 500, 502, 503, 504].contains(status) || code == "sync_busy" || code == "trakt_refresh_pending"
    }
    static func retryDate(_ header: String?, now: Date) -> Date? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(min(seconds, 86_400)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: header), date.timeIntervalSince1970.isFinite else { return nil }
        return min(date, now.addingTimeInterval(86_400))
    }
}

struct TraktApplyProgress: Equatable {
    let applied: Int
    let skipped: Int
    let remaining: Int
    let failed: Int
    let total: Int
    var finished: Int { applied + skipped }
    var fraction: Double { total > 0 ? min(1, Double(finished) / Double(total)) : 0 }
    var percent: Int { Int((fraction * 100).rounded(.down)) }
    init(_ sync: TraktSync) {
        func count(_ key: String) -> Int { min(Int.max / 8, max(0, sync.counts[key] ?? 0)) }
        applied = count("applied"); skipped = count("skipped")
        remaining = count("pending") + count("failed") + count("uncertain")
        failed = count("failed") + count("uncertain")
        total = applied + skipped + remaining
    }
}

@MainActor protocol TraktApplyCheckpointStoring: AnyObject { var runID: String? { get set } }
@MainActor final class MemoryTraktApplyCheckpoint: TraktApplyCheckpointStoring { var runID: String? }
@MainActor final class PreferencesTraktApplyCheckpoint: TraktApplyCheckpointStoring {
    private let key = "trakt.approvedBulkRun"
    var runID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { if let newValue { UserDefaults.standard.set(newValue, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    }
}
