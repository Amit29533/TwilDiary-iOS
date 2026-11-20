import SwiftUI
import WidgetKit
import ActivityKit
import TwilDiaryCore

@main struct TwilDiaryWidgets: WidgetBundle {
    var body: some Widget {
        SyncLiveActivityWidget()
        JellyPlaybackActivityWidget()
    }
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

#if canImport(ActivityKit) && canImport(WidgetKit)
/// JellySpace's Live Activity: on the Lock Screen and in the Dynamic Island while something plays.
struct JellyPlaybackActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JellyPlaybackAttributes.self) { context in
            JellyPlaybackBanner(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SyncAppMark(size: 40).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.paused ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(context.state.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let next = context.state.nextTitle, let at = context.state.nextAt {
                        HStack(spacing: 6) {
                            Text("Up next in").foregroundStyle(.secondary)
                            Text(timerInterval: Date.now...max(Date.now, at), countsDown: true).monospacedDigit()
                            Text("· " + next).lineLimit(1)
                        }.font(.system(size: 13, weight: .semibold))
                    } else {
                        JellyPlaybackBar(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.nextAt != nil ? "forward.end.fill" : context.state.paused ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
            } compactTrailing: {
                if let at = context.state.nextAt {
                    Text(timerInterval: Date.now...max(Date.now, at), countsDown: true).monospacedDigit().frame(width: 40)
                } else if context.state.paused {
                    Text("Paused").font(.system(size: 12, weight: .semibold))
                } else {
                    Text(timerInterval: Date.now...max(Date.now, context.state.endsAt), countsDown: true).monospacedDigit().frame(width: 48)
                }
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold))
            }
        }
    }
}
#endif
