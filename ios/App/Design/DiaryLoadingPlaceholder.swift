import SwiftUI

/// Static, noninteractive content space. Background refreshes keep the loaded
/// content instead of inserting/removing a spinner row above its controls.
struct DiaryLoadingPlaceholder: View {
    var height: CGFloat = 160
    var label = "Loading content"
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)).frame(height: max(44, height - 80))
                Capsule().fill(.white.opacity(0.08)).frame(width: geometry.size.width * 0.72, height: 12)
                Capsule().fill(.white.opacity(0.05)).frame(width: geometry.size.width * 0.48, height: 10)
            }
        }.frame(height: height).allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
