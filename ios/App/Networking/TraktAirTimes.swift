import Foundation
import Observation
import TwilDiaryCore

/// The hour your shows' next episodes air, from Trakt's calendar (TMDB gives only the day). Read
/// once every six hours, and only with Trakt signed in on this iPhone; without it the calendar
/// shows the day alone, as before.
@MainActor @Observable final class TraktAirTimes {
    static let shared = TraktAirTimes()
    private static let storeKey = "trakt.airTimes"
    private struct Saved: Codable { let fetchedAt: Date; let times: [String: Date] }

    private(set) var times: [String: Date] = [:]
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var tried: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            times = saved.times; fetchedAt = saved.fetchedAt
        }
    }

    nonisolated static func key(tmdb: Int, season: Int, number: Int) -> String { "tv:\(tmdb):\(season):\(number)" }

    func time(for item: UpcomingSchedule.Item) -> Date? {
        guard let tmdb = item.title.tmdbId else { return nil }
        return times[Self.key(tmdb: tmdb, season: item.episode.season, number: item.episode.number)]
    }

    func refresh(store: DiaryStore) async {
        guard !store.isPreview, store.traktSignedInOnPhone else { return }
        let now = Date()
        if let fetchedAt, fetchedAt <= now, now.timeIntervalSince(fetchedAt) < 6 * 3_600 { return }
        // A failed read waits ten minutes before the next try.
        if let tried, now.timeIntervalSince(tried) < 600 { return }
        tried = now
        var format = Date.ISO8601FormatStyle().year().month().day()
        format.timeZone = .gmt
        let start = format.format(now.addingTimeInterval(-86_400))
        guard let client = try? await TraktDirectStore.shared.client(store: store),
              let reply = try? await client.get("/calendars/my/shows/\(start)/16") else { return }
        times = Self.decode(reply.data)
        fetchedAt = now
        if let data = try? JSONEncoder().encode(Saved(fetchedAt: now, times: times)) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    /// Trakt's calendar rows: `first_aired` (UTC), the episode's season and number, the show's TMDB id.
    nonisolated static func decode(_ data: Data) -> [String: Date] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true), plain = Date.ISO8601FormatStyle()
        var out: [String: Date] = [:]
        for row in rows {
            guard let aired = row["first_aired"] as? String, let when = (try? fractional.parse(aired)) ?? (try? plain.parse(aired)),
                  let episode = row["episode"] as? [String: Any], let season = episode["season"] as? Int, let number = episode["number"] as? Int,
                  let show = row["show"] as? [String: Any], let ids = show["ids"] as? [String: Any], let tmdb = ids["tmdb"] as? Int
            else { continue }
            out[key(tmdb: tmdb, season: season, number: number)] = when
        }
        return out
    }
}
