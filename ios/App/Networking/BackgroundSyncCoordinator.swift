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

#if canImport(ActivityKit)
/// ActivityKit attributes for displaying background & foreground sync progress on the iOS Dynamic Island and Lock Screen.
public struct SyncLiveActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = SyncLiveActivityState
    public let sessionName: String

    public init(sessionName: String = "TwilDiary Sync") {
        self.sessionName = sessionName
    }
}
#endif

/// Reusable SwiftUI banner view used by both the Lock Screen Live Activity and expanded Dynamic Island region.
@MainActor struct DynamicIslandSyncBannerView: View {
    let state: SyncLiveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.subheadline.bold())
                    .foregroundStyle(accentColor)
                Text(state.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(state.percent)%")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(accentColor)
            }
            ProgressView(value: state.fraction)
                .tint(accentColor)
            HStack(spacing: 6) {
                Text(state.providerDisplayName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accentColor.opacity(0.18), in: Capsule())
                Text(state.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }

    private var iconName: String {
        switch state.phase {
        case .completed: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var accentColor: Color {
        switch state.phase {
        case .completed: .green
        case .paused, .failed: .orange
        default: Color(red: 0.62, green: 0.51, blue: 0.98)
        }
    }
}

#if canImport(ActivityKit) && canImport(WidgetKit)
/// Live Activity & Dynamic Island widget configuration for TwilDiary background sync.
struct SyncLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncLiveActivityAttributes.self) { context in
            DynamicIslandSyncBannerView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.phase == .completed ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                        Text(context.state.providerDisplayName)
                            .font(.caption.bold())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.percent)%")
                        .font(.caption.monospacedDigit().bold())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.fraction)
                        Text(context.state.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: context.state.phase == .completed ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.caption2.bold())
                    Text(context.state.compactBadge)
                        .font(.caption2.bold())
                }
            } compactTrailing: {
                Text("\(context.state.percent)%")
                    .font(.caption2.monospacedDigit().bold())
            } minimal: {
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
            }
        }
    }
}
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
    @ObservationIgnored private var liveActivity: Activity<SyncLiveActivityAttributes>?
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
            try? BGTaskScheduler.shared.submit(processingRequest)
        }
        #endif
    }

    /// Requests an iOS background execution window so an active sync or outbox flush can continue
    /// while updating the Dynamic Island Live Activity.
    func beginBackgroundExecution(onExpire: @escaping @MainActor @Sendable () -> Void = {}) {
        guard backgroundTaskID == .invalid else { return }
        isBackgroundTaskActive = true
        if let state = currentActivityState {
            let bgState = SyncLiveActivityState(
                provider: state.provider,
                phase: state.phase,
                title: state.title,
                subtitle: state.subtitle,
                completedCount: state.completedCount,
                totalCount: state.totalCount,
                isBackgrounded: true
            )
            applyLiveActivityState(bgState)
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "TwilDiaryBackgroundSync") { [weak self] in
            Task { @MainActor in
                onExpire()
                self?.endBackgroundExecution()
            }
        }
    }

    func endBackgroundExecution() {
        isBackgroundTaskActive = false
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    /// Updates the Dynamic Island Live Activity from a `TraktSync` snapshot.
    func updateFromTrakt(_ sync: TraktSync?, paused: Bool) {
        guard let sync,
              let state = SyncLiveActivityState.fromTrakt(sync, paused: paused, isBackgrounded: isBackgroundTaskActive) else {
            endLiveActivity()
            return
        }
        applyLiveActivityState(state)
    }

    /// Updates the Dynamic Island Live Activity for a multi-provider sync or outbox batch (`WeTrakr`, `Simkl`, `MDBList`, `Trakt`).
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

    func endLiveActivity() {
        let finalState = currentActivityState
        currentActivityState = nil
        #if canImport(ActivityKit)
        guard let activity = liveActivity else { return }
        liveActivity = nil
        Task {
            if let finalState {
                let content = ActivityContent(state: finalState, staleDate: nil)
                await activity.end(content, dismissalPolicy: .default)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    private func applyLiveActivityState(_ state: SyncLiveActivityState) {
        currentActivityState = state
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
        #endif
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
        if let existing = liveActivity {
            Task {
                await existing.update(content)
                if state.phase == .completed {
                    await existing.end(content, dismissalPolicy: .default)
                }
            }
            if state.phase == .completed {
                liveActivity = nil
            }
        } else if state.phase != .completed {
            let attributes = SyncLiveActivityAttributes()
            liveActivity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
        #endif
    }

    #if canImport(BackgroundTasks)
    private func handleAppRefresh(task: BGTask, store: DiaryStore) async {
        scheduleBackgroundTasks(hasPendingOutbox: !store.outbox.isEmpty)
        task.expirationHandler = {
            Task { @MainActor in
                store.suspendTraktForBackground()
            }
        }
        await store.refreshOnForeground()
        task.setTaskCompleted(success: true)
    }

    private func handleOutboxProcessing(task: BGTask, store: DiaryStore) async {
        task.expirationHandler = {
            Task { @MainActor in
                store.suspendTraktForBackground()
            }
        }
        await store.refreshOnForeground()
        await store.resumeTraktOnForeground()
        task.setTaskCompleted(success: true)
    }
    #endif
}
