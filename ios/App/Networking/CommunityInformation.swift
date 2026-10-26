import Foundation
import Observation
import TwilDiaryCore

struct CommunityIdentity: Hashable, Sendable {
    let kind: MediaKind
    let id: Int
    init?(kind: MediaKind, id: Int?) {
        guard let id, id > 0, id <= 9_999_999_999 else { return nil }
        self.kind = kind; self.id = id
    }
    var path: String { CatalogTools.apiPath("/api/trakt/community", query: ["kind": kind == .tv ? "show" : "movie", "provider": "tmdb", "id": String(id)]) }
}
struct CommunityInformation: Decodable, Sendable {
    enum State: String, Decodable, Sendable { case available, empty, unavailable, unmatched; case notConfigured = "not-configured" }
    struct Stats: Decodable, Sendable {
        let watchers: Int
        let plays: Int
        let collectors: Int
        let comments: Int
        let lists: Int
        var valid: Bool { [watchers, plays, collectors, comments, lists].allSatisfy { $0 >= 0 } }
    }
    struct Sentiments: Decodable, Sendable {
        let good: [String]
        let bad: [String]
        let analyzedAt: String
        let commentCount: Int
        var valid: Bool { commentCount >= 0 && DiaryDate.parse(analyzedAt) != nil && good.count <= 12 && bad.count <= 12 && (good + bad).allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1000 } }
    }
    let source: String
    let statsState: State
    let sentimentsState: State
    let stats: Stats?
    let sentiments: Sentiments?
    var valid: Bool {
        source == "trakt" && (statsState == .available ? stats?.valid == true : stats == nil)
        && ([.available, .empty].contains(sentimentsState) ? sentiments?.valid == true : sentiments == nil)
    }
    static let unmatched = CommunityInformation(source: "trakt", statsState: .unmatched, sentimentsState: .unmatched, stats: nil, sentiments: nil)
}

@MainActor final class CommunityInformationCache {
    private var scope: UUID?
    private var generation = UUID()
    private var pages: [CommunityIdentity: (at: Date, value: CommunityInformation)] = [:]
    private var pending: [CommunityIdentity: (id: UUID, task: Task<CommunityInformation, Error>)] = [:]
    func reset() {
        generation = UUID(); scope = nil; pages = [:]
        for read in pending.values { read.task.cancel() }
        pending = [:]
    }
    /// A fresh saved page for this session, for a synchronous first frame.
    func saved(_ identity: CommunityIdentity, scope: UUID) -> CommunityInformation? {
        guard self.scope == scope, let saved = pages[identity], Date.now.timeIntervalSince(saved.at) < 300 else { return nil }
        return saved.value
    }
    func load(_ identity: CommunityIdentity, scope: UUID, retry: Bool, fetch: @escaping @MainActor @Sendable () async throws -> CommunityInformation) async throws -> CommunityInformation {
        if self.scope != scope { reset(); self.scope = scope }
        let epoch = generation
        if !retry, let saved = pages[identity], Date.now.timeIntervalSince(saved.at) < (saved.value.statsState == .unavailable || saved.value.sentimentsState == .unavailable ? 30 : 300) { return saved.value }
        let task: Task<CommunityInformation, Error>
        if let active = pending[identity] { task = active.task }
        else {
            let id = UUID()
            task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                defer { if self.pending[identity]?.id == id { self.pending.removeValue(forKey: identity) } }
                let result = try await fetch()
                try Task.checkCancellation()
                guard self.scope == scope, self.generation == epoch else { throw CancellationError() }
                guard result.valid else { throw APIError.message("Trakt community information was incomplete. Please retry.") }
                if self.pages.count >= 32, self.pages[identity] == nil, let oldest = self.pages.min(by: { $0.value.at < $1.value.at })?.key { self.pages.removeValue(forKey: oldest) }
                self.pages[identity] = (.now, result)
                return result
            }
            pending[identity] = (id, task)
        }
        let value = try await task.value
        try Task.checkCancellation()
        guard self.scope == scope, generation == epoch else { throw CancellationError() }
        return value
    }
}

extension DiaryStore {
    func cachedCommunityInformation(_ identity: CommunityIdentity) -> CommunityInformation? {
        communityCache.saved(identity, scope: sessionRevision)
    }
    func communityInformation(_ identity: CommunityIdentity, retry: Bool) async throws -> CommunityInformation {
        let scope = sessionRevision
        return try await communityCache.load(identity, scope: scope, retry: retry) { [self] in
            #if DEBUG
            if isPreview { return CommunityInformation.fixture(unavailable: ProcessInfo.processInfo.arguments.contains("--ui-community-unavailable")) }
            #endif
            guard !needsSignIn else { throw APIError.signIn }
            do { return try await read(identity.path, timeout: 25) }
            catch APIError.rejected(404, _) { throw APIError.message("Community information is unavailable right now. Please try again later.") }
        }
    }
}

@MainActor @Observable final class CommunityInformationController {
    private var generation = UUID()
    private var identity: CommunityIdentity?
    private(set) var value: CommunityInformation?
    private(set) var loading = false
    private(set) var error: String?
    func load(_ identity: CommunityIdentity?, retry: Bool = false, fetch: @MainActor (CommunityIdentity, Bool) async throws -> CommunityInformation) async {
        let request = UUID(); generation = request
        if self.identity != identity { value = nil; self.identity = identity }
        guard let identity else { value = .unmatched; error = nil; loading = false; return }
        loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let result = try await fetch(identity, retry)
            guard generation == request, !Task.isCancelled else { return }
            guard result.valid else { throw APIError.message("Community information was incomplete. Please retry.") }
            value = result
        } catch is CancellationError { }
        catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

#if DEBUG
extension CommunityInformation {
    static func fixture(unavailable: Bool) -> CommunityInformation {
        if unavailable { return CommunityInformation(source: "trakt", statsState: .unavailable, sentimentsState: .unavailable, stats: nil, sentiments: nil) }
        return CommunityInformation(source: "trakt", statsState: .available, sentimentsState: .available,
            stats: Stats(watchers: 5200, plays: 49300, collectors: 327, comments: 13, lists: 2300),
            sentiments: Sentiments(good: ["Engaging pacing and mysteries", "Effective blend of genres"], bad: ["Repetitive storyline"], analyzedAt: "2026-10-24T10:00:00Z", commentCount: 13))
    }
}
#endif
