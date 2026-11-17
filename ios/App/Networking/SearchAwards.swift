import Foundation
import TwilDiaryCore

struct SearchAwardCeremony: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String

    // Provider IDs let the landing page show the main ceremonies before any request.
    static let featured: [Self] = [
        .init(id: 5, name: "Primetime Emmy Awards"), .init(id: 1, name: "Academy Awards"),
        .init(id: 11, name: "BAFTA Awards"), .init(id: 2, name: "Golden Globe Awards"),
        .init(id: 6, name: "Screen Actors Guild Awards"), .init(id: 4, name: "Critics’ Choice Awards")
    ]

    var style: (symbol: String, tint: String) {
        switch id {
        case 5, 10: ("sparkles.tv", "#f3c969")
        case 11: ("theatermasks.fill", "#dfa655")
        case 6: ("person.fill", "#81ccba")
        case 2: ("globe.europe.africa", "#f3c969")
        case 4: ("star.fill", "#c4c5d9")
        default: ("trophy.fill", "#f3c969")
        }
    }

    // Television movies belong to the Emmy ceremony alongside series.
    var televisionOnly: Bool { id == 5 || id == 10 }
}

struct SearchAwardCategory: Codable, Hashable, Identifiable, Sendable {
    enum AwardType: String, CaseIterable, Identifiable {
        case titles = "Titles", acting = "Acting", directing = "Directing", writing = "Writing", crafts = "Crafts"
        var id: Self { self }
    }

    let id: Int
    let name: String
    let forSeries: Bool?
    let forMovies: Bool?

    var awardType: AwardType {
        let words = Set(name.lowercased().split { !$0.isLetter }.map(String.init))
        // Guild categories can contain “performance” even when the award is for stunt work.
        if !words.isDisjoint(with: [
            "stunt", "stunts", "casting", "cinematographer", "cinematography", "costume", "costumes",
            "editing", "editor", "makeup", "hairstyling", "sound", "design", "effects",
            "score", "song", "composer", "composing"
        ]) || (words.contains("music") && !words.contains("video")) {
            return .crafts
        }
        if !words.isDisjoint(with: ["director", "directors", "directing", "directorial", "direction"]) { return .directing }
        if !words.isDisjoint(with: ["writer", "writers", "writing", "written", "screenplay", "screenwriting", "script"]) { return .writing }
        if !words.isDisjoint(with: [
            "acting", "actor", "actors", "actress", "actresses", "cast", "ensemble", "performance", "performer",
            "narrator", "host", "presenter", "talent", "newcomer"
        ]) || name.localizedCaseInsensitiveContains("Rising Star") {
            return .acting
        }
        return .titles
    }

    var media: Set<MediaKind> {
        // A linked title can be a movie while the award itself belongs to television.
        if forSeries == true, ["television movie", "tv movie", "made for television", "motion picture – television"]
            .contains(where: { name.localizedCaseInsensitiveContains($0) }) { return [.tv] }
        var kinds = Set<MediaKind>()
        if forMovies == true { kinds.insert(.movie) }
        if forSeries == true { kinds.insert(.tv) }
        return kinds
    }
}

struct SearchAwardNominee: Codable, Hashable, Identifiable, Sendable {
    struct WorkReference: Hashable, Sendable {
        let id: Int
        let kind: MediaKind
    }

    struct Work: Codable, Hashable, Sendable {
        let id: Int
        let name: String?
        let image: String?
    }

    struct Episode: Codable, Hashable, Sendable {
        let id: Int
        let name: String?
        let image: String?
        let seriesId: Int?
    }

    struct Character: Codable, Hashable, Sendable {
        let name: String?
        let peopleId: Int?
        let personName: String?
        let personImgURL: String?
        let movieId: Int?
        let seriesId: Int?
    }

    let id: Int
    let year: String?
    let name: String?
    let isWinner: Bool?
    let details: String?
    var category: String? = nil
    let movie: Work?
    let series: Work?
    let episode: Episode?
    let character: Character?

    var ceremonyYear: Int? {
        year.flatMap { value in
            guard value.count >= 4, let number = Int(value.prefix(4)), (1800...2200).contains(number) else { return nil }
            return number
        }
    }

    var work: WorkReference? {
        if let id = movie?.id ?? character?.movieId, id > 0 { return .init(id: id, kind: .movie) }
        if let id = series?.id ?? episode?.seriesId ?? character?.seriesId, id > 0 { return .init(id: id, kind: .tv) }
        return nil
    }

