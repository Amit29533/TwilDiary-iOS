import SwiftUI
import UIKit
import AVFoundation
import Vision
import LinkPresentation
import TwilDiaryCore

/// Saved clips in the app (owner's request: share a reel, TwilDiary works out the title): the list,
/// kept in step with the share sheet's file, and the work of naming each new clip. Cheapest first:
/// the words that came with it (and a TikTok or YouTube post's caption), the text on screen in a
/// saved video, then Gemini looking at a few frames. Nothing enters the diary until you pick.
@MainActor @Observable final class ClipInbox {
    static let shared = ClipInbox()
    private(set) var clips: [SavedClip] = []
    private var worker: Task<Void, Never>?
    /// Settings: Gemini may look at a clip's frames (on unless turned off).
    static let geminiKey = "clips.gemini"
    static var geminiAllowed: Bool { UserDefaults.standard.object(forKey: geminiKey) as? Bool ?? true }

    private let folderOverride: URL?
    private var folder: URL? { folderOverride ?? ClipStore.folder }
    private let identify: @MainActor (SavedClip, DiaryStore) async -> SavedClip

    init(folder: URL? = nil, identify: @escaping @MainActor (SavedClip, DiaryStore) async -> SavedClip = ClipIdentifier.identify) {
        folderOverride = folder
        self.identify = identify
        clips = ClipStore.load(from: folder ?? ClipStore.folder)
    }

    /// Clips waiting for you to pick their title.
    var toPick: [SavedClip] { clips.filter { $0.state == .needsPick } }
    /// The clips kept with a title.
    func clips(tmdbID: Int, tv: Bool) -> [SavedClip] {
        clips.filter { $0.chosen?.tmdbID == tmdbID && $0.chosen?.tv == tv }
    }

    func reload() {
        let fresh = ClipStore.load(from: folder)
        if fresh != clips { clips = fresh }
    }

    /// Names every clip that's waiting (the share sheet saves them; the app does the work).
    func process(store: DiaryStore) async {
        if let worker { await worker.value; return }
        let task = Task { @MainActor in
            await drain(store: store)
        }
        worker = task
        await task.value
    }

    /// Re-read the durable queue after each result. A retry transitions the clip back to
    /// waiting even if this worker already visited its ID earlier in the same run.
    private func drain(store: DiaryStore) async {
        defer { worker = nil }
        while !Task.isCancelled {
            reload()
            guard let clip = clips.first(where: { $0.state == .waiting || $0.state == .identifying }) else { return }
            var working = clip
            do {
                if working.attempts >= 3 {
                    working.state = .notFound
                    working.identificationHint = "Identification was interrupted. Try identifying this clip again."
                    try ClipStore.replace(clip, with: working, in: folder)
                    continue
                }
                working.state = .identifying
                working.attempts += 1
                try ClipStore.replace(clip, with: working, in: folder)
                reload()
                let named = await identify(working, store)
                try ClipStore.replace(working, with: named, in: folder)
            } catch ClipStore.EditError.changed {
                continue
            } catch {
                reload()
                return
            }
        }
    }

    func retry(_ id: UUID, store: DiaryStore) async {
        guard let old = clips.first(where: { $0.id == id }), old.state == .notFound else { return }
        var queued = old
        queued.state = .waiting
        queued.attempts = 0
        do { try ClipStore.replace(old, with: queued, in: folder) } catch { reload(); return }
        reload()
        await process(store: store)
    }

    func remove(_ clip: SavedClip) {
        try? ClipStore.remove(clip.id, in: folder)
        reload()
    }

