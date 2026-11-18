import Foundation
import TwilDiaryCore

struct TMDBAwardSubject: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, tv, person }
    let kind: Kind
    let id: Int
    var path: String { "\(kind.rawValue)/\(id)" }
}

enum TMDBAwardArchive {
    static let repository = URL(string: "https://github.com/eunaotenhoid/TMDB-awards-database")!

    private struct File: Decodable {
        struct Info: Decodable { let tmdb_award_id: Int }
        struct Entry: Decodable, Hashable {
            let category: String?
            let tmdb_id: Int?
            let media_type: String?
            let is_winner: Bool?
        }
        let award_info: Info
        let years: [String: [Entry]]
    }

    static func load(file: String, refresh: Bool) async throws -> SearchAwardArchive {
        let url = URL(string: "https://raw.githubusercontent.com/eunaotenhoid/TMDB-awards-database/main/awards/")!
            .appendingPathComponent(file + ".json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if refresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.message("Couldn’t load the TMDB-derived archive.")
        }
        let source = try JSONDecoder().decode(File.self, from: data)
        guard Int(file.prefix { $0.isNumber }) == source.award_info.tmdb_award_id else {
            throw APIError.message("The archive returned a different ceremony.")
        }
        var groups: [String: [SearchAwardNominee]] = [:]
        var nextID = 0
        for year in source.years.keys.sorted() where year.count == 4 && Int(year) != nil {
            var seen = Set<File.Entry>()
            for row in source.years[year] ?? [] where seen.insert(row).inserted {
                guard let category = row.category, !category.isEmpty, let id = row.tmdb_id, id > 0,
                      let kind = TMDBAwardSubject.Kind(rawValue: row.media_type ?? "") else { continue }
                nextID += 1
                groups[category, default: []].append(.init(id: nextID, year: year, name: nil, isWinner: row.is_winner,
                    details: nil, movie: nil, series: nil, episode: nil, character: nil, tmdb: .init(kind: kind, id: id)))
            }
        }
        guard !groups.isEmpty else { throw APIError.message("No editions are available in the TMDB-derived archive.") }
        var categories: [SearchAwardCategory] = []
        var results: [Int: SearchAwardResults] = [:]
        for (id, name) in groups.keys.sorted().enumerated() {
            // Some person nominations carry the medium only in the category name.
            let label = name.lowercased()
            let tv = ["television", "tv series", "drama series", "comedy series", "limited series"].contains(where: label.contains)
            let film = ["motion picture", "in a film"].contains(where: label.contains) && !tv
            categories.append(.init(id: id, name: name, forSeries: tv, forMovies: film))
            results[id] = .init(id: id, nominees: groups[name])
        }
        return .init(updatedAt: .now, categories: categories, results: results, failedCategoryIDs: [])
    }
}

@MainActor enum TMDBAwardLabels {
    struct LabelData: Codable {
        let title: String?
        let name: String?
        let profile_path: String?
        let poster_path: String?
    }

    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func resolve(_ subject: TMDBAwardSubject, token: String, language: String) async throws -> LabelData {
        let key = (subject.path + "/" + language) as NSString
        if let cached = cache.object(forKey: key) { return try JSONDecoder().decode(LabelData.self, from: cached as Data) }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TMDBAwardLabels", isDirectory: true)
        let suffix = language.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let file = folder?.appendingPathComponent("\(subject.kind.rawValue)-\(subject.id)-\(suffix).json")
        if let file, let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate, Date.now.timeIntervalSince(date) < 604_800,
           let saved = try? Data(contentsOf: file), let label = try? JSONDecoder().decode(LabelData.self, from: saved) {
            cache.setObject(saved as NSData, forKey: key, cost: saved.count)
            return label
        }
        let data = try await TMDBDirect.data(subject.path, query: ["language": language], token: token)
        let label = try JSONDecoder().decode(LabelData.self, from: data)
        if let compact = try? JSONEncoder().encode(label) {
            cache.setObject(compact as NSData, forKey: key, cost: compact.count)
            if let folder, let file {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? compact.write(to: file, options: .atomic)
            }
        }
        return label
    }
}