    var workName: String? { Self.clean(movie?.name) ?? Self.clean(series?.name) ?? Self.clean(episode?.name) }
    var creditedName: String? { Self.clean(character?.personName) ?? Self.clean(name) }
    var title: String { creditedName ?? workName ?? Self.clean(character?.name) ?? "Nominee" }
    var subtitle: String? {
        if creditedName != nil { return workName }
        if let episodeName = Self.clean(episode?.name), episodeName != title { return episodeName }
        return Self.clean(character?.name).flatMap { $0 == title ? nil : $0 }
    }
    var note: String? { Self.clean(details) }
    var subcategory: String? { Self.clean(category) }
    var image: String? {
        Self.clean(character?.personImgURL) ?? Self.clean(movie?.image) ?? Self.clean(series?.image) ?? Self.clean(episode?.image)
    }

    private static func clean(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

struct SearchAwardResults: Codable, Sendable {
    let id: Int
    let nominees: [SearchAwardNominee]?
    var rows: [SearchAwardNominee] {
        var seen = Set<Int>()
        return (nominees ?? []).filter { seen.insert($0.id).inserted }
    }
}

struct SearchAwardArchive: Codable, Sendable {
    let updatedAt: Date
    let categories: [SearchAwardCategory]
    let results: [Int: SearchAwardResults]
    let failedCategoryIDs: Set<Int>

    var incompleteCount: Int { categories.filter { results[$0.id] == nil || failedCategoryIDs.contains($0.id) }.count }
}

struct SearchAwardEditionIndex {
    struct Section: Identifiable {
        let category: SearchAwardCategory
        let nominees: [SearchAwardNominee]
        var id: Int { category.id }

        var media: Set<MediaKind> {
            let allowed = category.media
            if allowed.count == 1 { return allowed }
            return nominees.reduce(into: Set<MediaKind>()) { kinds, nominee in
                if let kind = nominee.work?.kind { kinds.insert(kind) }
                else { kinds.formUnion(allowed) }
            }
        }

        func matching(_ medium: MediaKind?) -> Section? {
            guard let medium else { return self }
            let allowed = category.media
            if allowed.count == 1 { return allowed.contains(medium) ? self : nil }
            let rows = nominees.filter { nominee in
                if let kind = nominee.work?.kind { return kind == medium }
                return allowed.isEmpty || allowed.contains(medium)
            }
            return rows.isEmpty ? nil : Section(category: category, nominees: rows)
        }
    }

    let years: [Int]
    let sections: [Int: [Section]]

    init(_ archive: SearchAwardArchive) {
        var sections: [Int: [Section]] = [:]
        for category in archive.categories {
            let byYear = Dictionary(grouping: archive.results[category.id]?.rows ?? [], by: \.ceremonyYear)
            for (year, nominees) in byYear {
                guard let year else { continue }
                sections[year, default: []].append(Section(category: category, nominees: nominees))
            }
        }
        self.years = sections.keys.sorted(by: >)
        self.sections = sections
    }
}

actor SearchAwardCache {
    static let shared = SearchAwardCache()
    private var memory: [Int: SearchAwardArchive] = [:]
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "TwilDiaryAwards-v1", directoryHint: .isDirectory)

    func read(_ ceremony: Int) -> SearchAwardArchive? {
        if let cached = memory[ceremony] { return cached }
        guard let url = directory?.appending(path: "\(ceremony).json"),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(SearchAwardArchive.self, from: data) else { return nil }
        memory[ceremony] = cached
        return cached
    }

    func save(_ archive: SearchAwardArchive, ceremony: Int) {
        if let current = memory[ceremony], current.updatedAt > archive.updatedAt { return }
        memory[ceremony] = archive
        guard let directory, let data = try? JSONEncoder().encode(archive) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "\(ceremony).json"), options: .atomic)
    }
}

@MainActor enum SearchAwardsArchiveService {
    private static var catalog: (date: Date, ceremonies: [SearchAwardCeremony])?

    static func ceremonies(key: String) async throws -> [SearchAwardCeremony] {
        if let catalog, Date.now.timeIntervalSince(catalog.date) < 900 { return catalog.ceremonies }
        let ceremonies = try await TVDBDirect.awardCatalog(key: key)
        let ranks = Dictionary(uniqueKeysWithValues: SearchAwardCeremony.featured.enumerated().map { ($0.element.id, $0.offset) })
        let sorted = ceremonies.sorted { first, second in
            let a = ranks[first.id] ?? Int.max, b = ranks[second.id] ?? Int.max
            return a == b ? first.name.localizedStandardCompare(second.name) == .orderedAscending : a < b
        }
        catalog = (.now, sorted)
        return sorted
    }

