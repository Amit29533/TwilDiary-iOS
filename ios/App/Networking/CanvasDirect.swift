import Foundation
import TwilDiaryCore

/// Canvas's Lists, read on this iPhone: Trakt's public lists with your Trakt sign-in, and their
/// posters from TMDB with your TMDB key, the way the server's /api/canvas routes build them.
/// nil when either connection is missing, so the server can still answer then.
@MainActor enum CanvasDirect {
    static let listsPerPage = 8, previewPosters = 4, itemsPerPage = 24

    /// Movies and shows on a Trakt list page, in its order, with TMDB ids and Trakt's rating.
    struct Entry: Sendable { let kind: MediaKind; let tmdb: Int; let name: String; let year: Int?; let rating: Double? }
    static func entries(_ data: Data) -> [Entry] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let type = row["type"] as? String
            guard type == "movie" || type == "show", let media = row[type!] as? [String: Any],
                  let tmdb = (media["ids"] as? [String: Any])?["tmdb"] as? Int, tmdb > 0 else { return nil }
            let rating = (media["rating"] as? Double).flatMap { $0 > 0 ? min(10, $0) : nil }
            return Entry(kind: type == "movie" ? .movie : .tv, tmdb: tmdb, name: media["title"] as? String ?? "", year: media["year"] as? Int, rating: rating)
        }
    }

    /// Poster, backdrop, name and year from TMDB for each entry (one read each, all at once).
    static func artwork(_ entries: [Entry], token: String) async -> [CanvasListItem] {
        struct Art: Sendable { let name: String?; let date: String?; let poster: String?; let backdrop: String? }
        // All at once (each waits on the network), then read in order.
        let reads = entries.map { entry in
            Task { @MainActor () -> Art? in
                guard let object = try? await TMDBDirect.object((entry.kind == .movie ? "movie/" : "tv/") + String(entry.tmdb), query: [:], token: token) else { return nil }
                return Art(name: (object["title"] as? String) ?? (object["name"] as? String),
                           date: (object["release_date"] as? String) ?? (object["first_air_date"] as? String),
                           poster: object["poster_path"] as? String, backdrop: object["backdrop_path"] as? String)
            }
        }
        var found: [Int: Art] = [:]
        for (index, read) in reads.enumerated() { if let art = await read.value { found[index] = art } }
        return entries.enumerated().map { index, entry in
            let art = found[index]
            return CanvasListItem(tmdbId: entry.tmdb, mediaType: entry.kind, name: art?.name.flatMap { $0.isEmpty ? nil : $0 } ?? entry.name,
                                  year: art?.date.flatMap { Int($0.prefix(4)) } ?? entry.year, posterPath: art?.poster, backdropPath: art?.backdrop)
        }
    }

    /// One page of lists: trending or popular, personal or official, or the lists holding a title
    /// (`title` = "tv:1396"), each with up to four posters.
    static func lists(_ query: [String: String], store: DiaryStore) async throws -> CanvasListsPage? {
        guard let token = TMDBDirect.token(store), let client = try? await TraktDirectStore.shared.client(store: store) else { return nil }
        let sort = query["sort"] ?? "trending", kind = query["kind"] ?? "personal", page = Int(query["page"] ?? "1") ?? 1
        var path = "lists/\(sort)/\(kind)"
        if let title = query["title"], let colon = title.firstIndex(of: ":"), let tmdb = Int(title[title.index(after: colon)...]) {
            let type = title.hasPrefix("tv") ? "show" : "movie"
            let found = try await client.get("search/tmdb/\(tmdb)", query: ["type": type])
            let rows = (try? JSONSerialization.jsonObject(with: found.data) as? [[String: Any]]) ?? []
            let match = rows.compactMap { $0[type] as? [String: Any] }.first { ($0["ids"] as? [String: Any])?["tmdb"] as? Int == tmdb }
            guard let trakt = (match?["ids"] as? [String: Any])?["trakt"] as? Int else { return CanvasListsPage(lists: [], page: page, totalPages: 1) }
            path = "\(type)s/\(trakt)/lists/\(kind)/\(sort)"
        }
        let reply = try await client.get(path, query: ["page": String(page), "limit": String(listsPerPage)])
        let rows = (try? JSONSerialization.jsonObject(with: reply.data) as? [[String: Any]]) ?? []
        let found: [(id: Int, name: String, user: String, count: Int, likes: Int)] = rows.prefix(listsPerPage).compactMap { row in
            // Trending and popular wrap each list; a title's lists are the list objects themselves.
            let list = row["list"] as? [String: Any] ?? row
            guard let id = (list["ids"] as? [String: Any])?["trakt"] as? Int, id > 0,
                  let name = list["name"] as? String, !name.isEmpty, list["privacy"] as? String != "private" else { return nil }
            let user = list["user"] as? [String: Any]
            return (id, name, (user?["username"] as? String) ?? (user?["name"] as? String) ?? "", list["item_count"] as? Int ?? 0, list["likes"] as? Int ?? 0)
        }
        // A failed preview leaves the card without posters rather than failing the page.
        let posters = await withTaskGroup(of: (Int, [String]).self) { group in
            for list in found {
                group.addTask {
                    guard let items = try? await client.get("lists/\(list.id)/items/movie,show", query: ["page": "1", "limit": String(previewPosters)]) else { return (list.id, []) }
                    let art = await artwork(Array(entries(items.data).prefix(previewPosters)), token: token)
                    return (list.id, art.compactMap(\.posterPath))
                }
            }
            var all: [Int: [String]] = [:]
            for await (id, paths) in group { all[id] = paths }
            return all
        }
        let lists = found.map { CanvasList(id: $0.id, name: $0.name, user: $0.user, itemCount: $0.count, likes: $0.likes, posters: posters[$0.id] ?? []) }
        return CanvasListsPage(lists: lists, page: page, totalPages: min(max(reply.pageCount, 1), 50))
    }

    /// One page of a list's titles, with Trakt's rating for each from the same read.
    static func items(list: Int, page: Int, store: DiaryStore) async throws -> (page: CanvasListItemsPage, ratings: [String: Double])? {
        guard let token = TMDBDirect.token(store), let client = try? await TraktDirectStore.shared.client(store: store) else { return nil }
        let reply = try await client.get("lists/\(list)/items/movie,show", query: ["page": String(page), "limit": String(itemsPerPage), "extended": "full"])
        let rows = Array(entries(reply.data).prefix(itemsPerPage))
        var ratings: [String: Double] = [:]
        for row in rows { if let rating = row.rating { ratings[row.kind.rawValue + ":" + String(row.tmdb)] = rating } }
        let items = await artwork(rows, token: token)
        return (CanvasListItemsPage(items: items, page: page, totalPages: min(max(reply.pageCount, 1), 50)), ratings)
    }
}
