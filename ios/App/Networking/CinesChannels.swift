import Foundation

/// Cines' second source (owner's call, 25 Nov 2026, as the anime.com app does): the official
/// YouTube channels themselves, for the scenes, clips and Shorts TMDB doesn't list. Each channel's
/// public feeds are read, with no key or quota: its newest uploads
/// (`feeds/videos.xml?channel_id=UC…`) and its newest Shorts (the `UUSH…` playlist), about 15 each.
/// A video only joins the feed when its title names a show or film that TMDB confirms
/// (`CinesFeed`), so Plan still adds the right title; channel promos and the like are left out.
enum CinesChannels {
    struct Channel: Sendable, Hashable {
        let name: String
        let id: String
        /// An anime channel: its videos are matched to anime only.
        let anime: Bool
    }
    struct Video: Sendable {
        let id: String
        let title: String
        let short: Bool
        let channel: Channel
    }

    /// The channel ids were read from each channel's page (25 Nov 2026).
    static let all: [Channel] = [
        Channel(name: "Netflix", id: "UCWOA1ZGywLbqmigxE4Qlvuw", anime: false),
        Channel(name: "Netflix K-Content", id: "UCpiCK8c6PBktcxq7Az_t4RQ", anime: false),
        Channel(name: "Prime Video", id: "UCQJWtTnAHhEG5w4uN0udnUQ", anime: false),
        Channel(name: "Disney+", id: "UCIrgJInjLS2BhlHOMDW7v0g", anime: false),
        Channel(name: "HBO", id: "UCVTQuK2CaWaTgSsoNkn5AiQ", anime: false),
        Channel(name: "Apple TV", id: "UC1Myj674wRVXB9I4c6Hm5zA", anime: false),
        Channel(name: "Hulu", id: "UCE5mQnNl8Q4H2qcv4ikaXeA", anime: false),
        Channel(name: "Paramount+", id: "UCrRttZIypNTA1Mrfwo745Sg", anime: false),
        Channel(name: "Peacock", id: "UCPgMAS8woHJ_o_OZdTR7kcQ", anime: false),
        Channel(name: "A24", id: "UCuPivVjnfNo4mb3Oog_frZg", anime: false),
        Channel(name: "Universal Pictures", id: "UCq0OueAsdxH6b8nyAspwViw", anime: false),
        Channel(name: "Sony Pictures", id: "UCz97F7dMxBNOfGYu3rx8aCw", anime: false),
        Channel(name: "Marvel", id: "UCvC4D8onUfXzvjTOM-dBfEA", anime: false),
        Channel(name: "Netflix Anime", id: "UCBSs9x2KzSLhyyA9IKyt4YA", anime: true),
        Channel(name: "Crunchyroll", id: "UC6pGDc4bFGD1_36IKv3FnYg", anime: true),
        Channel(name: "Muse Asia", id: "UCGbshtvS9t-8CW11W7TooQg", anime: true),
        Channel(name: "Aniplex USA", id: "UCDb0peSmF5rLX7BvuTcJfCw", anime: true),
        Channel(name: "TOHO animation", id: "UC14Yc2Qv92DMuyNRlHvpo2Q", anime: true),
        Channel(name: "GKIDS", id: "UCJXUTDi2Lc8Qub4bxICcPCA", anime: true),
    ]

    /// A channel's newest Shorts and uploads (a Short is in both; it's kept once, as a Short).
    nonisolated static func videos(_ channel: Channel) async -> [Video] {
        async let shorts = entries("playlist_id=UUSH" + channel.id.dropFirst(2))
        async let uploads = entries("channel_id=" + channel.id)
        let short = await shorts
        let shortIDs = Set(short.map(\.id))
        var found = short.map { Video(id: $0.id, title: $0.title, short: true, channel: channel) }
        for entry in await uploads where !shortIDs.contains(entry.id) {
            found.append(Video(id: entry.id, title: entry.title, short: false, channel: channel))
        }
        return found
    }

    nonisolated private static func entries(_ query: String) async -> [(id: String, title: String)] {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?" + query) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let xml = String(data: data, encoding: .utf8) else { return [] }
        return parse(xml)
    }

