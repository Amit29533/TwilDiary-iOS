import Foundation
import Observation
import SwiftUI
import UIKit
import TwilDiaryCore
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Coordinates iOS background sync execution (`BGTaskScheduler` + `UIApplication.beginBackgroundTask`)
/// and streams real-time progress to the Dynamic Island (`ActivityKit`).
@MainActor @Observable final class BackgroundSyncCoordinator {
    static let shared = BackgroundSyncCoordinator()
    static let refreshTaskIdentifier = "com.amit29533.TwilDiary.sync"
    static let outboxTaskIdentifier = "com.amit29533.TwilDiary.outbox"

    private(set) var currentActivityState: SyncLiveActivityState?
    private(set) var isBackgroundTaskActive = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var hasRegisteredBGTasks = false

    #if canImport(ActivityKit)
    @ObservationIgnored private var liveActivityID: String?
    @ObservationIgnored private var liveActivityUpdate: Task<Void, Never>?
    #endif

    init() {}

    /// Registers `BGTaskScheduler` handlers for periodic background sync and outbox flushing.
    func registerBackgroundTasksIfNeeded(store: DiaryStore) {
        guard !hasRegisteredBGTasks else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        hasRegisteredBGTasks = true
        #if canImport(BackgroundTasks)
        struct UncheckedBGTask: @unchecked Sendable { let value: BGTask }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { rawTask in
            let wrapped = UncheckedBGTask(value: rawTask)
            Task { @MainActor in
                await Self.shared.handleAppRefresh(task: wrapped.value, store: store)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.outboxTaskIdentifier, using: nil) { rawTask in
            let wrapped = UncheckedBGTask(value: rawTask)
            Task { @MainActor in
                await Self.shared.handleOutboxProcessing(task: wrapped.value, store: store)
            }
        }
        // Force Match and the other matches register their own background task when they start
        // (see MatchInBackground.begin).
        #endif
    }

    /// Schedules background refresh and outbox processing tasks with `BGTaskScheduler`.
    func scheduleBackgroundTasks(hasPendingOutbox: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        #if canImport(BackgroundTasks)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refreshRequest)

        if hasPendingOutbox {
            let processingRequest = BGProcessingTaskRequest(identifier: Self.outboxTaskIdentifier)
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(processingRequest)
        }
        #endif
    }

    func endBackgroundExecution() {
        isBackgroundTaskActive = false
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    /// Updates the Dynamic Island Live Activity for a multi-provider sync or outbox batch (`Trakt`, `MDBList`, `WeTrakr`).
    func updateForProviderBatch(
        provider: SyncProviderKind,
        completed: Int,
        total: Int,
        phase: SyncLiveActivityState.Phase = .flushingOutbox
    ) {
        let state = SyncLiveActivityState.forProviderBatch(
            provider: provider,
            completed: completed,
            total: total,
            phase: phase,
            isBackgrounded: isBackgroundTaskActive
        )
        applyLiveActivityState(state)
    }

    /// A match (Force Match, or Make … match the diary) in the same Live Activity as a sync.
    func showMatch(_ state: SyncLiveActivityState) { applyLiveActivityState(state) }

    func endLiveActivity() {
        let finalState = currentActivityState
        currentActivityState = nil
        #if canImport(ActivityKit)
        guard let id = liveActivityID else { return }
        liveActivityID = nil
        enqueueLiveActivityUpdate(id: id, state: finalState, ending: true)
        #endif
    }

    private func applyLiveActivityState(_ state: SyncLiveActivityState) {
        currentActivityState = state
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        #if canImport(ActivityKit)
        if let id = liveActivityID {
            // Done or stuck: it says so for a moment, then goes (it never stays up asking).
            let ending = state.phase == .completed || state.phase == .failed
            if ending { liveActivityID = nil }
            enqueueLiveActivityUpdate(id: id, state: state, ending: ending)
        } else if state.phase != .completed && state.phase != .failed {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            // One at a time: any left from before (another run, a crash) goes first.
            let staleIDs = Activity<SyncLiveActivityAttributes>.activities.map(\.id)
            if !staleIDs.isEmpty {
                Task.detached(priority: .utility) {
                    for activity in Activity<SyncLiveActivityAttributes>.activities where staleIDs.contains(activity.id) {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
            let attributes = SyncLiveActivityAttributes()
            liveActivityID = try? Activity.request(attributes: attributes, content: content, pushType: nil).id
        }
        #endif
    }

    #if canImport(ActivityKit)
    /// Only send value types across isolation boundaries. Each ordered operation
    /// resolves its own ActivityKit handle and keeps that handle local to its task.
    private func enqueueLiveActivityUpdate(id: String, state: SyncLiveActivityState?, ending: Bool) {
        let previous = liveActivityUpdate
        liveActivityUpdate = Task.detached(priority: .utility) {
            await previous?.value
            guard let activity = Activity<SyncLiveActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
            if ending {
                let content = state.map { ActivityContent(state: $0, staleDate: nil) }
                await activity.end(content, dismissalPolicy: state == nil ? .immediate : .after(.now.addingTimeInterval(6)))
            } else if let state {
                let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
                await activity.update(content)
            }
        }
    }
    #endif

    #if canImport(BackgroundTasks)
    private func handleAppRefresh(task: BGTask, store: DiaryStore) async {
        await run(task: task, store: store, includeTransfer: false)
    }

    private func handleOutboxProcessing(task: BGTask, store: DiaryStore) async {
        await run(task: task, store: store, includeTransfer: true)
    }

    private func run(task: BGTask, store: DiaryStore, includeTransfer: Bool) async {
        let work = Task { @MainActor in
            await store.flushOutbox()
            guard !Task.isCancelled else { return }
            // Edits waiting for the service your diary is on (sent before it's read) and for the
            // other services, so they go out without opening the app (Cinopsys's periodic worker).
            await store.readDiaryServiceIfDue(olderThan: 0)
            guard !Task.isCancelled else { return }
            await store.flushDirectProviders()
            guard !Task.isCancelled else { return }
            await store.refreshOnForeground()
            // Alerts kept current without opening the app (a new date learned in the background).
            if !Task.isCancelled { await EpisodeNotifications.reschedule(store: store) }
            if includeTransfer, !Task.isCancelled { await store.resumeTraktOnForeground() }
            if !Task.isCancelled { await ServerBackups.runIfDue(store: store) }
            if !Task.isCancelled { await GoogleDrive.runIfDue(store: store) }
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in store.suspendTraktForBackground() }
        }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled && !store.hasWaitingEdits)
        scheduleBackgroundTasks(hasPendingOutbox: store.hasWaitingEdits)
    }
    #endif
}
