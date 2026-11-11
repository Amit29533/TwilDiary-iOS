import Foundation
import TwilDiaryCore

/// More pictures for a profile than the server's list, read straight from this iPhone:
/// - TMDB's own photo lists for a person (every portrait, then posters and stills they're tagged
///   in), with your TMDB key;
/// - Wikimedia Commons, through the person's Wikidata entry (found by TMDB person ID);
/// - MyAnimeList's picture sets through Jikan (a free, keyless MyAnimeList API) for voice actors
///   and anime characters, found by name and, for characters, checked against the anime.
/// A request carries only a name or a numeric ID, nothing from the diary. Answers (including
/// "nothing found") are kept for the session; a failed request is asked again next time.
@MainActor final class ProfilePhotoSources {
    static let shared = ProfilePhotoSources()
    private var saved: [String: [PersonPhoto]] = [:]
    private var lastJikan = Date.distantPast
    private let session = URLSession.shared

    /// Cast: TMDB's portraits and tagged pictures, and the Commons photo.
    func cast(tmdbID: Int, token: String?) async -> [PersonPhoto] {
        let key = "cast:\(tmdbID)"
        if let cached = saved[key] { return cached }
        var photos: [PersonPhoto] = []
        var complete = true
        if let token {
            if let object = try? await TMDBDirect.object("person/\(tmdbID)/images", query: [:], token: token) {
                photos += Self.tmdbPictures(object["profiles"], kind: "portrait", aspect: 2.0 / 3.0)
            } else { complete = false }
            if let object = try? await TMDBDirect.object("person/\(tmdbID)/tagged_images", query: ["page": "1"], token: token) {
                photos += Self.tmdbPictures(object["results"], kind: nil, aspect: 16.0 / 9.0).prefix(40)
            } else { complete = false }
        }
        if let commons = await commons(tmdbID: tmdbID) { photos.append(commons) }
        if complete { saved[key] = photos }
        return photos
    }

    /// A voice actor on MyAnimeList, found by name (or their name in Japanese).
    func voiceActor(name: String, native: String?) async -> [PersonPhoto] {
        let key = "voice:" + name.lowercased()
        if let cached = saved[key] { return cached }
        guard let found = await jikan("/people", query: ["q": name, "limit": "10"]) else { return [] }
        let candidates = (found["data"] as? [[String: Any]]) ?? []
        let wanted = Self.tokens(name), wantedNative = native.map(Self.squashed)
        let matches: [[String: Any]] = candidates.filter { (person: [String: Any]) -> Bool in
            let given: String = (person["given_name"] as? String) ?? ""
            let family: String = (person["family_name"] as? String) ?? ""
            let full: String = (person["name"] as? String) ?? ""
            if Self.tokens(full) == wanted || Self.tokens(given + " " + family) == wanted { return true }
            // MyAnimeList keeps the Japanese name as family + given name.
            let kanji: String = family + given
            guard let wantedNative, !kanji.isEmpty else { return false }
            return Self.squashed(kanji) == wantedNative
        }
        let match: [String: Any]? = matches.max { (($0["favorites"] as? Int) ?? 0) < (($1["favorites"] as? Int) ?? 0) }
        guard let id = match?["mal_id"] as? Int else { saved[key] = []; return [] }
        guard let pictures = await jikan("/people/\(id)/pictures", query: [:]) else { return [] }
        let photos = Self.jikanPictures(pictures, kind: "portrait")
        saved[key] = photos
        return photos
    }

    /// An anime character on MyAnimeList: same name, and one of the same anime (so a common name
    /// like "Fern" never brings someone else's pictures).
    func character(name: String, native: String?, anime: [String]) async -> [PersonPhoto] {
        let key = "character:" + name.lowercased() + "|" + (anime.first ?? "")
        if let cached = saved[key] { return cached }
        guard let found = await jikan("/characters", query: ["q": name, "limit": "15", "order_by": "favorites", "sort": "desc"]) else { return [] }
        let candidates = (found["data"] as? [[String: Any]]) ?? []
        let wanted = Self.tokens(name), wantedNative = native.map(Self.squashed)
        let named = candidates.filter { character in
            if let full = character["name"] as? String, Self.tokens(full) == wanted { return true }
            if let kanji = character["name_kanji"] as? String, let wantedNative, Self.squashed(kanji) == wantedNative { return true }
            return false
        }
        let titles = Set(anime.map(Self.squashed).filter { !$0.isEmpty })
        var chosen: Int?
        for candidate in named.prefix(3) {
            guard let id = candidate["mal_id"] as? Int else { continue }
            guard let roles = await jikan("/characters/\(id)/anime", query: [:]) else { return [] }
            let theirs = ((roles["data"] as? [[String: Any]]) ?? []).compactMap { ($0["anime"] as? [String: Any])?["title"] as? String }.map(Self.squashed)
            if theirs.contains(where: { title in titles.contains { $0 == title || $0.contains(title) || title.contains($0) } }) { chosen = id; break }
        }
        guard let chosen else { saved[key] = []; return [] }
        guard let pictures = await jikan("/characters/\(chosen)/pictures", query: [:]) else { return [] }
        let photos = Self.jikanPictures(pictures, kind: "portrait")
        saved[key] = photos
        return photos
    }

