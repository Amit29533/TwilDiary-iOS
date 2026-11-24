import SwiftUI
import UIKit
import AVFoundation
import Vision
import TwilDiaryCore

/// Saved clips in the app (owner's request: share a reel, TwilDiary works out the title): the list,
/// kept in step with the share sheet's file, and the work of naming each new clip. Cheapest first:
/// the words that came with it (and a TikTok or YouTube post's caption), the text on screen in a
/// saved video, then Gemini looking at a few frames. Nothing enters the diary until you pick.
@MainActor @Observable final class ClipInbox {
    static let shared = ClipInbox()
    private(set) var clips: [SavedClip] = []
    private var running = false
    /// Settings: Gemini may look at a clip's frames (on unless turned off).
    static let geminiKey = "clips.gemini"
    static var geminiAllowed: Bool { UserDefaults.standard.object(forKey: geminiKey) as? Bool ?? true }

    private init() { clips = ClipStore.load() }

    /// Clips waiting for you to pick their title.
    var toPick: [SavedClip] { clips.filter { $0.state == .needsPick } }
    /// The clips kept with a title.
    func clips(tmdbID: Int, tv: Bool) -> [SavedClip] {
        clips.filter { $0.chosen?.tmdbID == tmdbID && $0.chosen?.tv == tv }
    }

    func reload() {
        let fresh = ClipStore.load()
        if fresh != clips { clips = fresh }
    }

    /// Names every clip that's waiting (the share sheet saves them; the app does the work).
    func process(store: DiaryStore) async {
        reload()
        guard !running else { return }
        running = true
        defer { running = false }
        // A clip left "identifying" (the app was closed mid-way) is tried again, at most three times.
        for clip in clips where (clip.state == .waiting || clip.state == .identifying) && clip.attempts < 3 {
            var working = clip
            working.state = .identifying
            save(working)
            let named = await ClipIdentifier.identify(working, store: store)
            guard !Task.isCancelled else { return }
            save(named)
        }
    }

    /// Writes one clip (newest list from the file first, so one the share sheet just added stays).
    func save(_ clip: SavedClip) {
        var all = ClipStore.load()
        if let index = all.firstIndex(where: { $0.id == clip.id }) { all[index] = clip } else { all.insert(clip, at: 0) }
        ClipStore.save(all)
        clips = all.sorted { $0.created > $1.created }
    }
    func remove(_ clip: SavedClip) {
        ClipStore.removeFiles(of: clip)
        let all = ClipStore.load().filter { $0.id != clip.id }
        ClipStore.save(all)
        clips = all
    }

    /// The clipboard's version last pasted (Search stops offering a link once it's added).
    static let pastedKey = "clips.pastedChange"

    /// A pasted link (and any words around it), for an install where the share sheet can't hand over.
    func add(pasted text: String, store: DiaryStore) async {
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: Self.pastedKey)
        let link = Self.firstLink(in: text)
        let rest = text.replacingOccurrences(of: link ?? "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard link != nil || !rest.isEmpty else { return }
        save(SavedClip(kind: link == nil ? .text : .link, url: link, text: rest.isEmpty ? nil : rest, source: ClipText.source(of: link)))
        await process(store: store)
    }
    /// A video or picture picked from Photos.
    func add(media data: Data, video: Bool, store: DiaryStore) async {
        guard let folder = ClipStore.folder else { return }
        let name = UUID().uuidString + (video ? ".mov" : ".jpg")
        guard (try? data.write(to: folder.appendingPathComponent(name))) != nil else { return }
        var clip = SavedClip(kind: video ? .video : .image, file: name, source: "Photos")
        if !video { clip.thumbnail = name }
        save(clip)
        await process(store: store)
    }

    /// You picked the title: kept with the clip, and added to Planned when you asked (or already
    /// in your diary). Returns the diary title, if there is one.
    @discardableResult func choose(_ candidate: SavedClip.Candidate, for clip: SavedClip, addToPlanned: Bool, store: DiaryStore) async -> String? {
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
        save(updated)
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
        clip.attempts += 1
        var pageTitle: String?
        // 1. A TikTok or YouTube post: its caption, account and thumbnail, from their public lookup.
        if let url = clip.url, let post = await ClipLinks.post(url) {
            pageTitle = post.title
            if clip.author == nil { clip.author = post.author }
            if clip.thumbnail == nil, let picture = post.thumbnail, let data = await ClipLinks.download(picture), let folder = ClipStore.folder {
                let name = clip.id.uuidString + "-thumb.jpg"
                if (try? data.write(to: folder.appendingPathComponent(name))) != nil { clip.thumbnail = name }
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
        } else if let still = ClipStore.url(clip.thumbnail), let data = try? Data(contentsOf: still) {
            frames = [data]
        }
        guard let token = TMDBDirect.token(store) else {
            clip.state = .notFound
            return clip
        }
        // 3. The words, then the text on screen, searched on TMDB.
        var found: [SavedClip.Candidate] = []
        for query in ClipText.queries(caption: clip.text, pageTitle: pageTitle) {
            found += await ClipTMDB.search(query, key: token)
        }
        let fromWords = !found.isEmpty
        for query in ClipText.queries(caption: nil, screenLines: lines, limit: 3) {
            found += await ClipTMDB.search(query, key: token).map { var guess = $0; guess.confidence *= 0.9; return guess }
        }
        var ranked = ClipRanking.merged(found)
        var method: String? = ranked.isEmpty ? nil : fromWords ? "caption" : "text on screen"
        // 4. Gemini, when the words aren't enough and it's allowed.
        if ClipRanking.state(for: ranked) != .identified, ClipInbox.geminiAllowed, !SemanticSearch.keys.isEmpty,
           !frames.isEmpty || clip.text?.isEmpty == false || pageTitle != nil {
            let guesses = await ClipGemini.guesses(frames: frames, words: [clip.text, pageTitle].compactMap { $0 }.joined(separator: "\n"),
                                                  screen: lines, source: clip.source)
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
                if ranked.first?.id != before || method == nil { method = "Gemini" }
            }
        }
        clip.candidates = Array(ranked.prefix(3))
        clip.state = ClipRanking.state(for: clip.candidates)
        clip.method = method
        if clip.state == .identified, let best = clip.candidates.first {
            clip.chosen = best
            clip.titleID = ClipInbox.libraryTitle(for: best, store: store)
        }
        return clip
    }
}

/// A post's caption, account and thumbnail from TikTok's and YouTube's public oEmbed lookups.
/// Instagram's needs a Meta developer key, so its posts keep only what the share handed over.
enum ClipLinks {
    struct Post: Sendable { let title: String?; let author: String?; let thumbnail: URL? }

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
        var frames: [Data] = [], lines: [String] = []
        for image in images {
            guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) else { continue }
            frames.append(data)
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
