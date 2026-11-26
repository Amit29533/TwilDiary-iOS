import Foundation
import Observation
import TwilDiaryCore

/// Cines' clips (owner's request, 25 Nov 2026: a Reels-like feed of trailers and scenes from
/// shows, movies and anime, each with its title and Add to Planned). Two sources, mixed: the
/// YouTube videos TMDB lists for each title (trailers, teasers, clips, featurettes), and the
/// newest scenes, clips and Shorts of the official channels (`CinesChannels`), each matched to
/// the title it names. They play in YouTube's own embedded player (`CinesPlayer`); nothing is
/// downloaded.
struct CinesClip: Identifiable, Hashable, Sendable {
    /// The YouTube video id.
    let id: String
    let kind: String
    let name: String
    let year: Int?
    let route: CatalogRoute
    let anime: Bool
    let genres: [String]
    let poster: String?
    let backdrop: String?
    /// A YouTube Short: vertical.
    var short = false
    var label: String { anime ? "Anime" : route.kind == .movie ? "Movie" : "Show" }
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=" + id)! }
    /// "Show · 2021 · Animation, Action"
    var detail: String {
        ([label, year.map(String.init)].compactMap { $0 } + (genres.isEmpty ? [] : [genres.prefix(2).joined(separator: ", ")])).joined(separator: " · ")
    }
}

enum CinesTab: String, CaseIterable, Identifiable, Sendable {
    case forYou, shows, movies, anime
    var id: String { rawValue }
    var name: String {
        switch self {
        case .forYou: "For you"
        case .shows: "Shows"
        case .movies: "Movies"
        case .anime: "Anime"
        }
    }
}

@MainActor @Observable final class CinesFeed {
    private(set) var clips: [CinesClip] = []
    private(set) var loading = false
    private(set) var failure: String?
    /// The channel that posted each clip ("Netflix", "Crunchyroll").
    private(set) var channels: [String: String] = [:]
    /// Clips YouTube said it will play in the app (true) or won't (false).
    @ObservationIgnored private var checked: [String: Bool] = [:]

    let tab: CinesTab
    private var page = 0
    private var exhausted = false
    private var queue: [Candidate] = []
    private var seenTitles = Set<String>()
    private var seenClips = Set<String>()
    /// Second clips of a title wait a while, so one title never plays twice in a row.
    private var later: [CinesClip] = []
    private var asking = Set<String>()
    // For you's sources.
    private var mine: [Candidate]?
    private var seeds: [CatalogRoute] = []
    private var liked: [(kind: MediaKind, id: Int)] = []
    private var sourcePages: [String: Int] = [:]
    // The official channels: those still to read (this tab's, shuffled), and matched clips waiting.
    private var channelsLeft: [CinesChannels.Channel]?
    private var channelClips: [CinesClip] = []
    /// With a YouTube key: how far each channel's uploads and Shorts have been read.
    private var channelPages: [String: ChannelPages] = [:]
    /// With a YouTube key: diary titles whose scenes are still to be searched (For you).
    private var sceneTitles: [Candidate]?
    /// TMDB's answer for a name in a video's title, once per name.
    @ObservationIgnored private var named: [String: [Candidate]] = [:]

    init(tab: CinesTab) { self.tab = tab }

    struct Candidate: Sendable {
        let route: CatalogRoute
        let name: String
        let year: Int?
        let anime: Bool
        let genres: [String]
        let poster: String?
        let backdrop: String?
        let popularity: Double
        /// TMDB's original title (a Japanese channel names the show in Japanese).
        var original: String? = nil
    }

