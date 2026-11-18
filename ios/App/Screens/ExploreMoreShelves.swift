import SwiftUI
import TwilDiaryCore

// Explore's extra rows: one-tap AI prompts, CineMind's movie and show picks, Because you loved,
// Trending from your Planned, this season's anime and Coming soon. Their data lives in
// `ExploreFeeds`, read once a day (or once a session), so leaving Explore and coming back shows
// the same rows straight away instead of loading them again. None show in the UI-test fixture.

// MARK: Data

/// What Explore's extra rows show, kept for the session (CineMind's picks also on the phone for
/// the day), so the page doesn't reload, reshuffle or jump when you come back to it.
@MainActor @Observable final class ExploreFeeds {
    static let shared = ExploreFeeds()

    struct Feed<Item> {
        var items: [Item] = []
        var loading = false
        /// The day (or session) it was read for; nil: not read yet.
        var loadedFor: String?
        var failure: String?
    }
    struct Upcoming: Identifiable, Hashable, Sendable {
        let item: CatalogItem
        let day: String
        let season: Int?
        var id: String { item.key }
    }

    var cineMovies = Feed<CatalogItem>()
    var cineShows = Feed<CatalogItem>()
    var loved = Feed<CatalogItem>()
    var lovedSeed: MediaTitle?
    var trending = Feed<CatalogItem>()
    var seasonal = Feed<SeasonalAnime>()
    var comingMovies = Feed<Upcoming>()
    var comingShows = Feed<Upcoming>()

    private func day(_ store: DiaryStore) -> String { DiaryDate.day(store.now) }

    // MARK: CineMind

    private struct SavedPicks: Codable { let day: String; let picks: [Pick] }
    private struct Pick: Codable {
        let tmdb: Int; let movie: Bool; let name: String; let year: Int?; let poster: String?
        var item: CatalogItem { CatalogItem(id: tmdb, mediaType: movie ? .movie : .tv, name: name, year: year, poster: poster) }
    }
    private func storageKey(_ movies: Bool) -> String { "cinemind.picks.v2." + (movies ? "movies" : "shows") }

    /// CineMind's picks for your taste: up to 25 of the titles you finished or are watching, best
    /// rated first (names, years and your ratings), and the names of titles of that kind already in
    /// your library so it suggests something new. Once a day, kept on the phone; `force` asks again.
    func loadCineMind(movies: Bool, store: DiaryStore, force: Bool = false) async {
        let today = day(store)
        var feed = movies ? cineMovies : cineShows
        if !force {
            if feed.loadedFor == today || feed.loading { return }
            if let data = UserDefaults.standard.data(forKey: storageKey(movies)),
               let saved = try? JSONDecoder().decode(SavedPicks.self, from: data) {
                feed.items = saved.picks.map(\.item)
                if saved.day == today { feed.loadedFor = today; set(movies, feed); return }
            }
        }
        guard SemanticSearch.key != nil else { feed.loadedFor = today; set(movies, feed); return }
        let titles = store.workspace.activeTitles
        let taste = titles.filter { ["completed", "watching", "paused"].contains($0.status) }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(25)
            .map { title in [title.name + (title.year.map { " (\($0))" } ?? ""), title.score.map { "\(Int($0.rounded()))/10" }].compactMap { $0 }.joined(separator: " · ") }
        guard taste.count >= 3 else { feed.loadedFor = today; set(movies, feed); return }
        let have = titles.filter { $0.isSeries != movies }.prefix(200).map(\.name)
        feed.loading = true; feed.failure = nil; set(movies, feed)
        do {
            let found = try await SemanticSearch.recommendations(movies: movies, taste: Array(taste), exclude: Array(have), store: store)
            let picks = found.map { Pick(tmdb: $0.item.id, movie: $0.item.mediaType == .movie, name: $0.item.name, year: $0.item.year, poster: $0.item.artwork) }
            feed.items = picks.map(\.item)
            UserDefaults.standard.set(try? JSONEncoder().encode(SavedPicks(day: today, picks: picks)), forKey: storageKey(movies))
        } catch {
            if feed.items.isEmpty { feed.failure = error.localizedDescription }
        }
        feed.loading = false; feed.loadedFor = today
        set(movies, feed)
    }
    private func set(_ movies: Bool, _ feed: Feed<CatalogItem>) { if movies { cineMovies = feed } else { cineShows = feed } }

