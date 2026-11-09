import Foundation

/// A studio or network from TMDB, with its own logo (`GET /api/metadata/extras`).
public struct TitleCompany: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let logoPath: String?
    /// "studio" (TMDB production company) or "network".
    public let kind: String
    public let country: String?
    public init(id: Int, name: String, logoPath: String?, kind: String, country: String?) {
        self.id = id; self.name = name; self.logoPath = logoPath; self.kind = kind; self.country = country
    }
    public var isNetwork: Bool { kind == "network" }
    /// Studios and networks can share a TMDB number, so the kind is part of the identity.
    public var key: String { kind + ":" + String(id) }
}

/// A TMDB keyword, shown as a tag that opens titles with the same tag.
public struct TitleKeyword: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

/// Someone who made the title: creator, director, writer, composer.
public struct TitleCrewMember: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let job: String
    public let profilePath: String?
    public init(id: Int, name: String, job: String, profilePath: String?) {
        self.id = id; self.name = name; self.job = job; self.profilePath = profilePath
    }
}

/// What a title page shows beyond its basics. Every field is optional on the wire so an older
/// server (without this endpoint's newer fields) still decodes.
public struct TitleExtras: Codable, Hashable, Sendable {
    public let status: String?
    public let certification: String?
    public let studios: [TitleCompany]
    public let networks: [TitleCompany]
    public let keywords: [TitleKeyword]
    public let crew: [TitleCrewMember]
    public init(status: String?, certification: String?, studios: [TitleCompany], networks: [TitleCompany], keywords: [TitleKeyword], crew: [TitleCrewMember] = []) {
        self.status = status; self.certification = certification; self.studios = studios
        self.networks = networks; self.keywords = keywords; self.crew = crew
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        certification = try c.decodeIfPresent(String.self, forKey: .certification)
        studios = try c.decodeIfPresent([TitleCompany].self, forKey: .studios) ?? []
        networks = try c.decodeIfPresent([TitleCompany].self, forKey: .networks) ?? []
        keywords = try c.decodeIfPresent([TitleKeyword].self, forKey: .keywords) ?? []
        crew = try c.decodeIfPresent([TitleCrewMember].self, forKey: .crew) ?? []
    }
    /// Studios first, then networks, each once.
    public var companies: [TitleCompany] {
        var seen = Set<String>()
        return (studios + networks).filter { seen.insert($0.key).inserted }
    }
    /// The status as a short chip: "Canceled", "Ended", "Returning", "In production"…
    /// A released movie says nothing (every movie on a page has been released).
    public var statusLabel: String? {
        switch status {
        case "Returning Series": "Returning"
        case "In Production": "In production"
        case "Post Production": "Post-production"
        case "Planned": "Planned"
        case "Pilot": "Pilot"
        case "Ended": "Ended"
        case "Canceled", "Cancelled": "Canceled"
        case "Rumored": "Rumored"
        default: nil
        }
    }
    /// A canceled show is the one status drawn as a warning.
    public var statusIsWarning: Bool { status == "Canceled" || status == "Cancelled" }
}

/// Low red, mid orange, high green, for any score out of 10.
public enum RatingTone: Equatable, Sendable {
    case low, mid, high
    public init(score: Double) {
        self = score < 5 ? .low : score < 7 ? .mid : .high
    }
}

public struct EpisodeRatingPoint: Hashable, Sendable {
    public let episode: Int
    public let score: Double
    public init(episode: Int, score: Double) { self.episode = episode; self.score = score }
}

/// Average, best and lowest episode for the rating trend. Scores outside 0–10 are ignored;
/// a tie for best or lowest goes to the earlier episode.
public struct EpisodeRatingSummary: Equatable, Sendable {
    public let points: [EpisodeRatingPoint]
    public let average: Double
    public let best: EpisodeRatingPoint
    public let lowest: EpisodeRatingPoint
    public init?(_ raw: [EpisodeRatingPoint]) {
        let points = raw.filter { $0.score.isFinite && $0.score > 0 && $0.score <= 10 }.sorted { $0.episode < $1.episode }
        guard let first = points.first else { return nil }
        self.points = points
        average = points.reduce(0) { $0 + $1.score } / Double(points.count)
        best = points.reduce(first) { $1.score > $0.score ? $1 : $0 }
        lowest = points.reduce(first) { $1.score < $0.score ? $1 : $0 }
    }
    /// Chart bounds rounded out to whole numbers, at least two points apart.
    public var range: ClosedRange<Double> {
        let low = max(0, floor(lowest.score) - 1), high = min(10, ceil(best.score) + 1)
        return high - low >= 2 ? low...high : max(0, high - 2)...min(10, max(high, low + 2))
    }
}

