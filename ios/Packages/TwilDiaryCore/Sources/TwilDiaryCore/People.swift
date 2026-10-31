import Foundation

public enum PersonSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case shows, movies, knownFor = "known-for", credits
    public var id: Self { self }
    public var label: String { switch self { case .shows: "Shows"; case .movies: "Movies"; case .knownFor: "Known for"; case .credits: "Credits" } }
}
public struct PersonFilmographyRoute: Hashable, Sendable {
    public let person: Int
    public let section: PersonSection
    public let onServer: Bool
    public let watchedOnly: Bool
    public init(person: Int, section: PersonSection, onServer: Bool = false, watchedOnly: Bool = false) { self.person = person; self.section = section; self.onServer = onServer; self.watchedOnly = watchedOnly }
}
public struct PersonSections: Sendable {
    public let movies: [CatalogItem], shows: [CatalogItem], knownFor: [CatalogItem], localMovies: [CatalogItem], localShows: [CatalogItem]
    public let watched: [CatalogItem]
    public init(person: PersonDetails, workspace: Workspace) {
        func byYear(_ items: [CatalogItem]) -> [CatalogItem] {
            items.sorted { a, b in (a.year ?? 0) != (b.year ?? 0) ? (a.year ?? 0) > (b.year ?? 0) : a.name.localizedCompare(b.name) == .orderedAscending }
        }
        movies = byYear(person.credits.filter { $0.mediaType == .movie })
        shows = byYear(person.credits.filter { $0.mediaType == .tv })
        let watchedIDs = Set(workspace.activeEvents.map(\.titleId))
        let watchedKeys = Set(workspace.activeTitles.filter { watchedIDs.contains($0.id) }.compactMap { title in
            title.tmdbId.map { (title.isSeries ? "tv:" : "movie:") + String($0) }
        })
        watched = byYear(person.credits.filter { watchedKeys.contains($0.key) })
        let stored = Set(workspace.locations.filter { $0.evidence == "present" }.map(\.titleId))
        func onDisk(_ item: CatalogItem) -> Bool { workspace.titles.contains { stored.contains($0.id) && $0.tmdbId == item.id && $0.isSeries == (item.mediaType == .tv) } }
        localMovies = movies.filter(onDisk); localShows = shows.filter(onDisk)
        let popular = person.credits.filter { ($0.votes ?? 0) >= 20 && ($0.character ?? "").range(of: #"^self\b"#, options: [.regularExpression, .caseInsensitive]) == nil }
        func prominence(_ item: CatalogItem) -> Double {
            (item.popularity ?? 0) * (item.mediaType == .tv && (item.episodeCount ?? 0) != 0 ? min(1, Double(item.episodeCount ?? 0) / 8) : 1)
        }
        knownFor = Array((popular.isEmpty ? person.credits : popular).enumerated().sorted { a, b in
            let first = prominence(a.element), second = prominence(b.element)
            if first != second { return first > second }
            if (a.element.votes ?? 0) != (b.element.votes ?? 0) { return (a.element.votes ?? 0) > (b.element.votes ?? 0) }
            return a.offset < b.offset
        }.prefix(12).map { $0.element })
    }
    public func items(_ section: PersonSection, onServer: Bool) -> [CatalogItem]? {
        switch section { case .shows: onServer ? localShows : shows; case .movies: onServer ? localMovies : movies; case .knownFor: knownFor; case .credits: onServer ? localShows + localMovies : nil }
    }
}
public struct PersonFilmographyFilters: Hashable, Sendable {
    public var genre = "", year = "", minimum = "0", query = ""
    public var sort: String
    public var onServer: Bool
    public var watchedOnly: Bool
    public init(section: PersonSection, onServer: Bool = false, watchedOnly: Bool = false) { sort = section == .knownFor ? "popular" : "newest"; self.onServer = onServer; self.watchedOnly = watchedOnly }
    public var normalizedQuery: String { query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    public var error: String? {
        if normalizedQuery.utf16.count > 200 { return "Keep search within 200 characters." }
        var filters = DiscoveryFilters(section: .daily); filters.year = year; filters.minimum = minimum; filters.genre = genre
        return filters.error(section: .daily)
    }
    public func credits(person: PersonDetails, workspace: Workspace, section: PersonSection) -> [CatalogItem] {
        let sections = PersonSections(person: person, workspace: workspace)
        if watchedOnly { return sections.watched.filter { section != .shows && section != .movies || $0.mediaType == (section == .shows ? .tv : .movie) } }
        return sections.items(section, onServer: onServer) ?? person.credits
    }
    public func applying(person: PersonDetails, workspace: Workspace, section: PersonSection) -> [CatalogItem] {
        let input = credits(person: person, workspace: workspace, section: section)
            .filter { normalizedQuery.isEmpty || $0.name.precomposedStringWithCompatibilityMapping.lowercased().contains(normalizedQuery) }
        var filters = DiscoveryFilters(section: .daily); filters.type = section == .shows ? "tv" : section == .movies ? "movie" : "all"
        filters.genre = genre.trimmingCharacters(in: .whitespacesAndNewlines); filters.year = year; filters.minimum = minimum; filters.sort = sort
        let filtered = filters.applying(input)
        if sort == "popular" {
            return filtered.sorted { a, b in
                if (a.popularity ?? 0) != (b.popularity ?? 0) { return (a.popularity ?? 0) > (b.popularity ?? 0) }
                if (a.votes ?? 0) != (b.votes ?? 0) { return (a.votes ?? 0) > (b.votes ?? 0) }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
        }
        return filtered
    }
    public func heading(person: PersonDetails, section: PersonSection) -> String { person.name + "’s " + (watchedOnly ? "Watched" : section == .credits && onServer ? "Titles on your server" : section.label) }
}
