import SwiftUI
import ActivityKit

#if canImport(ActivityKit)
/// JellySpace's Live Activity: what's playing, how far in (moving on its own from the times below,
/// so the app needn't update it every second), and the next episode's countdown.
public struct JellyPlaybackAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// The show (or the film).
        public var title: String
        /// "S1:E3 - Name", or the film's year.
        public var detail: String
        /// When it would have started, at this speed, to be where it is now.
        public var startedAt: Date
        /// When it ends, at this speed.
        public var endsAt: Date
        public var paused: Bool
        /// Where it is and how long it is (for the bar while paused).
        public var position: Double
        public var duration: Double
        /// "E4 · Name" and when it starts, during the up-next countdown.
        public var nextTitle: String?
        public var nextAt: Date?

        public init(title: String, detail: String, startedAt: Date, endsAt: Date, paused: Bool, position: Double, duration: Double,
                    nextTitle: String? = nil, nextAt: Date? = nil) {
            self.title = title; self.detail = detail; self.startedAt = startedAt; self.endsAt = endsAt; self.paused = paused
            self.position = position; self.duration = duration; self.nextTitle = nextTitle; self.nextAt = nextAt
        }
    }
    public let itemID: String
    public init(itemID: String) { self.itemID = itemID }
}
#endif

/// The Lock Screen card: the app's mark, the title and episode, then the bar with the time left,
/// or the next episode's countdown.
@MainActor struct JellyPlaybackBanner: View {
    let state: JellyPlaybackAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SyncAppMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(state.detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: state.paused ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            if let next = state.nextTitle, let at = state.nextAt {
                HStack(spacing: 6) {
                    Text("Up next in").foregroundStyle(.white.opacity(0.6))
                    Text(timerInterval: Date.now...max(Date.now, at), countsDown: true).monospacedDigit().foregroundStyle(.white)
                    Text("· " + next).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }.font(.system(size: 13, weight: .semibold))
            } else {
                JellyPlaybackBar(state: state)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// The bar and the time left: moving by itself while playing, still while paused.
struct JellyPlaybackBar: View {
    let state: JellyPlaybackAttributes.ContentState
    var body: some View {
        HStack(spacing: 10) {
            if state.paused || state.endsAt <= state.startedAt {
                ProgressView(value: min(state.position, max(state.duration, 1)), total: max(state.duration, 1))
                Text("Paused").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView(timerInterval: state.startedAt...state.endsAt, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                Text(timerInterval: Date.now...max(Date.now, state.endsAt), countsDown: true)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.8)).frame(width: 56, alignment: .trailing)
            }
        }.tint(.white)
    }
}
