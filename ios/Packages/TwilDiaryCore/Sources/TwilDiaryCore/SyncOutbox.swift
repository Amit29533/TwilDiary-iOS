import Foundation

/// Sync destinations supported by the local-first outbox and multi-provider engine.
public enum SyncProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case cloudflare
    case trakt
    case simkl
    case mdblist
    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .cloudflare: "Cloudflare D1"
        case .trakt: "Trakt"
        case .simkl: "Simkl"
        case .mdblist: "MDBList"
        }
    }
}

/// A local-first diary mutation that can be applied optimistically to an in-memory `Workspace`
/// without networking and queued in `SyncOutboxQueue` for durable delivery to Cloudflare D1 and external providers.
public enum OptimisticMutation: Codable, Equatable, Sendable {
    case markWatch(operationId: String, titleId: String, episodeId: String?, watchedAt: String, recordedAt: String, rewatch: Bool)
    case revokeWatch(eventId: String, titleId: String, expectedVersion: Int, revokedAt: String)
    case restoreWatch(eventId: String, titleId: String, expectedVersion: Int)
    case patchTitle(titleId: String, expectedVersion: Int?, status: String?, score: Double?, clearScore: Bool, favorite: Bool?, queued: Bool?, notes: String?, tags: [String]? = nil)
    case trashTitle(titleId: String, expectedVersion: Int, deletedAt: String)
    case restoreTitle(titleId: String, expectedVersion: Int)

    public var titleId: String {
        switch self {
        case .markWatch(_, let titleId, _, _, _, _): titleId
        case .revokeWatch(_, let titleId, _, _): titleId
        case .restoreWatch(_, let titleId, _): titleId
        case .patchTitle(let titleId, _, _, _, _, _, _, _, _): titleId
        case .trashTitle(let titleId, _, _): titleId
        case .restoreTitle(let titleId, _): titleId
        }
    }
}

/// One durable outbox item tracking which providers still need to receive the mutation.
public struct SyncOutboxEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let operationId: String
    public let createdAt: String
    public var mutation: OptimisticMutation
    public var pendingProviders: Set<SyncProviderKind>
    public var attempts: Int
    public var lastError: String?
    public var confirmedActions: Set<String>?
    public var uncertainActions: Set<String>?

    private enum CodingKeys: String, CodingKey {
        case id, operationId, createdAt, mutation, pendingProviders, attempts, lastError, confirmedActions, uncertainActions
    }
    /// A provider the app no longer has (WeTrakr was removed) is dropped from a saved entry instead
    /// of failing the whole outbox, which would lose every other pending edit.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        operationId = try c.decode(String.self, forKey: .operationId)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        mutation = try c.decode(OptimisticMutation.self, forKey: .mutation)
        pendingProviders = Set(try c.decode([String].self, forKey: .pendingProviders).compactMap(SyncProviderKind.init(rawValue:)))
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        confirmedActions = try c.decodeIfPresent(Set<String>.self, forKey: .confirmedActions)
        uncertainActions = try c.decodeIfPresent(Set<String>.self, forKey: .uncertainActions)
    }

    public init(
        id: String = UUID().uuidString,
        operationId: String = UUID().uuidString,
        createdAt: String,
        mutation: OptimisticMutation,
        pendingProviders: Set<SyncProviderKind> = [.cloudflare],
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.operationId = operationId
        self.createdAt = createdAt
        self.mutation = mutation
        self.pendingProviders = pendingProviders
        self.attempts = attempts
        self.lastError = lastError
        self.confirmedActions = nil
        self.uncertainActions = nil
    }
}

/// Value-type queue of pending local-first mutations with field coalescing and per-provider acknowledgment.
public struct SyncOutboxQueue: Codable, Equatable, Sendable {
    public private(set) var entries: [SyncOutboxEntry]

