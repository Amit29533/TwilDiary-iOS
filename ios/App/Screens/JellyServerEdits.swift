import SwiftUI
import TwilDiaryCore

/// Changes made to the server from JellySpace this session: titles deleted (gone from every row at
/// once; the server's own lists catch up when they next load), and whether you may delete at all.
@MainActor @Observable final class JellyServerEdits {
    static let shared = JellyServerEdits()
    /// Deleted from the server this session.
    var deleted: Set<String> = []
    /// Whether Delete from server is offered.
    private(set) var canDelete = false
    @ObservationIgnored private var checked: String?

    /// Deleted: the title itself, or the show an episode or season is in.
    func isDeleted(_ item: JellyfinClient.Item) -> Bool {
        deleted.contains(item.Id) || item.SeriesId.map(deleted.contains) == true
    }
    /// Whether this account may delete: connected with the server's API key (it may do anything), an
    /// administrator, or allowed to delete content in Jellyfin's user settings. Asked once a session.
    func check(client: JellyfinClient) async {
        let account = JellyAccount.userID
        let key = client.base.absoluteString + "|" + (account ?? "key")
        guard checked != key else { return }
        checked = key
        guard let account else { canDelete = true; return }
        guard let row = try? await client.user(account) else { checked = nil; return }
        let policy = row.Policy
        canDelete = policy?.IsAdministrator == true || policy?.EnableContentDeletion == true
            || !(policy?.EnableContentDeletionFromFolders ?? []).isEmpty
    }
    /// What can be deleted: a film, show, season, episode or video (not a library or folder).
    static func deletable(_ item: JellyfinClient.Item) -> Bool {
        ["Movie", "Series", "Season", "Episode", "Video", "MusicVideo"].contains(item.kind)
    }
    /// The confirmation's words.
    static func warning(kind: String) -> String {
        switch kind {
        case "Series": "This deletes the show, all its seasons and episodes, and their files from your Jellyfin server. You can't undo this."
        case "Season": "This deletes the season, its episodes and their files from your Jellyfin server. You can't undo this."
        default: "This deletes it and its files from your Jellyfin server. You can't undo this."
        }
    }
}

/// View in Diary: a film's or show's page in the diary (TMDB's), from JellySpace. An episode or a
/// season goes to its show's.
@MainActor enum JellyDiaryLink {
    static func tmdb(_ ids: [String: String]?) -> Int? {
        ids?.first { $0.key.lowercased() == "tmdb" }.flatMap { Int($0.value) }
    }
    /// Whether it may have a page: a film or show with a TMDB id (or none read yet), a season or an
    /// episode of a show.
    static func offers(_ item: JellyfinClient.Item) -> Bool {
        switch item.kind {
        case "Movie", "Series": item.ProviderIds == nil || tmdb(item.ProviderIds) != nil
        case "Season", "Episode": item.SeriesId != nil
        default: false
        }
    }
    /// The diary page for it, looked up on the server when the list it came from had no TMDB id.
    static func route(for item: JellyfinClient.Item, client: JellyfinClient) async -> CatalogRoute? {
        if item.kind == "Season" || item.kind == "Episode" {
            guard let series = item.SeriesId, let show = await lookUp(series, client: client), let id = tmdb(show.ProviderIds) else { return nil }
            return CatalogRoute(kind: .tv, id: id)
        }
        guard item.kind == "Movie" || item.kind == "Series" else { return nil }
        var id = tmdb(item.ProviderIds)
        if id == nil { id = tmdb(await lookUp(item.Id, client: client)?.ProviderIds) }
        return id.map { CatalogRoute(kind: item.kind == "Movie" ? .movie : .tv, id: $0) }
    }
    private static func lookUp(_ id: String, client: JellyfinClient) async -> JellyfinClient.Item? {
        guard let found = try? await client.item(id) else { return nil }
        return found
    }
}
