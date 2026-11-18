import SwiftUI
import TwilDiaryCore

// Explore's extra rows: one-tap AI prompts, CineMind's movie and show picks, Because you loved,
// Trending from your Planned, this season's anime and Coming soon. None show in the UI-test fixture.

// MARK: Shared pieces

/// A row heading: the name, an optional line under it, and anything on the right.
private struct ExploreRowHeading<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary).lineLimit(1)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
    }
}
private extension ExploreRowHeading where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle; self.trailing = { EmptyView() } }
}

/// A poster with its name and one or two lines under it, a third of the row wide.
private struct ExploreTile<Badge: View>: View {
    let artwork: String?
    let name: String
    var detail: String? = nil
    var note: String? = nil
    @ViewBuilder var badge: () -> Badge
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(path: artwork, title: name, initialsOnly: false).aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) { badge() }
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading)
            if let detail { Text(detail).font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.chipText).lineLimit(1) }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(3).multilineTextAlignment(.leading) }
        }
    }
}
private extension ExploreTile where Badge == EmptyView {
    init(artwork: String?, name: String, detail: String? = nil, note: String? = nil) {
        self.artwork = artwork; self.name = name; self.detail = detail; self.note = note; self.badge = { EmptyView() }
    }
}

/// A horizontal row of tiles, three to a screen.
private struct ExploreRow<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in tile(item).containerRelativeFrame(.horizontal, count: 3, spacing: 12) }
            }
        }.scrollIndicators(.hidden).padding(.bottom, 4)
    }
}

/// Opens a TMDB title: its library page when it's in your diary.
private struct CatalogLink<Label: View>: View {
    let item: CatalogItem
    @ViewBuilder let label: () -> Label
    @Environment(DiaryStore.self) private var store
    var body: some View {
        if let id = store.libraryIdentity(item) { NavigationLink(value: id) { label() }.buttonStyle(.springPress) }
        else { NavigationLink(value: item.route) { label() }.buttonStyle(.springPress) }
    }
}

