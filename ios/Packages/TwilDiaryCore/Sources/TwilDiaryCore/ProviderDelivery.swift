import Foundation
import CoreFoundation

public struct ProviderDelivery {
    public let key: String
    public let path: String
    public let body: [String: Any]
    public let history: Bool
}

public struct ProviderDeliveryPlan {
    public let deliveries: [ProviderDelivery]
    public let blocked: [String]
}

/// A watch taken off a diary that lives on a service. That diary is rebuilt from the service, so by
/// the time the other services are told, the watch (and sometimes its episode, or the whole title)
/// is no longer in it to look up. Everything they need travels in the removal's event id instead.
public struct DetachedWatch: Codable, Equatable, Sendable {
    public let tmdbId: Int
    public let movie: Bool
    public let season: Int?
    public let number: Int?
    public let watchedAt: String?
    /// The diary still has another play of this movie or episode: MDBList, which keeps one
    /// watch for all of them, are then left as they are.
    public let othersRemain: Bool
    public init(tmdbId: Int, movie: Bool, season: Int?, number: Int?, watchedAt: String?, othersRemain: Bool) {
        self.tmdbId = tmdbId; self.movie = movie; self.season = season; self.number = number
        self.watchedAt = watchedAt; self.othersRemain = othersRemain
    }
    static let prefix = "detached:"
    /// The event id a `.revokeWatch` carries for this watch.
    public var eventID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.prefix + ((try? encoder.encode(self))?.base64EncodedString() ?? "")
    }
    public init?(eventID: String) {
        guard eventID.hasPrefix(Self.prefix), let data = Data(base64Encoded: String(eventID.dropFirst(Self.prefix.count))),
              let value = try? JSONDecoder().decode(DetachedWatch.self, from: data) else { return nil }
        self = value
    }
}

