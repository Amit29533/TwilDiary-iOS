import Foundation
import Observation
import UIKit
import TwilDiaryCore

@MainActor protocol TraktServicing {
    func status() async throws -> TraktStatus
    func review(kind: TraktKind, query: String, after: String?) async throws -> TraktSync
    func start(mode: TraktRatingMode) async throws -> String
    func step(id: String) async throws -> TraktSync
    func apply(id: String, change: String?, choice: TraktChoice) async throws -> TraktSync
    /// One bounded batch of a review group (pull, push or conflict) resolved with one choice.
    func resolve(id: String, direction: String, choice: TraktChoice) async throws -> TraktSync
    func cancel(id: String) async throws
    func disconnect() async throws
}
extension TraktServicing {
    func resolve(id: String, direction: String, choice: TraktChoice) async throws -> TraktSync {
        throw APIError.message("Resolving a whole group is not available here.")
    }
}

@MainActor final class LiveTraktService: TraktServicing {
    private weak var owner: DiaryStore?
    init(store: DiaryStore) { owner = store }
    private func requireStore() throws -> DiaryStore {
        guard let owner else { throw CancellationError() }; return owner
    }
    func status() async throws -> TraktStatus { try await requireStore().read("/api/trakt/status") }
    func review(kind: TraktKind, query: String, after: String?) async throws -> TraktSync {
        try await requireStore().read(CatalogTools.apiPath("/api/trakt/sync", query: ["kind": kind.rawValue, "query": query, "after": after ?? ""]))
    }
    func start(mode: TraktRatingMode) async throws -> String {
        struct Receipt: Decodable { let id: String }
        let result: Receipt = try await requireStore().read("/api/trakt/sync", method: "POST", body: ["ratingMode": mode.rawValue])
        return result.id
    }
    func step(id: String) async throws -> TraktSync { try await requireStore().read("/api/trakt/sync/\(id)/step", method: "POST", body: [:]) }
    func apply(id: String, change: String?, choice: TraktChoice) async throws -> TraktSync {
        var body: [String: Any] = ["choice": choice.rawValue]
        if let change { body["changeId"] = change }
        return try await requireStore().read("/api/trakt/sync/\(id)/apply", method: "POST", body: body)
    }
    func resolve(id: String, direction: String, choice: TraktChoice) async throws -> TraktSync {
        try await requireStore().read("/api/trakt/sync/\(id)/resolve", method: "POST", body: ["direction": direction, "choice": choice.rawValue])
    }
    func cancel(id: String) async throws { let _: EmptyResponse = try await requireStore().read("/api/trakt/sync/\(id)/cancel", method: "POST", body: [:]) }
    func disconnect() async throws {
        let store = try requireStore()
        store.invalidateDiscovery()
        defer { store.invalidateDiscovery() }
        let _: EmptyResponse = try await requireStore().read("/api/trakt/disconnect", method: "POST", body: [:])
    }
}

