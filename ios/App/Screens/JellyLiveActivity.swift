import Foundation
import ActivityKit

/// JellySpace shows no Live Activity of its own: the system's Now Playing card on the Lock Screen
/// does that job. Older builds started one, which could outlive the player (on the Lock Screen and in
/// the Dynamic Island with nothing playing), so any left over is ended when the app opens.
enum JellyLiveActivity {
    static func endLeftovers() {
        Task.detached(priority: .utility) {
            for activity in Activity<JellyPlaybackAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
