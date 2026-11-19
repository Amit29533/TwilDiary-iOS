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

/// One name for each ceremony and category, whichever source a record came from: the bundled
/// archive says "BAFTA Film Awards" and "Best Adapted Screenplay", Wikidata "British Academy Film
/// Awards" (or nothing) and "Academy Award for Best Writing, Adapted Screenplay", so the same award
/// was listed twice (Oppenheimer, 2026-11-19).
enum AwardNames {
    private static let ceremonies: [String: String] = [
        "academy award": "Academy Awards", "academy awards": "Academy Awards", "oscars": "Academy Awards",
        "primetime emmy award": "Emmy Awards", "primetime emmy awards": "Emmy Awards", "emmy awards": "Emmy Awards",
        "golden globe award": "Golden Globes", "golden globe awards": "Golden Globes", "golden globes": "Golden Globes",
        "british academy film awards": "BAFTA Film Awards", "british academy film award": "BAFTA Film Awards",
        "bafta film awards": "BAFTA Film Awards", "bafta awards": "BAFTA Film Awards",
        "critics' choice awards": "Critics Choice Awards", "critics choice awards": "Critics Choice Awards",
        "critics' choice movie awards": "Critics Choice Awards", "broadcast film critics association award": "Critics Choice Awards",
        "broadcast film critics association awards": "Critics Choice Awards",
        "screen actors guild award": "Actor Awards", "screen actors guild awards": "Actor Awards", "actor awards": "Actor Awards"
    ]
    /// Categories that carry their ceremony's name ("BAFTA Award for Best Direction").
    private static let prefixes: [(String, String)] = [
        ("Academy Award for ", "Academy Awards"), ("Golden Globe Award for ", "Golden Globes"),
        ("Primetime Emmy Award for ", "Emmy Awards"), ("BAFTA Award for ", "BAFTA Film Awards"),
        ("Critics' Choice Movie Award for ", "Critics Choice Awards"), ("Critics' Choice Television Award for ", "Critics Choice Awards"),
        ("Broadcast Film Critics Association Award for ", "Critics Choice Awards"), ("Screen Actors Guild Award for ", "Actor Awards")
    ]
    private static let categories: [String: String] = [
        "best writing, adapted screenplay": "Best Adapted Screenplay", "best writing, original screenplay": "Best Original Screenplay",
        "best direction": "Best Director", "best actor in a leading role": "Best Actor", "best actress in a leading role": "Best Actress",
        "best actor in a supporting role": "Best Supporting Actor", "best actress in a supporting role": "Best Supporting Actress"
    ]
    static func normalized(_ record: TitleAwardRecord) -> TitleAwardRecord {
        var ceremony = ceremonies[record.ceremony.lowercased()] ?? record.ceremony
        var category = record.category.replacingOccurrences(of: " - ", with: " \u{2013} ").replacingOccurrences(of: " \u{2014} ", with: " \u{2013} ")
        if let (prefix, named) = prefixes.first(where: { category.hasPrefix($0.0) }) {
            category = String(category.dropFirst(prefix.count))
            category = category.prefix(1).uppercased() + category.dropFirst()
            // The award's own name says the ceremony when its family is missing ("Other awards").
            if ceremony == "Other awards" { ceremony = named }
        }
        category = categories[category.lowercased()] ?? category
        return TitleAwardRecord(year: record.year, ceremony: ceremony, category: category, won: record.won, recipient: record.recipient)
    }
    /// The bundled archive's records and Wikidata's credits as one list. For a film, a credit dated
    /// a year away from the only edition of that ceremony the archive has takes the archive's year:
    /// Wikidata dates some Golden Globes by the film's year (2023) and others by the ceremony's (2024).
    static func merge(archive: [TitleAwardRecord], people: [TitleAwardRecord], movie: Bool) -> [TitleAwardRecord] {
        let titles = archive.map(normalized)
        var years: [String: Set<Int>] = [:]
        for row in titles { if let year = row.year { years[row.ceremony, default: []].insert(year) } }
        let credits = people.map(normalized).map { row -> TitleAwardRecord in
            guard movie, let year = row.year, let known = years[row.ceremony], !known.contains(year) else { return row }
            let near = known.filter { abs($0 - year) == 1 }
            guard near.count == 1, let snapped = near.first else { return row }
            return TitleAwardRecord(year: snapped, ceremony: row.ceremony, category: row.category, won: row.won, recipient: row.recipient)
        }.map { row -> TitleAwardRecord in
            // The archive's fuller name for the same award ("Best Original Score – Motion Picture"
            // for Wikidata's "Best Original Score"), when that edition has exactly one.
            let fuller = Set(titles.filter { $0.ceremony == row.ceremony && $0.year == row.year && $0.category.hasPrefix(row.category + " \u{2013} ") }.map(\.category))
            guard fuller.count == 1, let name = fuller.first else { return row }
            return TitleAwardRecord(year: row.year, ceremony: row.ceremony, category: name, won: row.won, recipient: row.recipient)
        }
        return titles + credits
    }
}

