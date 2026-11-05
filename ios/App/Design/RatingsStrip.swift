import SwiftUI
import TwilDiaryCore

/// Ratings from MDBList (IMDb, TMDB, Trakt, Letterboxd, MyAnimeList, Rotten Tomatoes, Metacritic…),
/// each with its service's mark and its own scale (IMDb 7.3, Trakt 77%, Letterboxd 3.5). Scrolls
/// sideways when there are more than fit. Without MDBList, TMDB's score stands alone.
struct RatingsStrip: View {
    let scores: [MDBListSyncEngine.SourceScore]
    var tmdbFallback: Double?

    private struct Item: Identifiable { let id: String; let source: String; let text: String }

    private var items: [Item] {
        var seen = Set<String>()
        var result: [Item] = []
        for score in scores {
            let key = RatingsStrip.canonical(score.source)
            guard !seen.contains(key), let text = RatingsStrip.text(source: key, value: score.value, score: score.score) else { continue }
            seen.insert(key); result.append(Item(id: key, source: key, text: text))
        }
        if result.isEmpty, let tmdbFallback, tmdbFallback > 0 {
            result.append(Item(id: "tmdb", source: "tmdb", text: tmdbFallback.formatted(.number.precision(.fractionLength(1)))))
        }
        return result.sorted { RatingsStrip.order($0.source) < RatingsStrip.order($1.source) }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            // One line across the page when they fit; sideways scrolling only when they don't.
            ViewThatFits(in: .horizontal) {
                row(items, spacing: 14)
                row(items, spacing: 10)
                ScrollView(.horizontal, showsIndicators: false) { row(items, spacing: 14) }.scrollClipDisabled()
            }.accessibilityIdentifier("title-ratings")
        }
    }

    private func row(_ items: [Item], spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    RatingSourceMark(source: item.source).frame(width: 21, height: 21)
                    Text(item.text).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(RatingsStrip.name(item.source) + " " + item.text)
            }
        }.padding(.vertical, 2)
    }

    static func canonical(_ source: String) -> String {
        let value = source.lowercased().replacingOccurrences(of: " ", with: "")
        switch value {
        case "mal", "myanimelist": return "myanimelist"
        case "tomatoes", "rottentomatoes", "rt": return "tomatoes"
        case "tomatoesaudience", "popcorn", "audience": return "popcorn"
        default: return value
        }
    }
    static func order(_ source: String) -> Int {
        ["tmdb", "myanimelist", "imdb", "trakt", "letterboxd", "tomatoes", "popcorn", "metacritic", "rogerebert"].firstIndex(of: source) ?? 99
    }
    static func name(_ source: String) -> String {
        switch source {
        case "tmdb": "TMDB"; case "imdb": "IMDb"; case "trakt": "Trakt"; case "letterboxd": "Letterboxd"
        case "myanimelist": "MyAnimeList"; case "tomatoes": "Rotten Tomatoes"; case "popcorn": "Audience score"
        case "metacritic": "Metacritic"; case "rogerebert": "Roger Ebert"
        default: source.capitalized
        }
    }
    /// Each service's own scale: percentages for Trakt and Rotten Tomatoes, out of 5 for
    /// Letterboxd, out of 10 for IMDb, TMDB and MyAnimeList, out of 100 for Metacritic.
    static func text(source: String, value: Double?, score: Double?) -> String? {
        func one(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(1))) }
        switch source {
        case "trakt", "tomatoes", "popcorn":
            guard let number = value ?? score, number > 0 else { return nil }
            return "\(Int(number.rounded()))%"
        case "metacritic":
            guard let number = value ?? score, number > 0 else { return nil }
            return "\(Int(number.rounded()))"
        case "letterboxd", "rogerebert":
            if let value, value > 0 { return one(value) }
            guard let score, score > 0 else { return nil }
            return one(score / (source == "rogerebert" ? 25 : 20))
        default:
            if let value, value > 0 { return one(value > 10 ? value / 10 : value) }
            guard let score, score > 0 else { return nil }
            return one(score / 10)
        }
    }
}

/// A small mark for a rating source, drawn in each service's colours (the services this app
/// already has a logo for use it).
struct RatingSourceMark: View {
    let source: String
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            Group {
                switch source {
                case "tmdb": BrandLogo(service: .tmdb, size: size)
                case "trakt": BrandLogo(service: .trakt, size: size)
                case "imdb":
                    Text("IMDb").font(.system(size: size * 0.36, weight: .black)).foregroundStyle(.black)
                        .frame(width: size, height: size).background(Color(webHex: "#F5C518"), in: RoundedRectangle(cornerRadius: size * 0.18))
                case "myanimelist":
                    Text("MAL").font(.system(size: size * 0.32, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: size, height: size).background(Color(webHex: "#2E51A2"), in: Circle())
                case "letterboxd":
                    HStack(spacing: -size * 0.06) {
                        Circle().fill(Color(webHex: "#FF8000")); Circle().fill(Color(webHex: "#00E054")); Circle().fill(Color(webHex: "#40BCF4"))
                    }.frame(width: size * 0.78, height: size * 0.3)
                        .frame(width: size, height: size).background(Color(webHex: "#202830"), in: Circle())
                case "tomatoes", "popcorn":
                    Text(source == "tomatoes" ? "🍅" : "🍿").font(.system(size: size * 0.62)).frame(width: size, height: size)
                case "metacritic":
                    Text("M").font(.system(size: size * 0.55, weight: .black)).foregroundStyle(.white)
                        .frame(width: size, height: size).background(Color(webHex: "#000000"), in: Circle())
                        .overlay(Circle().strokeBorder(Color(webHex: "#FFCC34"), lineWidth: size * 0.08))
                default:
                    Text(String(source.prefix(2)).uppercased()).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white)
                        .frame(width: size, height: size).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.22))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.accessibilityHidden(true)
    }
}

/// MDBList's ratings for a title, kept for six hours: a page you come back to shows them at once
/// instead of clearing and asking MDBList again (its free plan has a daily request limit).
/// A failed read isn't kept, so the next visit tries again.
@MainActor enum CriticScores {
    private static var cache: [String: (at: Date, scores: [MDBListSyncEngine.SourceScore])] = [:]

    static func load(store: DiaryStore, tmdbId: Int, isSeries: Bool) async -> [MDBListSyncEngine.SourceScore] {
        let key = (isSeries ? "tv:" : "movie:") + String(tmdbId)
        if let entry = cache[key], Date.now.timeIntervalSince(entry.at) < 6 * 3600 { return entry.scores }
        guard store.providerSettings.mdblist.isAuthenticated else { return [] }
        let config = await store.freshProviderConfig(.mdblist)
        guard let summary = try? await store.directClient.fetchMDBListRatings(config: config, tmdbId: tmdbId, isSeries: isSeries) else { return [] }
        let scores = summary.ratings.filter { ($0.score ?? 0) > 0 || ($0.value ?? 0) > 0 }
        if cache.count >= 300 { cache.removeAll() }
        cache[key] = (.now, scores)
        return scores
    }
}