    /// A pasted link (and any words around it), for an install where the share sheet can't hand over.
    func add(pasted text: String, store: DiaryStore) async {
        let link = Self.firstLink(in: text)
        let rest = text.replacingOccurrences(of: link ?? "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard link != nil || !rest.isEmpty else { return }
        ClipStore.add(SavedClip(kind: link == nil ? .text : .link, url: link, text: rest.isEmpty ? nil : rest, source: ClipText.source(of: link)), to: folder)
        await process(store: store)
    }
    /// A video or picture picked from Photos.
    func add(media data: Data, video: Bool, store: DiaryStore) async {
        guard let folder else { return }
        let name = UUID().uuidString + (video ? ".mov" : ".jpg")
        guard (try? data.write(to: folder.appendingPathComponent(name))) != nil else { return }
        var clip = SavedClip(kind: video ? .video : .image, file: name, source: "Photos")
        if !video { clip.thumbnail = name }
        guard ClipStore.add(clip, to: folder) else {
            ClipStore.removeFiles(of: clip, in: folder)
            return
        }
        await process(store: store)
    }

    /// You picked the title: kept with the clip, and added to Planned when you asked (or already
    /// in your diary). Returns the diary title, if there is one.
    @discardableResult func choose(_ candidate: SavedClip.Candidate, for clip: SavedClip, addToPlanned: Bool, store: DiaryStore) async throws -> String? {
        var updated = clip
        updated.chosen = candidate
        updated.state = .identified
        if updated.method == nil { updated.method = "you" }
        var titleID = Self.libraryTitle(for: candidate, store: store)
        if titleID == nil, addToPlanned {
            let route = CatalogRoute(kind: candidate.tv ? .tv : .movie, id: candidate.tmdbID)
            if let browse = try? await store.browse(route) {
                titleID = await store.importTitle(browse.details, category: browse.details.suggestedCategory)
            }
        }
        updated.titleID = titleID
        try ClipStore.replace(clip, with: updated, in: folder)
        reload()
        return titleID
    }

    /// The diary title for a guess, when it's already in your library.
    static func libraryTitle(for candidate: SavedClip.Candidate, store: DiaryStore) -> String? {
        store.activeTitles.first { $0.tmdbId == candidate.tmdbID && $0.isSeries == candidate.tv }?.id
    }
    nonisolated static func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url?.absoluteString
    }
}

