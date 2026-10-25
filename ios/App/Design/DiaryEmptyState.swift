import SwiftUI

/// Shared web EmptyState geometry and copy, including the dashed inset boundary.
struct DiaryEmptyState: View {
    let title: String
    let description: String
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        VStack(spacing: 0) {
            DiaryIcon(name: "sparkles", size: 28).foregroundStyle(theme.accent).padding(.bottom, 8)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(.white).padding(.bottom, 8)
            Text(description).font(.system(size: 13.76)).foregroundStyle(Color(webHex: "#a09aa9")).lineSpacing(5).frame(maxWidth: 360)
        }.multilineTextAlignment(.center).padding(.horizontal, 24).padding(.vertical, 64).frame(maxWidth: .infinity, minHeight: 250)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(webHex: "#ffffff21"), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .accessibilityElement(children: .contain)
    }
}
