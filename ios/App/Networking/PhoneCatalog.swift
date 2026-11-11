import Foundation
import TwilDiaryCore

/// What the phone knows about titles that are only on Trakt (or Simkl, MDBList, WeTrakr): their
/// TMDB details (poster, seasons, category…), read with your TMDB key and kept in a file. These
/// titles used to be copied into your server's diary just to have a poster; now they stay on the
/// phone, and a title joins the server only when you give it something Trakt can't hold (a note,
/// tags, Queue, Trash). Details are read again after a week.
@MainActor final class PhoneCatalog {
    static let shared = PhoneCatalog()
    private struct Entry: Codable { let title: MediaTitle; let fetchedAt: Date }
    private let file = URL.applicationSupportDirectory.appending(path: "Trackers/catalog.json")
    private lazy var entries: [String: Entry] = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    private var filling = false, fillingEpisodes = false
    private var failed: [String: Date] = [:]
    private struct Episodes: Codable { let list: [CatalogEpisodeFact]; let fetchedAt: Date }
    private let episodesFile = URL.applicationSupportDirectory.appending(path: "Trackers/episodes.json")
    private lazy var episodeEntries: [String: Episodes] = (try? Data(contentsOf: episodesFile)).flatMap { try? JSONDecoder().decode([String: Episodes].self, from: $0) } ?? [:]
    /// Episode lists by show key, for `TraktDiary.addingCatalogEpisodes`.
    var episodes: [String: [CatalogEpisodeFact]] { episodeEntries.mapValues(\.list) }

    /// Reads every season's episodes for these shows (missing, or a week old; a show with a season
    /// still airing, a day old), six shows a pass, then rebuilds the diary.
    func fillEpisodes(_ keys: [String], store: DiaryStore) async {
        guard let token = TMDBDirect.token(store), !fillingEpisodes else { return }
        let now = Date.now
        let due = keys.filter { key in
            guard failed["episodes:" + key].map({ now.timeIntervalSince($0) > 600 }) ?? true else { return false }
            guard let entry = episodeEntries[key] else { return true }
            let airing = entry.list.contains { ($0.airedOn ?? "") >= DiaryDate.day(now.addingTimeInterval(-14 * 86_400)) }
            return now.timeIntervalSince(entry.fetchedAt) > (airing ? 86_400 : 7 * 86_400)
        }.prefix(6)
        guard !due.isEmpty else { return }
        fillingEpisodes = true
        defer { fillingEpisodes = false }
        var changed = false
        for key in due {
            guard let id = Int(key.dropFirst(3)) else { continue }
            guard let details = try? await TMDBDirect.details(CatalogRoute(kind: .tv, id: id), token: token) else { failed["episodes:" + key] = now; continue }
            let numbers = (details.seasons ?? []).map(\.number).filter { $0 >= 0 }
            var list: [CatalogEpisodeFact] = [], complete = true
            let reads = numbers.map { number in
                Task { @MainActor () -> [CatalogEpisodeFact]? in
                    guard let page = try? await TMDBDirect.season(id, number: number, reveal: true, token: token) else { return nil }
                    return page.items.map { CatalogEpisodeFact(season: number, number: $0.number, name: $0.name, overview: $0.overview,
                                                               airedOn: $0.airedOn, stillPath: $0.stillPath, communityScore: $0.communityScore) }
                }
            }
            for read in reads { if let facts = await read.value { list += facts } else { complete = false } }
            // A season that couldn't be read keeps the last list rather than losing episodes.
            guard complete || episodeEntries[key] == nil else { failed["episodes:" + key] = now; continue }
            episodeEntries[key] = Episodes(list: list, fetchedAt: now); changed = true
            if details.seasons.map({ $0.isEmpty }) == false, entries[key] == nil {
                entries[key] = Entry(title: TraktDiary.catalogTitle(details), fetchedAt: now)
            }
        }
        if changed {
            try? FileManager.default.createDirectory(at: episodesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(episodeEntries).write(to: episodesFile, options: .atomic)
            store.applyDiarySource()
        }
    }

    /// Titles by key ("tv:1399"), for `TraktDiary.build`.
    var titles: [String: MediaTitle] { entries.mapValues(\.title) }

    /// Reads the details of these keys that are missing or a week old (at most 24 at a time, eight
    /// side by side), then rebuilds the diary. Without your TMDB key: false (nothing to read with).
    @discardableResult func fill(_ keys: [String], store: DiaryStore) async -> Bool {
        guard let token = TMDBDirect.token(store) else { return false }
        guard !filling else { return true }
        let now = Date.now
        let due = keys.filter { key in
            (entries[key].map { now.timeIntervalSince($0.fetchedAt) > 7 * 86_400 } ?? true) && (failed[key].map { now.timeIntervalSince($0) > 600 } ?? true)
        }.prefix(24)
        guard !due.isEmpty else { return true }
        filling = true
        defer { filling = false }
        var changed = false
        for start in stride(from: 0, to: due.count, by: 8) {
            let chunk = Array(due)[start..<min(start + 8, due.count)]
            let reads = chunk.map { key in
                Task { @MainActor () -> (String, MediaTitle?) in
                    let parts = key.split(separator: ":")
                    guard parts.count == 2, let id = Int(parts[1]) else { return (key, nil) }
                    let route = CatalogRoute(kind: parts[0] == "movie" ? .movie : .tv, id: id)
                    return (key, (try? await TMDBDirect.details(route, token: token)).map(TraktDiary.catalogTitle))
                }
            }
            for read in reads {
                let (key, title) = await read.value
                if let title { entries[key] = Entry(title: title, fetchedAt: now); changed = true } else { failed[key] = now }
            }
        }
        if changed {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
            store.applyDiarySource()
        }
        return true
    }
    func forget() {
        entries = [:]; failed = [:]; episodeEntries = [:]
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: episodesFile)
    }
}

extension DiaryStore {
    /// A title only on the service joins your server diary now, because you're giving it something
    /// Trakt can't hold. Returns its server record.
    func joinServer(_ title: MediaTitle) async throws -> MediaTitle {
        guard isServiceOnly(title) else { return title }
        guard let tmdb = title.tmdbId else { throw APIError.message("This title has no TMDB id, so it can’t join your server diary.") }
        let found = try await browse(CatalogRoute(kind: title.isSeries ? .tv : .movie, id: tmdb))
        let id: String
        if let saved = found.libraryTitle { id = saved.id }
        else if let added = await importTitle(found.details, category: title.category, sendToService: false) { id = added }
        else { throw APIError.message(error ?? "This title couldn’t join your server diary. Try again.") }
        adoptedTraktKeys.insert(title.id)
        guard let joined = self.title(id) else {
            throw APIError.message("This title joined your server diary; try again in a moment.")
        }
        return joined
    }
}
