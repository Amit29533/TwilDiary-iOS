import SwiftUI
import UIKit
import TwilDiaryCore

/// One episode, opened from a show page or its Episodes page: still, season and number, name,
/// rating, summary, when you watched it, four actions, and previous / next along the season.
/// The season's episodes are pages side by side: swipe (or tap ‹ ›) and the next one slides in
/// beside the current one while the header and the pager stay put.
struct EpisodeInfoSheet: View {
    /// What one page shows for an episode (the parent knows names, art, spoilers and plays).
    struct Page {
        var name: String
        var summary: String
        var artwork: String?
        var hidden: Bool
        var runtime: Int? = nil
        var tmdbScore: Double?
        var traktScore: Double?
        var watched: Bool
    }
    let title: MediaTitle
    let season: Int
    let episodes: [Episode]
    /// The episode on screen; the parent updates it as you page.
    let episode: Episode
    let page: (Episode) -> Page
    let onToggleWatched: (Episode) -> Void
    let onNeighbour: (_ forward: Bool) -> Void
    let onNote: () -> Void
    let onClose: () -> Void
    /// False on a preview page (the title isn't in your diary): no Mark watched, Rate, Note or history.
    var inDiary = true
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page on screen. Set before the first frame, so the sheet opens on the tapped episode
    /// instead of drawing the first one and jumping.
    @State private var position: String?
    @State private var expanded = Set<String>()
    @State private var myRatings: [String: Int?] = [:]
    /// Ratings saved on this iPhone, read once (not from UserDefaults on every draw of every page).
    @State private var savedRatings: [String: Int]

    init(title: MediaTitle, season: Int, episodes: [Episode], episode: Episode, page: @escaping (Episode) -> Page,
         onToggleWatched: @escaping (Episode) -> Void, onNeighbour: @escaping (_ forward: Bool) -> Void,
         onNote: @escaping () -> Void, onClose: @escaping () -> Void, inDiary: Bool = true) {
        self.title = title; self.season = season; self.episodes = episodes; self.episode = episode; self.page = page
        self.onToggleWatched = onToggleWatched; self.onNeighbour = onNeighbour; self.onNote = onNote; self.onClose = onClose
        self.inDiary = inDiary
        _position = State(initialValue: episode.id)
        _savedRatings = State(initialValue: EpisodeRatings.all)
    }
    @State private var ratingError: String?
    @State private var rating = false
    /// The episode whose watch dates are open (to change one).
    @State private var dating: Episode?
    /// TheTVDB's synopsis by episode, where it says something TMDB's doesn't.
    @State private var tvdbSummaries: [String: String] = [:]
    /// The source picked per episode (TMDB's unless changed).
    @State private var summarySource: [String: SynopsisSource] = [:]
    /// What the pages show when TMDB has no synopsis.
    static let noSummary = "No episode summary available."

