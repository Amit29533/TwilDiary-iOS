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

    /// The next request: the first job that may go now (an earlier job of its title still waiting
    /// holds it back), with the same title's next jobs of the same kind (episodes of one show go
    /// together), up to 100.
    func batch(now: Date) -> [SimklJob] {
        var waiting = Set<String>()
        for (index, job) in jobs.enumerated() {
            if let notBefore = job.notBefore, notBefore > now { waiting.insert(job.titleKey); continue }
            if waiting.contains(job.titleKey) { continue }
            var batch = [job]
            guard job.kind == .watch || job.kind == .unwatch, !job.movie else { return batch }
            for other in jobs[(index + 1)...] where other.titleKey == job.titleKey {
                guard other.kind == job.kind, other.ownNumbering == job.ownNumbering, other.entry == job.entry,
                      other.notBefore.map({ $0 <= now }) ?? true, batch.count < 100 else { break }
                batch.append(other)
            }
            return batch
        }
        return []
    }
    /// When the first waiting job may go.
    var nextWake: Date? { jobs.compactMap(\.notBefore).min() }
}

/// Copies what you do in TwilDiary to Simkl when "Also save my activity to Simkl" is on.
@MainActor @Observable final class SimklMirror {
    static let shared = SimklMirror()
    private(set) var queue: SimklQueue
    private(set) var notKept: [SimklNotKept]
    private(set) var sending = false
    private(set) var lastProblem: String?
    @ObservationIgnored private var matches: [String: SimklMatchRecord]
    /// Simkl's episode lists and linked entries, kept on the phone: Simkl allows each account a
    /// daily number of requests (found while testing: "user_limit_exceeded"), so they aren't asked
    /// again on every launch. Linked entries a week; an airing entry's episodes a day, a finished
    /// one's a month.
    struct Lookups: Codable, Sendable {
        struct Episodes: Codable, Sendable { let at: Date; let list: [SimklAPI.Episode] }
        struct Linked: Codable, Sendable { let at: Date; let list: [SimklAPI.Related] }
        var episodes: [Int: Episodes] = [:]
        var related: [Int: Linked] = [:]
    }
    @ObservationIgnored private var lookups: Lookups
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored var session: URLSession = .shared

    struct SimklMatchRecord: Codable, Equatable, Sendable { let match: SimklAPI.Match?; let at: Date }

    init() {
        queue = SimklStorage.load(SimklQueue.self, "queue.json") ?? SimklQueue()
        notKept = SimklStorage.load([SimklNotKept].self, "not-kept.json") ?? []
        matches = SimklStorage.load([String: SimklMatchRecord].self, "titles.json") ?? [:]
        lookups = SimklStorage.load(Lookups.self, "lookups.json") ?? Lookups()
    }

    // MARK: Taking edits

