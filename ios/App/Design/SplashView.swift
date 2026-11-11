import SwiftUI

/// The animated splash: TwilDiary's star springs in and turns inside a violet glow, a ring of
/// small sparkles bursts out, and the name rises letter by letter. It follows the black launch
/// screen without a seam, stays (gently breathing) only while the diary is still opening, then
/// lifts away. Reduce Motion: a plain fade.
struct SplashView: View {
    /// Called once the opening animation has played (about 1.4 s).
    var onFinished: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markIn = false
    @State private var turned = false
    @State private var glow = false
    @State private var burst = false
    @State private var lettersIn = 0
    @State private var taglineIn = false
    @State private var breathing = false
    private let name = Array("TwilDiary")
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
                HStack(spacing: 0) {
                    ForEach(Array(name.enumerated()), id: \.offset) { index, letter in
                        Text(String(letter))
                            .font(.system(size: 40, weight: .bold, design: .rounded)).tracking(-0.5)
                            .foregroundStyle(.white)
                            .opacity(index < lettersIn ? 1 : 0)
                            .offset(y: index < lettersIn ? 0 : 14)
                            .blur(radius: index < lettersIn ? 0 : 4)
                    }
                }.accessibilityElement().accessibilityLabel("TwilDiary")
                Text("Your watch diary").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .opacity(taglineIn ? 1 : 0).offset(y: taglineIn ? 0 : 6)
            }.offset(y: -10)
        }
        .accessibilityIdentifier("splash")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.35)) { markIn = true; turned = true; glow = true; lettersIn = name.count; taglineIn = true }
            try? await Task.sleep(for: .milliseconds(600))
            onFinished(); return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { markIn = true }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) { turned = true }
        withAnimation(.easeOut(duration: 0.7)) { glow = true }
        try? await Task.sleep(for: .milliseconds(260))
        withAnimation(.easeOut(duration: 0.75)) { burst = true }
        try? await Task.sleep(for: .milliseconds(120))
        for index in 1...name.count {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) { lettersIn = index }
            try? await Task.sleep(for: .milliseconds(45))
        }
        withAnimation(.easeOut(duration: 0.4)) { taglineIn = true }
        try? await Task.sleep(for: .milliseconds(450))
        onFinished()
        // Still opening: breathe until the diary is ready and the splash lifts away.
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathing = true }
    }
}