/// Naming one clip.
@MainActor enum ClipIdentifier {
    static func identify(_ input: SavedClip, store: DiaryStore) async -> SavedClip {
        var clip = input
        clip.identificationHint = nil
        var pageTitle = clip.previewTitle
        // 1. A TikTok or YouTube post: its caption, account and thumbnail, from their public lookup.
        if let url = clip.url, let post = await ClipLinks.post(url) {
            pageTitle = post.title ?? pageTitle
            if clip.author == nil { clip.author = post.author }
            if clip.thumbnail == nil, let picture = post.thumbnail, let data = await ClipLinks.download(picture), let folder = ClipStore.folder {
                let name = clip.id.uuidString + "-thumb.jpg"
                if (try? data.write(to: folder.appendingPathComponent(name))) != nil { clip.thumbnail = name }
            }
        }
        // 1b. Any other link (an Instagram reel, a Threads or Facebook post, a web page): its public
        // page as a signed-out phone browser gets it, the caption taken out of the page's wrapper
        // ("Sulpho on Instagram: "…""), its account and its picture (as mymind reads a saved link).
        // The system link preview when the page gives nothing.
        if clip.url.map({ ClipText.source(of: $0) != "TikTok" && ClipText.source(of: $0) != "YouTube" }) == true,
           let url = clip.url.flatMap(URL.init(string:)) {
            if let page = await ClipPage.read(url) {
                let fromTitle = page.title.map(ClipText.unwrap), fromDescription = page.description.map(ClipText.unwrap)
                if let described = fromDescription, described.author != nil {
                    pageTitle = described.caption
                    if clip.author == nil { clip.author = described.author }
                } else if let title = fromTitle?.caption, !title.isEmpty {
                    pageTitle = title
                }
                if clip.thumbnail == nil, let picture = page.image, let data = await ClipLinks.download(picture), let folder = ClipStore.folder {
                    let name = clip.id.uuidString + "-preview.jpg"
                    if (try? data.write(to: folder.appendingPathComponent(name))) != nil { clip.thumbnail = name }
                }
            } else if ClipLinks.isInstagramPost(url), let preview = await ClipLinks.instagramPreview(url) {
                pageTitle = preview.title.map { ClipText.unwrap($0).caption } ?? pageTitle
                if clip.thumbnail == nil, let data = preview.image, let folder = ClipStore.folder {
                    let name = clip.id.uuidString + "-preview.jpg"
                    if (try? data.write(to: folder.appendingPathComponent(name))) != nil { clip.thumbnail = name }
                }
            }
        }
        // 2. A saved video's frames (or the picture) and the text on them; a link's thumbnail for Gemini.
        var frames: [Data] = [], lines: [String] = []
        if clip.kind == .video || clip.kind == .image, let file = ClipStore.url(clip.file) {
            let reading = await ClipFrames.read(file, video: clip.kind == .video)
            frames = reading.frames; lines = reading.lines
            if clip.thumbnail == nil, let first = frames.first, let folder = ClipStore.folder {
                let name = clip.id.uuidString + "-still.jpg"
                if (try? first.write(to: folder.appendingPathComponent(name))) != nil { clip.thumbnail = name }
            }
        } else if let still = ClipStore.url(clip.thumbnail) {
            let reading = await ClipFrames.read(still, video: false)
            frames = reading.frames; lines = reading.lines
        }
        if clip.kind == .link, clip.attachments?.isEmpty != false,
           let url = clip.url.flatMap(URL.init(string:)), ClipLinks.isInstagramPost(url) {
            clip.sampledPublicVideo = false
            let reel = await PublicReel.read(url)
            if pageTitle == nil, let caption = reel.caption { pageTitle = ClipText.unwrap(caption).caption }
            if let video = reel.reading {
                frames = video.frames
                lines = video.lines + lines.filter { !video.lines.contains($0) }
                clip.sampledPublicVideo = true
            }
        }
        clip.previewTitle = pageTitle
        // Prioritize the latest evidence within the existing four-frame Gemini budget.
        var evidenceFrames: [Data] = [], evidenceLines: [String] = []
        for item in (clip.attachments ?? []).reversed().prefix(4) {
            guard let url = ClipStore.url(item.file) else { continue }
            let reading = await ClipFrames.read(url, video: item.video)
            evidenceFrames.append(contentsOf: reading.frames.prefix(4 - evidenceFrames.count))
            for line in reading.lines where !evidenceLines.contains(line) { evidenceLines.append(line) }
        }
        frames = Array((evidenceFrames + frames).prefix(4))
        lines = evidenceLines + lines.filter { !evidenceLines.contains($0) }
        guard let token = TMDBDirect.token(store) else {
            clip.state = .notFound
            clip.identificationHint = "TMDB is unavailable. Check the TMDB key in Settings and try again."
            return clip
        }
        // 3 and 4 together (as mymind reads a saved link with AI, and then some): Gemini reads the
        // words, the picture and the frames for every clip it's allowed to, while the words and the
        // text on screen are searched on TMDB, each search with the year said beside its title.
        // Both land on TMDB's titles: when they agree the title is sure; when they don't, you pick.
        let words = [ClipText.unwrap(clip.text ?? "").caption, pageTitle, clip.author.map { "Posted by " + $0 }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let asksGemini = ClipInbox.geminiAllowed && !SemanticSearch.keys.isEmpty && (!frames.isEmpty || !words.isEmpty)
        let shownFrames = frames, screenText = lines, source = clip.source
        async let asked = asksGemini ? ClipGemini.guesses(frames: shownFrames, words: words, screen: screenText, source: source) : []
        var found: [SavedClip.Candidate] = []
        for search in ClipText.searches(caption: clip.text, pageTitle: pageTitle) {
            found += await ClipTMDB.search(search.text, key: token, year: search.year).map { var guess = $0; guess.confidence *= search.weight; return guess }
        }
        let fromWords = !found.isEmpty
        for search in ClipText.searches(caption: nil, screenLines: lines, limit: 3) {
            found += await ClipTMDB.search(search.text, key: token).map { var guess = $0; guess.confidence *= 0.9; return guess }
        }
        var ranked = ClipRanking.merged(found)
        var method: String? = ranked.isEmpty ? nil : fromWords ? "caption" : "text on screen"
        let guesses = await asked
        if !guesses.isEmpty {
            var named: [SavedClip.Candidate] = []
            for guess in guesses {
                let suggestion = SemanticSearch.Suggestion(title: guess.title, year: guess.year, type: guess.type, why: "")
                if let item = await SemanticSearch.find(suggestion, token: token) {
                    named.append(.init(tmdbID: item.id, tv: item.mediaType == .tv, name: item.name, year: item.year,
                                       posterPath: item.posterPath, confidence: min(0.95, max(0.05, guess.confidence))))
                }
            }
            if !named.isEmpty {
                let before = ranked.first?.id
                ranked = ClipRanking.merged(found + named)
                if method == nil || ranked.first?.id != before { method = "Gemini" }
                else if named.contains(where: { $0.id == before }) { method = (method ?? "caption") + " and Gemini" }
            }
        }
        clip.candidates = Array(ranked.prefix(3))
        clip.state = ClipRanking.state(for: clip.candidates)
        if clip.state == .notFound, clip.kind == .link, clip.attachments?.isEmpty != false, frames.isEmpty, (clip.text ?? "").isEmpty, pageTitle == nil {
            clip.identificationHint = "Twil couldn’t read the video or find a caption or preview image. Add a screenshot or the video from Photos to identify the scene."
        }
        clip.method = method
        if clip.state == .identified, let best = clip.candidates.first {
            clip.chosen = best
            clip.titleID = ClipInbox.libraryTitle(for: best, store: store)
        }
        return clip
    }
}

/// A post's caption, account and thumbnail from TikTok's and YouTube's public oEmbed lookups.
/// Instagram's needs a Meta developer key; its posts are read from their public page (ClipPage).
enum ClipLinks {
    struct Post: Sendable { let title: String?; let author: String?; let thumbnail: URL? }

