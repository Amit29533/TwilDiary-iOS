import Foundation
import Observation
import TwilDiaryCore

/// One thing to copy to Simkl, with everything needed to send it, kept from the moment of the edit
/// (the diary may have changed by the time it goes).
struct SimklJob: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case watch, unwatch, rate, unrate, list }
    var id = UUID().uuidString
    var kind: Kind
    var tmdb: Int
    var movie: Bool
    var anime = false
    var name: String
    var year: Int?
    var season: Int?
    var number: Int?
    /// The episode's day per TMDB, to find it on Simkl by date when its number doesn't match.
    var airedOn: String?
    var watchedAt: String?
    var rating: Int?
    /// Simkl's list: plantowatch, watching, completed, hold or dropped.
    var list: String?
    var attempts = 0
    var lastError: String?
    var notBefore: Date?
    /// Already placed by air date (only tried once).
    var placedByDate = false
    /// Numbered the way Simkl numbers this entry (not TVDB's seasons).
    var ownNumbering = false
    /// The season and number as the diary had them, before placing by air date (for Try again).
    var diarySeason: Int?
    var diaryNumber: Int?
    /// Sent to this Simkl entry by its own id and numbering: a later cour of an anime TMDB keeps as
    /// one long season, a special that is its own entry, or a film Simkl files as anime.
    var entry: Int?
    /// Its air date was already looked for in Simkl's entries.
    var datesChecked: Bool?
    /// The placed entry's own anime-database ids (MAL, AniDB, AniList), sent with its Simkl id.
    var entryIDs: [String: String]?
    /// Sent by the episode's own TVDB id (from TMDB), when neither its date nor its title is on
    /// Simkl: Simkl's own TVDB mapping places it (Scroblarr's way; tested 2026-11-14).
    var tvdbEpisode: Int?
    /// Its TVDB id was tried: TVDB's seasons are the last try.
    var tvdbEpisodeTried: Bool?

    var titleKey: String { (movie ? "movie:" : "show:") + String(tmdb) }
    var itemKey: String { titleKey + (season.map { ":\($0):\(number ?? 0)" } ?? "") }
    var label: String { movie || season == nil ? name : "\(name) · S\(season ?? 0) E\(number ?? 0)" }
}

/// Something Simkl couldn't take: shown once on the Simkl page, never sent again.
struct SimklNotKept: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    let label: String
    let reason: String
    let at: Date
    /// What Simkl answered (its not_found part), to see why.
    var reply: String?
    /// The change itself, for Try again.
    var job: SimklJob?
}

/// What waits to go to Simkl, as Cinopsys keeps its copy queue: one job per change, a newer change
/// replacing or cancelling one that hasn't gone yet (watched then unwatched sends nothing), one
/// title's changes in order, and a waiting title not holding up the others.
struct SimklQueue: Codable, Equatable, Sendable {
    var jobs: [SimklJob] = []

    mutating func add(_ job: SimklJob) {
        // Only a job that hasn't been tried can be cancelled: a tried one may already be on Simkl.
        func untried(_ other: SimklJob) -> Bool { other.attempts == 0 && other.lastError == nil }
        switch job.kind {
        case .watch:
            if let index = jobs.lastIndex(where: { $0.kind == .unwatch && $0.itemKey == job.itemKey && untried($0) }) { jobs.remove(at: index); return }
        case .unwatch:
            if let index = jobs.lastIndex(where: { $0.kind == .watch && $0.itemKey == job.itemKey && untried($0) && ($0.watchedAt == job.watchedAt || job.watchedAt == nil) }) {
                jobs.remove(at: index); return
            }
        case .rate, .unrate:
            jobs.removeAll { ($0.kind == .rate || $0.kind == .unrate) && $0.titleKey == job.titleKey && untried($0) }
        case .list:
            jobs.removeAll { $0.kind == .list && $0.titleKey == job.titleKey && untried($0) }
        }
        jobs.append(job)
    }

