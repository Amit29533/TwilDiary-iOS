import Foundation
import TwilDiaryCore

extension DiaryStore {
    func searchDiary(_ query: String, page: Int = 1) async throws -> DiarySearchPage {
        guard DiarySearchTools.ready(query), (1...500).contains(page) else { throw APIError.message("Enter a title or IMDb ID (2–200 characters)") }
        #if DEBUG
        if isPreview {
            if ProcessInfo.processInfo.arguments.contains("--ui-anime-navigation"), query == "Frieren: Beyond Journey’s End" {
                return DiarySearchPage(library: [], online: [CatalogItem(id: 209867, mediaType: .tv, name: query, year: 2023)], page: 1, totalPages: 1)
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-anime-navigation"), query.hasPrefix("Rascal Does Not Dream") {
                let film = query.contains("Knapsack")
                let item = CatalogItem(id: film ? 910001 : 910002, mediaType: film ? .movie : .tv, name: query, year: film ? 2023 : 2025)
                return DiarySearchPage(library: workspace.activeTitles.prefix(1).map(SearchLibraryTitle.init), online: [item], page: 1, totalPages: 1)
            }
            let result = PreviewCatalog.page(query: query, page: page)
            return DiarySearchPage(library: [], online: result.items, page: result.page, totalPages: result.totalPages)
        }
        #endif
        // TMDB from the phone with your key; which results are already yours comes from the diary on the phone.
        if let token = TMDBDirect.token(self) {
            let found = try await TMDBDirect.search(DiarySearchTools.normalize(query), page: page, token: token)
            var library: [SearchLibraryTitle] = [], online: [CatalogItem] = []
            for item in found.items {
                if let saved = workspace.activeTitles.first(where: { $0.tmdbId == item.id && $0.isSeries == (item.mediaType == .tv) }) {
                    if !library.contains(where: { $0.id == saved.id }) { library.append(SearchLibraryTitle(saved)) }
                } else { online.append(item) }
            }
            return DiarySearchPage(library: library, online: online, page: found.page, totalPages: found.totalPages)
        }
        return try await read(CatalogTools.apiPath("/api/search", query: ["q": query, "scope": "online", "page": String(page)]))
    }
    func browse(_ route: CatalogRoute) async throws -> CatalogBrowse {
        #if DEBUG
        if isPreview {
            let value = PreviewCatalog.browse(route)
            let saved = workspace.titles.first { $0.tmdbId == route.id && $0.isSeries == (route.kind == .tv) }
            return CatalogBrowse(details: value.details, libraryTitle: saved.map { CatalogBrowse.Saved(id: $0.id, trashed: $0.deletedAt != nil) })
        }
        #endif
        // TMDB from the phone with your key; whether it's already in your diary comes from the diary on the phone.
        if let token = TMDBDirect.token(self), let details = try? await TMDBDirect.details(route, token: token) {
            let saved = workspace.titles.first { $0.tmdbId == route.id && $0.isSeries == (route.kind == .tv) }
            return CatalogBrowse(details: details, libraryTitle: saved.map { CatalogBrowse.Saved(id: $0.id, trashed: $0.deletedAt != nil) })
        }
        return try await read(CatalogTools.apiPath("/api/metadata/browse", query: ["type": route.kind.rawValue, "id": String(route.id)]))
    }
    func cast(_ route: CatalogRoute) async throws -> CastResponse {
        #if DEBUG
        if isPreview {
            if ProcessInfo.processInfo.arguments.contains("--ui-slow-metadata") { try await Task.sleep(for: .milliseconds(700)) }
            if ProcessInfo.processInfo.arguments.contains("--ui-anime-navigation") {
                return try JSONDecoder().decode(CastResponse.self, from: Data(#"{"cast":[{"id":700001,"name":"Kana Ichinose","character":"Fern"}],"stale":false}"#.utf8))
            }
            return PreviewCatalog.cast
        }
        #endif
        // TMDB from the phone with your key; the diary server is the backup.
        if let token = TMDBDirect.token(self), let direct = try? await TMDBDirect.cast(route, token: token) { return direct }
        return try await read(CatalogTools.apiPath("/api/metadata/cast", query: ["type": route.kind.rawValue, "id": String(route.id)]))
    }
    func related(_ route: CatalogRoute) async throws -> RelatedResponse {
        #if DEBUG
        if isPreview {
            if ProcessInfo.processInfo.arguments.contains("--ui-slow-metadata") { try await Task.sleep(for: .milliseconds(700)) }
            return PreviewCatalog.related
        }
        #endif
        if let token = TMDBDirect.token(self), let direct = try? await TMDBDirect.related(route, token: token), !direct.items.isEmpty { return direct }
        return try await read(CatalogTools.apiPath("/api/metadata/related", query: ["type": route.kind.rawValue, "id": String(route.id)]))
    }
    func person(_ id: Int) async throws -> PersonResponse {
        guard !needsSignIn else { throw APIError.signIn }
        if let saved = cachedPeople[id], Date.now.timeIntervalSince(saved.at) < 900 { return saved.value }
        let revision = sessionRevision
        let response: PersonResponse
        #if DEBUG
        if isPreview {
            if ProfileFormattingPreview.enabled { response = try ProfileFormattingPreview.person(id) ?? PreviewCatalog.person }
            else { response = PreviewCatalog.person }
        }
        else { response = try await personFromTMDB(id) }
        #else
        response = try await personFromTMDB(id)
        #endif
        try Task.checkCancellation()
        guard revision == sessionRevision, !needsSignIn else { throw CancellationError() }
        cachedPeople.removeValue(forKey: id)
        if cachedPeople.count >= 32, let oldest = cachedPeople.min(by: { $0.value.at < $1.value.at })?.key { cachedPeople.removeValue(forKey: oldest) }
        cachedPeople[id] = (.now, response)
        return response
    }
    /// TMDB from the phone with your key; the diary server (which caches people for a week) without one.
    private func personFromTMDB(_ id: Int) async throws -> PersonResponse {
        if let token = TMDBDirect.token(self) { return try await TMDBDirect.person(id, token: token) }
        return try await read(CatalogTools.apiPath("/api/metadata/person", query: ["id": String(id)]))
    }
    func prepareSavedSeason(_ title: MediaTitle, number: Int, force: Bool = false) async throws {
        guard (0...999).contains(number) else { throw APIError.message("Choose a valid season.") }
        guard force || SeasonMetadata.needsPreparation(title: title, workspace: workspace, season: number, now: now) else { return }
        // No server: the phone's catalog reads the show's seasons from TMDB and the diary is rebuilt.
        if phoneOnly {
            if let tmdb = title.tmdbId, title.isSeries { await PhoneCatalog.shared.fillEpisodes(["tv:\(tmdb)"], store: self) }
            return
        }
        let _: EmptyResponse = try await read("/api/titles/\(title.id)/seasons/\(number)/metadata", method: "POST", body: [:])
        // Season metadata only changes this title's rows; refresh just this title.
        try Task.checkCancellation(); try await refreshAfterWrite([title.id])
    }
    func catalogEpisodes(_ route: CatalogRoute, season: Int, reveal: Bool) async throws -> CatalogEpisodesPage {
        guard route.kind == .tv, (0...999).contains(season) else { throw APIError.message("Choose a valid series season.") }
        if isPreview {
            return CatalogEpisodesPage(items: (1...12).map { CatalogEpisode(number: $0, name: reveal ? "Chapter \($0)" : "", overview: reveal ? "Reference episode summary." : "", airedOn: "2024-01-01", stillPath: reveal ? "/reference_backdrop.jpg" : nil, communityScore: 8.1) })
        }
        if let token = TMDBDirect.token(self), let direct = try? await TMDBDirect.season(route.id, number: season, reveal: reveal, token: token) { return direct }
        return try await read(CatalogTools.apiPath("/api/metadata/season", query: ["type": route.kind.rawValue, "id": String(route.id), "season": String(season), "reveal": reveal ? "1" : "0"]))
    }
    /// `sendToService`: also put it on the watchlist of the service that holds the diary (a title
    /// you add); false when the title came from that service (joining the server diary).
    func importTitle(_ details: CatalogDetails, category: String, sendToService: Bool = true) async -> String? {
        // A title joining from the service is background work: it never holds "busy", which would
        // turn away your own edits made meanwhile, and its failures stay quiet (it's retried).
        let quiet = !sendToService
        // No server (a service alone, or On this phone): the title goes on the service's watchlist
        // (or the diary on the phone), with its details kept on the phone.
        if phoneOnly {
            guard sendToService else { return nil }
            let title = PhoneCatalog.shared.add(details, category: category)
            applyDiarySource()
            do { try await servicePatch(title, values: ["status": "planned"]); error = nil; return title.id }
            catch { self.error = error.localizedDescription; return nil }
        }
        guard quiet || !busy, canMutate else { return nil }
        let revision = sessionRevision
        if !quiet { busy = true }
        defer { if !quiet, revision == sessionRevision { busy = false } }
        var confirmed = false
        do {
            let result: ImportedTitle = try await read("/api/metadata/import", method: "POST", body: ["mediaType": details.mediaType.rawValue, "tmdbId": details.id, "category": category, "status": "planned", "score": NSNull()])
            confirmed = true
            try await refreshAfterWrite([result.title.id])
            error = nil
            // Trakt (or the service) holds the diary: what you add goes on its watchlist at once,
            // instead of only into the server's copy, where nothing would send it on.
            if sendToService, diaryFromService || traktHoldsDiary {
                let name = diaryService?.name ?? "Trakt"
                if let saved = title(result.title.id) {
                    do { try await servicePatch(saved, values: ["status": "planned"]) }
                    catch is CancellationError {}
                    catch { self.error = "Added to your library, but it couldn’t go on your \(name) watchlist: " + error.localizedDescription }
                } else {
                    self.error = "Added to your library. Open it and set it to Planned to put it on your \(name) watchlist."
                }
            }
            // On your Jellyfin already: a quiet Jellyfin sync saves its folders to the new title now,
            // so they show without running Sync by hand (the title page shows Jellyfin meanwhile).
            if sendToService, !isPreview, JellyfinSettings.configured,
               JellyfinShelf.shared.entries.contains(where: { $0.tmdb == details.id && $0.movie == (details.mediaType == .movie) }) {
                Task { await JellyfinSync(store: self).run() }
            }
            return result.title.id
        } catch is CancellationError { return nil }
        catch {
            guard revision == sessionRevision, !quiet else { return nil }
            if confirmed { self.error = "Added to your library, but the refresh failed. Refresh or try adding again to reopen it; a second copy will not be created." }
            else { self.error = error.localizedDescription }
            return nil
        }
    }
    private struct ImportedTitle: Decodable {
        struct Identity: Decodable { let id: String }
        let title: Identity
    }
}
