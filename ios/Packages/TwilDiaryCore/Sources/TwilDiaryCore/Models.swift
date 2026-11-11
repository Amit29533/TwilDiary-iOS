import Foundation

public struct MediaTitle: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public let category: String
    public let year: Int?
    public let overview: String
    public let poster: String?
    public let backdrop: String?
    public let communityScore: Double?
    public let tmdbId: Int?
    public let genres: [String]
    public var tags: [String]?
    public let runtimeMinutes: Int?
    public var status: String
    public var favorite: Bool
    public var queued: Bool?
    public var score: Double?
    public var notes: String
    public var deletedAt: String?
    public var version: Int?
    public var seasons: [Season]?
    /// When the title was added to the diary (ISO 8601); absent in older snapshots.
    public let createdAt: String?
    /// When the title last changed on the server (ISO 8601): against Trakt, the newer change wins.
    public var updatedAt: String? = nil
    public var isSeries: Bool { category == "show" || category == "anime" }
    /// A title known only by its TMDB id (an import from another app); its details fill in later.
    public static func imported(id: String, name: String, series: Bool, year: Int?, tmdbId: Int, status: String, score: Double?, createdAt: String) -> MediaTitle {
        MediaTitle(id: id, name: name, category: series ? "show" : "movie", year: year, overview: "", poster: nil, backdrop: nil,
                   communityScore: nil, tmdbId: tmdbId, genres: [], tags: [], runtimeMinutes: nil, status: status, favorite: false,
                   queued: false, score: score, notes: "", deletedAt: nil, version: 1, seasons: nil, createdAt: createdAt)
    }
    /// The same title under another category (anime, anime movie…), as you chose it.
    public func withCategory(_ category: String) -> MediaTitle {
        MediaTitle(id: id, name: name, category: category, year: year, overview: overview, poster: poster, backdrop: backdrop,
                   communityScore: communityScore, tmdbId: tmdbId, genres: genres, tags: tags, runtimeMinutes: runtimeMinutes, status: status,
                   favorite: favorite, queued: queued, score: score, notes: notes, deletedAt: deletedAt, version: version, seasons: seasons,
                   createdAt: createdAt)
    }
    public var categoryName: String {
        switch category { case "anime-movie": "Anime movie"; default: category.capitalized }
    }
}

public struct Season: Codable, Hashable, Sendable {
    public let number: Int
    public let name: String
    public let expectedEpisodes: Int?
    public let metadataLoadedAt: String?
    public let metadataVersion: Int?
}

public struct Episode: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let titleId: String
    public let season: Int
    public let number: Int
    public let name: String
    public let overview: String
    public let airedOn: String?
    public let still: String?
    public let hidden: Bool?
    public let communityScore: Double?
    public var skipped: Bool?
    /// An episode known only by its number (an import from another app).
    public static func numbered(id: String, titleId: String, season: Int, number: Int) -> Episode {
        Episode(id: id, titleId: titleId, season: season, number: number, name: "", overview: "", airedOn: nil, still: nil, hidden: nil, communityScore: nil, skipped: nil)
    }
}

public struct WatchEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let operationId: String
    public let titleId: String
    public let episodeId: String?
    public var watchedAt: String?
    public let recordedAt: String
    public var revokedAt: String?
    public let origin: String
    public var version: Int?
    public init(id: String, operationId: String, titleId: String, episodeId: String?, watchedAt: String?, recordedAt: String, revokedAt: String? = nil, origin: String = "manual", version: Int? = 1) {
        self.id = id; self.operationId = operationId; self.titleId = titleId; self.episodeId = episodeId
        self.watchedAt = watchedAt; self.recordedAt = recordedAt; self.revokedAt = revokedAt
        self.origin = origin; self.version = version
    }
}

