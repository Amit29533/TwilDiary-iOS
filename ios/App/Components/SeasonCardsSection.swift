import SwiftUI
import TwilDiaryCore

/// "Seasons" on a show's page, above Episodes, as More like this looks (owner's choice): a row of
/// season posters (TMDB's, else the show's), each with a progress bar and a tick (complete) or a
/// play mark (under way) on it, its name and "watched/total" under it; a tap opens the season's
/// episodes. The heading folds the section away, says how much is left to watch, and flips the
/// order (newest first by default; Specials always last).
struct SeasonCardsSection: View {
    let title: MediaTitle
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("title.seasons.open") private var open = true
    @AppStorage("title.seasons.newestFirst") private var newestFirst = true
    /// TMDB's poster for each season (read once per show).
    @State private var posters: [Int: String] = [:]

    private struct Row: Identifiable {
        let number: Int; let name: String; let watched: Int; let total: Int
        var id: Int { number }
        var complete: Bool { total > 0 && watched >= total }
    }

    var body: some View {
        let rows = rows()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header(remaining: remainingMinutes())
                if open {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) { ForEach(rows) { tile($0) } }
                    }.scrollIndicators(.hidden).scrollClipDisabled().accessibilityIdentifier("title-seasons-shelf")
                        .transition(.opacity)
                }
            }.task(id: title.tmdbId) { await loadPosters() }
        }
    }

    private func header(remaining: Int) -> some View {
        HStack(spacing: 12) {
            Button { withAnimation(.snappy(duration: 0.25)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Text("Seasons").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(open ? "Seasons, hide" : "Seasons, show").accessibilityIdentifier("title-seasons-toggle")
            Spacer(minLength: 4)
            if remaining > 0 {
                Text("~" + Self.duration(remaining) + " remaining").font(.system(size: 14)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                    .accessibilityIdentifier("title-seasons-remaining")
            }
            if open {
                Button { withAnimation(.snappy(duration: 0.25)) { newestFirst.toggle() } } label: {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(newestFirst ? "Newest season first" : "Oldest season first").accessibilityIdentifier("title-seasons-order")
            }
        }
    }

    /// More like this's tile: a 111 x 167 poster (radius 18), the name in 14 pt semibold and
    /// "watched/total" under it; the progress bar along the poster's foot, the tick or play mark on top.
    private func tile(_ row: Row) -> some View {
        NavigationLink(value: ShowPageRoute.episodes(titleID: title.id, season: row.number)) {
            VStack(alignment: .leading, spacing: 0) {
                Artwork(path: posters[row.number] ?? title.poster, title: title.name, initialsOnly: false).frame(width: 111, height: 167)
                    .overlay(alignment: .bottom) {
                        if row.watched > 0 {
                            GeometryReader { proxy in
                                Capsule().fill(Color.black.opacity(0.45)).overlay(alignment: .leading) {
                                    Capsule().fill(row.complete ? Self.done : theme.accent)
                                        .frame(width: row.total > 0 ? proxy.size.width * CGFloat(min(row.watched, row.total)) / CGFloat(row.total) : 0)
                                }
                            }.frame(height: 5).padding(.horizontal, 10).padding(.bottom, 10)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topTrailing) {
                        if row.complete { status("checkmark", Self.done).padding(7) }
                        else if row.watched > 0 { status("play.fill", Color(webHex: "#2f7de1")).padding(7) }
                    }
                Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 10)
                Text("\(row.watched)/\(row.total) watched").font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(row.complete ? Self.done : row.watched > 0 ? theme.accent : HomeStyle.secondary).padding(.top, 3)
            }.frame(width: 111, alignment: .leading)
        }.buttonStyle(.springPress)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.name), \(row.watched) of \(row.total) watched" + (row.complete ? ", complete" : ""))
            .accessibilityIdentifier("title-season-\(row.number)")
    }
    private func status(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
    }
    private static let done = Color(webHex: "#3f9a4f")

    /// Each season with what's watched: its episodes in the diary (skipped ones left out), else
    /// the count TMDB expects; Specials last, the rest in the chosen order.
    private func rows() -> [Row] {
        let episodes = store.workspace.episodes.filter { $0.titleId == title.id && $0.skipped != true }
        let watched = store.watchedEpisodeIDs(title.id)
        var numbers = Set(title.seasons.map(\.number))
        numbers.formUnion(episodes.map(\.season))
        let rows = numbers.map { number -> Row in
            let inSeason = episodes.filter { $0.season == number }
            let named = title.seasons.first { $0.number == number }?.name
            let total = inSeason.isEmpty ? (title.seasons.first { $0.number == number }?.expectedEpisodes ?? 0) : inSeason.count
            return Row(number: number, name: number == 0 ? "Specials" : (named.flatMap { $0.isEmpty ? nil : $0 } ?? "Season \(number)"),
                       watched: inSeason.filter { watched.contains($0.id) }.count, total: total)
        }.filter { $0.total > 0 || $0.watched > 0 }
        let regular = rows.filter { $0.number > 0 }.sorted { newestFirst ? $0.number > $1.number : $0.number < $1.number }
        return regular + rows.filter { $0.number == 0 }
    }
    /// Each season's own poster from TMDB's show details, once per show (kept for the session).
    private func loadPosters() async {
        guard let tmdb = title.tmdbId else { return }
        if let known = Self.posterCache[tmdb] { posters = known; return }
        guard let token = TMDBDirect.token(store), let details = try? await TMDBDirect.object("tv/\(tmdb)", query: [:], token: token) else { return }
        var found: [Int: String] = [:]
        for season in details["seasons"] as? [[String: Any]] ?? [] {
            if let number = season["season_number"] as? Int, let path = CatalogTools.image(season["poster_path"] as? String, size: "w342") { found[number] = path }
        }
        if Self.posterCache.count > 200 { Self.posterCache.removeAll() }
        Self.posterCache[tmdb] = found
        posters = found
    }
    @MainActor private static var posterCache: [Int: [Int: String]] = [:]

    /// The unwatched episodes that have aired (Specials aside), at the show's runtime.
    private func remainingMinutes() -> Int {
        let today = DiaryDate.day(store.now)
        let watched = store.watchedEpisodeIDs(title.id)
        let left = store.workspace.episodes.filter {
            $0.titleId == title.id && $0.season > 0 && $0.skipped != true && !watched.contains($0.id) && ($0.airedOn.map { String($0.prefix(10)) <= today } ?? false)
        }.count
        return left * max(1, title.runtimeMinutes ?? (title.category.hasPrefix("anime") ? 24 : 45))
    }
    /// "45m", "5h" (rounded to the hour from an hour on: it's an estimate).
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(Int((Double(minutes) / 60).rounded()))h"
    }
}
