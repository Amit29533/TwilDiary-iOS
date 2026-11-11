import Foundation
import TwilDiaryCore

/// Trakt-first phase 4b, and phase 5 for Simkl and MDBList: with "Show my diary from <service>" on,
/// edits go to that service. Watches (at their exact time), removing a watch, ratings, Planned and
/// dropped are written to the service and applied to the phone's copy of it at once, so the screen
/// updates without a full re-read. Favourites go to Trakt (Simkl and MDBList keep none, so your
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
    /// A title only on the service has no server record for notes, tags or files yet.
    func isServiceOnly(_ title: MediaTitle) -> Bool { title.id.hasPrefix("tv:") || title.id.hasPrefix("movie:") }

    // MARK: Talking to the service

    private func send(_ path: String, _ body: [String: Any]) async throws {
        switch service {
        case .trakt: try await TraktDirectStore.shared.write(path, body: body, store: self)
        case .simkl, .mdblist: try await TrackerPreviewStore.shared.write(service, path, body: body, store: self)
        case .wetrakr: throw APIError.message("Editing the WeTrakr diary here isn’t available yet. Your edits still reach WeTrakr as a copy.")
        }
    }
    private func updateCopy(_ change: (inout TraktLibrary) -> Void) {
        switch service {
        case .trakt: TraktDirectStore.shared.update(store: self, change)
        case .simkl, .mdblist, .wetrakr: TrackerPreviewStore.shared.update(service, store: self, change)
        }
    }
    private func refreshCopySoon() {
        switch service {
        case .trakt: TraktDirectStore.shared.refreshSoon(store: self)
        case .simkl, .mdblist, .wetrakr: TrackerPreviewStore.shared.refreshSoon(service, store: self)
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
        // Simkl's only removal also clears the title's history, so its list is left as it is.
        // The WeTrakr diary is read-only here for now.
        case .simkl, .wetrakr: return
        }
        var body: [String: Any] = [:]
        let movies = planned.filter { !$0.isSeries }, shows = planned.filter(\.isSeries)
        if !movies.isEmpty { body["movies"] = try movies.map { try serviceRef($0) } }
        if !shows.isEmpty { body["shows"] = try shows.map { try serviceRef($0) } }
        try await send(path, body)
        let refs = planned.map { titleRef($0) }, keys = Set(refs.map(\.diaryKey))
        updateCopy { library in
            library.watchlist.removeAll { keys.contains($0.title.diaryKey) }
            if listed { library.watchlist += refs.map { TraktListed(title: $0, listedAt: nil) } }
        }
    }

    /// Queues an edit for the connected mirrors, never the service the diary comes from.
    func mirror(_ mutation: OptimisticMutation, to providers: Set<SyncProviderKind> = [.trakt, .simkl, .mdblist, .wetrakr]) {
        var skip: Set<SyncProviderKind> = [.cloudflare]
        if let diaryService { skip.insert(providerKind(diaryService)) }
        // The service holding the diary gets your edits directly (one writer, one pace), also
        // while the old server copy is on screen; never a second copy through the mirrors.
        if let serverRecord { skip.insert(providerKind(serverRecord)) }
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
        let path = service == .mdblist ? "/sync/watched" : "/sync/history"
        if title.isSeries {
            guard !episodes.isEmpty else { throw APIError.message("No episode is ready to mark.") }
            let seasons = Set(episodes.map { $0.season }).sorted().map { season in
                ["number": season, "episodes": episodes.filter { $0.season == season }.map { ["number": $0.number, "watched_at": when] }] as [String: Any]
            }
            item["seasons"] = seasons
            try await send(path, ["shows": [item]])
        } else {
            item["watched_at"] = when
            try await send(path, ["movies": [item]])
        }
        let ref = titleRef(title)
        let oneEach = !service.capabilities.keepsRewatches
        let key = ref.diaryKey
        updateCopy { library in
            if title.isSeries {
                for episode in episodes {
                    // Simkl and MDBList keep one watch per episode: the new time replaces the old.
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
                mirror(.markWatch(operationId: UUID().uuidString, titleId: title.id, episodeId: id, watchedAt: when, recordedAt: when, rewatch: false))
            }
        } else {
            mirror(.markWatch(operationId: UUID().uuidString, titleId: title.id, episodeId: nil, watchedAt: when, recordedAt: when, rewatch: false))
        }
        refreshCopySoon()
        return when
    }

    /// Undo for plays just added: exactly those plays (the same title at that time, so another
    /// watch of the same episode is never touched). Still waiting to reach Trakt: taken out of the
    /// queue. Sent but without Trakt's ids yet: Trakt is read first, then those plays removed.
    func serviceUndoPlays(_ title: MediaTitle, at when: String) async throws {
        if service == .trakt, TraktDirectStore.shared.cancelPending(watchedAt: when) {
            updateCopy { library in library.plays.removeAll { $0.historyId < 0 && $0.watchedAt == when } }
            return
        }
        let time = DiaryDate.parse(when)
        func plays() -> [WatchEvent] {
            workspace.activeEvents.filter { event in
                event.titleId == title.id && (event.watchedAt == when
                    || (time != nil && DiaryDate.parse(event.watchedAt).map { abs($0.timeIntervalSince(time!)) < 1 } == true))
            }
        }
        if service == .trakt, plays().contains(where: { (servicePlayID($0) ?? 0) <= 0 }) {
            await TraktDirectStore.shared.check(store: self)
        }
        let found = plays()
        guard !found.isEmpty else { throw APIError.message("That watch isn’t on \(service.name) any more.") }
        try await serviceRemoveWatches(found)
    }

    /// Removes exactly these watches. Trakt removes those very plays (by id, never all plays of an
    /// episode); Simkl and MDBList keep one watch per episode or movie, so that watch is removed.
    func serviceRemoveWatches(_ events: [WatchEvent]) async throws {
        guard !events.isEmpty else { throw APIError.message("There’s no watch to remove.") }
        let ids = events.compactMap(servicePlayID)
        if service == .trakt {
            let known = ids.filter { $0 > 0 }
            guard known.count == events.count else { throw APIError.message("That watch is still reaching Trakt. Try again in a moment.") }
            try await send("/sync/history/remove", ["ids": known])
        } else {
            var movies: [[String: Any]] = [], shows: [Int: [Int: [Int]]] = [:]
            for event in events {
                guard let title = self.title(event.titleId), let tmdb = title.tmdbId else { throw APIError.message("This watch has no TMDB id, so \(service.name) can’t find it.") }
                if title.isSeries {
                    guard let episode = workspace.episodes.first(where: { $0.id == event.episodeId }) else { throw APIError.message("This watch has no episode to remove.") }
                    shows[tmdb, default: [:]][episode.season, default: []].append(episode.number)
                } else { movies.append(["ids": ["tmdb": tmdb]]) }
            }
            let showBodies: [[String: Any]] = shows.keys.sorted().map { tmdb in
                let seasons = shows[tmdb] ?? [:]
                return ["ids": ["tmdb": tmdb], "seasons": seasons.keys.sorted().map { season in
                    ["number": season, "episodes": (seasons[season] ?? []).map { ["number": $0] }] as [String: Any]
                }]
            }
            try await send(service == .mdblist ? "/sync/watched/remove" : "/sync/history/remove", ["movies": movies, "shows": showBodies])
        }
        updateCopy { library in library.plays.removeAll { ids.contains($0.historyId) } }
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

    // MARK: Titles only on the service

    /// Titles only on the service join your server diary (details, poster and episodes; then notes,
    /// tags and Trash work too), a few at a time and once per title per session. Each import
    /// refreshes the diary, and the service diary then finds the title on the server by its TMDB id.
    func adoptServiceOnlyTitles() async {
        guard diaryFromService, !adoptingTraktTitles, !isPreview else { return }
        let now = Date.now, session = sessionRevision
        let candidates = workspace.titles.filter { title in
            isServiceOnly(title) && !adoptedTraktKeys.contains(title.id) && (adoptionRetry[title.id].map { $0.after <= now } ?? true)
        }.prefix(8)
        guard !candidates.isEmpty else { return }
        adoptingTraktTitles = true
        defer { adoptingTraktTitles = false }
        // A title counts as done only once it's in the server diary (or found there already).
        // A failed lookup or import waits 1, 2, 4… minutes (at most 30) and gives up after five
        // tries this session; sign-out starts over.
        func failed(_ id: String) {
            let tries = (adoptionRetry[id]?.tries ?? 0) + 1
            if tries >= 5 { adoptedTraktKeys.insert(id); adoptionRetry[id] = nil; return }
            adoptionRetry[id] = (tries, Date.now.addingTimeInterval(min(1800, 60 * pow(2, Double(tries - 1)))))
        }
        for title in candidates {
            guard diaryFromService, session == sessionRevision else { return }
            guard let tmdb = title.tmdbId else { adoptedTraktKeys.insert(title.id); continue }
            let route = CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdb)
            guard let found = try? await browse(route) else { failed(title.id); continue }
            guard session == sessionRevision else { return }
            if found.libraryTitle != nil { adoptedTraktKeys.insert(title.id); adoptionRetry[title.id] = nil; continue }
            if await importTitle(found.details, category: found.details.suggestedCategory, sendToService: false) != nil {
                adoptedTraktKeys.insert(title.id); adoptionRetry[title.id] = nil
            } else if session == sessionRevision { failed(title.id) }
        }
    }

    // MARK: Title facts

    /// Rating, Planned and dropped go to the service, and favourites to Trakt; everything else
    /// (notes, tags, Queue, and what the service can't keep) to the server's record of the title.
    func servicePatch(_ title: MediaTitle, values: [String: Any]) async throws {
        let item = try serviceRef(title)
        let slot = title.isSeries ? "shows" : "movies"
        if let score = values["score"] as? Double {
            try await send("/sync/ratings", [slot: [item.merging(["rating": Int(score.rounded())]) { $1 }]])
        } else if values["score"] is NSNull {
            try await send("/sync/ratings/remove", [slot: [item]])
        }
        let status = values["status"] as? String
        // Whether the service keeps this status (otherwise the server does).
        var serviceHolds = true
        if let status {
            let wasPlanned = title.status == "planned", wasDropped = title.isSeries && title.status == "dropped"
            switch service {
            case .trakt:
                switch status {
                case "planned":
                    try await send("/sync/watchlist", [slot: [item]])
                    if wasDropped { try await send("/users/hidden/dropped/remove", ["shows": [item]]) }
                case "dropped" where title.isSeries:
                    try await send("/users/hidden/dropped", ["shows": [item]])
                default:
                    if wasPlanned { try await send("/sync/watchlist/remove", [slot: [item]]) }
                    if wasDropped { try await send("/users/hidden/dropped/remove", ["shows": [item]]) }
                    // Trakt has no Completed, Watching or Paused (nor dropped movies): the server's
                    // record of the title keeps your choice, so it survives the next read.
                    serviceHolds = false
                }
            case .simkl:
                // Simkl moves the title to the list for its status (that keeps its history).
                if let list = TraktWritePlan.simklList(status: status, isSeries: title.isSeries) {
                    try await send("/sync/add-to-list", [slot: [item.merging(["to": list]) { $1 }]])
                } else { serviceHolds = false }
            case .mdblist:
                switch status {
                case "planned":
                    try await send("/watchlist/items/add", [slot: [item]])
                    if wasDropped { try await send("/sync/dropped/remove", ["shows": [item]]) }
                case "dropped" where title.isSeries:
                    if wasPlanned { try await send("/watchlist/items/remove", [slot: [item]]) }
                    try await send("/sync/dropped", ["shows": [item]])
                default:
                    if wasPlanned { try await send("/watchlist/items/remove", [slot: [item]]) }
                    if wasDropped { try await send("/sync/dropped/remove", ["shows": [item]]) }
                    serviceHolds = false
                }
            case .wetrakr:
                serviceHolds = false
            }
        }
        let favourite = values["favorite"] as? Bool
        let favouritesHere = service.capabilities.holdsFavourites
        if let favourite, favouritesHere {
            try await send(favourite ? "/sync/favorites" : "/sync/favorites/remove", [slot: [item]])
        }
        let ref = titleRef(title)
        let dropsHere = title.isSeries
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
        // The server keeps the rest: what the service can't hold (a dropped movie; favourites
        // outside Trakt) and notes, tags and Queue.
        var rest = values.filter { !["score", "favorite", "status"].contains($0.key) }
        if let status, !serviceHolds || (!title.isSeries && title.status == "dropped") { rest["status"] = status }
        if let favourite, !favouritesHere { rest["favorite"] = favourite }
        // A title only on the service has no server record yet: its status follows the service
        // until it joins (in a moment, on its own); notes, tags and Queue have to wait for that.
        if isServiceOnly(title) { rest.removeValue(forKey: "status") }
        if !rest.isEmpty {
            guard !isServiceOnly(title) else { throw APIError.message("Notes, tags and Queue need this title in your server diary. It joins on its own in a moment, or add it from its page.") }
            rest["expectedVersion"] = title.version
            let _: EmptyResponse = try await read("/api/titles/\(title.id)", method: "PATCH", body: rest)
        }
    }
}
