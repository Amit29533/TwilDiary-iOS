import Foundation
import TwilDiaryCore

extension DiaryStore {
    func searchDiary(_ query: String, page: Int = 1) async throws -> DiarySearchPage {
        guard DiarySearchTools.ready(query), (1...500).contains(page) else { throw APIError.message("Enter a title or IMDb ID (2–200 characters)") }
        #if DEBUG
        if isPreview {
            let result = PreviewCatalog.page(query: query, page: page)
            return DiarySearchPage(library: [], online: result.items, page: result.page, totalPages: result.totalPages)
        }
        #endif
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
        return try await read(CatalogTools.apiPath("/api/metadata/browse", query: ["type": route.kind.rawValue, "id": String(route.id)]))
    }
    func cast(_ route: CatalogRoute) async throws -> CastResponse {
        #if DEBUG
        if isPreview {
            if ProcessInfo.processInfo.arguments.contains("--ui-slow-metadata") { try await Task.sleep(for: .milliseconds(700)) }
            return PreviewCatalog.cast
        }
        #endif
        return try await read(CatalogTools.apiPath("/api/metadata/cast", query: ["type": route.kind.rawValue, "id": String(route.id)]))
    }
    func related(_ route: CatalogRoute) async throws -> RelatedResponse {
        #if DEBUG
        if isPreview {
            if ProcessInfo.processInfo.arguments.contains("--ui-slow-metadata") { try await Task.sleep(for: .milliseconds(700)) }
            return PreviewCatalog.related
        }
        #endif
        return try await read(CatalogTools.apiPath("/api/metadata/related", query: ["type": route.kind.rawValue, "id": String(route.id)]))
    }
    func person(_ id: Int) async throws -> PersonResponse {
        guard !needsSignIn else { throw APIError.signIn }
        if let saved = cachedPeople[id], Date.now.timeIntervalSince(saved.at) < 900 { return saved.value }
        let revision = sessionRevision
        let response: PersonResponse
        #if DEBUG
        if isPreview { response = PreviewCatalog.person }
        else { response = try await read(CatalogTools.apiPath("/api/metadata/person", query: ["id": String(id)])) }
        #else
        response = try await read(CatalogTools.apiPath("/api/metadata/person", query: ["id": String(id)]))
        #endif
        try Task.checkCancellation()
        guard revision == sessionRevision, !needsSignIn else { throw CancellationError() }
        cachedPeople.removeValue(forKey: id)
        if cachedPeople.count >= 32, let oldest = cachedPeople.min(by: { $0.value.at < $1.value.at })?.key { cachedPeople.removeValue(forKey: oldest) }
        cachedPeople[id] = (.now, response)
        return response
    }
    func prepareSavedSeason(_ title: MediaTitle, number: Int, force: Bool = false) async throws {
        guard (0...999).contains(number) else { throw APIError.message("Choose a valid season.") }
        guard force || SeasonMetadata.needsPreparation(title: title, workspace: workspace, season: number, now: now) else { return }
        let _: EmptyResponse = try await read("/api/titles/\(title.id)/seasons/\(number)/metadata", method: "POST", body: [:])
        // Season metadata only changes this title's rows; refresh just this title.
        try Task.checkCancellation(); try await refreshAfterWrite([title.id])
    }
    func catalogEpisodes(_ route: CatalogRoute, season: Int, reveal: Bool) async throws -> CatalogEpisodesPage {
        guard route.kind == .tv, (0...999).contains(season) else { throw APIError.message("Choose a valid series season.") }
        if isPreview {
            return CatalogEpisodesPage(items: (1...12).map { CatalogEpisode(number: $0, name: reveal ? "Chapter \($0)" : "", overview: reveal ? "Reference episode summary." : "", airedOn: "2024-01-01", stillPath: reveal ? "/reference_backdrop.jpg" : nil, communityScore: 8.1) })
        }
        return try await read(CatalogTools.apiPath("/api/metadata/season", query: ["type": route.kind.rawValue, "id": String(route.id), "season": String(season), "reveal": reveal ? "1" : "0"]))
    }
    func importTitle(_ details: CatalogDetails, category: String) async -> String? {
        guard !busy, canMutate else { return nil }
        let revision = sessionRevision
        busy = true; defer { if revision == sessionRevision { busy = false } }
        var confirmed = false
        do {
            let result: ImportedTitle = try await read("/api/metadata/import", method: "POST", body: ["mediaType": details.mediaType.rawValue, "tmdbId": details.id, "category": category, "status": "planned", "score": NSNull()])
            confirmed = true
            try await refreshAfterWrite([result.title.id])
            error = nil
            return result.title.id
        } catch is CancellationError { return nil }
        catch {
            guard revision == sessionRevision else { return nil }
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
