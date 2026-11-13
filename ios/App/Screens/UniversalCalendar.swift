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

    static func load(store: DiaryStore, days: Int, filter: Filter, genres: Set<String>, now: Date = .now) async throws -> [UniversalRelease] {
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(TimeInterval(days) * 86_400)
        let key = [DiaryDate.day(start), String(days), filter.rawValue, genres.sorted().joined(separator: ",")].joined(separator: "|")
        if let saved = cache[key], Date().timeIntervalSince(saved.at) < 1800 { return saved.items }
        guard let token = TMDBDirect.token(store) else { throw APIError.message(DiaryStore.needsTMDB) }
        var items: [UniversalRelease] = []
        if filter == .all || filter == .shows { items += try await shows(token: token, from: start, to: end, genres: genres, skipAnime: filter == .all) }
        if filter == .all || filter == .movies { items += try await movies(token: token, from: start, to: end, genres: genres) }
        if filter == .all || filter == .anime { items += (try? await anime(from: start, to: end, genres: genres)) ?? [] }
        items.sort { ($0.day, -$0.popularity) < ($1.day, -$1.popularity) }
        if cache.count > 12 { cache.removeAll() }
        cache[key] = (Date(), items)
        return items
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
        let genre = ids(genres, movie: false)
        // The days side by side, off the main actor (raw replies, read below).
        let replies = await withTaskGroup(of: (day: String, reply: Data?, error: String?).self) { group in
            for day in days {
                var query = ["air_date.gte": day, "air_date.lte": day, "sort_by": "popularity.desc", "page": "1", "include_null_first_air_dates": "false"]
                if let genre { query["with_genres"] = genre }
                group.addTask {
                    do { return (day, try await TMDBDirect.data("discover/tv", query: query, token: token), nil) }
                    catch { return (day, nil, error.localizedDescription) }
                }
            }
            var collected: [(day: String, reply: Data?, error: String?)] = []
            for await reply in group { collected.append(reply) }
            return collected
        }
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

    /// The episode a show airs on `day` ("S2 E5"), from its details, asked once per show and kept:
    /// only rows on screen ask.
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
        if episodeCache.count > 300 { episodeCache.removeAll() }
        episodeCache[id] = byDay
        return byDay[day]
    }

    /// TMDB's discover: movies first released in the window, most popular first.
    private static func movies(token: String, from start: Date, to end: Date, genres: Set<String>) async throws -> [UniversalRelease] {
        let first = dayText(start), last = dayText(end)
        var found: [UniversalRelease] = []
        for page in 1...2 {
            var query = ["primary_release_date.gte": first, "primary_release_date.lte": last, "sort_by": "popularity.desc", "page": String(page)]
            if let genre = ids(genres, movie: true) { query["with_genres"] = genre }
            let reply = try await TMDBDirect.object("discover/movie", query: query, token: token)
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

/// The calendar's Everything tab: type, genre and range filters, then each day's releases.
struct UniversalCalendarSection: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("calendar.everything.filter") private var filter = UniversalReleases.Filter.all
    @AppStorage("calendar.everything.days") private var days = 7
    @State private var genres: Set<String> = []
    @State private var showGenres = false
    @State private var items: [UniversalRelease]?
    @State private var failure: String?
    private var loadKey: String { [filter.rawValue, String(days), genres.sorted().joined(separator: ",")].joined(separator: "|") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            if let failure {
                RetryNotice(message: failure) { Task { await load() } }
            } else if let items {
                if items.isEmpty {
                    Text("Nothing releasing with these filters.").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).padding(.top, 8)
                } else { list(items) }
            } else { DiaryLoadingPlaceholder(height: 260, label: "Finding releases") }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showGenres) {
            CalendarGenreSheet(names: TMDBDirect.genreNames.map(\.name).sorted(), chosen: $genres)
        }
    }
    private func load() async {
        failure = nil
        do { items = try await UniversalReleases.load(store: store, days: days, filter: filter, genres: genres) }
        catch { if !Task.isCancelled { failure = error.localizedDescription; items = nil } }
    }

    private var controls: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Type", selection: $filter) { ForEach(UniversalReleases.Filter.allCases) { Text($0.rawValue).tag($0) } }
                } label: { pill(filter.rawValue, on: filter != .all) }
                Button { showGenres = true } label: {
                    pill(genres.isEmpty ? "All genres" : genres.count == 1 ? genres.first! : "\(genres.count) genres", on: !genres.isEmpty)
                }.buttonStyle(.plain)
                Menu {
                    Picker("Range", selection: $days) { ForEach([7, 14, 30], id: \.self) { Text("Next \($0) days").tag($0) } }
                } label: { pill("Next \(days) days", on: false) }
            }
        }.scrollIndicators(.hidden).accessibilityIdentifier("calendar-everything-filters")
    }
    private func pill(_ text: String, on: Bool) -> some View {
        HStack(spacing: 6) { Text(text).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
            .font(.system(size: 13, weight: .bold)).foregroundStyle(on ? theme.accent : HomeStyle.chipText)
            .padding(.horizontal, 12).frame(height: 32).background(on ? theme.accent.opacity(0.16) : HomeStyle.chip, in: Capsule())
    }

    @ViewBuilder private func list(_ items: [UniversalRelease]) -> some View {
        let days = Dictionary(grouping: items, by: \.day)
        let inDiary = Set(store.workspace.activeTitles.compactMap { title in title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } })
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(days.keys.sorted(), id: \.self) { day in
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.heading(day)).font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.secondary).textCase(.uppercase)
                    VStack(spacing: 0) {
                        let rows = days[day] ?? []
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider().padding(.leading, 74) }
                            row(item, saved: item.route.map { (($0.kind == .tv) ? "tv:" : "movie:") + String($0.id) }.map(inDiary.contains) ?? false)
                        }
                    }.modifier(SettingsCard())
                }
            }
        }
    }
    @ViewBuilder private func row(_ item: UniversalRelease, saved: Bool) -> some View {
        let label = HStack(spacing: 12) {
            Artwork(path: item.poster, title: item.name, initialsOnly: false).frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                ReleaseSubtitle(item: item)
            }
            Spacer(minLength: 8)
            if saved {
                Text("In diary").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
                    .padding(.horizontal, 8).frame(height: 22).background(theme.accent.opacity(0.16), in: Capsule())
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
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

/// "Show · S2 E5", "Movie", "Anime · Episode 7 · 9:30 PM". A show's episode number is read when
/// its row comes on screen (one small request per show, kept), so opening the tab stays light.
private struct ReleaseSubtitle: View {
    let item: UniversalRelease
    @Environment(DiaryStore.self) private var store
    @State private var episode: String?
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            .task(id: item.id) {
                guard item.kind == .show, episode == nil, let id = item.route?.id else { return }
                episode = await UniversalReleases.episode(show: id, day: item.day, store: store)
            }
    }
    private var text: String {
        switch item.kind {
        case .movie: return "Movie"
        case .show: return "Show · " + (episode ?? item.detail)
        case .anime:
            var parts = ["Anime", item.detail]
            if let time = item.time { parts.append(time.formatted(date: .omitted, time: .shortened)) }
            return parts.joined(separator: " · ")
        }
    }
}