    /// An edit made in TwilDiary (the hook in `DiaryStore.mirror`): turned into jobs while the diary
    /// still has everything they need, then sent in the background.
    func capture(_ mutation: OptimisticMutation, store: DiaryStore) {
        guard SimklAccount.shared.canSend, !store.isPreview else { return }
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
    func resume() async {
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

    /// One request. False when sending should stop for now (signed out, Simkl busy, no network).
    private func send(_ batch: [SimklJob], api: SimklAPI) async -> Bool {
        guard let first = batch.first else { return true }
        do {
            let match = first.entry == nil ? try await match(for: first, api: api) : nil
            // Anime episodes are placed by air date in Simkl's own entries before anything is sent:
            // TVDB's seasons can name another entry, and Simkl takes it without a word (TMDB's
            // Bleach S2 is Thousand-Year Blood War; TVDB's S2 is the 2004 show's second season).
            // TVDB's seasons are the fallback when Simkl lists no such date.
            if first.anime && !first.movie && first.entry == nil && first.datesChecked != true && (first.kind == .watch || first.kind == .unwatch) {
                await placeFirst(batch, match: match, api: api)
                return true
            }
            // A special Simkl lists on no such day isn't sent by TVDB's season 0: Simkl rarely places
            // it, and the try still puts the show on your Watching list with nothing watched.
            let unplacedSpecials = batch.filter { $0.anime && !$0.movie && $0.entry == nil && $0.season == 0 && $0.datesChecked == true }
            if !unplacedSpecials.isEmpty {
                finish(unplacedSpecials, reason: "Simkl lists no special or OVA on that day.")
                return true
            }
            let reply = try await api.post(SimklBody.path(first.kind), body: SimklBody.body(batch, simkl: first.entry ?? SimklBody.pin(first, match)))
            let missing = SimklBody.notFound(reply, sent: batch)
            lastProblem = nil
            remove(batch.filter { !missing.contains($0.id) })
            let unplaced = batch.filter { missing.contains($0.id) }
            if !unplaced.isEmpty { await place(unplaced, match: match, api: api, reply: SimklBody.missingPart(reply)) }
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

    /// Simkl's entry for the title, asked once and remembered (a miss is asked again after a week).
    private func match(for job: SimklJob, api: SimklAPI) async throws -> SimklAPI.Match? {
        if let known = matches[job.titleKey], known.match != nil || Date().timeIntervalSince(known.at) < 7 * 86_400 { return known.match }
        let found = try await api.match(tmdb: job.tmdb, movie: job.movie)
        matches[job.titleKey] = SimklMatchRecord(match: found, at: .now)
        SimklStorage.save(matches, "titles.json")
        return found
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
            // An anime episode whose date was already looked for: TVDB's place was the last try.
            let tried = job.datesChecked == true && !job.movie
            if !job.placedByDate, !tried, let spot = await spot(for: job, match: match, api: api) {
                if queue.jobs[index].diarySeason == nil { queue.jobs[index].diarySeason = job.season; queue.jobs[index].diaryNumber = job.number }
                queue.jobs[index].entry = spot.entry; queue.jobs[index].season = spot.season; queue.jobs[index].number = spot.number
                queue.jobs[index].ownNumbering = true; queue.jobs[index].placedByDate = true
            } else {
                finish([job], reason: job.movie ? "Simkl couldn’t find this title." : match == nil && job.entry == nil ? "Simkl couldn’t find this show." : "Simkl numbers this differently.", reply: reply)
            }
        }
    }
    private func placeFirst(_ jobs: [SimklJob], match: SimklAPI.Match?, api: SimklAPI) async {
        for job in jobs {
            let spot = await spot(for: job, match: match, api: api)
            guard let index = queue.jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            queue.jobs[index].datesChecked = true
            guard let spot else { continue }
            queue.jobs[index].diarySeason = job.season; queue.jobs[index].diaryNumber = job.number
            queue.jobs[index].entry = spot.entry; queue.jobs[index].season = spot.season; queue.jobs[index].number = spot.number
            queue.jobs[index].ownNumbering = true; queue.jobs[index].placedByDate = true
        }
    }
    private func spot(for job: SimklJob, match: SimklAPI.Match?, api: SimklAPI) async -> (entry: Int, season: Int?, number: Int?)? {
        if job.movie {
            guard job.anime, let found = try? await api.searchAnime(title: job.name, year: job.year) else { return nil }
            return (found.simkl, nil, nil)
        }
        guard let day = job.airedOn else { return nil }
        var root = match
        if root == nil, job.anime { root = try? await api.searchAnime(title: job.name, year: job.year) }
        guard let root else { return nil }
        let special = job.season == 0
        // In the show's own entries a special matches only a special (Re:Zero's S0 E1 isn't its
        // episode 1, though both aired that day); an OVA, ONA, special or film entry, any episode.
        if let episode = SimklBody.locate(day: day, in: await episodes(root.simkl, kind: root.kind, api: api), special: special, anyKind: false) {
            return (root.simkl, episode.special ? 0 : 1, episode.number)
        }
        guard root.kind == "anime" else { return nil }
        let year = Int(day.prefix(4)) ?? 0
        // The show's other cours (same TMDB id); for a special, also the OVAs, ONAs, specials and
        // films Simkl links to it, which TMDB may list under another id (Attack on Titan's OADs).
        let extras: Set<String> = ["ova", "ona", "special", "movie"]
        let family = ((try? await related(root.simkl, api: api)) ?? [])
            .filter { $0.simkl != root.simkl && ($0.tmdb == String(job.tmdb) || (special && extras.contains($0.type ?? ""))) }
            .sorted { ($0.tmdb == String(job.tmdb) ? 0 : 1, abs(($0.year ?? 0) - year)) < ($1.tmdb == String(job.tmdb) ? 0 : 1, abs(($1.year ?? 0) - year)) }
        for entry in family.prefix(10) {
            if let episode = SimklBody.locate(day: day, in: await episodes(entry.simkl, kind: "anime", api: api), special: special, anyKind: extras.contains(entry.type ?? "")) {
                return (entry.simkl, episode.special ? 0 : 1, episode.number)
            }
        }
        return nil
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
    private func related(_ simkl: Int, api: SimklAPI) async throws -> [SimklAPI.Related] {
        if let known = lookups.related[simkl], Date().timeIntervalSince(known.at) < 7 * 86_400 { return known.list }
        let list = try await api.related(to: simkl)
        lookups.related[simkl] = .init(at: .now, list: list)
        trimAndSaveLookups()
        return list
    }
    private func trimAndSaveLookups() {
        if lookups.episodes.count > 300 {
            for key in lookups.episodes.sorted(by: { $0.value.at < $1.value.at }).prefix(100).map(\.key) { lookups.episodes[key] = nil }
        }
        if lookups.related.count > 300 {
            for key in lookups.related.sorted(by: { $0.value.at < $1.value.at }).prefix(100).map(\.key) { lookups.related[key] = nil }
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
    /// Sends what Simkl didn't take once more, as the diary had it (after an update that finds
    /// more on Simkl).
    func retryNotKept() async {
        for item in notKept.reversed() {
            guard var job = item.job else { continue }
            if let season = job.diarySeason { job.season = season; job.number = job.diaryNumber }
            job.id = UUID().uuidString; job.attempts = 0; job.lastError = nil; job.notBefore = nil
            job.placedByDate = false; job.ownNumbering = false; job.diarySeason = nil; job.diaryNumber = nil; job.entry = nil; job.datesChecked = nil
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
        queue = SimklQueue(); notKept = []; matches = [:]; lookups = Lookups(); lastProblem = nil
    }
}
