import Foundation

// WeTrakr (api.wetrakr.com, public API v1): sign-in with PKCE, compact lists for the first read,
// then its journal for "what changed and how", the way its sync guide describes. Everything is
// read into the shared `TraktLibrary` model. An entry that can't be identified is counted in
// `skipped`, never guessed.

/// Request bodies for WeTrakr's tracking writes.
public enum WeTrakrWrite {
    /// The headers every WeTrakr call carries (the app key names the app; the token is the account).
    public static func headers(clientId: String, accessToken: String?) -> [String: String] {
        var headers = ["Accept": "application/json", "Content-Type": "application/json", "wetrakr-api-version": "1", "wetrakr-api-key": clientId]
        if let accessToken, !accessToken.isEmpty { headers["Authorization"] = "Bearer " + accessToken }
        return headers
    }
    /// A Trakt-shaped watch ({ids, watched_at} or {ids, seasons: [{number, episodes: [{number,
    /// watched_at}]}]}) as WeTrakr's: status "watched" with tracked_at. `rewatch` logs another play
    /// of something already watched (a real rewatch) instead of WeTrakr refusing it.
    public static func watched(_ watch: [String: Any], rewatch: Bool) -> [String: Any] {
        var item: [String: Any] = ["status": "watched", "allow_rewatch": rewatch]
        if let ids = watch["ids"] { item["ids"] = ids }
        if let date = watch["watched_at"] { item["tracked_at"] = date }
        if let seasons = watch["seasons"] as? [[String: Any]] {
            item["seasons"] = seasons.map { season -> [String: Any] in
                var next: [String: Any] = ["number": season["number"] ?? 0]
                next["episodes"] = (season["episodes"] as? [[String: Any]] ?? []).map { episode -> [String: Any] in
                    var value: [String: Any] = ["number": episode["number"] ?? 0]
                    if let date = episode["watched_at"] { value["tracked_at"] = date }
                    return value
                }
                return next
            }
        }
        return item
    }
    /// The token exchange: JSON with the app key, the code and the PKCE verifier.
    public static func codeBody(code: String, clientId: String, verifier: String, redirect: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["client_id": clientId, "code": code, "code_verifier": verifier, "redirect_uri": redirect], options: [.sortedKeys])) ?? Data()
    }
    public static func refreshBody(refreshToken: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])) ?? Data()
    }
    public static let tokenURL = URL(string: "https://api.wetrakr.com/oauth/token")!
    public static let refreshURL = URL(string: "https://api.wetrakr.com/oauth/token/refresh")!
}

