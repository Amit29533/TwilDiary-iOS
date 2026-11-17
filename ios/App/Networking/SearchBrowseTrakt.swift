import Foundation
import TwilDiaryCore

@MainActor enum SearchBrowseTrakt {
    private struct Person: Decodable, Sendable {
        struct IDs: Decodable, Sendable { let tmdb: Int? }
        let name: String
        let ids: IDs
    }

    private struct Credits: Decodable, Sendable {
        struct Cast: Decodable, Sendable { let person: Person }
        struct Crew: Decodable, Sendable { let person: Person; let jobs: [String]?; let job: String? }
        let cast: [Cast]?
        let crew: [String: [Crew]]?
    }

    private struct Trending: Decodable, Sendable {
        struct Title: Decodable, Sendable {
            struct IDs: Decodable, Sendable { let trakt: Int }
            let ids: IDs
        }
        let movie: Title?
        let show: Title?
    }

    private struct Charts: Sendable {
        let actors: [SearchBrowsePerson]
        let directors: [SearchBrowsePerson]
    }

    private static var cached: (client: String, date: Date, charts: Charts)?
    private static var pending: (client: String, id: UUID, task: Task<Charts, Error>)?

    static func people(for shelf: SearchBrowseShelf, store: DiaryStore) async throws -> [SearchBrowsePerson] {
        if store.isPreview { return SearchBrowsePerson.selections(for: shelf) }
        guard let client = ProviderAppIDs.id(for: .trakt) else {
            throw APIError.message("Trakt’s public catalog is unavailable.")
        }
        if let cached, cached.client == client, Date.now.timeIntervalSince(cached.date) < 1800 {
            return shelf == .directors ? cached.charts.directors : cached.charts.actors
        }
        let request: (client: String, id: UUID, task: Task<Charts, Error>)
        if let pending, pending.client == client { request = pending }
        else {
            request = (client, UUID(), Task { try await load(client: client) })
            pending = request
        }
        defer { if pending?.id == request.id { pending = nil } }
        let charts = try await request.task.value
        if pending?.id == request.id { cached = (client, .now, charts) }
        try Task.checkCancellation()
        return shelf == .directors ? charts.directors : charts.actors
    }

    private static func load(client: String) async throws -> Charts {
        async let films = chart("movies", client: client)
        async let shows = chart("shows", client: client)
        let results = await (films, shows)
        guard results.0 != nil || results.1 != nil else {
            throw APIError.message("Couldn’t load current Trakt credits.")
        }
        let credits = (results.0 ?? []) + (results.1 ?? [])
        if credits.isEmpty { throw APIError.message("No credits returned from the current Trakt charts.") }
        return Charts(
            actors: ranked(credits.map { ($0.cast ?? []).prefix(12).map(\.person) }),
            directors: ranked(credits.map { credit in
                (credit.crew?["directing"] ?? []).filter { member in
                    (member.jobs ?? member.job.map { [$0] } ?? []).contains {
                        ["director", "series director"].contains($0.lowercased())
                    }
                }.map(\.person)
            })
        )
    }

    // The public trending endpoints and public credits are GETs. No account token is sent.
    nonisolated private static func chart(_ path: String, client: String) async -> [Credits]? {
        guard let response = try? await TraktDirectClient.publicRead(path + "/trending", query: ["limit": "4"], clientID: client),
              let titles = try? JSONDecoder().decode([Trending].self, from: response.data) else { return nil }
        let ids = titles.prefix(4).compactMap { ($0.movie ?? $0.show)?.ids.trakt }.filter { $0 > 0 }
        return await withTaskGroup(of: (Int, Credits?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    guard let reply = try? await TraktDirectClient.publicRead("\(path)/\(id)/people", clientID: client) else {
                        return (index, nil)
                    }
                    return (index, try? JSONDecoder().decode(Credits.self, from: reply.data))
                }
            }
            var ordered: [(Int, Credits)] = []
            for await (index, result) in group { if let result { ordered.append((index, result)) } }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func ranked(_ credits: [[Person]]) -> [SearchBrowsePerson] {
        var entries: [Int: (person: SearchBrowsePerson, count: Int, order: Int)] = [:]
        var order = 0
        for people in credits {
            var seen = Set<Int>()
            for person in people {
                guard let id = person.ids.tmdb, id > 0, !person.name.isEmpty, seen.insert(id).inserted else { continue }
                if let entry = entries[id] { entries[id] = (entry.person, entry.count + 1, entry.order) }
                else {
                    entries[id] = (SearchBrowsePerson(id: id, name: person.name), 1, order)
                    order += 1
                }
            }
        }
        return entries.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
            .map(\.person)
    }
}
