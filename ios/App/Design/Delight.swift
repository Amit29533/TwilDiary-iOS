import SwiftUI
import TwilDiaryCore

/// Gold that sits beside the theme accent in celebrations.
private let celebrationGold = Color(webHex: "#f5d27a")

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
                BrandMark().fill(index.isMultiple(of: 2) ? theme.accent : celebrationGold).frame(width: 8, height: 8)
                    .offset(x: out ? cos(radians) * reach : 0, y: out ? sin(radians) * reach : 0)
                    .scaleEffect(out ? 0.25 : 1.15).opacity(out ? 0 : 1)
            }
        }.onAppear { withAnimation(.spring(duration: 0.75, bounce: 0.15)) { out = true } }
    }
}

/// The app-wide milestone moment: stars fall across the screen and a glass card names the milestone.
/// It never takes a touch, and Reduce Motion leaves just the card.
struct CelebrationOverlay: View {
    @Environment(DiaryStore.self) private var store
    var body: some View {
        ZStack {
            if let celebration = store.celebration {
                CelebrationMoment(milestone: celebration.milestone) { store.dismissCelebration(celebration.id) }
                    .id(celebration.id).transition(.opacity)
            }
        }.animation(.easeOut(duration: 0.3), value: store.celebration?.id)
            .allowsHitTesting(false)
            .sensoryFeedback(.success, trigger: store.celebration?.id)
    }
}

private struct CelebrationMoment: View {
    let milestone: Milestone
    let finish: () -> Void
    struct Star { let x: Double; let size: CGFloat; let delay: Double; let duration: Double; let spin: Double; let gold: Bool; let drift: CGFloat }
    @State private var stars: [Star] = (0..<26).map { _ in
        Star(x: .random(in: 0.02...0.98), size: .random(in: 8...19), delay: .random(in: 0...0.55), duration: .random(in: 1.5...2.4),
             spin: .random(in: 200...560) * (Bool.random() ? 1 : -1), gold: .random(), drift: .random(in: -40...40))
    }
    @State private var falling = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if !reduceMotion {
                    ForEach(stars.indices, id: \.self) { index in
                        let star = stars[index], color = star.gold ? celebrationGold : theme.accent
                        BrandMark().fill(color).frame(width: star.size, height: star.size)
                            .shadow(color: color.opacity(0.7), radius: 6)
                            .rotationEffect(.degrees(falling ? star.spin : 0))
                            .position(x: geometry.size.width * star.x + (falling ? star.drift : 0), y: falling ? geometry.size.height + 40 : -30)
                            .animation(.easeIn(duration: star.duration).delay(star.delay), value: falling)
                    }
                }
                card.padding(.top, geometry.safeAreaInsets.top + 64)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.ignoresSafeArea()
            .task {
                falling = true
                withAnimation(.spring(duration: 0.55, bounce: 0.45)) { shown = true }
                AccessibilityNotification.Announcement(milestone.headline + ", " + milestone.detail).post()
                try? await Task.sleep(for: .seconds(2.8))
                finish()
            }
    }
    private var card: some View {
        HStack(spacing: 12) {
            BrandMark().fill(theme.accent).frame(width: 26, height: 26)
                .rotationEffect(.degrees(shown && !reduceMotion ? 360 : 0)).scaleEffect(shown ? 1 : 0.3)
            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.headline).font(.system(size: 17, weight: .bold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                Text(milestone.detail).font(.system(size: 13)).foregroundStyle(Color(webHex: "#c5c0cf")).lineLimit(1)
            }
        }.padding(.leading, 16).padding(.trailing, 20).padding(.vertical, 13)
            .glassEffect(.regular, in: Capsule())
            .scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0)
            .accessibilityHidden(true)
    }
}
