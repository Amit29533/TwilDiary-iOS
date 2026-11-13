import Foundation
import UserNotifications
import TwilDiaryCore

/// Release alerts, worked out on this iPhone from TMDB (no server):
/// - a Planned movie's digital release in your region ("out to stream or buy"),
/// - a new season (or the first) of a show you finished or planned,
/// - a show you're watching coming back from a break of four weeks or more.
/// The first time a date appears you get a heads-up; on the day, an alert at 9 am. Each title is
/// asked again at most once a day; the first run only notes what's already known (no flood).
@MainActor enum ReleaseAlerts {
    static let enabledKey = "releaseAlerts"
    /// Follows new-episode alerts until you set it yourself (the same permission).
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? EpisodeNotifications.enabled }
    /// Settings → Notifications → Releases.
    @discardableResult static func setEnabled(_ on: Bool, store: DiaryStore) async -> Bool {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            await clear()
            return true
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        if granted { await refresh(store: store) }
        return granted
    }
    private static let cacheKey = "releaseAlerts.cache", seenKey = "releaseAlerts.seen"
    private static let prefix = "release|"

    /// What TMDB said about a title, kept a day.
    struct Found: Codable, Equatable {
        var day: String?
        var season: Int?
        /// "movie", "premiere" (a new season or the first) or "return" (after a break).
        var kind: String?
        var fetchedAt: Date
    }
    /// One release to tell you about.
    struct Release: Equatable {
        let id: String
        let titleId: String
        let day: String
        let heading: String
        let body: String
        let heads: String
        /// Watching shows already get the day's new-episode alert: only the heads-up then.
        let alertOnDay: Bool
    }

    static func refresh(store: DiaryStore) async {
        guard enabled, !store.isPreview, store.hasLoadedWorkspace, let token = TMDBDirect.token(store) else { return }
        let center = UNUserNotificationCenter.current()
        guard await EpisodeNotifications.allowed() else { return }
        let region = (UserDefaults.standard.string(forKey: "streamingRegion") ?? Locale.current.region?.identifier ?? "US").uppercased()
        let today = DiaryDate.day(store.now)
        var cache = (UserDefaults.standard.data(forKey: cacheKey)).flatMap { try? JSONDecoder().decode([String: Found].self, from: $0) } ?? [:]
        let candidates = store.workspace.activeTitles.filter { title in
            guard title.tmdbId != nil else { return false }
            return title.isSeries ? ["completed", "planned", "watching", "paused"].contains(title.status) : title.status == "planned"
        }
        var asked = 0
        for title in candidates {
            guard !Task.isCancelled else { return }
            if let known = cache[title.id], Date.now.timeIntervalSince(known.fetchedAt) < 86_400 { continue }
            guard asked < 40, let tmdb = title.tmdbId else { continue }  // the rest on the next open
            asked += 1
            do {
                cache[title.id] = title.isSeries ? try await showNews(tmdb, token: token) : try await movieRelease(tmdb, region: region, token: token)
            } catch { continue }
        }
        let live = Set(candidates.map(\.id))
        cache = cache.filter { live.contains($0.key) }
        UserDefaults.standard.set(try? JSONEncoder().encode(cache), forKey: cacheKey)
        let releases = candidates.compactMap { title in cache[title.id].flatMap { release(for: title, $0, today: today) } }
        let posters = Dictionary(candidates.map { ($0.id, $0.poster) }, uniquingKeysWith: { first, _ in first })
        await schedule(releases, today: today, center: center, posters: posters)
    }

    /// Turns what TMDB said into a release to tell you about (nil: nothing ahead).
    static func release(for title: MediaTitle, _ found: Found, today: String) -> Release? {
        guard let day = found.day, day >= today, let kind = found.kind else { return nil }
        let when = spoken(day)
        switch kind {
        case "movie":
            return Release(id: prefix + "movie|\(title.id)|\(day)", titleId: title.id, day: day,
                           heading: "\(title.name) is out to stream", body: "A movie you planned is out on digital today.",
                           heads: "\(title.name) comes out to stream or buy on \(when).", alertOnDay: true)
        case "premiere":
            let season = found.season ?? 1
            let what = season <= 1 ? "\(title.name) premieres" : "Season \(season) of \(title.name) premieres"
            return Release(id: prefix + "premiere|\(title.id)|\(season)|\(day)", titleId: title.id, day: day,
                           heading: "\(what) today", body: season <= 1 ? "A show you planned starts today." : "A show you finished is back.",
                           heads: "\(what) on \(when).", alertOnDay: title.status != "watching")
        default:
            return Release(id: prefix + "return|\(title.id)|\(day)", titleId: title.id, day: day,
                           heading: "\(title.name) is back today", body: "A show you're watching returns from its break.",
                           heads: "\(title.name) returns on \(when).", alertOnDay: false)
        }
    }

    /// The earliest digital release (TMDB type 4) in your region, else in the US.
    private static func movieRelease(_ tmdb: Int, region: String, token: String) async throws -> Found {
        let data = try await TMDBDirect.object("movie/\(tmdb)/release_dates", query: [:], token: token)
        return Found(day: digitalDay(data, region: region), season: nil, kind: "movie", fetchedAt: .now)
    }
    nonisolated static func digitalDay(_ data: [String: Any], region: String) -> String? {
        let countries = data["results"] as? [[String: Any]] ?? []
        func day(_ code: String) -> String? {
            guard let country = countries.first(where: { ($0["iso_3166_1"] as? String)?.uppercased() == code }) else { return nil }
            return ((country["release_dates"] as? [[String: Any]]) ?? [])
                .filter { ($0["type"] as? NSNumber)?.intValue == 4 }
                .compactMap { ($0["release_date"] as? String).map { String($0.prefix(10)) } }.min()
        }
        return day(region) ?? day("US")
    }
    /// A show's next episode: a premiere (episode 1), a return after four weeks or more, or nothing.
    private static func showNews(_ tmdb: Int, token: String) async throws -> Found {
        let data = try await TMDBDirect.object("tv/\(tmdb)", query: [:], token: token)
        return showFound(data)
    }
    nonisolated static func showFound(_ data: [String: Any]) -> Found {
        guard let next = data["next_episode_to_air"] as? [String: Any], let day = (next["air_date"] as? String).map({ String($0.prefix(10)) }), !day.isEmpty else {
            return Found(day: nil, season: nil, kind: nil, fetchedAt: .now)
        }
        let season = (next["season_number"] as? NSNumber)?.intValue
        if (next["episode_number"] as? NSNumber)?.intValue == 1 { return Found(day: day, season: season, kind: "premiere", fetchedAt: .now) }
        let last = ((data["last_episode_to_air"] as? [String: Any])?["air_date"] as? String).map { String($0.prefix(10)) }
        if let last, let gap = days(from: last, to: day), gap >= 28 { return Found(day: day, season: season, kind: "return", fetchedAt: .now) }
        return Found(day: nil, season: nil, kind: nil, fetchedAt: .now)
    }

    /// Heads-ups for dates new since last time (none the very first time), then the day alerts
    /// for the nearest 20 (iOS keeps 64 alerts per app, shared with new-episode alerts).
    private static func schedule(_ releases: [Release], today: String, center: UNUserNotificationCenter, posters: [String: String?] = [:]) async {
        let first = UserDefaults.standard.object(forKey: seenKey) == nil
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        var told = 0
        for release in releases where !seen.contains(release.id) {
            seen.insert(release.id)
            guard !first, told < 5, release.day > today else { continue }
            told += 1
            let content = UNMutableNotificationContent()
            content.title = "Release date"; content.body = release.heads; content.threadIdentifier = release.titleId
            if let picture = await NotificationArtwork.attachment(posters[release.titleId] ?? nil) { content.attachments = [picture] }
            try? await center.add(UNNotificationRequest(identifier: release.id + "|heads", content: content, trigger: nil))
        }
        let live = Set(releases.map(\.id))
        UserDefaults.standard.set(Array(seen.intersection(live)), forKey: seenKey)
        let ids = await center.pendingNotificationRequests().map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("|heads") })
        // A show's new-episode alert that day already says it.
        let episodeDays = Set(ids.filter { $0.hasPrefix("episode|") })
        let calendar = DiaryDate.calendar()
        for release in releases.filter({ $0.alertOnDay && !episodeDays.contains("episode|\($0.titleId)|\($0.day)") }).sorted(by: { $0.day < $1.day }).prefix(20) {
            let parts = release.day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            var when = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9)
            when.calendar = calendar; when.timeZone = calendar.timeZone
            if let date = calendar.date(from: when), date <= .now { continue }
            let content = UNMutableNotificationContent()
            content.title = release.heading; content.body = release.body; content.sound = .default; content.threadIdentifier = release.titleId
            if let picture = await NotificationArtwork.attachment(posters[release.titleId] ?? nil) { content.attachments = [picture] }
            try? await center.add(UNNotificationRequest(identifier: release.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }

    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// "14 March 2027".
    private static func spoken(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = DiaryDate.calendar().date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return day }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
    nonisolated static func days(from start: String, to end: String) -> Int? {
        func date(_ day: String) -> Date? {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let a = date(start), let b = date(end) else { return nil }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }
}
