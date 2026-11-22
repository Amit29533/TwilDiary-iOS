import Foundation
import Vision

/// Whether a poster has its title written on it, read once on the phone (Apple's text recognition)
/// and kept: the top card adds the title's logo only to posters without one (as Netflix's art is
/// textless with the logo on top), so a title never shows twice.
@MainActor enum JellyPosterText {
    private static let key = "jellyspace.posterHasTitle"
    private static var memory: [String: Bool] = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]

    /// The poster's own key: the title and its picture's tag (a new poster is read again).
    private static func id(_ item: JellyfinClient.Item) -> String? {
        item.ImageTags?["Primary"].map { item.Id + ":" + $0 }
    }
    /// What's known already (nil: not read yet).
    static func known(_ item: JellyfinClient.Item) -> Bool? { id(item).flatMap { memory[$0] } }

    /// Reads the poster (once) and says whether its title is on it.
    static func hasTitle(_ item: JellyfinClient.Item, poster: URL) async -> Bool {
        guard let id = id(item) else { return false }
        if let seen = memory[id] { return seen }
        // Not loaded: no logo this time, and read again next time.
        guard let loaded = try? await URLSession.shared.data(from: poster),
              (loaded.1 as? HTTPURLResponse)?.statusCode == 200 else { return true }
        let data = loaded.0, name = item.Name ?? ""
        let found = await Task.detached(priority: .utility) { await Self.read(data, title: name) }.value
        memory[id] = found
        // Kept between launches (a few hundred posters at most).
        if memory.count > 400 { memory = Dictionary(uniqueKeysWithValues: memory.suffix(300).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(memory, forKey: key)
        return found
    }

    /// The words on the poster against the title's: half its longer words there (or, for a title
    /// with none, any real writing at all) and it counts as written on.
    nonisolated private static func read(_ data: Data, title: String) async -> Bool {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let lines = try? await request.perform(on: data) else { return true }
        let text = lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let seen = Set(words(text))
        let wanted = words(title).filter { $0.count >= 3 }
        if wanted.isEmpty { return text.filter(\.isLetter).count >= 6 }
        let matched = wanted.filter { word in
            seen.contains(word) || seen.contains(where: { $0.count >= 4 && (word.hasPrefix($0) || $0.hasPrefix(word)) })
        }
        return matched.count * 2 >= wanted.count
    }
    nonisolated private static func words(_ text: String) -> [String] {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