    static func load(
        _ ceremony: SearchAwardCeremony, key: String, refresh: Bool = false,
        progress: @MainActor (Int, Int) -> Void
    ) async throws -> SearchAwardArchive {
        let startedAt = Date.now
        let previous = await SearchAwardCache.shared.read(ceremony.id)
        let recent = previous.map { startedAt.timeIntervalSince($0.updatedAt) < 21_600 } ?? false
        if !refresh, recent, let previous, previous.incompleteCount == 0 { return previous }
        let categories = try await TVDBDirect.awardCategories(ceremony.id, key: key)
        let previousResults = previous?.results ?? [:]
        let validIDs = Set(categories.map(\.id))
        var results = previousResults.filter { validIDs.contains($0.key) }
        let pending = categories.filter {
            refresh || !recent || results[$0.id] == nil || previous?.failedCategoryIDs.contains($0.id) == true
        }
        var failures = Set<Int>()
        let refreshing = Set(pending.map(\.id))
        var finished = Set<Int>()
        progress(categories.count - pending.count, categories.count)

        // A category reply contains its entire history. Bound in-flight reads per ceremony.
        for start in stride(from: 0, to: pending.count, by: 4) {
            if Task.isCancelled { break }
            let batch = pending[start..<min(start + 4, pending.count)]
            await withTaskGroup(of: (Int, SearchAwardResults?).self) { group in
                for category in batch {
                    group.addTask {
                        let result = try? await TVDBDirect.awardResults(category.id, key: key)
                        return (category.id, result)
                    }
                }
                for await (id, result) in group {
                    finished.insert(id)
                    if let result { results[id] = result }
                    else { failures.insert(id) }
                    progress(categories.count - pending.count + finished.count, categories.count)
                }
            }
        }

        failures.formUnion(refreshing.subtracting(finished))
        if !pending.isEmpty && failures.count == pending.count && results.isEmpty {
            try Task.checkCancellation()
            throw APIError.message("TheTVDB couldn’t load the category results.")
        }
        let archived = SearchAwardArchive(updatedAt: startedAt, categories: categories, results: results, failedCategoryIDs: failures)
        await SearchAwardCache.shared.save(archived, ceremony: ceremony.id)
        try Task.checkCancellation()
        return archived
    }
}

#if DEBUG
extension SearchAwardArchive {
    static var preview: Self {
        let drama = SearchAwardCategory(id: 126, name: "Outstanding Drama Series", forSeries: true, forMovies: false)
        let comedy = SearchAwardCategory(id: 125, name: "Outstanding Comedy Series", forSeries: true, forMovies: false)
        let acting = SearchAwardCategory(id: 137, name: "Outstanding Lead Actor in a Drama Series",
                                         forSeries: true, forMovies: false)
        let sopranos = SearchAwardNominee(id: 1, year: "2004", name: nil, isWinner: true, details: nil,
                                        movie: nil, series: .init(id: 75299, name: "The Sopranos", image: nil),
                                        episode: nil, character: nil)
        let westWing = SearchAwardNominee(id: 2, year: "2004", name: nil, isWinner: false, details: nil,
                                        movie: nil, series: .init(id: 72521, name: "The West Wing", image: nil),
                                        episode: nil, character: nil)
        let arrested = SearchAwardNominee(id: 3, year: "2004", name: nil, isWinner: true, details: nil,
                                         movie: nil, series: .init(id: 72173, name: "Arrested Development", image: nil),
                                         episode: nil, character: nil)
        let practice = SearchAwardNominee(id: 4, year: "1999", name: nil, isWinner: true, details: nil,
                                         movie: nil, series: .init(id: 78376, name: "The Practice", image: nil),
                                         episode: nil, character: nil)
        let leadActor = SearchAwardNominee(id: 5, year: "2004", name: nil, isWinner: true, details: "For playing Alan Shore",
                                          movie: nil, series: practice.series, episode: nil, character: nil)
        return Self(updatedAt: .now, categories: [drama, comedy, acting],
                    results: [drama.id: .init(id: drama.id, nominees: [sopranos, westWing, practice]),
                              comedy.id: .init(id: comedy.id, nominees: [arrested]),
                              acting.id: .init(id: acting.id, nominees: [leadActor])], failedCategoryIDs: [])
    }
}
#endif
