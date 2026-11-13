import Foundation

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
