import SwiftUI
import TwilDiaryCore

/// Keep the character/voice actor page visible during lookup instead of pushing
/// a temporary search screen before the actual title is known.
struct AnimeAppearanceButton<Label: View>: View {
    let appearance: AniAppearance
    let label: Label
    init(appearance: AniAppearance, @ViewBuilder label: () -> Label) {
        self.appearance = appearance; self.label = label()
    }
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var loading = false
    @State private var failure: String?
    @State private var lookup: Task<Void, Never>?
    var body: some View {
        Button(action: open) {
            label.overlay(alignment: .topTrailing) {
                if loading { ProgressView().controlSize(.small).padding(6).background(.black.opacity(0.7), in: Circle()) }
            }
        }.disabled(loading)
            .onDisappear { lookup?.cancel() }
            .alert("Unable to open title", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("Retry", action: open)
                Button("Cancel", role: .cancel) {}
            } message: { Text(failure ?? "") }
    }
    private func open() {
        let tab = router.selectedTab, depth = router.paths[router.selectedTab]?.count ?? 0
        failure = nil; loading = true
        lookup?.cancel()
        lookup = Task {
            defer { loading = false }
            do {
                let found = try await store.animeNavigation.title(appearance, service: store)
                if case .saved(let id)? = found.destination, store.title(id) == nil { await store.refresh() }
                try Task.checkCancellation()
                guard router.selectedTab == tab, (router.paths[tab]?.count ?? 0) == depth else { return }
                switch found.destination {
                case .saved(let id)?:
                    guard let title = store.title(id), title.deletedAt == nil else { throw APIError.message("This title is no longer available in your library.") }
                    router.openTitle(id, tab: tab)
                case .catalog(let route)?: router.paths[tab, default: NavigationPath()].append(route)
                case nil:
                    guard !found.page.library.isEmpty || !found.page.online.isEmpty else {
                        throw APIError.message("No matching TMDB title was found. Please try again later.")
                    }
                    router.paths[tab, default: NavigationPath()].append(appearance)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
