import Foundation
import TwilDiaryCore

/// Canvas's Lists, read on this iPhone: Trakt's public lists with your Trakt sign-in, and their
/// posters from TMDB with your TMDB key, the way the server's /api/canvas routes build them.
/// nil when either connection is missing, so the server can still answer then.
@MainActor enum CanvasDirect {
    nonisolated static let listsPerPage = 8, previewPosters = 4, itemsPerPage = 24

    /// Movies and shows on a Trakt list page, in its order, with TMDB ids and Trakt's rating.
    struct Entry: Sendable { let kind: MediaKind; let tmdb: Int; let name: String; let year: Int?; let rating: Double? }
    /// Parsed away from the main thread (a nonisolated async function runs on the shared pool),
    /// so a page landing while you scroll doesn't hold up a frame.
    nonisolated static func parsedEntries(_ data: Data) async -> [Entry] { entries(data) }
    nonisolated static func entries(_ data: Data) -> [Entry] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let type = row["type"] as? String
            guard type == "movie" || type == "show", let media = row[type!] as? [String: Any],
                  let tmdb = (media["ids"] as? [String: Any])?["tmdb"] as? Int, tmdb > 0 else { return nil }
            let rating = (media["rating"] as? Double).flatMap { $0 > 0 ? min(10, $0) : nil }
            return Entry(kind: type == "movie" ? .movie : .tv, tmdb: tmdb, name: media["title"] as? String ?? "", year: media["year"] as? Int, rating: rating)
        }
    }

    /// Poster, backdrop, name and year from TMDB for each entry (one read each, all at once), read
    /// and kept away from the main thread: Canvas's Lists stuttered while 30-odd TMDB replies a
    /// page were read on it, and again every time the tab came back.
    static func artwork(_ entries: [Entry], token: String) async -> [CanvasListItem] {
        let found = await withTaskGroup(of: (Int, CanvasArt?).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { (index, await CanvasArtCache.shared.art(entry.kind, entry.tmdb, token: token)) }
            }
            var all: [Int: CanvasArt] = [:]
            for await (index, art) in group { if let art { all[index] = art } }
            return all
        }
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
        let found = await listRows(reply.data)
        // A failed preview leaves the card without posters rather than failing the page.
        let posters = await withTaskGroup(of: (Int, [String]).self) { group in
            for list in found {
                group.addTask {
                    guard let items = try? await client.get("lists/\(list.id)/items/movie,show", query: ["page": "1", "limit": String(previewPosters)]) else { return (list.id, []) }
                    let art = await artwork(Array(await parsedEntries(items.data).prefix(previewPosters)), token: token)
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

    struct ListRow: Sendable { let id: Int; let name: String; let user: String; let count: Int; let likes: Int }
    /// A page of lists from Trakt, parsed away from the main thread.
    nonisolated static func listRows(_ data: Data) async -> [ListRow] {
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return rows.prefix(listsPerPage).compactMap { row in
            // Trending and popular wrap each list; a title's lists are the list objects themselves.
            let list = row["list"] as? [String: Any] ?? row
            guard let id = (list["ids"] as? [String: Any])?["trakt"] as? Int, id > 0,
                  let name = list["name"] as? String, !name.isEmpty, list["privacy"] as? String != "private" else { return nil }
            let user = list["user"] as? [String: Any]
            return ListRow(id: id, name: name, user: (user?["username"] as? String) ?? (user?["name"] as? String) ?? "",
                           count: list["item_count"] as? Int ?? 0, likes: list["likes"] as? Int ?? 0)
        }
    }

    /// One page of a list's titles, with Trakt's rating for each from the same read.
    static func items(list: Int, page: Int, store: DiaryStore) async throws -> (page: CanvasListItemsPage, ratings: [String: Double])? {
        guard let token = TMDBDirect.token(store), let client = try? await TraktDirectStore.shared.client(store: store) else { return nil }
        let reply = try await client.get("lists/\(list)/items/movie,show", query: ["page": String(page), "limit": String(itemsPerPage), "extended": "full"])
        let rows = Array(await parsedEntries(reply.data).prefix(itemsPerPage))
        var ratings: [String: Double] = [:]
        for row in rows { if let rating = row.rating { ratings[row.kind.rawValue + ":" + String(row.tmdb)] = rating } }
        let items = await artwork(rows, token: token)
        return (CanvasListItemsPage(items: items, page: page, totalPages: min(max(reply.pageCount, 1), 50)), ratings)
    }
}

/// TMDB's name, date, poster and backdrop for one title.
struct CanvasArt: Sendable { let name: String?; let date: String?; let poster: String?; let backdrop: String? }

/// TMDB details for Canvas, read and parsed off the main thread and kept for the session, so a
/// list (or a title on another list) seen once shows at once.
actor CanvasArtCache {
    static let shared = CanvasArtCache()
    private var values: [String: CanvasArt] = [:]
    func art(_ kind: MediaKind, _ tmdb: Int, token: String) async -> CanvasArt? {
        let path = (kind == .movie ? "movie/" : "tv/") + String(tmdb)
        if let known = values[path] { return known }
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        // A 32-character v3 key goes in api_key; a v4 read token in the Authorization header.
        let apiKey = token.count == 32 && token.allSatisfy(\.isHexDigit)
        if apiKey { components.queryItems = [URLQueryItem(name: "api_key", value: token)] }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let art = CanvasArt(name: (object["title"] as? String) ?? (object["name"] as? String),
                            date: (object["release_date"] as? String) ?? (object["first_air_date"] as? String),
                            poster: object["poster_path"] as? String, backdrop: object["backdrop_path"] as? String)
        if values.count >= 3_000 { values.removeAll(keepingCapacity: true) }
        values[path] = art
        return art
    }
}
