import Foundation
import ActivityKit

/// Starts, updates and ends JellySpace's Live Activity (one at a time). The bar moves on its own from
/// the start and end times, so it's only updated when something changes: play, pause, a jump, the
/// speed, the next episode's countdown.
@MainActor enum JellyLiveActivity {
    private static var current: Activity<JellyPlaybackAttributes>?

    static func show(_ state: JellyPlaybackAttributes.ContentState, item: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.paused ? nil : state.endsAt.addingTimeInterval(60))
        if let current, current.attributes.itemID == item, current.activityState == .active {
            Task { await current.update(content) }
            return
        }
        end()
        current = try? Activity.request(attributes: JellyPlaybackAttributes(itemID: item), content: content, pushType: nil)
    }
    static func end() {
        guard let finished = current else { return }
        current = nil
        Task { await finished.end(nil, dismissalPolicy: .immediate) }
    }
}