    // MARK: Because you loved

    /// TMDB's recommendations for one of your best-rated finished titles, a different one each day.
    func loadLoved(store: DiaryStore) async {
        let today = day(store)
        guard loved.loadedFor != today, !loved.loading else { return }
        loved.loading = true
        defer { loved.loading = false; loved.loadedFor = today }
        let best = store.workspace.activeTitles.filter { $0.status == "completed" && $0.tmdbId != nil && ($0.score ?? 0) >= 7 }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(10)
        guard !best.isEmpty else { return }
        let start = (Int(today.filter(\.isNumber)) ?? 0) % best.count
        let order = Array(best.dropFirst(start)) + Array(best.prefix(start))
        for candidate in order.prefix(3) {
            guard let tmdb = candidate.tmdbId,
                  let related = try? await store.related(CatalogRoute(kind: candidate.isSeries ? .tv : .movie, id: tmdb)) else { continue }
            let found = related.items.filter { store.libraryIdentity($0) == nil }
            if found.count >= 3 { lovedSeed = candidate; loved.items = found; return }
        }
    }

    // MARK: Trending from your Planned

    func loadTrending(store: DiaryStore) async {
        let today = day(store)
        guard trending.loadedFor != today, !trending.loading, let token = TMDBDirect.token(store) else { return }
        let planned = store.workspace.activeTitles.filter { $0.status == "planned" && $0.tmdbId != nil }
        guard !planned.isEmpty else { trending.loadedFor = today; return }
        trending.loading = true
        defer { trending.loading = false; trending.loadedFor = today }
        var ranks: [String: Int] = [:]
        for page in 1...3 {
            guard let data = try? await TMDBDirect.object("trending/all/week", query: ["page": String(page), "language": "en-US"], token: token),
                  let results = data["results"] as? [[String: Any]] else { break }
            for (offset, row) in results.enumerated() {
                guard let id = row["id"] as? Int, let type = row["media_type"] as? String, type == "movie" || type == "tv" else { continue }
                let key = type + ":" + String(id)
                if ranks[key] == nil { ranks[key] = (page - 1) * 20 + offset + 1 }
            }
        }
        trending.items = planned.compactMap { title -> (CatalogItem, Int)? in
            guard let tmdb = title.tmdbId, let rank = ranks[(title.isSeries ? "tv:" : "movie:") + String(tmdb)] else { return nil }
            return (CatalogItem(id: tmdb, mediaType: title.isSeries ? .tv : .movie, name: title.name, year: title.year, rating: title.communityScore,
                                inLibraryId: title.id, poster: title.poster, backdrop: title.backdrop), rank)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: This season's anime

    func loadSeasonal(store: DiaryStore) async {
        let (season, year) = SeasonalAnime.Season.of(store.now)
        let key = "\(season.rawValue)\(year)"
        guard seasonal.loadedFor != key, !seasonal.loading else { return }
        seasonal.loading = true
        defer { seasonal.loading = false }
        do { seasonal.items = try await AniListClient.shared.seasonal(season, year: year); seasonal.loadedFor = key }
        catch { seasonal.failure = "This season's anime couldn't be loaded." }
    }

    // MARK: Coming soon

    /// Upcoming movies in your region (TMDB), and season premieres, new shows and returning ones,
    /// from Trakt's premieres calendar (the most followed first), each with its TMDB poster.
    func loadComing(store: DiaryStore) async {
        let today = day(store)
        guard comingMovies.loadedFor != today, !comingMovies.loading else { return }
        guard let token = TMDBDirect.token(store) else {
            comingMovies.failure = "Coming soon needs TMDB, which isn’t set up."; comingShows.failure = comingMovies.failure
            comingMovies.loadedFor = today; comingShows.loadedFor = today; return
        }
        comingMovies.loading = true; comingShows.loading = true
        let region = (UserDefaults.standard.string(forKey: "streamingRegion") ?? Locale.current.region?.identifier ?? "US").uppercased()
        let calendar = Calendar(identifier: .gregorian)
        func dayString(_ offset: Int) -> String { DiaryDate.day(calendar.date(byAdding: .day, value: offset, to: store.now) ?? store.now) }
        let movieData = try? await TMDBDirect.object("discover/movie", query: [
            "primary_release_date.gte": dayString(1), "primary_release_date.lte": dayString(90), "region": region,
            "with_release_type": "2|3", "sort_by": "popularity.desc", "language": "en-US", "include_adult": "false"], token: token)
        comingMovies.items = ((movieData?["results"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let item = TMDBDirect.catalogItem(row, kind: .movie), let date = row["release_date"] as? String, date.count >= 10 else { return nil }
            return Upcoming(item: item, day: String(date.prefix(10)), season: nil)
        }.sorted { $0.day < $1.day }
        comingMovies.loading = false; comingMovies.loadedFor = today
        if comingMovies.items.isEmpty { comingMovies.failure = "No upcoming movies could be loaded." }

        let premieres = await Self.traktPremieres(from: dayString(0), days: 45)
        let found = await withTaskGroup(of: Upcoming?.self) { group in
            for premiere in premieres.prefix(24) {
                group.addTask { await Self.poster(for: premiere, token: token) }
            }
            var rows: [Upcoming] = []
            for await row in group { if let row { rows.append(row) } }
            return rows
        }
        comingShows.items = found.sorted { $0.day < $1.day }
        comingShows.loading = false; comingShows.loadedFor = today
        if comingShows.items.isEmpty { comingShows.failure = "No upcoming shows could be loaded." }
    }

    struct Premiere: Sendable { let tmdb: Int; let day: String; let season: Int; let votes: Int }
    /// Trakt's season premieres (a new show's first season, or a returning one's next) in the
    /// coming days, most followed first. Trakt's public calendar needs only TwilDiary's app ID.
    private static func traktPremieres(from start: String, days: Int) async -> [Premiere] {
        guard let clientID = ProviderAppIDs.id(for: .trakt),
              let url = URL(string: "https://api.trakt.tv/calendars/all/shows/premieres/\(start)/\(days)?extended=full") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var seen = Set<Int>()
        return rows.compactMap { row -> Premiere? in
            guard let show = row["show"] as? [String: Any], let ids = show["ids"] as? [String: Any], let tmdb = ids["tmdb"] as? Int, tmdb > 0,
                  let aired = row["first_aired"] as? String, let episode = row["episode"] as? [String: Any],
                  let season = episode["season"] as? Int, season > 0, seen.insert(tmdb).inserted else { return nil }
            let date = ISO8601DateFormatter.flexible(aired).map { DiaryDate.day($0) } ?? String(aired.prefix(10))
            return Premiere(tmdb: tmdb, day: date, season: season, votes: show["votes"] as? Int ?? 0)
        }.sorted { $0.votes > $1.votes }
    }
    private static func poster(for premiere: Premiere, token: String) async -> Upcoming? {
        guard let details = try? await TMDBDirect.object("tv/\(premiere.tmdb)", query: ["language": "en-US"], token: token),
              let item = TMDBDirect.catalogItem(details, kind: .tv) else { return nil }
        return Upcoming(item: item, day: premiere.day, season: premiere.season)
    }
}

private extension ISO8601DateFormatter {
    /// Trakt's times, with or without fractions of a second.
    static func flexible(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: Shared pieces

/// The app's standard poster tile (as `CatalogPoster`): the poster, its name and one line under it.
struct StandardPoster: View {
    let artwork: String?
    let name: String
    let subtitle: String
    var score: Double? = nil
    var subtitleTint: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: artwork, title: name, initialsOnly: false)
                .posterAspect()
                .overlay(alignment: .bottomLeading) {
                    if let score, score > 0 {
                        HStack(spacing: 5) { Image(systemName: "star.fill").font(.system(size: 13)); Text(String(format: "%.1f", score)).frame(height: 18) }
                            .font(.system(size: 12)).foregroundStyle(Color(themed: "#e7ca90"))
                            .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6)).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).frame(minHeight: 20.25).padding(.top, 8)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(subtitleTint).lineLimit(1).frame(height: 18).padding(.top, 4)
        }.accessibilityElement(children: .combine)
    }
}

/// A row heading as Explore's own: the name and the round chevron to see all.
private struct FeedHeading<Value: Hashable>: View {
    let title: String
    let value: Value?
    let identifier: String
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let value { SectionMoreLink(label: "See all " + title, value: value, identifier: identifier) }
        }
    }
}

