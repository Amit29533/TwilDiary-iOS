import Foundation

/// A clip shared to TwilDiary from another app's Share button (owner's request): a reel's link,
/// the text that came with it, or a video or picture. The share sheet saves it; the app works out
/// which movie or show it is. Kept in a folder both of them can reach (the app group).
struct SavedClip: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case link, video, image, text }
    /// Where it stands: waiting for the app, being identified, identified (a confident match),
    /// waiting for you to pick the title, or not found.
    enum State: String, Codable, Sendable { case waiting, identifying, identified, needsPick, notFound }

    /// A title it may be: TMDB's id, kind and name, and how sure the guess is (0…1).
    struct Candidate: Codable, Sendable, Equatable, Identifiable, Hashable {
        var tmdbID: Int
        var tv: Bool
        var name: String
        var year: Int?
        var posterPath: String?
        var confidence: Double
        var id: String { (tv ? "tv:" : "movie:") + String(tmdbID) }
    }

    var id: UUID
    var created: Date
    var kind: Kind
    /// The shared link, if any.
    var url: String?
    /// The words that came with it: a caption, a page title, shared text.
    var text: String?
    /// The saved video or picture, a file name in the clips folder.
    var file: String?
    /// A still to show for it (a frame of the video, a link's thumbnail), a file name.
    var thumbnail: String?
    /// Where it came from: "TikTok", "YouTube", "Instagram", "Photos", or a website.
    var source: String?
    /// The account that posted it ("@jdrama.clips"), when known.
    var author: String?
    var state: State
    var candidates: [Candidate]
    /// The title you picked, or the confident match.
    var chosen: Candidate?
    /// The diary title, once it's added (or was already there).
    var titleID: String?
    /// How it was named: "caption", "text on screen", "Gemini".
    var method: String?
    /// How many times the app has tried to identify it.
    var attempts: Int

    init(kind: Kind, url: String? = nil, text: String? = nil, file: String? = nil, source: String? = nil) {
        id = UUID(); created = Date(); self.kind = kind; self.url = url; self.text = text; self.file = file
        thumbnail = nil; self.source = source; author = nil; state = .waiting; candidates = []; chosen = nil
        titleID = nil; method = nil; attempts = 0
    }

    /// A short name for the row: the chosen title, else what it is.
    var label: String {
        if let chosen { return chosen.name }
        switch kind {
        case .video: return "Video"
        case .image: return "Picture"
        case .link: return source.map { $0 == "a website" ? "Video link" : "Reel from " + $0 } ?? "Video link"
        case .text: return "Shared text"
        }
    }
}

/// Where clips are kept: `clips.json` and the saved files, in the app group's folder (shared with
/// the share sheet). A copy of the app installed without the group still keeps clips (in its own
/// folder), added there by pasting a link or picking a video.
enum ClipStore {
    static let group = "group.com.amit29533.TwilDiary"

