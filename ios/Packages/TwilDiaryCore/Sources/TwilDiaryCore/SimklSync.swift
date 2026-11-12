import Foundation

/// Simkl's own sync rules (api.simkl.org/guides/sync): the whole library once, then only what
/// changed. `/sync/activities` says what moved; changed items come from
/// `/sync/all-items?date_from=<the saved "all">` and are merged in; ratings (not in item deltas)
/// are read again from `/sync/ratings/{type}` when `rated_at` moved; removals are found by
/// diffing `/sync/all-items?extended=simkl_ids_only` when `removed_from_list` moved.
public enum SimklSync {
    public enum Step: Equatable, Sendable {
        /// Nothing moved since the saved snapshot.
        case none
        /// The whole library (first read, no snapshot, or a copy from before Simkl ids were kept).
        case full
        /// Only what moved, since `since` (the saved snapshot's "all", sent back exactly as given).
        case delta(items: Bool, ratings: Bool, removals: Bool, since: String)
    }

    /// Kept among a copy's activities once it was read with Simkl's TVDB numbering for anime
    /// (`extended=full_anime_seasons`). A copy without it numbered each anime season entry from
    /// season 1 (Simkl's own way) and is read in full once. Not one of Simkl's lists, so never
    /// seen as a change.
    public static let animeSeasonsMark = "twildiary.anime_tvdb_seasons"
    public static func marked(_ activities: TraktActivities) -> TraktActivities {
        var stamps = activities.stamps
        stamps[animeSeasonsMark] = "1"
        return TraktActivities(all: activities.all, stamps: stamps)
    }

    public static func step(previous: TraktLibrary?, now: TraktActivities) -> Step {
        guard let previous, previous.fetchedAt != nil, let saved = previous.activities, let since = saved.all,
              now.all != nil, hasSimklIDs(previous), saved.stamps[animeSeasonsMark] != nil else { return .full }
        if now.all == since { return .none }
        var items = false, ratings = false, removals = false
        for key in Set(now.stamps.keys).union(saved.stamps.keys) where now.stamps[key] != saved.stamps[key] {
            let parts = key.split(separator: ".").map(String.init)
            guard let section = parts.first, ["tv_shows", "shows", "anime", "movies"].contains(section), let field = parts.last else { continue }
            switch field {
            case "rated_at": ratings = true
            case "removed_from_list": removals = true
            case "playback", "all": continue
            default: items = true  // watching, plantowatch, hold, completed, dropped, or anything new
            }
        }
        return .delta(items: items, ratings: ratings, removals: removals, since: since)
    }

    /// The copy was read since Simkl ids were kept. Entries your own edits add have none (they're
    /// matched by TMDB id and replaced by the next delta), so one id anywhere is enough; a copy
    /// saved before ids were kept has none at all and is read in full once.
    static func hasSimklIDs(_ library: TraktLibrary) -> Bool {
        let all = titles(library)
        return all.isEmpty || all.contains { $0.simklId != nil }
    }
    static func titles(_ library: TraktLibrary) -> [TraktTitleRef] {
        var result: [TraktTitleRef] = library.plays.map(\.title)
        result += library.ratings.map(\.title)
        result += library.watchlist.map(\.title)
        result += library.dropped.map(\.title)
        result += library.notes.compactMap(\.title)
        return result
    }

    /// Changed items replace everything the copy had for those titles (`touched`: every Simkl id
    /// in the delta, so an item that now reads as nothing still clears its old entries).
    public static func merge(_ delta: TraktLibrary, touched: Set<Int>, into library: TraktLibrary) -> TraktLibrary {
        let ids = touched.union(titles(delta).compactMap(\.simklId))
        let keys = Set(titles(delta).compactMap(\.diaryKey))
        func replaced(_ title: TraktTitleRef) -> Bool {
            (title.simklId.map(ids.contains) ?? false) || (title.diaryKey.map(keys.contains) ?? false)
        }
        var result = library
        result.plays = library.plays.filter { !replaced($0.title) } + delta.plays
        result.ratings = library.ratings.filter { !replaced($0.title) } + delta.ratings
        result.watchlist = library.watchlist.filter { !replaced($0.title) } + delta.watchlist
        result.dropped = library.dropped.filter { !replaced($0.title) } + delta.dropped
        result.notes = library.notes.filter { note in !(note.title.map(replaced) ?? false) } + delta.notes
        return result
    }

    /// Drops titles Simkl no longer lists (`keeping`: every Simkl id in the library now).
    public static func removing(from library: TraktLibrary, keeping: Set<Int>) -> TraktLibrary {
        func kept(_ title: TraktTitleRef) -> Bool { title.simklId.map(keeping.contains) ?? true }
        var result = library
        result.plays = library.plays.filter { kept($0.title) }
        result.ratings = library.ratings.filter { kept($0.title) }
        result.watchlist = library.watchlist.filter { kept($0.title) }
        result.dropped = library.dropped.filter { kept($0.title) }
        result.notes = library.notes.filter { note in note.title.map(kept) ?? true }
        return result
    }
}
