import Foundation

public enum PersonIdentityMatching {
    /// IDs here come from TMDB credits, never from AniList staff IDs.
    public static func uniqueID(in cast: [CastPerson], names: [String]) -> Int? {
        let keys = Set(names.map(key).filter { !$0.isEmpty })
        let matches = Set(cast.filter { $0.id > 0 && keys.contains(key($0.name)) }.map(\.id))
        return matches.count == 1 ? matches.first : nil
    }
    public static func sameName(_ a: String, _ b: String) -> Bool {
        let first = key(a); return !first.isEmpty && first == key(b)
    }
    private static func key(_ name: String) -> String {
        // The existing AniListClient spelling policy, shared by both directions.
        var text = String(name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter(\.isLetter))
        for (long, short) in [("ou", "o"), ("oo", "o"), ("uu", "u")] { text = text.replacingOccurrences(of: long, with: short) }
        return text
    }
}
