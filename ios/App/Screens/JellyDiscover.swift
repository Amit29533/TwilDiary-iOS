import SwiftUI

// MARK: Discover on JellySpace's home

/// One shelf of Discover: its heading, its titles, and the library it was drawn from (for its
/// shuffle button), or the genre for "Tonight".
struct JellyShelf: Sendable, Identifiable {
    let id: String
    let title: String
    var items: [JellyfinClient.Item]
    var library: JellyfinLibrary? = nil
    /// "Tonight: Romance": the genre's name, for See all.
    var genre: String? = nil
}

/// What JellySpace's home offers beyond the newest: genre chips, a Top 10, hidden gems (unwatched,
/// rated 7.5 or more), a genre for tonight, a random shelf from each film and show library, and
/// something from one of the plain video libraries. Drawn once a session, freshly shuffled, from
/// the libraries shown on the home only.
struct JellyDiscover: Sendable {
    var genres: [JellyfinClient.Item] = []
    var top: JellyShelf?
    var gems: [JellyfinClient.Item] = []
    var tonight: JellyShelf?
    var random: [JellyShelf] = []
    var folders: JellyShelf?

    /// Library kinds that hold videos (music, books, photos, collections and playlists don't).
    private static let videoKinds: Set<String> = ["movies", "tvshows", "homevideos", "mixed", "folders", "musicvideos"]

    /// `turn` picks which library's Top 10 and which plain library's shelf this visit shows, so they
    /// take turns.
    static func load(client: JellyfinClient, user: String?, libraries: [JellyfinLibrary], turn: Int) async -> JellyDiscover {
        let usable = libraries.filter { $0.type.map(videoKinds.contains) ?? true }
        let films = usable.filter { $0.type == "movies" || $0.type == "tvshows" }
        // A random sample of each film and show library; one where most titles have a backdrop is a
        // "rich" library (artwork, ratings, genres), the rest are shown as plain videos.
        let samples = await gather(films) { library in await random(client: client, user: user, library: library) }
        let rich = films.filter { library in
            let sample = samples[library.id] ?? []
            return !sample.isEmpty && sample.filter { !($0.BackdropImageTags ?? []).isEmpty }.count * 2 >= sample.count
        }
        let plain = usable.filter { library in !rich.contains { $0.id == library.id } }

        var found = JellyDiscover()
        found.random = rich.compactMap { library in
            guard let items = samples[library.id], !items.isEmpty else { return nil }
            return JellyShelf(id: "random-" + library.id, title: "Random from " + library.name, items: items, library: library)
        }
        // Hidden gems, the genres and the Top 10, from the rich libraries, at once.
        let topLibrary = rich.isEmpty ? nil : rich[turn % rich.count]
        async let gemLists = gather(rich) { library in
            (try? await client.discover(query(library, sort: "Random", limit: 8) + [
                URLQueryItem(name: "Filters", value: "IsUnplayed"), URLQueryItem(name: "MinCommunityRating", value: "7.5"),
                URLQueryItem(name: "ImageTypes", value: "Backdrop")], user: user)) ?? []
        }
        async let genreLists = gather(rich) { library in (try? await client.genres(in: library.id, user: user)) ?? [] }
        async let topItems = topTen(client: client, user: user, library: topLibrary)
        let gemMap = await gemLists, genreMap = await genreLists
        found.gems = Array(unique(rich.flatMap { gemMap[$0.id] ?? [] }).shuffled().prefix(14))
        var seenGenres = Set<String>()
        found.genres = Array(rich.flatMap { genreMap[$0.id] ?? [] }
            .filter { ($0.Name.map { seenGenres.insert($0.lowercased()).inserted }) ?? false }.shuffled().prefix(12))
        if let topLibrary {
            let items = await topItems
            if !items.isEmpty { found.top = JellyShelf(id: "top-" + topLibrary.id, title: "Top 10 in " + topLibrary.name, items: items, library: topLibrary) }
        }
        // Tonight: the first of the shuffled genres with enough titles that have a backdrop.
        for genre in found.genres.prefix(3) {
            guard let name = genre.Name else { continue }
            let lists = await gather(rich) { library in
                (try? await client.discover(query(library, sort: "Random", limit: 8) + [
                    URLQueryItem(name: "Genres", value: name), URLQueryItem(name: "ImageTypes", value: "Backdrop")], user: user)) ?? []
            }
            let items = unique(rich.flatMap { lists[$0.id] ?? [] }).shuffled()
            if items.count >= 4 {
                found.tonight = JellyShelf(id: "tonight-" + genre.Id, title: "Tonight: " + name, items: Array(items.prefix(12)), genre: name)
                break
            }
        }
        // Something from one plain library (your own folders of videos), a different one each visit.
        for step in 0..<plain.count {
            let library = plain[(turn + step) % plain.count]
            let items: [JellyfinClient.Item]
            if let sample = samples[library.id] { items = sample } else { items = await random(client: client, user: user, library: library) }
            if !items.isEmpty {
                found.folders = JellyShelf(id: "folders-" + library.id, title: "Something from " + library.name, items: items, library: library)
                break
            }
        }
        return found
    }