/// Plans only operations with an explicit transport contract. Unsupported edits stay pending.
public enum ProviderDeliveryPlanner {
    /// Taking one play off a mirror, from what the removal itself carries (see `DetachedWatch`):
    /// Trakt and WeTrakr that very play, by its time; MDBList its one watch, unless the
    /// diary still has another play of it.
    static func detachedRemoval(_ watch: DetachedWatch, provider: SyncProviderKind) -> ProviderDeliveryPlan {
        let slot = watch.movie ? "movies" : "shows"
        func item(timed: Bool) -> [String: Any]? {
            var value: [String: Any] = ["ids": ["tmdb": watch.tmdbId]]
            var time: String?
            if timed {
                guard let at = watch.watchedAt else { return nil }
                time = at
            }
            if watch.movie {
                if let time { value["watched_at"] = time }
            } else {
                guard let season = watch.season, season >= 0, let number = watch.number, number > 0 else { return nil }
                var episode: [String: Any] = ["number": number]
                if let time { episode["watched_at"] = time }
                let seasons: [[String: Any]] = [["number": season, "episodes": [episode]]]
                value["seasons"] = seasons
            }
            return value
        }
        func one(_ key: String, _ path: String, _ body: [String: Any]) -> ProviderDeliveryPlan {
            ProviderDeliveryPlan(deliveries: [ProviderDelivery(key: key, path: path, body: [slot: [body]], history: false)], blocked: [])
        }
        switch provider {
        case .trakt:
            guard let body = item(timed: true) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["Remove this play on Trakt itself: it has no time or episode here."])
            }
            return one("history-remove-timed", "/sync/history/remove", body)
        case .wetrakr:
            guard let timed = item(timed: true) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["WeTrakr removes one play by its time, and this watch has none."])
            }
            var body = WeTrakrWrite.watched(timed, rewatch: false)
            body.removeValue(forKey: "allow_rewatch")
            return one("history-remove", "/sync/tracking/remove", body)
        case .mdblist:
            if watch.othersRemain { return ProviderDeliveryPlan(deliveries: [], blocked: []) }
            guard let body = item(timed: false) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["A mapped episode is required before this removal can sync."])
            }
            return one("history-remove", "/sync/watched/remove", body)
        // Simkl's edits are placed and sent by the app's Simkl sync, never planned here.
        case .cloudflare, .simkl:
            return ProviderDeliveryPlan(deliveries: [], blocked: [])
        }
    }

    public static func plan(_ entry: SyncOutboxEntry, provider: SyncProviderKind, in workspace: Workspace) -> ProviderDeliveryPlan {
        guard provider != .cloudflare, provider != .simkl, !entry.pendingProviders.contains(.cloudflare) else { return ProviderDeliveryPlan(deliveries: [], blocked: ["Waiting for diary confirmation."]) }
        if case .revokeWatch(let eventID, _, _, _) = entry.mutation, let detached = DetachedWatch(eventID: eventID) {
            return detachedRemoval(detached, provider: provider)
        }
        guard let title = workspace.titles.first(where: { $0.id == entry.mutation.titleId }), let tmdb = title.tmdbId, tmdb > 0 else {
            return ProviderDeliveryPlan(deliveries: [], blocked: ["A TMDB mapping is required before this edit can sync."])
        }
        let slot = title.isSeries ? "shows" : "movies"
        let item: [String: Any] = ["ids": ["tmdb": tmdb]]
        var deliveries: [ProviderDelivery] = [], blocked: [String] = []
        func add(_ key: String, _ path: String, _ value: [String: Any]? = nil, history: Bool = false) {
            // MDBList takes Trakt's shape ("ids"), per its published API (api.mdblist.com/docs).
            let body: [String: Any] = value ?? item
            deliveries.append(ProviderDelivery(key: key, path: path, body: [slot: [body]], history: history))
        }
        /// The play in each service's shape: the movie, or show > season > episode, with its time.
        func watchItem(_ episodeID: String?, _ watchedAt: String) -> [String: Any]? {
            var watch = item
            if title.isSeries {
                guard let episode = workspace.episodes.first(where: { $0.id == episodeID && $0.titleId == title.id }), episode.season >= 0, episode.number > 0 else { return nil }
                let episodeItem: [String: Any] = ["number": episode.number, "watched_at": watchedAt]
                watch["seasons"] = [["number": episode.season, "episodes": [episodeItem]]]
            } else { watch["watched_at"] = watchedAt }
            return watch
        }
        func sendWatch(_ watch: [String: Any], rewatch: Bool) {
            // WeTrakr logs another play only when asked (allow_rewatch): just for a real rewatch,
            // so a resend can never double a first watch.
            if provider == .wetrakr { add("history", "/sync/tracking", WeTrakrWrite.watched(watch, rewatch: rewatch), history: true) }
            else { add("history", provider == .mdblist ? "/sync/watched" : "/sync/history", watch, history: true) }
        }
        switch entry.mutation {
        case .markWatch(_, _, let episodeID, let watchedAt, _, let rewatch):
            guard let watch = watchItem(episodeID, watchedAt) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["A mapped episode is required before this watch can sync."])
            }
            sendWatch(watch, rewatch: rewatch)
        case .restoreWatch(let eventID, _, _):
            // Undoing a removal sends that play again, at its own time.
            guard let event = workspace.events.first(where: { $0.id == eventID }), let date = event.watchedAt,
                  let watch = watchItem(event.episodeId, date) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["This watch has no date or episode to send again."])
            }
            sendWatch(watch, rewatch: false)
        case .revokeWatch(let eventID, _, _, _):
            // Only that play: Trakt by its history id (a removal without one would take every
            // play of the title), WeTrakr by its time, MDBList its one watch.
            guard let event = workspace.events.first(where: { $0.id == eventID }) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["This watch is no longer in the diary."])
            }
            switch provider {
            case .trakt:
                // A Trakt history id only when the play came from Trakt: a diary read from another
                // service (MDBList, WeTrakr, once Simkl) names its plays by that service's ids. Otherwise the play is
                // found in Trakt's history at its time and removed by its id (as Cinopsys does).
                let fromTrakt = !["simkl", "mdblist", "wetrakr"].contains(event.origin)
                if fromTrakt, eventID.hasPrefix("trakt-"), let history = Int64(eventID.dropFirst(6)) {
                    deliveries.append(ProviderDelivery(key: "history-remove", path: "/sync/history/remove", body: ["ids": [history]], history: false))
                } else if let date = event.watchedAt, let watch = watchItem(event.episodeId, date) {
                    deliveries.append(ProviderDelivery(key: "history-remove-timed", path: "/sync/history/remove", body: [slot: [watch]], history: false))
                } else {
                    blocked.append("Remove this play on Trakt itself: it has no Trakt history id or time here.")
                }
            case .wetrakr:
                guard let date = event.watchedAt, var watch = watchItem(event.episodeId, date).map({ WeTrakrWrite.watched($0, rewatch: false) }) else {
                    blocked.append("WeTrakr removes one play by its time, and this watch has none."); break
                }
                watch.removeValue(forKey: "allow_rewatch")
                add("history-remove", "/sync/tracking/remove", watch)
            case .mdblist:
                // Its one watch stands for every play of it: while the diary still has another
                // play of this movie or episode, taking one off leaves the service as it is.
                if workspace.events.contains(where: { $0.id != eventID && $0.titleId == title.id && $0.episodeId == event.episodeId && $0.revokedAt == nil }) { break }
                guard let watch = watchItem(event.episodeId, event.watchedAt ?? entry.createdAt) else {
                    blocked.append("A mapped episode is required before this removal can sync."); break
                }
                add("history-remove", "/sync/watched/remove", watch)
            case .cloudflare, .simkl: break
            }
        case .patchTitle(_, _, let status, let score, let clearScore, let favorite, _, _, _):
            if clearScore || score != nil {
                if clearScore { add("rating", "/sync/ratings/remove") }
                else if let score, score.isFinite, (1...10).contains(score) {
                    var rated = item; rated["rating"] = score.rounded(); rated["rated_at"] = entry.createdAt
                    add("rating", "/sync/ratings", rated)
                } else { blocked.append("Ratings must be between 1 and 10.") }
            }
            // Planned is each service's watchlist. Queue is TwilDiary's own list (no service keeps
            // one), so it never touches a watchlist.
            if status == "planned" {
                switch provider {
                case .mdblist: add("watchlist", "/watchlist/items/add")
                case .wetrakr: var value = item; value["status"] = "planning"; add("watchlist", "/sync/tracking", value)
                default: add("watchlist", "/sync/watchlist")
                }
            }
            // Leaving Planned takes the title off the watchlist too, or it stays listed there for
            // good (a match only ever adds). Asked whatever it was before: taking off something
            // that isn't listed changes nothing. WeTrakr is left to the match, since its removal call isn't confirmed to touch only Planning.
            if let status, status != "planned" {
                if provider == .trakt { add("watchlist-remove", "/sync/watchlist/remove") }
                else if provider == .mdblist { add("watchlist-remove", "/watchlist/items/remove") }
            }
            // A status the service doesn't keep (watching and completed come from the watches
            // themselves on Trakt and MDBList) and favourites outside Trakt stay in the diary.
            if let status, status != "planned", statusCarried(status, provider: provider, isSeries: title.isSeries) {
                if provider == .mdblist { add("status", "/sync/dropped") }
                else if provider == .wetrakr { var value = item; value["status"] = "dropped"; add("status", "/sync/tracking", value) }
                else if provider == .trakt { add("status", "/users/hidden/dropped") }
            }
            if let favorite, provider == .trakt || provider == .wetrakr { add("favorite", favorite ? "/sync/favorites" : "/sync/favorites/remove") }
        default:
            blocked.append("This edit requires provider-specific reconciliation before delivery.")
        }
        return ProviderDeliveryPlan(deliveries: deliveries, blocked: blocked)
    }

    /// Whether a service keeps anything this edit changes. Edits it doesn't keep aren't queued for it
    /// (a favourite only Trakt keeps; watching and completed come from the watches on Trakt and MDBList).
    public static func carries(_ mutation: OptimisticMutation, provider: SyncProviderKind, isSeries: Bool) -> Bool {
        guard case .patchTitle(_, _, let status, let score, let clearScore, let favorite, _, _, _) = mutation else { return true }
        if provider == .cloudflare || score != nil || clearScore { return true }
        if let status, statusCarried(status, provider: provider, isSeries: isSeries) { return true }
        // Any other status still takes the title off Trakt's and MDBList's watchlist.
        if status != nil, provider == .trakt || provider == .mdblist { return true }
        return favorite != nil && (provider == .trakt || provider == .wetrakr)
    }
    static func statusCarried(_ status: String, provider: SyncProviderKind, isSeries: Bool) -> Bool {
        if status == "planned" { return true }
        switch provider {
        case .trakt, .mdblist: return status == "dropped" && isSeries
        case .wetrakr, .simkl: return status == "dropped"
        case .cloudflare: return true
        }
    }

    /// The service answered but couldn't find the title (by its TMDB id): sending again won't help.
    public static func notFound(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        func nonempty(_ value: Any?) -> Bool {
            if let array = value as? [Any] { return !array.isEmpty }
            if let object = value as? [String: Any] { return object.values.contains { nonempty($0) } }
            if let number = value as? NSNumber { return number.doubleValue > 0 }
            return false
        }
        return nonempty(object["not_found"]) || nonempty(object["notFound"])
    }
    public static func confirms(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        func nonempty(_ value: Any?) -> Bool {
            if let array = value as? [Any] { return !array.isEmpty }
            if let object = value as? [String: Any] { return object.values.contains { nonempty($0) } }
            if let number = value as? NSNumber { return number.doubleValue > 0 }
            if let text = value as? String { return !text.isEmpty }
            return false
        }
        // WeTrakr spells them notFound and errored.
        if nonempty(object["not_found"]) || nonempty(object["notFound"]) || nonempty(object["errors"]) || nonempty(object["errored"])
            || nonempty(object["failed"]) || nonempty(object["error"]) { return false }
        func positiveCount(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let count = number.doubleValue
            return count.isFinite && count > 0 && count <= 9_007_199_254_740_991 && count.rounded(.towardZero) == count
        }
        func confirmedCount(_ value: Any?) -> Bool {
            if positiveCount(value) { return true }
            // A service may list what it added ({"added": {"movies": [{…}]}}) instead of counting it.
            if let items = value as? [Any] { return !items.isEmpty }
            guard let counts = value as? [String: Any] else { return false }
            return ["total", "movies", "shows", "episodes", "seasons", "items", "ratings", "anime"].contains { key in
                positiveCount(counts[key]) || ((counts[key] as? [Any]).map { !$0.isEmpty } ?? false)
            }
        }
        return ["added", "updated", "existing", "deleted", "removed", "matched"].contains { confirmedCount(object[$0]) }
    }
}
