import SwiftUI
import ActivityKit
import TwilDiaryCore

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

/// The Lock Screen pill, as Cinopsys draws it: TwilDiary's icon, "Syncing with Simkl" and
/// "5 of 382", and a ring that fills as it goes.
@MainActor struct DynamicIslandSyncBannerView: View {
    let state: SyncLiveActivityState

    var body: some View {
        HStack(spacing: 14) {
            SyncAppMark(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(SyncActivityText.headline(state)).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(SyncActivityText.detail(state)).font(.system(size: 15)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            SyncRing(state: state, size: 44)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// TwilDiary's icon (the widget's own copy of it).
struct SyncAppMark: View {
    let size: CGFloat
    var body: some View {
        Image("AppMark").resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

/// Progress as a ring: white while it runs, green when done, amber when it needs you.
struct SyncRing: View {
    let state: SyncLiveActivityState
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: size * 0.09)
            Circle().trim(from: 0, to: max(0.03, state.fraction)).stroke(tint, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbol).font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(tint)
        }.frame(width: size, height: size)
    }
    private var symbol: String {
        switch state.phase {
        case .completed: "checkmark"
        case .failed, .paused: "exclamationmark"
        default: "arrow.triangle.2.circlepath"
        }
    }
    private var tint: Color {
        switch state.phase {
        case .completed: Color(red: 0.5, green: 0.88, blue: 0.71)
        case .failed, .paused: .orange
        default: .white
        }
    }
}

enum SyncActivityText {
    /// "Syncing with Simkl", "Simkl sync paused", "Synced with Simkl".
    static func headline(_ state: SyncLiveActivityState) -> String {
        switch state.phase {
        case .completed: "Synced with \(state.providerDisplayName)"
        case .failed: "\(state.providerDisplayName) needs attention"
        case .paused: "\(state.providerDisplayName) sync paused"
        default: "Syncing with \(state.providerDisplayName)"
        }
    }
    /// "5 of 382", or what went wrong.
    static func detail(_ state: SyncLiveActivityState) -> String {
        if state.phase == .failed || state.phase == .paused { return state.subtitle }
        return state.totalCount > 0 ? "\(state.completedCount) of \(state.totalCount)" : state.subtitle
    }
}
