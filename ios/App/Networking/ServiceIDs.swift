import Foundation
import TwilDiaryCore

/// Each title's ids on every service, the way Cinopsys keeps them: learned from what each service
/// sends us (Trakt gives IMDb and TVDB ids; Simkl and WeTrakr their own), looked up once on the
/// service when it's missing (Simkl's search/id, WeTrakr's media/external), and remembered. Every
/// write to Simkl, WeTrakr or MDBList then names the title by the service's own id as well as
/// TMDB's, so it lands on the right title (anime included). A title the service doesn't have is
/// left out of the write and reported as not found, instead of being sent and retried forever.
@MainActor final class ServiceIDs {
    static let shared = ServiceIDs()

    struct Known: Codable, Equatable, Sendable {
        var simkl: Int?
        var wetrakr: Int?
        var imdb: String?
        var tvdb: Int?
        /// When a service said it doesn't have the title (asked again after a week).
        var missing: [String: Date] = [:]
    }
    private var known: [String: Known]
    private let file = URL.applicationSupportDirectory.appending(path: "Trackers/ids.json")
    /// Look-ups one write may make (the rest go as they are and are looked up next time).
    private let lookupsPerWrite = 120

    private init() {
        known = (try? Data(contentsOf: URL.applicationSupportDirectory.appending(path: "Trackers/ids.json")))
            .flatMap { try? JSONDecoder().decode([String: Known].self, from: $0) } ?? [:]
    }

    func known(_ key: String) -> Known? { known[key] }

    /// Learns the ids a service's library carries.
    func learn(from library: TraktLibrary) {
        var changed = false
        func take(_ ref: TraktTitleRef) {
            guard let key = ref.diaryKey else { return }
            var entry = known[key] ?? Known()
            let before = entry
            if let id = ref.simklId { entry.simkl = id; entry.missing["simkl"] = nil }
            if let id = ref.weTrakrId { entry.wetrakr = id; entry.missing["wetrakr"] = nil }
            if entry.imdb == nil, let id = ref.imdbId, !id.isEmpty { entry.imdb = id }
            if entry.tvdb == nil, let id = ref.tvdbId { entry.tvdb = id }
            if entry != before { known[key] = entry; changed = true }
        }
        library.plays.forEach { take($0.title) }
        library.ratings.forEach { take($0.title) }
        (library.watchlist + library.favorites + library.dropped).forEach { take($0.title) }
        if changed { BackgroundFiles.save(known, to: file) }
    }

    func forget() { known = [:]; BackgroundFiles.cancel(file); try? FileManager.default.removeItem(at: file) }

    /// A service's library with the TMDB id filled in for titles it lists without one (Simkl's
    /// anime often has only its own id) when this phone already matched that id once, so they
    /// line up with the diary instead of showing as missing on both sides.
    func filledIn(_ library: TraktLibrary) -> TraktLibrary {
        var bySimkl: [Int: String] = [:], byWeTrakr: [Int: String] = [:]
        for (key, entry) in known {
            if let id = entry.simkl { bySimkl[id] = key }
            if let id = entry.wetrakr { byWeTrakr[id] = key }
        }
        guard !bySimkl.isEmpty || !byWeTrakr.isEmpty else { return library }
        func fill(_ ref: TraktTitleRef) -> TraktTitleRef {
            guard ref.tmdbId == nil, let key = ref.simklId.flatMap({ bySimkl[$0] }) ?? ref.weTrakrId.flatMap({ byWeTrakr[$0] }),
                  let tmdb = Int(key.split(separator: ":").last ?? "") else { return ref }
            return TraktTitleRef(kind: key.hasPrefix("movie:") ? .movie : .show, traktId: ref.traktId, tmdbId: tmdb, imdbId: ref.imdbId, tvdbId: ref.tvdbId,
                                 name: ref.name, year: ref.year, simklId: ref.simklId, weTrakrId: ref.weTrakrId)
        }
        var filled = library
        filled.plays = library.plays.map { TraktPlay(historyId: $0.historyId, title: fill($0.title), season: $0.season, episode: $0.episode, watchedAt: $0.watchedAt, remoteId: $0.remoteId) }
        filled.ratings = library.ratings.map { TraktRating(title: fill($0.title), rating: $0.rating, ratedAt: $0.ratedAt) }
        filled.watchlist = library.watchlist.map { TraktListed(title: fill($0.title), listedAt: $0.listedAt) }
        filled.favorites = library.favorites.map { TraktListed(title: fill($0.title), listedAt: $0.listedAt) }
        filled.dropped = library.dropped.map { TraktListed(title: fill($0.title), listedAt: $0.listedAt) }
        filled.notes = library.notes.map { TraktNote(id: $0.id, title: $0.title.map(fill), text: $0.text, updatedAt: $0.updatedAt) }
        return filled
    }

