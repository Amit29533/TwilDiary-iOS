import Foundation

// Trakt-first plan, phase 4a (ios/docs/TRAKT-CLIENT-PLAN.md): the diary built from Trakt. Trakt is
// the record for watches, ratings, Planned (watchlist), favourites and dropped; the server's diary
// supplies what Trakt doesn't hold: posters and episode details, categories (anime), tags, notes,
// file locations and trash. Titles keep the server's ids where one exists, so file locations,
// notes and tags stay attached. Read-only for now: edits go back to the server diary.

public enum TraktDiary {
    /// `tracker`: the service the library comes from. What it doesn't keep (favourites on Simkl and
    /// MDBList) stays as the server has it.
    /// `catalog`: titles made on the phone from TMDB (`catalogTitle`) for what's only on the
    /// service, so they show their poster, seasons and category without joining the server.
    public static func build(library: TraktLibrary, server: Workspace, tracker: MainTracker = .trakt, catalog: [String: MediaTitle] = [:]) -> Workspace {
        let keepsFavourites = tracker.capabilities.holdsFavourites
        func key(_ title: MediaTitle) -> String? { title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) } }
        var serverByKey: [String: MediaTitle] = [:]
        for title in server.titles { if let k = key(title), serverByKey[k] == nil || title.deletedAt == nil { serverByKey[k] = title } }

        // Every title Trakt knows, with what it says about it.
        var refs: [String: TraktTitleRef] = [:]
        for ref in library.plays.map(\.title) + library.ratings.map(\.title) + library.watchlist.map(\.title)
            + library.favorites.map(\.title) + library.dropped.map(\.title) {
            if let k = ref.diaryKey, refs[k] == nil { refs[k] = ref }
        }
        let rated = Dictionary(library.ratings.compactMap { r in r.title.diaryKey.map { ($0, r.rating) } }, uniquingKeysWith: { first, _ in first })
        func keys(_ list: [TraktListed]) -> Set<String> { Set(list.compactMap(\.title.diaryKey)) }
        let watchlist = keys(library.watchlist), favourites = keys(library.favorites), dropped = keys(library.dropped)
        // Each title's note on the service (the newest, when there are several).
        var notes: [String: String] = [:]
        for note in library.notes.sorted(by: { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }) {
            if let k = note.title?.diaryKey, !note.text.isEmpty { notes[k] = note.text }
        }
        func note(_ server: String, _ k: String) -> String {
            // The service's note, unless the server keeps the same note in full (over the service's limit).
            guard let text = notes[k] else { return server }
            return server.hasPrefix(text) ? server : text
        }
        var played = Set<String>()
        for play in library.plays { if let k = play.title.diaryKey { played.insert(k) } }

        var titles: [MediaTitle] = []
        var idForKey: [String: String] = [:]
        // Server titles first (keeping their ids, extras and order), then Trakt-only ones.
        for title in server.titles {
            guard let k = key(title), refs[k] != nil else { titles.append(title); continue }
            guard serverByKey[k]?.id == title.id else { titles.append(title); continue }
            var value = title
            apply(&value, key: k, rating: rated[k], watchlist: watchlist, favourites: favourites, dropped: dropped, played: played)
            if !keepsFavourites { value.favorite = title.favorite }
            value.notes = note(title.notes, k)
            titles.append(value); idForKey[k] = title.id
        }
        for (k, ref) in refs.sorted(by: { $0.key < $1.key }) where idForKey[k] == nil {
            var value = catalog[k] ?? MediaTitle(id: k, name: ref.name, category: ref.kind == .movie ? "movie" : "show", year: ref.year, overview: "",
                                   poster: nil, backdrop: nil, communityScore: nil, tmdbId: ref.tmdbId, genres: [], tags: [], runtimeMinutes: nil,
                                   status: "planned", favorite: false, queued: false, score: nil, notes: "", deletedAt: nil, version: 1,
                                   seasons: nil, createdAt: nil)
            apply(&value, key: k, rating: rated[k], watchlist: watchlist, favourites: favourites, dropped: dropped, played: played)
            value.notes = note(value.notes, k)
            titles.append(value); idForKey[k] = k
        }

        // Watches come from Trakt only; episodes from the server, or made up from the play.
        var episodes = server.episodes
        var episodeIndex: [String: String] = [:]
        for episode in server.episodes { episodeIndex["\(episode.titleId)|\(episode.season)|\(episode.number)"] = episode.id }
        var events: [WatchEvent] = []
        for play in library.plays {
            guard let k = play.title.diaryKey, let titleID = idForKey[k] else { continue }
            var episodeID: String?
            if let season = play.season, let number = play.episode {
                let slot = "\(titleID)|\(season)|\(number)"
                if let found = episodeIndex[slot] { episodeID = found }
                else {
                    let made = "\(titleID)|s\(season)e\(number)"
                    episodes.append(Episode(id: made, titleId: titleID, season: season, number: number, name: "", overview: "",
                                            airedOn: nil, still: nil, hidden: nil, communityScore: nil, skipped: nil))
                    episodeIndex[slot] = made; episodeID = made
                }
            }
            let stamp = play.watchedAt ?? library.fetchedAt ?? "1970-01-01T00:00:00.000Z"
            events.append(WatchEvent(id: "trakt-\(play.historyId)", operationId: "trakt-\(play.historyId)", titleId: titleID, episodeId: episodeID,
                                     watchedAt: play.watchedAt, recordedAt: stamp, origin: tracker.rawValue))
        }
        return Workspace(titles: titles, episodes: episodes, events: events, locations: server.locations)
    }

    /// A title as the phone knows it from TMDB (no server record): its key ("tv:1399") as id,
    /// name, year, poster and backdrop, genres, runtime, score, seasons and category (anime when
    /// TMDB says Japanese animation), the same facts the server stores when a title is added.
    public static func catalogTitle(_ details: CatalogDetails) -> MediaTitle {
        let key = (details.mediaType == .tv ? "tv:" : "movie:") + String(details.id)
        let seasons = details.seasons?.map { Season(number: $0.number, name: $0.name, expectedEpisodes: $0.expectedEpisodes, metadataLoadedAt: nil, metadataVersion: nil) }
        return MediaTitle(id: key, name: details.name, category: details.suggestedCategory, year: details.year, overview: details.overview,
                          poster: CatalogTools.image(details.posterPath), backdrop: CatalogTools.image(details.backdropPath, size: "w780"),
                          communityScore: details.communityScore, tmdbId: details.id, genres: details.genres, tags: [],
                          runtimeMinutes: details.runtimeMinutes, status: "planned", favorite: false, queued: false, score: nil, notes: "",
                          deletedAt: nil, version: 1, seasons: details.mediaType == .tv ? seasons : nil, createdAt: nil)
    }

    /// Trakt's word on a title: rating, favourite, and its status (dropped, Planned, or watched).
    private static func apply(_ title: inout MediaTitle, key: String, rating: Int?, watchlist: Set<String>, favourites: Set<String>,
                              dropped: Set<String>, played: Set<String>) {
        title.score = rating.map(Double.init)
        title.favorite = favourites.contains(key)
        if dropped.contains(key) { title.status = "dropped" }
        else if played.contains(key) {
            // Trakt has no Completed, Paused or dropped-movie state: the server's record of the
            // title keeps your choice (the app saves it there), a watched movie is complete, and
            // anything else with watches is being watched.
            if ["completed", "paused", "on_hold"].contains(title.status) || (!title.isSeries && title.status == "dropped") { }
            else { title.status = title.isSeries ? "watching" : "completed" }
        } else if watchlist.contains(key) { title.status = "planned" }
        // A show Trakt no longer has dropped is back to Planned; a dropped movie stays dropped
        // (Trakt only drops shows, so the server keeps that).
        else if title.status == "dropped" && title.isSeries { title.status = "planned" }
    }
}

