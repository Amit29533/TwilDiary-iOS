import SwiftUI
import TwilDiaryCore

/// One release on the calendar's Everything view: a TV episode, a movie or an anime episode,
/// whether or not it's in your diary.
struct UniversalRelease: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case show, movie, anime }
    let id: String
    let kind: Kind
    let name: String
    let poster: String?
    /// "2026-11-17", local day.
    let day: String
    /// AniList's exact airing time (TV and movies come with a day only).
    let time: Date?
    let detail: String
    let route: CatalogRoute?
    let anime: AniAppearance?
    let genres: [String]
    let popularity: Double
}

/// Everything releasing in the next days (owner's request: a universal calendar, not only the
/// diary's shows): TV episodes and movies from TMDB (most popular first, with your genres), anime
/// from AniList's airing schedule. Kept for half an hour per set of filters.
@MainActor enum UniversalReleases {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All types", shows = "Shows", movies = "Movies", anime = "Anime"
        var id: String { rawValue }
    }
    private static var cache: [String: (at: Date, items: [UniversalRelease])] = [:]

    /// Releases from `offset` days after today, for `days` days.
    static func load(store: DiaryStore, offset: Int = 0, days: Int, filter: Filter, genres: Set<String>, now: Date = .now) async throws -> [UniversalRelease] {
        let today = Calendar.current.startOfDay(for: now)
        let start = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today.addingTimeInterval(TimeInterval(offset) * 86_400)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(TimeInterval(days) * 86_400)
        let key = [DiaryDate.day(start), String(days), filter.rawValue, genres.sorted().joined(separator: ",")].joined(separator: "|")
        if let saved = cache[key], Date().timeIntervalSince(saved.at) < 1800 { return saved.items }
        guard let token = TMDBDirect.token(store) else { throw APIError.message(DiaryStore.needsTMDB) }
        var items: [UniversalRelease] = []
        if filter == .all || filter == .shows { items += try await shows(token: token, from: start, to: end, genres: genres, skipAnime: filter == .all) }
        if filter == .all || filter == .movies { items += try await movies(token: token, from: start, to: end, genres: genres) }
        if filter == .all || filter == .anime { items += (try? await anime(from: start, to: end, genres: genres)) ?? [] }
        items = unique(items)
        items.sort { ($0.day, -$0.popularity) < ($1.day, -$1.popularity) }
        if cache.count > 12 { cache.removeAll() }
        cache[key] = (Date(), items)
        return items
    }

    /// Each release once: TMDB's two pages of a list can repeat a title, and the lazy list showing
    /// them stops the app when two rows share an id (owner's report: Everything crashed).
    nonisolated static func unique(_ items: [UniversalRelease]) -> [UniversalRelease] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
    private static func ids(_ genres: Set<String>, movie: Bool) -> String? {
        let ids = TMDBDirect.genreNames.filter { genres.contains($0.name) }.compactMap { movie ? $0.movie : $0.tv }
        return ids.isEmpty ? nil : ids.map(String.init).joined(separator: "|")
    }
    private static func dayText(_ date: Date) -> String { DiaryDate.day(date) }

    /// TMDB's discover, one request per day: the shows with an episode that day, most popular first
    /// (owner's request: fewer requests than asking each show for its next episode). A weekly show
    /// is listed on each day it airs. The episode number is read only for rows you scroll to.
    private static func shows(token: String, from start: Date, to end: Date, genres: Set<String>, skipAnime: Bool) async throws -> [UniversalRelease] {
        var days: [String] = []
        var date = start
        while date < end, days.count < 31 {
            days.append(dayText(date))
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? end
        }
        let replies = await discoverDays(days, genre: ids(genres, movie: false), token: token)
        var found: [UniversalRelease] = []
        var failure: String?
        for (day, reply, error) in replies {
            guard let reply, let root = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { failure = failure ?? error; continue }
            var results = root["results"] as? [[String: Any]] ?? []
            // With anime shown from AniList, Japanese animation from TMDB would be listed twice.
            if skipAnime { results.removeAll { ($0["original_language"] as? String) == "ja" && (($0["genre_ids"] as? [Int]) ?? []).contains(16) } }
            for item in results.prefix(15) {
                guard let id = item["id"] as? Int, let catalog = TMDBDirect.catalogItem(item, kind: .tv) else { continue }
                found.append(UniversalRelease(id: "tv:\(id):\(day)", kind: .show, name: catalog.name, poster: catalog.artwork, day: day, time: nil,
                                              detail: "New episode", route: CatalogRoute(kind: .tv, id: id), anime: nil,
                                              genres: catalog.genres ?? [], popularity: item["popularity"] as? Double ?? 0))
            }
        }
        // Every day refused (offline, a bad key): said, rather than an empty calendar.
        if found.isEmpty, let failure { throw APIError.message(failure) }
        return found
    }

    /// TMDB's discover for each day, side by side, with no Swift child tasks: plain URLSession
    /// requests whose replies are gathered under a lock and handed back once. The owner's phone
    /// (iOS 27 beta) crashed here twice inside Swift's task completion while the day requests ran
    /// as a task group, which the simulator never reproduced.
    nonisolated static func discoverDays(_ days: [String], genre: String?, token: String, session: URLSession = .shared) async -> [(day: String, reply: Data?, error: String?)] {
        guard !days.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            let replies = DayReplies(count: days.count) { continuation.resume(returning: $0) }
            for day in days {
                var query = ["air_date.gte": day, "air_date.lte": day, "sort_by": "popularity.desc", "page": "1", "include_null_first_air_dates": "false"]
                if let genre { query["with_genres"] = genre }
                guard let request = try? TMDBDirect.request("discover/tv", query: query, token: token) else {
                    replies.add((day, nil, "Invalid TMDB request.")); continue
                }
                session.dataTask(with: request) { data, response, error in
                    if let error { replies.add((day, nil, error.localizedDescription)); return }
                    do { replies.add((day, try TMDBDirect.checked(data ?? Data(), response), nil)) }
                    catch { replies.add((day, nil, error.localizedDescription)) }
                }.resume()
            }
        }
    }

    /// The episode a show airs on `day` ("S2 E5"), from its details (and, for a later week, its
    /// season's episode list), asked once per show and kept: only rows on screen ask.
    private static var episodeCache: [Int: [String: String]] = [:]
    static func episode(show id: Int, day: String, store: DiaryStore) async -> String? {
        if let known = episodeCache[id] { return known[day] }
        guard let token = TMDBDirect.token(store), let details = try? await TMDBDirect.object("tv/\(id)", query: [:], token: token) else { return nil }
        var byDay: [String: String] = [:]
        for episode in [details["last_episode_to_air"], details["next_episode_to_air"]].compactMap({ $0 as? [String: Any] }) {
            guard let date = episode["air_date"] as? String else { continue }
            let season = episode["season_number"] as? Int ?? 0, number = episode["episode_number"] as? Int ?? 0
            byDay[date] = season == 0 ? "Special \(number)" : "S\(season) E\(number)"
        }
        // A later week of the season (TMDB's details name only the last and next episode): the
        // season's whole episode list, once, so every row of this show gets its number.
        if byDay[day] == nil,
           let season = ((details["next_episode_to_air"] as? [String: Any]) ?? (details["last_episode_to_air"] as? [String: Any]))?["season_number"] as? Int,
           let list = try? await TMDBDirect.object("tv/\(id)/season/\(season)", query: [:], token: token) {
            for episode in list["episodes"] as? [[String: Any]] ?? [] {
                guard let date = episode["air_date"] as? String, let number = episode["episode_number"] as? Int, byDay[date] == nil else { continue }
                byDay[date] = season == 0 ? "Special \(number)" : "S\(season) E\(number)"
            }
        }
        if episodeCache.count > 300 { episodeCache.removeAll() }
        episodeCache[id] = byDay
        return byDay[day]
    }

    /// TMDB's discover: movies first released in the window, most popular first.
    private static func movies(token: String, from start: Date, to end: Date, genres: Set<String>) async throws -> [UniversalRelease] {
        let first = dayText(start), last = dayText(end)
        var found: [UniversalRelease] = []
        var lastPage = false
        for page in 1...2 where !lastPage {
            var query = ["primary_release_date.gte": first, "primary_release_date.lte": last, "sort_by": "popularity.desc", "page": String(page)]
            if let genre = ids(genres, movie: true) { query["with_genres"] = genre }
            let reply = try await TMDBDirect.object("discover/movie", query: query, token: token)
            if (reply["total_pages"] as? Int ?? 1) <= page { lastPage = true }
            for item in reply["results"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? Int, let catalog = TMDBDirect.catalogItem(item, kind: .movie),
                      let day = item["release_date"] as? String, day >= first, day < last else { continue }
                found.append(UniversalRelease(id: "movie:\(id)", kind: .movie, name: catalog.name, poster: catalog.artwork, day: day, time: nil,
                                              detail: "Movie", route: CatalogRoute(kind: .movie, id: id), anime: nil,
                                              genres: catalog.genres ?? [], popularity: item["popularity"] as? Double ?? 0))
            }
        }
        return found
    }

    /// AniList's airing schedule; your genres matched by their words ("Action & adventure" → Action
    /// or Adventure, "Sci-fi & fantasy" → Sci-Fi or Fantasy).
    private static func anime(from start: Date, to end: Date, genres: Set<String>) async throws -> [UniversalRelease] {
        let words = Set(genres.flatMap { $0.lowercased().components(separatedBy: " & ") })
        let slots = try await AniListClient.shared.airing(from: start, to: end)
        // Their TMDB links in one request, ahead of a tap.
        Task.detached(priority: .utility) { await WikidataAnime.shared.routes(slots.map { WikidataAnime.Anime(id: $0.appearance.id, format: $0.appearance.format) }) }
        return slots.compactMap { slot in
            if !words.isEmpty, !slot.genres.contains(where: { words.contains($0.lowercased()) }) { return nil }
            return UniversalRelease(id: "anime:\(slot.appearance.id):\(slot.episode)", kind: .anime, name: slot.appearance.title,
                                    poster: slot.appearance.cover, day: dayText(slot.airsAt), time: slot.airsAt,
                                    detail: "Episode \(slot.episode)", route: nil, anime: slot.appearance, genres: slot.genres,
                                    popularity: Double(slot.popularity))
        }
    }
}

