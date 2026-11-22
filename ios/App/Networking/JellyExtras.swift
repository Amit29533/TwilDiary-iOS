import Foundation

// MARK: Signing in (JellySpace as a Jellyfin user, not the server's API key)

/// Jellyfin's sign-in: a user's name and password, or Quick Connect (a code typed into another
/// signed-in Jellyfin app). Both answer with that user and an access token, which then stands in
/// for the API key in JellySpace.
enum JellyAuth {
    struct Session: Decodable, Sendable {
        struct User: Decodable, Sendable { let Id: String; let Name: String? }
        let User: User
        let AccessToken: String
    }
    struct QuickCode: Decodable, Sendable { let Code: String; let Secret: String }
    private struct QuickState: Decodable, Sendable { let Authenticated: Bool }

    static func signIn(_ base: URL, name: String, password: String) async throws -> Session {
        try await send(base, "Users/AuthenticateByName", body: ["Username": name, "Pw": password])
    }
    static func quickConnectEnabled(_ base: URL) async -> Bool {
        let enabled: Bool? = try? await send(base, "QuickConnect/Enabled", method: "GET")
        return enabled ?? false
    }
    static func startQuickConnect(_ base: URL) async throws -> QuickCode {
        try await send(base, "QuickConnect/Initiate", method: "POST")
    }
    /// True once the code has been approved in another Jellyfin app.
    static func approved(_ base: URL, secret: String) async -> Bool {
        let state: QuickState? = try? await send(base, "QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)], method: "GET")
        return state?.Authenticated == true
    }
    /// Ends a session on the server: its token is no good there any more.
    static func signOut(_ base: URL, token: String) async {
        var request = URLRequest(url: base.appending(path: "Sessions/Logout"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(JellyDevice.header + ", Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
    static func finishQuickConnect(_ base: URL, secret: String) async throws -> Session {
        try await send(base, "Users/AuthenticateWithQuickConnect", body: ["Secret": secret])
    }

    private static func send<T: Decodable & Sendable>(_ base: URL, _ path: String, query: [URLQueryItem] = [], body: [String: String]? = nil,
                                                     method: String = "POST") async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(JellyDevice.header, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.message(status == 401 ? "That name or password isn't right." : "Jellyfin answered \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: JellySpace's extra Jellyfin requests

extension JellyfinClient {
    /// A user on the server (the API key may list them all).
    struct Profile: Decodable, Sendable, Identifiable {
        let Id: String
        let Name: String?
        var id: String { Id }
    }
    func profiles() async throws -> [Profile] { try await get("Users") }
    /// A title's trailer files and its special features (behind the scenes, deleted scenes…).
    func extras(_ id: String, user: String?) async -> [Item] {
        let query = user.map { [URLQueryItem(name: "userId", value: $0)] } ?? []
        async let trailers: [Item]? = try? get("Items/\(id)/LocalTrailers", query)
        async let features: [Item]? = try? get("Items/\(id)/SpecialFeatures", query)
        return ((await trailers) ?? []) + ((await features) ?? [])
    }
    /// One version of a film (when it's stored in more than one quality).
    func streamURL(_ id: String, source: String?) -> URL? {
        guard let source, let plain = streamURL(id), var components = URLComponents(url: plain, resolvingAgainstBaseURL: false) else { return streamURL(id) }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "mediaSourceId", value: source)]
        return components.url
    }
    /// Playback told to Jellyfin as a session (only a signed-in user can): "start", "progress" or
    /// "stop". The server then shows it under Activity and its plugins (ListenBrainz…) see the plays.
    func report(_ event: String, item: String, source: String?, seconds: Double, paused: Bool = false) async {
        var body: [String: Any] = ["ItemId": item, "PositionTicks": Int64(max(0, seconds) * 10_000_000), "IsPaused": paused,
                                   "CanSeek": true, "PlayMethod": "DirectPlay"]
        if let source { body["MediaSourceId"] = source }
        let path = event == "start" ? "Sessions/Playing" : event == "stop" ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress"
        try? await post(path, [], body: body)
    }
    /// A song's words, each line with when it starts (when the file has timed lyrics).
    struct Lyrics: Decodable, Sendable {
        struct Line: Codable, Sendable { let Text: String?; let Start: Int64? }
        let Lyrics: [Line]?
    }
    func lyrics(_ id: String) async -> [Lyrics.Line] {
        let found: Lyrics? = try? await get("Audio/\(id)/Lyrics")
        return found?.Lyrics ?? []
    }
    /// A music library's album artists.
    func artists(in library: String, user: String?) async throws -> [Item] {
        var query = [URLQueryItem(name: "ParentId", value: library), URLQueryItem(name: "SortBy", value: "SortName"),
                     URLQueryItem(name: "Limit", value: "2000")]
        if let user { query.append(URLQueryItem(name: "userId", value: user)) }
        let page: Page = try await get("Artists/AlbumArtists", query)
        return page.Items
    }
    /// Every episode of a show, in order.
    func allEpisodes(of series: String, user: String?) async throws -> [Item] {
        var query = [URLQueryItem(name: "Fields", value: "ProviderIds,PrimaryImageAspectRatio")]
        if let user { query.append(URLQueryItem(name: "userId", value: user)) }
        let page: Page = try await get("Shows/\(series)/Episodes", query)
        return page.Items
    }
    /// A subtitle found by the server's subtitle providers (OpenSubtitles).
    struct RemoteSubtitle: Decodable, Sendable, Identifiable {
        let Id: String
        let Name: String?
        let ProviderName: String?
        let Format: String?
        let DownloadCount: Int?
        let IsHashMatch: Bool?
        var id: String { Id }
    }
    func searchSubtitles(_ item: String, language: String) async throws -> [RemoteSubtitle] {
        try await get("Items/\(item)/RemoteSearch/Subtitles/\(language)", [URLQueryItem(name: "isPerfectMatch", value: "false")])
    }
    /// Saves the subtitle next to the video on the server (it then shows among its subtitles).
    func downloadSubtitle(_ item: String, subtitle: String) async throws {
        try await post("Items/\(item)/RemoteSearch/Subtitles/\(subtitle)", [], body: nil)
    }
    /// A song as it is.
    func audioURL(_ id: String) -> URL? {
        var components = URLComponents(url: base.appending(path: "Audio/\(id)/stream"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "api_key", value: key)]
        return components?.url
    }
}

extension JellyfinClient.Segment {
    init(kind: String, start: Double, end: Double) {
        self.kind = kind
        StartTicks = Int64(start * 10_000_000)
        EndTicks = Int64(end * 10_000_000)
    }
}

// MARK: IntroDB (intro, recap and credits times when the server has none)

/// The community intro database (introdb.app): free to read, no key. Asked by IMDb id (the show's,
/// with the season and episode, or the film's) only when Jellyfin has no times for the video.
enum IntroDB {
    private struct Times: Decodable { let start_sec: Double; let end_sec: Double }
    private struct Answer: Decodable { let intro: Times?; let recap: Times?; let outro: Times? }

    static func segments(imdb: String, season: Int?, episode: Int?) async -> [JellyfinClient.Segment] {
        var components = URLComponents(string: "https://api.introdb.app/segments")!
        var query = [URLQueryItem(name: "imdb_id", value: imdb)]
        if let season, let episode {
            query += [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))]
        } else {
            query.append(URLQueryItem(name: "is_movie", value: "true"))
        }
        components.queryItems = query
        guard let url = components.url, let fetched = try? await URLSession.shared.data(from: url),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200, let answer = try? JSONDecoder().decode(Answer.self, from: fetched.0) else { return [] }
        return [("Intro", answer.intro), ("Recap", answer.recap), ("Outro", answer.outro)].compactMap { kind, times in
            guard let times, times.end_sec > times.start_sec else { return nil }
            return JellyfinClient.Segment(kind: kind, start: times.start_sec, end: times.end_sec)
        }
    }
}

// MARK: Jellyseerr / Overseerr (asking for what isn't on the server)

/// A Jellyseerr (or Overseerr) server: search TMDB through it and request a film or show.
struct JellySeerr: Sendable {
    let base: URL
    let key: String

    struct Result: Decodable, Sendable, Identifiable {
        struct Info: Decodable, Sendable { let status: Int? }
        let id: Int
        let mediaType: String
        let title: String?
        let name: String?
        let posterPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let mediaInfo: Info?
        var label: String { title ?? name ?? "" }
        var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
        /// 2 pending, 3 processing, 4 partly available, 5 available.
        var status: Int { mediaInfo?.status ?? 1 }
    }
    private struct Page: Decodable { let results: [Result] }

    func search(_ text: String) async throws -> [Result] {
        let page: Page = try await send("search", query: [URLQueryItem(name: "query", value: text), URLQueryItem(name: "page", value: "1")])
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }
    func request(_ result: Result) async throws {
        var body: [String: Any] = ["mediaType": result.mediaType, "mediaId": result.id]
        if result.mediaType == "tv" { body["seasons"] = "all" }
        let _: Ignored = try await send("request", body: body)
    }
    /// Checks the address and key.
    func check() async throws {
        let _: Ignored = try await send("auth/me")
    }
    private struct Ignored: Decodable {}

    private func send<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        var components = URLComponents(url: base.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.message(status == 401 || status == 403 ? "Jellyseerr didn't accept that key." : "Jellyseerr answered \(status).")
        }
        if data.isEmpty, let empty = try? JSONDecoder().decode(T.self, from: Data("{}".utf8)) { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: The home's Next up and For you

extension JellyfinClient {
    /// The next episode of each show you're following (the first episode of shows you haven't
    /// started is left out, and so are ones you've started: they're in Continue Watching).
    func nextUp(user: String) async throws -> [Item] {
        let page: Page = try await get("Shows/NextUp", [URLQueryItem(name: "userId", value: user), URLQueryItem(name: "Limit", value: "20"),
                                                       URLQueryItem(name: "Fields", value: "ProviderIds,PrimaryImageAspectRatio"),
                                                       URLQueryItem(name: "disableFirstEpisode", value: "true"),
                                                       URLQueryItem(name: "enableResumable", value: "false")])
        return page.Items
    }
    /// One group of Jellyfin's film recommendations: why ("SimilarToRecentlyPlayed"), from what
    /// ("Your Name"), and the films.
    struct Recommendation: Decodable, Sendable {
        let Items: [Item]?
        let RecommendationType: String?
        let BaselineItemName: String?
    }
    /// Recommendations from one library (Jellyfin otherwise mixes in every library, hidden ones too).
    func recommendations(user: String, library: String) async throws -> [Recommendation] {
        try await get("Movies/Recommendations", [URLQueryItem(name: "userId", value: user), URLQueryItem(name: "parentId", value: library),
                                                 URLQueryItem(name: "categoryLimit", value: "4"), URLQueryItem(name: "itemLimit", value: "12"),
                                                 URLQueryItem(name: "Fields", value: "ProviderIds,Genres,PrimaryImageAspectRatio")])
    }
}
