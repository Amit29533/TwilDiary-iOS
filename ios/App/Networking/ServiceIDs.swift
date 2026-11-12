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
        let refs = library.plays.map(\.title) + library.ratings.map(\.title) + (library.watchlist + library.favorites + library.dropped).map(\.title)
        // Two Simkl entries for one diary title (a season Simkl files as its own entry, placed on
        // the diary's show through Anime-Lists): neither is learned, so the show keeps the Simkl id
        // it had and writes for it don't go to that season's entry.
        var simklIDs: [String: Set<Int>] = [:]
        for ref in refs { if let key = ref.diaryKey, let id = ref.simklId { simklIDs[key, default: []].insert(id) } }
        func take(_ ref: TraktTitleRef) {
            guard let key = ref.diaryKey else { return }
            var entry = known[key] ?? Known()
            let before = entry
            if let id = ref.simklId, (simklIDs[key]?.count ?? 0) <= 1 { entry.simkl = id; entry.missing["simkl"] = nil }
            if let id = ref.weTrakrId { entry.wetrakr = id; entry.missing["wetrakr"] = nil }
            if entry.imdb == nil, let id = ref.imdbId, !id.isEmpty { entry.imdb = id }
            if entry.tvdb == nil, let id = ref.tvdbId { entry.tvdb = id }
            if entry != before { known[key] = entry; changed = true }
        }
        refs.forEach(take)
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
        // Simkl files anime under its own entries (one per season, each with its own Simkl id) and
        // often gives no TMDB id for them, only IMDb's or TVDB's. Those are matched through the ids
        // another service gave for the same title; otherwise every watch of them looks missing on
        // Simkl, is sent again on each match and never sticks. Only an id that names one title here.
        var byIMDb: [String: String] = [:], byTVDB: [Int: String] = [:]
        var sharedIMDb = Set<String>(), sharedTVDB = Set<Int>()
        for (key, entry) in known {
            if let id = entry.imdb, !id.isEmpty {
                if let other = byIMDb[id], other != key { sharedIMDb.insert(id) } else { byIMDb[id] = key }
            }
            if let id = entry.tvdb, key.hasPrefix("tv:") {
                if let other = byTVDB[id], other != key { sharedTVDB.insert(id) } else { byTVDB[id] = key }
            }
        }
        for id in sharedIMDb { byIMDb[id] = nil }
        for id in sharedTVDB { byTVDB[id] = nil }
        guard !bySimkl.isEmpty || !byWeTrakr.isEmpty || !byIMDb.isEmpty || !byTVDB.isEmpty else { return library }
        func otherIDs(_ ref: TraktTitleRef) -> String? {
            // The kind must agree: an anime film and its series can share nothing but a name.
            let prefix = ref.kind == .movie ? "movie:" : "tv:"
            if let key = ref.imdbId.flatMap({ byIMDb[$0] }), key.hasPrefix(prefix) { return key }
            if ref.kind == .show, let key = ref.tvdbId.flatMap({ byTVDB[$0] }) { return key }
            return nil
        }
        func fill(_ ref: TraktTitleRef) -> TraktTitleRef {
            guard ref.tmdbId == nil, let key = ref.simklId.flatMap({ bySimkl[$0] }) ?? ref.weTrakrId.flatMap({ byWeTrakr[$0] }) ?? otherIDs(ref),
                  let tmdb = Int(key.split(separator: ":").last ?? "") else { return ref }
            return TraktTitleRef(kind: key.hasPrefix("movie:") ? .movie : .show, traktId: ref.traktId, tmdbId: tmdb, imdbId: ref.imdbId, tvdbId: ref.tvdbId,
                                 name: ref.name, year: ref.year, simklId: ref.simklId, weTrakrId: ref.weTrakrId)
        }
        var filled = library
        filled.plays = library.plays.map { play in
            let title = fill(play.title)
            // Simkl files anime OVAs and ONAs as one-episode shows: found to be the diary's film,
            // the watch is the film's, with no episode number. Kept as "film S1E1" it matched no
            // diary watch, so Force Match took the film's watch off Simkl right after sending it.
            let film = title.kind == .movie && play.title.kind != .movie
            return TraktPlay(historyId: play.historyId, title: title, season: film ? nil : play.season, episode: film ? nil : play.episode,
                             watchedAt: play.watchedAt, remoteId: play.remoteId)
        }
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
        // Look-ups that got no answer in a row: after three the service isn't answering (or is
        // limiting us), and the rest of this write's look-ups wait for next time.
        var unanswered = 0
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
                    if native == nil, !gaveUp, lookups < lookupsPerWrite, unanswered < 3 {
                        // Spaced out: a write of a hundred new titles is a hundred look-ups, and
                        // sent all at once they trip the service's limit before the write itself.
                        if lookups > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                        lookups += 1
                        switch await lookUp(provider, tmdb: tmdb, show: slot == "shows", config: config, client: client) {
                        case .found(let id):
                            native = id; unanswered = 0
                            if provider == .simkl { entry.simkl = id } else { entry.wetrakr = id }
                            entry.missing[service] = nil
                        case .absent:
                            entry.missing[service] = .now; unanswered = 0
                        case .failed:
                            unanswered += 1  // Couldn't ask: Simkl gets it by TMDB id as before; asked again next time.
                        }
                        known[key] = entry
                    }
                    if let native {
                        if provider == .simkl { ids["simkl"] = native } else { item["id"] = native }
                    } else if provider == .wetrakr, entry.missing[service] == nil {
                        // Not looked up yet: left out of this write (counted in `waiting`, and
                        // answered as not found this time), so one title WeTrakr can't be asked
                        // about doesn't hold back the others in the same call.
                        waiting += 1
                        missing.append(["ids": ["tmdb": tmdb], "slot": slot])
                        continue
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
                return Self.weTrakrHasNone(data) ? .absent : .failed
            } catch APIError.rejected(let status, _) where status == 404 { return .absent }
            catch { return .failed }
        default:
            return .failed
        }
    }
    /// WeTrakr's look-up answered with no matches: an empty list, bare or under the key it lists
    /// them by. (Anything else unreadable stays "no answer" and is asked again.)
    nonisolated static func weTrakrHasNone(_ data: Data) -> Bool {
        let root = try? JSONSerialization.jsonObject(with: data)
        if let list = root as? [Any] { return list.isEmpty }
        guard let object = root as? [String: Any] else { return false }
        return ["data", "results", "matches", "items"].contains { (object[$0] as? [Any])?.isEmpty == true }
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