    private var myRating: Int? { myRating(episode) }
    private func myRating(_ item: Episode) -> Int? { myRatings[item.id] ?? savedRatings[item.id] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(episodes, id: \.id) { item in
                        ScrollView { pageView(item, page(item)) }.scrollIndicators(.hidden)
                            .containerRelativeFrame(.horizontal)
                            .id(item.id)
                    }
                }.scrollTargetLayout()
            }.scrollIndicators(.hidden).scrollTargetBehavior(.paging)
                .scrollPosition(id: $position)
                // A swipe counts once it has come to rest on a page.
                .onScrollPhaseChange { _, phase in if phase == .idle { settle() } }
            Rectangle().fill(Color(themed: "#2a2a33")).frame(height: HomeStyle.hairline)
            pager.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
                // Anchored at the bottom, by the actions, so the choices open there rather than at the top.
                .confirmationDialog("Rate episode \(episode.number)", isPresented: $rating, titleVisibility: .visible) {
                    ForEach((1...10).reversed(), id: \.self) { value in Button("\(value)") { rate(value) } }
                    if myRating != nil { Button("Remove rating", role: .destructive) { rate(nil) } }
                } message: { Text("Saved to Trakt.") }
        }.background(HomeStyle.round.ignoresSafeArea())
            .onChange(of: episode.id) { _, id in if position != id { position = id } }
            .task(id: episode.id) { ratingError = nil; await loadTVDBSummary(episode) }
            .sheet(item: $dating) { item in WatchDatesSheet(titleID: title.id, episodeID: item.id, heading: "Episode \(item.number)") }
            .accessibilityAction(named: "Next episode") { go(true) }
            .accessibilityAction(named: "Previous episode") { go(false) }
    }

    private func pageView(_ item: Episode, _ p: Page) -> some View {
        // Design (board 3): still, 16, label, 4, name, 8, facts, 12, summary, history, actions.
        VStack(alignment: .leading, spacing: 0) {
            still(item, p)
            Text("SEASON \(season) · EPISODE \(item.number)").font(.app(size: 12, weight: .bold)).foregroundStyle(theme.accent)
                .padding(.top, 16)
            Text(p.name).font(.app(size: 26, weight: .bold)).tracking(-0.52).foregroundStyle(HomeStyle.primary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("episode-sheet-name").padding(.top, 4)
            facts(item, p).padding(.top, 8)
            summaryText(item, p).padding(.top, 12)
            if inDiary, let history = history(item) { historyRow(history).padding(.top, 2) }
            if inDiary { actions(item, p).padding(.top, 6) }
            if item.id == episode.id, let ratingError { Text(ratingError).font(.footnote).foregroundStyle(HomeStyle.secondary).padding(.top, 8) }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
    private func index(_ id: String?) -> Int? { episodes.firstIndex { $0.id == id } }
    /// ‹ › and the accessibility actions: slide to the neighbour and tell the parent at once.
    private func go(_ forward: Bool) {
        guard let from = index(episode.id), episodes.indices.contains(from + (forward ? 1 : -1)) else { return }
        let target = episodes[from + (forward ? 1 : -1)].id
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.38)) { position = target }
        onNeighbour(forward)
    }
    /// After a swipe comes to rest: the page it rests on becomes the current episode.
    private func settle() {
        guard let to = index(position), let from = index(episode.id), to != from else { return }
        onNeighbour(to > from)
    }

    private var header: some View {
        ZStack {
            Text(title.name).font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.horizontal, 64)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Close").accessibilityIdentifier("episode-sheet-close")
                Spacer()
            }
        }.padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 14)
    }

    private func still(_ item: Episode, _ p: Page) -> some View {
        Color.clear.frame(height: 200).frame(maxWidth: .infinity)
            .overlay {
                if p.hidden { Color(themed: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 28).foregroundStyle(HomeStyle.secondary) } }
                else { Artwork(path: p.artwork, title: String(item.number)) }
            }
            .background(HomeStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .topLeading) {
                if p.watched {
                    Image(systemName: "checkmark").font(.app(size: 15, weight: .bold)).foregroundStyle(theme.ink)
                        .frame(width: 34, height: 34).background(theme.accent, in: Circle()).padding(12)
                        .accessibilityLabel("Watched")
                }
            }
            .overlay(alignment: .topTrailing) {
                ShareLink(item: shareText(item, p)) {
                    Image(systemName: "square.and.arrow.up").font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                }.padding(8).accessibilityLabel("Share episode")
            }
    }

    private func facts(_ item: Episode, _ p: Page) -> some View {
        // Design: the source's logo and score (14 pt bold), then "· 24 min · 2022" in 14 pt #b4b3c2.
        let traktScore = p.traktScore, tmdbScore = p.tmdbScore, myRating = myRating(item)
        return HStack(spacing: 10) {
            if let traktScore {
                HStack(spacing: 6) { BrandLogo(service: .trakt, size: 22); Text(traktScore.formatted(.number.precision(.fractionLength(1)))) }
                    .font(.app(size: 14, weight: .bold)).foregroundStyle(HomeStyle.primary)
            } else if let tmdbScore {
                HStack(spacing: 6) { BrandLogo(service: .tmdb, size: 22); Text(tmdbScore.formatted(.number.precision(.fractionLength(1)))) }
                    .font(.app(size: 14, weight: .bold)).foregroundStyle(HomeStyle.primary)
            }
            let rest = [(p.runtime ?? item.runtimeMinutes).map { "\($0) min" }, item.airedOn.map { String($0.prefix(4)) }].compactMap { $0 }
            ForEach(Array(rest.enumerated()), id: \.offset) { index, part in
                if index > 0 || (traktScore ?? tmdbScore) != nil { Text("·").font(.app(size: 14)).foregroundStyle(Color(themed: "#5a5a66")) }
                Text(part).font(.app(size: 14)).foregroundStyle(HomeStyle.dateChipText)
            }
            if let myRating {
                Spacer(minLength: 4)
                HStack(spacing: 3) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text("\(myRating)") }
                    .font(.app(size: 14, weight: .semibold)).accessibilityLabel("Your rating \(myRating)")
            }
        }.lineLimit(1)
    }

    @ViewBuilder private func summaryText(_ item: Episode, _ p: Page) -> some View {
        // TMDB's synopsis, and TheTVDB's where it differs (it stands in when TMDB has none).
        let tmdb = p.summary == Self.noSummary ? "" : p.summary
        let tvdb = tvdbSummaries[item.id]
        let sources: [SynopsisSource] = (tmdb.isEmpty ? [] : [.tmdb]) + (tvdb == nil ? [] : [.tvdb])
        let shown = summarySource[item.id].flatMap { sources.contains($0) ? $0 : nil } ?? sources.first ?? .tmdb
        let synopsis = shown == .tvdb ? (tvdb ?? p.summary) : p.summary
        let text = p.hidden ? "Watch it or tap Reveal on the show page to read this summary." : synopsis
        let expanded = expanded.contains(item.id)
        let choice = !p.hidden && sources.count > 1
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.app(size: 16)).lineSpacing(3).foregroundStyle(HomeStyle.soft)
                .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                .id(shown).transition(.opacity)
                .accessibilityIdentifier("episode-summary-\(item.number)")
            if !expanded && (text.count > 150 || choice) {
                Button("More") { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { _ = self.expanded.insert(item.id) } }
                    .font(.app(size: 16, weight: .semibold)).foregroundStyle(theme.accent).frame(minHeight: 32)
            } else if expanded && choice {
                HStack {
                    Spacer(minLength: 0)
                    SynopsisSwitcher(sources: sources, shown: shown) { source in
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { summarySource[item.id] = source }
                    }
                }.padding(.top, 6)
            }
        }
    }
    /// TheTVDB's synopsis of the episode on screen (asked once, kept on the phone), unless it's
    /// hidden as a spoiler or says the same as TMDB's.
    private func loadTVDBSummary(_ item: Episode) async {
        guard let tmdb = title.tmdbId, title.isSeries, tvdbSummaries[item.id] == nil, !store.isPreview else { return }
        let p = page(item)
        guard !p.hidden else { return }
        guard let text = await Synopses.tvdbEpisode(tmdb: tmdb, season: season, number: item.number, store: store), !Task.isCancelled else { return }
        // Also when it says the same as TMDB's (TMDB took many from TheTVDB): the choice is there.
        tvdbSummaries[item.id] = text
    }

    private struct History { let latest: Date?; let plays: Int }
    private func history(_ item: Episode) -> History? {
        let plays = store.titleScope(title.id).activeEvents.filter { $0.episodeId == item.id }
        guard !plays.isEmpty else { return nil }
        let latest = plays.compactMap { DiaryDate.parse($0.watchedAt ?? $0.recordedAt) }.max()
        return History(latest: latest, plays: plays.count)
    }
    private func historyRow(_ history: History) -> some View {
        Button {
            onClose()
            router.paths[router.selectedTab, default: NavigationPath()].append(HistoryRoute(query: title.name))
        } label: {
            HStack(spacing: 8) {
                DiaryIcon(name: "history", size: 17)
                Text([history.latest.map { $0.diaryTime(date: .abbreviated) } ?? "Date unknown", history.plays.counted("play", "plays")].joined(separator: " · "))
                DiaryIcon(name: "chevron-right", size: 13)
            }.font(.app(size: 14)).foregroundStyle(HomeStyle.dateChipText).frame(maxWidth: .infinity).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityIdentifier("episode-sheet-history")
    }

    private func actions(_ item: Episode, _ p: Page) -> some View {
        let watched = p.watched, myRating = myRating(item)
        return HStack(alignment: .top, spacing: 0) {
            action(watched ? "Watched" : "Mark watched", icon: "check", on: watched, enabled: !store.writesBlocked) { onToggleWatched(item) }
                .accessibilityIdentifier("episode-sheet-watched")
            action(myRating.map { "Rated \($0)" } ?? "Rate", icon: "star", on: myRating != nil, enabled: title.tmdbId != nil && title.isSeries) { rating = true }
            action("Note", icon: "notebook-pen", on: !title.notes.isEmpty) { onNote() }
            Menu {
                Button(watched ? "Mark unwatched" : "Mark watched", systemImage: watched ? "xmark.circle" : "checkmark.circle") { onToggleWatched(item) }
                    .disabled(store.writesBlocked)
                if watched, store.canChangeWatchDates {
                    Button("Watch date…", systemImage: "calendar") { dating = item }.disabled(store.writesBlocked)
                }
                ShareLink(item: shareText(item, p)) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Watch history", systemImage: "clock.arrow.circlepath") {
                    onClose()
                    router.paths[router.selectedTab, default: NavigationPath()].append(HistoryRoute(query: title.name))
                }
            } label: { actionLabel("More", icon: "chevron-down", on: false) }
                .frame(maxWidth: .infinity).accessibilityLabel("More episode actions")
        }.padding(.top, 6)
    }
    private func action(_ label: String, icon: String, on: Bool, enabled: Bool = true, run: @escaping () -> Void) -> some View {
        Button(action: run) { actionLabel(label, icon: icon, on: on) }.buttonStyle(.springPress).disabled(!enabled)
            .opacity(enabled ? 1 : 0.45).frame(maxWidth: .infinity)
    }
    private func actionLabel(_ label: String, icon: String, on: Bool) -> some View {
        // Design: 64 pt circles; on = accent with #e5dcff label, off = #26262e with a #2e2e38 hairline.
        VStack(spacing: 8) {
            DiaryIcon(name: icon, size: 22).foregroundStyle(on ? ThemeStore.current.accentInk : HomeStyle.primary)
                .frame(width: 64, height: 64)
                // Liquid Glass, as the Sentiments sheet's buttons (owner); a chosen one is the accent glass.
                .glassEffect(on ? .regular.tint(theme.accent).interactive() : .regular.interactive(), in: Circle())
            Text(label).font(.app(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color(themed: "#e5dcff") : HomeStyle.soft).lineLimit(1)
        }.contentShape(Rectangle())
    }

    private var pager: some View {
        let index = episodes.firstIndex { $0.id == episode.id } ?? 0
        // Design: 56 pt #26262e circles and pill (#2e2e38 hairline); 6 pt dots, the current one 16 wide.
        return HStack(spacing: 10) {
            Button { go(false) } label: { pagerCircle("chevron.left") }
                .buttonStyle(.springPress).disabled(index == 0).opacity(index == 0 ? 0.4 : 1).accessibilityLabel("Previous episode")
            VStack(spacing: 6) {
                Text("Episode \(episode.number) of \(episodes.count)").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                HStack(spacing: 6) {
                    ForEach(dotRange(index: index), id: \.self) { dot in
                        Capsule().fill(dot == index ? theme.accent : Color(themed: "#4a4a56")).frame(width: dot == index ? 16 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 56).glassEffect(.regular, in: Capsule())
            Button { go(true) } label: { pagerCircle("chevron.right") }
                .buttonStyle(.springPress).disabled(index >= episodes.count - 1).opacity(index >= episodes.count - 1 ? 0.4 : 1).accessibilityLabel("Next episode")
        }
    }
    private func pagerCircle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            .frame(width: 56, height: 56).glassEffect(.regular.interactive(), in: Circle())
    }
    /// Five dots at most, the current one among them.
    private func dotRange(index: Int) -> [Int] {
        guard episodes.count > 1 else { return [0] }
        let start = min(max(0, index - 2), max(0, episodes.count - 5))
        return Array(start..<min(episodes.count, start + 5))
    }
    private func shareText(_ item: Episode, _ p: Page) -> String { "\(title.name) · S\(season)E\(item.number)" + (p.hidden ? "" : " · " + p.name) }

    private func rate(_ value: Int?) {
        guard let show = title.tmdbId else { return }
        let target = episode
        ratingError = nil
        Task {
            do {
                try await TraktTitleReads.rateEpisode(store: store, show: show, season: season, episode: target.number, episodeID: target.id, rating: value)
                myRatings[target.id] = .some(value)
            } catch { if target.id == episode.id { ratingError = FriendlyError.message(error) } }
        }
    }
}
