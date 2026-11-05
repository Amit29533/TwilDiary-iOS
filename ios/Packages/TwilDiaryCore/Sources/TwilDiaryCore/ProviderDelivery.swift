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
        switch entry.mutation {
        case .markWatch(_, _, let episodeID, let watchedAt, _, _):
            do {
                var watch = item
                if title.isSeries {
                    guard let episode = workspace.episodes.first(where: { $0.id == episodeID && $0.titleId == title.id }), episode.season >= 0, episode.number > 0 else {
                        return ProviderDeliveryPlan(deliveries: [], blocked: ["A mapped episode is required before this watch can sync."])
                    }
                    let episodeItem: [String: Any] = ["number": episode.number, "watched_at": watchedAt]
                    watch["seasons"] = [["number": episode.season, "episodes": [episodeItem]]]
                } else { watch["watched_at"] = watchedAt }
                add("history", provider == .mdblist ? "/sync/watched" : "/sync/history", watch, history: true)
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
                else { add("watchlist", planned ? "/sync/watchlist" : "/sync/watchlist/remove") }
            }
            // A status the service doesn't keep (watching and completed come from the watches
            // themselves on Trakt and MDBList) and favourites outside Trakt stay in the diary.
            if let status, status != "planned", statusCarried(status, provider: provider, isSeries: title.isSeries) {
                if provider == .simkl, let list = TraktWritePlan.simklList(status: status, isSeries: title.isSeries) {
                    // Simkl moves the title to its list (this also takes it off Plan to Watch).
                    var value = item; value["to"] = list; add("status", "/sync/add-to-list", value)
                } else if provider == .mdblist { add("status", "/sync/dropped") }
                else if provider == .trakt { add("status", "/users/hidden/dropped") }
            }
            if let favorite, provider == .trakt { add("favorite", favorite ? "/sync/favorites" : "/sync/favorites/remove") }
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
        return favorite != nil && provider == .trakt
    }
    static func statusCarried(_ status: String, provider: SyncProviderKind, isSeries: Bool) -> Bool {
        if status == "planned" { return true }
        switch provider {
        case .simkl: return TraktWritePlan.simklList(status: status, isSeries: isSeries) != nil
        case .trakt, .mdblist: return status == "dropped" && isSeries
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
        if nonempty(object["not_found"]) || nonempty(object["errors"]) || nonempty(object["failed"]) || nonempty(object["error"]) { return false }
        func positiveCount(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let count = number.doubleValue
            return count.isFinite && count > 0 && count <= 9_007_199_254_740_991 && count.rounded(.towardZero) == count
        }
        func confirmedCount(_ value: Any?) -> Bool {
            if positiveCount(value) { return true }
            guard let counts = value as? [String: Any] else { return false }
            return ["movies", "shows", "episodes", "seasons", "items", "ratings"].contains { positiveCount(counts[$0]) }
        }
        return ["added", "updated", "existing", "deleted", "removed", "matched"].contains { confirmedCount(object[$0]) }
    }
}
