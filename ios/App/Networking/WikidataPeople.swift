import Foundation

/// Wikidata links an AniList voice actor to their TMDB person (AniList staff ID P11227 to TMDB
/// person ID P4985, about 8,900 people), so a voice-actor page can use TMDB's full-size photo and
/// credits instead of guessing from cast lists or names. Public data: a request carries only the
/// numeric id, nothing from the diary. Answers, including "no link", are kept for the session.
actor WikidataPeople {
    static let shared = WikidataPeople()
    private var tmdbByStaff: [Int: Int?] = [:]
    private var staffByTMDB: [Int: Int?] = [:]
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func tmdbID(forAniListStaff id: Int) async -> Int? {
        guard id > 0 else { return nil }
        if let saved = tmdbByStaff[id] { return saved }
        guard let url = Self.url(from: "P11227", to: "P4985", id: id), let found = await lookup(url) else { return nil }
        tmdbByStaff.updateValue(found, forKey: id)
        return found
    }
    func aniListStaffID(forTMDB id: Int) async -> Int? {
        guard id > 0 else { return nil }
        if let saved = staffByTMDB[id] { return saved }
        guard let url = Self.url(from: "P4985", to: "P11227", id: id), let found = await lookup(url) else { return nil }
        staffByTMDB.updateValue(found, forKey: id)
        return found
    }

    /// One SPARQL query: the other service's id for the person holding `id`.
    static func url(from: String, to: String, id: Int) -> URL? {
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")
        parts?.queryItems = [
            URLQueryItem(name: "query", value: "SELECT ?v WHERE { ?p wdt:\(from) \"\(id)\" ; wdt:\(to) ?v } LIMIT 3"),
            URLQueryItem(name: "format", value: "json")
        ]
        return parts?.url
    }
    /// The single linked id; nil when there is none or the link is ambiguous (two people, two ids).
    static func single(_ data: Data) -> Int? {
        struct Reply: Decodable {
            let results: Results
            struct Results: Decodable { let bindings: [Row] }
            struct Row: Decodable { let v: Value }
            struct Value: Decodable { let value: String }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        let ids = Set(reply.results.bindings.compactMap { Int($0.v.value) }.filter { $0 > 0 })
        return ids.count == 1 ? ids.first : nil
    }
    /// Outer nil: the request failed (ask again next time). Inner nil: Wikidata has no link.
    private func lookup(_ url: URL) async -> Int?? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        // Wikimedia asks automated clients to name themselves.
        request.setValue("TwilDiary/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return .some(Self.single(data))
    }
}
