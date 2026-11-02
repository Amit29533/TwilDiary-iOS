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
