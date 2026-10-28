import SwiftUI
import UIKit
import TwilDiaryCore

/// Only the small toolbar leaves observe scrolling. Keeping this reference in
/// the detail screen avoids invalidating every episode and cast cell per frame.
@MainActor @Observable final class CompactHeaderState {
    private(set) var progress: CGFloat = 0
    func update(_ value: CGFloat) {
        let next = value.isFinite ? min(1, max(0, value)) : 0
        guard next != progress else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { progress = next }
    }
}

/// Content-sized identity inside the system navigation bar. The system retains
/// Back/interactive transitions and owns safe-area geometry during scrolling.
struct CompactTitleNavigation: View {
    let name: String
    let poster: String?
    let state: CompactHeaderState
    private var progress: CGFloat { state.progress }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            Artwork(path: poster, title: name, initialsOnly: false).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 9))
            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }.frame(height: 28)
            .opacity(Double(progress))
            .offset(y: reduceMotion ? 0 : (1 - progress) * 6)
            .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityIdentifier("compact-title-navigation")
            .accessibilityHidden(progress < 0.5)
    }
}

/// Ignore the crossing band: toolbar layout and a reversing scroll must not
/// repeatedly insert/remove the title at the same single-pixel threshold.
enum CompactHeaderTransition {
    static func progress(nameBottom: CGFloat) -> CGFloat {
        guard nameBottom.isFinite else { return 0 }
        // Fade over 80 points of real scroll. Quantization limits body work;
        // there is no animation repeatedly chasing a reversing finger.
        let value = min(1, max(0, (48 - nameBottom) / 80))
        return (value * 32).rounded() / 32
    }
}

struct CompactHeaderBackdrop: View {
    let state: CompactHeaderState
    let topInset: CGFloat
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay(.black.opacity(0.22))
            .opacity(Double(state.progress))
            .frame(height: topInset).offset(y: -topInset)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// One native toolbar button owns the crossfade. Stacking two interactive
/// toolbar controls can leave the invisible control intercepting the share tap.
struct TitleHeaderAction: View {
    let name: String
    let kind: MediaKind
    let id: Int?
    let state: CompactHeaderState
    @Binding var informationPresented: Bool
    var informationIdentifier = "title-information"
    @State private var sharing = false
    private var progress: CGFloat { state.progress }
    private var compact: Bool { progress >= 0.5 }
    var body: some View {
        Button {
            if compact { sharing = true } else { informationPresented = true }
        } label: {
            ZStack {
                Image(systemName: "square.and.arrow.up").opacity(Double(progress))
                Image(systemName: "info.circle").opacity(Double(1 - progress))
            }.frame(width: 32, height: 32)
        }.accessibilityLabel(compact ? "Share " + name : "Community information")
            .accessibilityIdentifier(compact ? "title-share" : informationIdentifier)
            .sheet(isPresented: $sharing) { TitleActivitySheet(name: name, kind: kind, id: id) }
    }
}

@MainActor private struct TitleActivitySheet: UIViewControllerRepresentable {
    let name: String
    let kind: MediaKind
    let id: Int?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let item: Any
        if let id, id > 0, let url = URL(string: "https://www.themoviedb.org/\(kind == .tv ? "tv" : "movie")/\(id)") { item = url }
        else { item = name }
        return UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