/// A horizontal row of standard posters, three to a screen (as Explore's other rows).
private struct FeedTrack<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in tile(item).containerRelativeFrame(.horizontal, count: 3, spacing: 12) }
            }
        }.scrollIndicators(.hidden).padding(.bottom, 10)
    }
}

/// A placeholder the height of a row, so the page doesn't jump while a row loads.
private struct FeedPlaceholder: View {
    var body: some View { DiaryLoadingPlaceholder(label: "Loading titles", layout: .posterShelf) }
}

/// Opens a TMDB title: its library page when it's in your diary.
private struct CatalogTile: View {
    let item: CatalogItem
    var subtitle: String? = nil
    @Environment(DiaryStore.self) private var store
    var body: some View {
        Group {
            if let id = item.inLibraryId ?? store.libraryIdentity(item) { NavigationLink(value: id) { label } }
            else { NavigationLink(value: item.route) { label } }
        }.buttonStyle(.springPress).accessibilityIdentifier("explore-feed-" + item.key)
    }
    @ViewBuilder private var label: some View {
        if let subtitle { StandardPoster(artwork: item.artwork, name: item.name, subtitle: subtitle, score: item.rating) }
        else { CatalogPoster(item: item) }
    }
}

private struct Keyed: Identifiable { let item: CatalogItem; var id: String { item.key } }

