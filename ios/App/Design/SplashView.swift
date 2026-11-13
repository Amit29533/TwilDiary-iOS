import SwiftUI

/// The animated splash: TwilDiary's star springs in and turns, on its own with no glow,
/// sparkles or words (owner's choice; about 0.65 s). It follows the black launch
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
    @State private var breathing = false
    private let violet = Color(red: 0.69, green: 0.60, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 26) {
                ZStack {
                    // Just the star (owner's choice: no glow or sparkles around it).
                    BrandMark()
                        .fill(LinearGradient(colors: [.white, violet], startPoint: .top, endPoint: .bottom))
                        .frame(width: 78, height: 78)
                        .rotationEffect(.degrees(turned ? 0 : -90))
                        .scaleEffect(markIn ? (breathing ? 1.04 : 1) : 0.2)
                        .opacity(markIn ? 1 : 0)
                }.frame(width: 200, height: 120)
            }.offset(y: -10)
        }
        .accessibilityIdentifier("splash")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { markIn = true; turned = true; glow = true }
            try? await Task.sleep(for: .milliseconds(350))
            onFinished(); return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) { markIn = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { turned = true }
        withAnimation(.easeOut(duration: 0.45)) { glow = true }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.easeOut(duration: 0.5)) { burst = true }
        try? await Task.sleep(for: .milliseconds(500))
        onFinished()
        // Still opening: breathe until the diary is ready and the splash lifts away.
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { breathing = true }
    }
}
