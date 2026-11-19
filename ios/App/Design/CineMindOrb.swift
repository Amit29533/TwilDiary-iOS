import SwiftUI

/// CineMind's mark (owner's reference animation, 2026-11-19): a soft lavender glass bubble with
/// liquid cyan, violet and magenta slowly churning inside. Drawn live (a moving mesh of colour in
/// a wobbling blob, behind a glass rim and highlight), so it stays sharp at every size. `lively`:
/// while CineMind thinks, the liquid moves faster. Still under Reduce Motion.
struct CineMindOrb: View {
    let size: CGFloat
    var lively = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.8 : context.date.timeIntervalSinceReferenceDate * (lively ? 1.5 : 0.55)
            orb(time)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func orb(_ t: Double) -> some View {
        ZStack {
            // The glass: a pale lavender bubble.
            Circle().fill(RadialGradient(colors: [Color(red: 0.86, green: 0.85, blue: 1.0).opacity(0.55),
                                                  Color(red: 0.70, green: 0.70, blue: 0.96).opacity(0.75)],
                                         center: .center, startRadius: 0, endRadius: size * 0.55))
            // The liquid: a mesh of colour that drifts, inside a blob that wobbles.
            MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colours)
                .clipShape(OrbBlob(phase: t))
                .padding(size * 0.07)
                .blur(radius: size * 0.012)
            // The rim and the light on the glass.
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.15), Color(red: 0.75, green: 0.72, blue: 1).opacity(0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: max(0.6, size * 0.035))
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.5, height: size * 0.2)
                .offset(x: -size * 0.06, y: -size * 0.3)
                .blur(radius: size * 0.02)
        }
        .compositingGroup()
    }

    /// Light cyan and sky blue over violet and magenta, as in the reference.
    static let colours: [Color] = [
        Color(red: 0.55, green: 0.42, blue: 1.0), Color(red: 0.62, green: 0.84, blue: 1.0), Color(red: 0.48, green: 0.36, blue: 0.98),
        Color(red: 0.70, green: 0.90, blue: 1.0), Color(red: 0.56, green: 0.80, blue: 1.0), Color(red: 0.62, green: 0.30, blue: 0.95),
        Color(red: 0.80, green: 0.25, blue: 0.95), Color(red: 0.45, green: 0.38, blue: 1.0), Color(red: 0.88, green: 0.30, blue: 0.92)
    ]
    /// The mesh's nine points: corners fixed, the rest drifting on slow, out-of-step waves.
    static func points(_ t: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ offset: Double, _ reach: Double) -> Float { Float(sin(t * speed + offset) * reach) }
        return [
            [0, 0], [0.5 + wave(0.9, 0.0, 0.18), 0], [1, 0],
            [0, 0.5 + wave(0.7, 1.3, 0.2)], [0.45 + wave(1.1, 2.1, 0.22), 0.45 + wave(0.8, 0.4, 0.22)], [1, 0.5 + wave(0.6, 2.7, 0.2)],
            [0, 1], [0.5 + wave(1.0, 3.6, 0.18), 1], [1, 1]
        ]
    }
}

/// The liquid's outline: a round blob whose edge swells and dips in slow waves.
private struct OrbBlob: Shape {
    let phase: Double
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let count = 10
        let points: [CGPoint] = (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            let swell = 0.84 + 0.09 * sin(3 * angle + phase * 1.3) + 0.06 * sin(5 * angle - phase * 0.9)
            return CGPoint(x: centre.x + cos(angle) * radius * swell, y: centre.y + sin(angle) * radius * swell)
        }
        var path = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[count - 1], points[0]))
        for index in 0..<count {
            path.addQuadCurve(to: mid(points[index], points[(index + 1) % count]), control: points[index])
        }
        path.closeSubpath()
        return path
    }
}
