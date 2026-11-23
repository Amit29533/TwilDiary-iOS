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
    /// In a request that's been sent (set as it goes, kept after, whatever came back): it may be on Simkl
    /// already, so an Undo can't just take it off the queue any more; the undo is sent after it instead.
    var reserved: Bool?
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
    /// A removal of the whole title (Force Match taking off what the diary doesn't have).
    var wholeTitle: Bool?
    /// Sent by the check because a trashed title was still on Simkl (`sweepTrash`).
    var swept: Bool?

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
        func untried(_ other: SimklJob) -> Bool { other.attempts == 0 && other.lastError == nil && other.reserved != true }
        switch job.kind {
        case .watch:
            if let index = jobs.lastIndex(where: { $0.kind == .unwatch && $0.itemKey == job.itemKey && untried($0) }) { jobs.remove(at: index); return }
        case .unwatch where job.wholeTitle == true:
            // The whole title off Simkl: what hadn't gone for it yet is moot (an untried Plan to
            // watch would only be taken off again), and the removal goes first in line.
            jobs.removeAll { $0.titleKey == job.titleKey && untried($0) && $0.wholeTitle != true }
            if jobs.contains(where: { $0.titleKey == job.titleKey && $0.wholeTitle == true && untried($0) }) { return }
            jobs.insert(job, at: 0)
            return
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
    /// A title's waiting whole-title removal goes now (the trash sweep found the title still on Simkl).
    mutating func hurry(_ titleKey: String) {
        for index in jobs.indices where jobs[index].titleKey == titleKey && jobs[index].wholeTitle == true { jobs[index].notBefore = nil }
    }
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
    /// Where each diary episode ("tmdb:season:number") or anime film ("movie:tmdb") is on Simkl,
    /// as placed: for reading Simkl back in the diary's terms (SimklLibrary).
    @ObservationIgnored private(set) var placements: [String: SimklPlacement]
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
        placements = SimklStorage.load([String: SimklPlacement].self, "placements.json") ?? [:]
    }

    // MARK: Taking edits

    /// An edit made in TwilDiary (from `DiaryStore.mirror`): turned into jobs while the diary
    /// still has everything they need, then sent in the background.
    func capture(_ mutations: [OptimisticMutation], store: DiaryStore) {
        guard !store.isPreview else { return }
        SimklAccount.shared.adopt(store)
        guard SimklAccount.shared.canSend else { return }
        self.store = store
        for mutation in mutations { for job in Self.jobs(for: mutation, store: store) { queue.add(job) } }
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
            let anime = title.map(Self.isAnime) ?? false, name = title?.name ?? "TMDB \(watch.tmdbId)"
            var jobs = [SimklJob(kind: .unwatch, tmdb: watch.tmdbId, movie: watch.movie, anime: anime, name: name,
                                 year: title?.year, season: watch.season, number: watch.number, watchedAt: watch.watchedAt)]
            // Nothing of the show watched any more: back under Plan to watch (Simkl kept it under
            // Watching with no episodes, test account 2026-11-19), unless you dropped or paused it.
            if watch.titleEmpty == true, !watch.movie, !["dropped", "paused", "on_hold"].contains(title?.status ?? "") {
                var list = SimklJob(kind: .list, tmdb: watch.tmdbId, movie: false, anime: anime, name: name, year: title?.year)
                list.list = "plantowatch"
                jobs.append(list)
            }
            return jobs
        case .patchTitle(let titleId, _, let status, let score, let clearScore, _, _, _, _):
            guard let title = resolvedTitle(titleId, store: store), let tmdb = title.tmdbId else { return [] }
            let base = SimklJob(kind: .rate, tmdb: tmdb, movie: !title.isSeries, anime: Self.isAnime(title), name: title.name, year: title.year)
            if store.trashing.contains(titleId), status != nil {
                // Moved to Trash: the whole title off Simkl, alone. It takes the rating and every
                // list with it (test account, 2026-11-19), so no rating removal goes first: queued
                // ahead of it, the title's removal waited behind that and Simkl kept the title.
                var job = base; job.kind = .unwatch; job.wholeTitle = true
                return [job]
            }
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
        if let episode = store.titleEpisodes(title.id).first(where: { $0.id == id }) { return (episode.season, episode.number, episode.airedOn) }
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
        // The same Live Activity as the other services' sends ("Simkl · 5 of 40").
        var total = queue.jobs.count, done = 0
        let live = BackgroundSyncCoordinator.shared
        while true {
            let batch = queue.batch(now: .now)
            guard !batch.isEmpty, SimklAccount.shared.canSend else { return }
            guard let token = await SimklAccount.shared.token(session: session) else { SimklAccount.shared.signInLapsed(); return }
            if done == 0 { live.updateForProviderBatch(provider: .simkl, completed: 0, total: total) }
            let before = queue.jobs.count
            // Reserved before the first wait: an Undo made while this request is on its way took the watch
            // off the queue as "not tried" and dropped its own unwatch, then the request still put the
            // watch on Simkl, leaving it watched there with nothing left to send.
            let goingOut = Set(batch.map(\.id))
            for index in queue.jobs.indices where goingOut.contains(queue.jobs[index].id) { queue.jobs[index].reserved = true }
            save()
            let carryOn = await send(batch, api: SimklAPI(token: token, session: session))
            save()
            done += max(0, before - queue.jobs.count)
            total = max(total, done + queue.jobs.count)
            live.updateForProviderBatch(provider: .simkl, completed: min(done, total), total: total,
                                        phase: queue.jobs.isEmpty ? .completed : carryOn ? .flushingOutbox : .paused)
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
            // (Anime films too: one part of a film entry in parts must go as that part.)
            let unplaced = batch.filter { $0.anime && $0.entry == nil && $0.datesChecked != true && $0.wholeTitle != true && ($0.kind == .watch || $0.kind == .unwatch) }
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
            if first.kind == .watch { missing.formUnion(try await readBack(reply, groups: groups, missing: missing, api: api)) }
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
            delay(batch, by: nil, counting: true, problem: FriendlyError.message(error))
            return false
        }
    }

    /// Simkl's answer to a watch, read back (as CrossWatch does): a title filed as the other kind is
    /// listed to check; one Simkl said nothing about (neither took nor listed as not found) is
    /// looked up on the account (`/sync/watched`: in Simkl's own numbering, that very episode).
    /// Returns the jobs that aren't there. If the check can't be made, it throws and the whole batch
    /// stays queued to go again: a batch Simkl never confirmed is never counted as sent (it was, and
    /// 1,828 changes "went" without landing, owner's test 2026-11-14). Sending again is harmless:
    /// Simkl keeps an episode watched once.
    private func readBack(_ reply: Data, groups: [SimklBody.Group], missing: Set<String>, api: SimklAPI) async throws -> Set<String> {
        let filed = SimklBody.filed(reply, groups: groups)
        for (index, filing) in filed {
            guard let first = groups[index].jobs.first, let other = SimklBody.otherKind(first, filing) else { continue }
            filedDifferently.insert(SimklNotKept(label: first.label,
                                                 reason: "Simkl filed it as \(other); it may have taken another title.", at: .now, job: first), at: 0)
        }
        if filedDifferently.count > 50 { filedDifferently = Array(filedDifferently.prefix(50)) }
        if !filed.isEmpty { SimklStorage.save(filedDifferently, "filed.json") }
        let unclear = SimklBody.toCheck(reply, groups: groups, missing: missing)
        guard !unclear.isEmpty else { return [] }
        let question = SimklBody.watchedQuestion(groups, asking: unclear)
        var landed = Set<String>()
        if !question.asked.isEmpty {
            // Simkl takes one write a second per account and this question is one: wait a moment, and
            // once more if it was still too soon. A daily limit or no answer stops here (the batch waits).
            func ask() async throws -> Data { try await api.post("/sync/watched", query: ["extended": "episodes,specials"], body: question.body) }
            var answer: Data
            do {
                try await Task.sleep(for: .milliseconds(1_100))
                answer = try await ask()
            } catch SimklAPI.Failure.busy(let seconds) where seconds <= 10 {
                try await Task.sleep(for: .seconds(max(2, seconds)))
                answer = try await ask()
            }
            landed = SimklBody.confirmed(answer, groups: groups, asked: question.asked)
        }
        return Set(unclear.flatMap { groups[$0].jobs.map(\.id) }).subtracting(landed)
    }

    /// Simkl's entry for the title, asked once and remembered (a miss is asked again after a week):
    /// by TMDB id through Simkl's `/redirect`, then IMDb's, then TVDB's (shows), as Cinopsys looks
    /// titles up; an answer of the other kind (a movie for a show) is never taken.
    private func match(for job: SimklJob, ids: SimklExternalIDs?, api: SimklAPI) async throws -> SimklAPI.Match? {
        // The anime map's entry first: no request, and it knows titles Simkl lists with no TMDB id
        // (ViVid Strike!).
        if job.anime, let entry = AnimeMapStore.shared.map?.simkl(tmdb: job.tmdb, film: job.movie) { return SimklAPI.Match(simkl: entry, kind: "anime") }
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
                // A later part's rating would replace the whole entry's (Simkl keeps one for all parts).
                if job.movie, job.kind == .rate || job.kind == .unrate, let part = spot.number, part >= 2 {
                    remember(job, entry: spot.entry, season: spot.season, number: spot.number)
                    finish([job], reason: "Simkl keeps one rating for all parts of this film; this is part \(part).", reply: reply)
                    continue
                }
                if queue.jobs[index].diarySeason == nil { queue.jobs[index].diarySeason = job.season; queue.jobs[index].diaryNumber = job.number }
                queue.jobs[index].entry = spot.entry; queue.jobs[index].season = spot.season; queue.jobs[index].number = spot.number
                queue.jobs[index].entryIDs = spot.native; queue.jobs[index].ownNumbering = true; queue.jobs[index].placedByDate = true
                remember(job, entry: spot.entry, season: spot.season, number: spot.number)
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
            let tvdbEpisode = spot == nil && !job.movie && job.season != 0 && job.tvdbEpisodeTried != true ? await tvdbEpisodeID(job) : nil
            guard let index = queue.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            queue.jobs[index].datesChecked = true
            // A film: where it is, kept for reading Simkl back; it still goes by its TMDB id (Simkl's
            // own match) unless it's one part of a film entry in parts, which goes as that part alone.
            // By TMDB id, Dead or Bullet marked both of Date a Bullet's parts watched (test account,
            // 2026-11-15).
            if job.movie, spot?.number == nil { remember(job, entry: spot?.entry, season: nil, number: nil); continue }
            guard let spot else { queue.jobs[index].tvdbEpisode = tvdbEpisode; remember(job, entry: nil, season: nil, number: nil); continue }
            queue.jobs[index].diarySeason = job.season; queue.jobs[index].diaryNumber = job.number
            queue.jobs[index].entry = spot.entry; queue.jobs[index].season = spot.season; queue.jobs[index].number = spot.number
            queue.jobs[index].entryIDs = spot.native; queue.jobs[index].ownNumbering = true; queue.jobs[index].placedByDate = true
            remember(job, entry: spot.entry, season: spot.season, number: spot.number)
        }
    }
    /// The place of a diary episode or film on Simkl, kept for reading Simkl back.
    private func remember(_ job: SimklJob, entry: Int?, season: Int?, number: Int?) {
        guard let key = Self.placementKey(job) else { return }
        placements[key] = SimklPlacement(entry: entry, season: season, number: number, at: .now, rule: SimklPlacement.currentRule)
        SimklStorage.save(placements, "placements.json")
    }
    /// An anime series' own entry, for one with nothing watched.
    static func seriesKey(_ tmdb: Int) -> String { "show:\(tmdb)" }
    static func placementKey(_ job: SimklJob) -> String? {
        if job.movie { return "movie:\(job.tmdb)" }
        guard let season = job.diarySeason ?? job.season, let number = job.diaryNumber ?? job.number else { return nil }
        return "\(job.tmdb):\(season):\(number)"
    }

    // MARK: Reading Simkl back (the comparison)

    /// Simkl's library in the diary's terms, for the comparison: only the kinds whose time moved
    /// in `/sync/activities` are read again (their replies are kept on this iPhone); first, up to
    /// `budget` diary anime titles not yet placed are placed (Simkl's daily allowance). Returns the
    /// requests made and how many diary anime episodes still wait to be placed.
    func readLibrary(into library: inout TraktLibrary, store: DiaryStore, budget: Int = 25) async throws -> (requests: Int, waiting: Int) {
        self.store = store
        guard let token = await SimklAccount.shared.token() else { throw APIError.message("Sign in to Simkl first, in Connections.") }
        let api = SimklAPI(token: token, session: session)
        var requests = 1
        let activities = try await api.get("/sync/activities")
        let root = (try? JSONSerialization.jsonObject(with: activities)) as? [String: Any] ?? [:]
        var stamps: [String: String] = [:]
        for (kind, key) in [("movies", "movies"), ("shows", "tv_shows"), ("anime", "anime")] {
            stamps[kind] = ((root[key] as? [String: Any])?["all"] as? String) ?? "unknown"
        }
        for kind in ["movies", "shows", "anime"] {
            let saved = library.activities?.stamps[kind]
            guard saved != stamps[kind] || SimklStorage.load(Data.self, Self.libraryFile(kind)) == nil else { continue }
            // include_all_episodes: without it Simkl lists the episodes of titles still being
            // watched only; a completed show came back as a count (696 watched, 40 listed, on the
            // test account 2026-11-15), so its watches looked missing and were offered again.
            let data = try await api.get("/sync/all-items/\(kind)/", query: ["extended": "full", "episode_watched_at": "yes", "include_all_episodes": "yes"])
            SimklStorage.save(data, Self.libraryFile(kind))
            requests += 1
        }
        let diary = store.diaryToMatch
        // Matching anime costs a few requests a title. Keep 150 of the day's allowance for sending
        // and the other apps you connect (each check spent about 50, owner's recording).
        let room = ProviderQuota.daily(host: SimklAPI.quotaHost).map { max(0, ($0.limit - $0.used - 150) / 4) } ?? budget
        requests += await placeAhead(diary, api: api, budget: min(budget, room))
        let mapping = SimklLibrary.mapping(placements: placements, diary: diary, map: AnimeMapStore.shared.map, trashed: PhoneTrash.shared.titles)
        var read = TraktLibrary(activities: TraktActivities(all: root["all"] as? String, stamps: stamps))
        var listed = Set<String>()
        for kind in ["movies", "shows", "anime"] {
            if let data = SimklStorage.load(Data.self, Self.libraryFile(kind)) { SimklLibrary.apply(kind, data, mapping: mapping, into: &read, listed: &listed) }
        }
        listedOnSimkl = listed
        library = read
        return (requests, unplacedAnime(diary).count)
    }
    /// Each kind's last reply, kept on this iPhone. "-v2": with every episode, so the copies saved
    /// before include_all_episodes are read again once.
    static func libraryFile(_ kind: String) -> String { "library-\(kind)-v2.json" }
    /// Diary anime episodes (watched) and films whose place on Simkl isn't known yet.
    private func unplacedAnime(_ diary: Workspace) -> [SimklJob] {
        let titles = Dictionary(diary.activeTitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let episodes = Dictionary(diary.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(), jobs: [SimklJob] = []
        for event in diary.activeEvents {
            guard let title = titles[event.titleId], Self.isAnime(title), let tmdb = title.tmdbId else { continue }
            var job = SimklJob(kind: .watch, tmdb: tmdb, movie: !title.isSeries, anime: true, name: title.name, year: title.year)
            if title.isSeries {
                guard let id = event.episodeId, let episode = episodes[id] else { continue }
                job.season = episode.season; job.number = episode.number; job.airedOn = episode.airedOn
            }
            guard let key = Self.placementKey(job), !settled(job, key), seen.insert(key).inserted else { continue }
            jobs.append(job)
        }
        // Anime films not watched yet (Planned, Dropped) too: Simkl files some as an OVA or ONA with
        // no TMDB id (Bubble, Alice in Deadly School), so only a placement links its Plan to watch
        // entry back to the diary's film (new account, 2026-11-15).
        for title in diary.activeTitles where Self.isAnime(title) && !title.isSeries {
            guard let tmdb = title.tmdbId else { continue }
            let job = SimklJob(kind: .watch, tmdb: tmdb, movie: true, anime: true, name: title.name, year: title.year)
            guard let key = Self.placementKey(job), placements[key]?.isCurrent(for: key) != true, seen.insert(key).inserted else { continue }
            jobs.append(job)
        }
        // Anime series with nothing watched (Planned, Dropped): Simkl lists some with no TMDB id
        // (ViVid Strike!), so only their entry, found once, links Plan to watch back to the diary.
        let watchedTitles = Set(diary.activeEvents.map(\.titleId))
        for title in diary.activeTitles where Self.isAnime(title) && title.isSeries && !watchedTitles.contains(title.id) {
            guard let tmdb = title.tmdbId else { continue }
            let key = Self.seriesKey(tmdb)
            // Found, or looked for in the last week (an empty look-up is tried again after that).
            let settled = placements[key].map { $0.isCurrent(for: key) && ($0.entry != nil || Date.now.timeIntervalSince($0.at) < 7 * 86_400) } ?? false
            guard !settled, seen.insert(key).inserted else { continue }
            jobs.append(SimklJob(kind: .watch, tmdb: tmdb, movie: false, anime: true, name: title.name, year: title.year))
        }
        return jobs
    }
    /// Placed, and for good: with the current rules, or before the map where the map agrees (or
    /// says nothing). The map costs no request, so this check is free.
    private func settled(_ job: SimklJob, _ key: String) -> Bool {
        guard let placed = placements[key], placed.isCurrent(for: key) else { return false }
        guard placed.rule != SimklPlacement.currentRule, let season = job.season, let number = job.number, let map = AnimeMapStore.shared.map,
              let mapped = map.anilist(tmdb: job.tmdb, season: season, episode: number), let entry = map.simkl(anilist: mapped.id) else { return true }
        return placed.entry == entry && placed.number == mapped.episode
    }

    // MARK: Trash on Simkl

    /// Every title the last read found on Simkl ("tv:1399"), on whatever list.
    @ObservationIgnored private(set) var listedOnSimkl: Set<String> = []
    /// How often the check has sent each trashed title off Simkl ("show:61223": 2).
    @ObservationIgnored private var trashSweeps = SimklStorage.load([String: Int].self, "trash-sweep.json") ?? [:]
    /// Trashed titles Simkl still lists (Plan to watch, Dropped, watches or a rating) go off Simkl
    /// again: Trash takes a title off when it's moved, yet Akame ga Kill! stayed on Plan to watch
    /// until Force Match (owner, 2026-11-19). Simkl answers every removal "deleted", taken or not,
    /// so only the next read shows whether it went: three sends, then it's listed as Not kept.
    @discardableResult func sweepTrash(_ library: TraktLibrary, trashed: [MediaTitle], store: DiaryStore) -> Int {
        guard !store.isPreview, SimklAccount.shared.canSend else { return 0 }
        self.store = store
        var jobs: [SimklJob] = []
        for title in Self.trashedOnSimkl(library, trashed: trashed, listed: listedOnSimkl) {
            guard let tmdb = title.tmdbId else { continue }
            var job = SimklJob(kind: .unwatch, tmdb: tmdb, movie: !title.isSeries, anime: Self.isAnime(title), name: title.name, year: title.year)
            job.wholeTitle = true; job.swept = true
            jobs.append(job)
        }
        // A title off Simkl starts again from nothing if it's ever trashed again.
        let listed = Set(jobs.map(\.titleKey))
        trashSweeps = trashSweeps.filter { listed.contains($0.key) }
        var queued = 0
        // A removal already waiting (after a failed try) goes now instead of after its pause.
        for job in jobs { queue.hurry(job.titleKey) }
        for job in jobs where !queue.jobs.contains(where: { $0.titleKey == job.titleKey && $0.wholeTitle == true }) {
            let tries = trashSweeps[job.titleKey, default: 0]
            if tries >= 3 {
                if tries == 3 { finish([job], reason: "Moved to Trash, but Simkl still lists it after three removals. Remove it on simkl.com, or use Force Match.") }
                trashSweeps[job.titleKey] = 4
                continue
            }
            trashSweeps[job.titleKey] = tries + 1
            queue.add(job); queued += 1
        }
        SimklStorage.save(trashSweeps, "trash-sweep.json")
        if queued > 0 { save(); Task { await resume() } }
        return queued
    }
    /// The trashed titles Simkl lists in any way, by TMDB id. `listed`: every title Simkl lists,
    /// whatever its list (Watching, Completed and On hold aren't in the library's lists).
    nonisolated static func trashedOnSimkl(_ library: TraktLibrary, trashed: [MediaTitle], listed: Set<String> = []) -> [MediaTitle] {
        let refs = library.watchlist.map(\.title) + library.dropped.map(\.title) + library.ratings.map(\.title) + library.plays.map(\.title)
        let onSimkl = Set(refs.compactMap(\.diaryKey)).union(listed)
        return trashed.filter { title in title.tmdbId.map { onSimkl.contains((title.isSeries ? "tv:" : "movie:") + String($0)) } ?? false }
    }

    // MARK: Make Simkl match: three tries

    /// What Make Simkl match sent and Simkl hasn't shown yet (RetryStop): three sends that don't
    /// read back, and it's ignored from then on.
    @ObservationIgnored private var retry = SimklStorage.load(RetryStop.self, "retry.json") ?? RetryStop()
    func noteSent(_ tokens: Set<String>) { retry.sent(tokens); SimklStorage.save(retry, "retry.json") }
    /// What's ignored from now on.
    func observeRetries(missing: Set<String>) -> [String] {
        let ignored = retry.observe(missing: missing)
        SimklStorage.save(retry, "retry.json")
        return ignored
    }

    /// Places diary anime not placed yet, a few titles at a time (each title's look-ups are kept,
    /// so its other episodes cost nothing more). Returns roughly the requests it made.
    private func placeAhead(_ diary: Workspace, api: SimklAPI, budget: Int) async -> Int {
        let waiting = unplacedAnime(diary)
        var titles: [String] = []
        for job in waiting where !titles.contains(job.titleKey) { titles.append(job.titleKey) }
        var requests = 0
        for key in titles.prefix(budget) {
            guard let first = waiting.first(where: { $0.titleKey == key }) else { continue }
            let ids = await externalIDs(first)
            let match = try? await match(for: first, ids: ids, api: api)
            requests += 2
            for job in waiting where job.titleKey == key {
                // A series with nothing watched: its own entry, by TMDB id, else by name.
                if !job.movie, job.season == nil, job.number == nil {
                    var entry = (match ?? nil)?.simkl
                    if entry == nil { entry = ((try? await api.searchAnime(title: job.name, year: job.year)) ?? nil)?.simkl; requests += 1 }
                    placements[Self.seriesKey(job.tmdb)] = SimklPlacement(entry: entry, season: nil, number: nil, at: .now, rule: SimklPlacement.currentRule)
                    SimklStorage.save(placements, "placements.json")
                    continue
                }
                let spot = await spot(for: job, match: match ?? nil, api: api)
                remember(job, entry: spot?.entry, season: spot?.season, number: spot?.number)
            }
        }
        return requests
    }
    /// "Make Simkl match the diary": the plan's watches, ratings, Plan to watch and Dropped as jobs
    /// for this sync (each placed in Simkl's numbering when it goes). Taking things off Simkl's
    /// lists isn't part of it. Returns how many were queued.
    @discardableResult func enqueue(_ plan: TraktWritePlan, store: DiaryStore) -> Int {
        guard !store.isPreview else { return 0 }
        self.store = store
        let diary = store.diaryToMatch
        var titles: [String: MediaTitle] = [:]
        for title in diary.activeTitles { if let tmdb = title.tmdbId { titles[(title.isSeries ? "show:" : "movie:") + String(tmdb)] = title } }
        let episodes = Dictionary(grouping: diary.episodes, by: \.titleId)
        func base(_ ref: TraktWritePlan.Ref, kind: SimklJob.Kind) -> SimklJob {
            let title = titles[(ref.movie ? "movie:" : "show:") + String(ref.tmdbId)]
            return SimklJob(kind: kind, tmdb: ref.tmdbId, movie: ref.movie, anime: title.map(Self.isAnime) ?? false, name: title?.name ?? ref.name, year: title?.year)
        }
        var jobs: [SimklJob] = []
        for play in plan.plays {
            var job = base(play.title, kind: .watch)
            job.watchedAt = play.watchedAt
            if !play.title.movie {
                guard let season = play.season, let number = play.episode else { continue }
                job.season = season; job.number = number
                if let title = titles["show:\(play.title.tmdbId)"] {
                    job.airedOn = episodes[title.id]?.first { $0.season == season && $0.number == number }?.airedOn
                }
            }
            jobs.append(job)
        }
        for rating in plan.ratings { var job = base(rating.title, kind: .rate); job.rating = rating.rating; jobs.append(job) }
        for ref in plan.watchlistAdd { var job = base(ref, kind: .list); job.list = "plantowatch"; jobs.append(job) }
        for ref in plan.dropped { var job = base(ref, kind: .list); job.list = "dropped"; jobs.append(job) }
        // What Simkl refused already (Not kept) waits for Try again: sent again each match, it was
        // refused again and listed once more (Date A Bullet four times, 2026-11-15).
        let refused = Set(notKept.compactMap { $0.job.map(Self.changeKey) })
        jobs.removeAll { refused.contains(Self.changeKey($0)) }
        for job in jobs { queue.add(job) }
        save()
        Task { await resume() }
        return jobs.count
    }
    // MARK: Check-in

    /// Checks in on Simkl (`/scrobble/checkin`): a movie or show by its ids; an anime episode in
    /// Simkl's own numbering, placed as a watch would be (its entry by Simkl id). Tested
    /// 2026-11-14 (Frieren E3, Breaking Bad S1E2, Inception). Simkl marks it watched when the
    /// runtime has passed.
    func checkIn(_ title: MediaTitle, episode: Episode?, store: DiaryStore) async throws -> String {
        self.store = store
        guard let tmdb = title.tmdbId else { throw APIError.message("“\(title.name)” has no TMDB id, so Simkl can’t find it.") }
        guard let token = await SimklAccount.shared.token() else { throw APIError.message("Sign in to Simkl first, in Connections.") }
        let api = SimklAPI(token: token, session: session)
        var job = SimklJob(kind: .watch, tmdb: tmdb, movie: !title.isSeries, anime: Self.isAnime(title), name: title.name, year: title.year)
        if let episode { job.season = episode.season; job.number = episode.number; job.airedOn = episode.airedOn }
        let ids = await externalIDs(job)
        var body: [String: Any]
        if !title.isSeries {
            var item: [String: Any] = ["title": title.name, "ids": SimklBody.ids(job, simkl: nil, external: ids)]
            if let year = title.year { item["year"] = year }
            body = ["movie": item]
        } else {
            guard let episode else { throw APIError.message("There’s no next episode to check in to.") }
            if job.anime, let spot = await spot(for: job, match: try? await match(for: job, ids: ids, api: api), api: api) {
                var entryIDs: [String: Any] = ["simkl": spot.entry]
                for (key, value) in spot.native ?? [:] { entryIDs[key] = Int(value) ?? value }
                body = ["anime": ["ids": entryIDs], "episode": ["season": spot.season ?? 1, "number": spot.number ?? episode.number]]
            } else if job.anime {
                // (Simkl's check-in by an episode's TVDB id answered 404 for anime, 2026-11-14.)
                throw APIError.message("Simkl numbers this episode differently and TwilDiary can’t place it, so it can’t be checked in.")
            } else {
                body = ["show": ["title": title.name, "ids": SimklBody.ids(job, simkl: nil, external: ids)], "episode": ["season": episode.season, "number": episode.number]]
            }
        }
        let reply = try await api.post("/scrobble/checkin", body: try JSONSerialization.data(withJSONObject: body))
        if let id = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["id"] { UserDefaults.standard.set("\(id)", forKey: SimklStorage.prefix + "checkin") }
        return title.isSeries ? "Checked in to \(title.name) S\(episode?.season ?? 0) E\(episode?.number ?? 0) on Simkl. It’s logged when the episode ends."
            : "Checked in to \(title.name) on Simkl. It’s logged when the movie ends."
    }
    /// Cancels the check-in: its playback is deleted (Simkl's way), so nothing is logged.
    func cancelCheckIn(store: DiaryStore) async throws {
        guard let token = await SimklAccount.shared.token() else { throw APIError.message("Sign in to Simkl first, in Connections.") }
        let api = SimklAPI(token: token, session: session)
        let key = SimklStorage.prefix + "checkin"
        if let id = UserDefaults.standard.string(forKey: key), (try? await api.send("/sync/playback/\(id)", method: "DELETE")) != nil {
            UserDefaults.standard.removeObject(forKey: key); return
        }
        // Not that id: the newest playback Simkl lists is the check-in.
        let list = ((try? JSONSerialization.jsonObject(with: try await api.get("/sync/playback"))) as? [[String: Any]]) ?? []
        guard let newest = list.max(by: { ($0["paused_at"] as? String ?? "") < ($1["paused_at"] as? String ?? "") }), let id = newest["id"] else {
            throw APIError.message("Simkl has no check-in running.")
        }
        _ = try await api.send("/sync/playback/\(id)", method: "DELETE")
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Force Match (the diary as the source of truth): the plan's additions as "Make Simkl
    /// match", and what Simkl has that the diary doesn't taken off: plays (an anime episode by its
    /// remembered place), ratings, Plan to watch, and titles the diary doesn't have at all. A title
    /// Simkl has as Dropped while the diary doesn't goes to the diary's list instead (taking it off
    /// would take its watches too). Only what was read back in the diary's terms is touched;
    /// what couldn't be matched is never taken off. Returns how many were queued.
    @discardableResult func enqueue(force plan: ForceMatchPlan, store: DiaryStore) -> Int {
        guard !store.isPreview else { return 0 }
        var count = enqueue(plan.send, store: store)
        let diary = store.diaryToMatch
        var titles: [String: MediaTitle] = [:]
        for title in diary.activeTitles { if let tmdb = title.tmdbId { titles[(title.isSeries ? "show:" : "movie:") + String(tmdb)] = title } }
        func base(_ item: ForceMatchPlan.Item, kind: SimklJob.Kind) -> SimklJob {
            let title = titles[(item.movie ? "movie:" : "show:") + String(item.tmdbId)]
            return SimklJob(kind: kind, tmdb: item.tmdbId, movie: item.movie, anime: title.map(Self.isAnime) ?? false, name: title?.name ?? item.name, year: title?.year)
        }
        var jobs: [SimklJob] = []
        for play in plan.plays {
            var job = base(play.title, kind: .unwatch)
            if play.title.movie, let placed = placements["movie:\(play.title.tmdbId)"], let entry = placed.entry, let part = placed.number {
                // One part of a film entry comes off alone (taking the entry would take the others).
                job.entry = entry; job.season = 1; job.number = part; job.ownNumbering = true; job.placedByDate = true; job.datesChecked = true
            }
            if !play.title.movie {
                guard let season = play.season, let number = play.episode else { continue }
                job.season = season; job.number = number
                // An anime episode by where it was placed (that's how it was read back).
                if let placed = placements["\(play.title.tmdbId):\(season):\(number)"], let entry = placed.entry {
                    job.diarySeason = season; job.diaryNumber = number
                    job.entry = entry; job.season = placed.season; job.number = placed.number
                    job.ownNumbering = true; job.placedByDate = true; job.datesChecked = true
                }
            }
            jobs.append(job)
        }
        for item in plan.ratings { jobs.append(base(item, kind: .unrate)) }
        for item in plan.watchlist + plan.wipe { var job = base(item, kind: .unwatch); job.wholeTitle = true; jobs.append(job) }
        for item in plan.wipe { jobs.append(base(item, kind: .unrate)) }
        for item in plan.dropped {
            let status = titles[(item.movie ? "movie:" : "show:") + String(item.tmdbId)]?.status
            var job = base(item, kind: .list); job.list = status.flatMap { Self.list(for: $0, movie: item.movie) } ?? (item.movie ? "completed" : "watching")
            if job.list != "dropped" { jobs.append(job) }
        }
        for job in jobs { queue.add(job) }
        save()
        Task { await resume() }
        count += jobs.count
        return count
    }

    /// What Simkl refused, in the match plan's terms ("play|tv:46004|s1e11", "rating|movie:760161",
    /// "planned|…", "dropped|…"): left out of Make match and its count until Try again.
    var notKeptTokens: Set<String> {
        Set(notKept.compactMap { item -> String? in
            guard let job = item.job else { return nil }
            let key = (job.movie ? "movie:" : "tv:") + String(job.tmdb)
            switch job.kind {
            case .watch:
                guard !job.movie else { return "play|" + key }
                guard let season = job.diarySeason ?? job.season else { return nil }
                return "play|\(key)|s\(season)e\(job.diaryNumber ?? job.number ?? 0)"
            case .rate: return "rating|" + key
            case .list: return job.list == "plantowatch" ? "planned|" + key : job.list == "dropped" ? "dropped|" + key : nil
            case .unwatch, .unrate: return nil
            }
        })
    }
    /// A missing diary watch with where it was placed on Simkl ("on Simkl: entry 1258030, episode 4",
    /// "not placed on Simkl"), so a mismatch shows whether it's the placing or the reading.
    func placementNote(_ difference: TraktComparison.Difference) -> TraktComparison.Difference { Self.placementNote(difference, placements: placements) }
    nonisolated static func placementNote(_ difference: TraktComparison.Difference, placements: [String: SimklPlacement]) -> TraktComparison.Difference {
        guard let key = difference.key else { return difference }
        let parts = key.split(separator: "|").map(String.init)
        let id = parts[0].split(separator: ":").last.map(String.init) ?? ""
        let placementKey: String
        if parts[0].hasPrefix("movie:") { placementKey = "movie:" + id }
        else if parts.count == 2, let s = parts[1].dropFirst().split(separator: "e").first, let e = parts[1].split(separator: "e").last { placementKey = "\(id):\(s):\(e)" }
        else { return difference }
        guard let placed = placements[placementKey] else { return difference }
        let note: String
        if let entry = placed.entry {
            if parts[0].hasPrefix("movie:") { note = placed.number.map { "on Simkl: entry \(entry), part \($0)" } ?? "on Simkl: entry \(entry)" }
            else { note = "on Simkl: entry \(entry), " + (placed.season == 0 ? "special " : "episode ") + "\(placed.number ?? 0)" }
        } else { note = "not placed on Simkl" }
        return TraktComparison.Difference(title: difference.title, detail: difference.detail + " · " + note, key: key)
    }
    /// What Simkl didn't keep, as the comparison leaves it out ("movie:tmdb", "show:tmdb:s:n").
    var notKeptKeys: Set<String> {
        Set(notKept.compactMap { item in
            guard let job = item.job else { return nil }
            if job.movie { return "movie:\(job.tmdb)" }
            guard let season = job.diarySeason ?? job.season, let number = job.diaryNumber ?? job.number else { return nil }
            return "show:\(job.tmdb):\(season):\(number)"
        })
    }
    /// Where Simkl keeps the episode, in its own entries and numbering: by its air date (with the
    /// same-day rules), else by its title when exactly one episode across those entries has it.
    private func spot(for job: SimklJob, match: SimklAPI.Match?, api: SimklAPI) async -> (entry: Int, season: Int?, number: Int?, native: [String: String]?)? {
        if job.movie {
            guard job.anime else { return nil }
            var found: SimklAPI.Match? = (try? await api.searchAnime(title: job.name, year: job.year)) ?? nil
            // A film in parts is filed under its series' name: "Date A Bullet: Nightmare or Queen" is
            // found only as "Date A Bullet" (test account, 2026-11-15). Found so, it must be a part.
            var bySeries = false
            if found == nil, let series = SimklBody.seriesName(job.name) {
                found = (try? await api.searchAnime(title: series, year: job.year)) ?? nil
                bySeries = found != nil
            }
            guard let found else { return nil }
            let parts = await episodes(found.simkl, kind: "anime", api: api).filter { !$0.special }
            let native = (try? await detail(found.simkl, api: api))?.native
            // One part: the film. Several: the part titled as the film (Date a Bullet's part 2 is
            // Nightmare or Queen), sent and read as that part. Otherwise not here: Simkl's search
            // can answer with a series of a similar name, and a film placed there was read as the
            // whole series (Immortal King's ONA, 2026-11-15).
            if parts.count <= 1 { return bySeries ? nil : (found.simkl, nil, nil, native) }
            guard let part = SimklBody.filmPart(job.name, in: parts) else { return nil }
            return (found.simkl, 1, part, native)
        }
        // The diary built from a tracker keeps no air dates: TMDB's season (your server's without
        // your TMDB key, or when TMDB can't be reached) gives the day, so the episode is placed by
        // date instead of Simkl's TVDB mapping (which dropped TONIKAWA S1 E1, 2026-11-15).
        var aired = job.airedOn
        if aired == nil, let number = job.number { aired = await seasonDays(job)?.days[number] }
        // The anime map first: TMDB's episode is an AniList entry's episode, and that entry's Simkl
        // entry numbers it the same. Kept only where Simkl lists that episode and both days are
        // known and within 30 days (the map has mistakes); otherwise the matching below, as before.
        // A special never onto the show's own entry as a regular episode (Simkl keeps specials
        // there as specials).
        if job.anime, let season = job.season, let number = job.number, let day = aired, let map = AnimeMapStore.shared.map,
           let mapped = map.anilist(tmdb: job.tmdb, season: season, episode: number), let entry = map.simkl(anilist: mapped.id),
           season != 0 || entry != map.simkl(tmdb: job.tmdb, film: false) {
            let list = await episodes(entry, kind: "anime", api: api)
            if let episode = list.first(where: { !$0.special && $0.number == mapped.episode }), let simklDay = episode.day,
               SimklBody.daysApart(simklDay, day) <= 30 {
                return (entry, 1, episode.number, (try? await detail(entry, api: api))?.native)
            }
        }
        guard let day = aired else { return nil }
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
        guard let days = await seasonDays(job) else { return (nil, nil) }
        return (days.days.filter { SimklBody.daysApart($0.value, day) <= 1 }.map(\.key).sorted(), job.number.flatMap { days.names?[$0] })
    }
    /// TMDB's air day and title of each episode of the job's season, read once and kept (a season
    /// still airing is read again after a day, others after a month).
    private func seasonDays(_ job: SimklJob) async -> Lookups.Days? {
        guard let season = job.season else { return nil }
        let key = "\(job.tmdb)/\(season)"
        var days = lookups.tmdbDays?[key]
        if let known = days {
            let latest = known.days.values.max() ?? ""
            let airing = SimklBody.daysApart(latest, DiaryDate.day(.now)) <= 30
            if known.names == nil || Date().timeIntervalSince(known.at) >= (airing ? 86_400 : 30 * 86_400) { days = nil }
        }
        if days == nil, let store, let page = try? await store.catalogEpisodes(CatalogRoute(kind: .tv, id: job.tmdb), season: season, reveal: true) {
            var list: [Int: String] = [:], names: [Int: String] = [:]
            for episode in page.items {
                if let aired = episode.airedOn.map({ String($0.prefix(10)) }), aired.count == 10 { list[episode.number] = aired }
                if !episode.name.isEmpty { names[episode.number] = episode.name }
            }
            days = .init(at: .now, days: list, names: names)
            var all = lookups.tmdbDays ?? [:]
            all[key] = days
            lookups.tmdbDays = all
            trimAndSaveLookups()
        }
        return days ?? lookups.tmdbDays?[key]
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
        let keys = Set(jobs.map(Self.changeKey))
        notKept.removeAll { $0.job.map(Self.changeKey).map(keys.contains) == true }
        notKept.insert(contentsOf: jobs.map { SimklNotKept(label: Self.notKeptLabel($0), reason: reason, at: .now, reply: reply, job: $0) }, at: 0)
        if notKept.count > 100 { notKept = Array(notKept.prefix(100)) }
        SimklStorage.save(notKept, "not-kept.json")
    }
    /// One change, in the diary's numbering ("rate|movie:760161", "watch|show:46004:1:11"): the
    /// same change refused twice is one Not kept row, and isn't queued again until Try again.
    static func changeKey(_ job: SimklJob) -> String {
        // A film is the film, whichever part of an entry it was placed on.
        let season = job.movie ? nil : job.diarySeason ?? job.season, number = job.diaryNumber ?? job.number
        return job.kind.rawValue + "|" + job.titleKey + (season.map { ":\($0):\(number ?? 0)" } ?? "")
    }
    /// "Date A Bullet · Rating": a watch is the title alone; anything else says what it was.
    static func notKeptLabel(_ job: SimklJob) -> String {
        switch job.kind {
        case .watch: job.label
        case .unwatch: job.label + " · Removal"
        case .rate: job.label + " · Rating"
        case .unrate: job.label + " · Rating removal"
        case .list: job.label + " · List"
        }
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
    private func save() {
        SimklStorage.save(queue, "queue.json")
        // This round's size: the most that were waiting since the queue was last empty.
        let next = queue.jobs.isEmpty ? 0 : max(sendTotal, queue.jobs.count)
        if next != sendTotal { sendTotal = next }
    }
    /// How many changes this round of sending started with (for "612 of 1,828 sent"); kept across launches.
    private(set) var sendTotal = UserDefaults.standard.integer(forKey: "simkl.addon.sendTotal") {
        didSet { UserDefaults.standard.set(sendTotal, forKey: "simkl.addon.sendTotal") }
    }
    /// Sent so far this round, as a fraction (nil when nothing is waiting).
    var sendFraction: Double? {
        let waiting = queue.jobs.count, total = max(sendTotal, waiting)
        guard waiting > 0, total > 0 else { return nil }
        return Double(total - waiting) / Double(total)
    }

    /// Sends what's waiting now, without waiting for its time.
    /// Where sending stands, for the compare panel: what's waiting and, when nothing is going, why
    /// ("Paused: Simkl's daily limit is used up · resumes 5:35 am"). Nil when nothing is waiting.
    var status: (text: String, paused: Bool)? {
        let waiting = queue.jobs.count
        guard waiting > 0 else { return nil }
        let total = max(sendTotal, waiting)
        let count = total > waiting ? "\((total - waiting).formatted()) of \(total.formatted()) sent · \(waiting.formatted()) waiting"
            : "\(waiting.formatted()) \(waiting == 1 ? "change" : "changes") waiting"
        if !SimklAccount.shared.signedIn { return (count + " · paused: sign in to Simkl again to send", true) }
        if !SimklAccount.shared.saving { return (count + " · paused: turn on “Also save my activity to Simkl” to send", true) }
        if sending { return ("Sending · " + count, false) }
        if let wake = queue.nextWake, wake.timeIntervalSinceNow > 60 {
            let time = wake.diaryTime()
            let quota = ProviderQuota.daily(host: SimklAPI.quotaHost)
            let limit = SimklUsage.today().limitReachedAt != nil || (quota.map { $0.used >= $0.limit } ?? false)
            return (count + (limit ? " · paused: Simkl’s daily limit is used up · resumes \(time)" : " · next try \(time)"), true)
        }
        return (count, false)
    }
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
        queue = SimklQueue(); notKept = []; filedDifferently = []; matches = [:]; lookups = Lookups(); external = [:]; placements = [:]; lastProblem = nil
    }
}
