import SwiftUI
import TwilDiaryCore

/// "Seasons", above Episodes, on a show's page and on a show's preview page, drawn as More like
/// this is (a row of 111 x 167 posters, the name and a line under each) with a heading like
/// Episodes' (the count in a chip, then pills). Each season's poster is TMDB's, else the show's.
///
/// In your diary a tile shows what's watched (a progress bar along the poster's foot, a tick when
/// complete, a play mark under way) and opens the season's episodes; the heading says how much is
/// left. On a preview (a show not in your diary) a tile shows the episode count and picks that
/// season for the Episodes section below. The order flips (newest first by default; Specials last).
struct SeasonCardsSection: View {
    enum Source {
        /// A show in your diary.
        case diary(MediaTitle)
        /// A show's preview page: its seasons, and the season Episodes shows.
        case preview(CatalogDetails, selected: Binding<Int>)
    }
    let source: Source
    init(title: MediaTitle) { source = .diary(title) }
    init(preview details: CatalogDetails, selected: Binding<Int>) { source = .preview(details, selected: selected) }

    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("title.seasons.newestFirst") private var newestFirst = true
    /// TMDB's poster for each season (read once per show).
    @State private var posters: [Int: String] = [:]

    private struct Row: Identifiable {
        let number: Int; let name: String
        /// nil on a preview (nothing watched there).
        let watched: Int?
        let total: Int
        var id: Int { number }
        var complete: Bool { total > 0 && (watched ?? 0) >= total }
    }

