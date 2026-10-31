import SwiftUI
import TwilDiaryCore

enum ProfileDeepLink: Equatable {
    case character(Int), voice(Int), anime(Int), person(Int)
    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if ["anilist.co", "www.anilist.co"].contains(host), parts.count >= 2,
           let id = Int(parts[1]), id > 0 {
            switch parts[0] { case "character": return .character(id); case "staff": return .voice(id); case "anime": return .anime(id); default: return nil }
        }
        if ["themoviedb.org", "www.themoviedb.org"].contains(host), parts.count >= 2, parts[0] == "person",
           let id = Int(parts[1].split(separator: "-").first ?? ""), id > 0 { return .person(id) }
        return nil
    }
}

struct ProfileNativeLinks: ViewModifier {
    let kind: Favourite.Kind
    let ref: Int
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var lookup: Task<Void, Never>?
    @State private var failure: String?
    @State private var resolving = false
    @State private var generation = UUID()
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let target = ProfileDeepLink.parse(url) else { lookup?.cancel(); resolving = false; return .systemAction }
            open(target); return .handled
        }).onDisappear { lookup?.cancel(); resolving = false }
            .overlay(alignment: .bottom) {
                if resolving {
                    HStack(spacing: 8) { ProgressView(); Text("Opening title…").font(.subheadline) }
                        .padding(12).background(.black.opacity(0.9), in: Capsule()).padding(.bottom, 16)
                        .accessibilityIdentifier("profile-opening-link")
                }
            }
            .alert("Unable to open link", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }
    private func open(_ target: ProfileDeepLink) {
        lookup?.cancel(); failure = nil; resolving = false; generation = UUID()
        let tab = router.selectedTab, depth = router.paths[router.selectedTab]?.count ?? 0, session = store.sessionRevision
        switch target {
        case .character(let id): if kind != .character || ref != id { router.paths[tab, default: NavigationPath()].append(CharacterRoute(id: id)) }
        case .voice(let id): if kind != .voice || ref != id { router.paths[tab, default: NavigationPath()].append(VoiceActorRoute(id: id)) }
        case .person(let id): if kind != .cast || ref != id { router.paths[tab, default: NavigationPath()].append(PersonRoute(id: id)) }
        case .anime(let id):
            lookup?.cancel(); failure = nil
            resolving = true
            let request = generation
            lookup = Task {
                defer { if generation == request { resolving = false } }
                do {
                    let appearance = try await media(id)
                    let found = try await store.animeNavigation.title(appearance, service: store)
                    try Task.checkCancellation()
                    guard store.sessionRevision == session, router.selectedTab == tab, (router.paths[tab]?.count ?? 0) == depth else { return }
                    switch found.destination {
                    case .saved(let title)?:
                        guard let saved = store.title(title), saved.deletedAt == nil else { throw APIError.message("This title is no longer available in your library.") }
                        router.openTitle(title, tab: tab)
                    case .catalog(let route)?: router.paths[tab, default: NavigationPath()].append(route)
                    case nil:
                        guard !found.page.library.isEmpty || !found.page.online.isEmpty else { throw APIError.message("No matching title was found.") }
                        router.paths[tab, default: NavigationPath()].append(appearance)
                    }
                } catch is CancellationError { }
                catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
        }
    }
    private func media(_ id: Int) async throws -> AniAppearance {
        #if DEBUG
        if store.isPreview {
            guard let appearance = AniListPreview.detail(2).appearances.first(where: { $0.id == id }) else { throw APIError.message("No fixture for this anime link.") }
            return appearance
        }
        #endif
        return try await AniListClient.shared.media(id)
    }
}

/// Matches public credits conservatively; never treats Planned or a disk copy as a watch.
enum ProfileWatchMatching {
    static func titles(_ appearances: [AniAppearance], workspace: Workspace, confirmed: [Int: CatalogRoute] = [:]) -> [MediaTitle] {
        let watched = Set(workspace.activeEvents.map(\.titleId))
        var seen = Set<String>()
        return appearances.compactMap { item in
            let matches: [MediaTitle]
            if let route = confirmed[item.id] {
                matches = workspace.activeTitles.filter { $0.tmdbId == route.id && $0.isSeries == (route.kind == .tv) }
            } else { matches = AnimeTitleMatching.saved(workspace.activeTitles, names: item.names, year: item.year, kind: item.kind) }
            guard matches.count == 1, let title = matches.first, watched.contains(title.id), seen.insert(title.id).inserted else { return nil }
            return title
        }
    }
}

struct ProfileWatchedShelf: View {
    let appearances: [AniAppearance]
    @Environment(DiaryStore.self) private var store
    @State private var confirmed: [Int: CatalogRoute] = [:]
    var body: some View {
        let titles = ProfileWatchMatching.titles(appearances, workspace: store.workspace, confirmed: confirmed)
        VStack(alignment: .leading, spacing: 12) {
            Text("Watched").font(.system(size: 20, weight: .semibold))
            if titles.isEmpty { Text("No watches from these matched titles yet.").font(.subheadline).foregroundStyle(.secondary) }
            else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(titles) { title in
                            NavigationLink(value: title.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Artwork(path: title.poster, title: title.name).frame(width: 104, height: 156)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .bottomLeading) { if let score = title.communityScore, score > 0 { RatingBadge(score: score).padding(5) } }
                                    Text(title.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                }.frame(width: 104).foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("profile-watched-" + title.id)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.task(id: appearances.map { String($0.id) }.joined(separator: ",") + store.sessionRevision.uuidString) {
            var routes: [Int: CatalogRoute] = [:]
            for item in appearances {
                if let route = await AniListClient.shared.tmdbTitle(item.id) { routes[item.id] = route }
                guard !Task.isCancelled else { return }
            }
            confirmed = routes
        }
    }
}
