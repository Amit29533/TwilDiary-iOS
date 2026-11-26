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
    /// The first read has finished (with picks or without).
    @State private var loaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if !items.isEmpty, let seed {
                VStack(alignment: .leading, spacing: Gap.heading) {
                    HomeSectionHeader(title: "Recommended", icon: "cinemind", subtitle: "Because you watched " + seed.name) {
                        // All of the recommendations for that title (its More like this page), not Explore.
                        NavigationLink(value: ShowPageRoute.related(CatalogRoute(kind: seed.isSeries ? .tv : .movie, id: seed.tmdbId ?? 0), title: seed.name)) { HomeRoundIcon() }.buttonStyle(.plain)
                            .accessibilityLabel("More recommendations").accessibilityIdentifier("home-recommended-more")
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(items.prefix(12), id: \.key) { item in link(item) }
                        }.scrollTargetLayout()
                    }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                }
            } else if !loaded, !seeds.isEmpty {
                // While it reads: the heading and posters' shapes where the shelf will land. It took no room
                // until then, and appeared in the middle of Home pushing everything under it down.
                VStack(alignment: .leading, spacing: Gap.heading) {
                    HomeSectionHeader(title: "Recommended", icon: "cinemind", subtitle: seeds.first.map { "Because you watched " + $0.name }) { EmptyView() }
                    DiaryLoadingPlaceholder(label: "Loading recommendations", layout: .homeShelf)
                }
            } else {
                // A real (zero-height) view, so the task below runs: on an empty Group it never did,
                // and the shelf never loaded. The negative padding cancels Home's section gap.
                Color.clear.frame(height: 0).padding(.top, -Gap.section).accessibilityHidden(true)
            }
        }
        // Nothing to recommend: the room it held closes smoothly.
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: loaded)
        .task(id: seeds.map(\.id)) { await load(); loaded = true }
    }
    @ViewBuilder private func link(_ item: CatalogItem) -> some View {
        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) {
            CardLink(value: saved) { card(item) }.buttonStyle(.springPress).accessibilityIdentifier("home-recommended-\(item.id)")
        } else {
            CardLink(value: item.route) { card(item) }.buttonStyle(.springPress).accessibilityIdentifier("home-recommended-\(item.id)")
        }
    }
    private func card(_ item: CatalogItem) -> some View {
        let match = RecommendationMatch.percent(seedGenres: seed?.genres ?? [], genres: item.genres, rating: item.rating)
        let score = PosterScores.score(for: item, store: store)
        // Design Lab's Recommended match: a pill on the poster, green in the caption (one badge per
        // poster, the rating), or not shown.
        let place = StudioLab.shared.match
        return HomePoster(artwork: item.poster ?? CatalogTools.image(item.posterPath), name: item.name,
                          subtitle: [item.year.map(String.init), kindName(item)].compactMap { $0 }.joined(separator: " · "), score: score,
                          match: place == .inCaption ? match : nil) {
            if place == .onPoster { HomeMatchBadge(percent: match) }
        }.wantsPosterScore(item, known: score, store: store)
    }
    private func kindName(_ item: CatalogItem) -> String {
        // TMDB's own mark (Japanese and animated); a title read without it falls back to the genre.
        let anime = item.isAnime ?? (item.genres?.contains("Animation") == true)
        if anime { return item.mediaType == .movie ? "Anime movie" : "Anime" }
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