    struct Preview: Sendable { let title: String?; let image: Data? }

    static func isInstagramPost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "instagram.com" || host.hasSuffix(".instagram.com") else { return false }
        return true
    }

    static func instagramPreview(_ url: URL) async -> Preview? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        defer { withExtendedLifetime(provider) {} }
        return await withCheckedContinuation { continuation in
            provider.startFetchingMetadata(for: url) { metadata, _ in
                guard let metadata else { continuation.resume(returning: nil); return }
                let title = metadata.title.flatMap { value -> String? in
                    let boilerplate = ["instagram", "login", "log in", "login instagram", "instagram login"]
                    return boilerplate.contains(ClipText.comparable(value)) ? nil : value
                }
                guard let image = metadata.imageProvider, image.canLoadObject(ofClass: UIImage.self) else {
                    continuation.resume(returning: Preview(title: title, image: nil)); return
                }
                _ = image.loadObject(ofClass: UIImage.self) { object, _ in
                    let thumbnail = (object as? UIImage)?.preparingThumbnail(of: CGSize(width: 768, height: 768))
                    continuation.resume(returning: Preview(title: title, image: thumbnail?.jpegData(compressionQuality: 0.75)))
                }
            }
        }
    }

    static func post(_ link: String) async -> Post? {
        guard let source = ClipText.source(of: link), source == "TikTok" || source == "YouTube" else { return nil }
        var parts = URLComponents(string: source == "TikTok" ? "https://www.tiktok.com/oembed" : "https://www.youtube.com/oembed")!
        parts.queryItems = [URLQueryItem(name: "url", value: link)] + (source == "YouTube" ? [URLQueryItem(name: "format", value: "json")] : [])
        guard let url = parts.url, let reply = try? await URLSession.shared.data(from: url),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(reply.0)
    }
    /// The oEmbed reply's title, author ("@name") and thumbnail.
    nonisolated static func parse(_ data: Data) -> Post? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let author = (root["author_unique_id"] as? String ?? root["author_name"] as? String).map { $0.hasPrefix("@") ? $0 : "@" + $0 }
        return Post(title: root["title"] as? String, author: author, thumbnail: (root["thumbnail_url"] as? String).flatMap(URL.init(string:)))
    }
    static func download(_ url: URL) async -> Data? {
        guard let reply = try? await URLSession.shared.data(from: url), (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              reply.0.count < 3_000_000 else { return nil }
        return reply.0
    }
}

/// A public page's Open Graph data, read as a signed-out phone browser gets it: no cookies, no
/// sign-in, the page's own HTML (what mymind and link previews read). For an Instagram reel it's
/// "Sulpho on Instagram: "…"" with the caption, the picture and the account.
enum ClipPage {
    struct Meta: Sendable, Equatable {
        var title: String?
        var description: String?
        var image: URL?
        var video: URL?
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func read(_ url: URL) async -> Meta? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.prefix(2).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        // The head is enough; a link to a big file stops at 3 MB.
        guard let reply = try? await session.bytes(for: request), let response = reply.1 as? HTTPURLResponse,
              response.statusCode == 200, response.mimeType?.contains("html") == true else { return nil }
        var data = Data()
        do {
            for try await byte in reply.0 {
                data.append(byte)
                if data.count >= 3_000_000 { break }
            }
        } catch { if data.isEmpty { return nil } }
        let meta = parse(String(decoding: data, as: UTF8.self))
        return meta.title == nil && meta.description == nil && meta.image == nil ? nil : meta
    }

