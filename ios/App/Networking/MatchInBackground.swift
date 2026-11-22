import Foundation
import Observation
import BackgroundTasks
import TwilDiaryCore

// MARK: Matches that keep going in the background

/// A match you start keeps running when you leave the app, as an iOS 26 continued processing
/// task: iOS shows it as a Live Activity with its progress (Lock Screen and Dynamic Island) and
/// keeps the app working until it's done. If iOS has to stop it, the match stops cleanly and says
/// so; running it again sends only what's still different.
@MainActor final class MatchInBackground {
    static let shared = MatchInBackground()
    private static let prefix = (Bundle.main.bundleIdentifier ?? "com.amit29533.TwilDiary") + ".match"
    /// The identifier of the match now running; a launch for an older one is turned away.
    private var current: String?
    private var task: BGContinuedProcessingTask?
    private var title = "", subtitle = "Starting…"
    private var done: Int64 = 0, total: Int64 = 1
    /// The service being matched, for TwilDiary's own Live Activity ("Syncing with WeTrakr · 5 of 40").
    private var provider: SyncProviderKind?
    /// iOS stopped the background work: the match stops at the next call.
    private(set) var expired = false

    func begin(_ title: String, provider: SyncProviderKind) {
        end(nil)
        self.title = title; subtitle = "Starting…"; done = 0; total = 1; expired = false
        self.provider = provider
        show(.syncingProvider)
        // Info.plist permits "<bundle id>.match.*"; each match registers its own identifier under it
        // and then submits it. Submitting an identifier with no handler registered for it exactly
        // is an assertion failure in BGTaskScheduler that ends the app (registering the ".*"
        // pattern itself doesn't cover it). If iOS won't register it, the match still runs while
        // the app is open.
        let identifier = Self.prefix + "." + UUID().uuidString
        guard Self.registerLaunch(identifier) else { return }
        current = identifier
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }
    /// The launch and expiration handlers are made outside the main actor: iOS may call them on its
    /// own queue, and a main-actor closure called there traps under Swift 6. Each hops to the main
    /// actor itself, as the app's other background tasks do.
    private nonisolated static func registerLaunch(_ identifier: String) -> Bool {
        struct Unchecked: @unchecked Sendable { let task: BGTask }
        return BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { raw in
            let wrapped = Unchecked(task: raw)
            Task { @MainActor in MatchInBackground.shared.attach(wrapped.task, identifier: identifier) }
        }
    }
    private nonisolated static func expiry() -> @Sendable () -> Void {
        { Task { @MainActor in MatchInBackground.shared.expire() } }
    }
    private func attach(_ raw: BGTask, identifier: String) {
        guard let task = raw as? BGContinuedProcessingTask, !title.isEmpty, identifier == current else { raw.setTaskCompleted(success: false); return }
        self.task = task
        task.expirationHandler = Self.expiry()
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = done
        task.updateTitle(title, subtitle: subtitle)
    }
    /// What it's doing now, shown under the Live Activity's title.
    func update(_ text: String) {
        guard !title.isEmpty, text != subtitle else { return }
        subtitle = text
        task?.updateTitle(title, subtitle: text)
    }
    /// How far along: calls sent of calls to send.
    func count(_ done: Int, of total: Int) {
        self.done = Int64(max(0, done)); self.total = Int64(max(1, total))
        task?.progress.totalUnitCount = self.total
        task?.progress.completedUnitCount = min(self.done, self.total)
        show(.syncingProvider)
    }
    /// TwilDiary's own designed Live Activity: the service, how far along, then done or needs you.
    private func show(_ phase: SyncLiveActivityState.Phase, note: String? = nil) {
        guard let provider else { return }
        // While it runs: "12 of 40". Done or stuck: what happened (the ring shows full, or amber).
        let running = phase != .completed && phase != .failed && done > 0
        BackgroundSyncCoordinator.shared.showMatch(SyncLiveActivityState(
            provider: provider, phase: phase, title: title, subtitle: note ?? subtitle,
            completedCount: running ? Int(min(done, total)) : 0, totalCount: running ? Int(total) : 0, isBackgrounded: task != nil))
    }
    /// Done: the Live Activity shows how it went, and the app may go to sleep.
    func end(_ summary: String?, success: Bool = true) {
        if provider != nil {
            show(success ? .completed : .failed, note: summary.map { String($0.prefix(80)) })
            provider = nil
        }
        if let task {
            if let summary { task.updateTitle(title, subtitle: String(summary.prefix(120))) }
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil; title = ""; current = nil
    }
    private func expire() {
        expired = true
        task?.setTaskCompleted(success: false)
        task = nil
    }
}
