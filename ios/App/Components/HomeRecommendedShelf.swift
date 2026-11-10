import SwiftUI
import TwilDiaryCore

/// Home → Recommended: TMDB's recommendations for the title you watched last, each with how
/// closely it matches that title (shared genres and rating). Design: the section header with a
/// sparkle and "Because you watched …", 128 × 192 posters with a green match pill.
struct HomeRecommendedShelf: View {
    /// Recently watched titles with a TMDB id, newest first; the first that has recommendations is used.
    let seeds: [MediaTitle]
    @Environment(DiaryStore.self) private var store
    @State private var items: [CatalogItem] = []
    @State private var seed: MediaTitle?
    var body: some View {
        Group {
            if !items.isEmpty, let seed {
                VStack(alignment: .leading, spacing: 16) {
                    HomeSectionHeader(title: "Recommended", icon: "sparkle", subtitle: "Because you watched " + seed.name) {
                        NavigationLink(value: AppDestination.explore) { HomeRoundIcon() }.buttonStyle(.plain)
                            .accessibilityLabel("More recommendations").accessibilityIdentifier("home-recommended-more")
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(items.prefix(12), id: \.key) { item in link(item) }
                        }.scrollTargetLayout()
                    }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                }
            } else {
                // A real (zero-height) view, so the task below runs: on an empty Group it never did,
                // and the shelf never loaded. The negative padding cancels Home's 32 pt section gap.
                Color.clear.frame(height: 0).padding(.top, -32).accessibilityHidden(true)
            }
        }.task(id: seeds.map(\.id)) { await load() }
    }
    @ViewBuilder private func link(_ item: CatalogItem) -> some View {
        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) {
            NavigationLink(value: saved) { card(item) }.buttonStyle(.springPress).accessibilityIdentifier("home-recommended-\(item.id)")
        } else {
            NavigationLink(value: item.route) { card(item) }.buttonStyle(.springPress).accessibilityIdentifier("home-recommended-\(item.id)")
        }
    }
    private func card(_ item: CatalogItem) -> some View {
        let match = RecommendationMatch.percent(seedGenres: seed?.genres ?? [], genres: item.genres, rating: item.rating)
        return HomePoster(artwork: item.poster ?? CatalogTools.image(item.posterPath), name: item.name,
                          subtitle: [item.year.map(String.init), kindName(item)].compactMap { $0 }.joined(separator: " · ")) {
            HomeMatchBadge(percent: match)
        }
    }
    private func kindName(_ item: CatalogItem) -> String {
        if item.genres?.contains("Animation") == true { return item.mediaType == .movie ? "Anime movie" : "Anime" }
        return item.mediaType == .movie ? "Movie" : "Show"
    }
    private func load() async {
        let watched = Set(store.workspace.activeTitles.filter { $0.status == "completed" }.compactMap(\.tmdbId))
        // TMDB's recommendations for the title (the same list as its page's More like this). A title
        // with none (or a failed read) falls through to the next recent one, so the shelf still shows.
        for candidate in seeds.prefix(4) {
            guard let tmdb = candidate.tmdbId,
                  let related = try? await store.related(CatalogRoute(kind: candidate.isSeries ? .tv : .movie, id: tmdb)) else { continue }
            let found = related.items.filter { !watched.contains($0.id) }
                .sorted { RecommendationMatch.percent(seedGenres: candidate.genres, genres: $0.genres, rating: $0.rating) > RecommendationMatch.percent(seedGenres: candidate.genres, genres: $1.genres, rating: $1.rating) }
            if !found.isEmpty { seed = candidate; items = found; return }
        }
    }
}
