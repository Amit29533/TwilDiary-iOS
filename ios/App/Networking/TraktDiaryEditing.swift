import Foundation
import TwilDiaryCore

/// Trakt-first phase 4b: with "Show my diary from Trakt" on, edits go to Trakt. Watches (at their
/// exact time), removing a watch (that very play, by its Trakt id), ratings, Planned, favourites and
/// dropped are written to Trakt and applied to the phone's Trakt copy at once, so the screen
/// updates without a full re-read. Notes, tags, Queue and Trash stay on your server.
///
/// Phase 5: the same edits also go to Simkl and MDBList when they're connected for logging (through
/// the delivery queue, as in the server diary), within what each keeps. Never back to Trakt.
extension DiaryStore {
    /// Queues an edit for the connected mirrors (Simkl, MDBList), never Trakt.
    func mirror(_ mutation: OptimisticMutation, to providers: Set<SyncProviderKind> = [.simkl, .mdblist]) {
        let targets = providers.subtracting([.trakt, .cloudflare]).intersection(providerSettings.activeDirectLoggingProviders)
        guard !targets.isEmpty, !isPreview else { return }
        recordDirectProviderMutation(mutation, providers: targets)
    }

    private func traktRef(_ title: MediaTitle) throws -> [String: Any] {
        guard let tmdb = title.tmdbId else { throw APIError.message("“\(title.name)” has no TMDB id, so Trakt can’t find it.") }
        return ["ids": ["tmdb": tmdb]]
    }
    private func traktTitleRef(_ title: MediaTitle) -> TraktTitleRef {
        TraktTitleRef(kind: title.isSeries ? .show : .movie, traktId: nil, tmdbId: title.tmdbId, name: title.name, year: title.year)
    }
    private func stamp(_ date: Date) -> String { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date) }
    /// A title only on Trakt has no server record for notes, tags or files yet.
    func isTraktOnly(_ title: MediaTitle) -> Bool { title.id.hasPrefix("tv:") || title.id.hasPrefix("movie:") }

    // MARK: Watches

    /// Adds plays (movie, or episodes of one show) at the given times.
    func traktAddPlays(_ title: MediaTitle, episodes: [(season: Int, number: Int)], at date: Date) async throws {
        var item = try traktRef(title)
        let when = stamp(date)
        if title.isSeries {
            guard !episodes.isEmpty else { throw APIError.message("No episode is ready to mark.") }
            let seasons = Set(episodes.map { $0.season }).sorted().map { season in
                ["number": season, "episodes": episodes.filter { $0.season == season }.map { ["number": $0.number, "watched_at": when] }] as [String: Any]
            }
            item["seasons"] = seasons
            try await TraktDirectStore.shared.write("/sync/history", body: ["shows": [item]], store: self)
        } else {
            item["watched_at"] = when
            try await TraktDirectStore.shared.write("/sync/history", body: ["movies": [item]], store: self)
        }
        let ref = traktTitleRef(title)
        TraktDirectStore.shared.update(store: self) { library in
            if title.isSeries {
                for episode in episodes {
                    library.plays.append(TraktPlay(historyId: -TrackerDecode.playID("local|\(ref.tmdbId ?? 0)|\(episode.season)|\(episode.number)|\(when)"),
                                                   title: ref, season: episode.season, episode: episode.number, watchedAt: when))
                }
            } else {
                library.plays.append(TraktPlay(historyId: -TrackerDecode.playID("local|\(ref.tmdbId ?? 0)|\(when)"), title: ref, watchedAt: when))
            }
        }
        // The mirrors get each watch at the same time (the Trakt diary now has the episodes).
        if title.isSeries {
            for episode in episodes {
                let id = workspace.episodes.first { $0.titleId == title.id && $0.season == episode.season && $0.number == episode.number }?.id
                    ?? "\(title.id)|s\(episode.season)e\(episode.number)"
                mirror(.markWatch(operationId: UUID().uuidString, titleId: title.id, episodeId: id, watchedAt: when, recordedAt: when, rewatch: false))
            }
        } else {
            mirror(.markWatch(operationId: UUID().uuidString, titleId: title.id, episodeId: nil, watchedAt: when, recordedAt: when, rewatch: false))
        }
        TraktDirectStore.shared.refreshSoon(store: self)
    }
    /// Removes exactly these plays from Trakt history (never all plays of a title or episode).
    func traktRemovePlays(_ ids: [Int64]) async throws {
        let known = ids.filter { $0 > 0 }
        guard !known.isEmpty else { throw APIError.message("That watch is still reaching Trakt. Try again in a moment.") }
        try await TraktDirectStore.shared.write("/sync/history/remove", body: ["ids": known], store: self)
        TraktDirectStore.shared.update(store: self) { library in library.plays.removeAll { known.contains($0.historyId) } }
    }
    /// The Trakt history id behind a diary watch of the Trakt diary ("trakt-123").
    func traktPlayID(_ event: WatchEvent) -> Int64? {
        guard event.id.hasPrefix("trakt-") else { return nil }
        return Int64(event.id.dropFirst("trakt-".count))
    }
    /// The latest play of a title (or one episode of it).
    func latestTraktEvent(titleID: String, episodeID: String? = nil, any: Bool = false) -> WatchEvent? {
        workspace.activeEvents.filter { $0.titleId == titleID && (any || $0.episodeId == episodeID) }
            .max { ($0.watchedAt ?? $0.recordedAt) < ($1.watchedAt ?? $1.recordedAt) }
    }

    func traktSeasonProgress(_ title: MediaTitle, season: Int, count: Int, watchedAt: Date) async throws {
        let episodes = workspace.episodes.filter { $0.titleId == title.id && $0.season == season }.sorted { $0.number < $1.number }
        let wanted = Set(episodes.prefix(max(0, count)).map(\.id))
        let watched = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
        let add = episodes.filter { wanted.contains($0.id) && !watched.contains($0.id) }
        if !add.isEmpty { try await traktAddPlays(title, episodes: add.map { (season: $0.season, number: $0.number) }, at: watchedAt) }
        let remove = episodes.filter { !wanted.contains($0.id) && watched.contains($0.id) }
            .compactMap { latestTraktEvent(titleID: title.id, episodeID: $0.id) }.compactMap(traktPlayID)
        if !remove.isEmpty { try await traktRemovePlays(remove) }
    }

    /// A title's status in Trakt terms. Completing marks what's aired and unwatched (a movie gets
    /// its watch); the rest is the watchlist / dropped / favourite side (traktPatch).
    func traktSetStatus(_ title: MediaTitle, status: String, watchedAt: Date) async throws {
        if status == "completed" {
            let today = DiaryDate.day(now)
            let watched = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
            let due = workspace.episodes.filter { episode in
                episode.titleId == title.id && episode.season > 0 && !watched.contains(episode.id)
                    && (episode.airedOn.map { aired in aired <= today } ?? false)
            }
            if !title.isSeries && !workspace.activeEvents.contains(where: { $0.titleId == title.id }) {
                try await traktAddPlays(title, episodes: [], at: watchedAt)
            } else if !due.isEmpty {
                try await traktAddPlays(title, episodes: due.map { (season: $0.season, number: $0.number) }, at: watchedAt)
            }
        }
        try await traktPatch(title, values: ["status": status])
    }

    // MARK: Titles only on Trakt

    /// Titles only on Trakt join your server diary (details, poster and episodes; then notes, tags
    /// and Trash work too), a few at a time and once per title per session. Each import refreshes
    /// the diary, and the Trakt diary then finds the title on the server by its TMDB id.
    func adoptTraktOnlyTitles() async {
        guard diaryFromTrakt, !adoptingTraktTitles, !isPreview else { return }
        let candidates = workspace.titles.filter { isTraktOnly($0) && !adoptedTraktKeys.contains($0.id) }.prefix(8)
        guard !candidates.isEmpty else { return }
        adoptingTraktTitles = true
        defer { adoptingTraktTitles = false }
        for title in candidates {
            adoptedTraktKeys.insert(title.id)
            guard diaryFromTrakt, let tmdb = title.tmdbId else { continue }
            let route = CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdb)
            guard let found = try? await browse(route), found.libraryTitle == nil else { continue }
            _ = await importTitle(found.details, category: found.details.suggestedCategory)
        }
    }

    // MARK: Title facts

    /// Rating, Planned, dropped and favourite go to Trakt; everything else (notes, tags, Queue) to
    /// the server's record of the title.
    func traktPatch(_ title: MediaTitle, values: [String: Any]) async throws {
        let item = try traktRef(title)
        let slot = title.isSeries ? "shows" : "movies"
        if let score = values["score"] as? Double {
            try await TraktDirectStore.shared.write("/sync/ratings", body: [slot: [item.merging(["rating": Int(score.rounded())]) { $1 }]], store: self)
        } else if values["score"] is NSNull {
            try await TraktDirectStore.shared.write("/sync/ratings/remove", body: [slot: [item]], store: self)
        }
        if let status = values["status"] as? String {
            switch status {
            case "planned":
                try await TraktDirectStore.shared.write("/sync/watchlist", body: [slot: [item]], store: self)
                if title.isSeries && title.status == "dropped" { try await TraktDirectStore.shared.write("/users/hidden/dropped/remove", body: ["shows": [item]], store: self) }
            case "dropped" where title.isSeries:
                try await TraktDirectStore.shared.write("/users/hidden/dropped", body: ["shows": [item]], store: self)
            default:
                if title.status == "planned" { try await TraktDirectStore.shared.write("/sync/watchlist/remove", body: [slot: [item]], store: self) }
                if title.isSeries && title.status == "dropped" { try await TraktDirectStore.shared.write("/users/hidden/dropped/remove", body: ["shows": [item]], store: self) }
            }
        }
        if let favourite = values["favorite"] as? Bool {
            try await TraktDirectStore.shared.write(favourite ? "/sync/favorites" : "/sync/favorites/remove", body: [slot: [item]], store: self)
        }
        let ref = traktTitleRef(title)
        TraktDirectStore.shared.update(store: self) { library in
            let key = ref.diaryKey
            if let score = values["score"] as? Double {
                library.ratings.removeAll { $0.title.diaryKey == key }
                library.ratings.append(TraktRating(title: ref, rating: Int(score.rounded()), ratedAt: nil))
            } else if values["score"] is NSNull { library.ratings.removeAll { $0.title.diaryKey == key } }
            if let status = values["status"] as? String {
                library.watchlist.removeAll { $0.title.diaryKey == key }
                library.dropped.removeAll { $0.title.diaryKey == key }
                if status == "planned" { library.watchlist.append(TraktListed(title: ref, listedAt: nil)) }
                if status == "dropped" && title.isSeries { library.dropped.append(TraktListed(title: ref, listedAt: nil)) }
            }
            if let favourite = values["favorite"] as? Bool {
                library.favorites.removeAll { $0.title.diaryKey == key }
                if favourite { library.favorites.append(TraktListed(title: ref, listedAt: nil)) }
            }
        }
        // The mirrors: ratings to both; a status only where the service can hold it (MDBList keeps
        // Planned and dropped shows; Simkl moves the title to the list for its status).
        let score = values["score"] as? Double, clearScore = values["score"] is NSNull
        if score != nil || clearScore {
            mirror(.patchTitle(titleId: title.id, expectedVersion: nil, status: nil, score: score, clearScore: clearScore, favorite: nil, queued: nil, notes: nil))
        }
        if let status = values["status"] as? String {
            var to: Set<SyncProviderKind> = []
            if status == "planned" || TraktWritePlan.simklList(status: status, isSeries: title.isSeries) != nil { to.insert(.simkl) }
            if status == "planned" || (status == "dropped" && title.isSeries) { to.insert(.mdblist) }
            mirror(.patchTitle(titleId: title.id, expectedVersion: nil, status: status, score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil), to: to)
        }
        // The server keeps the rest, and a dropped movie (Trakt only drops shows).
        var rest = values.filter { !["score", "favorite", "status"].contains($0.key) }
        if let status = values["status"] as? String, status == "dropped" || title.status == "dropped", !title.isSeries { rest["status"] = status }
        if !rest.isEmpty {
            guard !isTraktOnly(title) else { throw APIError.message("Notes, tags and Queue need this title in your server diary. Add it from its page first.") }
            rest["expectedVersion"] = title.version
            let _: EmptyResponse = try await read("/api/titles/\(title.id)", method: "PATCH", body: rest)
        }
    }
}
