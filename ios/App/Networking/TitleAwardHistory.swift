import Foundation
import SQLite3
import TwilDiaryCore

struct TitleAwardRecord: Codable, Hashable, Sendable {
    let year: Int?
    let ceremony: String
    let category: String
    let won: Bool
    var recipient: String? = nil
}

actor TitleAwardHistory {
    static let shared = TitleAwardHistory()
    private var cachedPeople: [String: (Date, [TitleAwardRecord])] = [:]

    /// A single primary-key read from the bundled archive, also available offline.
    func titleRecords(_ route: CatalogRoute) throws -> [TitleAwardRecord] {
        guard let url = Bundle.main.url(forResource: "TitleAwards", withExtension: "sqlite") else {
            throw APIError.message("The awards archive is unavailable.")
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw APIError.message("The awards archive couldn’t be opened.")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT records FROM titles WHERE identity = ?", -1, &statement, nil) == SQLITE_OK else {
            throw APIError.message("The awards archive couldn’t be read.")
        }
        let key = "\(route.kind.rawValue):\(route.id)"
        return try key.withCString { pointer in
            guard sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK else {
                throw APIError.message("The title couldn’t be looked up.")
            }
            defer { sqlite3_clear_bindings(statement) }
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return []
            case SQLITE_ROW:
                guard let bytes = sqlite3_column_blob(statement, 0) else { return [] }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                return try JSONDecoder().decode([TitleAwardRecord].self, from: data)
            default: throw APIError.message("The awards archive couldn’t be read.")
            }
        }
    }

    /// P1686 ("for work") explicitly connects each individual's award statement to this title.
    func peopleRecords(_ route: CatalogRoute, imdbID: String?) async throws -> [TitleAwardRecord] {
        let property: String, value: String
        if let imdbID, imdbID.range(of: #"^tt[0-9]{7,10}$"#, options: .regularExpression) != nil {
            property = "P345"; value = imdbID
        } else {
            property = route.kind == .movie ? "P4947" : "P4983"; value = String(route.id)
        }
        let key = "\(property):\(value)"
        if let (at, saved) = cachedPeople[key], Date.now.timeIntervalSince(at) < 86_400 { return saved }
        let query = """
        SELECT ?awardLabel ?whoLabel ?date ?familyLabel ?won WHERE {
          { SELECT (SAMPLE(?candidate) AS ?work) WHERE { ?candidate wdt:\(property) "\(value)" } HAVING(COUNT(DISTINCT ?candidate) = 1) }
          ?s pq:P1686 ?work .
          { ?who p:P166 ?s . ?s ps:P166 ?award . BIND(true AS ?won) }
          UNION { ?who p:P1411 ?s . ?s ps:P1411 ?award . BIND(false AS ?won) }
          FILTER NOT EXISTS { ?s wikibase:rank wikibase:DeprecatedRank }
          OPTIONAL { ?s pq:P585 ?date }
          OPTIONAL { ?award wdt:P361 ?family }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        """
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")
        parts?.queryItems = [.init(name: "query", value: query), .init(name: "format", value: "json")]
        guard let url = parts?.url else { throw APIError.message("The credits request is unavailable.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue("TwilDiary/1.0 (iOS; https://github.com/Amit29533/TwilDiary-iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.message("Individual award credits couldn’t be loaded.")
        }
        struct Reply: Decodable {
            struct Results: Decodable { let bindings: [[String: Field]] }
            struct Field: Decodable { let value: String }
            let results: Results
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let rows = reply.results.bindings.compactMap { row -> TitleAwardRecord? in
            func label(_ key: String) -> String? {
                guard let text = row[key]?.value, !text.isEmpty,
                      text.range(of: #"^Q[0-9]+$"#, options: .regularExpression) == nil else { return nil }
                return text
            }
            guard let category = label("awardLabel"), let person = label("whoLabel"),
                  let flag = row["won"]?.value, let won = Bool(flag) else { return nil }
            let year = row["date"].flatMap { Int($0.value.prefix(4)) }
            var family = label("familyLabel")
            var categoryName = category
            // Some Wikidata categories name the ceremony explicitly but omit the family relation.
            let prefixes = [("Academy Award for ", "Academy Awards"),
                            ("Golden Globe Award for ", "Golden Globes"),
                            ("Primetime Emmy Award for ", "Primetime Emmy Awards")]
            if let (prefix, ceremony) = prefixes.first(where: { category.hasPrefix($0.0) }) {
                categoryName = String(category.dropFirst(prefix.count))
                family = ceremony
            }
            return .init(year: year, ceremony: family ?? "Other awards", category: categoryName,
                         won: won, recipient: person)
        }
        try Task.checkCancellation()
        if cachedPeople.count >= 200 { cachedPeople.removeAll(keepingCapacity: true) }
        cachedPeople[key] = (.now, rows)
        return rows
    }
}
