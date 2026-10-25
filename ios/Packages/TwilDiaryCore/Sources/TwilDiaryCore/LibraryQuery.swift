import Foundation

public struct LibraryQuery: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable { case library, title, year, score }
    public var query = "", category = "all", status = "all", disk = "all", availability = "all", genre = "", tag = ""
    public var queued = false, favorites = false, archived = false
    public var sort = Sort.library
    public init() { }
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
            return (title.deletedAt != nil) == archived && (needle.isEmpty || title.name.precomposedStringWithCompatibilityMapping.lowercased().contains(needle))
                && categoryMatches && (status == "all" || title.status == status) && (!queued || title.queued == true)
                && (!favorites || title.favorite) && (genre.isEmpty || title.genres.contains(genre))
                && (tag.isEmpty || title.tags?.contains(tag) == true) && diskMatches
                && (availability == "all" || confirmed == (availability == "present"))
        }
        guard sort != .library else { return selected }
        return selected.sorted { left, right in
            if sort == .year, (left.year ?? 0) != (right.year ?? 0) { return (left.year ?? 0) > (right.year ?? 0) }
            if sort == .score {
                let a = ratingFor(left) ?? -1, b = ratingFor(right) ?? -1
                if a != b { return a > b }
            }
            return Self.nameBefore(left.name, right.name)
        }
    }
    static func nameBefore(_ left: String, _ right: String) -> Bool {
        left.compare(right, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")) == .orderedAscending
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