public struct FileLocation: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let titleId: String
    public let deviceName: String
    public let deviceId: String?
    public let volumeId: String?
    public let driveLetter: String
    public let root: String
    public let relativePath: String
    public let season: Int?
    public let fileCount: Int
    public let evidence: String
    public let sizeBytes: Int64?
    public let checkedAt: String?
    /// Windows drives use backslashes; a POSIX root (a Jellyfin server's "/mnt/media") keeps slashes.
    public var path: String {
        let separator = root.hasPrefix("/") ? "/" : "\\", other = separator == "/" ? "\\" : "/"
        var base = root.replacingOccurrences(of: other, with: separator)
        var relative = relativePath.replacingOccurrences(of: other, with: separator)
        while base.hasSuffix(separator) { base.removeLast() }
        while relative.hasPrefix(separator) { relative.removeFirst() }
        return base + separator + relative
    }
    /// A folder Jellyfin holds, kept on the phone (no server): split the way the server splits it
    /// ("D:\TV\Show" → drive D:, "\\nas\media\TV" → the share, "/mnt/media/TV" → POSIX), present.
    public static func jellyfin(titleId: String, folder: String, season: Int?, fileCount: Int, checkedAt: String) -> FileLocation {
        var letter = "", root = "/", relative = folder
        let characters = Array(folder)
        if characters.count >= 2, characters[1] == ":", characters[0].isLetter {
            letter = String(characters[0]).uppercased() + ":"; root = letter + "\\"
            relative = String(folder.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        } else if folder.hasPrefix("\\\\") {
            let parts = folder.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
            root = "\\\\" + parts.prefix(2).joined(separator: "\\")
            relative = parts.dropFirst(2).joined(separator: "\\")
        } else {
            relative = String(folder.drop { $0 == "/" })
        }
        return FileLocation(id: "jellyfin|" + titleId + "|" + folder, titleId: titleId, deviceName: "Jellyfin", deviceId: "jellyfin",
                            volumeId: "jellyfin:" + (letter.isEmpty ? root : letter), driveLetter: letter, root: root, relativePath: relative,
                            season: season, fileCount: fileCount, evidence: "present", sizeBytes: nil, checkedAt: checkedAt)
    }
    /// The same folder for another title id (a title's phone key).
    public func moved(to titleId: String) -> FileLocation {
        FileLocation(id: id, titleId: titleId, deviceName: deviceName, deviceId: deviceId, volumeId: volumeId, driveLetter: driveLetter,
                     root: root, relativePath: relativePath, season: season, fileCount: fileCount, evidence: evidence, sizeBytes: sizeBytes, checkedAt: checkedAt)
    }
}

public struct WorkspacePage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let next: String?
}

public struct Workspace: Codable, Sendable {
    public var titles: [MediaTitle]
    public var episodes: [Episode]
    public var events: [WatchEvent]
    public var locations: [FileLocation]
    public init(titles: [MediaTitle] = [], episodes: [Episode] = [], events: [WatchEvent] = [], locations: [FileLocation] = []) {
        self.titles = titles; self.episodes = episodes; self.events = events; self.locations = locations
    }
    public var activeTitles: [MediaTitle] { titles.filter { $0.deletedAt == nil } }
    public var activeEvents: [WatchEvent] {
        let ids = Set(activeTitles.map(\.id))
        return events.filter { $0.revokedAt == nil && ids.contains($0.titleId) }
    }
}

public struct WatchCard: Codable, Equatable, Sendable {
    public struct Progress: Codable, Equatable, Sendable {
        public let watched: Int; public let total: Int
        public init(watched: Int, total: Int) { self.watched = watched; self.total = total }
    }
    public struct Season: Codable, Equatable, Sendable {
        public let number: Int; public let name: String; public let metadataLoadedAt: String?
        public init(number: Int, name: String, metadataLoadedAt: String?) { self.number = number; self.name = name; self.metadataLoadedAt = metadataLoadedAt }
    }
    public struct Next: Codable, Equatable, Sendable {
        public let id: String; public let number: Int
        public init(id: String, number: Int) { self.id = id; self.number = number }
    }
    public struct Previous: Codable, Equatable, Sendable {
        public let id: String; public let version: Int; public let episodeId: String?; public let number: Int?
        public init(id: String, version: Int, episodeId: String?, number: Int?) { self.id = id; self.version = version; self.episodeId = episodeId; self.number = number }
    }
    public let progress: Progress
    public let season: Season?
    public let next: Next?
    public let previous: Previous?
    public init(progress: Progress, season: Season?, next: Next?, previous: Previous?) {
        self.progress = progress; self.season = season; self.next = next; self.previous = previous
    }
}

