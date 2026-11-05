import Foundation

// Trakt-first plan, phase 4a (ios/docs/TRAKT-CLIENT-PLAN.md): the diary built from Trakt. Trakt is
// the record for watches, ratings, Planned (watchlist), favourites and dropped; the server's diary
// supplies what Trakt doesn't hold: posters and episode details, categories (anime), tags, notes,
// file locations and trash. Titles keep the server's ids where one exists, so file locations,
// notes and tags stay attached. Read-only for now: edits go back to the server diary.

public enum TraktDiary {
    /// `tracker`: the service the library comes from. What it doesn't keep (favourites on Simkl and
    /// MDBList) stays as the server has it.
    public static func build(library: TraktLibrary, server: Workspace, tracker: MainTracker = .trakt) -> Workspace {
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
            titles.append(value); idForKey[k] = title.id
        }
        for (k, ref) in refs.sorted(by: { $0.key < $1.key }) where idForKey[k] == nil {
            var value = MediaTitle(id: k, name: ref.name, category: ref.kind == .movie ? "movie" : "show", year: ref.year, overview: "",
                                   poster: nil, backdrop: nil, communityScore: nil, tmdbId: ref.tmdbId, genres: [], tags: [], runtimeMinutes: nil,
                                   status: "planned", favorite: false, queued: false, score: nil, notes: "", deletedAt: nil, version: 1,
                                   seasons: nil, createdAt: nil)
            apply(&value, key: k, rating: rated[k], watchlist: watchlist, favourites: favourites, dropped: dropped, played: played)
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
