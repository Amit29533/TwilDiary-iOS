import Foundation

/// AniList media IDs are never TMDB IDs. Only unique title/year/type matches may open directly.
public enum AnimeTitleMatching {
    public static func saved(_ titles: [MediaTitle], names: [String], year: Int?, kind: MediaKind?) -> [MediaTitle] {
        let keys = Set(names.map(key).filter { !$0.isEmpty })
        return titles.filter {
            $0.deletedAt == nil && keys.contains(key($0.name))
                && (year == nil || $0.year == year)
                && (kind == nil || $0.isSeries == (kind == .tv))
        }
    }

    public static func catalog(_ items: [CatalogItem], names: [String], year: Int?, kind: MediaKind?) -> CatalogItem? {
        let keys = Set(names.map(key).filter { !$0.isEmpty })
        let matches = CatalogTools.merging([], items).filter {
            keys.contains(key($0.name)) && (year == nil || $0.year == year)
                && (kind == nil || $0.mediaType == kind)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { String($0) }.joined()
    }
}
