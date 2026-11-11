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
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SyncAppMark(size: 44).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) { SyncRing(state: context.state, size: 40).padding(.trailing, 4) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SyncActivityText.headline(context.state)).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(SyncActivityText.detail(context.state)).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                SyncAppMark(size: 22)
            } compactTrailing: {
                SyncRing(state: context.state, size: 20)
            } minimal: {
                SyncRing(state: context.state, size: 20)
            }
        }
    }
}
#endif