    /// The next request, several titles at once (Simkl's docs: every write takes arrays): the first
    /// job that may go now and the later jobs of the same kind, up to 50 titles and 100 changes. A
    /// title's changes stay in order: once one of its jobs can't come along (another kind, or still
    /// waiting), its later jobs wait too, without holding up other titles.
    func batch(now: Date) -> [SimklJob] {
        var held = Set<String>(), titles = Set<String>(), batch: [SimklJob] = []
        for job in jobs {
            if held.contains(job.titleKey) { continue }
            let due = job.notBefore.map { $0 <= now } ?? true
            let fits = batch.isEmpty || (job.kind == batch[0].kind && batch.count < 100 && (titles.contains(job.titleKey) || titles.count < 50))
            guard due, fits else { held.insert(job.titleKey); continue }
            batch.append(job); titles.insert(job.titleKey)
        }
        return batch
    }
    /// When the first waiting job may go.
    var nextWake: Date? { jobs.compactMap(\.notBefore).min() }
}

/// Copies what you do in TwilDiary to Simkl when "Also save my activity to Simkl" is on.
@MainActor @Observable final class SimklMirror {
    static let shared = SimklMirror()
    private(set) var queue: SimklQueue
    private(set) var notKept: [SimklNotKept]
    /// Taken by Simkl, but filed as the other kind (a show sent as a movie, or the reverse): worth
    /// a look on Simkl, since it may be another title.
    private(set) var filedDifferently: [SimklNotKept]
    private(set) var sending = false
    private(set) var lastProblem: String?
    @ObservationIgnored private var matches: [String: SimklMatchRecord]
    /// Simkl's episode lists and linked entries, kept on the phone: Simkl allows each account a
    /// daily number of requests (found while testing: "user_limit_exceeded"), so they aren't asked
    /// again on every launch. Linked entries a week; an airing entry's episodes a day, a finished
    /// one's a month.
    struct Lookups: Codable, Sendable {
        struct Episodes: Codable, Sendable { let at: Date; let list: [SimklAPI.Episode] }
        struct Linked: Codable, Sendable { let at: Date; let detail: SimklAPI.Detail }
        struct Days: Codable, Sendable { let at: Date; let days: [Int: String]; var names: [Int: String]? = nil }
        var episodes: [Int: Episodes] = [:]
        var related: [Int: Linked] = [:]
        /// TMDB's air day and title of each episode of a season ("tmdb/season"), for episodes out
        /// the same day and episodes Simkl dates differently.
        var tmdbDays: [String: Days]? = [:]
    }
    @ObservationIgnored private var lookups: Lookups
    /// Each title's IMDb and TVDB ids, from TMDB (they don't change).
    @ObservationIgnored private var external: [String: SimklExternalIDs]
    /// For TMDB's ids (your TMDB key); set by each edit and on opening the app.
    @ObservationIgnored private weak var store: DiaryStore?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored var session: URLSession = .shared

    struct SimklMatchRecord: Codable, Equatable, Sendable { let match: SimklAPI.Match?; let at: Date }

    init() {
        queue = SimklStorage.load(SimklQueue.self, "queue.json") ?? SimklQueue()
        notKept = SimklStorage.load([SimklNotKept].self, "not-kept.json") ?? []
        filedDifferently = SimklStorage.load([SimklNotKept].self, "filed.json") ?? []
        matches = SimklStorage.load([String: SimklMatchRecord].self, "titles.json") ?? [:]
        lookups = SimklStorage.load(Lookups.self, "lookups.json") ?? Lookups()
        external = SimklStorage.load([String: SimklExternalIDs].self, "external.json") ?? [:]
    }

    // MARK: Taking edits

    /// An edit made in TwilDiary (from `DiaryStore.mirror`): turned into jobs while the diary
    /// still has everything they need, then sent in the background.
    func capture(_ mutation: OptimisticMutation, store: DiaryStore) {
        guard !store.isPreview else { return }
        SimklAccount.shared.adopt(store)
        guard SimklAccount.shared.canSend else { return }
        self.store = store
        for job in Self.jobs(for: mutation, store: store) { queue.add(job) }
        save()
        Task { await resume() }
    }