    /// The page's og: and twitter: tags (a description's own tag when there's no og:description),
    /// with HTML's escapes undone.
    nonisolated static func parse(_ html: String) -> Meta {
        var tags: [String: String] = [:]
        for tag in html.matches(of: #/<meta\s[^>]*>/#.ignoresCase()) {
            let text = String(tag.0)
            guard let key = text.firstMatch(of: #/(?:property|name)\s*=\s*["']([^"']+)["']/#.ignoresCase())?.1.lowercased(),
                  let value = text.firstMatch(of: #/content\s*=\s*"([^"]*)"/#.ignoresCase())?.1 ?? text.firstMatch(of: #/content\s*=\s*'([^']*)'/#.ignoresCase())?.1,
                  tags[key] == nil else { continue }
            tags[key] = decode(String(value))
        }
        func first(_ keys: String...) -> String? { keys.lazy.compactMap { tags[$0] }.first { !$0.isEmpty } }
        let secure = { (value: String?) in value.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } }
        return Meta(title: first("og:title", "twitter:title"),
                    description: first("og:description", "twitter:description", "description"),
                    image: secure(first("og:image", "og:image:secure_url", "twitter:image")),
                    video: secure(first("og:video:secure_url", "og:video:url", "og:video")))
    }

    /// &quot; &amp; &#39; &#x27; and the rest.
    nonisolated static func decode(_ text: String) -> String {
        var result = text
        for (code, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: code, with: character)
        }
        result = result.replacing(#/&#(x?)([0-9A-Fa-f]{1,6});/#) { match in
            let value = UInt32(String(match.2), radix: match.1.isEmpty ? 10 : 16)
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? String(match.0)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Frames from a saved video (or the picture itself), small enough to send, and the text on them.
enum ClipFrames {
    struct Reading: Sendable { let frames: [Data]; let lines: [String] }

    nonisolated static func read(_ file: URL, video: Bool) async -> Reading {
        var images: [CGImage] = []
        if video {
            let asset = AVURLAsset(url: file)
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 768, height: 768)
            // Four moments through it (a title card is often near the start or the end).
            let moments = seconds > 1 ? [0.08, 0.35, 0.62, 0.9].map { $0 * seconds } : [0]
            for moment in moments {
                if let frame = try? await generator.image(at: CMTime(seconds: moment, preferredTimescale: 600)) { images.append(frame.image) }
            }
        } else if let picture = UIImage(contentsOfFile: file.path)?.cgImage {
            images = [picture]
        }
        return await recognize(images.compactMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.7) })
    }

    nonisolated static func recognize(_ frames: [Data]) async -> Reading {
        var lines: [String] = []
        for data in frames {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let found = try? await request.perform(on: data) {
                for line in found.compactMap({ $0.topCandidates(1).first?.string }) where !lines.contains(line) { lines.append(line) }
            }
        }
        return Reading(frames: frames, lines: lines)
    }
}

/// Gemini's guesses for a clip: up to three titles with how sure it is, from the frames and the words.
@MainActor enum ClipGemini {
    struct Guess: Decodable, Sendable { let title: String; let year: Int?; let type: String; let confidence: Double }

    static func guesses(frames: [Data], words: String, screen: [String], source: String?) async -> [Guess] {
        guard let key = SemanticSearch.keys.first else { return [] }
        let note = [
            words.isEmpty ? nil : "Caption or title: " + words,
            screen.isEmpty ? nil : "Text seen on screen: " + screen.prefix(12).joined(separator: " / "),
            source.map { "Shared from: " + $0 },
        ].compactMap { $0 }.joined(separator: "\n")
        var parts: [[String: Any]] = [["text": note.isEmpty ? "Which movie or TV show is this from?" : note]]
        for frame in frames.prefix(4) {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": frame.base64EncodedString()]])
        }
        let instruction = """
        You identify which movie or TV show a short clip comes from, using its frames and the words \
        that came with it (a caption, hashtags, on-screen text). Reply with up to 3 real titles, most \
        likely first, each with its original English name as TMDB lists it, its first release year, \
        type "movie" or "tv", and confidence from 0 to 1 that the clip is from it. Judge from the scene, \
        setting, costumes, on-screen text and words; don't name or describe the people in it. If you \
        can't tell, reply with an empty list.
        """
        let schema: [String: Any] = [
            "type": "ARRAY",
            "items": [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"], "year": ["type": "INTEGER"],
                    "type": ["type": "STRING", "enum": ["movie", "tv"]], "confidence": ["type": "NUMBER"],
                ],
                "required": ["title", "type", "confidence"],
            ] as [String: Any],
        ]
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instruction]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": schema, "temperature": 0.2] as [String: Any],
        ]
        guard let data = try? await SemanticSearch.generate(body, key: key, geminiOnly: true),
              let text = try? SemanticSearch.answerText(data) else { return [] }
        return decode(text)
    }
    nonisolated static func decode(_ text: String) -> [Guess] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        return Array(((try? JSONDecoder().decode([Guess].self, from: Data(trimmed.utf8))) ?? []).prefix(3))
    }
}
