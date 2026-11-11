import Foundation

/// "Most watched" cast and voice actors, counted on the phone the way the server's cast-stats
/// query does: the people in the most titles you've watched (or are watching), from each title's
/// top-billed TMDB cast. Anime, anime films and anything tagged Animation count for voice actors;
/// everything else for cast.
public enum CastRanking {
    public enum Kind: String, Sendable { case cast, voice }
    /// One billed person in a title's cast, as kept in the phone's cast cache.
    public struct Member: Codable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public let character: String
        public let profilePath: String?
        public init(id: Int, name: String, character: String, profilePath: String?) {
            self.id = id; self.name = name; self.character = character; self.profilePath = profilePath
        }
    }
    public struct Row: Equatable, Sendable {
        public let id: Int
        public let name: String
        public let image: String?
        /// Their role in their most-played title here, and that title.
        public let character: String?
        public let title: String?
        public let titles: Int
        public let plays: Int
    }
    /// A watched title to count: its TMDB key ("movie:603"), name and plays.
    public struct Watched: Hashable, Sendable {
        public let key: String
        public let name: String
        public let plays: Int
    }

    public static func animated(_ title: MediaTitle) -> Bool {
        title.category == "anime" || title.category == "anime-movie" || title.genres.contains("Animation")
    }
    /// The titles that count for this kind, once each.
    public static func watched(_ workspace: Workspace, kind: Kind) -> [Watched] {
        var plays: [String: Int] = [:]
        for event in workspace.events where event.revokedAt == nil { plays[event.titleId, default: 0] += 1 }
        var seen = Set<String>()
        return workspace.titles.compactMap { title in
            guard title.deletedAt == nil, let tmdb = title.tmdbId, animated(title) == (kind == .voice),
                  ["watching", "completed"].contains(title.status) || plays[title.id] != nil else { return nil }
            let key = (title.isSeries ? "tv:" : "movie:") + String(tmdb)
            guard seen.insert(key).inserted else { return nil }
            return Watched(key: key, name: title.name, plays: plays[title.id] ?? 0)
        }
    }
    /// The top ten: most titles, then most plays, then by name.
    public static func rank(_ watched: [Watched], casts: [String: [Member]], limit: Int = 10) -> [Row] {
        struct Tally { var member: Member; var titles = 0; var plays = 0; var top = -1; var topTitle: String?; var topRole: String? }
        var people: [Int: Tally] = [:]
        for title in watched {
            var counted = Set<Int>()
            for member in casts[title.key] ?? [] where counted.insert(member.id).inserted {
                var tally = people[member.id] ?? Tally(member: member)
                tally.titles += 1; tally.plays += title.plays
                if title.plays > tally.top { tally.top = title.plays; tally.topTitle = title.name; tally.topRole = member.character }
                people[member.id] = tally
            }
        }
        return people.values.sorted {
            $0.titles != $1.titles ? $0.titles > $1.titles : $0.plays != $1.plays ? $0.plays > $1.plays : $0.member.name < $1.member.name
        }.prefix(limit).map { tally in
            // TMDB marks voice roles "Tsukasa Yuzaki (voice)".
            let role = tally.topRole?.replacingOccurrences(of: #"\s*\(voice\)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            return Row(id: tally.member.id, name: tally.member.name, image: tally.member.profilePath,
                       character: role.flatMap { $0.isEmpty ? nil : $0 }, title: tally.topTitle, titles: tally.titles, plays: tally.plays)
        }
    }
}
