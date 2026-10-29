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
    public let tags: [String]?
    public let runtimeMinutes: Int?
    public var status: String
    public var favorite: Bool
    public let queued: Bool?
    public var score: Double?
    public var notes: String
    public let deletedAt: String?
    public let version: Int?
    public let seasons: [Season]?
    /// When the title was added to the diary (ISO 8601); absent in older snapshots.
    public let createdAt: String?
    public var isSeries: Bool { category == "show" || category == "anime" }
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
    public let skipped: Bool?
}

public struct WatchEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let operationId: String
    public let titleId: String
    public let episodeId: String?
    public let watchedAt: String?
    public let recordedAt: String
    public let revokedAt: String?
    public let origin: String
    public let version: Int?
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
    public var path: String {
        var base = root.replacingOccurrences(of: "/", with: "\\")
        var relative = relativePath.replacingOccurrences(of: "/", with: "\\")
        while base.hasSuffix("\\") { base.removeLast() }
        while relative.hasPrefix("\\") { relative.removeFirst() }
        return base + "\\" + relative
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

public struct WatchCard: Decodable, Sendable {
    public struct Progress: Decodable, Sendable { public let watched: Int; public let total: Int }
    public struct Season: Decodable, Sendable { public let number: Int; public let name: String; public let metadataLoadedAt: String? }
    public struct Next: Decodable, Sendable { public let id: String; public let number: Int }
    public struct Previous: Decodable, Equatable, Sendable { public let id: String; public let version: Int; public let episodeId: String?; public let number: Int? }
    public let progress: Progress
    public let season: Season?
    public let next: Next?
    public let previous: Previous?
}

public enum DiaryDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
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