    /// Clips the player refused (embedding off, removed): left out from now on.
    private static let failedKey = "cines.failed"
    static var failed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: failedKey) ?? []) }
    static func markFailed(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: failedKey) ?? []
        guard !list.contains(id) else { return }
        list.append(id)
        UserDefaults.standard.set(Array(list.suffix(300)), forKey: failedKey)
    }

    /// More clips when the feed is within a few of its end (and the first ones on opening).
    func loadMore(_ store: DiaryStore) async {
        guard !loading, !exhausted || !queue.isEmpty || !later.isEmpty || channelsLeft?.isEmpty == false || !channelClips.isEmpty else { return }
        guard let token = TMDBDirect.token(store) else { failure = "Cines needs TMDB. Add a key in Settings → TMDB."; return }
        loading = true
        defer { loading = false }
        failure = nil
        let before = clips.count
        var rounds = 0
        if tab == .forYou { await searchScenes(store, token: token) }
        while clips.count < before + 8, rounds < 4 {
            rounds += 1
            // The channels are read alongside TMDB.
            async let channelsRead: Void = readChannels(store, token: token)
            var fetchFailed = false
            if queue.count < 8, !exhausted {
                do { try await fill(store, token: token) }
                catch {
                    // The page wasn't read: it's asked for again next time, not skipped.
                    page = max(0, page - 1)
                    fetchFailed = true
                    if !Task.isCancelled, clips.count == before, channelClips.isEmpty { failure = FriendlyError.message(error) }
                }
            }
            var found: [CinesClip] = []
            if !queue.isEmpty {
                let batch = Array(queue.prefix(8))
                queue.removeFirst(batch.count)
                found = await Self.videos(batch, token: token)
            }
            await channelsRead
            // Up to four of the channels' clips a round, mixed in with TMDB's.
            let fromChannels = Array(channelClips.prefix(4))
            channelClips.removeFirst(fromChannels.count)
            found += fromChannels
            let failed = Self.failed
            var fresh: [CinesClip] = []
            for clip in found where !failed.contains(clip.id) && seenClips.insert(clip.id).inserted {
                if fresh.contains(where: { $0.route == clip.route }) { later.append(clip) } else { fresh.append(clip) }
            }
            // A title's second clip joins a batch or two later.
            if later.count > 6 { fresh += later.prefix(3); later.removeFirst(min(3, later.count)) }
            if fresh.isEmpty, queue.isEmpty, exhausted, channelsLeft?.isEmpty != false, channelClips.isEmpty {
                clips += later; later = []
                break
            }
            // Offline: show what this round found, and try again on the next load rather than now.
            if fetchFailed {
                clips += Self.spread(fresh.shuffled())
                break
            }
            // With a YouTube key, YouTube says first which of them play here (1 unit a batch).
            if let key = CinesYouTube.key, !fresh.isEmpty,
               let statuses = await CinesYouTube.statuses(fresh.map(\.id), key: key, region: CinesYouTube.region) {
                for (id, status) in statuses {
                    checked[id] = status.playable
                    if !status.playable { Self.markFailed(id) }
                    if let channel = status.channel, !channel.isEmpty { channels[id] = String(channel.prefix(80)) }
                }
                fresh = fresh.filter { statuses[$0.id]?.playable != false }
            }
            clips += Self.spread(fresh.shuffled())
        }
    }

    /// Whether YouTube will play a clip inside the app, asked ahead of time: its public oEmbed
    /// lookup refuses a video whose uploader switched embedding off (401, 403) or that was taken
    /// down (404). A refused clip leaves the feed and is left out from then on. When the lookup
    /// can't be made (offline), the clip stays and the player decides.
    @discardableResult func check(_ id: String) async -> Bool {
        if let known = checked[id] { return known }
        guard asking.insert(id).inserted else { return true }
        defer { asking.remove(id) }
        var parts = URLComponents(string: "https://www.youtube.com/oembed")!
        parts.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=" + id), URLQueryItem(name: "format", value: "json")]
        guard let url = parts.url else { return true }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { return true }
        let playable = ![401, 403, 404].contains(status)
        // The same lookup names the channel.
        if status == 200, channels[id] == nil, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let author = object["author_name"] as? String, !author.isEmpty {
            channels[id] = String(author.prefix(80))
        }
        checked[id] = playable
        if !playable { refuse(id) }
        return playable
    }
    /// Takes a clip out of the feed (YouTube won't play it here).
    func refuse(_ id: String) {
        checked[id] = false
        Self.markFailed(id)
        clips.removeAll { $0.id == id }
    }

    // MARK: The official channels

    /// The next two channels' newest videos, each matched to the title it names (TMDB confirming
    /// it); this tab's kind only (a show's clip in Shows, anime in Anime).
    private func readChannels(_ store: DiaryStore, token: String) async {
        guard channelClips.count < 6 else { return }
        if channelsLeft == nil {
            channelsLeft = CinesChannels.all.filter { channel in
                switch tab {
                case .anime: channel.anime
                case .shows, .movies: !channel.anime
                case .forYou: true
                }
            }.shuffled()
        }
        guard let left = channelsLeft, !left.isEmpty else { return }
        let next = Array(left.prefix(2))
        channelsLeft?.removeFirst(next.count)
        let key = CinesYouTube.key
        let pages = channelPages
        let read = await withTaskGroup(of: (CinesChannels.Channel, [CinesChannels.Video], ChannelPages?).self) { group in
            for channel in next {
                group.addTask {
                    let (videos, after) = await Self.channelVideos(channel, pages: pages[channel.id], key: key)
                    return (channel, videos, after)
                }
            }
            var all: [(CinesChannels.Channel, [CinesChannels.Video], ChannelPages?)] = []
            for await found in group { all.append(found) }
            return all
        }
        var videos: [CinesChannels.Video] = []
        for (channel, found, after) in read {
            videos += found
            // With a key, a channel with older videos left comes round again after the others.
            if let after {
                channelPages[channel.id] = after
                if after.more { channelsLeft?.append(channel) }
            }
        }
        await matchVideos(videos, token: token)
    }

    /// Matches channel (or search) videos to the titles they name and queues the ones that fit
    /// this tab.
    private func matchVideos(_ videos: [CinesChannels.Video], token: String, kind: String? = nil) async {
        let failed = Self.failed
        let fresh = videos.filter { !failed.contains($0.id) && !seenClips.contains($0.id) }
        let names = fresh.map { CinesChannels.names(in: $0.title, short: $0.short) }
        let asks = Array(Set(names.flatMap { $0 })).filter { named[$0] == nil }
        let answers = await withTaskGroup(of: (String, [Candidate]).self) { group in
            for name in asks {
                group.addTask {
                    let found = (try? await Self.titles("search/multi", ["query": name, "include_adult": "false"], kind: nil, token: token)) ?? []
                    return (name, Array(found.prefix(5)))
                }
            }
            var all: [(String, [Candidate])] = []
            for await answer in group { all.append(answer) }
            return all
        }
        for (name, found) in answers { named[name] = found }
        var matched: [CinesClip] = []
        for (video, tries) in zip(fresh, names) {
            guard let title = match(tries, anime: video.channel.anime), fits(title) else { continue }
            channels[video.id] = video.channel.name
            matched.append(CinesClip(id: video.id, kind: kind ?? Self.kind(video), name: title.name, year: title.year, route: title.route, anime: title.anime,
                                     genres: title.genres, poster: title.poster, backdrop: title.backdrop, short: video.short))
        }
        channelClips += matched.shuffled()
    }

    /// How far a channel's uploads and Shorts have been read with the YouTube key.
    struct ChannelPages: Sendable {
        var uploads: String?
        var shorts: String?
        var uploadsDone = false
        var shortsDone = false
        var more: Bool { !uploadsDone || !shortsDone }
    }

    /// A channel's next videos: with a key, the next 50 of its uploads and of its Shorts (going
    /// back as far as the channel goes); without one, or if YouTube can't be asked, its feeds' newest.
    nonisolated private static func channelVideos(_ channel: CinesChannels.Channel, pages: ChannelPages?, key: String?) async -> ([CinesChannels.Video], ChannelPages?) {
        guard let key else { return (await CinesChannels.videos(channel), nil) }
        let state = pages ?? ChannelPages()
        let tail = String(channel.id.dropFirst(2))
        async let shorts = page("UUSH" + tail, token: state.shorts, done: state.shortsDone, key: key)
        async let uploads = page("UU" + tail, token: state.uploads, done: state.uploadsDone, key: key)
        let short = await shorts, upload = await uploads
        if pages == nil, short == nil, upload == nil { return (await CinesChannels.videos(channel), nil) }
        var after = state
        if let short { after.shorts = short.next; after.shortsDone = short.next == nil } else { after.shortsDone = true }
        if let upload { after.uploads = upload.next; after.uploadsDone = upload.next == nil } else { after.uploadsDone = true }
        let shortIDs = Set((short?.videos ?? []).map(\.id))
        var found = (short?.videos ?? []).map { CinesChannels.Video(id: $0.id, title: $0.title, short: true, channel: channel) }
        for video in upload?.videos ?? [] where !shortIDs.contains(video.id) {
            found.append(CinesChannels.Video(id: video.id, title: video.title, short: false, channel: channel))
        }
        return (found, after)
    }
    nonisolated private static func page(_ playlist: String, token: String?, done: Bool, key: String) async -> (videos: [CinesYouTube.Video], next: String?)? {
        if done { return ([], nil) }
        return await CinesYouTube.playlist(playlist, page: token, key: key)
    }

    /// For you with a YouTube key: scenes from one title in your diary each time more clips load
    /// (Planned first), found by a YouTube search (100 units; at most `CinesYouTube.searchesPerDay`).
    /// A video is kept when its title names the show and it isn't a reaction, review, edit or the
    /// like; the official channels' come first.
    private func searchScenes(_ store: DiaryStore, token: String) async {
        guard let key = CinesYouTube.key, channelClips.count < 10 else { return }
        if sceneTitles == nil {
            let titles = store.workspace.titles.filter { $0.deletedAt == nil && $0.tmdbId != nil }
            let planned = titles.filter { $0.status == "planned" }.shuffled()
            let others = titles.filter { ["watching", "completed", "paused", "on_hold"].contains($0.status) }.shuffled()
            sceneTitles = (planned + others).prefix(60).compactMap(Self.candidate)
        }
        guard let title = sceneTitles?.first, CinesYouTube.takeSearch() else { return }
        sceneTitles?.removeFirst()
        let name = title.name
        let found = await CinesYouTube.search(name + (title.anime ? " anime scene" : " scene"), key: key, region: CinesYouTube.region)
        let official = Set(CinesChannels.all.map(\.id))
        let needle = CinesChannels.comparable(name)
        let skip = ["reaction", "react", "review", "explained", "explain", "amv", "edit", "fan made", "fanmade", "theory", "theories",
                    "breakdown", "recap", "ranking", "ranked", "top 10", "top 5", "analysis", "podcast", "parody", "tier list", "meme"]
        let kept = found.filter { video in
            let words = CinesChannels.comparable(video.title)
            return (" " + words + " ").contains(" " + needle + " ") && !skip.contains { (" " + words + " ").contains(" " + $0 + " ") }
                && !seenClips.contains(video.id) && !Self.failed.contains(video.id)
        }.sorted { official.contains($0.channelID) && !official.contains($1.channelID) }.prefix(3)
        let scenes = kept.map { CinesClip(id: $0.id, kind: "Scene", name: title.name, year: title.year, route: title.route, anime: title.anime,
                                         genres: title.genres, poster: title.poster, backdrop: title.backdrop) }
        for video in kept { if let channel = video.channelTitle { channels[video.id] = channel } }
        channelClips += scenes
    }

    /// The title a video names: among the names in its title, the one TMDB has under that very
    /// name (the most popular when several do), else TMDB's best match when it's close enough
    /// (`CinesChannels.same`). An anime channel's videos match anime only.
    private func match(_ tries: [String], anime: Bool) -> Candidate? {
        var exact: [Candidate] = [], close: [Candidate] = []
        for name in tries {
            let found = (named[name] ?? []).filter { !anime || $0.anime }
            exact += found.filter { CinesChannels.same(name, $0.name, best: false) || $0.original.map { CinesChannels.same(name, $0, best: false) } == true }
            if let best = found.first, CinesChannels.same(name, best.name, best: true) || best.original.map({ CinesChannels.same(name, $0, best: true) }) == true {
                close.append(best)
            }
        }
        return exact.max { $0.popularity < $1.popularity } ?? close.first
    }

    /// Whether a title belongs in this tab.
    private func fits(_ title: Candidate) -> Bool {
        switch tab {
        case .forYou: true
        case .anime: title.anime
        case .shows: !title.anime && title.route.kind == .tv
        case .movies: !title.anime && title.route.kind == .movie
        }
    }

    nonisolated private static func kind(_ video: CinesChannels.Video) -> String {
        let words = CinesChannels.comparable(video.title)
        if words.contains("teaser") { return "Teaser" }
        if words.contains("trailer") { return words.contains("official") ? "Official trailer" : "Trailer" }
        if video.short { return "Short" }
        if words.contains("opening") { return "Opening" }
        return "Clip"
    }

    /// No title twice in a row: a clip next to one of the same title swaps with the one after.
    nonisolated private static func spread(_ clips: [CinesClip]) -> [CinesClip] {
        var out = clips
        guard out.count > 2 else { return out }
        for index in 1..<out.count where out[index].route == out[index - 1].route {
            if let other = out[(index + 1)...].firstIndex(where: { $0.route != out[index - 1].route }) { out.swapAt(index, other) }
        }
        return out
    }

    // MARK: Titles

    /// The next page of titles for this tab, shuffled. In Shows, Movies and Anime, titles already
    /// in your diary go to the back and only every second one is kept (shown less often).
    private func fill(_ store: DiaryStore, token: String) async throws {
        page += 1
        if tab == .forYou { try await fillForYou(store, token: token); return }
        var found: [Candidate] = []
        switch tab {
        case .shows: found = try await Self.titles("trending/tv/week", ["page": String(page)], kind: .tv, token: token)
        case .movies: found = try await Self.titles("trending/movie/week", ["page": String(page)], kind: .movie, token: token)
        default:
            let query = ["with_genres": "16", "with_original_language": "ja", "sort_by": "popularity.desc", "include_adult": "false", "page": String(page)]
            async let shows = Self.titles("discover/tv", query, kind: .tv, token: token)
            async let movies = Self.titles("discover/movie", query.merging(["vote_count.gte": "50"]) { $1 }, kind: .movie, token: token)
            found = Self.interleave(try await shows, (try? await movies) ?? [])
        }
        if found.isEmpty || page >= 20 { exhausted = true }
        queue += unseen(found, store: store, keepOwned: false).shuffled()
    }

    /// For you (owner's request, 25 Nov 2026: "some from my library, some from recommendations,
    /// trending, high rated, very popular, genres I like, shuffled so it looks random"). Each round
    /// takes a few from each, at a page picked at random, and shuffles them together:
    /// - your diary: titles you've planned, are watching or have watched;
    /// - recommendations from two titles you've watched lately or loved;
    /// - trending this week;
    /// - top rated (well-known titles only: many votes);
    /// - popular right now;
    /// - popular in a genre you watch most.
    private func fillForYou(_ store: DiaryStore, token: String) async throws {
        if mine == nil { prepareForYou(store) }
        let own = Array((mine ?? []).prefix(3))
        mine?.removeFirst(own.count)
        let rated = Bool.random() ? MediaKind.movie : .tv
        let popular: MediaKind = rated == .movie ? .tv : .movie
        let trendingPage = nextPage("trending", start: 1...3)
        let ratedQuery = ["sort_by": "vote_average.desc", "vote_count.gte": rated == .movie ? "2000" : "800", "include_adult": "false",
                          "page": String(nextPage("rated." + rated.rawValue, start: 1...5))]
        let popularPage = nextPage("popular." + popular.rawValue, start: 1...5)
        let genre = liked.randomElement()
        let genreQuery = genre.map { ["with_genres": String($0.id), "sort_by": "popularity.desc", "vote_count.gte": "150", "include_adult": "false",
                                      "page": String(nextPage("genre.\($0.kind.rawValue).\($0.id)", start: 1...3))] }
        let picks = Array(seeds.shuffled().prefix(2))

        async let trending = Self.titles("trending/all/week", ["page": String(trendingPage)], kind: nil, token: token)
        async let top = Self.titles("discover/" + Self.path(rated), ratedQuery, kind: rated, token: token)
        async let hot = Self.titles(Self.path(popular) + "/popular", ["page": String(popularPage)], kind: popular, token: token)
        var inGenre: [Candidate] = []
        if let genre, let genreQuery { inGenre = (try? await Self.titles("discover/" + Self.path(genre.kind), genreQuery, kind: genre.kind, token: token)) ?? [] }
        var similar: [Candidate] = []
        for seed in picks {
            let more = (try? await Self.titles("\(Self.path(seed.kind))/\(seed.id)/recommendations", ["page": String(Int.random(in: 1...2))], kind: seed.kind, token: token)) ?? []
            similar += more.shuffled().prefix(5)
        }
        var trendingError: Error?
        let trend: [Candidate]
        do { trend = try await trending } catch { trend = []; trendingError = error }
        let topRated = (try? await top) ?? []
        let popularNow = (try? await hot) ?? []
        let others: [Candidate] = Array(trend.shuffled().prefix(5)) + Array(topRated.shuffled().prefix(4))
            + Array(popularNow.shuffled().prefix(4)) + Array(inGenre.shuffled().prefix(4)) + similar
        if let trendingError, own.isEmpty, others.isEmpty { throw trendingError }
        if page >= 15 { exhausted = true }
        queue += (unseen(own, store: store, keepOwned: true) + unseen(others, store: store, keepOwned: false)).shuffled()
    }

    /// Titles not shown yet. Unless `keepOwned`, ones already in your diary are cut by half.
    private func unseen(_ found: [Candidate], store: DiaryStore, keepOwned: Bool) -> [Candidate] {
        var fresh: [Candidate] = [], owned: [Candidate] = []
        for item in found where seenTitles.insert(item.route.kind.rawValue + ":" + String(item.route.id)).inserted {
            let probe = CatalogItem(id: item.route.id, mediaType: item.route.kind, name: item.name)
            if !keepOwned, store.libraryIdentity(probe) != nil { owned.append(item) } else { fresh.append(item) }
        }
        return fresh + owned.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
    }

    /// A source's next page: the first one at random in `start`, then one after another.
    private func nextPage(_ key: String, start: ClosedRange<Int>) -> Int {
        let value = sourcePages[key].map { $0 + 1 } ?? Int.random(in: start)
        sourcePages[key] = value
        return value
    }

    /// Reads your diary once: its titles (shuffled), the ones to take recommendations from (watched
    /// lately, favourites, scored 8 or more), and the genres you watch most (favourites count twice).
    private func prepareForYou(_ store: DiaryStore) {
        let titles = store.workspace.titles.filter { $0.deletedAt == nil && $0.tmdbId != nil }
        mine = titles.filter { ["planned", "watching", "completed", "paused", "on_hold"].contains($0.status) }
            .shuffled().prefix(80).compactMap(Self.candidate)
        let watched = titles.filter { ["watching", "completed"].contains($0.status) }
        let recent = watched.sorted { ($0.updatedAt ?? $0.createdAt ?? "") > ($1.updatedAt ?? $1.createdAt ?? "") }.prefix(12)
        let loved = watched.filter { $0.favorite || ($0.score ?? 0) >= 8 }.shuffled().prefix(8)
        var routes: [CatalogRoute] = []
        for title in Array(recent) + Array(loved) {
            guard let id = title.tmdbId else { continue }
            let route = CatalogRoute(kind: title.isSeries ? .tv : .movie, id: id)
            if !routes.contains(route) { routes.append(route) }
        }
        seeds = routes
        var counts: [String: Int] = [:]
        for title in watched { for name in title.genres { counts[name, default: 0] += title.favorite ? 2 : 1 } }
        let top = counts.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        liked = top.flatMap { name -> [(kind: MediaKind, id: Int)] in
            var found: [(kind: MediaKind, id: Int)] = []
            if let id = Self.movieGenreIDs[name] { found.append((kind: .movie, id: id)) }
            if let id = Self.tvGenreIDs[name] { found.append((kind: .tv, id: id)) }
            return found
        }
    }

    private static func candidate(_ title: MediaTitle) -> Candidate? {
        guard let id = title.tmdbId else { return nil }
        let anime = title.category.hasPrefix("anime")
        return Candidate(route: CatalogRoute(kind: title.isSeries ? .tv : .movie, id: id), name: title.name, year: title.year, anime: anime,
                         genres: Array(title.genres.filter { $0 != "Animation" || !anime }.prefix(2)),
                         poster: title.poster, backdrop: title.backdrop, popularity: 0)
    }

    nonisolated private static func path(_ kind: MediaKind) -> String { kind == .movie ? "movie" : "tv" }

    /// Genre names (as the diary keeps them) to TMDB's ids, for movies and for TV.
    private static let movieGenreIDs: [String: Int] = [
        "Action": 28, "Action & Adventure": 28, "Adventure": 12, "Animation": 16, "Comedy": 35, "Crime": 80, "Documentary": 99,
        "Drama": 18, "Family": 10751, "Fantasy": 14, "History": 36, "Horror": 27, "Music": 10402, "Mystery": 9648, "Romance": 10749,
        "Science Fiction": 878, "Sci-Fi": 878, "Sci-Fi & Fantasy": 878, "Thriller": 53, "War": 10752, "War & Politics": 10752, "Western": 37,
    ]
    private static let tvGenreIDs: [String: Int] = [
        "Action": 10759, "Action & Adventure": 10759, "Adventure": 10759, "Animation": 16, "Comedy": 35, "Crime": 80, "Documentary": 99,
        "Drama": 18, "Family": 10751, "Kids": 10762, "Mystery": 9648, "Reality": 10764, "Science Fiction": 10765, "Sci-Fi": 10765,
        "Fantasy": 10765, "Sci-Fi & Fantasy": 10765, "War": 10768, "War & Politics": 10768, "Western": 37,
    ]

    private static func interleave(_ a: [Candidate], _ b: [Candidate]) -> [Candidate] {
        var out: [Candidate] = []
        for index in 0..<max(a.count, b.count) {
            if index < a.count { out.append(a[index]) }
            if index < b.count { out.append(b[index]) }
        }
        return out
    }

    nonisolated private static func titles(_ path: String, _ query: [String: String], kind: MediaKind?, token: String) async throws -> [Candidate] {
        let data = try await TMDBDirect.data(path, query: query, token: token)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (object["results"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, id > 0, item["adult"] as? Bool != true else { return nil }
            let media: MediaKind
            if let kind { media = kind }
            else if let type = item["media_type"] as? String, let kind = MediaKind(rawValue: type) { media = kind }
            else { return nil }
            guard let name = (item["name"] ?? item["title"]) as? String, !name.isEmpty else { return nil }
            let date = (item["first_air_date"] ?? item["release_date"]) as? String
            let year = date.flatMap { Int($0.prefix(4)) }
            let genreIDs = item["genre_ids"] as? [Int] ?? []
            let anime = genreIDs.contains(16) && (item["original_language"] as? String) == "ja"
            return Candidate(route: CatalogRoute(kind: media, id: id), name: String(name.prefix(200)), year: year, anime: anime,
                             genres: genreIDs.compactMap { genreNames[$0] }.filter { $0 != "Animation" || !anime },
                             poster: CatalogTools.image(item["poster_path"] as? String, size: "w342"),
                             backdrop: CatalogTools.image(item["backdrop_path"] as? String, size: "w780"),
                             popularity: item["popularity"] as? Double ?? 0,
                             original: (item["original_name"] ?? item["original_title"]) as? String)
        }
    }

    // MARK: Videos

    /// For each title its best trailer (or teaser) and its best clip (a scene, a featurette),
    /// official uploads first, read side by side.
    private static func videos(_ titles: [Candidate], token: String) async -> [CinesClip] {
        await withTaskGroup(of: (Int, [CinesClip]).self) { group in
            for (index, title) in titles.enumerated() {
                group.addTask {
                    let path = "\(title.route.kind == .movie ? "movie" : "tv")/\(title.route.id)/videos"
                    guard let data = try? await TMDBDirect.data(path, query: ["include_video_language": title.anime ? "en,ja" : "en"], token: token) else { return (index, []) }
                    return (index, Self.pick(data, title: title))
                }
            }
            var found: [(Int, [CinesClip])] = []
            for await result in group { found.append(result) }
            return found.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    nonisolated private static let typeRank = ["Trailer": 0, "Teaser": 1, "Clip": 2, "Featurette": 3, "Opening Credits": 4, "Behind the Scenes": 5]

    nonisolated private static func pick(_ data: Data, title: Candidate) -> [CinesClip] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let videos = (object["results"] as? [[String: Any]] ?? []).compactMap { item -> Video? in
            guard item["site"] as? String == "YouTube", let key = item["key"] as? String,
                  key.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil,
                  let type = item["type"] as? String, typeRank[type] != nil else { return nil }
            // English videos only (owner's call, 25 Nov 2026: Alien came up with Disney+ Japan's
            // trailer); anime may also have Japanese ones, English first.
            let language = item["iso_639_1"] as? String ?? ""
            guard language == "en" || (title.anime && language == "ja") else { return nil }
            return Video(key: key, type: type, official: item["official"] as? Bool ?? false, published: item["published_at"] as? String ?? "", english: language == "en")
        }
        func best(_ types: Set<String>) -> Video? {
            videos.filter { types.contains($0.type) }.sorted {
                if $0.official != $1.official { return $0.official }
                if $0.english != $1.english { return $0.english }
                if typeRank[$0.type]! != typeRank[$1.type]! { return typeRank[$0.type]! < typeRank[$1.type]! }
                return $0.published > $1.published
            }.first
        }
        let chosen = [best(["Trailer", "Teaser"]), best(["Clip", "Featurette", "Opening Credits", "Behind the Scenes"])].compactMap { $0 }
        return chosen.map { video in
            CinesClip(id: video.key, kind: video.label, name: title.name, year: title.year, route: title.route, anime: title.anime,
                      genres: title.genres, poster: title.poster, backdrop: title.backdrop)
        }
    }

    /// TMDB's genre ids (the same for every language and stable for years), movie and TV together.
    nonisolated private static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
        10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western", 10759: "Action", 10762: "Kids",
        10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk", 10768: "War & Politics",
    ]
}

