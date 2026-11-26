import Foundation
import TwilDiaryCore

/// Where a synopsis comes from: TMDB (the page's own), TheTVDB, or AniList (anime only).
enum SynopsisSource: String, CaseIterable, Sendable {
    case tmdb, tvdb, anilist
    var logo: BrandLogo.Service {
        switch self {
        case .tmdb: .tmdb
        case .tvdb: .tvdb
        case .anilist: .anilist
        }
    }
    var name: String {
        switch self {
        case .tmdb: "TMDB"
        case .tvdb: "TheTVDB"
        case .anilist: "AniList"
        }
    }
}

/// The other synopses beside TMDB's: TheTVDB's in English (a show, a film or an episode, found by
/// the ids TMDB lists for it) and AniList's for anime (by the community id map). Each answer, none
/// included, is kept on the phone, so a page asks once; a failed request isn't kept, so it's asked
/// again next time.
@MainActor enum Synopses {
    private enum Outcome { case text(String), none, failed }
    private static var kept: [String: String] = load()
    private static var asking: [String: Task<String?, Never>] = [:]
    /// A save waiting (the cache is written at most every few seconds, not on every answer).
    private static var saving: Task<Void, Never>?
    private static let file = URL.cachesDirectory.appending(path: "synopses.json")
    private static let limit = 3000

    /// A show's or film's synopsis from TheTVDB.
    static func tvdbTitle(tmdb: Int, series: Bool, store: DiaryStore) async -> String? {
        await cached("tvdb|\(series ? "tv" : "movie")|\(tmdb)") {
            guard let key = TVDBDirect.key(store), let token = TMDBDirect.token(store) else { return .failed }
            guard let ids = try? await TMDBDirect.object("\(series ? "tv" : "movie")/\(tmdb)/external_ids", query: [:], token: token) else { return .failed }
            do {
                if series {
                    guard let tvdb = ids["tvdb_id"] as? Int, tvdb > 0 else { return .none }
                    return outcome(try await TVDBDirect.overview("series/\(tvdb)/translations/eng", key: key))
                }
                // A film: TheTVDB found by its IMDb id (TMDB lists no TheTVDB id for films).
                guard let imdb = ids["imdb_id"] as? String, imdb.hasPrefix("tt") else { return .none }
                guard let movie = try await TVDBDirect.movieID(remote: imdb, key: key) else { return .none }
                return outcome(try await TVDBDirect.overview("movies/\(movie)/translations/eng", key: key))
            } catch {
                return .failed
            }
        }
    }

    /// An episode's synopsis from TheTVDB, by the TheTVDB id TMDB lists for that very episode (so a
    /// show numbered differently on the two still finds the right one).
    static func tvdbEpisode(tmdb: Int, season: Int, number: Int, store: DiaryStore) async -> String? {
        await cached("tvdb|ep|\(tmdb)|\(season)|\(number)") {
            guard let key = TVDBDirect.key(store), let token = TMDBDirect.token(store) else { return .failed }
            guard let ids = try? await TMDBDirect.object("tv/\(tmdb)/season/\(season)/episode/\(number)/external_ids", query: [:], token: token) else { return .failed }
            guard let tvdb = ids["tvdb_id"] as? Int, tvdb > 0 else { return .none }
            do { return outcome(try await TVDBDirect.overview("episodes/\(tvdb)/translations/eng", key: key)) }
            catch { return .failed }
        }
    }

    /// An anime's description from AniList (a show's first season, a film's own entry), as plain text
    /// with its spoilers left out.
    static func aniList(tmdb: Int, film: Bool) async -> String? {
        await cached("anilist|\(film ? "movie" : "tv")|\(tmdb)") {
            // Not listed: none. Offline or the map down: failed, so it's asked again next time (it
            // was kept as "none", and the synopsis never came once back online).
            let id: Int
            do {
                guard let found = try await AniListSync.lookUpMappedID(tmdb: tmdb, film: film) else { return .none }
                id = found
            } catch { return .failed }
            let raw: String?
            do { raw = try await AniListClient.shared.mediaDescription(id) } catch { return .failed }
            return outcome(raw.map { AniListText.readable($0, hideSpoilers: true) })
        }
    }

    /// Text that says the same as `other` (or nothing): not worth a choice of its own.
    static func same(_ text: String, as other: String) -> Bool {
        func plain(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = plain(text), b = plain(other)
        return a.isEmpty || a == b
    }

    private static func outcome(_ text: String?) -> Outcome {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? .none : .text(trimmed)
    }
    private static func cached(_ key: String, _ fetch: @escaping @MainActor () async -> Outcome) async -> String? {
        if let saved = kept[key] { return saved.isEmpty ? nil : saved }
        if let running = asking[key] { return await running.value }
        let task = Task<String?, Never> { @MainActor in
            switch await fetch() {
            case .text(let text): remember(key, text); return text
            case .none: remember(key, ""); return nil
            case .failed: return nil
            }
        }
        asking[key] = task
        let value = await task.value
        asking[key] = nil
        return value
    }
    private static func remember(_ key: String, _ text: String) {
        if kept.count >= limit { kept.removeAll() }
        kept[key] = text
        // Written once a few seconds on (paging through episodes rewrote the whole cache for each).
        guard saving == nil else { return }
        saving = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let snapshot = kept, file = file
            saving = nil
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
            }.value
        }
    }
    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return saved
    }
}
