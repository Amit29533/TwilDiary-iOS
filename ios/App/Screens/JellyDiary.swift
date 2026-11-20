import Foundation
import TwilDiaryCore

/// Marking a Jellyfin film or episode watched in the diary (when it's finished in the player, or
/// marked watched with a long press).
@MainActor enum JellyDiary {
    /// The note to show: what was marked, or why nothing was.
    static func mark(_ item: JellyfinClient.Item, client: JellyfinClient, store: DiaryStore) async -> String {
        let episode = item.kind == "Episode"
        var ids = item.ProviderIds
        if episode, let series = item.SeriesId { ids = (try? await client.item(series))?.ProviderIds }
        guard let tmdb = ids?["Tmdb"].flatMap(Int.init),
              let titleID = store.libraryIdentity(CatalogItem(id: tmdb, mediaType: episode ? .tv : .movie, name: item.SeriesName ?? item.Name ?? "")),
              let title = store.title(titleID) else { return "Not in your diary, so not marked" }
        if episode {
            guard let match = await diaryEpisode(item, title: title, client: client, store: store) else { return "Episode not found in your diary" }
            return await store.recordViewing(title, episode: match, watchedAt: store.now) ? "Marked S\(match.season) E\(match.number) in your diary" : ""
        }
        let seen = store.titleScope(title.id).activeEvents.contains { $0.titleId == title.id && $0.episodeId == nil }
        return await store.recordViewing(title, rewatch: seen, watchedAt: store.now) ? "Marked in your diary" : ""
    }

    /// The diary's episode: by season and number; else (when Jellyfin splits the seasons differently,
    /// as it often does for anime) by the episode's place in the whole show, specials left out.
    private static func diaryEpisode(_ item: JellyfinClient.Item, title: MediaTitle, client: JellyfinClient, store: DiaryStore) async -> Episode? {
        if let season = item.ParentIndexNumber, let number = item.IndexNumber,
           let direct = store.episodesForSeason(title.id, season: season).first(where: { $0.number == number }) {
            return direct
        }
        guard let series = item.SeriesId, let all = try? await client.allEpisodes(of: series, user: nil) else { return nil }
        let order = all.filter { ($0.ParentIndexNumber ?? 0) > 0 }
            .sorted { (($0.ParentIndexNumber ?? 0), ($0.IndexNumber ?? 0)) < (($1.ParentIndexNumber ?? 0), ($1.IndexNumber ?? 0)) }
        guard let place = order.firstIndex(where: { $0.Id == item.Id }) else { return nil }
        let diary = store.titleEpisodes(title.id).filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        return diary.indices.contains(place) ? diary[place] : nil
    }
}
