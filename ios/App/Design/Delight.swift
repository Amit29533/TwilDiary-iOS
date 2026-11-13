import SwiftUI
import TwilDiaryCore

/// Gold that sits beside the theme accent in the star burst.
private let burstGold = Color(webHex: "#f5d27a")

extension View {
    /// Each change of `trigger` pops the control and throws a ring of tiny TwilDiary stars from it.
    func starBurst(trigger: Int) -> some View { modifier(StarBurst(trigger: trigger)) }
}

private struct StarBurst: ViewModifier {
    let trigger: Int
    @State private var bursts: [UUID] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.22, 1.0], trigger: trigger) { view, scale in view.scaleEffect(scale) } animation: { _ in Motion.press }
            .overlay { ZStack { ForEach(bursts, id: \.self) { _ in BurstRing() } }.allowsHitTesting(false).accessibilityHidden(true) }
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                let burst = UUID(); bursts.append(burst)
                Task { try? await Task.sleep(for: .seconds(0.9)); bursts.removeAll { $0 == burst } }
            }
    }
}

/// Eight small stars fly out and fade while a thin ring widens behind them.
private struct BurstRing: View {
    @State private var out = false
    @State private var angles = (0..<8).map { Double($0) * 45 + Double.random(in: -14...14) }
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        ZStack {
            Circle().strokeBorder(theme.accent.opacity(out ? 0 : 0.55), lineWidth: out ? 1 : 3).frame(width: out ? 70 : 18, height: out ? 70 : 18)
            ForEach(angles.indices, id: \.self) { index in
                let radians = angles[index] * .pi / 180, reach: CGFloat = index.isMultiple(of: 2) ? 38 : 28
                BrandMark().fill(index.isMultiple(of: 2) ? theme.accent : burstGold).frame(width: 8, height: 8)
                    .offset(x: out ? cos(radians) * reach : 0, y: out ? sin(radians) * reach : 0)
                    .scaleEffect(out ? 0.25 : 1.15).opacity(out ? 0 : 1)
            }
        }.onAppear { withAnimation(.spring(duration: 0.75, bounce: 0.15)) { out = true } }
    }
}