/// Which episodes the Episodes page shows open: the one before what's next and two after it.
/// The rest fold into a group before and a group after.
public struct EpisodeWindow: Equatable, Sendable {
    public let before: Range<Int>
    public let shown: Range<Int>
    public let after: Range<Int>
    /// `focus` is the index of the next episode; nil means all are watched (the last few show).
    public init(count: Int, focus: Int?, leading: Int = 1, trailing: Int = 2) {
        guard count > 0 else { before = 0..<0; shown = 0..<0; after = 0..<0; return }
        let size = min(count, leading + 1 + trailing)
        let anchor = min(max(0, focus ?? count - 1), count - 1)
        var start = max(0, anchor - leading)
        let end = min(count, start + size)
        start = max(0, end - size)
        before = 0..<start; shown = start..<end; after = end..<count
    }
}

/// A small emoji for a tag, so the tag cloud reads at a glance. Unknown tags get a label.
public enum TagEmoji {
    private static let table: [(String, String)] = [
        ("hand-drawn", "✏️"), ("adult animation", "😈"), ("anime", "🌸"), ("seinen", "🎴"), ("shounen", "🔥"), ("shonen", "🔥"),
        ("shoujo", "🎀"), ("shojo", "🎀"), ("josei", "🌷"), ("coming of age", "🌱"), ("coming-of-age", "🌱"),
        ("romantic comedy", "💕"), ("romance", "❤️"), ("love", "❤️"), ("comedy", "😂"), ("deaf", "🤟"), ("sign language", "🤟"),
        ("bully", "💔"), ("friendship", "🤝"), ("school", "🏫"), ("high school", "🏫"), ("college", "🎓"), ("cosplay", "🎭"),
        ("doll", "🎎"), ("craft", "🧵"), ("sewing", "🧵"), ("music", "🎵"), ("band", "🎸"), ("idol", "🎤"), ("sport", "🏅"),
        ("baseball", "⚾"), ("basketball", "🏀"), ("soccer", "⚽"), ("football", "🏈"), ("volleyball", "🏐"), ("food", "🍜"),
        ("cooking", "🍳"), ("magic", "✨"), ("witch", "🧙"), ("wizard", "🧙"), ("isekai", "🌀"), ("fantasy", "🐉"),
        ("dragon", "🐉"), ("demon", "👹"), ("vampire", "🧛"), ("zombie", "🧟"), ("ghost", "👻"), ("supernatural", "🔮"),
        ("horror", "🩸"), ("murder", "🔪"), ("detective", "🕵️"), ("mystery", "🔍"), ("crime", "🚨"), ("police", "🚓"),
        ("war", "⚔️"), ("samurai", "🗡️"), ("ninja", "🥷"), ("martial arts", "🥋"), ("robot", "🤖"), ("mecha", "🤖"),
        ("space", "🚀"), ("alien", "👽"), ("time travel", "⏳"), ("dystopia", "🏚️"), ("post-apocalyptic", "☢️"),
        ("psychological", "🧠"), ("mental", "🧠"), ("family", "👨‍👩‍👧"), ("slice of life", "☕"), ("iyashikei", "🍵"),
        ("based on manga", "📚"), ("manga", "📚"), ("based on novel", "📖"), ("light novel", "📖"), ("based on comic", "💥"),
        ("superhero", "🦸"), ("revenge", "😤"), ("survival", "🏕️"), ("game", "🎮"), ("work", "💼"), ("office", "💼"),
        ("travel", "🧳"), ("animal", "🐾"), ("cat", "🐈"), ("dog", "🐕"), ("ocean", "🌊"), ("sea", "🌊"), ("christmas", "🎄"),
        ("wedding", "💍"), ("lgbt", "🏳️‍🌈"), ("gay", "🏳️‍🌈"), ("lesbian", "🏳️‍🌈"), ("historical", "🏯"), ("history", "🏯"),
        ("politics", "🏛️"), ("money", "💰"), ("drama", "🎭"), ("teen", "🧑"), ("woman director", "🎬"), ("biography", "👤")
    ]
    public static func symbol(for name: String) -> String {
        let value = name.lowercased()
        return table.first { value.contains($0.0) }?.1 ?? "🏷️"
    }
}
