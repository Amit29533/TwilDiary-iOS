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
            if feed.items.isEmpty { feed.failure = FriendlyError.message(error) }
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
        guard trending.loadedFor != today, !trending.loading else { return }
        // No TMDB key: nothing to read (asked again next time). Marked as read meanwhile, or the row's
        // stand-in waited for ever.
        guard let token = TMDBDirect.token(store) else { trending.loadedFor = "no TMDB key"; return }
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
        let moviesDone = comingMovies.loadedFor == today && !comingMovies.items.isEmpty
        let showsDone = comingShows.loadedFor == today && !comingShows.items.isEmpty
        guard !(moviesDone && showsDone), !comingMovies.loading, !comingShows.loading else { return }
        guard let token = TMDBDirect.token(store) else {
            comingMovies.failure = "Coming soon needs TMDB, which isn’t set up."; comingShows.failure = comingMovies.failure
            comingMovies.loadedFor = today; comingShows.loadedFor = today; return
        }
        // Only the side that isn't loaded yet (a failed one is asked again on the next visit).
        if !moviesDone { comingMovies.loading = true; comingMovies.failure = nil }
        if !showsDone { comingShows.loading = true; comingShows.failure = nil }
        let region = (UserDefaults.standard.string(forKey: "streamingRegion") ?? Locale.current.region?.identifier ?? "US").uppercased()
        let calendar = Calendar(identifier: .gregorian)
        func dayString(_ offset: Int) -> String { DiaryDate.day(calendar.date(byAdding: .day, value: offset, to: store.now) ?? store.now) }
        if !moviesDone {
            let movieData = try? await TMDBDirect.object("discover/movie", query: [
                "primary_release_date.gte": dayString(1), "primary_release_date.lte": dayString(90), "region": region,
                "with_release_type": "2|3", "sort_by": "popularity.desc", "language": "en-US", "include_adult": "false"], token: token)
            let movies = ((movieData?["results"] as? [[String: Any]]) ?? []).compactMap { row -> Upcoming? in
                guard let item = TMDBDirect.catalogItem(row, kind: .movie), let date = row["release_date"] as? String, date.count >= 10 else { return nil }
                return Upcoming(item: item, day: String(date.prefix(10)), season: nil)
            }.sorted { $0.day < $1.day }
            if !movies.isEmpty { comingMovies.items = movies }
            comingMovies.loading = false; comingMovies.loadedFor = today
            if comingMovies.items.isEmpty { comingMovies.failure = "No upcoming movies could be loaded." }
        }

        if !showsDone {
            // One request to Trakt, posters included (no lookup per show, which failed on flaky links).
            let found = await Self.traktPremieres(from: dayString(0), days: 33)
            if !found.isEmpty { comingShows.items = found.sorted { $0.day < $1.day } }
            comingShows.loading = false; comingShows.loadedFor = today
            if comingShows.items.isEmpty { comingShows.failure = "No upcoming shows could be loaded." }
        }
    }

    /// Trakt's season premieres (a new show's first season, or a returning one's next) in the
    /// coming days, the most followed first, with Trakt's own posters. Trakt's public calendar
    /// needs only TwilDiary's app ID.
    private static func traktPremieres(from start: String, days: Int) async -> [Upcoming] {
        guard let clientID = ProviderAppIDs.id(for: .trakt),
              let url = URL(string: "https://api.trakt.tv/calendars/all/shows/premieres/\(start)/\(days)?extended=full,images") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var reply: (Data, URLResponse)?
        for attempt in 0..<2 where reply == nil {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            reply = try? await URLSession.shared.data(for: request)
        }
        guard let (data, response) = reply, (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        func image(_ show: [String: Any], _ kind: String) -> String? {
            ((show["images"] as? [String: Any])?[kind] as? [String])?.first.map { $0.hasPrefix("http") ? $0 : "https://" + $0 }
        }
        var seen = Set<Int>()
        let found = rows.compactMap { row -> (Upcoming, Int)? in
            guard let show = row["show"] as? [String: Any], let ids = show["ids"] as? [String: Any], let tmdb = ids["tmdb"] as? Int, tmdb > 0,
                  let name = show["title"] as? String, let aired = row["first_aired"] as? String, let episode = row["episode"] as? [String: Any],
                  let season = episode["season"] as? Int, season > 0, seen.insert(tmdb).inserted else { return nil }
            let date = ISO8601DateFormatter.flexible(aired).map { DiaryDate.day($0) } ?? String(aired.prefix(10))
            let item = CatalogItem(id: tmdb, mediaType: .tv, name: name, year: show["year"] as? Int, overview: show["overview"] as? String ?? "",
                                   rating: (show["rating"] as? NSNumber).map { $0.doubleValue }.flatMap { $0 > 0 ? $0 : nil },
                                   poster: image(show, "poster"), backdrop: image(show, "fanart"))
            return (Upcoming(item: item, day: date, season: season), show["votes"] as? Int ?? 0)
        }
        return found.sorted { $0.1 > $1.1 }.prefix(24).map { $0.0 }
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
    private var showsCaption: Bool { TilePrefs.shared.posterCaptions }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(path: artwork, title: name, initialsOnly: false)
                .posterAspect()
                .overlay(alignment: Studio.badgeCorner(.bottomLeading)) { if let score, score > 0 { PosterScoreBadge(score: score) } }
                .clipShape(RoundedRectangle(cornerRadius: Studio.corner(Gap.posterCorner)))
            if showsCaption {
                Text(name).font(.app(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).frame(minHeight: 20.25).padding(.top, 8)
                Text(subtitle).font(.app(size: 12)).foregroundStyle(subtitleTint).lineLimit(1).frame(height: 18).padding(.top, 4)
            }
        }.accessibilityElement(children: .combine)
    }
}