    static func jobs(for mutation: OptimisticMutation, store: DiaryStore) -> [SimklJob] {
        switch mutation {
        case .markWatch(_, let titleId, let episodeId, let watchedAt, _, let rewatch):
            // Simkl keeps one watched state per episode or movie: a rewatch is already there.
            guard !rewatch, let title = resolvedTitle(titleId, store: store), let tmdb = title.tmdbId else { return [] }
            var job = SimklJob(kind: .watch, tmdb: tmdb, movie: !title.isSeries, anime: Self.isAnime(title), name: title.name, year: title.year, watchedAt: watchedAt)
            if title.isSeries {
                guard let place = episode(episodeId, of: title, store: store) else { return [] }
                job.season = place.season; job.number = place.number; job.airedOn = place.airedOn
            }
            return [job]
        case .revokeWatch(let eventId, let titleId, _, _):
            // Another play of it is still in the diary: Simkl keeps it watched.
            guard let watch = DetachedWatch(eventID: eventId), !watch.othersRemain else { return [] }
            let title = resolvedTitle(titleId, store: store)
            return [SimklJob(kind: .unwatch, tmdb: watch.tmdbId, movie: watch.movie, anime: title.map(Self.isAnime) ?? false, name: title?.name ?? "TMDB \(watch.tmdbId)",
                             year: title?.year, season: watch.season, number: watch.number, watchedAt: watch.watchedAt)]
        case .patchTitle(let titleId, _, let status, let score, let clearScore, _, _, _, _):
            guard let title = resolvedTitle(titleId, store: store), let tmdb = title.tmdbId else { return [] }
            let base = SimklJob(kind: .rate, tmdb: tmdb, movie: !title.isSeries, anime: Self.isAnime(title), name: title.name, year: title.year)
            var jobs: [SimklJob] = []
            if let score { var job = base; job.rating = min(10, max(1, Int(score.rounded()))); jobs.append(job) }
            else if clearScore { var job = base; job.kind = .unrate; jobs.append(job) }
            if let status, let list = list(for: status, movie: !title.isSeries) { var job = base; job.kind = .list; job.list = list; jobs.append(job) }
            return jobs
        default:
            return []
        }
    }
    static func isAnime(_ title: MediaTitle) -> Bool { title.category == "anime" || title.category == "anime-movie" }
    /// The title, also one added a moment ago: adding a title rebuilds the diary in the background,
    /// so the phone's catalog has it before the diary does (Add to Planned from a title's page).
    private static func resolvedTitle(_ id: String, store: DiaryStore) -> MediaTitle? {
        store.title(id) ?? PhoneCatalog.shared.titles[id]
    }
    /// Simkl's list for a diary status (movies: planned, completed or dropped).
    static func list(for status: String, movie: Bool) -> String? {
        switch status {
        case "planned": "plantowatch"
        case "completed": "completed"
        case "dropped": "dropped"
        case "watching": movie ? nil : "watching"
        case "paused", "on_hold": movie ? nil : "hold"
        default: nil
        }
    }
    private static func episode(_ id: String?, of title: MediaTitle, store: DiaryStore) -> (season: Int, number: Int, airedOn: String?)? {
        guard let id else { return nil }
        if let episode = store.workspace.episodes.first(where: { $0.id == id }) { return (episode.season, episode.number, episode.airedOn) }
        // "<title>|s2e5", for an episode the diary names before its details are read.
        guard let range = id.range(of: "|s", options: .backwards) else { return nil }
        let parts = id[range.upperBound...].split(separator: "e").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1], nil) : nil
    }

    // MARK: Sending

    /// Sends what's waiting, one request at a time (Simkl takes one write per account at a time).
    func resume(store: DiaryStore? = nil) async {
        if let store, !store.isPreview { self.store = store; SimklAccount.shared.adopt(store) }
        guard !sending, SimklAccount.shared.canSend, !queue.jobs.isEmpty else { return }
        sending = true
        defer { sending = false; scheduleWake() }
        while true {
            let batch = queue.batch(now: .now)
            guard !batch.isEmpty, SimklAccount.shared.canSend else { return }
            guard let token = await SimklAccount.shared.token(session: session) else { SimklAccount.shared.signInLapsed(); return }
            let carryOn = await send(batch, api: SimklAPI(token: token, session: session))
            save()
            guard carryOn else { return }
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    /// One request for the batch. False when sending should stop for now (signed out, Simkl busy,
    /// no network).
    private func send(_ batch: [SimklJob], api: SimklAPI) async -> Bool {
        guard let first = batch.first else { return true }
        do {
            // Each title once: its IMDb and TVDB ids (TMDB) and Simkl's entry for it.
            var order: [String] = []
            for job in batch where !order.contains(job.titleKey) { order.append(job.titleKey) }
            var found: [String: SimklAPI.Match?] = [:], ids: [String: SimklExternalIDs?] = [:]
            for key in order {
                guard let job = batch.first(where: { $0.titleKey == key }) else { continue }
                let known = await externalIDs(job)
                ids[key] = known
                found[key] = batch.contains(where: { $0.titleKey == key && $0.entry == nil }) ? try await match(for: job, ids: known, api: api) : nil
            }
            // Anime episodes are placed by air date in Simkl's own entries before anything is sent:
            // TVDB's seasons can name another entry, and Simkl takes it without a word (TMDB's
            // Bleach S2 is Thousand-Year Blood War; TVDB's S2 is the 2004 show's second season).
            // TVDB's seasons are the fallback when Simkl lists no such date.
            let unplaced = batch.filter { $0.anime && !$0.movie && $0.entry == nil && $0.datesChecked != true && ($0.kind == .watch || $0.kind == .unwatch) }
            if !unplaced.isEmpty {
                for key in order where unplaced.contains(where: { $0.titleKey == key }) {
                    await placeFirst(unplaced.filter { $0.titleKey == key }, match: found[key] ?? nil, api: api)
                }
                return true
            }
            // A special Simkl lists on no such day isn't sent by TVDB's season 0: Simkl rarely places
            // it, and the try still puts the show on your Watching list with nothing watched.
            let unplacedSpecials = batch.filter { $0.anime && !$0.movie && $0.entry == nil && $0.season == 0 && $0.datesChecked == true }
            if !unplacedSpecials.isEmpty {
                finish(unplacedSpecials, reason: "Simkl lists no special or OVA on that day.")
                return true
            }
            let groups = SimklBody.groups(batch, simkl: { SimklBody.pin($0, found[$0.titleKey] ?? nil) }, external: { ids[$0.titleKey] ?? nil })
            let reply = try await api.post(SimklBody.path(first.kind), body: SimklBody.body(groups))
            var missing = SimklBody.notFound(reply, groups: groups)
            if first.kind == .watch { missing.formUnion(await readBack(reply, groups: groups, missing: missing, api: api)) }
            lastProblem = nil
            remove(batch.filter { !missing.contains($0.id) })
            let refused = batch.filter { missing.contains($0.id) }
            if !refused.isEmpty {
                let note = SimklBody.missingPart(reply)
                for key in order where refused.contains(where: { $0.titleKey == key }) {
                    await place(refused.filter { $0.titleKey == key }, match: found[key] ?? nil, api: api, reply: note)
                }
            }
            return true
        } catch let failure as SimklAPI.Failure {
            switch failure {
            case .signIn:
                // One renewal, then you're asked to sign in again (nothing waiting is lost).
                if await SimklAccount.shared.renew(session: session) != nil { return true }
                SimklAccount.shared.signInLapsed()
                lastProblem = "Simkl signed TwilDiary out. Sign in again to send what’s waiting."
                return false
            case .busy(let seconds):
                delay(batch, by: seconds, counting: false,
                      problem: seconds > 600 ? "Simkl’s daily request limit for your account is used up; what’s waiting goes after it resets." : nil)
                return false
            case .unavailable(let message):
                delay(batch, by: nil, counting: true, problem: message)
                return false
            case .refused(let status, let message):
                finish(batch, reason: "Simkl refused it (HTTP \(status)): " + String(message.prefix(120)))
                return true
            }
        } catch {
            delay(batch, by: nil, counting: true, problem: error.localizedDescription)
            return false
        }
    }

    /// Simkl's answer to a watch, read back (as CrossWatch does): a title filed as the other kind is
    /// listed to check; one Simkl said nothing about (neither took nor listed as not found) is
    /// looked up on the account (`/sync/watched`: in Simkl's own numbering, that very episode).
    /// Returns the jobs that aren't there. If the check itself fails, nothing is held against them.
    private func readBack(_ reply: Data, groups: [SimklBody.Group], missing: Set<String>, api: SimklAPI) async -> Set<String> {
        let filed = SimklBody.filed(reply, groups: groups)
        for (index, filing) in filed {
            guard let first = groups[index].jobs.first, let other = SimklBody.otherKind(first, filing) else { continue }
            filedDifferently.insert(SimklNotKept(label: first.label,
                                                 reason: "Simkl filed it as \(other); it may have taken another title.", at: .now, job: first), at: 0)
        }
        if filedDifferently.count > 50 { filedDifferently = Array(filedDifferently.prefix(50)) }
        if !filed.isEmpty { SimklStorage.save(filedDifferently, "filed.json") }
        let unclear = SimklBody.unclear(reply, groups: groups, missing: missing)
        guard !unclear.isEmpty else { return [] }
        let question = SimklBody.watchedQuestion(groups, asking: unclear)
        var landed = Set<String>()
        if !question.asked.isEmpty {
            guard let answer = try? await api.post("/sync/watched", query: ["extended": "episodes,specials"], body: question.body) else { return [] }
            landed = SimklBody.confirmed(answer, groups: groups, asked: question.asked)
        }
        return Set(unclear.flatMap { groups[$0].jobs.map(\.id) }).subtracting(landed)
    }

    /// Simkl's entry for the title, asked once and remembered (a miss is asked again after a week):
    /// by TMDB id through Simkl's `/redirect`, then IMDb's, then TVDB's (shows), as Cinopsys looks
    /// titles up; an answer of the other kind (a movie for a show) is never taken.
    private func match(for job: SimklJob, ids: SimklExternalIDs?, api: SimklAPI) async throws -> SimklAPI.Match? {
        if let known = matches[job.titleKey], known.match != nil || Date().timeIntervalSince(known.at) < 7 * 86_400 { return known.match }
        func fitting(_ match: SimklAPI.Match?) -> SimklAPI.Match? { match.flatMap { SimklAPI.accepts($0, movie: job.movie) ? $0 : nil } }
        var found = fitting(try await api.redirect(["tmdb": String(job.tmdb), "type": job.movie ? "movie" : "tv"]))
        if found == nil, let imdb = ids?.imdb { found = fitting(try await api.redirect(["imdb": imdb])) }
        if found == nil, !job.movie, let tvdb = ids?.tvdb { found = fitting(try await api.redirect(["tvdb": String(tvdb)])) }
        matches[job.titleKey] = SimklMatchRecord(match: found, at: .now)
        SimklStorage.save(matches, "titles.json")
        return found
    }
    /// The title's IMDb and TVDB ids from TMDB, once (without your TMDB key: none).
    private func externalIDs(_ job: SimklJob) async -> SimklExternalIDs? {
        if let known = external[job.titleKey] { return known }
        guard let store, let token = TMDBDirect.token(store),
              let data = try? await TMDBDirect.data((job.movie ? "movie/" : "tv/") + "\(job.tmdb)/external_ids", query: [:], token: token),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let imdb = (root["imdb_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tvdb = ((root["tvdb_id"] as? NSNumber)?.intValue).flatMap { $0 > 0 ? $0 : nil }
        let ids = SimklExternalIDs(imdb: imdb, tvdb: tvdb)
        external[job.titleKey] = ids
        SimklStorage.save(external, "external.json")
        return ids
    }

    /// What Simkl couldn't place, found another way once (tested against Simkl's replies):
    /// - an anime film Simkl files as anime (an ONA such as Bubble): its entry by title and year,
    ///   sent as that entry's episode;
    /// - an episode: its air date in the show's Simkl entry, then in the entries that share the
    ///   show's TMDB id (the later cours of an anime TMDB keeps as one long season, such as
    ///   Re:Zero's S1 E26 being its second cour's episode 1; specials that are their own entry),
    ///   sent to that entry by Simkl's own number.
    /// Otherwise listed as not kept and never sent again.
    private func place(_ jobs: [SimklJob], match: SimklAPI.Match?, api: SimklAPI, reply: String?) async {
        for job in jobs {
            guard let index = queue.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            // Not taken by its TVDB episode id: TVDB's seasons next, once.
            if job.entry == nil, job.tvdbEpisode != nil {
                queue.jobs[index].tvdbEpisode = nil; queue.jobs[index].tvdbEpisodeTried = true
                continue
            }
            // An anime episode whose date was already looked for: TVDB's place was the last try.
            let tried = job.datesChecked == true && !job.movie
            if !job.placedByDate, !tried, let spot = await spot(for: job, match: match, api: api) {
                if queue.jobs[index].diarySeason == nil { queue.jobs[index].diarySeason = job.season; queue.jobs[index].diaryNumber = job.number }
                queue.jobs[index].entry = spot.entry; queue.jobs[index].season = spot.season; queue.jobs[index].number = spot.number
                queue.jobs[index].entryIDs = spot.native; queue.jobs[index].ownNumbering = true; queue.jobs[index].placedByDate = true
            } else {
                finish([job], reason: job.movie ? "Simkl couldn’t find this title." : match == nil && job.entry == nil ? "Simkl couldn’t find this show." : "Simkl numbers this differently.", reply: reply)
            }
        }
    }
    private func placeFirst(_ jobs: [SimklJob], match: SimklAPI.Match?, api: SimklAPI) async {
        for job in jobs {
            let spot = await spot(for: job, match: match, api: api)
            // Neither its day nor its title on Simkl: a regular episode goes by its own TVDB id next
            // (Simkl's mapping), then TVDB's seasons. A special doesn't (Simkl's mapping put Demon
            // Slayer's S0 E2 on another year's special).
            let tvdbEpisode = spot == nil && job.season != 0 && job.tvdbEpisodeTried != true ? await tvdbEpisodeID(job) : nil
            guard let index = queue.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            queue.jobs[index].datesChecked = true
            guard let spot else { queue.jobs[index].tvdbEpisode = tvdbEpisode; continue }
            queue.jobs[index].diarySeason = job.season; queue.jobs[index].diaryNumber = job.number
            queue.jobs[index].entry = spot.entry; queue.jobs[index].season = spot.season; queue.jobs[index].number = spot.number
            queue.jobs[index].entryIDs = spot.native; queue.jobs[index].ownNumbering = true; queue.jobs[index].placedByDate = true
        }
    }
    /// Where Simkl keeps the episode, in its own entries and numbering: by its air date (with the
    /// same-day rules), else by its title when exactly one episode across those entries has it.
    private func spot(for job: SimklJob, match: SimklAPI.Match?, api: SimklAPI) async -> (entry: Int, season: Int?, number: Int?, native: [String: String]?)? {
        if job.movie {
            guard job.anime, let found = try? await api.searchAnime(title: job.name, year: job.year) else { return nil }
            return (found.simkl, nil, nil, (try? await detail(found.simkl, api: api))?.native)
        }
        guard let day = job.airedOn else { return nil }
        var root = match
        if root == nil, job.anime { root = try? await api.searchAnime(title: job.name, year: job.year) }
        guard let root else { return nil }
        let special = job.season == 0
        let tmdb = await tmdbEpisode(job, day: day)
        // In the show's own entries a special matches only a special (Re:Zero's S0 E1 isn't its
        // episode 1, though both aired that day); an OVA, ONA, special or film entry, any episode.
        let own = await episodes(root.simkl, kind: root.kind, api: api)
        let rootNative = root.kind == "anime" ? (try? await detail(root.simkl, api: api))?.native : nil
        if let episode = SimklBody.locate(day: day, in: own, special: special, anyKind: false,
                                          season: job.season, number: job.number, sameDay: tmdb.sameDay, title: tmdb.name) {
            return (root.simkl, episode.special ? 0 : 1, episode.number, rootNative)
        }
        var titled: [(entry: Int, episode: SimklAPI.Episode, native: [String: String]?)] =
            SimklBody.titled(tmdb.name, in: own, special: special, anyKind: false).map { (root.simkl, $0, rootNative) }
        if root.kind == "anime" {
            let year = Int(day.prefix(4)) ?? 0
            // The show's other cours (same TMDB id); for a special, also the OVAs, ONAs, specials and
            // films Simkl links to it, which TMDB may list under another id (Attack on Titan's OADs).
            let extras: Set<String> = ["ova", "ona", "special", "movie"]
            let family = ((try? await detail(root.simkl, api: api))?.related ?? [])
                .filter { $0.simkl != root.simkl && ($0.tmdb == String(job.tmdb) || (special && extras.contains($0.type ?? ""))) }
                .sorted { ($0.tmdb == String(job.tmdb) ? 0 : 1, abs(($0.year ?? 0) - year)) < ($1.tmdb == String(job.tmdb) ? 0 : 1, abs(($1.year ?? 0) - year)) }
            for entry in family.prefix(10) {
                let list = await episodes(entry.simkl, kind: "anime", api: api), anyKind = extras.contains(entry.type ?? "")
                if let episode = SimklBody.locate(day: day, in: list, special: special, anyKind: anyKind,
                                                  season: job.season, number: job.number, sameDay: tmdb.sameDay, title: tmdb.name) {
                    return (entry.simkl, episode.special ? 0 : 1, episode.number, entry.native)
                }
                titled += SimklBody.titled(tmdb.name, in: list, special: special, anyKind: anyKind).map { (entry.simkl, $0, entry.native) }
            }
        }
        // No such day on Simkl (it dates some releases by another country's premiere: Netflix's
        // anime): the one episode titled the same, if exactly one is.
        guard titled.count == 1, let only = titled.first else { return nil }
        return (only.entry, only.episode.special ? 0 : 1, only.episode.number, only.native)
    }
    private func episodes(_ simkl: Int, kind: String, api: SimklAPI) async -> [SimklAPI.Episode] {
        if let known = lookups.episodes[simkl] {
            let latest = known.list.compactMap(\.day).max() ?? ""
            let airing = SimklBody.daysApart(latest, DiaryDate.day(.now)) <= 30
            if Date().timeIntervalSince(known.at) < (airing ? 86_400 : 30 * 86_400) { return known.list }
        }
        guard let list = try? await api.episodes(of: SimklAPI.Match(simkl: simkl, kind: kind)) else { return lookups.episodes[simkl]?.list ?? [] }
        lookups.episodes[simkl] = .init(at: .now, list: list)
        trimAndSaveLookups()
        return list
    }
    /// From TMDB's season (your TMDB key; without it, nothing): its episode numbers aired within a
    /// day of this one, sorted, and this one's title. Kept like Simkl's lists: a day while the
    /// season airs, else a month.
    private func tmdbEpisode(_ job: SimklJob, day: String) async -> (sameDay: [Int]?, name: String?) {
        guard let season = job.season else { return (nil, nil) }
        let key = "\(job.tmdb)/\(season)"
        var days = lookups.tmdbDays?[key]
        if let known = days {
            let latest = known.days.values.max() ?? ""
            let airing = SimklBody.daysApart(latest, DiaryDate.day(.now)) <= 30
            if known.names == nil || Date().timeIntervalSince(known.at) >= (airing ? 86_400 : 30 * 86_400) { days = nil }
        }
        if days == nil, let store, let token = TMDBDirect.token(store),
           let data = try? await TMDBDirect.data("tv/\(job.tmdb)/season/\(season)", query: [:], token: token),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var list: [Int: String] = [:], names: [Int: String] = [:]
            for episode in root["episodes"] as? [[String: Any]] ?? [] {
                guard let number = (episode["episode_number"] as? NSNumber)?.intValue else { continue }
                if let aired = episode["air_date"] as? String, aired.count == 10 { list[number] = aired }
                if let name = episode["name"] as? String, !name.isEmpty { names[number] = name }
            }
            days = .init(at: .now, days: list, names: names)
            var all = lookups.tmdbDays ?? [:]
            all[key] = days
            lookups.tmdbDays = all
            trimAndSaveLookups()
        }
        guard let days = days ?? lookups.tmdbDays?[key] else { return (nil, nil) }
        return (days.days.filter { SimklBody.daysApart($0.value, day) <= 1 }.map(\.key).sorted(), job.number.flatMap { days.names?[$0] })
    }
    /// The episode's own TVDB id, from TMDB (your TMDB key; without it, none).
    private func tvdbEpisodeID(_ job: SimklJob) async -> Int? {
        guard let season = job.season, let number = job.number, let store, let token = TMDBDirect.token(store),
              let data = try? await TMDBDirect.data("tv/\(job.tmdb)/season/\(season)/episode/\(number)/external_ids", query: [:], token: token),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ((root["tvdb_id"] as? NSNumber)?.intValue).flatMap { $0 > 0 ? $0 : nil }
    }
    private func detail(_ simkl: Int, api: SimklAPI) async throws -> SimklAPI.Detail {
        if let known = lookups.related[simkl], Date().timeIntervalSince(known.at) < 7 * 86_400 { return known.detail }
        let detail = try await api.detail(of: simkl)
        lookups.related[simkl] = .init(at: .now, detail: detail)
        trimAndSaveLookups()
        return detail
    }
    private func trimAndSaveLookups() {
        if lookups.episodes.count > 300 {
            for key in lookups.episodes.sorted(by: { $0.value.at < $1.value.at }).prefix(100).map(\.key) { lookups.episodes[key] = nil }
        }
        if lookups.related.count > 300 {
            for key in lookups.related.sorted(by: { $0.value.at < $1.value.at }).prefix(100).map(\.key) { lookups.related[key] = nil }
        }
        if let days = lookups.tmdbDays, days.count > 300 {
            for key in days.sorted(by: { $0.value.at < $1.value.at }).prefix(100).map(\.key) { lookups.tmdbDays?[key] = nil }
        }
        SimklStorage.save(lookups, "lookups.json")
    }

    private func remove(_ jobs: [SimklJob]) {
        let ids = Set(jobs.map(\.id))
        queue.jobs.removeAll { ids.contains($0.id) }
    }
    /// Off the queue for good, listed on the Simkl page.
    private func finish(_ jobs: [SimklJob], reason: String, reply: String? = nil) {
        remove(jobs)
        notKept.insert(contentsOf: jobs.map { SimklNotKept(label: $0.label, reason: reason, at: .now, reply: reply, job: $0) }, at: 0)
        if notKept.count > 100 { notKept = Array(notKept.prefix(100)) }
        SimklStorage.save(notKept, "not-kept.json")
    }
    /// Tried again later: Simkl's wait, or longer after each failure; given up after 10 tries.
    private func delay(_ jobs: [SimklJob], by seconds: TimeInterval?, counting: Bool, problem: String?) {
        lastProblem = problem
        for job in jobs {
            guard let index = queue.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            if counting { queue.jobs[index].attempts += 1; queue.jobs[index].lastError = problem }
            let attempts = queue.jobs[index].attempts
            if attempts >= 10 { finish([queue.jobs[index]], reason: "Gave up after 10 tries: " + (problem ?? "no answer")); continue }
            queue.jobs[index].notBefore = Date().addingTimeInterval(seconds ?? min(30 * pow(2, Double(max(0, attempts - 1))), 6 * 3_600))
        }
    }
    private func scheduleWake() {
        wake?.cancel()
        guard let next = queue.nextWake, SimklAccount.shared.canSend else { return }
        let wait = max(1, next.timeIntervalSinceNow)
        guard wait < 15 * 60 else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.resume()
        }
    }
    private func save() { SimklStorage.save(queue, "queue.json") }

    /// Sends what's waiting now, without waiting for its time.
    func sendNow() async {
        for index in queue.jobs.indices { queue.jobs[index].notBefore = nil }
        save()
        await resume()
    }
    func clearNotKept() { notKept = []; SimklStorage.save(notKept, "not-kept.json") }
    func clearFiledDifferently() { filedDifferently = []; SimklStorage.save(filedDifferently, "filed.json") }
    /// Sends what Simkl didn't take once more, as the diary had it (after an update that finds
    /// more on Simkl).
    func retryNotKept() async {
        for item in notKept.reversed() {
            guard var job = item.job else { continue }
            if let season = job.diarySeason { job.season = season; job.number = job.diaryNumber }
            job.id = UUID().uuidString; job.attempts = 0; job.lastError = nil; job.notBefore = nil
            job.placedByDate = false; job.ownNumbering = false; job.diarySeason = nil; job.diaryNumber = nil; job.entry = nil; job.datesChecked = nil; job.entryIDs = nil
            job.tvdbEpisode = nil; job.tvdbEpisodeTried = nil
            queue.add(job)
        }
        notKept.removeAll { $0.job != nil }
        SimklStorage.save(notKept, "not-kept.json")
        save()
        await resume()
    }
    /// Forgets everything (the add-on is being removed).
    func forget() {
        wake?.cancel()
        queue = SimklQueue(); notKept = []; filedDifferently = []; matches = [:]; lookups = Lookups(); external = [:]; lastProblem = nil
    }
}
