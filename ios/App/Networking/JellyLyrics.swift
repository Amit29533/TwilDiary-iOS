import Foundation

/// A song's words for Now Playing: your Jellyfin server's first (an .lrc file or lyrics in the
/// file's tags); else LRCLIB (lrclib.net, free, no account), asked from the phone with the song's
/// title, artist, album and length only, and kept on the phone so the next time needs no request.
@MainActor enum JellyLyrics {
    typealias Line = JellyfinClient.Lyrics.Line

    static func find(_ track: JellyfinClient.Item, client: JellyfinClient) async -> [Line] {
        let server = await client.lyrics(track.Id)
        if !server.isEmpty { return server }
        guard UserDefaults.standard.object(forKey: JellyPrefs.lrclibKey) as? Bool ?? true else { return [] }
        if let saved = saved(track.Id) { return saved }
        guard let title = track.Name, let artist = track.AlbumArtist ?? track.Artists?.first else { return [] }
        guard let found = await LRCLIB.lines(title: title, artist: artist, album: track.Album,
                                             seconds: track.RunTimeTicks.map { Double($0) / 10_000_000 }) else { return [] }
        save(found, for: track.Id)
        return found
    }

    // Kept on the phone, one small file per song (an empty list remembers that LRCLIB had none).
    private static var folder: URL { URL.applicationSupportDirectory.appending(path: "Jellyfin/Lyrics") }
    private static func saved(_ song: String) -> [Line]? {
        guard let data = try? Data(contentsOf: folder.appending(path: song + ".json")) else { return nil }
        return try? JSONDecoder().decode([Line].self, from: data)
    }
    private static func save(_ lines: [Line], for song: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lines) { try? data.write(to: folder.appending(path: song + ".json"), options: .atomic) }
    }
}

/// LRCLIB's read API: the exact song first (by title, artist, album and length), then a search.
/// Timed lyrics (LRC) come back with each line's start; plain ones without; an instrumental says so.
enum LRCLIB {
    private struct Answer: Decodable { let syncedLyrics: String?; let plainLyrics: String?; let instrumental: Bool? }

    /// nil when the request failed (asked again next time); empty when LRCLIB has no words for it.
    static func lines(title: String, artist: String, album: String?, seconds: Double?) async -> [JellyfinClient.Lyrics.Line]? {
        var exact = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album { exact.append(URLQueryItem(name: "album_name", value: album)) }
        if let seconds, seconds > 0 { exact.append(URLQueryItem(name: "duration", value: String(Int(seconds.rounded())))) }
        switch await fetch("get", exact) {
        case .found(let data):
            if let answer = try? JSONDecoder().decode(Answer.self, from: data) { return convert(answer) }
        case .failed:
            return nil
        case .missing:
            break
        }
        guard case .found(let data) = await fetch("search", [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]),
              let answers = try? JSONDecoder().decode([Answer].self, from: data) else { return [] }
        let best = answers.first { $0.syncedLyrics?.isEmpty == false } ?? answers.first { $0.plainLyrics?.isEmpty == false } ?? answers.first
        return best.map(convert) ?? []
    }

    private enum Reply { case found(Data), missing, failed }
    private static func fetch(_ path: String, _ query: [URLQueryItem]) async -> Reply {
        var components = URLComponents(string: "https://lrclib.net/api/" + path)!
        components.queryItems = query
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 15)
        // LRCLIB asks clients to name themselves; nothing about the person is sent.
        request.setValue("TwilDiary/2.0", forHTTPHeaderField: "User-Agent")
        guard let answer = try? await URLSession.shared.data(for: request) else { return .failed }
        switch (answer.1 as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return .found(answer.0)
        case 404: return .missing
        default: return .failed
        }
    }

    private static func convert(_ answer: Answer) -> [JellyfinClient.Lyrics.Line] {
        if answer.instrumental == true { return [JellyfinClient.Lyrics.Line(Text: "♪ Instrumental", Start: nil)] }
        if let synced = answer.syncedLyrics, !synced.isEmpty {
            let timed = parse(synced)
            if !timed.isEmpty { return timed }
        }
        return (answer.plainLyrics ?? "").components(separatedBy: .newlines).map { JellyfinClient.Lyrics.Line(Text: $0, Start: nil) }
            .filter { !($0.Text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "[01:23.45] words" (a line may carry several times, for a chorus) into lines with their start.
    static func parse(_ lrc: String) -> [JellyfinClient.Lyrics.Line] {
        var timed: [(Int64, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var starts: [Int64] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { break }
                starts.append(Int64((minutes * 60 + seconds) * 10_000_000))
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for start in starts { timed.append((start, text)) }
        }
        return timed.sorted { $0.0 < $1.0 }.map { JellyfinClient.Lyrics.Line(Text: $0.1, Start: $0.0) }
    }
}
