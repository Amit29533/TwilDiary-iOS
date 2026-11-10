import SwiftUI
import UIKit
import TwilDiaryCore

/// One episode, opened from a show page or its Episodes page: still, season and number, name,
/// rating, summary, when you watched it, four actions, and previous / next along the season.
struct EpisodeInfoSheet: View {
    let title: MediaTitle
    let season: Int
    let episodes: [Episode]
    let episode: Episode
    let name: String
    let summary: String
    let artwork: String?
    let hidden: Bool
    let tmdbScore: Double?
    let traktScore: Double?
    let watched: Bool
    var forward = true
    let onToggleWatched: () -> Void
    let onNeighbour: (_ forward: Bool) -> Void
    let onNote: () -> Void
    let onClose: () -> Void
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var myRating: Int?
    @State private var ratingError: String?
    @State private var rating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                // Design (board 3): still, 16, label, 4, name, 8, facts, 12, summary, history, actions.
                VStack(alignment: .leading, spacing: 0) {
                    still
                    Text("SEASON \(season) · EPISODE \(episode.number)").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accent)
                        .padding(.top, 16)
                    Text(name).font(.system(size: 26, weight: .bold)).tracking(-0.52).foregroundStyle(HomeStyle.primary)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("episode-sheet-name").padding(.top, 4)
                    facts.padding(.top, 8)
                    summaryText.padding(.top, 12)
                    if let history { historyRow(history).padding(.top, 2) }
                    actions.padding(.top, 6)
                    if let ratingError { Text(ratingError).font(.footnote).foregroundStyle(HomeStyle.secondary).padding(.top, 8) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
                    .id(episode.id)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }.scrollIndicators(.hidden)
                // Swipe left for the next episode, right for the previous one.
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > 60, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                    onNeighbour(dx < 0)
                })
            Rectangle().fill(Color(webHex: "#2a2a33")).frame(height: HomeStyle.hairline)
            pager.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        }.background(HomeStyle.round.ignoresSafeArea())
            .task(id: episode.id) { myRating = EpisodeRatings.all[episode.id]; expanded = false; ratingError = nil }
            .accessibilityAction(named: "Next episode") { onNeighbour(true) }
            .accessibilityAction(named: "Previous episode") { onNeighbour(false) }
            .confirmationDialog("Rate episode \(episode.number)", isPresented: $rating, titleVisibility: .visible) {
                ForEach((1...10).reversed(), id: \.self) { value in Button("\(value)") { rate(value) } }
                if myRating != nil { Button("Remove rating", role: .destructive) { rate(nil) } }
            } message: { Text("Saved to Trakt.") }
    }

    private var header: some View {
        ZStack {
            Text(title.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).padding(.horizontal, 64)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        .frame(width: 44, height: 44).background(Color(webHex: "#26262e"), in: Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Close").accessibilityIdentifier("episode-sheet-close")
                Spacer()
            }
        }.padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 14)
    }

    private var still: some View {
        Color.clear.frame(height: 200).frame(maxWidth: .infinity)
            .overlay {
                if hidden { Color(webHex: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 28).foregroundStyle(HomeStyle.secondary) } }
                else { Artwork(path: artwork, title: String(episode.number)) }
            }
            .background(HomeStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(alignment: .topLeading) {
                if watched {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.ink)
                        .frame(width: 34, height: 34).background(theme.accent, in: Circle()).padding(12)
                        .accessibilityLabel("Watched")
                }
            }
            .overlay(alignment: .topTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).frame(width: 44, height: 44)
                        .background(HomeStyle.card.opacity(0.6), in: Circle())
                }.padding(8).accessibilityLabel("Share episode")
            }
    }

    private var facts: some View {
        // Design: the source's logo and score (14 pt bold), then "· 24 min · 2022" in 14 pt #b4b3c2.
        HStack(spacing: 10) {
            if let traktScore {
                HStack(spacing: 6) { BrandLogo(service: .trakt, size: 22); Text(traktScore.formatted(.number.precision(.fractionLength(1)))) }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(HomeStyle.primary)
            } else if let tmdbScore {
                HStack(spacing: 6) { BrandLogo(service: .tmdb, size: 22); Text(tmdbScore.formatted(.number.precision(.fractionLength(1)))) }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(HomeStyle.primary)
            }
            let rest = [title.runtimeMinutes.map { "\($0) min" }, episode.airedOn.map { String($0.prefix(4)) }].compactMap { $0 }
            ForEach(Array(rest.enumerated()), id: \.offset) { index, part in
                if index > 0 || (traktScore ?? tmdbScore) != nil { Text("·").font(.system(size: 14)).foregroundStyle(Color(webHex: "#5a5a66")) }
                Text(part).font(.system(size: 14)).foregroundStyle(HomeStyle.dateChipText)
            }
            if let myRating {
                Spacer(minLength: 4)
                HStack(spacing: 3) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text("\(myRating)") }
                    .font(.system(size: 14, weight: .semibold)).accessibilityLabel("Your rating \(myRating)")
            }
        }.lineLimit(1)
    }

    @ViewBuilder private var summaryText: some View {
        let text = hidden ? "Watch it or tap Reveal on the show page to read this summary." : summary
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(HomeStyle.dateChipText)
                .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("episode-summary-\(episode.number)")
            if !expanded && text.count > 150 {
                Button("More") { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { expanded = true } }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent).frame(minHeight: 32)
            }
        }
    }

    private struct History { let latest: Date?; let plays: Int }
    private var history: History? {
        let plays = store.titleScope(title.id).activeEvents.filter { $0.episodeId == episode.id }
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
                Text([history.latest.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Date unknown", history.plays.counted("play", "plays")].joined(separator: " · "))
                DiaryIcon(name: "chevron-right", size: 13)
            }.font(.system(size: 14)).foregroundStyle(HomeStyle.dateChipText).frame(maxWidth: .infinity).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityIdentifier("episode-sheet-history")
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 0) {
            action(watched ? "Watched" : "Mark watched", icon: "check", on: watched, enabled: !store.writesBlocked) { onToggleWatched() }
                .accessibilityIdentifier("episode-sheet-watched")
            action(myRating.map { "Rated \($0)" } ?? "Rate", icon: "star", on: myRating != nil, enabled: title.tmdbId != nil && title.isSeries) { rating = true }
            action("Note", icon: "notebook-pen", on: !title.notes.isEmpty) { onNote() }
            Menu {
                Button(watched ? "Mark unwatched" : "Mark watched", systemImage: watched ? "xmark.circle" : "checkmark.circle") { onToggleWatched() }
                    .disabled(store.writesBlocked)
                ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
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
            DiaryIcon(name: icon, size: 22).foregroundStyle(on ? Color(webHex: "#0b0b10") : HomeStyle.primary)
                .frame(width: 64, height: 64).background(on ? theme.accent : Color(webHex: "#26262e"), in: Circle())
                .overlay(Circle().strokeBorder(on ? .clear : Color(webHex: "#2e2e38"), lineWidth: HomeStyle.hairline))
            Text(label).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color(webHex: "#e5dcff") : HomeStyle.soft).lineLimit(1)
        }.contentShape(Rectangle())
    }

    private var pager: some View {
        let index = episodes.firstIndex { $0.id == episode.id } ?? 0
        // Design: 56 pt #26262e circles and pill (#2e2e38 hairline); 6 pt dots, the current one 16 wide.
        return HStack(spacing: 10) {
            Button { onNeighbour(false) } label: { pagerCircle("chevron.left") }
                .buttonStyle(.springPress).disabled(index == 0).opacity(index == 0 ? 0.4 : 1).accessibilityLabel("Previous episode")
            VStack(spacing: 6) {
                Text("Episode \(episode.number) of \(episodes.count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.soft)
                HStack(spacing: 6) {
                    ForEach(dotRange(index: index), id: \.self) { dot in
                        Capsule().fill(dot == index ? theme.accent : Color(webHex: "#4a4a56")).frame(width: dot == index ? 16 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 56).background(Color(webHex: "#26262e"), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(webHex: "#2e2e38"), lineWidth: HomeStyle.hairline))
            Button { onNeighbour(true) } label: { pagerCircle("chevron.right") }
                .buttonStyle(.springPress).disabled(index >= episodes.count - 1).opacity(index >= episodes.count - 1 ? 0.4 : 1).accessibilityLabel("Next episode")
        }
    }
    private func pagerCircle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            .frame(width: 56, height: 56).background(Color(webHex: "#26262e"), in: Circle())
            .overlay(Circle().strokeBorder(Color(webHex: "#2e2e38"), lineWidth: HomeStyle.hairline))
    }
    /// Five dots at most, the current one among them.
    private func dotRange(index: Int) -> [Int] {
        guard episodes.count > 1 else { return [0] }
        let start = min(max(0, index - 2), max(0, episodes.count - 5))
        return Array(start..<min(episodes.count, start + 5))
    }
    private var shareText: String { "\(title.name) · S\(season)E\(episode.number)" + (hidden ? "" : " · " + name) }

    private func rate(_ value: Int?) {
        guard let show = title.tmdbId else { return }
        let target = episode
        ratingError = nil
        Task {
            do {
                try await TraktTitleReads.rateEpisode(store: store, show: show, season: season, episode: target.number, episodeID: target.id, rating: value)
                if target.id == episode.id { myRating = value }
            } catch { if target.id == episode.id { ratingError = error.localizedDescription } }
        }
    }
}