/// Collects one reply per day from URLSession's own threads and hands them over once, when the last arrives.
private final class DayReplies: @unchecked Sendable {
    typealias Reply = (day: String, reply: Data?, error: String?)
    private let lock = NSLock()
    private var collected: [Reply] = []
    private let count: Int
    private var finish: (([Reply]) -> Void)?
    init(count: Int, finish: @escaping @Sendable ([Reply]) -> Void) { self.count = count; self.finish = finish }
    func add(_ reply: Reply) {
        lock.lock()
        collected.append(reply)
        let done = collected.count == count ? finish : nil
        if done != nil { finish = nil }
        let all = collected
        lock.unlock()
        done?(all)
    }
}

/// The calendar's Everything tab: type, genre and range filters, then each day's releases.
struct UniversalCalendarSection: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("calendar.everything.filter") private var filter = UniversalReleases.Filter.all
    @AppStorage("calendar.everything.days") private var days = 7
    @State private var genres: Set<String> = []
    @State private var showGenres = false
    @State private var items: [UniversalRelease]?
    @State private var failure: String?
    /// Later days still coming in, and why they stopped if they did.
    @State private var loadingMore = false
    @State private var moreFailure: String?
    /// Each load's number: an older load that's still finishing leaves the screen alone.
    @State private var generation = 0
    private var loadKey: String { [filter.rawValue, String(days), genres.sorted().joined(separator: ",")].joined(separator: "|") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            if let failure {
                RetryNotice(message: failure) { Task { await load() } }
            } else if let items {
                if items.isEmpty && !loadingMore {
                    Text("Nothing releasing with these filters.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).padding(.top, 8)
                } else { list(items) }
                if loadingMore {
                    HStack(spacing: 8) { ProgressView(); Text("Loading later days").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary) }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                } else if let moreFailure {
                    RetryNotice(message: "Later days couldn’t be loaded. " + moreFailure) { Task { await load() } }
                }
            } else { DiaryLoadingPlaceholder(height: 260, label: "Finding releases") }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showGenres) {
            CalendarGenreSheet(names: TMDBDirect.genreNames.map(\.name).sorted(), chosen: $genres)
        }
    }
    /// Today and tomorrow first, then a week at a time, each shown as it arrives: a few requests at
    /// once instead of the whole range together.
    private func load() async {
        generation += 1
        let mine = generation, steps = Self.steps(days)
        failure = nil; moreFailure = nil
        loadingMore = steps.count > 1 && items != nil
        var collected: [UniversalRelease] = []
        for (index, step) in steps.enumerated() {
            do {
                let part = try await UniversalReleases.load(store: store, offset: step.offset, days: step.days, filter: filter, genres: genres)
                guard mine == generation, !Task.isCancelled else { return }
                collected = UniversalReleases.unique(collected + part)
                items = collected
                loadingMore = index < steps.count - 1
            } catch {
                guard mine == generation, !Task.isCancelled else { return }
                if index == 0 { failure = error.localizedDescription; items = nil } else { moreFailure = error.localizedDescription }
                loadingMore = false
                return
            }
        }
    }
    /// The range in steps: the first two days, then weeks.
    static func steps(_ days: Int) -> [(offset: Int, days: Int)] {
        var steps: [(offset: Int, days: Int)] = [], offset = 0
        while offset < days {
            let size = offset == 0 ? min(2, days) : min(7, days - offset)
            steps.append((offset, size)); offset += size
        }
        return steps
    }

    /// The other tabs' filters: type and genres on the left, the range on the right.
    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Type", selection: $filter) { ForEach(UniversalReleases.Filter.allCases) { Text($0.rawValue).tag($0) } }
            } label: { CalendarStyle.pill(filter.rawValue, active: filter != .all) }
            Button { showGenres = true } label: {
                CalendarStyle.pill(genres.isEmpty ? "Genres" : genres.count == 1 ? genres.first! : "\(genres.count) genres", active: !genres.isEmpty)
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            Menu {
                Picker("Range", selection: $days) { ForEach([1, 7, 14, 30], id: \.self) { Text(Self.range($0)).tag($0) } }
            } label: { CalendarStyle.pill(Self.range(days), active: days == 1) }
        }.accessibilityIdentifier("calendar-everything-filters")
    }
    static func range(_ days: Int) -> String { days == 1 ? "Today" : "Next \(days) days" }

    @ViewBuilder private func list(_ items: [UniversalRelease]) -> some View {
        let days = Dictionary(grouping: items, by: \.day)
        let inDiary = Set(store.workspace.activeTitles.compactMap { title in title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } })
        // As the other tabs: a heading with its count per day, then plain rows.
        ForEach(days.keys.sorted(), id: \.self) { day in
            let rows = days[day] ?? []
            LazyVStack(alignment: .leading, spacing: 16) {
                CalendarStyle.heading(Self.heading(day), rows.count)
                ForEach(rows) { item in
                    row(item, saved: item.route.map { (($0.kind == .tv) ? "tv:" : "movie:") + String($0.id) }.map(inDiary.contains) ?? false)
                }
            }
        }
    }
    @ViewBuilder private func row(_ item: UniversalRelease, saved: Bool) -> some View {
        let label = ReleaseRow(item: item, saved: saved)
        if let route = item.route {
            NavigationLink(value: route) { label }.buttonStyle(.plain).accessibilityIdentifier("everything-" + item.id)
        } else if let anime = item.anime {
            AnimeAppearanceButton(appearance: anime) { label }.buttonStyle(.plain).accessibilityIdentifier("everything-" + item.id)
        }
    }
    static func heading(_ day: String, now: Date = .now) -> String {
        let today = DiaryDate.day(now)
        if day == today { return "Today" }
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now), day == DiaryDate.day(tomorrow) { return "Tomorrow" }
        let parser = DateFormatter(); parser.calendar = Calendar(identifier: .gregorian); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// A release in the other tabs' row layout: "Fri 20 Nov · 9:30 PM" on top with how far away it is
