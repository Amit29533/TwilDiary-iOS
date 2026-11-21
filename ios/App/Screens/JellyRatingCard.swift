import SwiftUI

/// The rating card a moment after a video starts, as Netflix shows it: the age rating and what's in
/// it ("violence, sexual content, language").
struct JellyRatingInfo: Equatable {
    let rating: String?
    let warnings: [String]
}

@MainActor enum JellyRatingCard {
    /// The rating from Jellyfin (an episode's, else its show's), else IMDb's; the warnings from IMDb's
    /// parents guide (the show's, for an episode): only what's Moderate or Severe, the strongest first.
    /// Nil when there's neither.
    static func load(_ item: JellyfinClient.Item, client: JellyfinClient) async -> JellyRatingInfo? {
        let user = await JellyfinUser.id(client)
        let detail = try? await client.detail(item.Id, user: user)
        var imdb = imdbID(detail?.ProviderIds ?? item.ProviderIds)
        var showRating: String?
        if item.kind == "Episode", let series = item.SeriesId, let show = try? await client.detail(series, user: user) {
            imdb = imdbID(show.ProviderIds) ?? imdb
            showRating = show.OfficialRating
        }
        var guide: ParentsGuide?
        if let imdb { guide = await IMDbParentsGuide.shared.guide(imdbID: imdb) }
        let rating = [detail?.OfficialRating, showRating, guide?.certificate]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let words = ["NUDITY": "sexual content", "VIOLENCE": "violence", "PROFANITY": "language",
                     "ALCOHOL": "substances", "FRIGHTENING": "frightening scenes"]
        let strong = (guide?.categories ?? []).enumerated().filter { $0.element.level >= 2 }
            .sorted { $0.element.level != $1.element.level ? $0.element.level > $1.element.level : $0.offset < $1.offset }
        let warnings = strong.compactMap { words[$0.element.id] }
        guard rating != nil || !warnings.isEmpty else { return nil }
        return JellyRatingInfo(rating: rating, warnings: warnings)
    }
    private static func imdbID(_ ids: [String: String]?) -> String? {
        ids?.first { $0.key.lowercased() == "imdb" }?.value
    }
}

/// The card: a red line down the side, RATED and the rating, then the warnings.
struct JellyRatingCardView: View {
    let info: JellyRatingInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Color(red: 0.89, green: 0.29, blue: 0.29)).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                if let rating = info.rating {
                    Text("RATED " + rating.uppercased()).font(.system(size: 17, weight: .bold)).tracking(0.3)
                }
                if !info.warnings.isEmpty {
                    Text(info.warnings.joined(separator: ", ")).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("jellyspace-rating-card")
    }
}