    // MARK: Sources

    /// Wikidata's image (P18) for the person with this TMDB person ID, as a 1000 px Commons file.
    private func commons(tmdbID: Int) async -> PersonPhoto? {
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")
        parts?.queryItems = [URLQueryItem(name: "query", value: "SELECT ?img WHERE { ?p wdt:P4985 \"\(tmdbID)\" ; wdt:P18 ?img } LIMIT 1"),
                             URLQueryItem(name: "format", value: "json")]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        // Wikimedia asks automated clients to name themselves.
        request.setValue("TwilDiary/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (object["results"] as? [String: Any])?["bindings"] as? [[String: Any]],
              let file = (rows.first?["img"] as? [String: Any])?["value"] as? String,
              var commons = URLComponents(string: file.replacingOccurrences(of: "http://", with: "https://")) else { return nil }
        commons.queryItems = [URLQueryItem(name: "width", value: "1000")]
        guard let link = commons.url?.absoluteString else { return nil }
        return PersonPhoto(path: link, kind: "portrait", aspectRatio: 2.0 / 3.0, title: nil)
    }

    /// One Jikan read, spaced out (Jikan allows about three a second).
    private func jikan(_ path: String, query: [String: String]) async -> [String: Any]? {
        let wait = 0.4 - Date().timeIntervalSince(lastJikan)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        lastJikan = Date()
        var parts = URLComponents(string: "https://api.jikan.moe/v4" + path)
        if !query.isEmpty { parts?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Parsing and matching

    static func tmdbPictures(_ value: Any?, kind: String?, aspect: Double) -> [PersonPhoto] {
        ((value as? [[String: Any]]) ?? []).compactMap { item in
            guard let path = item["file_path"] as? String, CatalogTools.image(path, size: "w500") != nil else { return nil }
            let media = item["media"] as? [String: Any]
            let title = (media?["title"] as? String) ?? (media?["name"] as? String)
            let type = kind ?? ((item["image_type"] as? String) == "poster" ? "poster" : "still")
            return PersonPhoto(path: path, kind: type, aspectRatio: item["aspect_ratio"] as? Double ?? aspect, title: title)
        }
    }
    static func jikanPictures(_ object: [String: Any], kind: String) -> [PersonPhoto] {
        ((object["data"] as? [[String: Any]]) ?? []).compactMap { item in
            let jpg = item["jpg"] as? [String: Any]
            guard let link = (jpg?["large_image_url"] as? String) ?? (jpg?["image_url"] as? String), link.hasPrefix("https://") else { return nil }
            return PersonPhoto(path: link, kind: kind, aspectRatio: 0.7, title: nil)
        }
    }
    /// "Tanezaki, Atsumi" and "Atsumi Tanezaki" are the same name.
    static func tokens(_ name: String) -> [String] {
        name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.sorted()
    }
    /// Letters and digits only, lowercased: "Sousou no Frieren" → "sousounofrieren".
    static func squashed(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    /// Every source's pictures once each, in order.
    static func merge(_ lists: [PersonPhoto]...) -> [PersonPhoto] {
        var seen = Set<String>()
        return lists.flatMap { $0 }.filter { seen.insert($0.path).inserted }
    }
}

extension PersonPhoto {
    /// A TMDB path at `size`, or a full link (AniList, MyAnimeList, Commons) as it is.
    func link(size: String) -> String? {
        path.hasPrefix("https://") ? path : CatalogTools.image(path, size: size)
    }
    /// The biggest version: TMDB's original, or the full link.
    var originalURL: URL? {
        if path.hasPrefix("https://") { return URL(string: path) }
        guard CatalogTools.image(path, size: "w780") != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/original" + path)
    }
}