    public init(entries: [SyncOutboxEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public func pending(for provider: SyncProviderKind) -> [SyncOutboxEntry] {
        entries.filter { $0.pendingProviders.contains(provider) }
    }

    /// Enqueues a mutation, deduplicating by `operationId` and coalescing consecutive
    /// `patchTitle` edits for the same title and provider set.
    @discardableResult
    public mutating func enqueue(_ entry: SyncOutboxEntry) -> SyncOutboxEntry {
        if let existing = entries.first(where: { $0.operationId == entry.operationId }) {
            return existing
        }
        if case .patchTitle(let titleId, let expVer, let status, let score, let clearScore, let favorite, let queued, let notes, let tags) = entry.mutation,
           let lastIndex = entries.indices.last(where: { entries[$0].mutation.titleId == titleId }),
           entries[lastIndex].attempts == 0,
           (entries[lastIndex].confirmedActions ?? []).isEmpty,
           (entries[lastIndex].uncertainActions ?? []).isEmpty,
           entries[lastIndex].pendingProviders == entry.pendingProviders,
           case .patchTitle(_, let prevExpVer, let prevStatus, let prevScore, let prevClearScore, let prevFav, let prevQueued, let prevNotes, let prevTags) = entries[lastIndex].mutation {
            let mergedScore: Double? = clearScore ? nil : (score ?? prevScore)
            let mergedClearScore: Bool = clearScore || (score == nil && prevClearScore)
            entries[lastIndex].mutation = .patchTitle(
                titleId: titleId,
                expectedVersion: prevExpVer ?? expVer,
                status: status ?? prevStatus,
                score: mergedScore,
                clearScore: mergedClearScore,
                favorite: favorite ?? prevFav,
                queued: queued ?? prevQueued,
                notes: notes ?? prevNotes,
                tags: tags ?? prevTags
            )
            return entries[lastIndex]
        }
        entries.append(entry)
        return entry
    }

    /// Marks one provider as confirmed for `entryID`, removing the entry once all target providers confirm.
    public mutating func acknowledge(entryID: String, provider: SyncProviderKind) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].pendingProviders.remove(provider)
        entries[index].lastError = nil
        if entries[index].pendingProviders.isEmpty {
            entries.remove(at: index)
        }
    }

    public mutating func recordFailure(entryID: String, error: String) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].attempts += 1
        entries[index].lastError = error
    }

    public mutating func recordDelivery(entryID: String, key: String, confirmed: Bool, rejected: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        if confirmed {
            entries[index].confirmedActions = (entries[index].confirmedActions ?? []).union([key])
        }
        if confirmed || rejected { entries[index].uncertainActions?.remove(key) }
        else { entries[index].uncertainActions = (entries[index].uncertainActions ?? []).union([key]) }
    }

    public mutating func remove(entryID: String) {
        entries.removeAll { $0.id == entryID }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// Projects all pending `.cloudflare` mutations onto a `Workspace` snapshot.
    public func project(onto workspace: Workspace) -> Workspace {
        workspace.applyingOutbox(pending(for: .cloudflare))
    }
}

public protocol SyncOutboxStoring: Sendable {
    func load(scope: String) -> SyncOutboxQueue
    func save(_ queue: SyncOutboxQueue, scope: String) throws
    func removeAll() throws
}

public final class MemorySyncOutboxStore: SyncOutboxStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: SyncOutboxQueue] = [:]
    public init() {}
    public func load(scope: String) -> SyncOutboxQueue {
        lock.withLock { storage[scope] ?? SyncOutboxQueue() }
    }
    public func save(_ queue: SyncOutboxQueue, scope: String) throws {
        lock.withLock { storage[scope] = queue }
    }
    public func removeAll() throws {
        lock.withLock { storage.removeAll() }
    }
}

public final class FileSyncOutboxStore: SyncOutboxStoring, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("PrivateDiaryOutbox", isDirectory: true)
    }
    public func load(scope: String) -> SyncOutboxQueue {
        lock.withLock {
            let url = fileURL(for: scope)
            guard let data = try? Data(contentsOf: url), data.count <= 2 * 1_024 * 1_024,
                  let queue = try? JSONDecoder().decode(SyncOutboxQueue.self, from: data) else {
                return SyncOutboxQueue()
            }
            return queue
        }
    }
    public func save(_ queue: SyncOutboxQueue, scope: String) throws {
        try lock.withLock {
            let url = fileURL(for: scope)
            if queue.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(queue)
            guard data.count <= 2 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: [.atomic])
            #endif
        }
    }
    public func removeAll() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }
    private func fileURL(for scope: String) -> URL {
        let sanitized = scope.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("outbox-\(sanitized.isEmpty ? "default" : sanitized).json")
    }
}