/// An episode as TMDB lists it, kept in the phone's catalog.
public struct CatalogEpisodeFact: Codable, Hashable, Sendable {
    public let season: Int
    public let number: Int
    public let name: String
    public let overview: String
    public let airedOn: String?
    public let stillPath: String?
    public let communityScore: Double?
    public init(season: Int, number: Int, name: String, overview: String, airedOn: String?, stillPath: String?, communityScore: Double?) {
        self.season = season; self.number = number; self.name = name; self.overview = overview
        self.airedOn = airedOn; self.stillPath = stillPath; self.communityScore = communityScore
    }
}

public extension TraktDiary {
    /// Adds the phone's TMDB episode lists to a diary built from the service, so shows have every
    /// episode (air dates for progress, the calendar and "next up") without the server's copy.
    /// An episode the diary already has keeps its id and your marks (skipped); names, summaries
    /// and stills show only once you've watched the episode, as the server's spoiler rule does.
    static func addingCatalogEpisodes(_ diary: Workspace, catalog: [String: [CatalogEpisodeFact]]) -> Workspace {
        guard !catalog.isEmpty else { return diary }
        var result = diary
        var index: [String: Int] = [:]
        for (position, episode) in diary.episodes.enumerated() { index["\(episode.titleId)|\(episode.season)|\(episode.number)"] = position }
        let watched = Set(diary.events.filter { $0.revokedAt == nil }.compactMap(\.episodeId))
        for title in diary.titles where title.isSeries {
            guard let tmdb = title.tmdbId, let facts = catalog["tv:" + String(tmdb)] else { continue }
            for fact in facts {
                let slot = "\(title.id)|\(fact.season)|\(fact.number)"
                let id = index[slot].map { diary.episodes[$0].id } ?? "\(title.id)|s\(fact.season)e\(fact.number)"
                let seen = watched.contains(id)
                let episode = Episode(id: id, titleId: title.id, season: fact.season, number: fact.number,
                                      name: seen ? fact.name : "", overview: seen ? fact.overview : "", airedOn: fact.airedOn,
                                      still: seen ? CatalogTools.image(fact.stillPath) : nil, hidden: !seen,
                                      communityScore: fact.communityScore, skipped: index[slot].flatMap { diary.episodes[$0].skipped })
                if let position = index[slot] {
                    // Keep what the diary already shows when TMDB has less (a renamed or missing episode).
                    let current = diary.episodes[position]
                    result.episodes[position] = Episode(id: current.id, titleId: current.titleId, season: current.season, number: current.number,
                                                        name: episode.name.isEmpty ? current.name : episode.name,
                                                        overview: episode.overview.isEmpty ? current.overview : episode.overview,
                                                        airedOn: episode.airedOn ?? current.airedOn, still: episode.still ?? current.still,
                                                        hidden: episode.hidden, communityScore: episode.communityScore ?? current.communityScore,
                                                        skipped: current.skipped)
                } else {
                    index[slot] = result.episodes.count
                    result.episodes.append(episode)
                }
            }
        }
        return result
    }
}
