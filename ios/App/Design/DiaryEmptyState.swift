import SwiftUI

/// Shared web EmptyState geometry and copy, including the dashed inset boundary.
struct DiaryEmptyState: View {
    let title: String
    let description: String
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if ThemeStore.current.native {
            // Native: iOS's own empty state (symbol, title, explanation), as Apple's apps show one.
            ContentUnavailableView {
                Label(title, systemImage: "sparkles")
            } description: {
                Text(description)
            }.frame(maxWidth: .infinity, minHeight: 250)
        } else {
            classic
        }
    }
    private var classic: some View {
        VStack(spacing: 0) {
            DiaryIcon(name: "sparkles", size: 28).foregroundStyle(theme.accent).padding(.bottom, 8)
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.ink).padding(.bottom, 8)
            Text(description).font(.system(size: 13.76)).foregroundStyle(Color(themed: "#a09aa9")).lineSpacing(5).frame(maxWidth: 360)
        }.multilineTextAlignment(.center).padding(.horizontal, 24).padding(.vertical, 64).frame(maxWidth: .infinity, minHeight: 250)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(themed: "#ffffff21"), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .accessibilityElement(children: .contain)
    }
}