public extension WatchCard {
    /// Computes a `WatchCard` locally on-device from `Workspace`, matching
    /// the server's `watchCard` projection in `src/lib/server/dashboard.ts`.
    static func calculate(title: MediaTitle, in workspace: Workspace, day: String, season selectedSeason: Int? = nil) -> WatchCard {
        if !title.isSeries {
            let previousEvent = workspace.events
                .filter { $0.titleId == title.id && $0.episodeId == nil && $0.revokedAt == nil }
                .sorted { a, b in
                    if a.recordedAt != b.recordedAt { return a.recordedAt > b.recordedAt }
                    return a.id > b.id
                }
                .first
            return WatchCard(
                progress: Progress(watched: previousEvent != nil ? 1 : 0, total: 1),
                season: nil,
                next: nil,
                previous: previousEvent.map { Previous(id: $0.id, version: $0.version ?? 1, episodeId: nil, number: nil) }
            )
        }
        let activeEvents = workspace.events.filter { $0.titleId == title.id && $0.revokedAt == nil }
        let watchedEpisodeIDs = Set(activeEvents.compactMap(\.episodeId))
        let allEpisodes = workspace.episodes.filter { $0.titleId == title.id }
        let manifests = (title.seasons ?? []).sorted { $0.number < $1.number }
        struct ComputedSeason {
            let number: Int
            let name: String
            let metadataLoadedAt: String?
            let total: Int
            let watched: Int
            let next: Next?
            let previous: Previous?
        }
        let computed: [ComputedSeason] = manifests.map { manifest in
            let seasonEpisodes = allEpisodes
                .filter { $0.season == manifest.number }
                .sorted { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number }
            let total = manifest.metadataLoadedAt == nil ? (manifest.expectedEpisodes ?? 0) : seasonEpisodes.count
            let watched = seasonEpisodes.filter { watchedEpisodeIDs.contains($0.id) }.count
            let nextEpisode = seasonEpisodes.first { ep in
                guard ep.skipped != true, !watchedEpisodeIDs.contains(ep.id),
                      let aired = ep.airedOn, SeasonAdjustment.validDay(aired), aired <= day else { return false }
                return true
            }
            let episodeByID = Dictionary(uniqueKeysWithValues: seasonEpisodes.map { ($0.id, $0) })
            let previousMatch = activeEvents
                .compactMap { event -> (event: WatchEvent, episode: Episode)? in
                    guard let epID = event.episodeId, let ep = episodeByID[epID] else { return nil }
                    return (event, ep)
                }
                .sorted { a, b in
                    if a.episode.number != b.episode.number { return a.episode.number > b.episode.number }
                    if a.event.recordedAt != b.event.recordedAt { return a.event.recordedAt > b.event.recordedAt }
                    return a.event.id > b.event.id
                }
                .first
            return ComputedSeason(
                number: manifest.number,
                name: manifest.name,
                metadataLoadedAt: manifest.metadataLoadedAt,
                total: total,
                watched: watched,
                next: nextEpisode.map { Next(id: $0.id, number: $0.number) },
                previous: previousMatch.map { Previous(id: $0.event.id, version: $0.event.version ?? 1, episodeId: $0.episode.id, number: $0.episode.number) }
            )
        }
        let normal = computed.filter { $0.number > 0 }
        let choices = normal.isEmpty ? computed : normal
        let chosen: ComputedSeason? = if let selectedSeason {
            computed.first { $0.number == selectedSeason }
        } else {
            choices.first { $0.next != nil }
                ?? choices.first { $0.metadataLoadedAt == nil }
                ?? choices.last
        }
        return WatchCard(
            progress: Progress(watched: chosen?.watched ?? 0, total: chosen?.total ?? 0),
            season: chosen.map { Season(number: $0.number, name: $0.name, metadataLoadedAt: $0.metadataLoadedAt) },
            next: chosen?.next,
            previous: chosen?.previous
        )
    }
}

public extension Workspace {
    /// Applies a sequence of outbox entries optimistically to a `Workspace` copy.
    func applyingOutbox(_ entries: [SyncOutboxEntry]) -> Workspace {
        entries.reduce(self) { current, entry in
            current.applying(entry.mutation)
        }
    }