private extension CatalogItem {
    var kindLabel: String {
        if isAnime == true || genres?.contains("Animation") == true { return mediaType == .movie ? "Anime movie" : "Anime" }
        return mediaType == .movie ? "Movie" : "Show"
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
                CineMindPicksRow(movies: true)
                CineMindPicksRow(movies: false)
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
            ExploreRowHeading(title: "Ask CineMind", subtitle: "One tap, AI picks")
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

/// CineMind's picks of movies (or shows) for your taste: worked out once a day from up to 25 of
/// the titles you finished or are watching, best rated first (names, years and your ratings
/// only), kept on this iPhone; Refresh asks again.
private struct CineMindPicksRow: View {
    let movies: Bool
    @Environment(DiaryStore.self) private var store
    @State private var picks: [Pick] = []
    @State private var loading = false
    @State private var failure: String?

    struct Pick: Codable, Hashable, Identifiable {
        let tmdb: Int
        let movie: Bool
        let name: String
        let year: Int?
        let poster: String?
        let why: String
        var id: String { (movie ? "movie:" : "tv:") + String(tmdb) }
        var item: CatalogItem { CatalogItem(id: tmdb, mediaType: movie ? .movie : .tv, name: name, year: year, poster: poster) }
    }
    private struct Saved: Codable { let day: String; let picks: [Pick] }
    private var storageKey: String { "cinemind.picks." + (movies ? "movies" : "shows") }

    var body: some View {
        let shown = picks.filter { store.libraryIdentity($0.item) == nil }
        VStack(alignment: .leading, spacing: 10) {
            ExploreRowHeading(title: movies ? "Movies for you" : "Shows for you", subtitle: "Recommended by CineMind") {
                if SemanticSearch.key != nil {
                    Button { Task { await load(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                    }.disabled(loading).accessibilityLabel("Ask CineMind again")
                }
            }
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
                ExploreRow(items: shown) { pick in
                    CatalogLink(item: pick.item) { ExploreTile(artwork: pick.poster, name: pick.name, detail: pick.year.map(String.init), note: pick.why) }
                        .accessibilityIdentifier("explore-cinemind-" + pick.id)
                }
            } else if loading {
                DiaryLoadingPlaceholder(label: "CineMind is picking", layout: .posterShelf)
            } else if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text("Rate or finish a few titles and CineMind will pick more for you.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.task(id: store.sessionRevision) { await load(force: false) }
    }

    private var taste: [String] {
        let rows = store.workspace.activeTitles.filter { ["completed", "watching", "paused"].contains($0.status) }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(25)
        return rows.map { title in
            [title.name + (title.year.map { " (\($0))" } ?? ""), title.score.map { "\(Int($0.rounded()))/10" }].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func load(force: Bool) async {
        let today = DiaryDate.day(store.now)
        if !force, picks.isEmpty, let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            picks = saved.picks
            if saved.day == today { return }
        }
        guard !loading, SemanticSearch.key != nil, taste.count >= 3 else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let found = try await SemanticSearch.recommendations(movies: movies, taste: taste, store: store)
            guard !Task.isCancelled else { return }
            let fresh = found.map { Pick(tmdb: $0.item.id, movie: $0.item.mediaType == .movie, name: $0.item.name, year: $0.item.year, poster: $0.item.artwork, why: $0.why) }
            if !fresh.isEmpty {
                picks = fresh
                UserDefaults.standard.set(try? JSONEncoder().encode(Saved(day: today, picks: fresh)), forKey: storageKey)
            }
        } catch {
            if !Task.isCancelled, picks.isEmpty { failure = error.localizedDescription }
        }
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

/// TMDB's recommendations for one of your best-rated finished titles, a different one each day
/// (Home's Recommended follows what you watched last).
private struct BecauseYouLovedRow: View {
    @Environment(DiaryStore.self) private var store
    @State private var seed: MediaTitle?
    @State private var items: [CatalogItem] = []

    var body: some View {
        Group {
            if let seed, !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ExploreRowHeading(title: "Because you loved", subtitle: seed.name)
                    ExploreRow(items: items.map(Identified.init)) { entry in
                        CatalogLink(item: entry.item) {
                            ExploreTile(artwork: entry.item.artwork, name: entry.item.name,
                                        detail: [entry.item.year.map(String.init), entry.item.kindLabel].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }.task(id: DiaryDate.day(store.now)) { await load() }
    }

    private func load() async {
        let loved = store.workspace.activeTitles.filter { $0.status == "completed" && $0.tmdbId != nil && ($0.score ?? 0) >= 7 }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(10)
        guard !loved.isEmpty else { return }
        let start = (Int(DiaryDate.day(store.now).filter(\.isNumber)) ?? 0) % loved.count
        let order = Array(loved[(loved.startIndex + start)...]) + Array(loved[..<(loved.startIndex + start)])
        for candidate in order.prefix(3) {
            guard let tmdb = candidate.tmdbId,
                  let related = try? await store.related(CatalogRoute(kind: candidate.isSeries ? .tv : .movie, id: tmdb)) else { continue }
            let found = related.items.filter { store.libraryIdentity($0) == nil }
            if found.count >= 3 { seed = candidate; items = Array(found.prefix(15)); return }
        }
    }
}

private struct Identified: Identifiable {
    let item: CatalogItem
    var id: String { item.key }
}

/// Titles on your Planned list that are among TMDB's trending this week, by their rank.
private struct TrendingPlannedRow: View {
    @Environment(DiaryStore.self) private var store
    @State private var rows: [Row] = []

    struct Row: Identifiable { let title: MediaTitle; let rank: Int; var id: String { title.id } }

    var body: some View {
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ExploreRowHeading(title: "Trending from your Planned", subtitle: "Popular this week")
                    ExploreRow(items: rows) { row in
                        NavigationLink(value: row.title.id) {
                            ExploreTile(artwork: row.title.poster, name: row.title.name, detail: "#\(row.rank) trending")
                        }.buttonStyle(.springPress)
                    }
                }
            } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }.task(id: store.sessionRevision) { await load() }
    }

    private func load() async {
        let planned = store.workspace.activeTitles.filter { $0.status == "planned" && $0.tmdbId != nil }
        guard !planned.isEmpty, let token = TMDBDirect.token(store) else { rows = []; return }
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
        guard !Task.isCancelled else { return }
        rows = planned.compactMap { title in
            guard let tmdb = title.tmdbId, let rank = ranks[(title.isSeries ? "tv:" : "movie:") + String(tmdb)] else { return nil }
            return Row(title: title, rank: rank)
        }.sorted { $0.rank < $1.rank }
    }
}

/// This season's most popular anime on AniList, each with a countdown to its next episode.
private struct SeasonalAnimeRow: View {
    @Environment(DiaryStore.self) private var store
    @State private var items: [SeasonalAnime] = []
    @State private var failed = false

    var body: some View {
        let (season, year) = SeasonalAnime.Season.of(store.now)
        VStack(alignment: .leading, spacing: 10) {
            if !items.isEmpty {
                ExploreRowHeading(title: "This season's anime", subtitle: "\(season.name) \(year) · AniList")
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ExploreRow(items: items) { anime in
                        AnimeAppearanceButton(appearance: anime.appearance) {
                            ExploreTile(artwork: anime.cover, name: anime.name,
                                        detail: SeasonalAnime.countdown(episode: anime.nextEpisode, at: anime.nextAiring, now: context.date)
                                            ?? anime.episodes.map { "\($0) episodes" },
                                        note: anime.score.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) })
                        }.buttonStyle(.springPress).accessibilityIdentifier("explore-seasonal-\(anime.id)")
                    }
                }
            } else if failed {
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }.task(id: "\(season.rawValue)\(year)") {
            guard items.isEmpty else { return }
            do { items = try await AniListClient.shared.seasonal(season, year: year) } catch { failed = true }
        }
    }
}

/// Upcoming movies and new or returning shows (TMDB), each with "Remind me": it adds the title to
/// Planned and turns release alerts on, so the app tells you when it's out (a movie when it can
/// be streamed or bought, a show on its premiere).
private struct ComingSoonRow: View {
    @Environment(DiaryStore.self) private var store
    @State private var movies = true
    @State private var films: [Upcoming] = []
    @State private var shows: [Upcoming] = []
    @State private var adding: Set<String> = []
    @State private var failure: String?

    struct Upcoming: Identifiable, Hashable {
        let item: CatalogItem
        let day: String
        let season: Int?
        var id: String { item.key }
    }

    var body: some View {
        let shown = movies ? films : shows
        VStack(alignment: .leading, spacing: 10) {
            ExploreRowHeading(title: "Coming soon", subtitle: movies ? "Movies on the way" : "New and returning shows") {
                Picker("Coming soon", selection: $movies) {
                    Text("Movies").tag(true)
                    Text("Shows").tag(false)
                }.pickerStyle(.segmented).frame(width: 160)
            }
            if !shown.isEmpty {
                ExploreRow(items: shown) { entry in
                    // The bell sits over the poster, outside the link, so it doesn't open the page.
                    ZStack(alignment: .topTrailing) {
                        CatalogLink(item: entry.item) {
                            ExploreTile(artwork: entry.item.artwork, name: entry.item.name,
                                        detail: Self.when(entry.day) + (entry.season.map { $0 > 1 ? " · Season \($0)" : " · New" } ?? ""))
                        }.accessibilityIdentifier("explore-coming-" + entry.id)
                        remindButton(entry, saved: store.libraryIdentity(entry.item) != nil)
                    }
                }
            } else if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                DiaryLoadingPlaceholder(label: "Loading what's coming", layout: .posterShelf)
            }
        }.task(id: DiaryDate.day(store.now)) { await load() }
    }

    private func remindButton(_ entry: Upcoming, saved: Bool) -> some View {
        Button { Task { await remind(entry) } } label: {
            Group {
                if adding.contains(entry.id) { ProgressView().controlSize(.small) }
                else { Image(systemName: saved ? "bell.fill" : "bell").font(.system(size: 14, weight: .semibold)) }
            }.foregroundStyle(.white).frame(width: 34, height: 34).background(.black.opacity(0.6), in: Circle())
                .padding(6).frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).disabled(saved || adding.contains(entry.id))
            .accessibilityLabel(saved ? "Reminder on: in your Planned list" : "Remind me when " + entry.item.name + " is out")
    }

    private func remind(_ entry: Upcoming) async {
        guard adding.insert(entry.id).inserted else { return }
        defer { adding.remove(entry.id) }
        guard let browse = try? await store.browse(entry.item.route),
              await store.importTitle(browse.details, category: browse.details.suggestedCategory) != nil else { return }
        if ReleaseAlerts.enabled { await ReleaseAlerts.refresh(store: store) }
        else { await ReleaseAlerts.setEnabled(true, store: store) }
    }

    /// "Today", "Tomorrow", "In 5 days", else "12 Dec".
    static func when(_ day: String) -> String {
        let today = DiaryDate.day(.now)
        guard let gap = ReleaseAlerts.days(from: today, to: day) else { return day }
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

    /// The show's next episode, when it's a premiere (a season's first episode).
    private static func premiere(_ item: CatalogItem, token: String) async -> Upcoming? {
        guard let details = try? await TMDBDirect.object("tv/\(item.id)", query: ["language": "en-US"], token: token),
              let next = details["next_episode_to_air"] as? [String: Any], next["episode_number"] as? Int == 1,
              let date = next["air_date"] as? String, date.count >= 10 else { return nil }
        return Upcoming(item: item, day: String(date.prefix(10)), season: next["season_number"] as? Int)
    }

    private func load() async {
        guard films.isEmpty || shows.isEmpty else { return }
        guard let token = TMDBDirect.token(store) else { failure = "Coming soon needs TMDB, which isn’t set up."; return }
        let region = (UserDefaults.standard.string(forKey: "streamingRegion") ?? Locale.current.region?.identifier ?? "US").uppercased()
        let calendar = Calendar(identifier: .gregorian)
        func day(_ offset: Int) -> String { DiaryDate.day(calendar.date(byAdding: .day, value: offset, to: .now) ?? .now) }
        let movieData = try? await TMDBDirect.object("discover/movie", query: [
            "primary_release_date.gte": day(1), "primary_release_date.lte": day(90), "region": region,
            "with_release_type": "2|3", "sort_by": "popularity.desc", "language": "en-US", "include_adult": "false"], token: token)
        let showData = try? await TMDBDirect.object("discover/tv", query: [
            "air_date.gte": day(1), "air_date.lte": day(30), "sort_by": "popularity.desc", "language": "en-US",
            "include_adult": "false", "vote_count.gte": "10"], token: token)
        guard !Task.isCancelled else { return }
        films = ((movieData?["results"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let item = TMDBDirect.catalogItem(row, kind: .movie), let date = row["release_date"] as? String, date.count >= 10 else { return nil }
            return Upcoming(item: item, day: String(date.prefix(10)), season: nil)
        }.sorted { $0.day < $1.day }
        // A show's next episode is a premiere (a new season's first episode, or the series' first).
        let candidates = ((showData?["results"] as? [[String: Any]]) ?? []).compactMap { TMDBDirect.catalogItem($0, kind: .tv) }.prefix(20)
        let found = await withTaskGroup(of: Upcoming?.self) { group in
            for item in candidates {
                group.addTask { await Self.premiere(item, token: token) }
            }
            var rows: [Upcoming] = []
            for await row in group { if let row { rows.append(row) } }
            return rows
        }
        guard !Task.isCancelled else { return }
        shows = found.sorted { $0.day < $1.day }
        if films.isEmpty && shows.isEmpty { failure = "Nothing coming up could be loaded." }
    }
}