// MARK: Routes and the see-all page

/// A see-all page for one of Explore's extra rows.
struct ExploreFeedRoute: Hashable {
    enum Kind: String, Hashable { case cineMovies, cineShows, trending, seasonal, comingMovies, comingShows }
    let kind: Kind
}

struct ExploreFeedPage: View {
    let route: ExploreFeedRoute
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    private var title: String {
        switch route.kind {
        case .cineMovies: "Movies recommended by CineMind"
        case .cineShows: "Shows recommended by CineMind"
        case .trending: "Trending from your Planned"
        case .seasonal: "This season's anime"
        case .comingMovies: "Coming soon · Movies"
        case .comingShows: "Coming soon · Shows"
        }
    }
    private var symbol: String {
        switch route.kind {
        case .cineMovies, .cineShows: "sparkles"
        case .trending: "chart.line.uptrend.xyaxis"
        case .seasonal: "sparkles.tv"
        case .comingMovies, .comingShows: "calendar"
        }
    }

    var body: some View {
        ExploreBrowsePage(title: title, symbol: symbol, artwork: artwork) {
            LazyVGrid(columns: columns, spacing: 18) {
                switch route.kind {
                case .cineMovies: ForEach(feeds.cineMovies.items.map(Keyed.init)) { CatalogTile(item: $0.item) }
                case .cineShows: ForEach(feeds.cineShows.items.map(Keyed.init)) { CatalogTile(item: $0.item) }
                case .trending: ForEach(feeds.trending.items.map(Keyed.init)) { CatalogTile(item: $0.item) }
                case .seasonal: ForEach(feeds.seasonal.items) { SeasonalTile(anime: $0, now: store.now) }
                case .comingMovies: ForEach(feeds.comingMovies.items) { ComingTile(entry: $0) }
                case .comingShows: ForEach(feeds.comingShows.items) { ComingTile(entry: $0) }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
    }
    private var artwork: String? {
        switch route.kind {
        case .cineMovies: ExploreBrowseHeader.artwork(in: feeds.cineMovies.items)
        case .cineShows: ExploreBrowseHeader.artwork(in: feeds.cineShows.items)
        case .trending: ExploreBrowseHeader.artwork(in: feeds.trending.items)
        case .seasonal: feeds.seasonal.items.first?.cover
        case .comingMovies: ExploreBrowseHeader.artwork(in: feeds.comingMovies.items.map(\.item))
        case .comingShows: ExploreBrowseHeader.artwork(in: feeds.comingShows.items.map(\.item))
        }
    }
}

// MARK: AI prompts and CineMind

/// A one-tap AI search ("Cozy anime"): the chip's name and the description sent.
struct ExploreAIPromptRoute: Hashable {
    let label: String
    let prompt: String
}

/// The AI area near the top of Explore: one-tap prompts, then CineMind's movie and show picks.
struct ExploreAIArea: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        if !store.isPreview {
            VStack(alignment: .leading, spacing: 22) {
                ExploreAIPrompts()
                CineMindRow(movies: true)
                CineMindRow(movies: false)
            }
        }
    }
}

private struct ExploreAIPrompts: View {
    static let prompts: [ExploreAIPromptRoute] = [
        .init(label: "Cozy anime", prompt: "Cozy, relaxing slice-of-life anime with warm characters and a gentle pace"),
        .init(label: "Mind-bending thrillers", prompt: "Mind-bending psychological thrillers with twists that change everything"),
        .init(label: "Feel-good comedies", prompt: "Light, feel-good comedies that leave you happy"),
        .init(label: "Short series for a weekend", prompt: "Excellent short TV series or miniseries you can finish in a weekend"),
        .init(label: "Epic fantasy worlds", prompt: "Epic fantasy with rich world-building, quests and magic"),
        .init(label: "Dark crime dramas", prompt: "Dark, gritty crime dramas with morally grey characters"),
        .init(label: "Underrated sci-fi", prompt: "Underrated, thoughtful science fiction movies and shows"),
        .init(label: "Heartwarming family films", prompt: "Heartwarming family movies everyone can enjoy together")
    ]
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask CineMind").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.prompts, id: \.label) { prompt in
                        NavigationLink(value: prompt) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                                Text(prompt.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            }.padding(.horizontal, 14).frame(height: 40).background(HomeStyle.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)).frame(minHeight: 44)
                        }.buttonStyle(.springPress).accessibilityIdentifier("explore-ai-" + prompt.label)
                    }
                }
            }.scrollIndicators(.hidden).scrollClipDisabled()
        }
    }
}

