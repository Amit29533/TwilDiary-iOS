import Foundation
import TwilDiaryCore

/// Trakt-first phase 4b, and phase 5 for MDBList and WeTrakr: with "Show my diary from
/// <service>" on, edits go to that service, the way Cinopsys makes them. Watches (at their exact
/// time), removing a watch, ratings, Planned and dropped change the phone's copy first, so the
/// screen updates at once, and go to the service right away in the background (kept on the phone
/// until it takes them). Favourites go to Trakt and WeTrakr (MDBList keeps none, so your
/// server keeps them); notes, tags, Queue and Trash stay on your server.
///
/// The same edits also go to the other connected services (the mirrors) through the delivery
/// queue, as in the server diary, within what each keeps. Never back to the service they came from.
extension DiaryStore {
    /// The service the diary on screen comes from (nil: your server's diary).
    var diaryService: MainTracker? { diaryFromTrakt ? .trakt : diaryFromTracker }
    var diaryFromService: Bool { diaryService != nil }
    private var service: MainTracker { diaryService ?? .trakt }
    private func providerKind(_ tracker: MainTracker) -> SyncProviderKind {
        tracker.provider
    }

    private func serviceRef(_ title: MediaTitle) throws -> [String: Any] {
        guard let tmdb = title.tmdbId else { throw APIError.message("“\(title.name)” has no TMDB id, so \(service.name) can’t find it.") }
        return ["ids": ["tmdb": tmdb]]
    }
    private func titleRef(_ title: MediaTitle) -> TraktTitleRef {
        TraktTitleRef(kind: title.isSeries ? .show : .movie, traktId: nil, tmdbId: title.tmdbId, name: title.name, year: title.year)
    }
    private func stamp(_ date: Date) -> String { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date) }
    /// A title the diary knows only from the service (its details are read on the phone).
    func isServiceOnly(_ title: MediaTitle) -> Bool { title.id.hasPrefix("tv:") || title.id.hasPrefix("movie:") }

    // MARK: Talking to the service

    /// Queues the edit for the service and sends it in the background (never waits for an answer).
    private func send(_ path: String, _ body: [String: Any], resolve: Bool = false) throws {
        switch service {
        case .trakt: try TraktDirectStore.shared.write(path, body: body, store: self, resolve: resolve)
        case .mdblist, .wetrakr: try TrackerPreviewStore.shared.write(service, path, body: body, store: self)
        }
    }
    private func updateCopy(_ change: (inout TraktLibrary) -> Void) {
        switch service {
        case .trakt: TraktDirectStore.shared.update(store: self, change)
        case .mdblist, .wetrakr: TrackerPreviewStore.shared.update(service, store: self, change)
        }
    }
    private func refreshCopySoon() {
        switch service {
        case .trakt: TraktDirectStore.shared.refreshSoon(store: self)
        case .mdblist, .wetrakr: TrackerPreviewStore.shared.refreshSoon(service, store: self)
        }
    }

    /// Trash takes Planned titles off the service's watchlist and Restore puts them back: the
    /// service holds the diary, so a trashed title would otherwise stay planned there. Watch
    /// history and ratings on the service are left alone.
    func serviceWatchlist(_ titles: [MediaTitle], listed: Bool) async throws {
        let planned = titles.filter { $0.status == "planned" && $0.tmdbId != nil }
        guard !planned.isEmpty else { return }
        let path: String
        switch service {
        case .trakt: path = listed ? "/sync/watchlist" : "/sync/watchlist/remove"
        case .mdblist: path = listed ? "/watchlist/items/add" : "/watchlist/items/remove"
        case .wetrakr: path = listed ? "/sync/tracking" : "/sync/tracking/remove"
        }
        func entry(_ title: MediaTitle) throws -> [String: Any] {
            var value = try serviceRef(title)
            if service == .wetrakr { value["status"] = "planning" }
            return value
        }
        var body: [String: Any] = [:]
        let movies = planned.filter { !$0.isSeries }, shows = planned.filter(\.isSeries)
        if !movies.isEmpty { body["movies"] = try movies.map { try entry($0) } }
        if !shows.isEmpty { body["shows"] = try shows.map { try entry($0) } }
        try send(path, body)
        let refs = planned.map { titleRef($0) }, keys = Set(refs.map(\.diaryKey))
        updateCopy { library in
            library.watchlist.removeAll { keys.contains($0.title.diaryKey) }
            if listed { library.watchlist += refs.map { TraktListed(title: $0, listedAt: nil) } }
        }
    }

    /// Queues an edit for the connected mirrors, never the service the diary comes from.
    func mirror(_ mutation: OptimisticMutation, to providers: Set<SyncProviderKind> = [.trakt, .mdblist, .wetrakr]) {
        var skip: Set<SyncProviderKind> = [.cloudflare]
        if let diaryService { skip.insert(providerKind(diaryService)) }
        // The service holding the diary gets your edits directly (one writer, one pace), also
        // while the old server copy is on screen; never a second copy through the mirrors.
        let targets = providers.subtracting(skip).intersection(providerSettings.activeDirectLoggingProviders)
        guard !targets.isEmpty, !isPreview else { return }
        recordDirectProviderMutation(mutation, providers: targets)
    }

    // MARK: Watches

    /// Adds plays (movie, or episodes of one show) at the given time, which it returns (it names
    /// these very plays for Undo).
    @discardableResult func serviceAddPlays(_ title: MediaTitle, episodes: [(season: Int, number: Int)], at date: Date) async throws -> String {
        var item = try serviceRef(title)
        let when = stamp(date)
        let path = service == .mdblist ? "/sync/watched" : service == .wetrakr ? "/sync/tracking" : "/sync/history"
        // What the diary already had watched: those are rewatches (Cinopsys's is_rewatch).
        let watchedBefore = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap { event -> String? in
            guard let id = event.episodeId else { return "movie" }
            return workspace.episodes.first { $0.id == id }.map { "\($0.season)|\($0.number)" }
        })
        // WeTrakr: status "watched" with tracked_at; only a rewatch may log another play.
        func shaped(_ watch: [String: Any], rewatch: Bool) -> [String: Any] { service == .wetrakr ? WeTrakrWrite.watched(watch, rewatch: rewatch) : watch }
        if title.isSeries {
            guard !episodes.isEmpty else { throw APIError.message("No episode is ready to mark.") }
            func showItem(_ part: [(season: Int, number: Int)]) -> [String: Any] {
                var value = item
                value["seasons"] = Set(part.map { $0.season }).sorted().map { season in
                    ["number": season, "episodes": part.filter { $0.season == season }.map { ["number": $0.number, "watched_at": when] }] as [String: Any]
                }
                return value
            }
            let again = episodes.filter { watchedBefore.contains("\($0.season)|\($0.number)") }
            let first = episodes.filter { !watchedBefore.contains("\($0.season)|\($0.number)") }
            if service == .wetrakr, !again.isEmpty, !first.isEmpty {
                try send(path, ["shows": [shaped(showItem(first), rewatch: false), shaped(showItem(again), rewatch: true)]])
            } else {
                try send(path, ["shows": [shaped(showItem(episodes), rewatch: first.isEmpty)]])
            }
        } else {
            item["watched_at"] = when
            try send(path, ["movies": [shaped(item, rewatch: watchedBefore.contains("movie"))]])
        }
        let ref = titleRef(title)
        let oneEach = !service.capabilities.keepsRewatches
        let key = ref.diaryKey
        updateCopy { library in
            if title.isSeries {
                for episode in episodes {
                    // MDBList keeps one watch per episode: the new time replaces the old.
                    if oneEach { library.plays.removeAll { $0.title.diaryKey == key && $0.season == episode.season && $0.episode == episode.number } }
                    library.plays.append(TraktPlay(historyId: -TrackerDecode.playID("local|\(ref.tmdbId ?? 0)|\(episode.season)|\(episode.number)|\(when)"),
                                                   title: ref, season: episode.season, episode: episode.number, watchedAt: when))
                }
            } else {
                if oneEach { library.plays.removeAll { $0.title.diaryKey == key && $0.season == nil } }
                library.plays.append(TraktPlay(historyId: -TrackerDecode.playID("local|\(ref.tmdbId ?? 0)|\(when)"), title: ref, watchedAt: when))
            }
        }
        // The mirrors get each watch at the same time (the diary now has the episodes).
        if title.isSeries {
            for episode in episodes {
                let id = workspace.episodes.first { $0.titleId == title.id && $0.season == episode.season && $0.number == episode.number }?.id
                    ?? "\(title.id)|s\(episode.season)e\(episode.number)"
                mirror(.markWatch(operationId: UUID().uuidString, titleId: title.id, episodeId: id, watchedAt: when, recordedAt: when,
                                  rewatch: watchedBefore.contains("\(episode.season)|\(episode.number)")))
            }
        } else {
            mirror(.markWatch(operationId: UUID().uuidString, titleId: title.id, episodeId: nil, watchedAt: when, recordedAt: when, rewatch: watchedBefore.contains("movie")))
        }
        refreshCopySoon()
        return when
    }

    /// Removes exactly these watches. Trakt removes those very plays (by id, never all plays of an
    /// episode); MDBList keeps one watch per episode or movie, so that watch is removed.
    /// The screen changes at once and the removal goes in the background. Trakt: plays it has ids
    /// for go by id (all in one request); a play just added (no id here yet) is found in Trakt's
    /// history at its time when its turn comes, right after the add itself (Cinopsys's way, with
    /// no read first). WeTrakr removes the play at its time; MDBList keeps one watch per
    /// episode or movie, so that watch is removed.
    func serviceRemoveWatches(_ events: [WatchEvent]) async throws {
        guard !events.isEmpty else { throw APIError.message("There’s no watch to remove.") }
        let ids = events.compactMap(servicePlayID)
        if service == .trakt, TraktDirectStore.shared.localOnly {
            // On this phone: nothing to send; the copy below is the diary.
        } else if service == .trakt {
            let known = ids.filter { $0 > 0 }
            let fresh = events.filter { (servicePlayID($0) ?? 0) <= 0 }
            if !known.isEmpty { try send("/sync/history/remove", ["ids": known]) }
            if !fresh.isEmpty { try send("/sync/history/remove", try playsBody(fresh, timed: true), resolve: true) }
        } else {
            let path = service == .mdblist ? "/sync/watched/remove" : service == .wetrakr ? "/sync/tracking/remove" : "/sync/history/remove"
            try send(path, try playsBody(events, timed: service == .wetrakr))
        }
        mirrorRemovals(events)
        updateCopy { library in library.plays.removeAll { ids.contains($0.historyId) } }
        refreshCopySoon()
    }
    /// The mirrors lose the same plays. Called before the phone's copy changes: the diary is rebuilt
    /// from that copy, so afterwards the watch (and perhaps its episode or title) isn't there to
    /// look up; each removal carries what the mirrors need itself (`DetachedWatch`).
    private func mirrorRemovals(_ events: [WatchEvent]) {
        let going = Set(events.map(\.id)), when = stamp(now)
        for event in events {
            guard let title = self.title(event.titleId), let tmdb = title.tmdbId else { continue }
            let episode = event.episodeId.flatMap { id in workspace.episodes.first { $0.id == id } }
            if title.isSeries && episode == nil { continue }
            let others = workspace.activeEvents.contains { $0.titleId == event.titleId && $0.episodeId == event.episodeId && !going.contains($0.id) }
            let watch = DetachedWatch(tmdbId: tmdb, movie: !title.isSeries, season: episode?.season, number: episode?.number,
                                      watchedAt: event.watchedAt, othersRemain: others)
            mirror(.revokeWatch(eventId: watch.eventID, titleId: title.id, expectedVersion: 1, revokedAt: when))
        }
    }
    /// Watches as the service's body (movies; shows > seasons > episodes), with each play's time
    /// when `timed`. WeTrakr's shape: status "watched" and tracked_at.
    private func playsBody(_ events: [WatchEvent], timed: Bool) throws -> [String: Any] {
        var movies: [[String: Any]] = [], shows: [Int: [Int: [[String: Any]]]] = [:]
        for event in events {
            guard let title = self.title(event.titleId), let tmdb = title.tmdbId else { throw APIError.message("This watch has no TMDB id, so \(service.name) can’t find it.") }
            if timed && event.watchedAt == nil { throw APIError.message("This watch has no time, so \(service.name) can’t tell which play to remove.") }
            if title.isSeries {
                guard let episode = workspace.episodes.first(where: { $0.id == event.episodeId }) else { throw APIError.message("This watch has no episode to remove.") }
                var entry: [String: Any] = ["number": episode.number]
                if timed, let when = event.watchedAt { entry["watched_at"] = when }
                shows[tmdb, default: [:]][episode.season, default: []].append(entry)
            } else {
                var entry: [String: Any] = ["ids": ["tmdb": tmdb]]
                if timed, let when = event.watchedAt { entry["watched_at"] = when }
                movies.append(entry)
            }
        }
        var showBodies: [[String: Any]] = shows.keys.sorted().map { tmdb in
            let seasons = shows[tmdb] ?? [:]
            return ["ids": ["tmdb": tmdb], "seasons": seasons.keys.sorted().map { season in
                ["number": season, "episodes": seasons[season] ?? []] as [String: Any]
            }]
        }
        if service == .wetrakr {
            func tracked(_ watch: [String: Any]) -> [String: Any] {
                var value = WeTrakrWrite.watched(watch, rewatch: false)
                value.removeValue(forKey: "allow_rewatch")
                return value
            }
            movies = movies.map(tracked); showBodies = showBodies.map(tracked)
        }
        return ["movies": movies, "shows": showBodies]
    }
    /// Every play of a title. Trakt: the whole title in one removal (as Cinopsys removes history),
    /// plays just added included, with nothing read first.
    func removeAllPlays(_ title: MediaTitle) async throws {
        let plays = workspace.events.filter { $0.titleId == title.id && $0.revokedAt == nil }
        guard !plays.isEmpty else { return }
        guard service == .trakt else { return try await serviceRemoveWatches(plays) }
        if !TraktDirectStore.shared.localOnly {
            try send("/sync/history/remove", [title.isSeries ? "shows" : "movies": [try serviceRef(title)]])
        }
        let ids = Set(plays.compactMap(servicePlayID)), key = titleRef(title).diaryKey
        mirrorRemovals(plays)
        updateCopy { library in library.plays.removeAll { ids.contains($0.historyId) || (key != nil && $0.title.diaryKey == key) } }
        refreshCopySoon()
    }
    /// The service's play behind a watch in the service diary ("trakt-123").
    func servicePlayID(_ event: WatchEvent) -> Int64? {
        guard event.id.hasPrefix("trakt-") else { return nil }
        return Int64(event.id.dropFirst("trakt-".count))
    }
    /// The latest play of a title (or one episode of it).
    func latestServiceEvent(titleID: String, episodeID: String? = nil, any: Bool = false) -> WatchEvent? {
        workspace.activeEvents.filter { $0.titleId == titleID && (any || $0.episodeId == episodeID) }
            .max { ($0.watchedAt ?? $0.recordedAt) < ($1.watchedAt ?? $1.recordedAt) }
    }

    func serviceSeasonProgress(_ title: MediaTitle, season: Int, count: Int, watchedAt: Date) async throws {
        let episodes = workspace.episodes.filter { $0.titleId == title.id && $0.season == season }.sorted { $0.number < $1.number }
        let wanted = Set(episodes.prefix(max(0, count)).map(\.id))
        let watched = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
        let add = episodes.filter { wanted.contains($0.id) && !watched.contains($0.id) }
        if !add.isEmpty { try await serviceAddPlays(title, episodes: add.map { (season: $0.season, number: $0.number) }, at: watchedAt) }
        let remove = episodes.filter { !wanted.contains($0.id) && watched.contains($0.id) }
            .compactMap { latestServiceEvent(titleID: title.id, episodeID: $0.id) }
        if !remove.isEmpty { try await serviceRemoveWatches(remove) }
    }

    /// A title's status on the service. Completing marks what's aired and unwatched (a movie gets
    /// its watch); the rest is the list side (servicePatch).
    func serviceSetStatus(_ title: MediaTitle, status: String, watchedAt: Date) async throws {
        if status == "completed" {
            let today = DiaryDate.day(now)
            let watched = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
            let due = workspace.episodes.filter { episode in
                episode.titleId == title.id && episode.season > 0 && !watched.contains(episode.id)
                    && (episode.airedOn.map { aired in aired <= today } ?? false)
            }
            if !title.isSeries && !workspace.activeEvents.contains(where: { $0.titleId == title.id }) {
                try await serviceAddPlays(title, episodes: [], at: watchedAt)
            } else if !due.isEmpty {
                try await serviceAddPlays(title, episodes: due.map { (season: $0.season, number: $0.number) }, at: watchedAt)
            }
        }
        try await servicePatch(title, values: ["status": status])
    }

    // MARK: Title facts

    /// Rating, Planned and dropped go to the service, and favourites to Trakt; everything else
    /// (notes, tags, Queue, and what the service can't keep) stays on the phone (PhoneExtras).
    func servicePatch(_ title: MediaTitle, values: [String: Any]) async throws {
        let item = try serviceRef(title)
        let slot = title.isSeries ? "shows" : "movies"
        if let score = values["score"] as? Double {
            try send("/sync/ratings", [slot: [item.merging(["rating": Int(score.rounded())]) { $1 }]])
        } else if values["score"] is NSNull {
            try send("/sync/ratings/remove", [slot: [item]])
        }
        let status = values["status"] as? String
        // Whether the service keeps this status (otherwise the server does).
        var serviceHolds = true
        // A watched movie set back to Planned (a watch logged by accident): its plays come off the
        // service too, each by its own id, or the service would keep counting it as watched.
        // Shows keep their history; resetting a season is its own action.
        if status == "planned", !title.isSeries { try await removeAllPlays(title) }
        if let status {
            let wasPlanned = title.status == "planned", wasDropped = (title.isSeries || service == .wetrakr) && title.status == "dropped"
            switch service {
            case .trakt:
                switch status {
                case "planned":
                    try send("/sync/watchlist", [slot: [item]])
                    if wasDropped { try send("/users/hidden/dropped/remove", ["shows": [item]]) }
                case "dropped" where title.isSeries:
                    try send("/users/hidden/dropped", ["shows": [item]])
                default:
                    if wasPlanned { try send("/sync/watchlist/remove", [slot: [item]]) }
                    if wasDropped { try send("/users/hidden/dropped/remove", ["shows": [item]]) }
                    // Trakt has no Completed, Watching or Paused (nor dropped movies): the server's
                    // record of the title keeps your choice, so it survives the next read.
                    serviceHolds = false
                }
            case .mdblist:
                switch status {
                case "planned":
                    try send("/watchlist/items/add", [slot: [item]])
                    if wasDropped { try send("/sync/dropped/remove", ["shows": [item]]) }
                case "dropped" where title.isSeries:
                    if wasPlanned { try send("/watchlist/items/remove", [slot: [item]]) }
                    try send("/sync/dropped", ["shows": [item]])
                default:
                    if wasPlanned { try send("/watchlist/items/remove", [slot: [item]]) }
                    if wasDropped { try send("/sync/dropped/remove", ["shows": [item]]) }
                    serviceHolds = false
                }
            case .wetrakr:
                // WeTrakr's tracking statuses: planning and dropped (movies too); watched comes from the plays.
                func tracking(_ value: String) -> [String: Any] { item.merging(["status": value]) { $1 } }
                switch status {
                case "planned":
                    if wasDropped { try send("/sync/tracking/remove", [slot: [tracking("dropped")]]) }
                    try send("/sync/tracking", [slot: [tracking("planning")]])
                case "dropped":
                    if wasPlanned { try send("/sync/tracking/remove", [slot: [tracking("planning")]]) }
                    try send("/sync/tracking", [slot: [tracking("dropped")]])
                default:
                    if wasPlanned { try send("/sync/tracking/remove", [slot: [tracking("planning")]]) }
                    if wasDropped { try send("/sync/tracking/remove", [slot: [tracking("dropped")]]) }
                    serviceHolds = false
                }
            }
        }
        let favourite = values["favorite"] as? Bool
        let favouritesHere = service.capabilities.holdsFavourites
        if let favourite, favouritesHere {
            try send(favourite ? "/sync/favorites" : "/sync/favorites/remove", [slot: [item]])
        }
        let ref = titleRef(title)
        let dropsHere = title.isSeries || service == .wetrakr
        updateCopy { library in
            let key = ref.diaryKey
            if let score = values["score"] as? Double {
                library.ratings.removeAll { $0.title.diaryKey == key }
                library.ratings.append(TraktRating(title: ref, rating: Int(score.rounded()), ratedAt: nil))
            } else if values["score"] is NSNull { library.ratings.removeAll { $0.title.diaryKey == key } }
            if let status {
                library.watchlist.removeAll { $0.title.diaryKey == key }
                library.dropped.removeAll { $0.title.diaryKey == key }
                if status == "planned" { library.watchlist.append(TraktListed(title: ref, listedAt: nil)) }
                if status == "dropped" && dropsHere { library.dropped.append(TraktListed(title: ref, listedAt: nil)) }
            }
            if let favourite, favouritesHere {
                library.favorites.removeAll { $0.title.diaryKey == key }
                if favourite { library.favorites.append(TraktListed(title: ref, listedAt: nil)) }
            }
        }
        // The mirrors: ratings to all; a status and a favourite where each service keeps them.
        let score = values["score"] as? Double, clearScore = values["score"] is NSNull
        if score != nil || clearScore || status != nil || favourite != nil {
            mirror(.patchTitle(titleId: title.id, expectedVersion: nil, status: status, score: score, clearScore: clearScore, favorite: favourite, queued: nil, notes: nil))
        }
        // The phone keeps the rest: what the service can't hold (a dropped movie; favourites
        // outside Trakt), a note's full text, tags and Queue.
        var rest = values.filter { !["score", "favorite", "status"].contains($0.key) }
        // Notes: to Trakt (500 characters); the phone keeps a longer note's full text.
        if service == .trakt, let text = values["notes"] as? String {
            try await TraktDirectStore.shared.setNote(text, for: titleRef(title), store: self)
            rest["notes"] = text.count > 500 ? text : ""
        }
        if let status, !serviceHolds || (!title.isSeries && title.status == "dropped" && service != .wetrakr) { rest["status"] = status }
        if let favourite, !favouritesHere { rest["favorite"] = favourite }
        // A status the service holds clears the phone's.
        if status != nil, rest["status"] == nil { rest["status"] = NSNull() }
        if !rest.isEmpty {
            PhoneExtras.shared.update(title, rest)
            applyDiarySource()
        }
    }
}