    /// A library's ten best-rated titles.
    private static func topTen(client: JellyfinClient, user: String?, library: JellyfinLibrary?) async -> [JellyfinClient.Item] {
        guard let library else { return [] }
        return (try? await client.discover(query(library, sort: "CommunityRating,SortName", limit: 10) + [
            URLQueryItem(name: "SortOrder", value: "Descending")], user: user)) ?? []
    }
    /// A fresh random shelf from one library (a shelf's shuffle button).
    static func random(client: JellyfinClient, user: String?, library: JellyfinLibrary) async -> [JellyfinClient.Item] {
        (try? await client.discover(query(library, sort: "Random", limit: 16), user: user)) ?? []
    }

    /// One library's titles in an order: films, shows, or (any other library) its videos.
    private static func query(_ library: JellyfinLibrary, sort: String, limit: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "ParentId", value: library.id), URLQueryItem(name: "SortBy", value: sort),
                     URLQueryItem(name: "Limit", value: String(limit))]
        switch library.type {
        case "movies": items.append(URLQueryItem(name: "IncludeItemTypes", value: "Movie"))
        case "tvshows": items.append(URLQueryItem(name: "IncludeItemTypes", value: "Series"))
        default:
            items.append(URLQueryItem(name: "MediaTypes", value: "Video"))
            items.append(URLQueryItem(name: "IncludeItemTypes", value: "Movie,Video,Episode,MusicVideo"))
        }
        return items
    }
    /// The same request to each library at once, the answers by library.
    private static func gather<Value: Sendable>(_ libraries: [JellyfinLibrary],
                                                _ fetch: @escaping @Sendable (JellyfinLibrary) async -> Value) async -> [String: Value] {
        await withTaskGroup(of: (String, Value).self) { group in
            for library in libraries { group.addTask { (library.id, await fetch(library)) } }
            var answers: [String: Value] = [:]
            for await (id, value) in group { answers[id] = value }
            return answers
        }
    }
    /// The first of each title (one can be in two libraries).
    private static func unique(_ items: [JellyfinClient.Item]) -> [JellyfinClient.Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.Id).inserted }
    }
}

/// A title's poster (Jellyfin's picture, else its initials), filling its frame.
struct JellyPosterImage: View {
    let item: JellyfinClient.Item
    let client: JellyfinClient
    var body: some View {
        Color.clear.overlay {
            let fallback = Artwork(path: nil, title: item.Name ?? "", initialsOnly: false)
            if let url = JellySpace.poster(item, base: client.base) { JellyfinPoster(url: url) { fallback } } else { fallback }
        }
    }
}

extension JellyfinClient {
    /// Discover's requests: any filters over the libraries, with what the cards show.
    func discover(_ query: [URLQueryItem], user: String?) async throws -> [Item] {
        var all = [URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "Fields", value: "ProviderIds,Overview,Genres")] + query
        if let user { all.append(URLQueryItem(name: "userId", value: user)) }
        let page: Page = try await get("Items", all)
        return page.Items
    }
    /// The genres used in one library (each a genre item: its name and id).
    func genres(in library: String, user: String?) async throws -> [Item] {
        var query = [URLQueryItem(name: "ParentId", value: library), URLQueryItem(name: "SortBy", value: "SortName")]
        if let user { query.append(URLQueryItem(name: "userId", value: user)) }
        let page: Page = try await get("Genres", query)
        return page.Items
    }
}
