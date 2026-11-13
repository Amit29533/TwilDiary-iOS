import Foundation

/// How long a service asked to be left alone. Trakt and WeTrakr send `Retry-After`
/// (seconds or an HTTP date); MDBList also sends `X-RateLimit-Remaining` with a reset
/// (`X-RateLimit-Reset`, epoch seconds or seconds from now). The pause is kept between 5 seconds
/// and a day, so a bad header can't lock a service out for long.
public enum ProviderCooldown {
    public static func until(status: Int, headers: [String: String], now: Date = .now) -> Date? {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.trimmingCharacters(in: .whitespaces)
        }
        func clamp(_ seconds: Double) -> Date { now.addingTimeInterval(min(max(seconds, 5), 86_400)) }
        let exhausted = header("X-RateLimit-Remaining").flatMap(Double.init) == 0
        guard status == 429 || exhausted else { return nil }
        if let retry = header("Retry-After") {
            if let seconds = Double(retry) { return clamp(seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: retry) { return clamp(date.timeIntervalSince(now)) }
        }
        if let reset = header("X-RateLimit-Reset").flatMap(Double.init) {
            // Epoch seconds, or seconds from now.
            return clamp(reset > 1_000_000_000 ? reset - now.timeIntervalSince1970 : reset)
        }
        // Told to slow down without saying for how long: a minute.
        return status == 429 ? clamp(60) : nil
    }
}

/// A write whose answer was lost may or may not have reached the service. Before sending it again,
/// the service's own copy is read: a play of the same title (and episode) logged within two
/// minutes of the diary's time means it arrived, so it isn't sent twice.
public enum LostWriteCheck {
    public static func delivered(_ mutation: OptimisticMutation, in workspace: Workspace, library: TraktLibrary) -> Bool {
        guard case .markWatch(_, let titleId, let episodeId, let watchedAt, _, _) = mutation,
              let title = workspace.titles.first(where: { $0.id == titleId }), let tmdb = title.tmdbId,
              let when = DiaryDate.parse(watchedAt) else { return false }
        var season: Int?, number: Int?
        if title.isSeries {
            guard let episode = workspace.episodes.first(where: { $0.id == episodeId && $0.titleId == titleId }) else { return false }
            season = episode.season; number = episode.number
        }
        return library.plays.contains { play in
            play.title.tmdbId == tmdb && (play.title.kind == .show) == title.isSeries
                && play.season == season && play.episode == number
                && play.watchedAt.flatMap { DiaryDate.parse($0) }.map { abs($0.timeIntervalSince(when)) <= 120 } == true
        }
    }
}

/// How often the phone saves a backup to your server on its own (as Cinopsys does with its
/// folder and Drive backups: every 1, 7 or 30 days, with an hour's leeway so a backup made a
/// little early still counts).
public enum BackupSchedule: String, CaseIterable, Identifiable, Sendable {
    case off, daily, weekly, monthly
    public var id: String { rawValue }
    public var label: String {
        switch self { case .off: "Off"; case .daily: "Daily"; case .weekly: "Weekly"; case .monthly: "Monthly" }
    }
    public var interval: TimeInterval? {
        switch self { case .off: nil; case .daily: 86_400; case .weekly: 7 * 86_400; case .monthly: 30 * 86_400 }
    }
    /// When the next automatic backup is due (now, when there has never been one).
    public func next(after last: Date?, now: Date = .now) -> Date? {
        guard let interval else { return nil }
        guard let last else { return now }
        return last.addingTimeInterval(interval - 3_600)
    }
    public func isDue(last: Date?, now: Date = .now) -> Bool {
        guard let next = next(after: last, now: now) else { return false }
        return now >= next
    }
}
