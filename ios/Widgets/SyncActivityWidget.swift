import SwiftUI
import WidgetKit
import ActivityKit
import TwilDiaryCore

@main struct TwilDiaryWidgets: WidgetBundle {
    var body: some Widget { SyncLiveActivityWidget() }
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
