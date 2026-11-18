import Foundation

public struct SearchLibraryTitle: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let year: Int?
    public let category: String
    public let posterPath: String?
    public let localPoster: String?
    public fileprivate(set) var matchedName: String?
    public var artwork: String? { localPoster ?? CatalogTools.image(posterPath) }
    public init(_ title: MediaTitle) {
        self.init(title, matchedName: nil)
    }
    public init(_ title: MediaTitle, matchedName: String?) {
        id = title.id; name = title.name; year = title.year; category = title.category
        posterPath = nil; localPoster = title.poster; self.matchedName = matchedName
    }
}

public struct DiarySearchPage: Decodable, Sendable {
    public let library: [SearchLibraryTitle]
    public let online: [CatalogItem]
    public let page: Int
    public let totalPages: Int
    public let onlineError: String
    public init(library: [SearchLibraryTitle], online: [CatalogItem], page: Int, totalPages: Int, onlineError: String = "") { self.library = library; self.online = online; self.page = page; self.totalPages = totalPages; self.onlineError = onlineError }
}

public enum DiarySearchTools {
    public static func normalize(_ input: String) -> String {
        let value = input.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:https?://(?:www\.)?imdb\.com/title/)?(tt[0-9]{7,10})(?:/?(?:[?#].*)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return value }
        return String(value[range]).lowercased()
    }
    public static func ready(_ query: String) -> Bool {
        (2...200).contains(query.utf16.count) && !query.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    public static func matches(_ workspace: Workspace, query: String) -> [SearchLibraryTitle] {
        guard ready(query) else { return [] }
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return workspace.activeTitles.filter { $0.name.precomposedStringWithCompatibilityMapping.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle) }.map(SearchLibraryTitle.init)
    }
    public static func merging(_ local: [SearchLibraryTitle], _ identified: [SearchLibraryTitle]) -> [SearchLibraryTitle] {
        var positions: [String: Int] = [:]
        var rows: [SearchLibraryTitle] = []
        for row in local + identified {
            if let index = positions[row.id] {
                if let alias = row.matchedName, alias != rows[index].name { rows[index].matchedName = alias }
            } else {
                positions[row.id] = rows.count
                rows.append(row)
            }
        }
        return rows
    }
}

/// "Did you mean…" for a search that found nothing: the closest known title name, a letter or two
/// off ("breking bad" → "Breaking Bad"). Accents, case and punctuation don't count.
public enum SpellingSuggestion {
    public static func best(for query: String, in names: [String]) -> String? {
        let wanted = comparable(query)
        guard wanted.count >= 3 else { return nil }
        // One edit for short names, then one per three letters (at most three): "frerein" → Frieren.
        let allowed = min(3, max(1, wanted.count / 3))
        var best: (name: String, distance: Int)?
        var seen = Set<String>()
        for name in names {
            let candidate = comparable(name)
            guard !candidate.isEmpty, candidate != wanted, seen.insert(candidate).inserted,
                  abs(candidate.count - wanted.count) <= allowed else { continue }
            let distance = editDistance(Array(wanted), Array(candidate), limit: allowed)
            if distance <= allowed, distance < (best?.distance ?? .max) { best = (name, distance) }
        }
        return best?.name
    }
    /// Lower case, no accents, punctuation as single spaces.
    public static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }
    /// Edits (insert, delete, change, swap two neighbours) from one to the other; stops early past `limit`.
    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var before = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var smallest = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, before[j - 2] + 1) }
                current[j] = value
                smallest = min(smallest, value)
            }
            if smallest > limit { return limit + 1 }
            before = previous; previous = current
        }
        return previous[b.count]
    }
}
