import SwiftUI
import TwilDiaryCore

enum SearchBrowseTopic: String, CaseIterable, Identifiable {
    case drama = "Drama", anime = "Anime", documentary = "Documentary"
    var id: Self { self }

    enum Tile: Identifiable {
        case catalog(SearchBrowseCategory)
        case anime(title: String, tag: String)

        var id: String {
            switch self {
            case .catalog(let category): category.title
            case .anime(let title, _): title
            }
        }
    }

    var tiles: [Tile] {
        switch self {
        case .drama:
            return [
                tagged("Coming-of-Age", 10683),
                category("Drama", symbol: "theatermasks", filter: .genre("Drama")), tagged("Costume Drama", 195013), tagged("Docudrama", 15061),
                tagged("Epic", 349749, 278700), tagged("Financial Drama", 246911, 177493),
                tagged("Historical Epic", 278700),
                category("Korean Drama", symbol: "heart.text.square", filter: .koreanDrama, types: [.tv]),
                tagged("Legal Drama", 214780, 33519, 10909), tagged("Medical Drama", 208788, 11612),
                tagged("Micro-Drama", 382841, 383994, 381124), tagged("Period Drama", 15060),
                tagged("Political Drama", 298528), tagged("Prison Drama", 355148),
                tagged("Psychological Drama", 272553, 12565, 159315), tagged("Showbiz Drama", 837),
                category("Soap Opera", symbol: "tv", filter: .genre("Soap"), types: [.tv]),
                tagged("Teen Drama", 193400), tagged("Telenovela", 199262), tagged("Tragedy", 10614),
                tagged("Workplace Drama", 370143), tagged("Sports Drama", 6075),
                tagged("Survival Drama", 10349), tagged("Heist Drama", 10051), tagged("Espionage Drama", 5265)
            ]
        case .anime:
            let genres: [Tile] = AniListClient.browseGenres.map { name in
                .anime(title: name == "Mahou Shoujo" ? "Magical Girl" : name, tag: name)
            }
            return [.catalog(SearchBrowseTheme.anime.category), .anime(title: "Isekai", tag: "Isekai")] + genres + [
                .anime(title: "Shōnen", tag: "Shounen"), .anime(title: "Shōjo", tag: "Shoujo"),
                .anime(title: "Seinen", tag: "Seinen"), .anime(title: "Josei", tag: "Josei"),
                .anime(title: "Iyashikei", tag: "Iyashikei"), .anime(title: "Martial Arts", tag: "Martial Arts"),
                .anime(title: "Wuxia", tag: "Wuxia"), .anime(title: "Cultivation", tag: "Cultivation"),
                .anime(title: "Cyberpunk", tag: "Cyberpunk"), .anime(title: "Space Opera", tag: "Space Opera")
            ]
        case .documentary:
            return [
                tagged("Crime Documentary", 33722),
                category("Documentary", symbol: "globe", filter: .genre("Documentary")),
                category("Docuseries", symbol: "tv", filter: .genre("Documentary"), types: [.tv]),
                tagged("Faith & Spirituality Documentary", 11001, 10706), tagged("Food Documentary", 10637),
                tagged("History Documentary", 378429, 239635, 159289), tagged("Military Documentary", 162365, 273967),
                tagged("Music Documentary", 283297, 156137), tagged("Nature Documentary", 221355, 18330, 9902),
                tagged("Political Documentary", 239902, 232569, 6083),
                tagged("Science & Technology Documentary", 325892, 287067, 1576),
                tagged("Sports Documentary", 6075), tagged("Travel Documentary", 9935)
            ]
        }
    }

    private func tagged(_ title: String, _ keywords: Int...) -> Tile {
        category(title, symbol: self == .documentary ? "globe" : "theatermasks",
                 filter: .genreKeywords(rawValue, keywords))
    }

    private func category(_ title: String, symbol: String, filter: SearchBrowseCategory.Filter,
                          types: [MediaKind] = [.movie, .tv]) -> Tile {
        .catalog(SearchBrowseCategory(title: title, symbol: symbol, tint: self == .documentary ? "#315b54" : "#67424f",
                                      filter: filter, types: types))
    }
}

struct SearchTopicShelf: View {
    let topic: SearchBrowseTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(topic.rawValue).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                SectionMoreLink(label: "See all " + topic.rawValue, value: SearchBrowseRoute.topics(topic),
                                identifier: "search-topics-more-" + topic.rawValue)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: Gap.item) {
                    ForEach(topic.tiles) { tile in
                        SearchTopicLink(tile: tile)
                            .containerRelativeFrame(.horizontal) { width, _ in min(210, width * 0.44) }
                    }
                }.padding(.horizontal, 14)
            }.scrollIndicators(.hidden).padding(.horizontal, -14)
        }
    }
}

struct SearchTopicGrid: View {
    let topic: SearchBrowseTopic
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExploreBrowsePage(title: topic.rawValue, symbol: topic == .anime ? "sparkles" : topic == .drama ? "theatermasks" : "globe") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                      count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                ForEach(topic.tiles) { SearchTopicLink(tile: $0) }
            }.padding(14).padding(.bottom, 32)
        }
    }
}

private struct SearchTopicLink: View {
    let tile: SearchBrowseTopic.Tile

    var body: some View {
        switch tile {
        case .catalog(let category): SearchCategoryLink(category: category)
        case .anime(let title, let tag): SearchAnimeTopicCard(title: title, tag: tag)
        }
    }
}

private struct SearchAnimeTopicCard: View {
    let title: String
    let tag: String
    @Environment(DiaryStore.self) private var store
    @State private var artwork: String?

    var body: some View {
        NavigationLink(value: SearchBrowseRoute.animeTopic(SearchBrowseTag(name: tag, anilist: true, displayName: title))) {
            SearchBrowseArtworkTile(title: title, symbol: "wand.and.stars", tint: "#56426b", artwork: artwork)
        }.buttonStyle(.springPress)
            .preference(key: BrowseCoverPreference.self, value: artwork)
            .accessibilityIdentifier("search-anime-topic-" + tag)
            .task {
                guard !store.isPreview, artwork == nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(450))
                    artwork = try await AniListClient.shared.browseTagArtwork(tag)
                } catch { /* Keep the category usable without an image. */ }
            }
    }
}
