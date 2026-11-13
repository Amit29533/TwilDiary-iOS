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

    /// TMDB's discover: shows with an episode airing in the window, most popular first; each one's
    /// next (or just-aired) episode from its details, for the day and the episode number.
    private static func shows(token: String, from start: Date, to end: Date, genres: Set<String>, skipAnime: Bool) async throws -> [UniversalRelease] {
        let first = dayText(start), last = dayText(end)
        var results: [[String: Any]] = []
        for page in 1...2 {
            var query = ["air_date.gte": first, "air_date.lte": last, "sort_by": "popularity.desc", "page": String(page), "include_null_first_air_dates": "false"]
            if let genre = ids(genres, movie: false) { query["with_genres"] = genre }
            let reply = try await TMDBDirect.object("discover/tv", query: query, token: token)
            results += reply["results"] as? [[String: Any]] ?? []
        }
        // With anime shown from AniList, Japanese animation from TMDB would be listed twice.
        if skipAnime { results.removeAll { ($0["original_language"] as? String) == "ja" && (($0["genre_ids"] as? [Int]) ?? []).contains(16) } }
        let picked = Array(results.prefix(40))
        var found: [UniversalRelease] = []
        await withTaskGroup(of: UniversalRelease?.self) { group in
            for item in picked {
                guard let id = item["id"] as? Int, let catalog = TMDBDirect.catalogItem(item, kind: .tv) else { continue }
                let popularity = item["popularity"] as? Double ?? 0
                group.addTask { @MainActor in
                    guard let details = try? await TMDBDirect.object("tv/\(id)", query: [:], token: token) else { return nil }
                    let episodes = [details["next_episode_to_air"], details["last_episode_to_air"]].compactMap { $0 as? [String: Any] }
                    guard let episode = episodes.first(where: { ($0["air_date"] as? String).map { $0 >= first && $0 < last } ?? false }),
                          let day = episode["air_date"] as? String else { return nil }
                    let season = episode["season_number"] as? Int ?? 0, number = episode["episode_number"] as? Int ?? 0
                    return UniversalRelease(id: "tv:\(id):\(season):\(number)", kind: .show, name: catalog.name, poster: catalog.artwork, day: day,
                                            time: nil, detail: season == 0 ? "Special \(number)" : "S\(season) E\(number)",
                                            route: CatalogRoute(kind: .tv, id: id), anime: nil, genres: catalog.genres ?? [], popularity: popularity)
                }
            }
            for await item in group { if let item { found.append(item) } }
        }
        return found
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
                Text(subtitle(item)).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
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
    private func subtitle(_ item: UniversalRelease) -> String {
        let kind = item.kind == .anime ? "Anime" : item.kind == .movie ? "Movie" : "Show"
        var parts = [item.kind == .movie ? kind : kind + " · " + item.detail]
        if let time = item.time { parts.append(time.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
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
