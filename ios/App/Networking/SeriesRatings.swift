import Foundation
import TwilDiaryCore

/// A show's ratings across all its episodes, from IMDb, TMDB and Trakt, for the title page's rating
/// chart: each source's score for the whole show, and each episode's score and votes, lined up in
/// TMDB's order. A source that splits the seasons differently (some anime) is matched by its order
/// instead of its numbers when its episode count agrees, and left out of the episodes otherwise.
struct SeriesRatings: Sendable {
    enum Source: String, CaseIterable, Sendable { case imdb = "IMDb", tmdb = "TMDB", trakt = "Trakt" }
    struct Score: Sendable, Equatable {
        let value: Double
        let votes: Int
    }
    struct Episode: Sendable, Identifiable {
        let index: Int
        let season: Int
        let number: Int
        let name: String?
        let scores: [Source: Score]
        var id: Int { index }
        /// The plain average of the sources that rated it.
        var overall: Double? { scores.isEmpty ? nil : scores.values.map(\.value).reduce(0, +) / Double(scores.count) }
        var votes: Int { scores.values.map(\.votes).reduce(0, +) }
        func score(_ source: Source?) -> Double? { source.map { scores[$0]?.value } ?? overall }
    }
    let episodes: [Episode]
    let show: [Source: Score]
    /// The sources with episode scores to draw.
    var sources: [Source] { Source.allCases.filter { source in episodes.filter { $0.scores[source] != nil }.count >= 2 } }
    var overallShow: Score? {
        guard !show.isEmpty else { return nil }
        return Score(value: show.values.map(\.value).reduce(0, +) / Double(show.count), votes: show.values.map(\.votes).reduce(0, +))
    }

