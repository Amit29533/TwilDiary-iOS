import SwiftUI

/// The animated splash: TwilDiary's star springs in and turns inside a violet glow, and a ring of
/// small sparkles bursts out (about 0.65 s). It follows the black launch
/// screen without a seam, stays (gently breathing) only while the diary is still opening, then
/// lifts away. Reduce Motion: a plain fade.
struct SplashView: View {
    /// Called once the opening animation has played (about 0.65 s).
    var onFinished: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markIn = false
    @State private var turned = false
    @State private var glow = false
    @State private var burst = false
    @State private var taglineIn = false
    @State private var breathing = false
    private let violet = Color(red: 0.69, green: 0.60, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // The glow behind the mark.
            RadialGradient(colors: [violet.opacity(0.55), violet.opacity(0.12), .clear], center: .center, startRadius: 4, endRadius: 190)
                .frame(width: 380, height: 380)
                .scaleEffect(glow ? (breathing ? 1.08 : 1) : 0.3)
                .opacity(glow ? (breathing ? 0.85 : 1) : 0)
                .offset(y: -40)
                .blur(radius: 6)
            VStack(spacing: 26) {
                ZStack {
                    // Sparkles bursting out of the mark.
                    ForEach(0..<8, id: \.self) { index in
                        let angle = Double(index) / 8 * 2 * .pi + .pi / 8
                        let reach: CGFloat = index.isMultiple(of: 2) ? 88 : 64
                        BrandMark().fill(violet)
                            .frame(width: index.isMultiple(of: 2) ? 12 : 8, height: index.isMultiple(of: 2) ? 12 : 8)
                            .offset(x: burst ? cos(angle) * reach : 0, y: burst ? sin(angle) * reach : 0)
                            .scaleEffect(burst ? 1 : 0.2)
                            .opacity(burst ? 0 : (markIn ? 1 : 0))
                    }
                    BrandMark()
                        .fill(LinearGradient(colors: [.white, violet], startPoint: .top, endPoint: .bottom))
                        .frame(width: 78, height: 78)
                        .shadow(color: violet.opacity(0.8), radius: glow ? 22 : 0)
                        .rotationEffect(.degrees(turned ? 0 : -90))
                        .scaleEffect(markIn ? (breathing ? 1.04 : 1) : 0.2)
                        .opacity(markIn ? 1 : 0)
                }.frame(width: 200, height: 120)
                Text("Your watch diary").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .opacity(taglineIn ? 1 : 0).offset(y: taglineIn ? 0 : 6)
            }.offset(y: -10)
        }
        .accessibilityIdentifier("splash")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { markIn = true; turned = true; glow = true; taglineIn = true }
            try? await Task.sleep(for: .milliseconds(350))
            onFinished(); return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { markIn = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { turned = true }
        withAnimation(.easeOut(duration: 0.45)) { glow = true }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.easeOut(duration: 0.5)) { burst = true }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.3)) { taglineIn = true }
        try? await Task.sleep(for: .milliseconds(400))
        onFinished()
        // Still opening: breathe until the diary is ready and the splash lifts away.
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { breathing = true }
    }
}