/// One YouTube video TMDB lists for a title.
private struct Video {
    let key: String
    let type: String
    let official: Bool
    let published: String
    let english: Bool
    var label: String {
        switch type {
        case "Trailer": official ? "Official trailer" : "Trailer"
        case "Teaser": "Teaser"
        case "Clip": "Clip"
        case "Featurette": "Featurette"
        case "Opening Credits": "Opening"
        default: "Behind the scenes"
        }
    }
}

// MARK: A title's trailer

extension CinesFeed {
    /// A title's trailer for its page's cover: TMDB's YouTube trailer (else teaser), official first,
    /// English (anime: Japanese too, English first), the newest.
    static func trailer(tmdb: Int, series: Bool, anime: Bool, token: String) async -> String? {
        let path = "\(series ? "tv" : "movie")/\(tmdb)/videos"
        guard let data = try? await TMDBDirect.data(path, query: ["include_video_language": anime ? "en,ja" : "en"], token: token) else { return nil }
        return bestTrailer(data, anime: anime)
    }
    nonisolated static func bestTrailer(_ data: Data, anime: Bool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        struct Found { let key: String; let trailer: Bool; let official: Bool; let english: Bool; let published: String }
        let found = (object["results"] as? [[String: Any]] ?? []).compactMap { item -> Found? in
            guard item["site"] as? String == "YouTube", let key = item["key"] as? String,
                  key.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil,
                  let type = item["type"] as? String, type == "Trailer" || type == "Teaser" else { return nil }
            let language = item["iso_639_1"] as? String ?? ""
            guard language == "en" || (anime && language == "ja") else { return nil }
            return Found(key: key, trailer: type == "Trailer", official: item["official"] as? Bool ?? false,
                         english: language == "en", published: item["published_at"] as? String ?? "")
        }
        return found.sorted {
            if $0.official != $1.official { return $0.official }
            if $0.english != $1.english { return $0.english }
            if $0.trailer != $1.trailer { return $0.trailer }
            return $0.published > $1.published
        }.first?.key
    }
}