/// The page a prompt opens: AI search's own results for its description.
struct ExploreAIPromptPage: View {
    let route: ExploreAIPromptRoute
    var body: some View {
        ExploreBrowsePage(title: route.label, symbol: "sparkles", subtitle: "Picked by CineMind") {
            VStack(alignment: .leading, spacing: 14) {
                SemanticSearchSection(query: route.prompt, kind: .all)
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
    }
}

private struct CineMindRow: View {
    let movies: Bool
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }

    var body: some View {
        let feed = movies ? feeds.cineMovies : feeds.cineShows
        let shown = feed.items.filter { store.libraryIdentity($0) == nil }
        let title = movies ? "Movies recommended by CineMind" : "Shows recommended by CineMind"
        VStack(alignment: .leading, spacing: 10) {
            FeedHeading(title: title, value: shown.isEmpty ? nil : ExploreFeedRoute(kind: movies ? .cineMovies : .cineShows),
                        identifier: "explore-more-cinemind-" + (movies ? "movies" : "shows"))
            if SemanticSearch.key == nil {
                NavigationLink(value: AppDestination.apis) {
                    HStack(spacing: 10) {
                        CineMindMark(size: 22)
                        Text("Add a Gemini or Groq key for CineMind's picks").font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).frame(minHeight: 48).diarySectionBackground(radius: 11).contentShape(Rectangle())
                }.buttonStyle(.springPress)
            } else if !shown.isEmpty {
                FeedTrack(items: shown.map(Keyed.init)) { CatalogTile(item: $0.item) }
            } else if feed.loading || feed.loadedFor == nil {
                FeedPlaceholder()
            } else {
                HStack(spacing: 10) {
                    Text(feed.failure ?? "CineMind has no new picks right now.").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Ask again") { Task { await feeds.loadCineMind(movies: movies, store: store, force: true) } }.font(.system(size: 13)).frame(minHeight: 44)
                }
            }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadCineMind(movies: movies, store: store) }
    }
}

// MARK: More rows

/// Below Trakt's picks: Because you loved, Trending from your Planned, this season's anime and
/// Coming soon.
struct ExploreMoreShelves: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        if !store.isPreview {
            VStack(alignment: .leading, spacing: 22) {
                BecauseYouLovedRow()
                TrendingPlannedRow()
                SeasonalAnimeRow()
                ComingSoonRow()
            }
        }
    }
}

