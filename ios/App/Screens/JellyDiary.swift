import Foundation
import TwilDiaryCore

/// Marking a Jellyfin film or episode watched in the diary (when it's finished in the player or on a
/// Chromecast, or marked watched by hand), and taking that watch back when it's un-marked.
@MainActor enum JellyDiary {
    /// What JellySpace has logged since the app opened, by the Jellyfin item: un-marking it takes back
    /// that very watch, never one from before.
    private static var logged: [String: (title: String, when: String)] = [:]
    /// The times of watches taken back (the diary on screen can hold them a moment longer).
    private static var undone: Set<String> = []
    private static var last: Task<Void, Never>?

    /// Marked watched or unwatched by hand: one change after another, so a quick on and off ends as
    /// you left it.
    static func follow(_ watched: Bool, _ item: JellyfinClient.Item, client: JellyfinClient, store: DiaryStore) {
        let before = last
        last = Task {
            await before?.value
            if watched { _ = await mark(item, client: client, store: store) } else { await unmark(item, store: store) }
        }
    }

    /// The note to show: what was marked, or why nothing was.
    static func mark(_ item: JellyfinClient.Item, client: JellyfinClient, store: DiaryStore) async -> String {
        // A change being saved just then is waited for: the watch was lost to it before, without a word.
        guard await store.readyToRecord() else { return "Your diary isn’t ready, so not marked" }
        let episode = item.kind == "Episode"
        var ids = item.ProviderIds
        if episode, let series = item.SeriesId { ids = (try? await client.item(series))?.ProviderIds }
        guard let tmdb = ids?["Tmdb"].flatMap(Int.init),
              let titleID = store.libraryIdentity(CatalogItem(id: tmdb, mediaType: episode ? .tv : .movie, name: item.SeriesName ?? item.Name ?? "")),
              let title = store.title(titleID) else { return "Not in your diary, so not marked" }
        let found = episode ? await diaryEpisodes(item, title: title, client: client, store: store) : []
        if episode, found.isEmpty { return "Episode not found in your diary" }
        let now = store.now, length = item.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0
        let watches = store.activeEvents.filter { $0.titleId == title.id && !undone.contains($0.watchedAt ?? "") }
        func justLogged(_ id: String?) -> Bool { sameViewing(watches.filter { $0.episodeId == id }.map(\.watchedAt), now: now, length: length) }
        let fresh = found.filter { !justLogged($0.id) }
        if episode ? fresh.isEmpty : justLogged(nil) { return "Already in your diary" }
        guard let when = await store.logViewing(title, episodes: fresh, watchedAt: now) else { return "Couldn’t mark it in your diary" }
        logged[item.Id] = (title.id, when)
        guard let first = fresh.first, let end = fresh.last else { return "Marked in your diary" }
        return "Marked S\(first.season) E\(first.number)" + (fresh.count > 1 ? "–E\(end.number)" : "") + " in your diary"
    }

    /// Un-marked: the watch JellySpace logged for it comes off the diary and its services again. A watch
    /// it didn't log stays (un-marking something in Jellyfin mustn't cost you years of history).
    private static func unmark(_ item: JellyfinClient.Item, store: DiaryStore) async {
        guard let entry = logged[item.Id], await store.undoViewing(titleID: entry.title, at: entry.when) else { return }
        logged[item.Id] = nil
        undone.insert(entry.when)
    }

    /// Whether one of these watches is this same viewing: logged so lately that it can't have been
    /// watched again since (less than most of its length ago). It stops a second watch when the same
    /// viewing is marked twice: by hand and by finishing it, or on the phone and on the TV.
    nonisolated static func sameViewing(_ watches: [String?], now: Date, length: Double) -> Bool {
        let window = max(600, length * 0.8)
        return watches.contains { watch in
            guard let at = DiaryDate.parse(watch) else { return false }
            let ago = now.timeIntervalSince(at)
            return ago > -60 && ago < window
        }
    }

    /// The diary's episodes: by season and number (each of them, for a file that holds several); else
    /// (when Jellyfin splits the seasons differently, as it often does for anime) by the episode's
    /// place in the whole show, specials left out.
    private static func diaryEpisodes(_ item: JellyfinClient.Item, title: MediaTitle, client: JellyfinClient, store: DiaryStore) async -> [Episode] {
        if let season = item.ParentIndexNumber, let number = item.IndexNumber {
            let covered = Self.numbers(number, to: item.IndexNumberEnd)
            let direct = store.episodesForSeason(title.id, season: season).filter { covered.contains($0.number) }.sorted { $0.number < $1.number }
            if direct.first?.number == number { return direct }
        }
        guard let series = item.SeriesId, let all = try? await client.allEpisodes(of: series, user: nil) else { return [] }
        let order = all.filter { ($0.ParentIndexNumber ?? 0) > 0 }
            .sorted { (($0.ParentIndexNumber ?? 0), ($0.IndexNumber ?? 0)) < (($1.ParentIndexNumber ?? 0), ($1.IndexNumber ?? 0)) }
        guard let place = order.firstIndex(where: { $0.Id == item.Id }) else { return [] }
        let diary = store.titleEpisodes(title.id).filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        // Only when both count the show alike: with an episode missing on one side, the place would
        // mark a neighbouring episode.
        return diary.count == order.count && diary.indices.contains(place) ? [diary[place]] : []
    }
    /// The episode numbers a file covers ("S01E01-E02": 1 and 2).
    nonisolated static func numbers(_ first: Int, to last: Int?) -> ClosedRange<Int> {
        guard let last, last > first, last - first < 20 else { return first...first }
        return first...last
    }
}
