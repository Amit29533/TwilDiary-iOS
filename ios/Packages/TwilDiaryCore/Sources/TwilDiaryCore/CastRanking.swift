import Foundation

/// "Most watched" cast and voice actors, counted on the phone the way the server's cast-stats
/// query does: the people in the most titles you've watched (or are watching), from each title's
/// top-billed TMDB cast. Each role counts for one list (2026-11-16; before, a whole title did):
/// a role TMDB marks "(voice)" is a voice role in any title (Groot in a live-action film); in an
/// animated title that marks some roles so, an unmarked one was played on camera (cast); in one
/// that marks none (most anime on TMDB), every role is a voice role.
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
        /// Anime, an anime film or tagged Animation.
        public var animated = true
    }

    public static func animated(_ title: MediaTitle) -> Bool {
        title.category == "anime" || title.category == "anime-movie" || title.genres.contains("Animation")
    }
    /// Whether one billed role counts for voice actors (see the type's note). `titleMarksVoices`:
    /// some role in the same title is marked "(voice)".
    public static func isVoice(_ member: Member, animated: Bool, titleMarksVoices: Bool) -> Bool {
        if marksVoice(member.character) { return true }
        return animated && !titleMarksVoices
    }
    /// TMDB's voice marker: "Groot (voice)", "Narrator (voice) (uncredited)", "(voice, uncredited)".
    static func marksVoice(_ character: String) -> Bool { character.range(of: "(voice", options: .caseInsensitive) != nil }
    /// The titles you've watched (or are watching), once each. Both lists look at every title: a
    /// live-action film can hold a voice role, and an animated one a role played on camera.
    public static func watched(_ workspace: Workspace) -> [Watched] {
        var plays: [String: Int] = [:]
        for event in workspace.events where event.revokedAt == nil { plays[event.titleId, default: 0] += 1 }
        var seen = Set<String>()
        return workspace.titles.compactMap { title in
            guard title.deletedAt == nil, let tmdb = title.tmdbId,
                  ["watching", "completed"].contains(title.status) || plays[title.id] != nil else { return nil }
            let key = (title.isSeries ? "tv:" : "movie:") + String(tmdb)
            guard seen.insert(key).inserted else { return nil }
            return Watched(key: key, name: title.name, plays: plays[title.id] ?? 0, animated: animated(title))
        }
    }
    /// The top ten of `kind`: most titles, then most plays, then by name. Only each person's roles
    /// of that kind count.
    public static func rank(_ watched: [Watched], casts: [String: [Member]], kind: Kind, limit: Int = 10) -> [Row] {
        struct Tally { var member: Member; var titles = 0; var plays = 0; var top = -1; var topTitle: String?; var topRole: String? }
        var people: [Int: Tally] = [:]
        for title in watched {
            var counted = Set<Int>()
            let members = casts[title.key] ?? []
            let marks = members.contains { marksVoice($0.character) }
            for member in members where isVoice(member, animated: title.animated, titleMarksVoices: marks) == (kind == .voice) && counted.insert(member.id).inserted {
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
            let role = tally.topRole?.replacingOccurrences(of: #"\s*\(voice[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            return Row(id: tally.member.id, name: tally.member.name, image: tally.member.profilePath,
                       character: role.flatMap { $0.isEmpty ? nil : $0 }, title: tally.topTitle, titles: tally.titles, plays: tally.plays)
        }
    }
}