private struct BecauseYouLovedRow: View {
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    var body: some View {
        Group {
            if let seed = feeds.lovedSeed, let tmdb = seed.tmdbId, !feeds.loved.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FeedHeading(title: "Because you loved " + seed.name,
                                value: ShowPageRoute.related(CatalogRoute(kind: seed.isSeries ? .tv : .movie, id: tmdb), title: seed.name),
                                identifier: "explore-more-loved")
                    FeedTrack(items: feeds.loved.items.prefix(15).map(Keyed.init)) { CatalogTile(item: $0.item) }
                }
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadLoved(store: store) }
    }
}

private struct TrendingPlannedRow: View {
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    var body: some View {
        Group {
            if !feeds.trending.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FeedHeading(title: "Trending from your Planned", value: ExploreFeedRoute(kind: .trending), identifier: "explore-more-trending")
                    FeedTrack(items: feeds.trending.items.map(Keyed.init)) { CatalogTile(item: $0.item) }
                }
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadTrending(store: store) }
    }
}

/// An anime of the season: its poster, and when the next episode airs.
private struct SeasonalTile: View {
    let anime: SeasonalAnime
    let now: Date
    var body: some View {
        AnimeAppearanceButton(appearance: anime.appearance) {
            StandardPoster(artwork: anime.cover, name: anime.name,
                           subtitle: SeasonalAnime.countdown(episode: anime.nextEpisode, at: anime.nextAiring, now: now) ?? anime.episodes.map { "\($0) episodes" } ?? "Anime",
                           score: anime.score, subtitleTint: anime.nextAiring == nil ? .secondary : HomeStyle.chipText)
        }.buttonStyle(.springPress).accessibilityIdentifier("explore-seasonal-\(anime.id)")
    }
}

private struct SeasonalAnimeRow: View {
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    var body: some View {
        Group {
            if !feeds.seasonal.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    FeedHeading(title: "This season's anime", value: ExploreFeedRoute(kind: .seasonal), identifier: "explore-more-seasonal")
                    // The countdowns move once a minute.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        FeedTrack(items: Array(feeds.seasonal.items.prefix(15))) { SeasonalTile(anime: $0, now: context.date) }
                    }
                }
            } else if feeds.seasonal.loading || feeds.seasonal.loadedFor == nil, feeds.seasonal.failure == nil {
                VStack(alignment: .leading, spacing: 10) {
                    FeedHeading(title: "This season's anime", value: nil as ExploreFeedRoute?, identifier: "explore-more-seasonal")
                    FeedPlaceholder()
                }
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadSeasonal(store: store) }
    }
}

