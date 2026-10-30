import Foundation

public struct LibraryQuery: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable { case added, library, title, year, score }
    public var query = "", category = "all", status = "all", disk = "all", availability = "all", genre = "", tag = ""
    public var queued = false, favorites = false, archived = false
    /// Titles in any of these genres (the filter sheet's chips), on top of `genre`.
    public var genres: Set<String> = []
    /// Only titles on Jellyfin: a present Jellyfin folder (from Sync now), or one of the diary
    /// titles the Jellyfin list the phone last read was matched to.
    public var jellyfin = false
    public var jellyfinTitles: Set<String> = []
    public var sort = Sort.library
    public init() { }
    /// Library shortcuts already include the drive's colon (for example `drive:E:`).
    /// Accept older colon-less keys too, without ever comparing a drive against `E::`.
    public static func jellyfinDriveMatches(_ drive: String, disk: String) -> Bool {
        switch disk {
        case "all", "mapped": return true
        case "unmapped": return false
        default:
            if disk.hasPrefix("drive:") {
                let selected = String(disk.dropFirst(6)).uppercased()
                return drive.uppercased() == (selected.hasSuffix(":") ? selected : selected + ":")
            }
            return disk.contains("\"jellyfin:" + drive + "\"")
        }
    }
    public func titles(in workspace: Workspace, ratingFor: (MediaTitle) -> Double? = { $0.communityScore }) -> [MediaTitle] {
        let needle = query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let locations = Dictionary(grouping: workspace.locations, by: \.titleId)
        let selected = workspace.titles.filter { title in
            let copies = locations[title.id] ?? []
            let confirmed = copies.contains { $0.evidence == "present" }
            let categoryMatches = category == "all" || title.category == category || (title.category == "anime-movie" && ["movie", "anime"].contains(category))
            let diskMatches: Bool
            switch disk {
            case "all": diskMatches = true
            case "downloads": diskMatches = title.queued == true
            case "unmapped": diskMatches = copies.isEmpty
            case "mapped": diskMatches = !copies.isEmpty
            default: diskMatches = copies.contains { $0.diskKey == disk || (disk.hasPrefix("drive:") && $0.driveLetter.uppercased() == String(disk.dropFirst(6))) }
            }
            let jellyfinMatches = !jellyfin || jellyfinTitles.contains(title.id)
                || copies.contains { $0.deviceId == "jellyfin" && $0.evidence == "present" }
            return (title.deletedAt != nil) == archived && (needle.isEmpty || title.name.precomposedStringWithCompatibilityMapping.lowercased().contains(needle))
                && categoryMatches && (status == "all" || title.status == status) && (!queued || title.queued == true)
                && (!favorites || title.favorite) && (genre.isEmpty || title.genres.contains(genre))
                && (genres.isEmpty || title.genres.contains { genres.contains($0) })
                && (tag.isEmpty || title.tags?.contains(tag) == true) && diskMatches && jellyfinMatches
                && (availability == "all" || confirmed == (availability == "present"))
        }
        guard sort != .library else { return selected }
        return selected.sorted { left, right in
            // Newest first; titles without a date (older snapshots) go last, by name.
            if sort == .added, (left.createdAt ?? "") != (right.createdAt ?? "") { return (left.createdAt ?? "") > (right.createdAt ?? "") }
            if sort == .year, (left.year ?? 0) != (right.year ?? 0) { return (left.year ?? 0) > (right.year ?? 0) }
            if sort == .score {
                let a = ratingFor(left) ?? -1, b = ratingFor(right) ?? -1
                if a != b { return a > b }
            }
            return Self.nameBefore(left.name, right.name)
        }
    }
    /// Built once: sorting compared names with a freshly constructed Locale per comparison.
    private static let sortLocale = Locale(identifier: "en_US")
    static func nameBefore(_ left: String, _ right: String) -> Bool {
        left.compare(right, options: [.caseInsensitive, .diacriticInsensitive], locale: sortLocale) == .orderedAscending
    }
}

public struct LibraryShelf: Identifiable, Equatable, Sendable {
    public var id: String { genre }
    public let genre: String, titles: [MediaTitle]
    public static func make(_ titles: [MediaTitle]) -> [Self] {
        var groups: [String: [MediaTitle]] = [:], unclassified: [MediaTitle] = []
        for title in titles {
            let names = Set(title.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if names.isEmpty { unclassified.append(title) }
            for name in names where groups[name]?.contains(where: { $0.id == title.id }) != true { groups[name, default: []].append(title) }
        }
        var result = groups.map { Self(genre: $0.key, titles: $0.value) }.sorted {
            $0.titles.count == $1.titles.count ? LibraryQuery.nameBefore($0.genre, $1.genre) : $0.titles.count > $1.titles.count
        }
        if !unclassified.isEmpty { result.append(Self(genre: "Without a genre", titles: unclassified)) }
        return result
    }
}

extension FileLocation {
    public var diskKey: String {
        let pair: [Any] = [deviceId as Any? ?? NSNull(), volumeId as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: pair, options: [.withoutEscapingSlashes]), let key = String(data: data, encoding: .utf8) else { return "[null,null]" }
        return key
    }
}