/// A row heading as Explore's own: the name and the round chevron to see all.
private struct FeedHeading<Value: Hashable>: View {
    let title: String
    let value: Value?
    let identifier: String
    /// CineMind's rows: a shimmering sparkle says the AI picked them.
    var ai = false
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                if ai { AISparkle() }
                Text(title).font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    .minimumScaleFactor(0.75).truncationMode(.tail)
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let value { SectionMoreLink(label: "See all " + title, value: value, identifier: identifier) }
        }.frame(minHeight: Gap.headingRow)
    }
}

/// The AI mark: CineMind's glass orb, its liquid churning (the owner's reference animation).
struct AISparkle: View {
    var size: CGFloat = 18
    var body: some View {
        CineMindOrb(size: size * 1.3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Picked by AI")
    }
}

/// A horizontal row of standard posters, three to a screen (as Explore's other rows).
private struct FeedTrack<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in tile(item).containerRelativeFrame(.horizontal, count: posterSize.columns, spacing: 12) }
            }
        }.scrollIndicators(.hidden).padding(.bottom, 10)
    }
}

/// A placeholder the height of a row (its posters, captions and the track's bottom space), so the
/// page doesn't jump while a row loads. `standard`: the row's tiles are `StandardPoster`s.
private struct FeedPlaceholder: View {
    var standard = false
    var body: some View { DiaryLoadingPlaceholder(label: "Loading titles", layout: standard ? .standardShelf : .posterShelf).padding(.bottom, 10) }
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
        if let subtitle {
            let score = PosterScores.score(for: item, store: store)
            StandardPoster(artwork: item.artwork, name: item.name, subtitle: subtitle, score: score).wantsPosterScore(item, known: score, store: store)
        }
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
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: posterSize.columns) }

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
                case .cineMovies: ForEach(feeds.cineMovies.items.filter { store.libraryIdentity($0) == nil }.map(Keyed.init)) { CatalogTile(item: $0.item) }
                case .cineShows: ForEach(feeds.cineShows.items.filter { store.libraryIdentity($0) == nil }.map(Keyed.init)) { CatalogTile(item: $0.item) }
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


