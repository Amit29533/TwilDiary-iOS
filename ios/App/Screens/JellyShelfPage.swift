import SwiftUI
import TwilDiaryCore

/// A home row's whole list on its own page (its round ›): Continue Watching, Because you watched,
/// a Dynamic recommendations row, Hidden gems. The titles in the row's order.
struct JellyShelfRoute: Hashable {
    let title: String
    let ids: [String]
}

struct JellyShelfPage: View {
    let route: JellyShelfRoute
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @State private var items: [JellyfinClient.Item] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var playing: JellyPlayback?

    var body: some View {
        EdgeToEdgeScroll(frosted: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let client = JellySpace.client {
                    if let failure { RetryNotice(message: failure) { Task { await load() } } }
                    else if loading && items.isEmpty { DiaryLoadingPlaceholder(label: "Loading", layout: .posterGrid(columns: 3, rows: 3)) }
                    else if items.isEmpty { Text("Nothing here.").font(.subheadline).foregroundStyle(.secondary) }
                    else {
                        Text(items.count == 1 ? "1 title" : "\(items.count) titles").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                            .padding(.horizontal, 4)
                    }
                    JellyGrid(items: items, client: client, playing: $playing)
                }
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 110)
        }
        .diaryScreenBackground()
        .jellyFaceLock()
        .navigationTitle(route.title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { JellyMiniPlayer().padding(.bottom, 4) }
        .task(id: hiddenRaw) { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { JellyPlayerView(playback: $0) }
    }

    /// The titles as the server has them now (watched marks and progress up to date), a few dozen at a
    /// time, put back in the row's order; without what you hid.
    private func load() async {
        guard let client = JellySpace.client else { return }
        let user = await JellyfinUser.id(client)
        let chunks = stride(from: 0, to: route.ids.count, by: 60).map { Array(route.ids[$0..<min($0 + 60, route.ids.count)]) }
        var found: [JellyfinClient.Item] = []
        var failed = false
        await withTaskGroup(of: [JellyfinClient.Item]?.self) { group in
            for chunk in chunks { group.addTask { try? await client.items(ids: chunk, user: user) } }
            for await part in group {
                if let part { found += part } else { failed = true }
            }
        }
        guard !Task.isCancelled else { return }
        loading = false
        if failed && found.isEmpty {
            failure = "Couldn't load these titles."
            return
        }
        failure = nil
        let order = Dictionary(route.ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let hidden = JellyHidden.decode(hiddenRaw)
        items = found.filter { hidden[$0.Id] == nil && ($0.SeriesId.map { hidden[$0] == nil } ?? true) }
            .sorted { (order[$0.Id] ?? .max) < (order[$1.Id] ?? .max) }
    }
}
