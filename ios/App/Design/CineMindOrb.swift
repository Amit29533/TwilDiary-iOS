import SwiftUI
import UIKit

/// CineMind's mark: the liquid inside the owner's reference orb (2026-11-19), cyan, violet and
/// magenta churning, played from the frames of that animation (`cinemind-orb.jpg`: 140 frames of
/// 96 px, 20 a second, its end blended into its start so it loops without a jump), in a circle
/// with a thin rim. `lively`: while CineMind thinks, it plays faster. Still under Reduce Motion.
struct CineMindOrb: View {
    let size: CGFloat
    var lively = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Off screen in a scroll view (a row scrolled away), the orb stops: its 20 redraws a second
    /// went on there and cost frames while the page scrolled.
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || !onScreen)) { context in
            let frames = OrbFrames.shared.frames
            if frames.isEmpty {
                Circle().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.80, blue: 1), Color(red: 0.62, green: 0.30, blue: 0.95)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                let time = context.date.timeIntervalSinceReferenceDate * (lively ? 1.6 : 1)
                let index = reduceMotion ? 0 : Int(time * 20) % frames.count
                Image(decorative: frames[index], scale: 1).resizable().interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(red: 1, green: 0.88, blue: 0.95).opacity(0.55), lineWidth: max(0.5, size * 0.025)))
        .accessibilityHidden(true)
    }
}

/// The orb's frames, cut from the sheet once and shared by every orb on screen.
@MainActor private final class OrbFrames {
    static let shared = OrbFrames()
    let frames: [CGImage]
    init() {
        guard let path = Bundle.main.path(forResource: "cinemind-orb", ofType: "jpg"),
              let sheet = UIImage(contentsOfFile: path)?.cgImage else { frames = []; return }
        let side = 96, columns = sheet.width / side, rows = sheet.height / side, count = 140
        var cut: [CGImage] = []
        for index in 0..<min(count, columns * rows) {
            let rect = CGRect(x: (index % columns) * side, y: (index / columns) * side, width: side, height: side)
            if let frame = sheet.cropping(to: rect) { cut.append(frame) }
        }
        frames = cut
    }
}