    /// The write with every title's ids filled in for `provider`. Titles the service doesn't have
    /// are left out and returned (by name), to be reported as not found.
    func prepare(_ body: Data, for provider: SyncProviderKind, config: ExternalProviderConfig, client: DirectProviderClient) async -> (body: Data, missing: [[String: Any]], movies: Int, shows: Int, waiting: Int) {
        guard [.simkl, .wetrakr, .mdblist].contains(provider),
              var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return (body, [], 0, 0, 0) }
        // WeTrakr is only ever written by its own id (as Cinopsys does): a title whose id couldn't
        // be looked up yet makes the write wait, rather than go by TMDB id.
        var missing: [[String: Any]] = [], lookups = 0, kept = (movies: 0, shows: 0), waiting = 0
        let service = provider.rawValue
        for slot in ["movies", "shows"] {
            guard let items = root[slot] as? [[String: Any]] else { continue }
            var next: [[String: Any]] = []
            for var item in items {
                var ids = item["ids"] as? [String: Any] ?? [:]
                guard let tmdb = (ids["tmdb"] as? NSNumber)?.intValue else { next.append(item); continue }
                let key = (slot == "movies" ? "movie:" : "tv:") + String(tmdb)
                var entry = known[key] ?? Known()
                if ids["imdb"] == nil, let imdb = entry.imdb { ids["imdb"] = imdb }
                if slot == "shows", ids["tvdb"] == nil, let tvdb = entry.tvdb { ids["tvdb"] = tvdb }
                if provider != .mdblist {
                    var native = provider == .simkl ? entry.simkl : entry.wetrakr
                    let gaveUp = entry.missing[service].map { Date.now.timeIntervalSince($0) < 7 * 86_400 } ?? false
                    if native == nil, !gaveUp, lookups < lookupsPerWrite {
                        lookups += 1
                        switch await lookUp(provider, tmdb: tmdb, show: slot == "shows", config: config, client: client) {
                        case .found(let id):
                            native = id
                            if provider == .simkl { entry.simkl = id } else { entry.wetrakr = id }
                            entry.missing[service] = nil
                        case .absent:
                            entry.missing[service] = .now
                        case .failed:
                            break  // Couldn't ask: sent by TMDB id as before, asked again next time.
                        }
                        known[key] = entry
                    }
                    if let native {
                        if provider == .simkl { ids["simkl"] = native } else { item["id"] = native }
                    } else if provider == .wetrakr, entry.missing[service] == nil {
                        waiting += 1
                    } else if entry.missing[service] != nil {
                        // The service doesn't have it: not sent (and said), as Cinopsys drops it.
                        missing.append(["ids": ["tmdb": tmdb], "slot": slot])
                        continue
                    }
                }
                item["ids"] = ids
                next.append(item)
            }
            root[slot] = next
            if slot == "movies" { kept.movies = next.count } else { kept.shows = next.count }
        }
        if lookups > 0 { BackgroundFiles.save(known, to: file) }
        return ((try? JSONSerialization.data(withJSONObject: root)) ?? body, missing, kept.movies, kept.shows, waiting)
    }

    /// A look-up's answer: the service's id, a clear "not here", or no answer (try again later).
    enum LookUp: Equatable { case found(Int), absent, failed }
    private func lookUp(_ provider: SyncProviderKind, tmdb: Int, show: Bool, config: ExternalProviderConfig, client: DirectProviderClient) async -> LookUp {
        switch provider {
        case .simkl:
            var answer = LookUp.failed
            for type in show ? ["show", "tv"] : ["movie"] {
                do {
                    let found = Self.simklLookUp(try await client.read(config, path: "/search/id", query: ["tmdb": String(tmdb), "type": type]))
                    if case .found = found { return found }
                    if found == .absent { answer = .absent }
                } catch APIError.rejected(let status, _) where status == 404 { answer = .absent }
                catch { }
            }
            return answer
        case .wetrakr:
            do {
                let data = try await client.read(config, path: "/media/external/tmdb/\(tmdb)", query: ["type": show ? "show" : "movie"])
                if let id = TrackerPreviewStore.weTrakrMatch(data, show: show) { return .found(id) }
                return ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.isEmpty == true ? .absent : .failed
            } catch APIError.rejected(let status, _) where status == 404 { return .absent }
            catch { return .failed }
        default:
            return .failed
        }
    }
    /// Simkl's search/id answer: a list of matches (empty: Simkl doesn't have it), each with ids.simkl.
    nonisolated static func simklLookUp(_ data: Data) -> LookUp {
        let root = try? JSONSerialization.jsonObject(with: data)
        if let list = root as? [Any], list.isEmpty { return .absent }
        if let id = simklID(data) { return .found(id) }
        return .failed
    }
    /// Simkl's search/id answer: a list of matches (or one), each with ids.simkl.
    nonisolated static func simklID(_ data: Data) -> Int? {
        let root = try? JSONSerialization.jsonObject(with: data)
        let first = (root as? [[String: Any]])?.first ?? (root as? [String: Any])
        guard let first else { return nil }
        let ids = first["ids"] as? [String: Any] ?? first
        return (ids["simkl"] as? NSNumber)?.intValue ?? (ids["simkl_id"] as? NSNumber)?.intValue
    }

    /// Adds the titles left out of a write to the service's reply as not found, so the caller says so.
    nonisolated static func reply(_ data: Data, adding missing: [[String: Any]]) -> Data {
        guard !missing.isEmpty else { return data }
        var root = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        var notFound = root["not_found"] as? [String: Any] ?? [:]
        for item in missing {
            guard let slot = item["slot"] as? String else { continue }
            var list = notFound[slot] as? [Any] ?? []
            list.append(["ids": item["ids"] ?? [:]])
            notFound[slot] = list
        }
        root["not_found"] = notFound
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }
}
