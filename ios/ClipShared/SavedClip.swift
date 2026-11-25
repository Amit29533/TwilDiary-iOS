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
    var identificationHint: String?
    var attempts: Int

    struct Attachment: Codable, Equatable, Sendable {
        let file: String
        let video: Bool
    }
    var attachments: [Attachment]?
    var previewTitle: String?
    var sampledPublicVideo: Bool?

    var evidenceSummary: String {
        var items: [String] = []
        if url != nil { items.append("Link") }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != url { items.append("Caption") }
        if previewTitle != nil { items.append("Preview title") }
        if kind == .link, thumbnail != nil { items.append("Preview image") }
        if sampledPublicVideo == true { items.append("Reel frames") }
        if file != nil { items.append(kind == .video ? "Video" : "Image") }
        for attachment in attachments ?? [] { items.append(attachment.video ? "Attached video" : "Attached image") }
        return items == ["Link"] ? "Link only" : items.joined(separator: " · ")
    }

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
    enum EditError: Error { case changed }

    /// Coordinate the entire index edit across the app and share extension.
    /// A missing index starts empty; an unreadable index must never be overwritten.
    private static func edit<T>(in folder: URL?, _ change: @escaping (inout [SavedClip]) throws -> T) throws -> T {
        guard let index = folder?.appendingPathComponent("clips.json") else { throw CocoaError(.fileWriteUnknown) }
        var coordinationError: NSError?
        var outcome: Result<T, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: index, options: .forReplacing, error: &coordinationError) { url in
            outcome = Result {
                var clips: [SavedClip]
                do { clips = try decoder.decode([SavedClip].self, from: Data(contentsOf: url)) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { clips = [] }
                let value = try change(&clips)
                try encoder.encode(clips).write(to: url, options: .atomic)
                return value
            }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }

    @discardableResult static func add(_ clip: SavedClip, to folder: URL? = folder) -> Bool {
        do {
            try edit(in: folder) { clips in
                guard !clips.contains(where: { $0.id == clip.id }) else { throw EditError.changed }
                clips.insert(clip, at: 0)
            }
            return true
        } catch { return false }
    }

    /// A late identification result cannot overwrite evidence, a manual choice or a deletion.
    static func replace(_ old: SavedClip, with new: SavedClip, in folder: URL? = folder) throws {
        try edit(in: folder) { clips in
            guard old.id == new.id, let index = clips.firstIndex(of: old) else { throw EditError.changed }
            clips[index] = new
        }
    }

    static func remove(_ id: UUID, in folder: URL? = folder) throws {
        let removed = try edit(in: folder) { clips in
            guard let index = clips.firstIndex(where: { $0.id == id }) else { throw EditError.changed }
            return clips.remove(at: index)
        }
        removeFiles(of: removed, in: folder)
    }
    /// Append to an existing unresolved reel under a single coordinated index update.
    static func attach(_ source: URL, video: Bool, to id: UUID, in folder: URL) throws {
        let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? (video ? "mov" : "jpg") : source.pathExtension)
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try edit(in: folder) { clips in
                guard let i = clips.firstIndex(where: { $0.id == id }), clips[i].url != nil,
                      clips[i].state == .notFound || clips[i].state == .needsPick else {
                    throw CocoaError(.userCancelled)
                }
                clips[i].attachments = (clips[i].attachments ?? []) + [.init(file: name, video: video)]
                clips[i].state = .waiting
                clips[i].attempts = 0
                clips[i].candidates = []
                clips[i].method = nil
                clips[i].identificationHint = nil
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// A saved file's full address.
    static func url(_ name: String?, in folder: URL? = folder) -> URL? {
        guard let name, !name.isEmpty, let folder else { return nil }
        return folder.appendingPathComponent(name)
    }
    /// Takes a clip's files away with it.
    static func removeFiles(of clip: SavedClip, in folder: URL? = folder) {
        for name in [clip.file, clip.thumbnail].compactMap({ $0 }) + (clip.attachments ?? []).map(\.file) {
            if let url = url(name, in: folder) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static var encoder: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
    private static var decoder: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}

struct ClipShareInput {
    private var explicitURL: URL?
    private var parts: [String] = []

    mutating func add(url: URL?) {
        guard explicitURL == nil, let url, Self.isWebURL(url) else { return }
        explicitURL = url
    }
    mutating func add(text: String?) {
        guard let text, !text.isEmpty, !parts.contains(text) else { return }
        parts.append(text)
    }
    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
    func resolved() -> (URL?, String?) {
        let text = parts.joined(separator: "\n")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let inferred = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first(where: Self.isWebURL)
        let link = explicitURL ?? inferred
        let caption = (link.map { text.replacingOccurrences(of: $0.absoluteString, with: "") } ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (link, caption.isEmpty ? nil : caption)
    }
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

    /// One search for a title: its words, the year said with them, and how much a match counts
    /// (a tagline in quotes next to "Title (Year)" counts for less than the title itself).
    struct Search: Equatable, Sendable {
        let text: String
        var year: Int? = nil
        var weight: Double = 1
    }

    /// The searches to try for these words, best first, at most `limit`.
    static func queries(caption: String?, pageTitle: String? = nil, screenLines: [String] = [], limit: Int = 6) -> [String] {
        searches(caption: caption, pageTitle: pageTitle, screenLines: screenLines, limit: limit).map(\.text)
    }

    /// The searches to try for these words, best first, at most `limit`. A social page's wrapper
    /// ("Sulpho on Instagram: "…"") is taken off first, and each part of a caption ("…" - My Sassy
    /// Girl (2001) | Edit) is read on its own, so a title before its year is found with its year.
    static func searches(caption: String?, pageTitle: String? = nil, screenLines: [String] = [], limit: Int = 6) -> [Search] {
        var found: [Search] = []
        func keep(_ value: String, year: Int? = nil, weight: Double = 1) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            guard trimmed.count >= 2, trimmed.count <= 60, trimmed.contains(where: \.isLetter) else { return }
            if let at = found.firstIndex(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                if found[at].year == nil, let year { found[at].year = year }
                return
            }
            found.append(Search(text: trimmed, year: year, weight: weight))
        }
        let words = caption.map { unwrap($0).caption }
        let page = pageTitle.map { unwrap($0).caption }
        let text = [words, page].compactMap { $0 }.joined(separator: "\n")
        // Common caption format: "Movie: The Bear #edit".
        for match in text.matches(of: #/(?im)^\s*(?:movie|film|show|series|drama|anime|title)(?: name)?\s*[:：]\s*([^\n#@|]{2,60})/#) {
            keep(String(match.1))
        }
        // A title before its year, in each part of the caption: "My Sassy Girl (2001)", "Vivant (2023)".
        let yearPattern = #/([A-Z0-9][^\n()#@|"“”]{0,58}?)\s*[(\[]((?:19|20)\d\d)(?:\s*[-–—]\s*(?:(?:19|20)\d\d)?)?[)\]]/#
        var titled = false
        for part in parts(of: text) {
            for match in part.matches(of: yearPattern) {
                keep(String(match.1), year: Int(match.2))
                titled = true
            }
        }
        // Words beside a "Title (Year)" are mostly a tagline or the song: they count for less.
        let aside = titled ? 0.7 : 1
        // A title in quotes ("Vivant", “Vivant”, 'Vivant').
        for match in text.matches(of: #/["“”'‘’]([^"“”'‘’\n]{2,60})["“”'‘’]/#) { keep(String(match.1), weight: aside) }
        // A video page's title before " - " or " | " ("Vivant (2023) - Official Trailer").
        if let page, let first = page.split(whereSeparator: { $0 == "|" || $0 == "–" || $0 == "—" || $0 == "\n" }).first {
            let head = first.components(separatedBy: " - ").first ?? String(first)
            keep(head.replacingOccurrences(of: #"\((19|20)\d\d\)"#, with: "", options: .regularExpression), weight: aside)
        }
        // Hashtags that aren't noise: #vivant, #breakingbad, #TheBear.
        for match in text.matches(of: #/[#]([\p{L}\p{N}_]{2,40})/#) {
            let tag = String(match.1)
            guard !noise.contains(tag.lowercased()) else { continue }
            keep(spaced(tag), weight: aside)
        }
        if let words, !words.contains(where: { "#@:/!?\n".contains($0) }),
           words.split(whereSeparator: { $0.isWhitespace }).count <= 6, found.isEmpty {
            keep(words)
        }
        // Lines read off the screen: a title card or credits (short lines with letters, not subtitles' sentences).
        let screen = screenLines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && $0.count <= 40 && $0.filter(\.isLetter).count >= 3 && !$0.hasSuffix(".") && !$0.hasSuffix("?") }
            .sorted { lhs, rhs in
                let upperL = lhs == lhs.uppercased(), upperR = rhs == rhs.uppercased()
                return upperL != upperR ? upperL : lhs.count > rhs.count
            }
        for line in screen.prefix(3) { keep(line, weight: aside) }
        return Array(found.prefix(limit))
    }

    /// A caption cut at its separators: new lines, " - ", " – ", " — ", "|", "•", "·" (a dash
    /// without spaces stays: it's a year range, "(2021–2022)").
    static func parts(of text: String) -> [String] {
        var pieces = text.components(separatedBy: "\n")
        for dash in [" - ", " – ", " — "] { pieces = pieces.flatMap { $0.components(separatedBy: dash) } }
        return pieces.flatMap { $0.split(whereSeparator: { "|•·".contains($0) }).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A social page's title or description, reduced to the post's own words and its account.
    /// "Sulpho on Instagram: "…"" and "168K likes, 262 comments - sulpho.96 on August 10, 2025:
    /// "…"" (how Instagram, Threads and Facebook title a post) give the caption inside; anything
    /// else comes back as it was.
    static func unwrap(_ text: String) -> (caption: String, author: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.firstMatch(of: #/(?s)^[\d.,]+[KkMm]?\s+likes?,\s*[\d.,]+[KkMm]?\s+comments?\s*[-–]\s*([\w.]+)\s+on\s+[^:\n]{3,40}:\s*(.*)$/#) {
            return (unquote(String(match.2)), "@" + String(match.1))
        }
        if let match = trimmed.firstMatch(of: #/(?s)^[^\n]{1,80}?\s+on\s+(?:Instagram|Threads|Facebook)\s*:\s*(.*)$/#) {
            return (unquote(String(match.1)), nil)
        }
        return (trimmed, nil)
    }
    /// The wrapper's own quotes taken off the caption.
    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, let last = value.last, "\"“".contains(first), "\"”".contains(last) {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Movies and shows for a search, with how well each name fits it (and its year, when given).
    static func search(_ query: String, key: String, year: Int? = nil) async -> [SavedClip.Candidate] {
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
        return candidates(fromSearch: reply.0, query: query, year: year)
    }

    /// The results of a TMDB multi search as guesses: movies and shows whose names fit the search,
    /// more sure for a closer name and a better-known title.
    /// With a year: the title of that year counts more, one years apart much less ("My Sassy Girl
    /// (2001)" is the Korean film, not the 2008 remake).
    static func candidates(fromSearch data: Data, query: String, year: Int? = nil) -> [SavedClip.Candidate] {
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
            var confidence = min(0.95, fit * (0.7 + 0.2 * known) + (index == 0 ? 0.08 : 0))
            let date = (tv ? row["first_air_date"] : row["release_date"]) as? String
            let released = date.flatMap { Int($0.prefix(4)) }
            if let year, let released {
                confidence = abs(released - year) <= 1 ? min(0.95, confidence + 0.1) : confidence * 0.5
            }
            result.append(.init(tmdbID: id, tv: tv, name: name.isEmpty ? original : name, year: released,
                                posterPath: row["poster_path"] as? String, confidence: confidence))
        }
        return result
    }
}