public enum DiaryDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    /// Made once per time zone and reused: every date on screen asks for it, and building a
    /// calendar each time was a steady cost while scrolling.
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        calendarLock.lock(); defer { calendarLock.unlock() }
        if let saved = savedCalendar, saved.timeZone == timeZone { return saved }
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        savedCalendar = value
        return value
    }
    private static let calendarLock = NSLock()
    nonisolated(unsafe) private static var savedCalendar: Calendar?
    public static func parse(_ value: String?) -> Date? {
        guard let value, value.count >= 20, SeasonAdjustment.validDay(String(value.prefix(10))) else { return nil }
        return (try? fractional.parse(value)) ?? (try? wholeSeconds.parse(value))
    }
    public static func day(_ date: Date = .now, timeZone: TimeZone = .current) -> String {
        let parts = calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

public struct SeasonProgress: Equatable, Sendable {
    public let watched: Int
    public let total: Int
    public let remainingMinutes: Int?
    public var fraction: Double { total > 0 ? min(1, Double(watched) / Double(total)) : 0 }
    public static func calculate(title: MediaTitle, workspace: Workspace, season: Int) -> Self {
        let episodes = workspace.episodes.filter { $0.titleId == title.id && $0.season == season }
        let watched = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
        let count = episodes.filter { watched.contains($0.id) }.count
        let manifest = title.seasons?.first { $0.number == season }
        let total = max(episodes.count, manifest?.expectedEpisodes ?? 0)
        let complete = manifest.map { s in
            s.expectedEpisodes.map { $0 == episodes.count } ?? (s.metadataLoadedAt != nil)
        } ?? (title.tmdbId == nil && !episodes.isEmpty)
        let remaining = max(0, total - count)
        let minutes: Int? = !complete ? nil : remaining == 0 ? 0 : title.runtimeMinutes.flatMap { $0 > 0 ? remaining * $0 : nil }
        return Self(watched: count, total: total, remainingMinutes: minutes)
    }
}

public enum Period: String, Codable, CaseIterable, Identifiable, Sendable {
    case today, week, month, ninetyDays = "90d", year, all
    public var id: Self { self }
    public var label: String { switch self { case .today: "Today"; case .week: "This Week"; case .month: "This Month"; case .ninetyDays: "Last 90 Days"; case .year: "This Year"; case .all: "All time" } }
    public func contains(_ date: Date, now: Date, calendar: Calendar, year: Int? = nil) -> Bool {
        guard calendar.startOfDay(for: date) <= calendar.startOfDay(for: now) else { return false }
        switch self {
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .week:
            var week = calendar; week.firstWeekday = 2; week.minimumDaysInFirstWeek = 4
            return week.dateInterval(of: .weekOfYear, for: now)?.contains(date) == true
        case .month: return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .ninetyDays: return date >= calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: now))!
        case .year:
            let current = calendar.component(.year, from: now)
            let selected = year.flatMap { $0 >= 1900 && $0 <= current ? $0 : nil } ?? current
            return calendar.component(.year, from: date) == selected
        case .all: return true
        }
    }
}

public enum LibraryCategory: String, CaseIterable, Identifiable {
    case all = "All", movies = "Movies", shows = "Shows", anime = "Anime"
    public var id: Self { self }
    public func includes(_ title: MediaTitle) -> Bool {
        switch self { case .all: true; case .movies: !title.isSeries; case .shows: title.category == "show"; case .anime: title.category.hasPrefix("anime") }
    }
}
