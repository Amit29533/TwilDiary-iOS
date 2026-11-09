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
                VStack(alignment: .leading, spacing: 14) {
                    still
                    Text("SEASON \(season) · EPISODE \(episode.number)").font(.system(size: 12, weight: .bold)).tracking(1.2).foregroundStyle(theme.accent)
                        .padding(.top, 4)
                    Text(name).font(.system(size: 26, weight: .bold)).tracking(-0.6).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("episode-sheet-name")
                    facts
                    summaryText
                    if let history { historyRow(history) }
                    actions
                    if let ratingError { Text(ratingError).font(.footnote).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.bottom, 16)
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
            Divider().overlay(.white.opacity(0.08))
            pager.padding(.horizontal, 16).padding(.vertical, 12)
        }.background(Color(webHex: "#111116").ignoresSafeArea())
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
            Text(title.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).padding(.horizontal, 64)
            HStack {
                Button(action: onClose) { RoundTool(icon: "x", tint: .white) }.buttonStyle(.plain)
                    .accessibilityLabel("Close").accessibilityIdentifier("episode-sheet-close")
                Spacer()
            }
        }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
    }

    private var still: some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if hidden { Color(webHex: "#211d2d").overlay { DiaryIcon(name: "eye-off", size: 28).foregroundStyle(.secondary) } }
                else { Artwork(path: artwork, title: String(episode.number)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .topLeading) {
                if watched {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.ink)
                        .frame(width: 34, height: 34).background(theme.accent, in: Circle()).padding(12)
                        .accessibilityLabel("Watched")
                }
            }
            .overlay(alignment: .topTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                }.padding(10).accessibilityLabel("Share episode")
            }
    }

    private var facts: some View {
        HStack(spacing: 8) {
            if let traktScore {
                Text("TRAKT").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 22).background(Color(webHex: "#ed1c24"), in: RoundedRectangle(cornerRadius: 6))
                Text(traktScore.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 15, weight: .bold))
            } else if let tmdbScore {
                Text("TMDB").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(webHex: "#0d253f"))
                    .padding(.horizontal, 7).frame(height: 22).background(Color(webHex: "#90cea1"), in: RoundedRectangle(cornerRadius: 6))
                Text(tmdbScore.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 15, weight: .bold))
            }
            let rest = [title.runtimeMinutes.map { "\($0) min" }, episode.airedOn.map { String($0.prefix(4)) }].compactMap { $0 }
            if !rest.isEmpty {
                Text(((traktScore ?? tmdbScore) == nil ? "" : "· ") + rest.joined(separator: " · ")).font(.system(size: 15)).foregroundStyle(.secondary)
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
            Text(text).font(.system(size: 15.5)).lineSpacing(4).foregroundStyle(Color(webHex: "#c5c0cf"))
                .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("episode-summary-\(episode.number)")
            if !expanded && text.count > 150 {
                Button("More") { withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { expanded = true } }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).frame(minHeight: 32)
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
            }.font(.system(size: 14)).foregroundStyle(Color(webHex: "#c5c0cf")).frame(maxWidth: .infinity).frame(minHeight: 40)
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
        VStack(spacing: 8) {
            DiaryIcon(name: icon, size: 22).foregroundStyle(on ? theme.ink : .white)
                .frame(width: 64, height: 64).background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.white.opacity(0.09)), in: Circle())
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? theme.accent : Color(webHex: "#c5c0cf")).lineLimit(1)
        }.contentShape(Rectangle())
    }

    private var pager: some View {
        let index = episodes.firstIndex { $0.id == episode.id } ?? 0
        return HStack(spacing: 12) {
            Button { onNeighbour(false) } label: { RoundTool(icon: "chevron-left", tint: .white, size: 48) }
                .buttonStyle(.springPress).disabled(index == 0).opacity(index == 0 ? 0.4 : 1).accessibilityLabel("Previous episode")
            VStack(spacing: 6) {
                Text("Episode \(episode.number) of \(episodes.count)").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    ForEach(dotRange(index: index), id: \.self) { dot in
                        Capsule().fill(dot == index ? theme.accent : .white.opacity(0.25)).frame(width: dot == index ? 18 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 56).background(.white.opacity(0.07), in: Capsule())
            Button { onNeighbour(true) } label: { RoundTool(icon: "chevron-right", tint: .white, size: 48) }
                .buttonStyle(.springPress).disabled(index >= episodes.count - 1).opacity(index >= episodes.count - 1 ? 0.4 : 1).accessibilityLabel("Next episode")
        }
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