struct ExploreAIPrompts: View {
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
        VStack(alignment: .leading, spacing: Gap.heading) {
            HStack(spacing: 8) {
                AISparkle()
                Text("Ask CineMind").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
            }.frame(minHeight: Gap.headingRow).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.prompts, id: \.label) { prompt in
                        NavigationLink(value: prompt) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles").font(.app(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                                Text(prompt.label).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
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
    /// The picks shown: the first one's picture is the page's cover.
    @State private var picks: [CatalogItem] = []
    var body: some View {
        ExploreBrowsePage(title: route.label, symbol: "sparkles", subtitle: "Picked by CineMind", artwork: ExploreBrowseHeader.artwork(in: picks)) {
            VStack(alignment: .leading, spacing: 14) {
                SemanticSearchSection(query: route.prompt, kind: .all, showsLabel: false) { found in picks = found }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
    }
}

struct CineMindRow: View {
    let movies: Bool
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }

    var body: some View {
        let feed = movies ? feeds.cineMovies : feeds.cineShows
        let shown = feed.items.filter { store.libraryIdentity($0) == nil }
        let title = movies ? "Movies recommended by CineMind" : "Shows recommended by CineMind"
        VStack(alignment: .leading, spacing: Gap.heading) {
            FeedHeading(title: title, value: shown.isEmpty ? nil : ExploreFeedRoute(kind: movies ? .cineMovies : .cineShows),
                        identifier: "explore-more-cinemind-" + (movies ? "movies" : "shows"), ai: true)
            if SemanticSearch.key == nil {
                NavigationLink(value: AppDestination.apis) {
                    HStack(spacing: 10) {
                        CineMindMark(size: 22)
                        Text("Add a Gemini or Groq key for CineMind's picks").font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.app(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).frame(minHeight: 48).diarySectionBackground(radius: 11).contentShape(Rectangle())
                }.buttonStyle(.springPress)
            } else if !shown.isEmpty {
                FeedTrack(items: shown.map(Keyed.init)) { CatalogTile(item: $0.item) }
            } else if feed.loading || feed.loadedFor == nil {
                FeedPlaceholder()
            } else {
                HStack(spacing: 10) {
                    Text(feed.failure ?? "CineMind has no new picks right now.").font(.app(size: 13)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Ask again") { Task { await feeds.loadCineMind(movies: movies, store: store, force: true) } }.font(.app(size: 13)).frame(minHeight: 44)
                }
            }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadCineMind(movies: movies, store: store) }
    }
}

// MARK: More rows

/// Below Trakt's picks: Because you loved, Trending from your Planned, this season's anime and
/// Coming soon.

struct BecauseYouLovedRow: View {
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    var body: some View {
        Group {
            if let seed = feeds.lovedSeed, let tmdb = seed.tmdbId, !feeds.loved.items.isEmpty {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    FeedHeading(title: "Because you loved " + seed.name,
                                value: ShowPageRoute.related(CatalogRoute(kind: seed.isSeries ? .tv : .movie, id: tmdb), title: seed.name),
                                identifier: "explore-more-loved")
                    FeedTrack(items: feeds.loved.items.prefix(15).map(Keyed.init)) { CatalogTile(item: $0.item) }
                }
            } else if feeds.loved.loading || feeds.loved.loadedFor == nil, feeds.loved.failure == nil {
                // While it reads: its shapes where the row will land (it took no room, then pushed Explore down).
                VStack(alignment: .leading, spacing: Gap.heading) {
                    FeedHeading(title: feeds.lovedSeed.map { "Because you loved " + $0.name } ?? "Because you loved", value: nil as ShowPageRoute?, identifier: "explore-more-loved")
                    FeedPlaceholder()
                }
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }.task(id: DiaryDate.day(store.now)) { await feeds.loadLoved(store: store) }
    }
}

struct TrendingPlannedRow: View {
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    var body: some View {
        Group {
            if !feeds.trending.items.isEmpty {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    FeedHeading(title: "Trending from your Planned", value: ExploreFeedRoute(kind: .trending), identifier: "explore-more-trending")
                    FeedTrack(items: feeds.trending.items.map(Keyed.init)) { CatalogTile(item: $0.item) }
                }
            } else if feeds.trending.loading || feeds.trending.loadedFor == nil, feeds.trending.failure == nil {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    FeedHeading(title: "Trending from your Planned", value: nil as ExploreFeedRoute?, identifier: "explore-more-trending")
                    FeedPlaceholder()
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

struct SeasonalAnimeRow: View {
    @Environment(DiaryStore.self) private var store
    private var feeds: ExploreFeeds { .shared }
    var body: some View {
        Group {
            if !feeds.seasonal.items.isEmpty {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    FeedHeading(title: "This season's anime", value: ExploreFeedRoute(kind: .seasonal), identifier: "explore-more-seasonal")
                    // The countdowns move once a minute.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        FeedTrack(items: Array(feeds.seasonal.items.prefix(15))) { SeasonalTile(anime: $0, now: context.date) }
                    }
                }
            } else if feeds.seasonal.loading || feeds.seasonal.loadedFor == nil, feeds.seasonal.failure == nil {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    FeedHeading(title: "This season's anime", value: nil as ExploreFeedRoute?, identifier: "explore-more-seasonal")
                    FeedPlaceholder(standard: true)
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
    @State private var confirmRemove = false
    @AppStorage("confirmDeletions") private var confirmDeletions = true

    var body: some View {
        let saved = store.libraryIdentity(entry.item)
        // A filled bell takes its reminder back off while the title is still only Planned.
        let removable = saved.flatMap { store.title($0) }?.status == "planned"
        ZStack(alignment: .topTrailing) {
            Group {
                if let saved { NavigationLink(value: saved) { poster } } else { NavigationLink(value: entry.item.route) { poster } }
            }.buttonStyle(.springPress).accessibilityIdentifier("explore-coming-" + entry.id)
            // Over the poster, outside the link, so it doesn't open the page.
            Button {
                if saved == nil { Task { await remind() } }
                else if confirmDeletions { confirmRemove = true }
                else { Task { await unremind() } }
            } label: {
                Group {
                    if adding { ProgressView().controlSize(.small) }
                    else { Image(systemName: saved != nil ? "bell.fill" : "bell").font(.app(size: 13, weight: .semibold)) }
                }.foregroundStyle(.white).frame(width: 30, height: 30).background(.black.opacity(0.6), in: Circle())
                    .padding(5).frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain).disabled(adding || (saved != nil && !removable))
                .accessibilityLabel(saved != nil ? "Remove the reminder for " + entry.item.name : "Remind me when " + entry.item.name + " is out")
        }
        .confirmationDialog("Remove the reminder for \(entry.item.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove reminder", role: .destructive) { Task { await unremind() } }
        } message: { Text("It moves from Planned to Trash.") }
    }
    /// Takes it back out of Planned (into Trash, where it can be restored); its alert goes with it.
    private func unremind() async {
        guard let id = store.libraryIdentity(entry.item), let title = store.title(id), title.status == "planned" else { return }
        adding = true
        defer { adding = false }
        guard await store.trash(title) else { return }
        Haptics.play(.light)
        await ReleaseAlerts.refresh(store: store)
    }
    private var poster: some View {
        StandardPoster(artwork: entry.item.artwork, name: entry.item.name,
                       subtitle: ComingSoonRow.when(entry.day, now: store.now) + (entry.season.map { $0 > 1 ? " · S\($0)" : " · New" } ?? ""),
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
        Haptics.play(.success)
        if ReleaseAlerts.enabled { await ReleaseAlerts.refresh(store: store) }
        else { await ReleaseAlerts.setEnabled(true, store: store) }
    }
}

struct ComingSoonRow: View {
    @Environment(DiaryStore.self) private var store
    @State private var movies = true
    private var feeds: ExploreFeeds { .shared }

    var body: some View {
        let feed = movies ? feeds.comingMovies : feeds.comingShows
        VStack(alignment: .leading, spacing: Gap.heading) {
            HStack(alignment: .center, spacing: 10) {
                Text("Coming soon").font(.app(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Picker("Coming soon", selection: $movies) {
                    Text("Movies").tag(true)
                    Text("Shows").tag(false)
                }.pickerStyle(.segmented).frame(width: 150).haptic(.selection, trigger: movies)
                if !feed.items.isEmpty {
                    SectionMoreLink(label: "See all coming soon", value: ExploreFeedRoute(kind: movies ? .comingMovies : .comingShows), identifier: "explore-more-coming")
                }
            }.frame(minHeight: Gap.headingRow)
            if !feed.items.isEmpty {
                FeedTrack(items: Array(feed.items.prefix(15))) { ComingTile(entry: $0) }
            } else if feed.loading || feed.loadedFor == nil {
                FeedPlaceholder(standard: true)
            } else {
                HStack(spacing: 10) {
                    Text(feed.failure ?? "Nothing coming up.").font(.app(size: 13)).foregroundStyle(.secondary)
                    if feed.failure != nil {
                        Button("Try again") { Task { await feeds.loadComing(store: store) } }
                            .font(.app(size: 13, weight: .semibold)).accessibilityIdentifier("explore-coming-retry")
                    }
                }.frame(minHeight: 44)
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