    /// One source's episodes (season > 0), placed on TMDB's: by season and number when most of
    /// them match, else by order when the count is within two, else not at all.
    static func align(_ base: [(season: Int, number: Int)], _ theirs: [(season: Int, number: Int, score: Score)]) -> [Int: Score] {
        guard !base.isEmpty, !theirs.isEmpty else { return [:] }
        var position: [String: Int] = [:]
        for (index, episode) in base.enumerated() { position["\(episode.season):\(episode.number)"] = index }
        let byKey = theirs.compactMap { row in position["\(row.season):\(row.number)"].map { ($0, row.score) } }
        if Double(byKey.count) >= Double(theirs.count) * 0.8, !byKey.isEmpty {
            return Dictionary(byKey, uniquingKeysWith: { first, _ in first })
        }
        guard abs(theirs.count - base.count) <= 2 else { return [:] }
        let ordered = theirs.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        return Dictionary(ordered.prefix(base.count).enumerated().map { ($0.offset, $0.element.score) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Reads and keeps (for the session) a show's ratings for the chart.
@MainActor enum SeriesRatingsLoader {
    private static var kept: [Int: (at: Date, ratings: SeriesRatings)] = [:]

    static func load(tmdb: Int, imdbID: String?, store: DiaryStore) async -> SeriesRatings? {
        if let saved = kept[tmdb], Date.now.timeIntervalSince(saved.at) < 21_600 { return saved.ratings }
        guard !store.isPreview else { return nil }
        // TMDB: every season's episodes (names, scores, votes), twenty seasons a request.
        var base: [(season: Int, number: Int, name: String?, score: SeriesRatings.Score?)] = []
        var show: [SeriesRatings.Source: SeriesRatings.Score] = [:]
        var imdb = imdbID
        if let token = TMDBDirect.token(store),
           let details = try? await TMDBDirect.object("tv/\(tmdb)", query: ["language": "en-US", "append_to_response": "external_ids"], token: token) {
            if let value = details["vote_average"] as? Double, let votes = details["vote_count"] as? Int, votes > 0 { show[.tmdb] = .init(value: value, votes: votes) }
            if imdb == nil { imdb = (details["external_ids"] as? [String: Any])?["imdb_id"] as? String }
            let seasons = ((details["seasons"] as? [[String: Any]]) ?? []).compactMap { $0["season_number"] as? Int }.filter { $0 > 0 }.sorted().prefix(60)
            for start in stride(from: 0, to: seasons.count, by: 20) {
                let batch = Array(seasons)[start..<min(start + 20, seasons.count)]
                guard let data = try? await TMDBDirect.object("tv/\(tmdb)", query: ["language": "en-US", "append_to_response": batch.map { "season/\($0)" }.joined(separator: ",")], token: token) else { continue }
                for season in batch {
                    for episode in ((data["season/\(season)"] as? [String: Any])?["episodes"] as? [[String: Any]]) ?? [] {
                        guard let number = episode["episode_number"] as? Int else { continue }
                        let votes = episode["vote_count"] as? Int ?? 0, value = episode["vote_average"] as? Double ?? 0
                        base.append((season, number, episode["name"] as? String, votes >= 3 && value > 0 ? .init(value: value, votes: votes) : nil))
                    }
                }
            }
        }
        let keys = base.map { (season: $0.season, number: $0.number) }
        var scores: [SeriesRatings.Source: [Int: SeriesRatings.Score]] = [:]
        scores[.tmdb] = Dictionary(base.enumerated().compactMap { index, row in row.score.map { (index, $0) } }, uniquingKeysWith: { first, _ in first })
        // IMDb: the community dataset's episodes, and IMDb's own score for the show.
        if let imdb {
            if let seasons = try? await IMDbEpisodeRatings.shared.seasons(showID: imdb) {
                let rows = seasons.filter { $0.key > 0 }.flatMap { season, points in
                    points.map { (season: season, number: $0.episode, score: SeriesRatings.Score(value: $0.score, votes: $0.votes ?? 0)) }
                }
                scores[.imdb] = SeriesRatings.align(keys, rows)
            }
            if let summary = await imdbSummary(imdb) { show[.imdb] = summary }
        }
        // Trakt: the show and every episode with its votes (public, TwilDiary's app ID).
        if let trakt = await traktSeries(tmdb: tmdb) {
            if let summary = trakt.show { show[.trakt] = summary }
            scores[.trakt] = SeriesRatings.align(keys, trakt.episodes.map { (season: $0.season, number: $0.number, score: $0.score) })
            for (season, rows) in Dictionary(grouping: trakt.episodes, by: \.season) {
                TraktTitleReads.remember(show: tmdb, season: season, points: rows.filter { $0.score.votes >= EpisodeRatingAgreement.traktVotes }
                    .map { EpisodeRatingPoint(episode: $0.number, score: $0.score.value, votes: $0.score.votes) })
            }
        }
        let episodes = base.enumerated().map { index, row in
            var mine: [SeriesRatings.Source: SeriesRatings.Score] = [:]
            for source in SeriesRatings.Source.allCases { if let score = scores[source]?[index] { mine[source] = score } }
            return SeriesRatings.Episode(index: index + 1, season: row.season, number: row.number, name: row.name, scores: mine)
        }.filter { !$0.scores.isEmpty }
        guard episodes.count >= 2 || !show.isEmpty else { return nil }
        let result = SeriesRatings(episodes: episodes, show: show)
        // Kept for six hours only when TMDB's episodes came through: after a failed read (a flaky
        // link) the next visit asks again instead of leaving the chart away for hours.
        if !base.isEmpty { kept[tmdb] = (.now, result) }
        return result
    }

    private static func imdbSummary(_ id: String) async -> SeriesRatings.Score? {
        var request = URLRequest(url: URL(string: "https://caching.graphql.imdb.com/")!, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("twildiary", forHTTPHeaderField: "x-imdb-client-name")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": "query($id: ID!) { title(id: $id) { ratingsSummary { aggregateRating voteCount } } }", "variables": ["id": id]])
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = (((root["data"] as? [String: Any])?["title"] as? [String: Any])?["ratingsSummary"] as? [String: Any]),
              let value = (summary["aggregateRating"] as? NSNumber)?.doubleValue, let votes = summary["voteCount"] as? Int, votes > 0 else { return nil }
        return .init(value: value, votes: votes)
    }

    private struct TraktEpisode { let season: Int; let number: Int; let score: SeriesRatings.Score }
    private static func traktSeries(tmdb: Int) async -> (show: SeriesRatings.Score?, episodes: [TraktEpisode])? {
        guard let clientID = ProviderAppIDs.id(for: .trakt) else { return nil }
        func get(_ path: String) async -> Any? {
            guard let url = URL(string: "https://api.trakt.tv" + path) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")
            request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
            guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        let found = (await get("/search/tmdb/\(tmdb)?type=show") as? [[String: Any]]) ?? []
        guard let ids = found.compactMap({ ($0["show"] as? [String: Any])?["ids"] as? [String: Any] }).first(where: { ($0["tmdb"] as? Int) == tmdb }),
              let trakt = ids["trakt"] as? Int else { return nil }
        let summary = await get("/shows/\(trakt)?extended=full") as? [String: Any]
        let show = summary.flatMap { row -> SeriesRatings.Score? in
            guard let value = (row["rating"] as? NSNumber)?.doubleValue, let votes = row["votes"] as? Int, votes > 0 else { return nil }
            return .init(value: value, votes: votes)
        }
        let seasons = (await get("/shows/\(trakt)/seasons?extended=episodes,full") as? [[String: Any]]) ?? []
        let episodes = seasons.flatMap { season -> [TraktEpisode] in
            guard let number = season["number"] as? Int, number > 0 else { return [] }
            return ((season["episodes"] as? [[String: Any]]) ?? []).compactMap { episode in
                guard let episodeNumber = episode["number"] as? Int, let value = (episode["rating"] as? NSNumber)?.doubleValue,
                      let votes = episode["votes"] as? Int, votes >= EpisodeRatingAgreement.traktVotes, value > 0 else { return nil }
                return TraktEpisode(season: number, number: episodeNumber, score: .init(value: value, votes: votes))
            }
        }
        return (show, episodes)
    }
}
