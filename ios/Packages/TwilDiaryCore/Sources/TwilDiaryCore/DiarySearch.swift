import Foundation

public struct SearchLibraryTitle: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let year: Int?
    public let category: String
    public let posterPath: String?
    public let localPoster: String?
    public var artwork: String? { localPoster ?? CatalogTools.image(posterPath) }
    public init(_ title: MediaTitle) { id = title.id; name = title.name; year = title.year; category = title.category; posterPath = nil; localPoster = title.poster }
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
        let needle = query.lowercased()
        return workspace.activeTitles.filter { $0.name.precomposedStringWithCompatibilityMapping.lowercased().contains(needle) }.map(SearchLibraryTitle.init)
    }
    public static func merging(_ local: [SearchLibraryTitle], _ identified: [SearchLibraryTitle]) -> [SearchLibraryTitle] {
        var seen = Set<String>()
        return (local + identified).filter { seen.insert($0.id).inserted }
    }
}