    /// Applies one `OptimisticMutation` in memory, including derived status transitions.
    func applying(_ mutation: OptimisticMutation) -> Workspace {
        var copy = self
        switch mutation {
        case .markWatch(let operationId, let titleId, let episodeId, let watchedAt, let recordedAt, let rewatch):
            guard let titleIndex = copy.titles.firstIndex(where: { $0.id == titleId && $0.deletedAt == nil }) else { return copy }
            if copy.events.contains(where: { $0.operationId == operationId }) { return copy }
            if !rewatch,
               copy.events.contains(where: { $0.titleId == titleId && $0.episodeId == episodeId && $0.revokedAt == nil }) {
                return copy
            }
            let event = WatchEvent(
                id: "local-\(operationId)",
                operationId: operationId,
                titleId: titleId,
                episodeId: episodeId,
                watchedAt: watchedAt,
                recordedAt: recordedAt,
                revokedAt: nil,
                origin: "manual",
                version: 1
            )
            copy.events.append(event)
            copy.events.sort { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
            copy.titles[titleIndex] = Self.deriveWatchStatus(for: copy.titles[titleIndex], in: copy, isRevoke: false)

        case .revokeWatch(let eventId, let titleId, _, let revokedAt):
            guard let eventIndex = copy.events.firstIndex(where: { $0.id == eventId }) else { return copy }
            copy.events[eventIndex].revokedAt = revokedAt
            copy.events[eventIndex].version = (copy.events[eventIndex].version ?? 1) + 1
            if let titleIndex = copy.titles.firstIndex(where: { $0.id == titleId && $0.deletedAt == nil }) {
                copy.titles[titleIndex] = Self.deriveWatchStatus(for: copy.titles[titleIndex], in: copy, isRevoke: true)
            }

        case .restoreWatch(let eventId, let titleId, _):
            guard let eventIndex = copy.events.firstIndex(where: { $0.id == eventId }) else { return copy }
            copy.events[eventIndex].revokedAt = nil
            copy.events[eventIndex].version = (copy.events[eventIndex].version ?? 1) + 1
            if let titleIndex = copy.titles.firstIndex(where: { $0.id == titleId && $0.deletedAt == nil }) {
                copy.titles[titleIndex] = Self.deriveWatchStatus(for: copy.titles[titleIndex], in: copy, isRevoke: false)
            }

        case .patchTitle(let titleId, _, let status, let score, let clearScore, let favorite, let queued, let notes, let tags):
            guard let index = copy.titles.firstIndex(where: { $0.id == titleId && $0.deletedAt == nil }) else { return copy }
            if let status { copy.titles[index].status = status }
            if clearScore { copy.titles[index].score = nil }
            else if let score { copy.titles[index].score = score }
            if let favorite { copy.titles[index].favorite = favorite }
            if let queued { copy.titles[index].queued = queued }
            if let notes { copy.titles[index].notes = notes }
            if let tags { copy.titles[index].tags = tags }
            copy.titles[index].version = (copy.titles[index].version ?? 1) + 1

        case .trashTitle(let titleId, _, let deletedAt):
            guard let index = copy.titles.firstIndex(where: { $0.id == titleId }) else { return copy }
            copy.titles[index].deletedAt = deletedAt
            copy.titles[index].version = (copy.titles[index].version ?? 1) + 1

        case .restoreTitle(let titleId, _):
            guard let index = copy.titles.firstIndex(where: { $0.id == titleId }) else { return copy }
            copy.titles[index].deletedAt = nil
            copy.titles[index].version = (copy.titles[index].version ?? 1) + 1
        }
        return copy
    }

    private static func deriveWatchStatus(for title: MediaTitle, in workspace: Workspace, isRevoke: Bool) -> MediaTitle {
        var updated = title
        if isRevoke && !["completed", "watching"].contains(title.status) {
            return updated
        }
        let activeEvents = workspace.events.filter { $0.titleId == title.id && $0.revokedAt == nil }
        let anyWatched = !activeEvents.isEmpty
        let desired: String
        if !title.isSeries {
            let completedMovie = activeEvents.contains { $0.episodeId == nil }
            desired = completedMovie ? "completed" : (anyWatched ? "watching" : "planned")
        } else {
            let watchedIDs = Set(activeEvents.compactMap(\.episodeId))
            let regularSeasons = (title.seasons ?? []).filter { $0.number > 0 }
            let regularEpisodes = workspace.episodes.filter { $0.titleId == title.id && $0.season > 0 }
            let allSeasonsLoaded = !regularEpisodes.isEmpty && !regularSeasons.contains { season in
                guard let expected = season.expectedEpisodes else { return true }
                let loadedCount = regularEpisodes.filter { $0.season == season.number }.count
                return loadedCount < expected
            }
            let completeSeries = allSeasonsLoaded && regularEpisodes.allSatisfy { watchedIDs.contains($0.id) }
            desired = completeSeries ? "completed" : (anyWatched ? "watching" : "planned")
        }
        if desired != updated.status {
            updated.status = desired
            updated.version = (updated.version ?? 1) + 1
        }
        return updated
    }
}