public enum WeTrakrDecode {
    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func int(_ value: Any?) -> Int? { TrackerDecode.int(value) }
    static func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
    static func rows(_ data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let rows = json as? [[String: Any]] { return rows }
        if let rows = (json as? [String: Any])?["data"] as? [[String: Any]] { return rows }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "WeTrakr sent a list in an unknown shape."))
    }
    static func ref(kind: TraktTitleRef.Kind, id: Any?, ids: Any?, name: Any? = nil) -> TraktTitleRef? {
        let ids = object(ids) ?? [:]
        let tmdb = int(ids["tmdb"]), own = int(id)
        guard tmdb != nil || own != nil else { return nil }
        return TraktTitleRef(kind: kind, traktId: nil, tmdbId: tmdb, imdbId: text(ids["imdb"]), tvdbId: int(ids["tvdb"]),
                             name: text(name) ?? "", weTrakrId: own)
    }

    /// `/sync/last_activities`: every section's stamps, flattened to "section.field".
    public static func activities(from data: Data) throws -> TraktActivities {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "WeTrakr sent unreadable activities."))
        }
        var stamps: [String: String] = [:]
        for (section, value) in root {
            if let fields = value as? [String: Any] {
                for (field, stamp) in fields { if let stamp = stamp as? String { stamps[section + "." + field] = stamp } }
            }
        }
        if let visible = root["journal_visible_until"] as? String { stamps["journal_visible_until"] = visible }
        return TraktActivities(all: root["all"] as? String, stamps: stamps)
    }

    /// One page of `/sync/tracking/watched/history/{movies|episodes}?compact=true`: every play,
    /// rewatches included, with WeTrakr's play_id.
    public static func plays(from data: Data, skipped: inout Int) throws -> [TraktPlay] {
        try rows(data).compactMap { row in
            guard let playID = text(row["play_id"]) else { skipped += 1; return nil }
            let date = row["watched_at_unknown"] as? Bool == true ? nil : text(row["watched_at"])
            if text(row["type"]) == "movie" {
                guard let title = ref(kind: .movie, id: row["id"], ids: row["ids"], name: row["title"]) else { skipped += 1; return nil }
                return TraktPlay(historyId: TrackerDecode.playID("wetrakr|" + playID), title: title, watchedAt: date, remoteId: playID)
            }
            // The show's name, where WeTrakr gives it (otherwise the compare lists it nameless).
            let showName = row["show_title"] ?? row["show_name"] ?? (object(row["show"])?["title"])
            guard let show = ref(kind: .show, id: row["show_id"], ids: row["show_ids"], name: showName),
                  let season = int(row["season_number"]) ?? (row["season_number"] as? Int), let number = int(row["number"]) else { skipped += 1; return nil }
            return TraktPlay(historyId: TrackerDecode.playID("wetrakr|" + playID), title: show, season: season, episode: number, watchedAt: date, remoteId: playID)
        }
    }

    /// A compact title list (`/sync/tracking/{planning|dropped}/{target}`, `/sync/favorites/{target}`).
    public static func listed(from data: Data, skipped: inout Int) throws -> [TraktListed] {
        try rows(data).compactMap { row in
            guard let kind = kind(row["type"]), let title = ref(kind: kind, id: row["id"], ids: row["ids"], name: row["title"]) else { skipped += 1; return nil }
            return TraktListed(title: title, listedAt: text(row["tracked_at"]) ?? text(row["favorited_at"]))
        }
    }

    /// `/sync/ratings/{target}?compact=true`: 0–10 with one decimal, kept as the nearest whole number.
    public static func ratings(from data: Data, skipped: inout Int) throws -> [TraktRating] {
        try rows(data).compactMap { row in
            guard let kind = kind(row["type"]) else { return nil }  // seasons, episodes, people aren't diary ratings
            let value = (row["rating"] as? NSNumber)?.doubleValue
            guard let title = ref(kind: kind, id: row["id"], ids: row["ids"], name: row["title"]), let value, (0...10).contains(value) else { skipped += 1; return nil }
            return TraktRating(title: title, rating: Int(value.rounded()), ratedAt: text(row["rated_at"]))
        }
    }

    static func kind(_ value: Any?) -> TraktTitleRef.Kind? {
        switch value as? String { case "movie": .movie; case "show": .show; default: nil }
    }

    /// What one journal read changed.
    public struct JournalResult: Equatable, Sendable {
        /// The next from_date: the newest action_at applied, or visible_until when nothing came.
        public var mark: String?
        public var applied = 0
        /// Something the journal can't place on its own (an episode of a show this copy has never
        /// seen, an expired journal): read the lists again in full.
        public var needsFullRead = false
        public var hasMore = false
        /// How many entries the page held (a full page means there may be more).
        public var entries = 0
    }

    /// Applies one page of `/sync/journal` (oldest first) to the library. `seen` holds entry_ids
    /// already applied, so re-reading from the same mark never applies one twice.
    public static func applyJournal(_ data: Data, to library: inout TraktLibrary, seen: inout Set<String>) throws -> JournalResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = root["journal"] as? [[String: Any]] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "WeTrakr sent an unreadable journal."))
        }
        var result = JournalResult(mark: text(root["visible_until"]))
        result.entries = entries.count
        let shows = Dictionary(library.plays.compactMap { play in play.season == nil ? nil : play.title.weTrakrId.map { ($0, play.title) } },
                               uniquingKeysWith: { first, _ in first })
        func same(_ a: TraktTitleRef, _ b: TraktTitleRef) -> Bool {
            a.kind == b.kind && ((a.weTrakrId != nil && a.weTrakrId == b.weTrakrId) || (a.tmdbId != nil && a.tmdbId == b.tmdbId))
        }
        func update(_ list: inout [TraktListed], _ title: TraktTitleRef, added: Bool, at: String?) {
            list.removeAll { same($0.title, title) }
            if added { list.append(TraktListed(title: title, listedAt: at)) }
        }
        for entry in entries {
            if let at = text(entry["action_at"]) { result.mark = at }
            guard let id = text(entry["entry_id"]), seen.insert(id).inserted else { continue }
            let status = text(entry["status"]) ?? "", added = status == "added" || status == "updated"
            let type = text(entry["type"]), at = text(entry["action_at"])
            switch text(entry["category"]) {
            case "watched":
                guard let playID = text(entry["play_id"]) else { continue }  // a show or season entering its watched list
                if !added { library.plays.removeAll { $0.remoteId == playID }; result.applied += 1; continue }
                guard !library.plays.contains(where: { $0.remoteId == playID }) else { continue }
                let date = entry["watched_at_unknown"] as? Bool == true ? nil : text(entry["watched_at"])
                if type == "movie", let title = ref(kind: .movie, id: entry["id"], ids: entry["ids"], name: entry["title"]) {
                    library.plays.append(TraktPlay(historyId: TrackerDecode.playID("wetrakr|" + playID), title: title, watchedAt: date, remoteId: playID))
                    result.applied += 1
                } else if type == "episode", let showID = int(entry["media_id"]), let show = shows[showID],
                          let season = int(entry["season_number"]) ?? (entry["season_number"] as? Int), let number = int(entry["number"]) {
                    library.plays.append(TraktPlay(historyId: TrackerDecode.playID("wetrakr|" + playID), title: show, season: season, episode: number, watchedAt: date, remoteId: playID))
                    result.applied += 1
                } else { result.needsFullRead = true }
            case "planning", "dropped", "favorites":
                guard let kind = kind(type), let title = ref(kind: kind, id: entry["id"], ids: entry["ids"], name: entry["title"]) else { continue }
                switch text(entry["category"]) {
                case "planning": update(&library.watchlist, title, added: added, at: at)
                case "dropped": update(&library.dropped, title, added: added, at: at)
                default: update(&library.favorites, title, added: added, at: at)
                }
                result.applied += 1
            case "ratings":
                guard let kind = kind(type), let title = ref(kind: kind, id: entry["id"], ids: entry["ids"], name: entry["title"]) else { continue }
                library.ratings.removeAll { same($0.title, title) }
                if added, let value = (entry["rating"] as? NSNumber)?.doubleValue, (0...10).contains(value) {
                    library.ratings.append(TraktRating(title: title, rating: Int(value.rounded()), ratedAt: at))
                }
                result.applied += 1
            default:
                continue  // watching, waiting, paused and ignored follow from the plays; notes, lists and the rest aren't read
            }
        }
        let pagination = object(root["pagination"])
        result.hasMore = (pagination?["has_more"] as? Bool) ?? false
        return result
    }

    /// The lists to read again from what moved in last activities (nil: all of them).
    public static func listsToRead(previous: TraktActivities?, now: TraktActivities) -> Set<TraktDomain>? {
        guard let previous else { return nil }
        if now.all == previous.all { return [] }
        func moved(_ keys: [String]) -> Bool { keys.contains { now.stamps[$0] != previous.stamps[$0] } }
        var result = Set<TraktDomain>()
        let removed = moved(["movies.last_tracking_removed_at", "shows.last_tracking_removed_at", "episodes.last_tracking_removed_at"])
        if removed || moved(["movies.last_tracking_watched_at", "episodes.last_tracking_watched_at"]) { result.insert(.history) }
        if removed || moved(["movies.last_tracking_planning_at", "shows.last_tracking_planning_at"]) { result.insert(.watchlist) }
        if removed || moved(["movies.last_tracking_dropped_at", "shows.last_tracking_dropped_at"]) { result.insert(.dropped) }
        if moved(["ratings.all", "movies.last_rated_at", "shows.last_rated_at"]) { result.insert(.ratings) }
        if moved(["favorites.all", "movies.last_favorited_at", "shows.last_favorited_at"]) { result.insert(.favorites) }
        return result
    }
}
