import Foundation
import ActivityKit

/// Starts, updates and ends JellySpace's Live Activity (one at a time). The bar moves on its own from
/// the start and end times, so it's only updated when something changes: play, pause, a jump, the
/// speed, the next episode's countdown. As the sync Live Activity does, each change runs after the one
/// before and finds its ActivityKit handle by id inside its own task.
@MainActor enum JellyLiveActivity {
    private static var currentID: String?
    private static var currentItem: String?
    private static var pending: Task<Void, Never>?

    static func show(_ state: JellyPlaybackAttributes.ContentState, item: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.paused ? nil : state.endsAt.addingTimeInterval(60))
        if let id = currentID, currentItem == item {
            enqueue(id: id, content: content, ending: false)
            return
        }
        end()
        currentID = try? Activity.request(attributes: JellyPlaybackAttributes(itemID: item), content: content, pushType: nil).id
        currentItem = item
    }
    static func end() {
        guard let id = currentID else { return }
        currentID = nil; currentItem = nil
        enqueue(id: id, content: nil, ending: true)
    }
    private static func enqueue(id: String, content: ActivityContent<JellyPlaybackAttributes.ContentState>?, ending: Bool) {
        let previous = pending
        pending = Task.detached(priority: .utility) {
            await previous?.value
            guard let activity = Activity<JellyPlaybackAttributes>.activities.first(where: { $0.id == id }) else { return }
            if ending {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else if let content {
                await activity.update(content)
            }
        }
    }
}