/// (and "In diary"), the name, then "Anime · Episode 7", "Show · S2 E5" or "Movie" in lilac. A
/// show's episode number and time are read when its row comes on screen (one small request per
/// show, kept), so opening the tab stays light.
private struct ReleaseRow: View {
    let item: UniversalRelease
    let saved: Bool
    @Environment(DiaryStore.self) private var store
    @State private var episode: String?
    var body: some View {
        CalendarStyle.row(poster: item.poster, name: item.name, when: when, line: line) {
            if saved { CalendarStyle.badge("In diary", strong: true) }
            CalendarStyle.badge(CalendarStyle.away(daysAway))
        } extra: { EmptyView() }
            .task(id: item.id) {
                guard item.kind == .show, let id = item.route?.id else { return }
                if episode == nil { episode = await UniversalReleases.episode(show: id, day: item.day, store: store) }
                await EpisodeAirTimes.shared.load(tmdb: id, day: item.day, store: store)
            }
    }
    private var date: Date? {
        let parser = DateFormatter(); parser.calendar = Calendar(identifier: .gregorian); parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: item.day)
    }
    private var time: Date? {
        if let time = item.time { return time }
        guard item.kind == .show, let id = item.route?.id else { return nil }
        return EpisodeAirTimes.shared.time(tmdb: id, day: item.day)
    }
    private var when: String {
        let day = (time ?? date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? item.day
        return time.map { day + " · " + $0.formatted(date: .omitted, time: .shortened) } ?? day
    }
    private var daysAway: Int {
        let calendar = Calendar.current
        guard let at = time ?? date else { return 0 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: store.now), to: calendar.startOfDay(for: at)).day ?? 0
    }
    private var line: String {
        switch item.kind {
        case .movie: "Movie"
        case .show: "Show · " + (episode ?? item.detail)
        case .anime: "Anime · " + item.detail
        }
    }
}