    /// The feed's entries: each one's video id and title.
    nonisolated static func parse(_ xml: String) -> [(id: String, title: String)] {
        xml.components(separatedBy: "<entry>").dropFirst().compactMap { entry in
            guard let id = between(entry, "<yt:videoId>", "</yt:videoId>"),
                  id.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil,
                  let title = between(entry, "<title>", "</title>") else { return nil }
            return (id, decode(title))
        }
    }
    nonisolated private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }
    nonisolated static func decode(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
    }

    // MARK: Names in a video's title

    /// The names a video's title may hold, likeliest first: its hashtags ("#BlueBox" → "Blue Box")
    /// for a Short, the parts between "|" ("Scene | Kakegurui | Clip | Netflix Anime" → "Scene",
    /// "Kakegurui"; words like Clip, Trailer and channel names are dropped), and a title in
    /// capitals inside a sentence ("… THE MOSQUITO BOWL premieres …"). "Season 3" and a trailing
    /// number ("Stranger Things 5") are taken off as a second try.
    nonisolated static func names(in title: String, short: Bool) -> [String] {
        var found: [String] = []
        func add(_ value: String) {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "!?'"))))
            guard name.count >= 2, name.count <= 70, name.rangeOfCharacter(from: .letters) != nil,
                  !found.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            found.append(name)
        }
        let tags = matches(#"#([\p{L}\p{N}_]+)"#, in: title).map(spaced)
        if short { tags.forEach(add) }
        var text = title.replacingOccurrences(of: #"#[\p{L}\p{N}_]+"#, with: "", options: .regularExpression)
        text = text.unicodeScalars.filter { !$0.properties.isEmojiPresentation && $0 != "\u{FE0F}" }.map(String.init).joined()
        var parts = text.components(separatedBy: "|")
        if parts.count == 1 {
            parts = text.components(separatedBy: " - ").flatMap { $0.components(separatedBy: " – ") }.flatMap { $0.components(separatedBy: " — ") }
        }
        for part in parts where !noise(part) {
            let clean = part.replacingOccurrences(of: #"\((?:19|20)\d\d\)"#, with: "", options: .regularExpression)
            add(clean)
            let bare = clean.replacingOccurrences(of: #"(?i)\s+(season|part|cour)\s+\d+.*$|\s+s\d+$|\s+\d{1,2}$"#, with: "", options: .regularExpression)
            if bare != clean { add(bare) }
        }
        for caps in matches(#"\b([A-Z][A-Z0-9'’&:]+(?:\s+[A-Z0-9'’&:]+){1,6})\b"#, in: text) where !noise(caps) { add(caps) }
        if !short { tags.forEach(add) }
        return Array(found.prefix(4))
    }

    /// A part that is a label, not a name: Clip, Official Trailer, "Netflix Anime", "Now Streaming"…
    nonisolated private static func noise(_ part: String) -> Bool {
        let value = comparable(part)
        if value.isEmpty { return true }
        let channels = Set(all.map { comparable($0.name) } + ["netflix", "netflix anime", "crunchyroll", "disney", "max", "hbo max", "prime"])
        if channels.contains(value) { return true }
        let labels = ["trailer", "teaser", "clip", "clips", "official", "featurette", "now streaming", "streaming now", "opening", "ending",
                      "english dub", "english sub", "dub", "sub", "subbed", "dubbed", "behind the scenes", "first look", "sneak peek", "recap",
                      "shorts", "on netflix", "only on netflix"]
        let words = Set(value.split(separator: " ").map(String.init))
        if labels.contains(where: { $0.contains(" ") ? value.contains($0) : words.contains($0) }) { return true }
        return false
    }

    /// For comparing names: lowercase, no accents, letters and digits only, single spaces.
    nonisolated static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: " and ")
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        return kept.split(separator: " ").joined(separator: " ")
    }

    /// "TheHuntingWives" → "The Hunting Wives", "sparks_of_tomorrow" → "sparks of tomorrow".
    nonisolated static func spaced(_ tag: String) -> String {
        let underscored = tag.replacingOccurrences(of: "_", with: " ")
        return underscored.replacingOccurrences(of: #"(?<=[a-z0-9])(?=[A-Z])"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let group = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            return Range(group, in: text).map { String(text[$0]) }
        }
    }

    /// Whether a TMDB name is the name in a video's title: the same, or (for TMDB's best match
    /// only) one inside the other when the shorter has two words or more ("STEEL BALL RUN JoJo's
    /// Bizarre Adventure" and "JoJo's Bizarre Adventure"), or TMDB's name starting with it
    /// ("Frieren" and "Frieren: Beyond Journey's End").
    nonisolated static func same(_ query: String, _ name: String, best: Bool) -> Bool {
        let a = comparable(query), b = comparable(name)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard best else { return false }
        let shorter = a.count < b.count ? a : b, longer = a.count < b.count ? b : a
        if shorter.split(separator: " ").count >= 2, (" " + longer + " ").contains(" " + shorter + " ") { return true }
        return a.count >= 5 && b.hasPrefix(a + " ")
    }
}
