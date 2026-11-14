import SwiftUI
import TwilDiaryCore

/// Native's "now watching" bar (owner's request, after Apple Music's mini player): the show you're
/// watching floats above the tab bar on the system's glass, its cover, name and next episode, with a
/// + that logs that episode. Tapping the bar opens the title. When the tab bar shrinks on scroll, iOS
/// tucks the bar in beside it, as Apple Music does.
struct NowWatchingBar: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var card: WatchCard?
    @State private var marked = 0

    /// The title watched most recently that's still being watched (else the first one being watched).
    static func current(in store: DiaryStore) -> MediaTitle? {
        let watching = store.activeTitles.filter { $0.status == "watching" }
        guard !watching.isEmpty else { return nil }
        let ids = Set(watching.map(\.id))
        let latest = store.activeEvents.filter { ids.contains($0.titleId) }
            .max { ($0.watchedAt ?? $0.recordedAt) < ($1.watchedAt ?? $1.recordedAt) }
        return latest.flatMap { store.title($0.titleId) } ?? watching.first
    }

    var body: some View {
        if let title = Self.current(in: store) {
            HStack(spacing: 10) {
                Button { router.openTitle(title.id, tab: router.selectedTab) } label: {
                    HStack(spacing: 10) {
                        Artwork(path: title.poster, title: title.name, initialsOnly: false)
                            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(line(for: title)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                .contentTransition(.numericText()).animation(reduceMotion ? nil : .smooth, value: card?.next?.id)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Now watching " + title.name).accessibilityHint("Opens the title")
                    .accessibilityIdentifier("now-watching-bar")
                if title.isSeries {
                    Button { Task { await mark(title) } } label: {
                        Image(systemName: "plus").font(.system(size: 19, weight: .bold)).foregroundStyle(.primary)
                            .symbolEffect(.bounce, value: marked)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(card?.next == nil || store.needsMutationRefresh)
                        .accessibilityLabel(card?.next.map { "Mark episode \($0.number) watched" } ?? "Nothing to mark")
                        .accessibilityIdentifier("now-watching-mark")
                }
            }.padding(.leading, 10).padding(.trailing, 6).frame(maxWidth: .infinity, maxHeight: .infinity)
                .sensoryFeedback(.success, trigger: marked)
                .task(id: (store.cardRevision(title.id)?.uuidString ?? "") + title.id) {
                    card = store.cachedCard(title)
                    if let fresh = try? await store.card(title), !Task.isCancelled { card = fresh }
                }
        } else {
            Color.clear
        }
    }

    private func line(for title: MediaTitle) -> String {
        guard title.isSeries else { return "Movie" + (title.year.map { " · \($0)" } ?? "") }
        guard let card else { return "Watching" }
        if let next = card.next {
            let season = card.season.map { $0.number == 0 ? "Specials · " : "S\($0.number) · " } ?? ""
            return season + "E\(next.number) next"
        }
        return card.progress.total > 0 ? "All \(card.progress.total) watched" : "Watching"
    }

    private func mark(_ title: MediaTitle) async {
        guard let next = card?.next else { return }
        let before = card?.progress.watched
        await store.markNext(title, expectedEpisode: next.id)
        if let fresh = try? await store.card(title) { card = fresh }
        if let before, let after = card?.progress.watched, after > before { marked += 1 }
    }
}
