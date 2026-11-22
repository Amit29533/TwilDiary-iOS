import Foundation
import Observation
import TwilDiaryCore

/// Device-session public scores. Personal diary ratings never enter this cache.
@MainActor @Observable final class CommunityRatingsController {
    /// Every visible poster reads this dictionary, so it is replaced once per batch
    /// (one observation change) rather than once per title.
    private(set) var entries: [String: PublicRating] = [:] {
        didSet {
            let missing = entries.values.contains { $0.state == "unavailable" }
            if unavailable != missing { unavailable = missing }
        }
    }
    private(set) var source = PublicRatingSource.trakt
    private(set) var pending = 0
    var loading: Bool { pending > 0 }
    /// Stored, so the Library body no longer scans every entry on each read.
    private(set) var unavailable = false
    /// Bumped when scores that timed out may be tried again; screens include it in their load task's id.
    private(set) var retryRound = 0
    @ObservationIgnored private var retryScheduled = false
    @ObservationIgnored private var expires: [String: Date] = [:]
    @ObservationIgnored private var inflight = Set<String>()
    @ObservationIgnored private var generation = UUID()
    private let clock: () -> Date
    /// Where scores are kept between launches (none in tests).
    private let folder: URL?
    /// The wait after a failed batch before the next.
    private let pause: Double
    init(clock: @escaping () -> Date = { Date() }, folder: URL? = nil, pause: Double = 0) { self.clock = clock; self.folder = folder; self.pause = pause }

    func selectSource(_ value: PublicRatingSource) {
        guard source != value || (!restored && folder != nil) else { return }
        reset()
        source = value
        restore()
    }

    // MARK: Kept on the phone

    /// Scores read before (rated or unrated, still fresh) come back at once, so the Library shows
    /// them on opening instead of reading every title again.
    private struct Saved: Codable { var entries: [String: PublicRating]; var expires: [String: Date] }
    @ObservationIgnored private var restored = false
    private var file: URL? { folder?.appending(path: "public-ratings-\(source.rawValue).json") }
    private func restore() {
        restored = true
        guard let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let now = clock()
        var next = entries
        for (id, rating) in saved.entries where rating.state != "unavailable" {
            guard let until = saved.expires[id], until > now, next[id] == nil else { continue }
            next[id] = rating; expires[id] = until
        }
        entries = next
    }
    private func persist() {
        guard let file else { return }
        let kept = entries.filter { $0.value.state != "unavailable" }
        BackgroundFiles.save(Saved(entries: kept, expires: expires.filter { kept[$0.key] != nil }), to: file)
    }
    func reset() {
        generation = UUID(); entries = [:]; expires = [:]; inflight = []; pending = 0; retryRound = 0; retryScheduled = false; restored = false
    }
    func retryUnavailable() {
        for (id, entry) in entries where entry.state == "unavailable" { expires.removeValue(forKey: id) }
    }
    private func markUnavailable(_ ids: ArraySlice<String>) {
        var next = entries
        let retry = clock().addingTimeInterval(60)
        for id in ids {
            // Keep a previously fetched community score visible during a transient outage.
            if next[id]?.state != "rated" { next[id] = PublicRating(score: nil, state: "unavailable") }
            expires[id] = retry
        }
        entries = next
        // A few automatic retries a session once the wait is over; after that, the Retry button.
        guard retryRound < 5 else { return }
        scheduleRound(after: 61)
    }
    /// `batch` titles are asked for at a time; `seconds` is how long one run may take before the rest
    /// waits for the next run (not marked failed: they're simply asked for again). A batch that
    /// fails is marked on its own and the rest carry on, so one refusal never fails the whole list.
    func prepare(_ titleIDs: [String], batch size: Int = 4, seconds: Double = 12, fetch: ([String]) async throws -> [String: PublicRating]) async {
        var seen = Set<String>()
        let now = clock()
        let ids = titleIDs.filter { seen.insert($0).inserted && !inflight.contains($0) && (expires[$0].map { $0 <= now } ?? true) }
        guard !ids.isEmpty, !Task.isCancelled else { return }
        let session = generation
        inflight.formUnion(ids); pending += 1
        defer {
            if session == generation { inflight.subtract(ids); pending -= 1 }
        }
        // The existing endpoint fans out four provider calls at a time. Small batches
        // avoid waiting for six sequential provider waves before the first score appears.
        let deadline = now.addingTimeInterval(seconds)
        var failedInARow = 0
        for offset in stride(from: 0, to: ids.count, by: size) {
            guard session == generation, !Task.isCancelled else { return }
            if clock() >= deadline {
                // Out of time for this run: the rest are asked for again in a moment.
                scheduleRound(after: 2); return
            }
            let batch = Array(ids[offset..<min(offset + size, ids.count)])
            let results: [String: PublicRating]
            do { results = try await fetch(batch) }
            catch is CancellationError { return }
            catch {
                guard session == generation, !Task.isCancelled else { return }
                markUnavailable(batch[...]); failedInARow += 1
                // The service is down, not just busy: stop asking for now.
                if failedInARow >= 3 { markUnavailable(ids[(offset + batch.count)...]); return }
                if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
                continue
            }
            guard session == generation, !Task.isCancelled else { return }
            if results.isEmpty || results.values.allSatisfy({ $0.state == "unavailable" }) {
                // The service answered but has no scores: no wait, it isn't busy.
                markUnavailable(batch[...]); failedInARow += 1
                if failedInARow >= 3 { markUnavailable(ids[(offset + batch.count)...]); return }
                continue
            }
            failedInARow = 0
            let received = clock()
            var next = entries
            for id in batch {
                let rating = results[id] ?? PublicRating(score: nil, state: "unavailable")
                next[id] = rating
                expires[id] = received.addingTimeInterval(rating.state == "unavailable" ? 60 : 3 * 86_400)
            }
            entries = next
            persist()
        }
    }
    /// Screens ask again (their load task's id includes the round).
    private func scheduleRound(after seconds: Double) {
        guard !retryScheduled else { return }
        retryScheduled = true
        let session = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, session == self.generation else { return }
            self.retryScheduled = false; self.retryRound += 1
        }
    }
}
