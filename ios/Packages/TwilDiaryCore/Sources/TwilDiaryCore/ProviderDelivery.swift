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

/// Plans only operations with an explicit transport contract. Unsupported edits stay pending.
public enum ProviderDeliveryPlanner {
    public static func plan(_ entry: SyncOutboxEntry, provider: SyncProviderKind, in workspace: Workspace) -> ProviderDeliveryPlan {
        guard provider != .cloudflare, !entry.pendingProviders.contains(.cloudflare) else { return ProviderDeliveryPlan(deliveries: [], blocked: ["Waiting for diary confirmation."]) }
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
        func sendWatch(_ watch: [String: Any]) {
            if provider == .wetrakr { add("history", "/sync/tracking", WeTrakrWrite.watched(watch, rewatch: true), history: true) }
            else { add("history", provider == .mdblist ? "/sync/watched" : "/sync/history", watch, history: true) }
        }
        switch entry.mutation {
        case .markWatch(_, _, let episodeID, let watchedAt, _, _):
            guard let watch = watchItem(episodeID, watchedAt) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["A mapped episode is required before this watch can sync."])
            }
            sendWatch(watch)
        case .restoreWatch(let eventID, _, _):
            // Undoing a removal sends that play again, at its own time.
            guard let event = workspace.events.first(where: { $0.id == eventID }), let date = event.watchedAt,
                  let watch = watchItem(event.episodeId, date) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["This watch has no date or episode to send again."])
            }
            sendWatch(watch)
        case .revokeWatch(let eventID, _, _, _):
            // Only that play: Trakt by its history id (a removal without one would take every
            // play of the title), WeTrakr by its time, Simkl and MDBList their one watch.
            guard let event = workspace.events.first(where: { $0.id == eventID }) else {
                return ProviderDeliveryPlan(deliveries: [], blocked: ["This watch is no longer in the diary."])
            }
            switch provider {
            case .trakt:
                guard eventID.hasPrefix("trakt-"), let history = Int64(eventID.dropFirst(6)) else {
                    blocked.append("Remove this play on Trakt itself: it has no Trakt history id here."); break
                }
                deliveries.append(ProviderDelivery(key: "history-remove", path: "/sync/history/remove", body: ["ids": [history]], history: false))
            case .wetrakr:
                guard let date = event.watchedAt, var watch = watchItem(event.episodeId, date).map({ WeTrakrWrite.watched($0, rewatch: false) }) else {
                    blocked.append("WeTrakr removes one play by its time, and this watch has none."); break
                }
                watch.removeValue(forKey: "allow_rewatch")
                add("history-remove", "/sync/tracking/remove", watch)
            case .simkl, .mdblist:
                guard let watch = watchItem(event.episodeId, event.watchedAt ?? entry.createdAt) else {
                    blocked.append("A mapped episode is required before this removal can sync."); break
                }
                add("history-remove", provider == .mdblist ? "/sync/watched/remove" : "/sync/history/remove", watch)
            case .cloudflare: break
            }
        case .patchTitle(_, _, let status, let score, let clearScore, let favorite, let queued, _, _):
            if clearScore || score != nil {
                if clearScore { add("rating", "/sync/ratings/remove") }
                else if let score, score.isFinite, (1...10).contains(score) {
                    var rated = item; rated["rating"] = score.rounded(); rated["rated_at"] = entry.createdAt
                    add("rating", "/sync/ratings", rated)
                } else { blocked.append("Ratings must be between 1 and 10.") }
            }
            if queued != nil || status == "planned" {
                let planned = queued ?? true
                if provider == .simkl && !planned { blocked.append("Removing a Simkl plan requires review so existing watch history is preserved.") }
                else if provider == .simkl { var value = item; value["to"] = "plantowatch"; add("watchlist", "/sync/add-to-list", value) }
                else if provider == .mdblist { add("watchlist", planned ? "/watchlist/items/add" : "/watchlist/items/remove") }
                else if provider == .wetrakr { var value = item; value["status"] = "planning"; add("watchlist", planned ? "/sync/tracking" : "/sync/tracking/remove", value) }
                else { add("watchlist", planned ? "/sync/watchlist" : "/sync/watchlist/remove") }
            }
            // A status the service doesn't keep (watching and completed come from the watches
            // themselves on Trakt and MDBList) and favourites outside Trakt stay in the diary.
            if let status, status != "planned", statusCarried(status, provider: provider, isSeries: title.isSeries) {
                if provider == .simkl, let list = TraktWritePlan.simklList(status: status, isSeries: title.isSeries) {
                    // Simkl moves the title to its list (this also takes it off Plan to Watch).
                    var value = item; value["to"] = list; add("status", "/sync/add-to-list", value)
                } else if provider == .mdblist { add("status", "/sync/dropped") }
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
        guard case .patchTitle(_, _, let status, let score, let clearScore, let favorite, let queued, _, _) = mutation else { return true }
        if provider == .cloudflare || score != nil || clearScore || queued != nil { return true }
        if let status, statusCarried(status, provider: provider, isSeries: isSeries) { return true }
        return favorite != nil && (provider == .trakt || provider == .wetrakr)
    }
    static func statusCarried(_ status: String, provider: SyncProviderKind, isSeries: Bool) -> Bool {
        if status == "planned" { return true }
        switch provider {
        case .simkl: return TraktWritePlan.simklList(status: status, isSeries: isSeries) != nil
        case .trakt, .mdblist: return status == "dropped" && isSeries
        case .wetrakr: return status == "dropped"
        case .cloudflare: return true
        }
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
            guard let counts = value as? [String: Any] else { return false }
            return ["total", "movies", "shows", "episodes", "seasons", "items", "ratings"].contains { positiveCount(counts[$0]) }
        }
        return ["added", "updated", "existing", "deleted", "removed", "matched"].contains { confirmedCount(object[$0]) }
    }
}
