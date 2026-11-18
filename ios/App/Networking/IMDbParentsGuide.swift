import Foundation

/// IMDb's parents guide for a title: how much sex and nudity, violence, profanity, drinking and
/// drugs, and frightening scenes it has (None, Mild, Moderate or Severe, as IMDb's users voted),
/// read from IMDb's public GraphQL endpoint by the title's IMDb id. IMDb allows this for personal,
/// non-commercial use. Kept a week per title.
struct ParentsGuide: Codable, Equatable, Sendable {
    struct Category: Codable, Equatable, Sendable, Identifiable {
        /// NUDITY, VIOLENCE, PROFANITY, ALCOHOL or FRIGHTENING.
        let id: String
        /// 0 none, 1 mild, 2 moderate, 3 severe.
        let level: Int
        var levelName: String { ["None", "Mild", "Moderate", "Severe"][max(0, min(3, level))] }
        /// Out of five bars: none 0, mild 2, moderate 3, severe 5.
        var bars: Int { [0, 2, 3, 5][max(0, min(3, level))] }
    }
    let categories: [Category]
    /// IMDb's age certificate ("TV-PG"), when it has one.
    let certificate: String?

    static func decode(_ data: Data) throws -> ParentsGuide {
        struct Reply: Decodable {
            struct DataPart: Decodable { let title: Title? }
            struct Title: Decodable { let certificate: Certificate?; let parentsGuide: Guide? }
            struct Certificate: Decodable { let rating: String? }
            struct Guide: Decodable { let categories: [Row]? }
            struct Row: Decodable { let category: Kind; let severity: Severity? }
            struct Kind: Decodable { let id: String }
            struct Severity: Decodable { let text: String? }
            let data: DataPart?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let title = reply.data?.title else { throw URLError(.cannotParseResponse) }
        let order = ["NUDITY", "VIOLENCE", "PROFANITY", "ALCOHOL", "FRIGHTENING"]
        let rows = (title.parentsGuide?.categories ?? []).compactMap { row -> Category? in
            guard order.contains(row.category.id), let text = row.severity?.text,
                  let level = ["none": 0, "mild": 1, "moderate": 2, "severe": 3][text.lowercased()] else { return nil }
            return Category(id: row.category.id, level: level)
        }.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
        return ParentsGuide(categories: rows, certificate: title.certificate?.rating.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The youngest age a rating suits, as people say it: "10+" for TV-PG, "All ages" for G.
    static func age(for rating: String) -> String? {
        let value = rating.trimmingCharacters(in: .whitespaces).uppercased()
        let known: [String: String] = [
            "TV-Y": "All ages", "TV-G": "All ages", "G": "All ages", "U": "All ages", "ALL": "All ages", "TV-Y7": "7+", "TV-Y7-FV": "7+",
            "TV-PG": "10+", "PG": "8+", "PG-13": "13+", "TV-14": "14+", "TV-MA": "17+", "R": "17+", "NC-17": "18+",
            "12A": "12+", "PG12": "12+", "PG-12": "12+", "R15+": "15+", "R18+": "18+", "MA15+": "15+", "M": "15+", "X": "18+"
        ]
        if let age = known[value] { return age }
        let digits = value.filter(\.isNumber)
        if let years = Int(digits), (3...21).contains(years), digits.count == value.replacingOccurrences(of: "+", with: "").count { return "\(years)+" }
        return nil
    }
}

actor IMDbParentsGuide {
    static let shared = IMDbParentsGuide()
    private var cache: [String: (at: Date, guide: ParentsGuide?)] = [:]

    func guide(imdbID: String) async -> ParentsGuide? {
        guard imdbID.range(of: #"^tt[0-9]{7,10}$"#, options: .regularExpression) != nil else { return nil }
        if let kept = cache[imdbID], Date.now.timeIntervalSince(kept.at) < 604_800 { return kept.guide }
        let key = "imdbGuide." + imdbID
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           Date.now.timeIntervalSince(saved.at) < 604_800 {
            cache[imdbID] = (saved.at, saved.guide)
            return saved.guide
        }
        var request = URLRequest(url: URL(string: "https://caching.graphql.imdb.com/")!, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("twildiary", forHTTPHeaderField: "x-imdb-client-name")
        let query = "query($id: ID!) { title(id: $id) { certificate { rating } parentsGuide { categories { category { id } severity { text } } } } }"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": imdbID]])
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let guide = try? ParentsGuide.decode(data) else { return nil }
        cache[imdbID] = (.now, guide)
        UserDefaults.standard.set(try? JSONEncoder().encode(Saved(at: .now, guide: guide)), forKey: key)
        return guide
    }
    private struct Saved: Codable { let at: Date; let guide: ParentsGuide }
}