/// An upcoming title with its day, and the bell to be reminded.
private struct ComingTile: View {
    let entry: ExploreFeeds.Upcoming
    @Environment(DiaryStore.self) private var store
    @State private var adding = false

    var body: some View {
        let saved = store.libraryIdentity(entry.item)
        ZStack(alignment: .topTrailing) {
            Group {
                if let saved { NavigationLink(value: saved) { poster } } else { NavigationLink(value: entry.item.route) { poster } }
            }.buttonStyle(.springPress).accessibilityIdentifier("explore-coming-" + entry.id)
            // Over the poster, outside the link, so it doesn't open the page.
            Button { Task { await remind() } } label: {
                Group {
                    if adding { ProgressView().controlSize(.small) }
                    else { Image(systemName: saved != nil ? "bell.fill" : "bell").font(.system(size: 13, weight: .semibold)) }
                }.foregroundStyle(.white).frame(width: 30, height: 30).background(.black.opacity(0.6), in: Circle())
                    .padding(5).frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain).disabled(saved != nil || adding)
                .accessibilityLabel(saved != nil ? "Reminder on: in your Planned list" : "Remind me when " + entry.item.name + " is out")
        }
    }
    private var poster: some View {
        StandardPoster(artwork: entry.item.artwork, name: entry.item.name,
                       subtitle: ComingSoonRow.when(entry.day, now: store.now) + (entry.season.map { $0 > 1 ? " · Season \($0)" : " · New" } ?? ""),
                       subtitleTint: HomeStyle.chipText)
    }
    /// Adds it to Planned and turns release alerts on: the app then tells you when it's out (a
    /// movie when it can be streamed or bought, a show on its premiere).
    private func remind() async {
        guard !adding else { return }
        adding = true
        defer { adding = false }
        guard let browse = try? await store.browse(entry.item.route),
              await store.importTitle(browse.details, category: browse.details.suggestedCategory) != nil else { return }
        if ReleaseAlerts.enabled { await ReleaseAlerts.refresh(store: store) }
        else { await ReleaseAlerts.setEnabled(true, store: store) }
    }
}

private struct ComingSoonRow: View {
    @Environment(DiaryStore.self) private var store
    @State private var movies = true
    private var feeds: ExploreFeeds { .shared }

    var body: some View {
        let feed = movies ? feeds.comingMovies : feeds.comingShows
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Coming soon").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Picker("Coming soon", selection: $movies) {
                    Text("Movies").tag(true)
                    Text("Shows").tag(false)
                }.pickerStyle(.segmented).frame(width: 150)
                if !feed.items.isEmpty {
                    SectionMoreLink(label: "See all coming soon", value: ExploreFeedRoute(kind: movies ? .comingMovies : .comingShows), identifier: "explore-more-coming")
                }
            }
            if !feed.items.isEmpty {
                FeedTrack(items: Array(feed.items.prefix(15))) { ComingTile(entry: $0) }
            } else if feed.loading || feed.loadedFor == nil {
                FeedPlaceholder()
            } else {
                Text(feed.failure ?? "Nothing coming up.").font(.system(size: 13)).foregroundStyle(.secondary).frame(minHeight: 44)
            }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadComing(store: store) }
    }

    /// "Today", "Tomorrow", "In 5 days", else "12 Dec".
    static func when(_ day: String, now: Date) -> String {
        guard let gap = ReleaseAlerts.days(from: DiaryDate.day(now), to: day) else { return day }
        switch gap {
        case ..<1: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return "In \(gap) days"
        default:
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