actor TitleAwardHistory {
    static let shared = TitleAwardHistory()
    private var cachedPeople: [String: (Date, [TitleAwardRecord])] = [:]
    /// Requests on their way: a second ask for the same title waits for the first.
    private var inFlight: [String: Task<[TitleAwardRecord], Error>] = [:]
    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("TitleAwardCredits", isDirectory: true)
    }

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
        // Kept on the phone a week (none found too), so a title page doesn't ask Wikidata every time.
        let file = Self.folder?.appendingPathComponent(key.replacingOccurrences(of: ":", with: "-") + ".json")
        if let file, let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate, Date.now.timeIntervalSince(date) < 604_800,
           let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([TitleAwardRecord].self, from: data) {
            cachedPeople[key] = (date, saved)
            return saved
        }
        if let running = inFlight[key] { return try await running.value }
        // Not tied to the screen that asked: leaving the page doesn't throw away a 15-second answer.
        let request = Task { try await Self.fetchPeople(property: property, value: value) }
        inFlight[key] = request
        defer { inFlight[key] = nil }
        let rows = try await request.value
        if cachedPeople.count >= 200 { cachedPeople.removeAll(keepingCapacity: true) }
        cachedPeople[key] = (.now, rows)
        if let folder = Self.folder, let file, let data = try? JSONEncoder().encode(rows) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return rows
    }

    private static func fetchPeople(property: String, value: String) async throws -> [TitleAwardRecord] {
        let query = """
        SELECT ?awardLabel ?whoLabel ?date ?familyLabel ?won WHERE {
          { SELECT (SAMPLE(?candidate) AS ?work) WHERE { ?candidate wdt:\(property) "\(value)" } HAVING(COUNT(DISTINCT ?candidate) = 1) }
          ?s pq:P1686 ?work .
          { ?who p:P166 ?s . ?s ps:P166 ?award . BIND(true AS ?won) }
          UNION { ?who p:P1411 ?s . ?s ps:P1411 ?award . BIND(false AS ?won) }
          FILTER NOT EXISTS { ?s wikibase:rank wikibase:DeprecatedRank }
          OPTIONAL { ?s pq:P585 ?date }
          OPTIONAL { ?award wdt:P361 ?family }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
        }
        """
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")
        parts?.queryItems = [.init(name: "query", value: query), .init(name: "format", value: "json")]
        guard let url = parts?.url else { throw APIError.message("The credits request is unavailable.") }
        // Wikidata can take 15 seconds on a title it hasn't answered lately (Parasite took 14),
        // then answers the same question at once: a long wait, and one more try.
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue("TwilDiary/1.0 (iOS app)", forHTTPHeaderField: "User-Agent")
        var answer: Data?
        for attempt in 0..<2 where answer == nil {
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                answer = data
            }
            try Task.checkCancellation()
        }
        guard let data = answer else { throw APIError.message("Individual award credits couldn’t be loaded.") }
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
            // The ceremony from the award's family, else its own name (AwardNames).
            return AwardNames.normalized(.init(year: year, ceremony: label("familyLabel") ?? "Other awards", category: category,
                                               won: won, recipient: person))
        }
        return rows
    }
}
