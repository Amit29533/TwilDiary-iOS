import SwiftUI
import TwilDiaryCore

/// On a diary title page, when the title is on your Jellyfin: Play (a show's next episode by your
/// diary, a film from where you stopped) straight into JellySpace's player, and a button to its
/// JellySpace page.
struct JellyPlayButton: View {
    let title: MediaTitle
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var target: JellyfinClient.Item?
    @State private var label = "Play"
    /// Why there's nothing to play (the server unreachable, or the title or episode not there): shown
    /// with a retry instead of the spinner, which otherwise turned for ever.
    @State private var problem: String?
    @State private var playing: JellyPlayback?

    /// The title in the Jellyfin list this iPhone keeps (matched by TMDB id and type).
    private var entry: JellyfinEntry? {
        guard let tmdb = title.tmdbId else { return nil }
        return JellyfinShelf.shared.entries.first { $0.tmdb == tmdb && $0.movie == !title.isSeries }
    }

    var body: some View {
        if let entry, JellySpace.client != nil {
            HStack(spacing: 10) {
                Button {
                    if let client = JellySpace.client, let target { playing = JellySpace.playback(target, client: client) }
                    else if problem != nil { Task { await find(entry) } }
                } label: {
                    HStack(spacing: 8) {
                        if target != nil { Image(systemName: "play.fill") }
                        else if problem != nil { Image(systemName: "arrow.clockwise") }
                        else { ProgressView().tint(WatchStyle.ink) }
                        Text(target == nil ? (problem ?? label) : label).lineLimit(1)
                    }
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(WatchStyle.ink)
                    .frame(maxWidth: .infinity).frame(height: 48).background(WatchStyle.fill, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.springPress).disabled(target == nil && problem == nil).accessibilityIdentifier("title-jellyspace-play")
                Button { router.paths[router.selectedTab, default: NavigationPath()].append(JellyDetailRoute(id: entry.id, name: entry.name)) } label: {
                    Image("jellyfin-mark").resizable().scaledToFit().frame(width: 22, height: 22)
                        .frame(width: 48, height: 48).background(Color.primary.opacity(0.09), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.springPress).accessibilityLabel("Open in JellySpace").accessibilityIdentifier("title-jellyspace-open")
            }
            .padding(.top, -8)
            // Again when the diary's progress changes, and after watching.
            .task(id: store.watchedEpisodeIDs(title.id).count) { await find(entry) }
            .fullScreenCover(item: $playing, onDismiss: { Task { await find(entry) } }) { JellyPlayerView(playback: $0) }
        }
    }

    /// What Play plays and what it says: a film (Resume when it was stopped partway), or a show's
    /// next episode by your diary (else Jellyfin's next up, else its first episode).
    private func find(_ entry: JellyfinEntry) async {
        guard let client = JellySpace.client else { return }
        problem = nil
        let user = await JellyfinUser.id(client)
        if entry.movie {
            guard let film = try? await client.item(entry.id) else { problem = "Couldn't load it · Try again"; return }
            target = film
            label = "Play"
            if let user, let place = try? await client.userData(entry.id, user: user), let ticks = place.PlaybackPositionTicks, ticks > 300_000_000,
               let total = film.RunTimeTicks, total > ticks {
                label = "Resume · " + DiaryDate.duration(max(1, Int((total - ticks) / 600_000_000))) + " left"
            }
            return
        }
        guard let episodes = try? await client.allEpisodes(of: entry.id, user: user) else { problem = "Couldn't load it · Try again"; return }
        let numbered = episodes.filter { ($0.ParentIndexNumber ?? 0) > 0 }
            .sorted { (($0.ParentIndexNumber ?? 0), ($0.IndexNumber ?? 0)) < (($1.ParentIndexNumber ?? 0), ($1.IndexNumber ?? 0)) }
        var pick: JellyfinClient.Item?
        // The diary's next unwatched episode, by season and number, else by its place in the show.
        let watched = store.watchedEpisodeIDs(title.id)
        let diary = store.titleEpisodes(title.id).filter { $0.season > 0 }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        if let next = diary.firstIndex(where: { !watched.contains($0.id) }) {
            let wanted = diary[next]
            // By season and number; by place only when both count the show alike (Jellyfin splitting an
            // anime's seasons differently). With an episode missing on one side the place points at
            // another episode, so then Jellyfin's own next up (below) instead.
            pick = numbered.first { $0.ParentIndexNumber == wanted.season && $0.IndexNumber == wanted.number }
                ?? (numbered.count == diary.count && numbered.indices.contains(next) ? numbered[next] : nil)
        }
        if pick == nil, let user { pick = try? await client.nextUp(series: entry.id, user: user) }
        if pick == nil { pick = numbered.first }
        guard let episode = pick else { problem = "No episodes on Jellyfin · Try again"; return }
        target = episode
        let place = [episode.ParentIndexNumber.map { "S\($0)" }, episode.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
        label = ((episode.UserData?.PlayedPercentage ?? 0) > 0 ? "Resume " : "Play ") + place
    }
}