    var body: some View {
        let rows = rows()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header(count: rows.count, remaining: remainingMinutes())
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) { ForEach(rows) { tile($0) } }
                }.scrollIndicators(.hidden).scrollClipDisabled().accessibilityIdentifier("title-seasons-shelf")
            }.task(id: tmdbID) { await loadPosters() }
        }
    }

    // MARK: Heading (as Episodes')

    private func header(count: Int, remaining: Int) -> some View {
        HStack(spacing: 10) {
            Text("Seasons").font(.system(size: 22, weight: .bold)).tracking(-0.22).foregroundStyle(HomeStyle.primary)
            chip(count.formatted())
            if remaining > 0 { chip("~" + Self.duration(remaining) + " left").accessibilityIdentifier("title-seasons-remaining") }
            Spacer(minLength: 0)
            if count > 1 {
                Button { withAnimation(.snappy(duration: 0.25)) { newestFirst.toggle() } } label: {
                    HStack(spacing: 8) {
                        Text(newestFirst ? "Newest" : "Oldest").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                    }.padding(.horizontal, 18).frame(height: 44)
                        .background(HomeStyle.round, in: Capsule()).overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityLabel(newestFirst ? "Newest season first" : "Oldest season first").accessibilityIdentifier("title-seasons-order")
            }
        }
    }
    /// The Episodes heading's count chip.
    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.soft).lineLimit(1)
            .padding(.horizontal, 10).frame(height: 28).background(HomeStyle.round, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeStyle.dateChipBorder, lineWidth: HomeStyle.hairline))
    }

    // MARK: Tiles (as More like this)

    @ViewBuilder private func tile(_ row: Row) -> some View {
        switch source {
        case .diary(let title):
            NavigationLink(value: ShowPageRoute.episodes(titleID: title.id, season: row.number)) { tileBody(row, chosen: false) }
                .buttonStyle(.springPress).accessibilityIdentifier("title-season-\(row.number)")
        case .preview(_, let selected):
            Button { withAnimation(.snappy(duration: 0.25)) { selected.wrappedValue = row.number } } label: { tileBody(row, chosen: selected.wrappedValue == row.number) }
                .buttonStyle(.springPress).accessibilityAddTraits(selected.wrappedValue == row.number ? .isSelected : [])
                .accessibilityIdentifier("catalog-season-\(row.number)")
        }
    }
    /// More like this's tile: a 111 x 167 poster (radius 18), the name in 14 pt semibold and a
    /// line in 12 pt under it. In the diary, the progress bar and the tick or play mark are on the
    /// poster; on a preview, the season Episodes shows is outlined.
    private func tileBody(_ row: Row, chosen: Bool) -> some View {
        let watched = row.watched ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Artwork(path: posters[row.number] ?? showPoster, title: showName, initialsOnly: false).frame(width: 111, height: 167)
                .overlay(alignment: .bottom) {
                    if watched > 0 {
                        GeometryReader { proxy in
                            Capsule().fill(Color.black.opacity(0.45)).overlay(alignment: .leading) {
                                Capsule().fill(row.complete ? Self.done : theme.accent)
                                    .frame(width: row.total > 0 ? proxy.size.width * CGFloat(min(watched, row.total)) / CGFloat(row.total) : 0)
                            }
                        }.frame(height: 5).padding(.horizontal, 10).padding(.bottom, 10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay { if chosen { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.accent, lineWidth: 2) } }
                .overlay(alignment: .topTrailing) {
                    if row.complete { status("checkmark", Self.done).padding(7) }
                    else if watched > 0 { status("play.fill", Color(webHex: "#2f7de1")).padding(7) }
                }
            Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 10)
            Text(line(row)).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(row.complete ? Self.done : watched > 0 ? theme.accent : HomeStyle.secondary).padding(.top, 3)
        }.frame(width: 111, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.name + ", " + line(row) + (row.complete ? ", complete" : ""))
    }
    private func line(_ row: Row) -> String {
        guard let watched = row.watched else { return row.total == 1 ? "1 episode" : "\(row.total) episodes" }
        return "\(watched)/\(row.total) watched"
    }
    private func status(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
    }
    private static let done = Color(webHex: "#3f9a4f")

    // MARK: Data

    private var tmdbID: Int? {
        switch source { case .diary(let title): title.tmdbId; case .preview(let details, _): details.id }
    }
    private var showName: String {
        switch source { case .diary(let title): title.name; case .preview(let details, _): details.name }
    }
    private var showPoster: String? {
        switch source { case .diary(let title): title.poster; case .preview(let details, _): CatalogTools.image(details.posterPath, size: "w342") }
    }
    /// Each season, with what's watched in the diary (its episodes there, skipped ones left out,
    /// else the count TMDB expects); Specials last, the rest in the chosen order.
    private func rows() -> [Row] {
        var rows: [Row] = []
        switch source {
        case .diary(let title):
            let episodes = store.workspace.episodes.filter { $0.titleId == title.id && $0.skipped != true }
            let watched = store.watchedEpisodeIDs(title.id)
            var numbers = Set(title.seasons.map(\.number))
            numbers.formUnion(episodes.map(\.season))
            rows = numbers.map { number in
                let inSeason = episodes.filter { $0.season == number }
                let season = title.seasons.first { $0.number == number }
                let total = inSeason.isEmpty ? (season?.expectedEpisodes ?? 0) : inSeason.count
                return Row(number: number, name: Self.name(number, season?.name), watched: inSeason.filter { watched.contains($0.id) }.count, total: total)
            }.filter { $0.total > 0 || ($0.watched ?? 0) > 0 }
        case .preview(let details, _):
            rows = (details.seasons ?? []).map { Row(number: $0.number, name: Self.name($0.number, $0.name), watched: nil, total: $0.expectedEpisodes ?? 0) }
        }
        let regular = rows.filter { $0.number > 0 }.sorted { newestFirst ? $0.number > $1.number : $0.number < $1.number }
        return regular + rows.filter { $0.number == 0 }
    }
    private static func name(_ number: Int, _ given: String?) -> String {
        number == 0 ? "Specials" : (given.flatMap { $0.isEmpty ? nil : $0 } ?? "Season \(number)")
    }
    /// Each season's own poster from TMDB's show details, once per show (kept for the session).
    private func loadPosters() async {
        guard let tmdb = tmdbID else { return }
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

    /// In the diary: the unwatched episodes that have aired (Specials aside), at the show's runtime.
    private func remainingMinutes() -> Int {
        guard case .diary(let title) = source else { return 0 }
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
