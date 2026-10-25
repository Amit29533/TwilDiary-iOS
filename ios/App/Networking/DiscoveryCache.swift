import Foundation
import TwilDiaryCore

/// Shared by a diary session, never globally or on disk. A caller disappearing
/// does not cancel another shelf's request; owner/account changes invalidate it.
@MainActor final class DiscoveryCache {
    private struct Entry { let at: Date; let page: CatalogPage }
    private struct Read { let id: UUID; let task: Task<CatalogPage, Error> }
    private var owner: UUID?
    private var generation = UUID()
    private var personalGeneration = UUID()
    private var pages: [String: Entry] = [:]
    private var reads: [String: Read] = [:]
    private var statusRead: (id: UUID, task: Task<TraktStatus, Error>)?
    private(set) var account: String?
    private let now: @MainActor () -> Date
    init(now: @escaping @MainActor () -> Date = { .now }) { self.now = now }
    func reset() {
        generation = UUID(); personalGeneration = UUID()
        for read in reads.values { read.task.cancel() }
        statusRead?.task.cancel(); statusRead = nil
        reads = [:]; pages = [:]; account = nil; owner = nil
    }
    private func synchronize(_ scope: UUID) {
        if owner != scope { reset(); owner = scope }
    }
    func activateAccount(_ username: String?) {
        let next = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identity = next?.isEmpty == false ? next : nil
        guard account != identity else { return }
        personalGeneration = UUID(); account = identity
        for key in Array(reads.keys) where key.hasPrefix("trakt:") { reads.removeValue(forKey: key)?.task.cancel() }
        pages = pages.filter { !$0.key.hasPrefix("trakt:") }
    }
    private func key(_ path: String, personal: Bool) -> String? {
        if !personal { return "public:" + path }
        guard let account else { return nil }
        return "trakt:" + account + ":" + path
    }
    func cached(_ path: String, scope: UUID, personal: Bool, allowStale: Bool = false) -> CatalogPage? {
        synchronize(scope)
        guard let key = key(path, personal: personal), let entry = pages[key], allowStale || now().timeIntervalSince(entry.at) < 300 else { return nil }
        return entry.page
    }
    func page(_ path: String, scope: UUID, personal: Bool, refresh: Bool = false, fetch: @escaping @MainActor @Sendable () async throws -> CatalogPage) async throws -> CatalogPage {
        synchronize(scope)
        let epoch = generation, personalEpoch = personalGeneration
        // No account identity means no personal cache can be safely reused.
        guard let key = key(path, personal: personal) else {
            let value = try await fetch()
            try Task.checkCancellation()
            guard epoch == generation, personalEpoch == personalGeneration else { throw CancellationError() }
            return value
        }
        if !refresh, let saved = cached(path, scope: scope, personal: personal) { return saved }
        if let read = reads[key] {
            let value = try await read.task.value
            try Task.checkCancellation()
            guard epoch == generation, !personal || personalEpoch == personalGeneration else { throw CancellationError() }
            return value
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { if self.reads[key]?.id == id { self.reads.removeValue(forKey: key) } }
            let value = try await fetch()
            try Task.checkCancellation()
            guard epoch == self.generation, !personal || personalEpoch == self.personalGeneration else { throw CancellationError() }
            if self.pages.count >= 16, self.pages[key] == nil, let oldest = self.pages.min(by: { $0.value.at < $1.value.at })?.key { self.pages.removeValue(forKey: oldest) }
            self.pages[key] = Entry(at: self.now(), page: value)
            return value
        }
        reads[key] = Read(id: id, task: task)
        let value = try await task.value
        try Task.checkCancellation()
        guard epoch == generation, !personal || personalEpoch == personalGeneration else { throw CancellationError() }
        return value
    }
    func status(scope: UUID, fetch: @escaping @MainActor @Sendable () async throws -> TraktStatus) async throws -> TraktStatus {
        synchronize(scope)
        let epoch = generation
        if let pending = statusRead {
            let value = try await pending.task.value
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            return value
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { if self.statusRead?.id == id { self.statusRead = nil } }
            let result = try await fetch()
            try Task.checkCancellation()
            guard epoch == self.generation else { throw CancellationError() }
            return result
        }
        statusRead = (id, task)
        let value = try await task.value
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        return value
    }
}
