import SwiftUI
import TwilDiaryCore

/// Home → Recommended: TMDB's recommendations for the title you watched last, each with how
/// closely it matches that title (shared genres and rating).
struct HomeRecommendedShelf: View {
    let seed: MediaTitle
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var items: [CatalogItem] = []
    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        DiaryIcon(name: "sparkles", size: 18).foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recommended").font(.system(size: 22, weight: .bold)).tracking(-0.6)
                            Text("Because you watched " + seed.name).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        SectionMoreLink(label: "More recommendations", value: AppDestination.explore, identifier: "home-recommended-more")
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(items.prefix(12), id: \.key) { item in
                                link(item)
                                    .containerRelativeFrame(.horizontal) { width, _ in min(144, max(96, (width - 24) / 3.15)) }
                            }
                        }.scrollTargetLayout()
                    }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).scrollClipDisabled()
                }.padding(.horizontal, -4)
            }
        }.task(id: seed.id) { await load() }
    }
    @ViewBuilder private func link(_ item: CatalogItem) -> some View {
        if let saved = CatalogTools.libraryIdentity(item, in: store.workspace) {
            NavigationLink(value: saved) { card(item) }.buttonStyle(.springPress).accessibilityIdentifier("home-recommended-\(item.id)")
        } else {
            NavigationLink(value: item.route) { card(item) }.buttonStyle(.springPress).accessibilityIdentifier("home-recommended-\(item.id)")
        }
    }
    private func card(_ item: CatalogItem) -> some View {
        let match = RecommendationMatch.percent(seedGenres: seed.genres, genres: item.genres, rating: item.rating)
        return VStack(alignment: .leading, spacing: 6) {
            Artwork(path: item.poster ?? CatalogTools.image(item.posterPath), title: item.name, initialsOnly: false)
                .posterAspect().clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .bottomLeading) {
                    Text("\(match)%match").font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 22).background(Color(webHex: "#1f7a4d").opacity(0.92), in: Capsule()).padding(7)
                        .accessibilityLabel("\(match) percent match")
                }
            Text(item.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
            Text([item.year.map(String.init), kindName(item)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private func kindName(_ item: CatalogItem) -> String {
        if item.genres?.contains("Animation") == true { return item.mediaType == .movie ? "Anime movie" : "Anime" }
        return item.mediaType == .movie ? "Movie" : "Show"
    }
    private func load() async {
        guard let tmdb = seed.tmdbId else { items = []; return }
        // TMDB's recommendations for the title (the same list as its page's More like this).
        guard let related = try? await store.related(CatalogRoute(kind: seed.isSeries ? .tv : .movie, id: tmdb)) else { return }
        let watched = Set(store.workspace.activeTitles.filter { $0.status == "completed" }.compactMap(\.tmdbId))
        items = related.items.filter { !watched.contains($0.id) }
            .sorted { RecommendationMatch.percent(seedGenres: seed.genres, genres: $0.genres, rating: $0.rating) > RecommendationMatch.percent(seedGenres: seed.genres, genres: $1.genres, rating: $1.rating) }
    }
}
