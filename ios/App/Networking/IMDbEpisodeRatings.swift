import Foundation
import TwilDiaryCore

/// One file per series from the community index of IMDb's public episode and ratings datasets.
actor IMDbEpisodeRatings {
    static let shared = IMDbEpisodeRatings()
    private struct Entry {
        let fetched: Date
        let seasons: [Int: [EpisodeRatingPoint]]
    }
    private var cache: [String: Entry] = [:]

    /// Every season's rated episodes (season 0, specials, included).
    func seasons(showID: String) async throws -> [Int: [EpisodeRatingPoint]] {
        _ = try await points(showID: showID, season: 1)
        return cache[showID]?.seasons ?? [:]
    }

    func points(showID: String, season: Int) async throws -> [EpisodeRatingPoint] {
        guard showID.range(of: #"^tt[0-9]{7,10}$"#, options: .regularExpression) != nil else { return [] }
        if let entry = cache[showID], Date.now.timeIntervalSince(entry.fetched) < 86_400 {
            return entry.seasons[season] ?? []
        }
        let base = URL(string: "https://raw.githubusercontent.com/ya0903/imdb-episode-dataset/main/data/shows/")!
        let request = URLRequest(url: base.appendingPathComponent(showID + ".json"), timeoutInterval: 12)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        let seasons: [Int: [EpisodeRatingPoint]]
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: seasons = try Self.decode(data, showID: showID)
        case 404: seasons = [:]
        default: throw URLError(.badServerResponse)
        }
        if cache.count >= 64, let oldest = cache.min(by: { $0.value.fetched < $1.value.fetched }) {
            cache.removeValue(forKey: oldest.key)
        }
        cache[showID] = Entry(fetched: .now, seasons: seasons)
        return seasons[season] ?? []
    }

    static func decode(_ data: Data, showID: String) throws -> [Int: [EpisodeRatingPoint]] {
        struct Score: Decodable { let r: Double?, v: Int? }
        struct Series: Decodable { let id: String, seasons: [String: [String: Score]] }
        let series = try JSONDecoder().decode(Series.self, from: data)
        guard series.id == showID else { throw URLError(.cannotParseResponse) }
        var result: [Int: [EpisodeRatingPoint]] = [:]
        for (key, episodes) in series.seasons {
            guard let season = Int(key), season >= 0 else { continue }
            result[season] = episodes.compactMap { key, value -> EpisodeRatingPoint? in
                guard let episode = Int(key), episode > 0, let score = value.r,
                      score > 0, score <= 10, (value.v ?? 0) >= EpisodeRatingAgreement.imdbVotes else { return nil }
                return EpisodeRatingPoint(episode: episode, score: score, votes: value.v)
            }.sorted { $0.episode < $1.episode }
        }
        return result
    }
}