    /// The app groups this install may have, most likely first. A sideloading tool can rename the
    /// group: AltStore and SideStore list the new name under ALTAppGroups in the app's Info.plist,
    /// and every tool leaves it in the signing profile inside the app; the built-in name is last.
    /// The share sheet looks in its own bundle and in the app's around it.
    static var groups: [String] {
        let here = Bundle.main.bundleURL
        let containing = here.pathExtension == "appex" ? Bundle(url: here.deletingLastPathComponent().deletingLastPathComponent()) : nil
        var found: [String] = []
        for bundle in [Bundle.main, containing].compactMap({ $0 }) {
            found += (bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String]) ?? []
            found += profileGroups(bundle.url(forResource: "embedded", withExtension: "mobileprovision"))
        }
        found.append(group)
        var seen = Set<String>()
        return found.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    /// The app groups named in a signing profile (a signed plist: the XML between its markers).
    static func profileGroups(_ profile: URL?) -> [String] {
        guard let profile, let data = try? Data(contentsOf: profile) else { return [] }
        return appGroups(inProfile: data)
    }
    static func appGroups(inProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// The group's clips folder; nil when this install has no app group (the share sheet then
    /// hands a link over by copying it).
    static var sharedFolder: URL? {
        for identifier in groups {
            if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return prepared(base.appendingPathComponent("Clips", isDirectory: true))
            }
        }
        return nil
    }
    /// The folder the app uses: the group's, else its own.
    static var folder: URL? {
        if let shared = sharedFolder { return shared }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return prepared(base.appendingPathComponent("Clips", isDirectory: true))
    }
    private static func prepared(_ url: URL) -> URL? {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url } catch { return nil }
    }

    /// Every clip, newest first.
    static func load(from folder: URL? = folder) -> [SavedClip] {
        guard let file = folder?.appendingPathComponent("clips.json") else { return [] }
        var clips: [SavedClip] = []
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: nil) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            clips = (try? decoder.decode([SavedClip].self, from: data)) ?? []
        }
        return clips.sorted { $0.created > $1.created }
    }
    /// Writes the list (coordinated, so the share sheet and the app don't overwrite each other).
    @discardableResult static func save(_ clips: [SavedClip], to folder: URL? = folder) -> Bool {
        guard let file = folder?.appendingPathComponent("clips.json"), let data = try? encoder.encode(clips) else { return false }
        var saved = false
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: nil) { url in
            saved = (try? data.write(to: url, options: .atomic)) != nil
        }
        return saved
    }
    /// Adds one clip to the list already there.
    @discardableResult static func add(_ clip: SavedClip, to folder: URL? = folder) -> Bool {
        guard let folder else { return false }
        var clips = load(from: folder)
        clips.removeAll { $0.id == clip.id }
        clips.insert(clip, at: 0)
        return save(clips, to: folder)
    }
    /// A saved file's full address.
    static func url(_ name: String?, in folder: URL? = folder) -> URL? {
        guard let name, !name.isEmpty, let folder else { return nil }
        return folder.appendingPathComponent(name)
    }
    /// Takes a clip's files away with it.
    static func removeFiles(of clip: SavedClip, in folder: URL? = folder) {
        for name in [clip.file, clip.thumbnail].compactMap({ $0 }) {
            if let url = url(name, in: folder) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static var encoder: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
    private static var decoder: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}

/// Reading a clip's words: where it's from, its hashtags, a title in quotes or before a year, a
/// video page's title before " - ", and lines of text read off the screen. Each becomes a search.
enum ClipText {
    /// "TikTok", "YouTube", "Instagram", "X", "Reddit", "Facebook", else "a website"; nil for no link.
    static func source(of link: String?) -> String? {
        guard let link, let host = URL(string: link)?.host?.lowercased() else { return nil }
        let known: [(String, String)] = [("tiktok", "TikTok"), ("youtube", "YouTube"), ("youtu.be", "YouTube"), ("instagram", "Instagram"),
                                         ("twitter", "X"), ("x.com", "X"), ("reddit", "Reddit"), ("facebook", "Facebook"), ("fb.watch", "Facebook")]
        return known.first { host.contains($0.0) }?.1 ?? "a website"
    }

    /// Tags that say nothing about which title it is.
    static let noise: Set<String> = [
        "fyp", "foryou", "foryoupage", "fy", "viral", "trending", "explore", "explorepage", "reels", "reel", "shorts", "short", "tiktok",
        "movie", "movies", "film", "films", "cinema", "tv", "tvshow", "series", "show", "shows", "drama", "dramas", "kdrama", "jdrama",
        "cdrama", "thaidrama", "anime", "animeedit", "edit", "edits", "scene", "scenes", "movieclips", "clips", "netflix", "hbo", "disney",
        "primevideo", "hulu", "appletv", "fyc", "recommendation", "recommendations", "mustwatch", "watchlist", "actor", "actress", "love",
        "funny", "sad", "romance", "action", "horror", "thriller", "comedy", "fypシ", "capcut", "4k", "hd", "foryourpage", "xyzbca", "viralvideo"
    ]

    /// The searches to try for these words, best first, at most `limit`.
    static func queries(caption: String?, pageTitle: String? = nil, screenLines: [String] = [], limit: Int = 6) -> [String] {
        var found: [String] = []
        func keep(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard trimmed.count >= 2, trimmed.count <= 60, trimmed.contains(where: \.isLetter) else { return }
            if !found.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { found.append(trimmed) }
        }
        let text = caption ?? ""
        // A title in quotes ("Vivant", “Vivant”, 'Vivant').
        for match in text.matches(of: #/["“”'‘’]([^"“”'‘’\n]{2,60})["“”'‘’]/#) { keep(String(match.1)) }
        // A title before its year: "Vivant (2023)".
        for match in text.matches(of: #/([A-Z0-9][^\n()#@]{1,58}?)\s*\((?:19|20)\d\d\)/#) { keep(String(match.1)) }
        // A video page's title before " - " or " | " ("Vivant (2023) - Official Trailer").
        if let page = pageTitle, let first = page.split(whereSeparator: { $0 == "|" || $0 == "–" || $0 == "—" }).first {
            let head = first.components(separatedBy: " - ").first ?? String(first)
            keep(head.replacingOccurrences(of: #"\((19|20)\d\d\)"#, with: "", options: .regularExpression))
        }
        // Hashtags that aren't noise: #vivant, #breakingbad, #TheBear.
        for match in text.matches(of: #/[#]([\p{L}\p{N}_]{2,40})/#) {
            let tag = String(match.1)
            guard !noise.contains(tag.lowercased()) else { continue }
            keep(spaced(tag))
        }
        // Lines read off the screen: a title card or credits (short lines with letters, not subtitles' sentences).
        let screen = screenLines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && $0.count <= 40 && $0.filter(\.isLetter).count >= 3 && !$0.hasSuffix(".") && !$0.hasSuffix("?") }
            .sorted { lhs, rhs in
                let upperL = lhs == lhs.uppercased(), upperR = rhs == rhs.uppercased()
                return upperL != upperR ? upperL : lhs.count > rhs.count
            }
        for line in screen.prefix(3) { keep(line) }
        return Array(found.prefix(limit))
    }

    /// "TheBear" → "The Bear", "breaking_bad" → "breaking bad"; an all-lowercase tag stays as it is.
    static func spaced(_ tag: String) -> String {
        var result = ""
        for (index, character) in tag.replacingOccurrences(of: "_", with: " ").enumerated() {
            if index > 0, character.isUppercase, let last = result.last, last.isLowercase { result.append(" ") }
            result.append(character)
        }
        return result
    }

    /// A name for comparing: lower case, no accents or punctuation.
    static func comparable(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: " and ")
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }
    /// How well a search's result fits what was searched: 1 the same name, 0.8 the name with a
    /// subtitle, 0.55 the search inside the name, else 0. Names joined without spaces (from a
    /// hashtag, "breakingbad") match too.
    static func fit(query: String, name: String) -> Double {
        let wanted = comparable(query), have = comparable(name)
        guard !wanted.isEmpty, !have.isEmpty else { return 0 }
        if wanted == have || wanted.replacingOccurrences(of: " ", with: "") == have.replacingOccurrences(of: " ", with: "") {
            // A name of one to three letters ("Up", "It") matches too much to be sure from words alone.
            return wanted.count <= 3 ? 0.6 : 1
        }
        if have.hasPrefix(wanted + " ") || wanted.hasPrefix(have + " ") && have.count >= 4 { return 0.8 }
        if wanted.count >= 4, have.contains(wanted) { return 0.55 }
        return 0
    }
}

/// Deciding from the guesses: the best few, merged by title, and whether the best is sure enough
/// to need no pick.
enum ClipRanking {
    /// The same title found more than once counts once, more sure for each way it was found.
    static func merged(_ found: [SavedClip.Candidate]) -> [SavedClip.Candidate] {
        var byID: [String: SavedClip.Candidate] = [:], order: [String] = []
        for candidate in found {
            if var kept = byID[candidate.id] {
                kept.confidence = 1 - (1 - kept.confidence) * (1 - candidate.confidence)
                if kept.posterPath == nil { kept.posterPath = candidate.posterPath }
                if kept.year == nil { kept.year = candidate.year }
                byID[candidate.id] = kept
            } else { byID[candidate.id] = candidate; order.append(candidate.id) }
        }
        return order.compactMap { byID[$0] }.sorted { $0.confidence > $1.confidence }
    }
    /// The state for these guesses (best first): identified when the best is at least 0.85 sure
    /// and well ahead of the next, a pick when there are guesses, else not found.
    static func state(for candidates: [SavedClip.Candidate]) -> SavedClip.State {
        guard let best = candidates.first else { return .notFound }
        let next = candidates.dropFirst().first?.confidence ?? 0
        return best.confidence >= 0.85 && best.confidence - next >= 0.3 ? .identified : .needsPick
    }
}

/// TMDB's search, for the share sheet (with the key built into the app) and the app (with yours).
enum ClipTMDB {
    /// The key built into this copy (TWILDIARY_TMDB_KEY when building); nil when there isn't one.
    static var builtInKey: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryTMDBKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// Movies and shows for a search, with how well each name fits it.
    static func search(_ query: String, key: String) async -> [SavedClip.Candidate] {
        var parts = URLComponents(string: "https://api.themoviedb.org/3/search/multi")!
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        // A 32-character v3 key goes in the address; a longer v4 token in the header.
        let v3 = key.count <= 40
        if v3 { items.append(URLQueryItem(name: "api_key", value: key)) }
        parts.queryItems = items
        guard let url = parts.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if !v3 { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return candidates(fromSearch: reply.0, query: query)
    }

    /// The results of a TMDB multi search as guesses: movies and shows whose names fit the search,
    /// more sure for a closer name and a better-known title.
    static func candidates(fromSearch data: Data, query: String) -> [SavedClip.Candidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["results"] as? [[String: Any]] else { return [] }
        var result: [SavedClip.Candidate] = []
        for (index, row) in rows.prefix(8).enumerated() {
            guard let type = row["media_type"] as? String, type == "movie" || type == "tv", let id = row["id"] as? Int else { continue }
            let tv = type == "tv"
            let name = (tv ? row["name"] : row["title"]) as? String ?? ""
            let original = (tv ? row["original_name"] : row["original_title"]) as? String ?? ""
            let fit = max(ClipText.fit(query: query, name: name), ClipText.fit(query: query, name: original))
            guard fit > 0 else { continue }
            let votes = Double(row["vote_count"] as? Int ?? 0)
            // Well-known titles and TMDB's own order count a little; the name counts most.
            let known = min(1, log10(votes + 1) / 4)
            let confidence = min(0.95, fit * (0.7 + 0.2 * known) + (index == 0 ? 0.08 : 0))
            let date = (tv ? row["first_air_date"] : row["release_date"]) as? String
            result.append(.init(tmdbID: id, tv: tv, name: name.isEmpty ? original : name, year: date.flatMap { Int($0.prefix(4)) },
                                posterPath: row["poster_path"] as? String, confidence: confidence))
        }
        return result
    }
}