@MainActor @Observable final class TraktController {
    private let service: any TraktServicing
    private let checkpoint: any TraktApplyCheckpointStoring
    private let clock: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private let onTransferFinished: @MainActor () async -> Void
    /// Scans and approved imports run for minutes; auto-lock would suspend the app
    /// and stop them. The screen stays awake only while such work is running.
    private let keepAwake: @MainActor (Bool) -> Void
    @ObservationIgnored private var awakeHolds = 0
    private var operationID = UUID()
    private(set) var applyingAll = false
    /// The review group (pull, push or conflict) being resolved at once, if any.
    private(set) var resolvingGroup: String?
    private(set) var restoringApproval = false
    private var refreshFailure: Error?
    private var runningTask: Task<Void, Never>?
    private var runningTaskID = UUID()
    private(set) var retryAttempt = 0
    private(set) var retryMessage: String?
    var approvedRunID: String? { checkpoint.runID }
    private(set) var status: TraktStatus?
    private(set) var sync: TraktSync?
    private(set) var busy = false
    private(set) var loading = false
    private(set) var cooldownUntil = Date.distantPast
    private(set) var limit = 6
    var kind = TraktKind.all
    var query = ""
    var mode = TraktRatingMode.round
    var conflictDefault: TraktConflictDefault { didSet { defaults.set(conflictDefault.rawValue, forKey: Self.conflictDefaultKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    static let conflictDefaultKey = "traktConflictDefault"
    var error: String?
    var paused = false
    private var refreshID = UUID()
    private var receivedMode = false
    private var changingReview = false
    private var deferredRefresh = false
    private var deferredStatus = false
    init(service: any TraktServicing, checkpoint: (any TraktApplyCheckpointStoring)? = nil,
         clock: @escaping @MainActor () -> Date = { .now },
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         keepAwake: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         onTransferFinished: @escaping @MainActor () async -> Void = {},
         defaults: UserDefaults = .standard) {
        self.service = service; self.checkpoint = checkpoint ?? MemoryTraktApplyCheckpoint()
        self.defaults = defaults
        conflictDefault = TraktConflictDefault(rawValue: defaults.string(forKey: Self.conflictDefaultKey) ?? "") ?? .ask
        self.clock = clock; self.sleep = sleep; self.keepAwake = keepAwake; self.onTransferFinished = onTransferFinished
    }
    private func holdAwake() { awakeHolds += 1; if awakeHolds == 1 { keepAwake(true) } }
    private func releaseAwake() { awakeHolds = max(0, awakeHolds - 1); if awakeHolds == 0 { keepAwake(false) } }
    /// Pause between successful steps. Cooldowns and Retry-After are honoured
    /// separately; the old fixed 1 s / 0.5 s waits added about 30 minutes to a
    /// 2,000-change import without protecting anything.
    private static let stepPacing: TimeInterval = 0.15
    func pauseApplying() {
        paused = true; checkpoint.runID = nil
        if restoringApproval { runningTask?.cancel() }
    }
    func suspendForBackground() { paused = true; runningTask?.cancel() }
    func finishSuspendingTransfer() async {
        if let task = runningTask, task.isCancelled { await task.value }
    }
    func startApprovedApply() {
        launchApprovedApply(restoring: nil)
    }
    private func launchApprovedApply(restoring id: String?) {
        guard !busy, runningTask == nil else { return }
        let taskID = UUID(); runningTaskID = taskID
        runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let id { await self.restoreApprovedApply(id: id) }
            else { await self.apply() }
            guard self.runningTaskID == taskID else { return }
            if !Task.isCancelled { await self.onTransferFinished() }
            if self.runningTaskID == taskID { self.runningTask = nil }
        }
    }
    func invalidateSession() {
        operationID = UUID(); refreshID = UUID(); runningTaskID = UUID(); paused = true; checkpoint.runID = nil
        runningTask?.cancel(); runningTask = nil
        sync = nil; status = nil; error = nil; retryMessage = nil; refreshFailure = nil
    }
    func resumeApprovedApply() async {
        guard !busy, !loading, let id = checkpoint.runID else { return }
        if refreshFailure == nil, let status, let sync {
            guard sync.run?.id == id, sync.reviewing, status.connected, status.needsReconnect != true else {
                checkpoint.runID = nil; return
            }
            startApprovedApply()
        } else { launchApprovedApply(restoring: id) }
    }
    /// A persisted approval is only a run identity. Restore the connection and
    /// current review with GETs before it can authorize another write.
    private func restoreApprovedApply(id: String) async {
        guard !busy, checkpoint.runID == id else { return }
        holdAwake(); defer { releaseAwake() }
        let ticket = UUID(); operationID = ticket; refreshID = UUID()
        busy = true; changingReview = true; restoringApproval = true; paused = false
        retryAttempt = 0; error = nil; retryMessage = nil
        var restored = false
        do {
            if let failure = refreshFailure { try scheduleRecovery(failure, ticket: ticket) }
            while !paused {
                try await waitForCooldown(ticket)
                try checkApproval(id: id, ticket: ticket)
                do {
                    let connection = try await service.status()
                    try checkApproval(id: id, ticket: ticket)
                    guard connection.connected, connection.needsReconnect != true else {
                        throw APIError.message("Reconnect Trakt before resuming this import.")
                    }
                    let review = try await service.review(kind: .all, query: "", after: nil)
                    try checkApproval(id: id, ticket: ticket)
                    guard review.run?.id == id else {
                        throw APIError.message("The review changed. Open the current review before continuing.")
                    }
                    if review.run?.state == "complete" {
                        // A final receipt may have been lost before termination.
                        // This GET confirms completion; never replay its POST.
                        status = connection; accept(review); refreshFailure = nil; checkpoint.runID = nil
                        break
                    }
                    guard review.reviewing else {
                        throw APIError.message("The review changed. Open the current review before continuing.")
                    }
                    status = connection; accept(review); limit = 6; refreshFailure = nil
                    restored = true; break
                } catch is CancellationError { throw CancellationError() }
                catch { try scheduleRecovery(error, ticket: ticket) }
            }
        } catch is CancellationError { if operationID == ticket { paused = true } }
        catch {
            if operationID == ticket { self.error = error.localizedDescription; paused = true; checkpoint.runID = nil }
        }
        restoringApproval = false
        guard operationID == ticket else { changingReview = false; busy = false; return }
        changingReview = false; busy = false; retryMessage = nil
        if restored, !paused, !Task.isCancelled, checkpoint.runID == id {
            await applyAllReady()
        } else {
            // Do not bypass the cooldown with a deferred filter/status refresh.
            deferredRefresh = false; deferredStatus = false
        }
    }
    private func checkApproval(id: String, ticket: UUID) throws {
        try Task.checkCancellation()
        guard operationID == ticket, !paused, checkpoint.runID == id else { throw CancellationError() }
    }
    var visibleItems: [TraktChange] { sync?.items.filter { (kind == .all || $0.kind == kind.rawValue) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } ?? [] }
    func refresh() async {
        await refresh(includeStatus: true)
    }
    func refreshReview() async {
        await refresh(includeStatus: status == nil)
    }
    private func refresh(includeStatus: Bool) async {
        guard !Task.isCancelled else { return }
        guard !changingReview else {
            deferredRefresh = true; deferredStatus = deferredStatus || includeStatus
            return
        }
        let request = UUID(); refreshID = request; loading = true
        let selectedKind = kind, search = query
        defer { if refreshID == request { loading = false } }
        do {
            let connection: TraktStatus?
            if includeStatus { connection = try await service.status() } else { connection = nil }
            let review = try await service.review(kind: selectedKind, query: search, after: nil)
            guard request == refreshID, !changingReview, kind == selectedKind, query == search, !Task.isCancelled else { return }
            if let connection { status = connection }
            accept(review); limit = 6; error = nil; refreshFailure = nil
            if !receivedMode, let raw = review.run?.ratingMode, let value = TraktRatingMode(rawValue: raw) { mode = value; receivedMode = true }
        } catch is CancellationError { }
        catch { if request == refreshID, !changingReview, kind == selectedKind, query == search, !Task.isCancelled { self.error = error.localizedDescription; refreshFailure = error } }
    }
    func loadMore() async {
        guard !busy, let current = sync else { return }
        if limit < current.items.count { limit += 6; return }
        guard let cursor = current.next else { return }
        let request = refreshID, selectedKind = kind, search = query
        busy = true; defer { busy = false }
        do {
            let next = try await service.review(kind: selectedKind, query: search, after: cursor)
            guard request == refreshID, kind == selectedKind, query == search else { return }
            accept(current.appending(next)); limit += 6
        } catch is CancellationError { }
        catch { if request == refreshID, kind == selectedKind, query == search, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func scan(start: Bool) async {
        guard !busy else { return }
        holdAwake(); defer { releaseAwake() }
        let ticket = UUID(); operationID = ticket
        refreshID = UUID(); loading = false; busy = true; changingReview = true
        paused = false; error = nil; retryAttempt = 0
        do {
            var id = sync?.run?.id
            if start || id == nil {
                if let run = sync?.run, ["building", "review", "applying"].contains(run.state) { try await service.cancel(id: run.id) }
                id = try await service.start(mode: mode)
            }
            guard let id else { throw APIError.message("The Trakt scan did not start. Please retry.") }
            var previousStep: String?
            var reconcile = false
            while !paused {
                try await waitForCooldown(ticket)
                if paused { break }
                do {
                    if reconcile {
                        let saved = try await service.review(kind: .all, query: "", after: nil)
                        try Task.checkCancellation()
                        guard operationID == ticket else { throw CancellationError() }
                        if paused { break }
                        guard saved.run?.id == id else { throw APIError.message("The scan changed. Open the latest review.") }
                        accept(saved); reconcile = false
                        if cooldownUntil > clock() { continue }
                        if saved.run?.state != "building" { break }
                    }
                    let result = try await service.step(id: id)
                    guard operationID == ticket else { throw CancellationError() }
                    accept(result); retryAttempt = 0; retryMessage = nil
                    if result.run?.state != "building" { break }
                    let signature = "\(result.run?.stage ?? ""):\(result.run?.page ?? 0):\(result.run?.progress ?? 0)"
                    if signature == previousStep { paused = true; break }
                    previousStep = signature
                    try await sleep(Self.stepPacing)
                } catch is CancellationError { throw CancellationError() }
                catch { try scheduleRecovery(error, ticket: ticket); reconcile = true }
            }
        } catch is CancellationError { paused = true }
        catch { if operationID == ticket { self.error = error.localizedDescription; paused = true } }
        retryMessage = nil
        if operationID == ticket { await finishChangingReview() }
        else { changingReview = false; busy = false; return }
        // With a conflict default the whole review applies itself, conflicts included.
        if conflictDefault.choice != nil, error == nil, !paused, sync?.reviewing == true, sync?.run?.id != nil { startApprovedApply() }
    }
    func apply(change: TraktChange? = nil, choice: TraktChoice = .apply) async {
        if change == nil && choice == .apply { await applyAllReady(); return }
        guard !busy, let current = sync, current.reviewing, let id = current.run?.id, choice == .skip || cooldownUntil <= .now else { return }
        refreshID = UUID(); loading = false; busy = true; changingReview = true; paused = false; error = nil
        do {
            var steps = 0
            repeat {
                try Task.checkCancellation()
                let result = try await service.apply(id: id, change: change?.id, choice: choice); accept(result)
                steps += 1
                if change != nil || paused || !result.reviewing || (result.counts["safe"] ?? 0) == 0 || cooldownUntil > .now { break }
                if steps >= 100 { paused = true; break }
            } while true
            if !paused, let result = sync, result.reviewing,
               (result.counts["safe"] ?? 0) == 0, result.unresolved == 0 {
                accept(try await service.apply(id: id, change: nil, choice: .apply))
            }
            deferredRefresh = true; deferredStatus = true
        } catch is CancellationError { paused = true }
        catch { self.error = error.localizedDescription }
        await finishChangingReview()
    }
    private func applyAllReady() async {
        guard !busy, let current = sync, current.reviewing, let id = current.run?.id else { return }
        holdAwake(); defer { releaseAwake() }
        let ticket = UUID(); operationID = ticket
        refreshID = UUID(); loading = false; busy = true; changingReview = true
        paused = false; applyingAll = true; checkpoint.runID = id
        error = nil; retryAttempt = 0; retryMessage = nil
        var reconcile = false, stagnant = 0
        do {
            while !paused {
                try Task.checkCancellation()
                guard operationID == ticket else { throw CancellationError() }
                try await waitForCooldown(ticket)
                if paused { break }
                do {
                    if reconcile {
                        let latest = try await service.review(kind: .all, query: "", after: nil)
                        try Task.checkCancellation()
                        guard operationID == ticket else { throw CancellationError() }
                        if paused { break }
                        guard latest.run?.id == id else { throw APIError.message("The review changed. Open the current review before continuing.") }
                        accept(latest); reconcile = false
                        if cooldownUntil > clock() { continue }
                    }
                    guard let before = sync, before.run?.id == id, before.reviewing else { break }
                    if (before.counts["safe"] ?? 0) == 0 && before.unresolved > 0 {
                        // Ready changes are done; the server settles conflicts with the chosen side, a batch per request.
                        guard let choice = conflictDefault.choice, (before.counts["review:conflict"] ?? 0) > 0 else { break }
                        let result = try await service.resolve(id: id, direction: "conflict", choice: choice)
                        guard operationID == ticket else { throw CancellationError() }
                        guard result.run?.id == id else { throw APIError.message("The review changed. Refresh before continuing.") }
                        accept(result); retryAttempt = 0; retryMessage = nil; error = nil
                        // Unchanged counts: what is left (Trash, unconfirmed sends) needs an individual choice.
                        if !result.reviewing || result.counts == before.counts { break }
                        try await sleep(Self.stepPacing); continue
                    }
                    let result = try await service.apply(id: id, change: nil, choice: .apply)
                    guard operationID == ticket else { throw CancellationError() }
                    guard result.run?.id == id else { throw APIError.message("The review changed. Refresh before continuing.") }
                    accept(result); retryAttempt = 0; retryMessage = nil; error = nil
                    if !result.reviewing { break }
                    if result.counts == before.counts { stagnant += 1 } else { stagnant = 0 }
                    if stagnant >= 2 { throw APIError.message("The server made no further progress. Your completed changes are saved; review the remaining items.") }
                    // Yield and lightly pace the approved job instead of stopping at
                    // 100 requests or running a tight loop against the free-plan backend.
                    try await sleep(Self.stepPacing)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try scheduleRecovery(error, ticket: ticket)
                    reconcile = true
                }
            }
            if !paused { checkpoint.runID = nil }
            deferredRefresh = true; deferredStatus = true
        } catch is CancellationError { paused = true }
        catch { self.error = error.localizedDescription; paused = true; checkpoint.runID = nil }
        applyingAll = false; retryMessage = nil
        if operationID == ticket { await finishChangingReview() }
        else { changingReview = false; busy = false }
    }
    /// Resolve every pending review item of one direction with one choice, a bounded batch
    /// per request, until none remain. Items the server cannot resolve this way (blocked or
    /// unconfirmed) stay for an individual choice. A finished review is then completed.
    func resolveAll(direction: String, choice: TraktChoice) async {
        guard !busy, let current = sync, current.reviewing, let id = current.run?.id,
              choice != .apply, choice == .skip || cooldownUntil <= clock() else { return }
        holdAwake(); defer { releaseAwake() }
        let ticket = UUID(); operationID = ticket
        refreshID = UUID(); loading = false; busy = true; changingReview = true
        paused = false; resolvingGroup = direction
        error = nil; retryAttempt = 0; retryMessage = nil
        let key = "review:" + direction
        var reconcile = false
        do {
            while !paused {
                try Task.checkCancellation()
                guard operationID == ticket else { throw CancellationError() }
                try await waitForCooldown(ticket)
                if paused { break }
                do {
                    if reconcile {
                        let latest = try await service.review(kind: .all, query: "", after: nil)
                        guard operationID == ticket else { throw CancellationError() }
                        guard latest.run?.id == id else { throw APIError.message("The review changed. Open the current review before continuing.") }
                        accept(latest); reconcile = false
                        if cooldownUntil > clock() { continue }
                    }
                    guard let before = sync, before.run?.id == id, before.reviewing, (before.counts[key] ?? 0) > 0 else { break }
                    let result = try await service.resolve(id: id, direction: direction, choice: choice)
                    guard operationID == ticket else { throw CancellationError() }
                    guard result.run?.id == id else { throw APIError.message("The review changed. Refresh before continuing.") }
                    accept(result); retryAttempt = 0; retryMessage = nil
                    if !result.reviewing || (result.counts[key] ?? 0) == 0 { break }
                    if result.counts == before.counts {
                        throw APIError.message("\(result.counts[key] ?? 0) items need an individual choice (for example titles in Trash). Everything else is saved.")
                    }
                    try await sleep(Self.stepPacing)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try scheduleRecovery(error, ticket: ticket)
                    reconcile = true
                }
            }
            if !paused, let result = sync, result.reviewing, (result.counts["safe"] ?? 0) == 0, result.unresolved == 0 {
                accept(try await service.apply(id: id, change: nil, choice: .apply))
            }
            deferredRefresh = true; deferredStatus = true
        } catch is CancellationError { paused = true }
        catch { self.error = error.localizedDescription }
        resolvingGroup = nil; retryMessage = nil
        if operationID == ticket { await finishChangingReview() }
        else { changingReview = false; busy = false }
        if choice != .skip { await onTransferFinished() }
    }
    private func waitForCooldown(_ ticket: UUID) async throws {
        while cooldownUntil > clock() && !paused {
            let remaining = cooldownUntil.timeIntervalSince(clock())
            try await sleep(min(remaining > 60 ? 30 : 1, remaining))
            try Task.checkCancellation()
            guard operationID == ticket else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard operationID == ticket else { throw CancellationError() }
    }
    private func scheduleRecovery(_ error: Error, ticket: UUID) throws {
        guard operationID == ticket else { throw CancellationError() }
        let failure = error as? TraktTransferFailure
        let reset: Date?
        let databaseQuota: Bool
        if case APIError.databaseLimit(let date) = error { databaseQuota = true; reset = date ?? clock().addingTimeInterval(3600) }
        else { databaseQuota = false; reset = failure?.retryAt }
        guard failure?.retryable == true || databaseQuota || error is DecodingError else { throw error }
        retryAttempt += 1
        guard retryAttempt <= 6 else { throw APIError.message("The connection is still unavailable after six recovery attempts. Completed changes are saved. Resume when the service is available.") }
        let delay = min(60, pow(2, Double(retryAttempt)))
        cooldownUntil = max(reset ?? .distantPast, clock().addingTimeInterval(delay))
        retryMessage = databaseQuota
            ? "Cloudflare’s daily database allowance is exhausted. Waiting until the reset, then checking saved progress."
            : "\(failure?.message ?? "The response was incomplete.") Waiting, then checking saved progress (attempt \(retryAttempt) of 6)."
    }
    func cancel() async {
        checkpoint.runID = nil
        guard !busy, let id = sync?.run?.id else { return }
        refreshID = UUID(); loading = false; busy = true; changingReview = true
        do { try await service.cancel(id: id); deferredRefresh = true; deferredStatus = true } catch { self.error = error.localizedDescription }
        await finishChangingReview()
    }
    func disconnect() async {
        checkpoint.runID = nil
        guard !busy else { return }
        refreshID = UUID(); loading = false; busy = true; changingReview = true
        do { try await service.disconnect(); deferredRefresh = true; deferredStatus = true } catch { self.error = error.localizedDescription }
        await finishChangingReview()
    }
    private func finishChangingReview() async {
        changingReview = false; busy = false
        let pending = deferredRefresh, includeStatus = deferredStatus
        deferredRefresh = false; deferredStatus = false
        if pending {
            let retainedError = error
            await refresh(includeStatus: includeStatus)
            if let retainedError { error = retainedError }
        }
    }
    private func accept(_ value: TraktSync) { sync = value; cooldownUntil = clock().addingTimeInterval(Double(max(0, min(86_400, value.run?.retryAfter ?? 0)))) }
}
