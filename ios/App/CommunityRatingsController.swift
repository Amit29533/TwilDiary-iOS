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
    init(clock: @escaping () -> Date = { Date() }) { self.clock = clock }

    func reset() {
        generation = UUID(); entries = [:]; expires = [:]; inflight = []; pending = 0; retryRound = 0; retryScheduled = false
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
        guard !retryScheduled, retryRound < 5 else { return }
        retryScheduled = true
        let session = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(61))
            guard let self, session == self.generation else { return }
            self.retryScheduled = false; self.retryRound += 1
        }
    }
    func prepare(_ titleIDs: [String], fetch: ([String]) async throws -> [String: PublicRating]) async {
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
        let deadline = now.addingTimeInterval(12)
        for offset in stride(from: 0, to: ids.count, by: 4) {
            guard session == generation, !Task.isCancelled else { return }
            if clock() >= deadline { markUnavailable(ids[offset...]); return }
            let batch = Array(ids[offset..<min(offset + 4, ids.count)])
            let results: [String: PublicRating]
            do { results = try await fetch(batch) }
            catch is CancellationError { return }
            catch {
                guard session == generation, !Task.isCancelled else { return }
                markUnavailable(ids[offset...]); return
            }
            guard session == generation, !Task.isCancelled else { return }
            if results.isEmpty || results.values.allSatisfy({ $0.state == "unavailable" }) {
                markUnavailable(ids[offset...]); return
            }
            let received = clock()
            var next = entries
            for id in batch {
                let rating = results[id] ?? PublicRating(score: nil, state: "unavailable")
                next[id] = rating
                expires[id] = received.addingTimeInterval(rating.state == "unavailable" ? 60 : 86_400)
            }
            entries = next
        }
    }
}
